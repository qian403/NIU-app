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
    private var hasLoaded = false

    init(repository: (any MoodleAnnouncementsRepositoryProtocol)? = nil) {
        self.repository = repository ?? MoodleAnnouncementsRepository()
    }

    func load(courseId: Int, force: Bool = false) async {
        guard force || !hasLoaded else { return }
        isLoading = true
        errorMessage = nil
        do {
            discussions = try await repository.fetchAnnouncements(courseId: courseId)
            hasLoaded = true
        } catch is CancellationError {
            isLoading = false
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct MoodleCourseAnnouncementsView: View {
    let courseId: Int
    @ObservedObject var viewModel: MoodleAnnouncementsViewModel

    init(courseId: Int, viewModel: MoodleAnnouncementsViewModel) {
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
                    NavigationLink(destination: MoodleForumView(discussion: discussion)) {
                        MoodleDiscussionRow(discussion: discussion, messagePreview: viewModel.messagePreviews[discussion.id])
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.medium)
        } retry: {
            await viewModel.load(courseId: courseId, force: true)
        }
        .task { await viewModel.load(courseId: courseId) }
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
    private var hasLoaded = false
    private(set) var sortOrder = MoodleAssignmentSortOrder.defaultOrder

    init(repository: (any MoodleAssignmentsRepositoryProtocol)? = nil) {
        self.repository = repository ?? MoodleAssignmentsRepository()
    }

    func setSortOrder(_ order: MoodleAssignmentSortOrder) {
        guard sortOrder != order else { return }
        sortOrder = order
        assignments = order.sorted(assignments)
    }

    func load(courseId: Int, force: Bool = false) async {
        guard force || !hasLoaded else { return }
        isLoading = true
        errorMessage = nil
        do {
            let snapshot = try await repository.fetchAssignments(courseId: courseId)
            assignments = sortOrder.sorted(snapshot.assignments)
            submittedStatus = snapshot.submittedStatus
            hasLoaded = true
        } catch is CancellationError {
            isLoading = false
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct MoodleCourseAssignmentsView: View {
    let courseId: Int
    @ObservedObject var viewModel: MoodleAssignmentsListViewModel
    @AppStorage(MoodleAssignmentSortOrder.storageKey)
    private var sortOrder = MoodleAssignmentSortOrder.defaultOrder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(courseId: Int, viewModel: MoodleAssignmentsListViewModel) {
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
                    NavigationLink(destination: MoodleAssignmentView(assignment: assignment)) {
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
            searchIndex = MoodleSearchIndex(items) { item in
                [MoodleSearch.plainText(item.itemname ?? (item.itemtype == "course" ? "課程總分" : "分類"))]
            }
            updateSearch()
        }
    }
    @Published var searchText = "" { didSet { updateSearch() } }
    @Published private(set) var filteredItems: [MoodleGradeItem] = []
    private var searchIndex = MoodleSearchIndex()

    private func updateSearch() {
        filteredItems = searchIndex.filter(items, query: searchText)
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repository: any MoodleGradesRepositoryProtocol
    private var hasLoaded = false

    init(repository: (any MoodleGradesRepositoryProtocol)? = nil) {
        self.repository = repository ?? MoodleGradesRepository()
    }

    func load(courseId: Int, force: Bool = false) async {
        guard force || !hasLoaded else { return }
        isLoading = true
        errorMessage = nil
        do {
            items = try await repository.fetchGrades(courseId: courseId)
            hasLoaded = true
        } catch is CancellationError {
            isLoading = false
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
                            .font(.system(size: 11))
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
        .task { await viewModel.load(courseId: courseId) }
    }
}

struct MoodleDiscussionRow: View {
    let discussion: MoodleDiscussion
    var messagePreview: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(discussion.subject)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(messagePreview ?? discussion.plainMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Text(discussion.userfullname)
                Spacer()
                Text(discussion.timeModifiedDate, style: .relative)
            }
            .font(.system(size: 11))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(assignment.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
                statusBadge
            }
            if !introPreview.isEmpty {
                Text(introPreview)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let due = assignment.dueDateValue {
                Label("截止：\(due.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    .font(.system(size: 12))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12), in: Capsule())
        } else if assignment.isOverdue {
            Text("已截止")
                .font(.system(size: 11, weight: .semibold))
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
                                    .font(.system(size: 11))
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
