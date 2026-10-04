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
    @Published var searchText: String = "" { didSet { pruneSelection() } }
    @Published var favoritesOnly = false { didSet { pruneSelection() } }
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var isSelecting = false

    var selectedEvents: [EventData] { filteredEvents.filter { selectedIDs.contains($0.id) } }
    var hasNoFavorites: Bool { favoritesOnly && !events.contains { favoriteIDs.contains($0.id) } }
    var isBusy: Bool { activity != nil }

    func beginSelection(_ event: EventData? = nil) {
        guard canInteract() else { return }
        isSelecting = true
        if let event, filteredEvents.contains(where: { $0.id == event.id }) { selectedIDs.insert(event.id) }
    }

    func toggleSelection(_ event: EventData) {
        guard canInteract(), filteredEvents.contains(where: { $0.id == event.id }) else { return }
        isSelecting = true
        if !selectedIDs.insert(event.id).inserted { selectedIDs.remove(event.id) }
    }

    func selectAllVisible() {
        guard canInteract() else { return }
        isSelecting = true
        selectedIDs = Set(filteredEvents.map(\.id))
    }

    func cancelSelection() {
        guard !isBusy else { return }
        selectedIDs.removeAll()
        isSelecting = false
    }

    func toggleFavorite(_ event: EventData) {
        guard canInteract(), events.contains(where: { $0.id == event.id }) else { return }
        favorites.setFavorite(!favoriteIDs.contains(event.id), ids: [event.id], session: session)
        synchronizeFavorites()
    }

    func favoriteSelection(_ favorite: Bool) {
        guard canInteract() else { return }
        favorites.setFavorite(favorite, ids: Set(selectedEvents.map(\.id)), session: session)
        synchronizeFavorites()
    }

    /// Returns only the current filtered selection; the parent owns batch confirmation/submission.
    func batchRegistrationEvents() -> [EventData] {
        guard canInteract() else { return [] }
        return selectedEvents
    }

    private func pruneSelection() {
        selectedIDs.formIntersection(filteredEvents.map(\.id))
    }

    private func canInteract() -> Bool {
        synchronizeFavorites()
        return !isBusy && favorites.isCurrent(session)
    }

    func synchronizeFavorites() {
        guard favorites.isCurrent(session) else {
            cancelLoading()
            events = []
            favoriteIDs = []
            selectedIDs = []
            isSelecting = false
            searchText = ""
            favoritesOnly = false
            updatedAt = nil
            alert = nil
            phase = .idle
            return
        }
        favoriteIDs = favorites.favorites(for: session)
        pruneSelection()
    }

    var filteredEvents: [EventData] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = events.filter { !favoritesOnly || favoriteIDs.contains($0.id) }
        if query.isEmpty {
            return candidates
        } else {
            return candidates.filter { event in
                event.eventSerialID.localizedCaseInsensitiveContains(query) ||
                event.name.localizedCaseInsensitiveContains(query) ||
                event.department.localizedCaseInsensitiveContains(query) ||
                event.eventDetail.localizedCaseInsensitiveContains(query)
            }
        }
    }

    // MARK: - Loading

    private let service: any EventRegistrationServing
    private let favorites: EventFavoritesStore
    private let session: EventFavoritesStore.Session?
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var cancellables = Set<AnyCancellable>()

    init(service: (any EventRegistrationServing)? = nil, favorites: EventFavoritesStore? = nil) {
        self.service = service ?? EventRegistrationClient.shared
        let favorites = favorites ?? .shared
        self.favorites = favorites
        session = favorites.currentSession
        favoriteIDs = favorites.favorites(for: session)
        favorites.$revision.dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.synchronizeFavorites() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.synchronizeFavorites() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .didChangeEventRegistration)
            .sink { [weak self] _ in Task { @MainActor in self?.reload() } }
            .store(in: &cancellables)
    }

    /// Loads once per visit; a failed or cancelled load waits for the user's retry or next visit.
    func loadIfNeeded() {
        synchronizeFavorites()
        if phase == .idle { reload() }
    }

    func reload() {
        guard canInteract() else { return }
        loadTask?.cancel()
        let id = UUID()
        loadID = id
        phase = .loading
        let service = service
        loadTask = Task { [weak self] in
            do {
                let events = try await service.availableEvents()
                guard let self, loadID == id, favorites.isCurrent(session) else { return }
                // School IDs remain stable across refreshes; discard duplicate or missing identifiers.
                var seen = Set<String>()
                self.events = events.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
                pruneSelection()
                updatedAt = Date()
                phase = .loaded
            } catch {
                guard let self, loadID == id, favorites.isCurrent(session) else { return }
                phase = error is CancellationError ? (updatedAt == nil ? .idle : .loaded)
                    : .failed(EventRegistrationError.message(for: error))
            }
            if self?.loadID == id { self?.loadTask = nil }
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

    deinit { loadTask?.cancel() }

    // MARK: - 報名

    func register(_ event: EventData) {
        guard canInteract(), events.contains(where: { $0.id == event.id }),
              event.event_state.contains("報名中") else { return }
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
            guard favorites.isCurrent(session) else { synchronizeFavorites(); return }
            alert = result
            NotificationCenter.default.post(name: .didChangeEventRegistration, object: nil)
        }
    }
}
