import SwiftUI
import Combine

@MainActor
final class EventRegistration_Tab2_ViewModel: ObservableObject {
    @Published private(set) var events: [EventData_Apply] = []
    @Published private(set) var phase: EventLoadPhase = .idle
    @Published private(set) var updatedAt: Date?
    @Published private(set) var activity: String?
    @Published var alert: EventActionAlert?

    // 搜尋
    @Published var searchText: String = ""

    var filteredEvents: [EventData_Apply] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return events
        } else {
            return events.filter { event in
                event.eventSerialID.localizedCaseInsensitiveContains(query) ||
                event.name.localizedCaseInsensitiveContains(query) ||
                event.department.localizedCaseInsensitiveContains(query) ||
                event.eventDetail.localizedCaseInsensitiveContains(query) ||
                event.state.localizedCaseInsensitiveContains(query)
            }
        }
    }

    // MARK: - Loading

    private let service: any EventRegistrationServing
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var cancellables = Set<AnyCancellable>()

    init(service: (any EventRegistrationServing)? = nil) {
        self.service = service ?? EventRegistrationClient.shared
        NotificationCenter.default.publisher(for: .didChangeEventRegistration)
            .sink { [weak self] _ in Task { @MainActor in self?.reload() } }
            .store(in: &cancellables)
    }

    /// Loads once per visit; a failed or cancelled load waits for the user's retry or next visit.
    func loadIfNeeded() {
        if phase == .idle { reload() }
    }

    func reload() {
        loadTask?.cancel()
        let id = UUID()
        loadID = id
        phase = .loading
        let session = EventRegistrationClient.shared.sessionRevision
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let events = try await service.appliedEvents()
                guard loadID == id, session == EventRegistrationClient.shared.sessionRevision, !Task.isCancelled else { return }
                EventRegistrationSubmission.shared.reconcileApplied(events, session: session)
                self.events = events
                updatedAt = Date()
                phase = .loaded
            } catch {
                guard loadID == id else { return }
                phase = error is CancellationError ? (updatedAt == nil ? .idle : .loaded)
                    : .failed(EventRegistrationError.message(for: error))
            }
            if loadID == id { loadTask = nil }
        }
    }

    /// Pull to refresh: SwiftUI cancels this when the list leaves the screen.
    func refresh() async {
        reload()
        let id = loadID
        await withTaskCancellationHandler {
            await loadTask?.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.loadID == id else { return }
                self?.cancelLoading()
            }
        }
    }

    /// Stops reading pages; a cancellation or edit already sent keeps running to report its result.
    func cancelLoading() {
        guard let loadTask else { return }
        loadID = UUID()
        loadTask.cancel()
        self.loadTask = nil
        phase = updatedAt == nil ? .idle : .loaded
    }

    // MARK: - 取消／修改報名

    func cancelRegistration(eventID: String) {
        let session = EventRegistrationClient.shared.sessionRevision
        perform(activity: "正在取消報名…", action: "取消報名") { service in
            let outcome = try await service.cancelRegistration(eventID: eventID)
            guard session == EventRegistrationClient.shared.sessionRevision else { throw CancellationError() }
            if case .confirmed = outcome {
                NotificationCenter.default.post(name: .didConfirmEventCancellation, object: nil,
                                                userInfo: ["eventID": eventID, "session": session])
            }
            return outcome
        }
    }

    func modifyRegistration(eventID: String, form: EventRegistrationForm) {
        perform(activity: "正在儲存報名資料…", action: "修改") { service in
            try await service.modifyRegistration(eventID: eventID, form: form)
        }
    }

    private func perform(activity text: String, action: String,
                         _ request: @escaping (any EventRegistrationServing) async throws -> EventActionOutcome) {
        guard activity == nil else { return }
        activity = text
        Task { [weak self] in
            guard let self else { return }
            let result: EventActionAlert
            do {
                result = EventActionAlert(try await request(service), action: action)
            } catch is CancellationError {
                activity = nil
                return
            } catch {
                result = EventActionAlert(error: error, action: action)
            }
            activity = nil
            alert = result
            NotificationCenter.default.post(name: .didChangeEventRegistration, object: nil)
        }
    }
}
