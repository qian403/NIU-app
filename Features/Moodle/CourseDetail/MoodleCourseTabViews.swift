import Combine
import SwiftUI

@MainActor
final class MoodleAnnouncementsViewModel: ObservableObject {
    @Published private(set) var discussions: [MoodleDiscussion] = [] {
        didSet {
            messagePreviews = [:]
            searchIndex = MoodleSearchIndex(discussions) { discussion in
                let message = MoodleSearch.plainText(discussion.message)
                messagePreviews[discussion.id] = message
                return [MoodleSearch.plainText(discussion.subject), discussion.userfullname, message]
            }
            updateSearch()
        }
    }
    @Published var searchText = "" { didSet { updateSearch() } }
    @Published private(set) var filteredDiscussions: [MoodleDiscussion] = []
    private var searchIndex = MoodleSearchIndex()
    private(set) var messagePreviews: [Int: String] = [:]

    private func updateSearch() {
        filteredDiscussions = searchIndex.filter(discussions, query: searchText)
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repository: any MoodleAnnouncementsRepositoryProtocol
    private(set) var hasLoaded = false
    private(set) var hasLoadedAll = false
    private let loads = MoodleCourseLoadCoordinator()
    private var loadGeneration = 0

    init(repository: (any MoodleAnnouncementsRepositoryProtocol)? = nil) {
        self.repository = repository ?? MoodleAnnouncementsRepository()
    }

    func load(courseId: Int, force: Bool = false) async {
        await loads.run(force: force) { [self] in
            await performLoad(courseId: courseId, force: force)
        }
    }

    func loadComplete(courseId: Int, force: Bool = false) async {
        await load(courseId: courseId, force: force)
        guard !Task.isCancelled, hasLoaded, errorMessage == nil else { return }
        // A refresh can supersede pagination and finish before the old task.
        // Continue only while this consumer is active and no actual error occurred.
        repeat {
            await loads.run(force: false, phase: .completeAnnouncements) { [self] in
                guard hasLoaded, errorMessage == nil, !hasLoadedAll else { return }
                loadGeneration &+= 1
                let generation = loadGeneration
                isLoading = true
                errorMessage = nil
                defer { if generation == loadGeneration { isLoading = false } }
                do {
                    let result = try await repository.fetchCompleteAnnouncements(courseId: courseId, cached: discussions)
                    try Task.checkCancellation()
                    guard generation == loadGeneration else { return }
                    discussions = result
                    hasLoadedAll = true
                } catch {
                    guard generation == loadGeneration, !Task.isCancelled else { return }
                    errorMessage = error is CancellationError ? "公告載入已中止，請重試。" : error.localizedDescription
                }
            }
        } while !Task.isCancelled && hasLoaded && !hasLoadedAll && errorMessage == nil
    }

    private func performLoad(courseId: Int, force: Bool) async {
        guard force || !hasLoaded else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { isLoading = false } }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await repository.fetchAnnouncements(courseId: courseId)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            discussions = result
            hasLoaded = true
            hasLoadedAll = false
        } catch {
            guard generation == loadGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct MoodleCourseAnnouncementsView: View {
    let courseId: Int
    @ObservedObject var viewModel: MoodleAnnouncementsViewModel

    private let postsRepository: (any MoodleDiscussionPostsRepositoryProtocol)?

    init(courseId: Int, viewModel: MoodleAnnouncementsViewModel,
         postsRepository: (any MoodleDiscussionPostsRepositoryProtocol)? = nil) {
        self.postsRepository = postsRepository
        self.courseId = courseId
        self.viewModel = viewModel
    }

    var body: some View {
        MoodleCourseTabContainer(
            isLoading: viewModel.isLoading,
            isEmpty: viewModel.discussions.isEmpty,
            errorMessage: viewModel.errorMessage,
            emptyTitle: "目前沒有公告",
            searchText: viewModel.searchText,
            hasSearchResults: !viewModel.filteredDiscussions.isEmpty,
            emptyIcon: "megaphone"
        ) {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.filteredDiscussions) { discussion in
                    NavigationLink(destination: MoodleForumView(discussion: discussion, repository: postsRepository)) {
                        MoodleDiscussionRow(discussion: discussion, messagePreview: viewModel.messagePreviews[discussion.id])
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.medium)
        } retry: {
            await viewModel.loadComplete(courseId: courseId, force: true)
        }
        .navigationTitle("公告")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "搜尋公告")
        .task { await viewModel.loadComplete(courseId: courseId) }
    }
}

@MainActor
final class MoodleAssignmentsListViewModel: ObservableObject {
    @Published private(set) var assignments: [MoodleAssignment] = [] {
        didSet {
            introPreviews = [:]
            searchIndex = MoodleSearchIndex(assignments) { assignment in
                let intro = MoodleSearch.plainText(assignment.intro)
                introPreviews[assignment.id] = intro
                return [MoodleSearch.plainText(assignment.name), intro]
            }
            updateSearch()
        }
    }
    @Published var searchText = "" { didSet { updateSearch() } }
    @Published private(set) var filteredAssignments: [MoodleAssignment] = []
    private var searchIndex = MoodleSearchIndex()
    private(set) var introPreviews: [Int: String] = [:]

    private func updateSearch() {
        filteredAssignments = searchIndex.filter(assignments, query: searchText)
    }
    @Published private(set) var submittedStatus: [Int: Bool] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repository: any MoodleAssignmentsRepositoryProtocol
    private(set) var hasLoaded = false
    private let loads = MoodleCourseLoadCoordinator()
    private var loadGeneration = 0
    private var submissionRevision = 0
    private var localStatusUpdates: [Int: (revision: Int, submitted: Bool)] = [:]
    private(set) var sortOrder = MoodleAssignmentSortOrder.defaultOrder

    init(repository: (any MoodleAssignmentsRepositoryProtocol)? = nil) {
        self.repository = repository ?? MoodleAssignmentsRepository()
    }

    func updateSubmission(assignmentID: Int, submitted: Bool) {
        submissionRevision &+= 1
        localStatusUpdates[assignmentID] = (submissionRevision, submitted)
        submittedStatus[assignmentID] = submitted
    }

    func setSortOrder(_ order: MoodleAssignmentSortOrder) {
        guard sortOrder != order else { return }
        sortOrder = order
        assignments = order.sorted(assignments)
    }

    func load(courseId: Int, force: Bool = false) async {
        await loads.run(force: force) { [self] in
            await performLoad(courseId: courseId, force: force)
        }
    }

    private func performLoad(courseId: Int, force: Bool) async {
        guard force || !hasLoaded else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { isLoading = false } }
        isLoading = true
        errorMessage = nil
        do {
            let startingSubmissionRevision = submissionRevision
            let snapshot = try await repository.fetchAssignments(courseId: courseId)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            assignments = sortOrder.sorted(snapshot.assignments)
            var statuses = snapshot.submittedStatus
            localStatusUpdates = localStatusUpdates.filter { $0.value.revision > startingSubmissionRevision }
            for (id, update) in localStatusUpdates { statuses[id] = update.submitted }
            submittedStatus = statuses
            hasLoaded = true
        } catch {
            guard generation == loadGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct MoodleCourseAssignmentsView: View {
    let courseId: Int
    @ObservedObject var viewModel: MoodleAssignmentsListViewModel
    @AppStorage(MoodleAssignmentSortOrder.storageKey)
    private var sortOrder = MoodleAssignmentSortOrder.defaultOrder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let submissionRepository: (any MoodleSubmissionRepositoryProtocol)?

    init(courseId: Int, viewModel: MoodleAssignmentsListViewModel,
         submissionRepository: (any MoodleSubmissionRepositoryProtocol)? = nil) {
        self.submissionRepository = submissionRepository
        self.courseId = courseId
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Menu {
                    Picker("排序", selection: $sortOrder) {
                        ForEach(MoodleAssignmentSortOrder.allCases, id: \.self) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                        .font(.body)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("排序，\(sortOrder.title)")
            }
            .padding(.horizontal, Theme.Spacing.medium)

            assignmentsContent
        }
        .background(Color(.systemGroupedBackground))
        .onChange(of: sortOrder) { _, order in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                viewModel.setSortOrder(order)
            }
        }
        .navigationTitle("作業")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "搜尋作業")
        .task {
            viewModel.setSortOrder(sortOrder)
            await viewModel.load(courseId: courseId)
        }
    }

    private var assignmentsContent: some View {
        MoodleCourseTabContainer(
            isLoading: viewModel.isLoading,
            isEmpty: viewModel.assignments.isEmpty,
            errorMessage: viewModel.errorMessage,
            emptyTitle: "目前沒有作業",
            searchText: viewModel.searchText,
            hasSearchResults: !viewModel.filteredAssignments.isEmpty,
            emptyIcon: "checklist"
        ) {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.filteredAssignments) { assignment in
                    NavigationLink {
                        MoodleAssignmentView(assignment: assignment, repository: submissionRepository) { submitted in
                            viewModel.updateSubmission(assignmentID: assignment.id, submitted: submitted)
                        }
                    } label: {
                        MoodleAssignmentRow(
                            assignment: assignment,
                            introPreview: viewModel.introPreviews[assignment.id] ?? "",
                            isSubmitted: viewModel.submittedStatus[assignment.id] ?? false
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.medium)
        } retry: {
            await viewModel.load(courseId: courseId, force: true)
        }
    }
}

@MainActor
final class MoodleGradesViewModel: ObservableObject {
    @Published private(set) var items: [MoodleGradeItem] = [] {
        didSet {
            itemTitles = [:]
            searchIndex = MoodleSearchIndex(items) { item in
                let title = MoodleSearch.plainText(item.itemname ?? (item.itemtype == "course" ? "課程總分" : "分類"))
                itemTitles[item.id] = title
                return [title]
            }
            updateSearch()
        }
    }
    @Published var searchText = "" { didSet { updateSearch() } }
    @Published private(set) var filteredItems: [MoodleGradeItem] = []
    private var searchIndex = MoodleSearchIndex()
    private(set) var itemTitles: [Int: String] = [:]

    private func updateSearch() {
        filteredItems = searchIndex.filter(items, query: searchText)
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repository: any MoodleGradesRepositoryProtocol
    private(set) var hasLoaded = false
    private let loads = MoodleCourseLoadCoordinator()
    private var loadGeneration = 0

    init(repository: (any MoodleGradesRepositoryProtocol)? = nil) {
        self.repository = repository ?? MoodleGradesRepository()
    }

    func load(courseId: Int, force: Bool = false) async {
        await loads.run(force: force) { [self] in
            await performLoad(courseId: courseId, force: force)
        }
    }

    private func performLoad(courseId: Int, force: Bool) async {
        guard force || !hasLoaded else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { isLoading = false } }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await repository.fetchGrades(courseId: courseId)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            items = result
            hasLoaded = true
        } catch {
            guard generation == loadGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct MoodleCourseGradesView: View {
    let courseId: Int
    @ObservedObject var viewModel: MoodleGradesViewModel

    init(courseId: Int, viewModel: MoodleGradesViewModel) {
        self.courseId = courseId
        self.viewModel = viewModel
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                MoodleCourseTabErrorView(message: error) {
                    await viewModel.load(courseId: courseId, force: true)
                }
            } else if viewModel.items.isEmpty {
                ScrollView {
                    if !MoodleSearch.trimmed(viewModel.searchText).isEmpty {
                        MoodleSearchEmptyView(searchText: viewModel.searchText)
                    } else {
                        ContentUnavailableView {
                            Label("目前沒有成績資料", systemImage: "chart.bar")
                        } actions: {
                            Button("重新整理") {
                                Task { await viewModel.load(courseId: courseId, force: true) }
                            }
                        }
                        .frame(minHeight: 420)
                    }
                }
                .refreshable { await viewModel.load(courseId: courseId, force: true) }
            } else {
                VStack(spacing: 0) {
                    if let error = viewModel.errorMessage {
                        Label("更新失敗，以下為上次資料：\(error)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    if !MoodleSearch.trimmed(viewModel.searchText).isEmpty && viewModel.filteredItems.isEmpty {
                        ScrollView { MoodleSearchEmptyView(searchText: viewModel.searchText) }
                    } else {
                        MoodleGradeView(items: viewModel.filteredItems)
                    }
                }
                .refreshable { await viewModel.load(courseId: courseId, force: true) }
            }
        }
        .navigationTitle("成績")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "搜尋成績")
        .task { await viewModel.load(courseId: courseId) }
    }
}

struct MoodleDiscussionRow: View {
    let discussion: MoodleDiscussion
    var messagePreview: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(discussion.subject)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(messagePreview ?? discussion.plainMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Text(discussion.userfullname)
                Spacer()
                Text(MoodlePresentation.relativeTime(discussion.timeModifiedDate))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MoodleAssignmentRow: View {
    let assignment: MoodleAssignment
    let introPreview: String
    let isSubmitted: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top))
            layout {
                Text(assignment.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statusBadge
            }
            if !introPreview.isEmpty {
                Text(introPreview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let due = assignment.dueDateValue {
                Label("截止：\(MoodlePresentation.dateTime(due))", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(assignment.isOverdue ? .red : .secondary)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isSubmitted {
            Text("已繳交")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12), in: Capsule())
        } else if assignment.isOverdue {
            Text("已截止")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.1), in: Capsule())
        }
    }
}

private struct MoodleCourseTabContainer<Content: View>: View {
    let isLoading: Bool
    let isEmpty: Bool
    let errorMessage: String?
    let emptyTitle: String
    let emptyIcon: String
    let searchText: String
    let hasSearchResults: Bool
    let content: Content
    let retry: () async -> Void

    init(
        isLoading: Bool,
        isEmpty: Bool,
        errorMessage: String?,
        emptyTitle: String,
        searchText: String = "",
        hasSearchResults: Bool = true,
        emptyIcon: String,
        @ViewBuilder content: () -> Content,
        retry: @escaping () async -> Void
    ) {
        self.isLoading = isLoading
        self.isEmpty = isEmpty
        self.errorMessage = errorMessage
        self.searchText = searchText
        self.hasSearchResults = hasSearchResults
        self.emptyTitle = emptyTitle
        self.emptyIcon = emptyIcon
        self.content = content()
        self.retry = retry
    }

    var body: some View {
        Group {
            if isLoading && isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, isEmpty {
                MoodleCourseTabErrorView(message: errorMessage, retry: retry)
            } else if isEmpty {
                ScrollView {
                    Group {
                        if MoodleSearch.trimmed(searchText).isEmpty {
                            ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
                        } else {
                            MoodleSearchEmptyView(searchText: searchText)
                        }
                    }
                    .frame(minHeight: 420)
                }
                .refreshable { await retry() }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        if let errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("更新失敗，以下為上次資料：\(errorMessage)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Spacer()
                            }
                            .padding(10)
                        }
                        if !MoodleSearch.trimmed(searchText).isEmpty && !hasSearchResults {
                            MoodleSearchEmptyView(searchText: searchText)
                        } else {
                            content
                        }
                    }
                }
                    .refreshable { await retry() }
            }
        }
        .background(Color(.systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct MoodleCourseTabErrorView: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("載入失敗", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重試") { Task { await retry() } }
        }
    }
}

/// Explicit Traditional Chinese copy, independent of the device's system language.
struct MoodleSearchEmptyView: View {
    let searchText: String

    var body: some View {
        ContentUnavailableView {
            Label("找不到符合的結果", systemImage: "magnifyingglass")
        } description: {
            Text("找不到符合「\(MoodleSearch.trimmed(searchText))」的項目，請試試其他關鍵字。")
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}
