import Combine
import Foundation

/// A course owns the four overview models. Resources and questions are created
/// only on demand. The same instances follow navigation into their full pages.
@MainActor
final class MoodleCourseDetailViewModel: ObservableObject {
    enum Destination: String, CaseIterable, Identifiable {
        case assignments = "作業", announcements = "公告", resources = "資源"
        case questions = "問答", attendance = "出缺席", grades = "成績"
        var id: Self { self }
        var iconName: String {
            switch self {
            case .announcements: "megaphone"
            case .assignments: "checklist"
            case .questions: "questionmark.bubble"
            case .resources: "folder"
            case .attendance: "person.badge.clock"
            case .grades: "chart.bar"
            }
        }
    }

    struct SearchResult: Identifiable {
        let id: String
        let title: String
        let subtitle: String
    }
    struct SearchGroup: Identifiable {
        let destination: Destination
        let results: [SearchResult]
        var id: Destination { destination }
        var count: Int { results.count }
        var preview: [SearchResult] { Array(results.prefix(3)) }
    }

    let course: MoodleCourse
    let repositories: MoodleDetailRepositories
    let assignments: MoodleAssignmentsListViewModel
    let announcements: MoodleAnnouncementsViewModel
    let attendance: MoodleAttendanceViewModel
    let grades: MoodleGradesViewModel
    @Published private(set) var resources: MoodleResourcesViewModel?
    @Published private(set) var questions: MoodleQuestionsViewModel?
    private var observations = Set<AnyCancellable>()
    @Published var searchText: String { didSet { updateSearch() } }

    init(course: MoodleCourse, repositories: MoodleDetailRepositories, initialQuery: String = "") {
        self.course = course
        self.repositories = repositories
        self.searchText = initialQuery
        assignments = MoodleAssignmentsListViewModel(repository: repositories.assignments)
        announcements = MoodleAnnouncementsViewModel(repository: repositories.announcements)
        attendance = MoodleAttendanceViewModel(repository: repositories.attendance)
        grades = MoodleGradesViewModel(repository: repositories.grades)
        observe(assignments); observe(announcements); observe(attendance); observe(grades)
        updateSearch()
    }

    private func observe<Model: ObservableObject>(_ model: Model) where Model.ObjectWillChangePublisher == ObservableObjectPublisher {
        model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }

    func resourcesModel() -> MoodleResourcesViewModel {
        if let resources { return resources }
        let model = MoodleResourcesViewModel(repository: repositories.resources)
        resources = model
        model.searchText = searchText
        observe(model)
        return model
    }

    func questionsModel() -> MoodleQuestionsViewModel {
        if let questions { return questions }
        let model = MoodleQuestionsViewModel(repository: repositories.questions)
        questions = model
        model.searchText = searchText
        observe(model)
        return model
    }

    func preparePage(_ destination: Destination, query: String) {
        switch destination {
        case .assignments: assignments.searchText = query
        case .announcements: announcements.searchText = query
        case .resources: resourcesModel().searchText = query
        case .questions: questionsModel().searchText = query
        case .attendance: attendance.searchText = query
        case .grades: grades.searchText = query
        }
    }

    /// A child edits only its own query. Restore the overview query on return.
    func updateSearch() {
        assignments.searchText = searchText
        announcements.searchText = searchText
        attendance.searchText = searchText
        grades.searchText = searchText
        resources?.searchText = searchText
        questions?.searchText = searchText
    }

    func loadOverview(force: Bool = false) async {
        async let a: Void = assignments.load(courseId: course.id, force: force)
        async let b: Void = announcements.load(courseId: course.id, force: force)
        async let c: Void = attendance.loadCourse(course.id, force: force)
        async let d: Void = grades.load(courseId: course.id, force: force)
        _ = await (a, b, c, d)
    }

    func loadSearchExtras(force: Bool = false) async {
        guard !MoodleSearch.trimmed(searchText).isEmpty, !Task.isCancelled else { return }
        let resources = resourcesModel()
        let questions = questionsModel()
        async let a: Void = resources.load(courseId: course.id, force: force)
        async let b: Void = questions.load(courseId: course.id, force: force)
        async let c: Void = announcements.loadComplete(courseId: course.id)
        _ = await (a, b, c)
    }

    func refresh() async {
        await loadOverview(force: true)
        await loadSearchExtras(force: true)
    }

    func retry(_ destination: Destination) async {
        switch destination {
        case .assignments: await assignments.load(courseId: course.id, force: true)
        case .announcements:
            if MoodleSearch.trimmed(searchText).isEmpty {
                await announcements.load(courseId: course.id, force: true)
            } else {
                await announcements.loadComplete(courseId: course.id, force: true)
            }
        case .resources: await resourcesModel().load(courseId: course.id, force: true)
        case .questions: await questionsModel().load(courseId: course.id, force: true)
        case .attendance: await attendance.loadCourse(course.id, force: true)
        case .grades: await grades.load(courseId: course.id, force: true)
        }
    }

    var pendingAssignments: [MoodleAssignment] {
        MoodleAssignmentSortOrder.dueSoonestFirst.sorted(
            assignments.assignments.filter { assignments.submittedStatus[$0.id] == false })
    }
    var pendingPreview: [MoodleAssignment] { Array(pendingAssignments.prefix(3)) }
    var unknownSubmissionCount: Int {
        assignments.assignments.filter { assignments.submittedStatus[$0.id] == nil }.count
    }
    var pendingEmptyMessage: String {
        unknownSubmissionCount > 0
            ? "\(unknownSubmissionCount) 份作業狀態未知，請到作業頁確認" : "沒有待繳作業"
    }
    var nextAssignment: MoodleAssignment? { nextAssignment(now: Date()) }
    func nextAssignment(now: Date) -> MoodleAssignment? {
        pendingAssignments.first { assignment in
            guard let due = assignment.dueDateValue else { return true }
            return due >= MoodleUpcomingRules.window(now: now).lowerBound
        }
    }
    var latestAnnouncements: [MoodleDiscussion] {
        Array(announcements.discussions.sorted {
            $0.timemodified == $1.timemodified ? $0.id < $1.id : $0.timemodified > $1.timemodified
        }.prefix(3))
    }
    var attendancePercent: Int? {
        let resolved = attendance.sections.reduce(0) { $0 + $1.resolvedCount }
        guard attendance.hasLoaded, resolved > 0 else { return nil }
        let present = attendance.sections.reduce(0) { $0 + $1.presentCount }
        return Int((Double(present) / Double(resolved) * 100).rounded())
    }
    var currentGrade: String? {
        MoodlePresentation.assignmentGrade(grades.items.first { $0.itemtype == "course" })
    }
    func nextDeadline(now: Date) -> String {
        guard assignments.hasLoaded else { return "載入中…" }
        guard let nextAssignment = nextAssignment(now: now) else {
            return unknownSubmissionCount > 0 ? "狀態未知" : "無待繳"
        }
        guard let due = nextAssignment.dueDateValue else { return "未設定截止日" }
        let text = MoodlePresentation.upcomingDeadline(due, now: now)
        return due < now ? text : "\(text) 截止"
    }

    func hasLoaded(_ destination: Destination) -> Bool {
        switch destination {
        case .assignments: assignments.hasLoaded
        case .announcements: announcements.hasLoaded
        case .resources: resources?.hasLoaded ?? false
        case .questions: questions?.hasLoaded ?? false
        case .attendance: attendance.hasLoaded
        case .grades: grades.hasLoaded
        }
    }
    func isLoading(_ destination: Destination) -> Bool {
        switch destination {
        case .assignments: assignments.isLoading
        case .announcements: announcements.isLoading
        case .resources: resources?.isLoading ?? false
        case .questions: questions?.isLoading ?? false
        case .attendance:
            if case .loading = attendance.state { true } else { false }
        case .grades: grades.isLoading
        }
    }
    func error(_ destination: Destination) -> String? {
        switch destination {
        case .assignments: assignments.errorMessage
        case .announcements: announcements.errorMessage
        case .resources: resources?.errorMessage
        case .questions: questions?.errorMessage
        case .attendance: attendance.lastErrorMessage
        case .grades: grades.errorMessage
        }
    }
    func detail(_ destination: Destination) -> String? {
        guard hasLoaded(destination) else { return nil }
        switch destination {
        case .assignments:
            if unknownSubmissionCount > 0 {
                return pendingAssignments.isEmpty
                    ? "\(unknownSubmissionCount) 份狀態未知"
                    : "\(pendingAssignments.count) 份待繳、\(unknownSubmissionCount) 份狀態未知"
            }
            return "\(pendingAssignments.count) 份待繳"
        case .announcements: return announcements.hasLoadedAll ? "\(announcements.discussions.count) 則公告" : nil
        case .resources: return "\(resources?.sections.flatMap(\.modules).count ?? 0) 個項目"
        case .questions: return "\(questions?.sections.flatMap(\.modules).count ?? 0) 個活動"
        case .attendance: return attendancePercent.map { "出席 \($0)%" }
        case .grades: return currentGrade.map { "目前成績 \($0)" }
        }
    }

    var searchGroups: [SearchGroup] {
        Destination.allCases.map { destination in
            let results: [SearchResult]
            switch destination {
            case .assignments:
                results = assignments.filteredAssignments.map {
                    SearchResult(id: String($0.id), title: $0.name,
                        subtitle: $0.dueDateValue.map { "截止：\(MoodlePresentation.dateTime($0))" } ?? "未設定截止日")
                }
            case .announcements:
                results = announcements.filteredDiscussions.map {
                    SearchResult(id: String($0.id), title: $0.subject,
                        subtitle: "\($0.userfullname)・\(MoodlePresentation.relativeTime($0.timeModifiedDate))")
                }
            case .resources:
                results = (resources?.filteredSections ?? []).flatMap { section in
                    section.modules.map { SearchResult(id: "\(section.id)-\($0.id)", title: $0.name, subtitle: section.name) }
                }
            case .questions:
                results = (questions?.filteredSections ?? []).flatMap { section in
                    section.modules.map { SearchResult(id: "\(section.id)-\($0.id)", title: $0.name, subtitle: section.name) }
                }
            case .attendance:
                results = attendance.filteredSections.flatMap { section in
                    section.records.map { SearchResult(id: "\(section.id)-\($0.id)", title: $0.description ?? "課堂點名",
                        subtitle: "\(MoodlePresentation.fullDate($0.date))・\($0.statusLabel)") }
                }
            case .grades:
                results = grades.filteredItems.map {
                    SearchResult(id: String($0.id), title: grades.itemTitles[$0.id] ?? "成績",
                        subtitle: MoodlePresentation.assignmentGrade($0) ?? "尚未評分")
                }
            }
            return SearchGroup(destination: destination, results: results)
        }
    }
    func hasSearchLoaded(_ destination: Destination) -> Bool {
        destination == .announcements ? announcements.hasLoadedAll : hasLoaded(destination)
    }
    var searchComplete: Bool {
        announcements.hasLoadedAll && Destination.allCases.allSatisfy { hasLoaded($0) && !isLoading($0) && error($0) == nil }
    }
}
