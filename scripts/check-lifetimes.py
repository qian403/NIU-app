#!/usr/bin/env python3
"""Run the production activity ViewModels offline against a scripted service: one load per visit,
stale responses, cancellation and release, failure versus empty lists, and mutations that keep
running after the page stops loading."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
feature = root / "Features/EventRegistration"

fixture = r'''
import Foundation
import WebKit

@MainActor final class LoginRepository {
    static let shared = LoginRepository()
    func getSavedCredentials() -> (username: String, password: String)? {
        fatalError("Keychain access is forbidden in this fixture")
    }
}

func event(_ id: String) -> EventData {
    EventData(name: "活動 \(id)", department: "測試單位", event_state: "報名中", eventSerialID: id,
              eventTime: "", eventLocation: "", eventRegisterTime: "", eventDetail: "", contactInfoName: "",
              contactInfoTel: "", contactInfoMail: "", Related_links: "", Multi_factor_authentication: "",
              eventPeople: "", Remark: "")
}

@MainActor final class ScriptedService: EventRegistrationServing {
    var availableCalls = 0
    var appliedCalls = 0
    var registerCalls = 0
    var pending: [CheckedContinuation<[EventData], Error>?] = []
    var hold = false
    /// false simulates a response that arrives after the caller has moved on.
    var honorsCancellation = true
    var failure: Error?
    var result: [EventData] = []
    var outcome: EventActionOutcome = .confirmed("已完成報名。")
    var registerGate: CheckedContinuation<Void, Never>?
    var holdRegister = false

    func availableEvents() async throws -> [EventData] {
        availableCalls += 1
        if hold {
            let index = pending.count
            pending.append(nil)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pending[index] = $0 }
            } onCancel: {
                Task { @MainActor in
                    guard self.honorsCancellation, index < self.pending.count,
                          let waiting = self.pending[index] else { return }
                    self.pending[index] = nil
                    waiting.resume(throwing: CancellationError())
                }
            }
        }
        if let failure { throw failure }
        return result
    }
    func drain() {
        pending.compactMap { $0 }.forEach { $0.resume(throwing: CancellationError()) }
        pending.removeAll()
    }
    func appliedEvents() async throws -> [EventData_Apply] { appliedCalls += 1; return [] }
    func register(eventID: String) async throws -> EventActionOutcome {
        registerCalls += 1
        if holdRegister { await withCheckedContinuation { registerGate = $0 } }
        return outcome
    }
    func cancelRegistration(eventID: String) async throws -> EventActionOutcome { .confirmed("已取消報名。") }
    func registrationForm(eventID: String) async throws -> EventRegistrationForm {
        EventRegistrationForm(tel: "0900", mail: "a@example.com")
    }
    func modifyRegistration(eventID: String, form: EventRegistrationForm) async throws -> EventActionOutcome {
        .confirmed("已更新報名資料。")
    }
}

@MainActor func settle(_ condition: @MainActor () -> Bool, _ message: String) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    print("FAIL: \(message)")
    exit(1)
}

@MainActor func expect(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}

@MainActor enum Checks {
    static func run() async {
        let service = ScriptedService()
        let model = EventRegistration_Tab1_ViewModel(service: service)
        service.result = [event("1")]
        model.loadIfNeeded()
        model.loadIfNeeded()
        await settle({ model.phase == .loaded }, "first load finishes")
        model.loadIfNeeded()
        expect(service.availableCalls == 1, "appearing again does not restart a loaded list")

        service.failure = EventRegistrationError.offline
        model.reload()
        await settle({ if case .failed = model.phase { return true }; return false }, "refresh failure surfaces")
        expect(model.events.map(\.id) == ["1"], "a failed refresh keeps the last valid list")

        let empty = EventRegistration_Tab1_ViewModel(service: service)
        empty.reload()
        await settle({ if case .failed = empty.phase { return true }; return false }, "offline first load fails")
        expect(empty.events.isEmpty && empty.updatedAt == nil, "offline is not reported as an empty school list")
        service.failure = nil
        service.result = []
        empty.reload()
        await settle({ empty.phase == .loaded }, "empty list loads")
        expect(empty.events.isEmpty && empty.updatedAt != nil, "a genuinely empty list is distinct from failure")

        service.hold = true
        service.honorsCancellation = false
        service.result = [event("new")]
        model.reload()
        await settle({ service.pending.count == 1 }, "first request waits")
        model.reload()
        await settle({ service.pending.count == 2 }, "second request waits")
        service.pending[1]?.resume(returning: [event("new")])
        service.pending[1] = nil
        await settle({ model.phase == .loaded }, "newest response applies")
        service.pending[0]?.resume(returning: [event("old")])
        service.pending[0] = nil
        try? await Task.sleep(for: .milliseconds(30))
        expect(model.events.map(\.id) == ["new"], "an older response never overwrites a newer one")
        service.drain()
        service.honorsCancellation = true

        let leaving = EventRegistration_Tab1_ViewModel(service: service)
        leaving.loadIfNeeded()
        await settle({ service.pending.count == 1 }, "visit starts loading")
        leaving.cancelLoading()
        expect(leaving.phase == .idle, "leaving before the first result allows the next visit to load")
        service.drain()
        service.hold = false
        leaving.loadIfNeeded()
        await settle({ leaving.phase == .loaded }, "returning reloads")

        service.hold = true
        var refreshing: EventRegistration_Tab1_ViewModel? = EventRegistration_Tab1_ViewModel(service: service)
        weak var released = refreshing
        let pull = Task { [model = refreshing!] in await model.refresh() }
        await settle({ service.pending.count == 1 }, "pull to refresh waits")
        let started = ContinuousClock.now
        pull.cancel()
        await pull.value
        expect(started.duration(to: .now) < .seconds(1), "cancelling pull to refresh returns promptly")
        expect(refreshing?.phase == .idle, "cancelled pull leaves no spinner")
        service.drain()
        refreshing = nil
        expect(released == nil, "a cancelled refresh releases the ViewModel")
        service.hold = false

        let applied = EventRegistration_Tab2_ViewModel(service: service)
        applied.loadIfNeeded()
        await settle({ applied.phase == .loaded }, "applied list loads")
        let appliedBefore = service.appliedCalls
        service.holdRegister = true
        model.register(event("1"))
        model.register(event("1"))
        await settle({ service.registerGate != nil }, "registration starts")
        expect(model.activity != nil && service.registerCalls == 1, "a double tap submits once")
        model.cancelLoading()
        service.registerGate?.resume()
        await settle({ model.alert != nil }, "registration result reported after the list stops loading")
        expect(model.alert?.kind == .success && model.activity == nil, "confirmed registration shown as success")
        await settle({ service.appliedCalls > appliedBefore }, "applied list reloads after registration")

        service.holdRegister = false
        service.outcome = .uncertain("尚無法確認")
        model.alert = nil
        model.register(event("2"))
        await settle({ model.alert != nil }, "uncertain result reported")
        expect(model.alert?.kind == .uncertain, "uncertain outcome is never presented as success")

        let form = EventRegistrationFormViewModel(eventID: "1", service: service)
        form.load()
        await settle({ form.phase == .loaded }, "form loads")
        expect(form.isValid && !form.hasChanges, "loaded form is valid and unchanged")
        form.form.mail = "invalid"
        expect(!form.isValid && form.hasChanges, "invalid mail blocks saving")
        print("PASS: one load per visit, failure vs empty, stale responses, cancellation and release, single mutation, verified outcomes, form validation")
    }
}

@main struct Main {
    static func main() {
        Task { @MainActor in await Checks.run(); exit(0) }
        RunLoop.main.run()
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-lifetime-") as directory:
    folder = Path(directory)
    swift = folder / "Checks.swift"
    swift.write_text(fixture)
    binary = folder / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", str(folder / "ModuleCache"),
        str(feature / "Models/EventRegistrationModels.swift"),
        str(feature / "Services/EventRegistrationClient.swift"),
        str(feature / "ViewModels/EventRegistrationViewModel.swift"),
        str(feature / "ViewModels/EventRegistration_Tab1_ViewModel.swift"),
        str(feature / "ViewModels/EventRegistration_Tab2_ViewModel.swift"),
        str(swift), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=60)
