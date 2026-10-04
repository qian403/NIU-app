#if DEBUG
import SwiftUI

/// Launch with `-NIUEventFavoritesFixture list|favorites-empty|selection|selection-animation`.
/// This root bypasses AppState, Keychain, school services and ordinary app defaults.
enum EventFavoritesUIFixture {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-NIUEventFavoritesFixture") }
    static var scenario: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-NIUEventFavoritesFixture"),
              arguments.indices.contains(index + 1) else { return "list" }
        return arguments[index + 1]
    }

    static let events: [EventData] = [
        event("0012345", "生成式 AI 實作工作坊（合成資料）", "報名中"),
        event("22222", "校園攝影講座：構圖與光線（合成資料）", "已額滿"),
        event("33333", "職涯探索講座（合成資料）", "即將開始")
    ]

    private static func event(_ id: String, _ name: String, _ state: String) -> EventData {
        EventData(name: name, department: "合成測試單位", event_state: state, eventSerialID: id,
                  eventTime: "2099/10/10 10:00–12:00", eventLocation: "合成活動中心",
                  eventRegisterTime: "2099/10/01–10/09", eventDetail: "離線畫面測試資料，非校方活動。",
                  contactInfoName: "測試聯絡人", contactInfoTel: "", contactInfoMail: "test@example.com",
                  Related_links: "", Multi_factor_authentication: "", eventPeople: "限額 80 人，已報名 42 人", Remark: "")
    }
}

@MainActor
private final class EventFavoritesFixtureService: EventRegistrationServing {
    func availableEvents() async throws -> [EventData] { EventFavoritesUIFixture.events }
    func appliedEvents() async throws -> [EventData_Apply] { [] }
    func register(eventID: String) async throws -> EventActionOutcome { .rejected("離線展示不會送出報名。") }
    func cancelRegistration(eventID: String) async throws -> EventActionOutcome { .rejected("離線展示不會取消報名。") }
    func registrationForm(eventID: String) async throws -> EventRegistrationForm { throw EventRegistrationError.offline }
    func modifyRegistration(eventID: String, form: EventRegistrationForm) async throws -> EventActionOutcome {
        .rejected("離線展示不會修改報名。")
    }
}

struct EventFavoritesUIFixtureRoot: View {
    @StateObject private var model: EventRegistration_Tab1_ViewModel
    @State private var prepared = false

    init() {
        _model = StateObject(wrappedValue: Self.makeModel())
    }

    private static func makeModel() -> EventRegistration_Tab1_ViewModel {
        // A dedicated synthetic suite never reads ordinary app or real-account defaults.
        let suite = "dev.niu.event-favorites-fixture"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Fixture defaults unavailable") }
        defaults.removePersistentDomain(forName: suite)
        let favorites = EventFavoritesStore(defaults: defaults, account: { "synthetic-fixture" }, session: { "fixture-session" })
        return EventRegistration_Tab1_ViewModel(service: EventFavoritesFixtureService(), favorites: favorites)
    }

    var body: some View {
        NavigationStack {
            EventRegistration_Tab1_View(viewModel: model)
                .navigationTitle("活動報名")
                .navigationBarTitleDisplayMode(.inline)
                .overlay { if let activity = model.activity { EventActivityOverlay(text: activity) } }
                .task {
                    guard !prepared else { return }
                    prepared = true
                    await model.refresh()
                    if EventFavoritesUIFixture.scenario == "favorites-empty" { model.favoritesOnly = true }
                    else if let first = model.events.first {
                        model.toggleFavorite(first)
                        if EventFavoritesUIFixture.scenario == "selection" { model.selectAllVisible() }
                        if EventFavoritesUIFixture.scenario == "selection-animation" {
                            do {
                                try await Task.sleep(for: .seconds(2))
                                model.beginSelection(first)
                                try await Task.sleep(for: .seconds(1))
                                if let second = model.events.dropFirst().first { model.toggleSelection(second) }
                                try await Task.sleep(for: .seconds(1))
                                model.toggleSelection(first)
                                try await Task.sleep(for: .seconds(1))
                                model.cancelSelection()
                            } catch { return }
                        }
                    }
                }
                .onDisappear { model.cancelLoading() }
        }
    }
}
struct EventIntegratedUIFixtureRoot: View {
    private let favorites: EventFavoritesStore
    private let service = EventBatchPreviewFixtures.Service()

    init() {
        let suite = "dev.niu.event-integrated-fixture"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Fixture defaults unavailable") }
        defaults.removePersistentDomain(forName: suite)
        favorites = EventFavoritesStore(defaults: defaults, account: { "synthetic-fixture" }, session: { "fixture-session" })
    }

    var body: some View {
        NavigationStack { EventRegistrationView(service: service, favorites: favorites) }
    }
}
#endif
