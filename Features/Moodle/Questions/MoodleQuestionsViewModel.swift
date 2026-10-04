import Combine
import Foundation

@MainActor
final class MoodleQuestionsViewModel: ObservableObject {
    @Published private(set) var sections: [MoodleQuestionSection] = [] {
        didSet {
            searchIndex = MoodleSearchIndex(sections.flatMap(\.modules)) {
                [$0.name, $0.description ?? ""].map(MoodleSearch.plainText)
            }
            updateSearch()
        }
    }
    @Published var searchText = "" { didSet { updateSearch() } }
    @Published private(set) var filteredSections: [MoodleQuestionSection] = []
    private var searchIndex = MoodleSearchIndex()

    private func updateSearch() {
        guard !MoodleSearch.trimmed(searchText).isEmpty else {
            filteredSections = sections
            return
        }
        filteredSections = sections.compactMap { section in
            let modules = searchIndex.filter(section.modules, query: searchText)
            return modules.isEmpty ? nil : MoodleQuestionSection(id: section.id, name: section.name, modules: modules)
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repository: any MoodleQuestionsRepositoryProtocol
    private var courseID: Int?
    private var sessionRevision: Int?
    private var hasLoaded = false
    private var generation = 0
    private var loadingTask: Task<[MoodleQuestionSection], Error>?

    init(repository: any MoodleQuestionsRepositoryProtocol) {
        self.repository = repository
    }

    func load(courseId: Int, force: Bool = false) async {
        let revision = repository.sessionRevision
        if courseID != courseId || sessionRevision != revision {
            cancel()
            sections = []
            errorMessage = nil
            hasLoaded = false
            courseID = courseId
            sessionRevision = revision
        }
        guard force || !hasLoaded else { return }
        cancel()
        let requestGeneration = generation
        isLoading = true
        errorMessage = nil
        let task = Task { try await repository.fetchSections(courseId: courseId) }
        loadingTask = task
        defer {
            if generation == requestGeneration {
                isLoading = false
                loadingTask = nil
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            guard revision == repository.sessionRevision else {
                clearSessionData()
                return
            }
            sections = result
            hasLoaded = true
        } catch {
            guard generation == requestGeneration else { return }
            guard revision == repository.sessionRevision else {
                clearSessionData()
                return
            }
            if Task.isCancelled || error is CancellationError ||
                (error as? URLError)?.code == .cancelled { return }
            if (error as? URLError)?.code == .notConnectedToInternet {
                errorMessage = "目前沒有網路連線，請連線後再試。"
            } else if (error as? URLError)?.code == .timedOut {
                errorMessage = "M 園區回應逾時，請稍後重試。"
            } else {
                errorMessage = "無法取得問答活動，請重試或確認 M 園區登入狀態。"
            }
        }
    }

    func cancel() {
        generation &+= 1
        loadingTask?.cancel()
        loadingTask = nil
        isLoading = false
    }

    private func clearSessionData() {
        sections = []
        hasLoaded = false
        sessionRevision = nil
        errorMessage = nil
    }
}
