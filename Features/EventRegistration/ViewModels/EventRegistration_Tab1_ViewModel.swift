import SwiftUI
import Combine

@MainActor
final class EventRegistration_Tab1_ViewModel: ObservableObject {
    @Published private(set) var events: [EventData] = []
    @Published private(set) var phase: EventLoadPhase = .idle
    @Published private(set) var updatedAt: Date?
    @Published private(set) var activity: String?
    @Published var alert: EventActionAlert?

    // 搜尋
    @Published var searchText: String = ""

    var filteredEvents: [EventData] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return events
        } else {
            return events.filter { event in
                event.eventSerialID.localizedCaseInsensitiveContains(query) ||
                event.name.localizedCaseInsensitiveContains(query) ||
                event.department.localizedCaseInsensitiveContains(query) ||
                event.eventDetail.localizedCaseInsensitiveContains(query)
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
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let events = try await service.availableEvents()
                guard loadID == id else { return }
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

    /// Stops reading pages; a registration already sent keeps running to report its result.
    func cancelLoading() {
        guard let loadTask else { return }
        loadID = UUID()
        loadTask.cancel()
        self.loadTask = nil
        phase = updatedAt == nil ? .idle : .loaded
    }

    // MARK: - 報名

    func register(_ event: EventData) {
        guard activity == nil else { return }
        activity = "正在報名…"
        Task { [weak self] in
            guard let self else { return }
            let result: EventActionAlert
            do {
                result = EventActionAlert(try await service.register(eventID: event.eventSerialID), action: "報名")
            } catch is CancellationError {
                activity = nil
                return
            } catch {
                result = EventActionAlert(error: error, action: "報名")
            }
            activity = nil
            alert = result
            NotificationCenter.default.post(name: .didChangeEventRegistration, object: nil)
        }
    }
}
