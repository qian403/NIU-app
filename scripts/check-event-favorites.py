#!/usr/bin/env python3
"""Exercise production favorites/store/ViewModel with isolated defaults and synthetic services.

Also typechecks the complete event UI + DEBUG fixture against the iOS Simulator SDK.
Never launches a simulator, opens Keychain, or contacts school servers.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
feature = root / "Features/EventRegistration"
stubs = r'''
import Foundation
@MainActor enum StorageKeys {
    static let username = "fixture.username"
    static let authSessionID = "fixture.session"
}
@MainActor final class LoginRepository {
    static let shared = LoginRepository()
    func getSavedCredentials() -> (username: String, password: String)? {
        fatalError("Keychain is forbidden in this offline regression")
    }
}
'''
checks = r'''
@MainActor final class Identity {
    var account: String? = "synthetic-a"
    var session: String? = "session-a"
}

@MainActor final class Service: EventRegistrationServing {
    var rows: [EventData] = []
    var failure = false
    var holdLoads = false
    var loads: [CheckedContinuation<[EventData], Error>] = []
    var registration: CheckedContinuation<EventActionOutcome, Error>?
    var registrationCount = 0
    func availableEvents() async throws -> [EventData] {
        if holdLoads { return try await withCheckedThrowingContinuation { loads.append($0) } }
        if failure { throw EventRegistrationError.offline }
        return rows
    }
    func appliedEvents() async throws -> [EventData_Apply] { [] }
    func register(eventID: String) async throws -> EventActionOutcome {
        registrationCount += 1
        return try await withCheckedThrowingContinuation { registration = $0 }
    }
    func cancelRegistration(eventID: String) async throws -> EventActionOutcome { fatalError("Unexpected mutation") }
    func registrationForm(eventID: String) async throws -> EventRegistrationForm { fatalError("Unexpected form") }
    func modifyRegistration(eventID: String, form: EventRegistrationForm) async throws -> EventActionOutcome { fatalError("Unexpected mutation") }
}

@MainActor enum Checks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { print("FAIL: \(message)"); exit(1) }
    }
    static func until(_ condition: @escaping () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        expect(false, "Timed out waiting for test continuation")
    }
    static func drain() async { for _ in 0..<20 { await Task.yield() } }
    static func event(_ id: String, name: String = "Swift 工作坊") -> EventData {
        EventData(name: name, department: "資訊中心", event_state: "報名中", eventSerialID: id,
                  eventTime: "2099/10/10", eventLocation: "合成場地", eventRegisterTime: "",
                  eventDetail: "程式設計入門", contactInfoName: "", contactInfoTel: "", contactInfoMail: "",
                  Related_links: "", Multi_factor_authentication: "", eventPeople: "", Remark: "")
    }
    static func run() async {
        let suite = "dev.niu.event-favorites-check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Test suite unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = Identity()
        func store() -> EventFavoritesStore {
            EventFavoritesStore(defaults: defaults, account: { identity.account }, session: { identity.session })
        }
        let favorites = store()
        let a = favorites.currentSession
        favorites.setFavorite(true, ids: ["00123", "456"], session: a)
        expect(favorites.favorites(for: a) == ["00123", "456"], "stable IDs preserve leading zeros")
        let second = store()
        expect(second.favorites(for: second.currentSession) == ["00123", "456"], "same-session persistence")
        identity.account = "synthetic-b"; identity.session = "session-b"
        expect(favorites.favorites(for: a).isEmpty, "old read cannot expose previous account")
        favorites.setFavorite(true, ids: ["old-write"], session: a)
        let b = favorites.currentSession
        expect(favorites.favorites(for: b).isEmpty, "old writes rejected after switch")
        favorites.setFavorite(true, ids: ["789"], session: b)
        expect(favorites.favorites(for: b) == ["789"], "new account can favorite")
        identity.account = "synthetic-a"; identity.session = "session-a2"
        expect(favorites.favorites(for: favorites.currentSession).isEmpty, "switch back does not restore cleared account")
        let beforeClear = favorites.currentSession
        favorites.setFavorite(true, ids: ["00123"], session: beforeClear)
        favorites.clear()
        expect(defaults.data(forKey: "eventFavorites.v1.record") == nil, "clear removes all account/ID data immediately")
        second.setFavorite(true, ids: ["resurrection"], session: beforeClear)
        expect(favorites.favorites(for: beforeClear).isEmpty, "clear rejects old read before auth keys removed")
        expect(favorites.favorites(for: favorites.currentSession).isEmpty, "clear generation fences another store instance")
        let beforeLogout = favorites.currentSession
        identity.account = nil; identity.session = nil
        favorites.setFavorite(true, ids: ["old"], session: beforeLogout)
        expect(favorites.currentSession == nil, "logged-out store has no writable session")
        identity.account = "synthetic-a"; identity.session = "session-a3"
        expect(favorites.favorites(for: favorites.currentSession).isEmpty, "logout does not resurrect")
        print("PASS: account/session isolation, same-session persistence, clear generation, cross-instance stale writes, logout")

        let service = Service()
        service.rows = [event("0012345"), event("98765", name: "攝影講座")]
        let model = EventRegistration_Tab1_ViewModel(service: service, favorites: favorites)
        await model.refresh()
        expect(model.phase == .loaded && model.events.count == 2, "synthetic list loads")
        for query in ["001", " 0012345\n", "SWIFT", "程式", "資訊中心"] {
            model.searchText = query
            expect(!model.filteredEvents.isEmpty, "search retains ID/name/detail/department behavior: \(query)")
        }
        model.searchText = "９８７６５"
        expect(model.filteredEvents.map(\.id) == ["98765"], "full-width search")
        model.searchText = ""
        model.toggleFavorite(service.rows[0])
        model.favoritesOnly = true
        expect(model.filteredEvents.map(\.id) == ["0012345"] && !model.hasNoFavorites, "favorites filter")
        model.searchText = "missing"
        expect(model.filteredEvents.isEmpty && !model.hasNoFavorites, "search no results differs from empty favorites")
        model.searchText = ""
        model.beginSelection(service.rows[0])
        expect(model.selectedIDs == ["0012345"], "long press/accessibility begin selection")
        model.favoriteSelection(false)
        expect(model.hasNoFavorites && model.selectedIDs.isEmpty, "unfavorite under favorites filter prunes selection")
        model.favoritesOnly = false
        model.selectAllVisible()
        expect(model.selectedIDs.count == 2, "select all visible")
        model.searchText = "98765"
        expect(model.selectedIDs == ["98765"], "search prunes hidden selection")
        model.searchText = ""
        expect(model.selectedIDs == ["98765"], "clearing search does not restore hidden selection")
        model.selectAllVisible()
        model.favoriteSelection(true)
        expect(model.favoriteIDs == ["0012345", "98765"], "batch favorite persists all selected IDs")
        service.rows = [event("98765", name: "刷新後名稱"), event("98765"), event("")]
        await model.refresh()
        expect(model.events.count == 1 && model.selectedIDs == ["98765"], "refresh prunes removed IDs and deduplicates")
        expect(model.favoriteIDs.contains("0012345"), "refresh absence never deletes favorites")
        expect(model.batchRegistrationEvents().map(\.name) == ["刷新後名稱"], "callback gets current event values")
        service.failure = true
        await model.refresh()
        expect(model.events.count == 1 && model.selectedIDs == ["98765"], "failed refresh preserves list and selection")
        expect(model.phase == .failed(EventRegistrationError.offline.localizedDescription), "failed refresh is explicit")
        service.failure = false
        service.rows = (0..<300).map { event(String(10000 + $0)) }
        await model.refresh()
        model.selectAllVisible()
        expect(model.selectedIDs.count == 300 && model.batchRegistrationEvents().count == 300, "no artificial batch limit")
        model.cancelSelection()
        expect(!model.isSelecting && model.selectedIDs.isEmpty, "cancel clears selection")
        print("PASS: search, favorites/empty states, stable IDs, selection/filter/refresh pruning, failed refresh, unlimited selection")

        // A cancelled request deliberately ignores cancellation; its late response must still be fenced.
        service.holdLoads = true
        model.reload()
        await until { service.loads.count == 1 }
        model.cancelLoading()
        service.loads.removeFirst().resume(returning: [event("stale")])
        await drain()
        expect(model.events.count == 300 && model.phase == .loaded, "cancel ignores late response")
        model.reload()
        await until { service.loads.count == 1 }
        model.reload()
        await until { service.loads.count == 2 }
        service.loads.removeLast().resume(returning: [event("fresh")])
        await until { model.events.first?.id == "fresh" }
        service.loads.removeFirst().resume(returning: [event("obsolete")])
        await drain()
        expect(model.events.first?.id == "fresh", "superseded load cannot replace newer data")
        var temporary: EventRegistration_Tab1_ViewModel? = EventRegistration_Tab1_ViewModel(service: service, favorites: favorites)
        weak let weakModel = temporary
        temporary?.reload()
        await until { service.loads.count == 1 }
        temporary = nil
        expect(weakModel == nil, "pending read does not retain departed ViewModel")
        service.loads.removeFirst().resume(returning: [])
        await drain()
        service.holdLoads = false
        service.rows = [event("fresh")]
        model.beginSelection(model.events[0])
        model.register(model.events[0])
        await until { service.registrationCount == 1 }
        let previousFavorites = model.favoriteIDs
        model.toggleFavorite(model.events[0]); model.favoriteSelection(true)
        model.cancelSelection(); model.selectAllVisible(); model.register(model.events[0])
        expect(model.isBusy && model.favoriteIDs == previousFavorites && model.isSelecting, "busy blocks mutations and cancel")
        expect(model.batchRegistrationEvents().isEmpty && service.registrationCount == 1, "busy prevents batch/repeated registration")
        service.registration?.resume(returning: .uncertain("合成：無法驗證")); service.registration = nil
        await until { !model.isBusy }
        expect(model.alert?.kind == .uncertain, "single registration retains uncertainty")
        await drain()
        service.holdLoads = true
        model.reload()
        await until { service.loads.count == 1 }
        favorites.clear()
        identity.account = "synthetic-b"; identity.session = "new-session"
        await until { model.events.isEmpty } // clear publishes without a view disappearance or explicit resync
        service.loads.removeFirst().resume(returning: [event("after-logout")])
        await drain()
        expect(model.events.isEmpty && model.selectedIDs.isEmpty && model.favoriteIDs.isEmpty, "session change clears old view state")
        model.toggleFavorite(event("old")); model.reload()
        expect(favorites.favorites(for: favorites.currentSession).isEmpty && service.loads.isEmpty, "old VM cannot read/write new session")
        let freshModel = EventRegistration_Tab1_ViewModel(service: service, favorites: favorites)
        service.holdLoads = false
        await freshModel.refresh()
        freshModel.register(service.rows[0])
        await until { service.registrationCount == 2 }
        favorites.clear(); identity.account = nil; identity.session = nil
        service.registration?.resume(returning: .confirmed("合成結果")); service.registration = nil
        await until { !freshModel.isBusy }
        expect(freshModel.alert == nil && freshModel.events.isEmpty, "old registration completion cannot repopulate logout state")
        print("PASS: cancellation, superseding loads, ViewModel lifetime, busy guards, uncertainty, stale-session reads/writes/completions")
    }
}

@main struct Main {
    static func main() async { await Checks.run() }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-event-favorites-") as directory:
    folder = Path(directory)
    support = folder / "Support.swift"
    support.write_text(stubs)
    source = folder / "Checks.swift"
    source.write_text("import Foundation\n" + checks)
    binary = folder / "checks"
    production = [feature / "Models/EventRegistrationModels.swift",
                  feature / "Services/EventRegistrationClient.swift",
                  feature / "Stores/EventFavoritesStore.swift",
                  feature / "ViewModels/EventRegistrationViewModel.swift",
                  feature / "ViewModels/EventRegistration_Tab1_ViewModel.swift"]
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    "-default-isolation", "MainActor", "-module-cache-path", str(folder / "ModuleCache"),
                    *map(str, production), str(support), str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=45)
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    ui = [*sorted(feature.rglob("*.swift")), root / "Shared/Theme/Theme.swift", support]
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-typecheck", "-D", "DEBUG",
                    "-default-isolation", "MainActor", "-sdk", sdk, "-target", "arm64-apple-ios26.2-simulator",
                    "-module-cache-path", str(folder / "SimulatorModuleCache"), *map(str, ui)], check=True)
    print("PASS: complete event UI + DEBUG offline fixture typechecked for iOS Simulator (no simulator launched)")
