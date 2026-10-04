import Foundation
import Combine

@MainActor
final class MoodleUpcomingViewModel: ObservableObject {
    enum State: Equatable {
        case loading, loaded([MoodleUpcomingItem]), empty, failed(String)
    }
    @Published private(set) var state: State = .loading
    @Published private(set) var refreshError: String?
    @Published private(set) var openingID: Int?
    @Published var assignment: MoodleAssignment?
    @Published var navigationError: String?
    @Published private(set) var navigationOwner: UUID?
    @Published private(set) var now: Date
    private let repository: any MoodleUpcomingRepositoryProtocol
    private let clock: () -> Date
    private var courses: [MoodleCourse] = []
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var loadedCourseIDs: [Int]?
    private var submissionRefreshTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var sessionObserver: AnyCancellable?
    private var submissionObserver: AnyCancellable?

    init(repository: (any MoodleUpcomingRepositoryProtocol)? = nil, clock: @escaping () -> Date = Date.init) {
        self.repository = repository ?? MoodleUpcomingRepository()
        self.clock = clock
        now = clock()
        sessionObserver = NotificationCenter.default.publisher(for: .moodleSessionDidChange)
            .sink { [weak self] _ in self?.reset() }
        submissionObserver = NotificationCenter.default.publisher(for: .moodleSubmissionDidChange)
            .sink { [weak self] notification in
                guard let self, let change = notification.object as? MoodleSubmissionChange,
                      change.sessionRevision == self.repository.sessionRevision,
                      self.courses.contains(where: { $0.id == change.courseID }) else { return }
                self.submissionDidChange(assignmentID: change.assignmentID, submitted: change.submitted)
            }
    }

    deinit { loadTask?.cancel(); navigationTask?.cancel(); submissionRefreshTask?.cancel() }

    var items: [MoodleUpcomingItem] {
        if case .loaded(let items) = state { return items }
        return []
    }
    func preview(limit: Int = 5) -> [MoodleUpcomingItem] { Array(items.prefix(max(0, limit))) }
    var grouped: [(group: MoodleUpcomingGroup, items: [MoodleUpcomingItem])] {
        MoodleUpcomingGroup.allCases.compactMap { group in
            let matching = items.filter { MoodleUpcomingRules.group(due: $0.dueDate, now: now) == group }
            return matching.isEmpty ? nil : (group, matching)
        }
    }

    /// Invalidate immediately, including while the course list refresh is still in flight.
    func invalidate(clearState: Bool = true) {
        generation = UUID()
        loadTask?.cancel()
        navigationTask?.cancel()
        loadTask = nil
        navigationTask = nil
        openingID = nil
        assignment = nil
        navigationError = nil
        navigationOwner = nil
        loadedCourseIDs = nil
        refreshError = nil
        submissionRefreshTask?.cancel()
        submissionRefreshTask = nil
        if clearState { state = .loading }
    }
    func fail(_ message: String) {
        invalidate()
        state = .failed(message)
    }
    func reset() {
        invalidate()
        courses = []
    }

    func loadIfNeeded(courses: [MoodleCourse]) async {
        guard !Task.isCancelled else { return }
        let ids = courses.map(\.id).sorted()
        if loadedCourseIDs == ids { return }
        if self.courses.map(\.id).sorted() == ids, let loadTask {
            await loadTask.value
            guard !Task.isCancelled, loadedCourseIDs != ids else { return }
        }
        await load(courses: courses)
    }

    func load(courses: [MoodleCourse]) async {
        guard !Task.isCancelled else { return }
        let task = startLoad(courses: courses)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func startLoad(courses: [MoodleCourse]) -> Task<Void, Never> {
        if self.courses.map(\.id).sorted() != courses.map(\.id).sorted() {
            invalidate()
        } else {
            generation = UUID()
            loadTask?.cancel()
            cancelOpening()
        }
        refreshError = nil
        loadedCourseIDs = nil
        self.courses = courses
        now = clock()
        let request = generation
        let revision = repository.sessionRevision
        let date = now
        let repository = repository
        let task = Task { [weak self] in
            defer {
                if let self, self.generation == request { self.loadTask = nil }
            }
            do {
                let items = try await repository.fetchUpcoming(courses: courses, now: date)
                try Task.checkCancellation()
                guard let self, self.generation == request, revision == repository.sessionRevision else { return }
                self.loadedCourseIDs = courses.map(\.id).sorted()
                self.state = items.isEmpty ? .empty : .loaded(MoodleUpcomingRules.sorted(items))
            } catch {
                guard let self, self.generation == request, revision == repository.sessionRevision,
                      !Task.isCancelled, !(error is CancellationError) else { return }
                let message = "待繳作業載入失敗，請重試。"
                self.loadedCourseIDs = courses.map(\.id).sorted()
                if case .loaded = self.state {
                    self.refreshError = message
                } else {
                    self.state = .failed(message)
                }
            }
        }
        loadTask = task
        return task
    }

    func reload() async { await load(courses: courses) }

    func submissionDidChange(assignmentID: Int, submitted: Bool) {
        guard !courses.isEmpty else { return }
        if submitted, case .loaded(let items) = state {
            let remaining = items.filter { $0.assignmentID != assignmentID }
            state = remaining.isEmpty ? .empty : .loaded(remaining)
        }
        submissionRefreshTask?.cancel()
        // Start synchronously to fence older responses immediately. The task only
        // weakly owns this model, so deinit can cancel an outstanding refresh.
        submissionRefreshTask = startLoad(courses: courses)
    }

    func open(_ item: MoodleUpcomingItem, owner: UUID) {
        navigationOwner = owner
        navigationTask?.cancel()
        openingID = item.id
        navigationError = nil
        let request = generation
        let revision = repository.sessionRevision
        let repository = repository
        navigationTask = Task { [weak self] in
            do {
                let assignment = try await repository.resolveAssignment(item)
                try Task.checkCancellation()
                guard let self, self.generation == request, revision == repository.sessionRevision else { return }
                self.assignment = assignment
                self.openingID = nil
            } catch {
                guard let self, self.generation == request, revision == repository.sessionRevision,
                      !Task.isCancelled, !(error is CancellationError) else { return }
                self.openingID = nil
                self.navigationError = Self.openingErrorMessage(error)
            }
        }
    }

    static func openingErrorMessage(_ error: Error) -> String {
        if case MoodleUpcomingError.assignmentNotFound = error {
            return "這份作業可能已被移除或尚未開放"
        }
        if let error = error as? URLError { return error.localizedDescription }
        if let error = error as? MoodleError {
            switch error {
            case .notAuthenticated, .invalidToken, .authFailed, .serverError:
                return error.localizedDescription
            default: break
            }
        }
        return "無法開啟這份作業，請稍後重試。"
    }

    func cancelOpening() {
        navigationTask?.cancel()
        navigationTask = nil
        openingID = nil
    }
}
