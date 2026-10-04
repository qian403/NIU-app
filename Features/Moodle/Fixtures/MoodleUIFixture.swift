#if DEBUG
import SwiftUI

/// In-memory, synthetic data only. No service singleton, credentials or remote URLs.
@MainActor
final class MoodleUIFixtureRepository: MoodleCourseRepositoryProtocol,
    MoodleAnnouncementsRepositoryProtocol, MoodleAssignmentsRepositoryProtocol,
    MoodleResourcesRepositoryProtocol, MoodleAttendanceRepositoryProtocol,
    MoodleGradesRepositoryProtocol, MoodleSubmissionRepositoryProtocol,
    MoodleDiscussionPostsRepositoryProtocol {
    var isAuthenticated: Bool { true }
    let availableSemesters = ["115-1", "114-2", "113-2"]
    var failsAnnouncements = false
    private var failsNextLoad: Bool
    private let now = Int(Date().timeIntervalSince1970)
    private var submitted = Set([1])

    init(failsNextLoad: Bool = false) { self.failsNextLoad = failsNextLoad }

    func authenticate(username: String, password: String) async throws { try Task.checkCancellation() }

    var courses: [MoodleCourse] {
        ["1151", "1142"].enumerated().flatMap { semesterIndex, semester in
            ["跨領域人工智慧與永續智慧城市系統設計實務專題", "資料結構", "行動應用程式設計", "資料庫系統", "資訊安全導論"].enumerated().map { index, name in
                MoodleCourse(id: semesterIndex * 10 + index + 1, shortname: name,
                    fullname: name, displayname: name, enrolledusercount: 35,
                    idnumber: "\(semester)_CS\(index + 1)", visible: 1,
                    summary: "開課教師：測試教師\(index + 1); 學分數：3;", format: "topics",
                    courseimage: nil, showgrades: true, progress: index == 0 ? 45 : nil,
                    completed: false, startdate: now - 86400 * 30, enddate: now + 86400 * 90,
                    lastaccess: now - index * 100, isfavourite: false, hidden: false)
            }
        }
    }

    func fetchCourses() async throws -> [MoodleCourse] {
        try Task.checkCancellation()
        if failsNextLoad {
            failsNextLoad = false
            throw FixtureError.unavailable
        }
        return courses
    }

    func fetchAnnouncements(courseId: Int) async throws -> [MoodleDiscussion] {
        try Task.checkCancellation()
        if failsAnnouncements { failsAnnouncements = false; throw FixtureError.unavailable }
        return [
            MoodleDiscussion(id: 1, name: "課程公告", subject: "本週課程安排與分組專題繳交說明",
                message: "各位同學好：本週將進行專題討論，請攜帶初步設計。這是離線合成資料，沒有真實學生資訊。",
                timemodified: now, userfullname: "測試教師", created: now - 86400, numreplies: 1, pinned: true),
            MoodleDiscussion(id: 2, name: "上課提醒", subject: "教材與參考資料已更新",
                message: "請於上課前閱讀第一章，並準備一個想在課堂討論的問題。",
                timemodified: now - 86400 * 2, userfullname: "測試助教", created: now - 86400 * 2,
                numreplies: 0, pinned: false),
            MoodleDiscussion(id: 3, name: "設計討論", subject: "設計研究討論時間",
                message: "請準備設計草圖。", timemodified: now - 86400 * 3,
                userfullname: "測試教師", created: now - 86400 * 3, numreplies: 0, pinned: false),
            MoodleDiscussion(id: 4, name: "設計參考", subject: "設計參考範例",
                message: "參考資料已更新。", timemodified: now - 86400 * 4,
                userfullname: "測試助教", created: now - 86400 * 4, numreplies: 0, pinned: false),
            MoodleDiscussion(id: 5, name: "設計提醒", subject: "設計專題分組提醒",
                message: "請完成分組。", timemodified: now - 86400 * 5,
                userfullname: "測試教師", created: now - 86400 * 5, numreplies: 0, pinned: false)
        ]
    }
    func fetchCompleteAnnouncements(courseId: Int, cached: [MoodleDiscussion]) async throws -> [MoodleDiscussion] {
        try Task.checkCancellation()
        return cached
    }
    func fetchDiscussions(forumId: Int) async throws -> MoodleDiscussionsResponse {
        MoodleDiscussionsResponse(discussions: try await fetchAnnouncements(courseId: forumId))
    }
    func fetchPosts(discussionId: Int) async throws -> [MoodlePost] {
        try Task.checkCancellation()
        return [MoodlePost(id: 10, subject: "補充說明", message: "課堂將保留時間回答問題。",
            author: MoodlePostAuthor(id: 1, fullname: "測試助教"), timecreated: now)]
    }

    func assignments(courseId: Int) -> [MoodleAssignment] {
        ["第一週練習：問題分析與設計", "期中專題計畫書與系統架構說明", "課堂練習補交", "自主學習心得（無截止日）", "期末設計成果"].enumerated().map { index, name in
            MoodleAssignment(id: index + 1, cmid: index + 101, course: courseId,
                name: name, intro: "請以自己的文字整理學習重點，附上設計過程與參考來源。此作業僅供離線畫面測試。",
                duedate: index == 3 ? 0 : now + (index == 2 ? -86400 : (index + 1) * 86400),
                allowsubmissionsfromdate: now - 86400 * 7, grade: 100, timemodified: now)
        }
    }
    func fetchAssignments(courseId: Int) async throws -> MoodleAssignmentsSnapshot {
        try Task.checkCancellation()
        let items = assignments(courseId: courseId)
        return MoodleAssignmentsSnapshot(assignments: items,
            submittedStatus: Dictionary(uniqueKeysWithValues: items.map { ($0.id, submitted.contains($0.id)) }))
    }
    func findAssignment(courseId: Int, module: MoodleModule) async throws -> MoodleAssignment? {
        try Task.checkCancellation()
        return assignments(courseId: courseId).first { $0.cmid == module.id }
    }
    func fetchStatus(assignment: MoodleAssignment) async throws -> MoodleSubmissionStatus {
        try Task.checkCancellation()
        return MoodleSubmissionStatus(lastattempt: MoodleLastAttempt(
            submission: MoodleSubmission(id: assignment.id, status: submitted.contains(assignment.id) ? "submitted" : "new",
                timemodified: now, plugins: []), graded: submitted.contains(assignment.id)))
    }
    func clear(assignment: MoodleAssignment) async throws { try Task.checkCancellation(); submitted.remove(assignment.id) }
    func submit(assignment: MoodleAssignment) async throws { try Task.checkCancellation(); submitted.insert(assignment.id) }
    func upload(assignment: MoodleAssignment, localFileURL: URL) async throws { try Task.checkCancellation() }
    func webSubmissionURL(for assignment: MoodleAssignment) -> String? { nil }
    func fileURL(for rawURL: String) -> URL? { nil }
    func authenticatedFileURL(for rawURL: String) -> URL? { nil }

    func fetchSections(courseId: Int) async throws -> [MoodleCourseSection] {
        try Task.checkCancellation()
        return (1...3).map { index in
            MoodleCourseSection(id: index, name: "第 \(index) 週：\(["課程導覽", "基礎概念", "應用實作"][index - 1])",
                visible: 1, summary: "本週學習重點", modules: [
                    MoodleModule(id: index, name: "第 \(index) 週設計教材與延伸閱讀", instance: index,
                        modname: "page", modplural: nil, url: "fixture://page/\(index)", visible: 1,
                        uservisible: true, availabilityinfo: nil, description: "離線教材", contents: nil)
                ])
        }
    }
    func fetchPages(courseId: Int) async throws -> [MoodlePage] {
        try Task.checkCancellation()
        return (1...3).map { MoodlePage(id: $0, coursemodule: $0, name: "第 \($0) 週教材", intro: nil,
            content: "本章介紹課程核心概念。\n請閱讀教材並完成課堂練習。\n所有內容都是合成資料。") }
    }
    func fetchCourseAttendance(courseId: Int) async throws -> [MoodleAttendanceSection] {
        try Task.checkCancellation()
        let records = (0..<5).map { index in
            MoodleAttendanceRecord(id: index, date: Date(timeIntervalSince1970: TimeInterval(now - index * 86400 * 7)),
                timeText: "09:10–12:00", description: "第 \(5 - index) 週設計課程", statusLabel: index == 1 ? "缺席" : "出席",
                scoreText: index == 1 ? "0 / 2" : "2 / 2", remarks: nil, status: index == 1 ? .absent : .present)
        }
        return [MoodleAttendanceSection(id: 1, sectionName: "本學期", moduleName: "課堂出缺席紀錄",
            records: records, total: 5, source: .webService)]
    }
    func fetchAttendance(module: MoodleModule, sectionName: String, attendanceId: Int?, courseModuleId: Int?) async throws -> MoodleAttendanceSection {
        let sections = try await fetchCourseAttendance(courseId: 1)
        guard let section = sections.first else { throw FixtureError.unavailable }
        return section
    }
    func fetchGrades(courseId: Int) async throws -> [MoodleGradeItem] {
        try Task.checkCancellation()
        return [MoodleGradeItem(id: 1, itemname: "第一週練習：問題分析與設計", itemtype: "mod", itemmodule: "assign",
            graderaw: 92, gradeformatted: "92.00", grademin: 0, grademax: 100, percentageformatted: "92%",
            feedback: "分析完整，請再補充測試案例。", weightformatted: "20%", contributiontocoursetotal: "18.4", rangeformatted: "0–100"),
            MoodleGradeItem(id: 2, itemname: "課程總分", itemtype: "course", itemmodule: nil,
                graderaw: 92, gradeformatted: "92.00", grademin: 0, grademax: 100,
                percentageformatted: "92%", feedback: nil, weightformatted: nil,
                contributiontocoursetotal: nil, rangeformatted: "0–100")]
    }

    var details: MoodleDetailRepositories {
        MoodleDetailRepositories(announcements: self, assignments: self, resources: self,
            questions: MoodleUIFixtureQuestionsRepository(), attendance: self, grades: self, submission: self, posts: self)
    }
    enum FixtureError: Error { case unavailable }
}

@MainActor
private struct MoodleUIFixtureQuestionsRepository: MoodleQuestionsRepositoryProtocol {
    var sessionRevision: Int { 0 }
    func fetchSections(courseId: Int) async throws -> [MoodleQuestionSection] {
        try Task.checkCancellation()
        return [MoodleQuestionSection(id: 1, name: "設計問答", modules: [
            MoodleModule(id: 501, name: "設計基礎測驗", instance: 501, modname: "quiz",
                modplural: nil, url: nil, visible: 1, uservisible: false, availabilityinfo: nil,
                description: "離線合成問答活動", contents: nil)
        ])]
    }
}

/// Use the production repository for both calendar and fallback paths.
@MainActor
final class MoodleUIFixtureUpcomingClient: MoodleUpcomingAPIClientProtocol {
    let repository: MoodleUIFixtureRepository
    let calendarCapability = MoodleCalendarCapability()
    var sessionRevision: Int { 0 }
    let calendarUnavailable: Bool
    let empty: Bool
    var failNext: Bool
    private(set) var calendarCalls = 0
    private(set) var statusCalls = 0
    // A Monday at noon keeps today/tomorrow/this-week/next-week deterministic.
    static var referenceDate: Date { Date(timeIntervalSince1970: 1791172800) }
    init(repository: MoodleUIFixtureRepository, calendarUnavailable: Bool = false, empty: Bool = false, failNext: Bool = false) {
        self.repository = repository
        self.calendarUnavailable = calendarUnavailable
        self.empty = empty
        self.failNext = failNext
    }
    var assignments: [MoodleAssignment] {
        if empty { return [] }
        let start = MoodleUpcomingRules.calendar.startOfDay(for: Self.referenceDate)
        return [-2, 0, 1, 3, 5, 8, 10].enumerated().map { index, day in
            let due = start.addingTimeInterval(Double(day * 86400 + (index == 1 ? 23 * 3600 + 59 * 60 : 18 * 3600)))
            return MoodleAssignment(id: 800 + index, cmid: 1800 + index, course: index % 5 + 1,
                name: index == 3 ? "跨領域人工智慧與永續智慧城市系統設計實務：期中專題計畫書、系統架構與使用者研究成果報告" : ["課堂練習補交", "問題分析與設計", "資料結構練習", "專題計畫書", "資料庫設計", "行動應用程式實作", "資訊安全案例分析"][index],
                intro: "離線合成作業，可測試瀏覽與繳交後重新整理。", duedate: Int(due.timeIntervalSince1970),
                allowsubmissionsfromdate: Int(start.timeIntervalSince1970) - 7 * 86400, grade: 100,
                timemodified: Int(start.timeIntervalSince1970))
        }
    }
    private func check() throws {
        try Task.checkCancellation()
        if failNext { failNext = false; throw URLError(.notConnectedToInternet) }
    }
    func fetchActionEvents(from: Int, to: Int, after: Int, limit: Int) async throws -> MoodleCalendarActionEvents {
        try check()
        calendarCalls += 1
        if calendarUnavailable { throw MoodleUpcomingAPIError(exception: "webservice_access_exception", errorcode: "accessexception") }
        var events: [MoodleCalendarActionEvent] = []
        for assignment in assignments where assignment.id > after && (from...to).contains(assignment.duedate) {
            let status = try await repository.fetchStatus(assignment: assignment)
            if try MoodleUpcomingRules.isSubmitted(status) { continue }
            events.append(MoodleCalendarActionEvent(id: assignment.id, name: assignment.name, timesort: assignment.duedate,
                modulename: "assign", instance: assignment.id, course: .init(id: assignment.course),
                action: .init(actionable: true, url: nil), url: nil, eventtype: "due"))
        }
        let page = Array(events.prefix(limit))
        return MoodleCalendarActionEvents(events: page, lastid: page.last?.id)
    }
    func fetchUpcomingAssignments(courseIDs: [Int]) async throws -> [MoodleAssignment] {
        try check()
        return try assignmentResponse(courseIDs: courseIDs).assignments(courseIDs: courseIDs)
    }
    func fetchAssignments(courseId: Int) async throws -> [MoodleAssignment] {
        try check()
        return try assignmentResponse(courseIDs: [courseId]).assignments(courseIDs: [courseId])
    }
    // Model mod_assign_get_assignments including a harmless warning and empty courses.
    func assignmentResponse(courseIDs: [Int]) -> MoodleUpcomingAssignmentsResponse {
        MoodleUpcomingAssignmentsResponse(courses: courseIDs.map { id in
            MoodleAssignmentCourse(id: id, assignments: assignments.filter { $0.course == id })
        }, warnings: [.init(warningcode: "fixture_unrelated_permission")])
    }
    func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus {
        try check()
        statusCalls += 1
        guard let assignment = assignments.first(where: { $0.id == assignId }) else { throw MoodleUpcomingError.assignmentNotFound }
        return try await repository.fetchStatus(assignment: assignment)
    }
}

@MainActor
struct MoodleUIFixtureRoot: View {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-NIUMoodleUIFixture") || arguments.contains("-NIUMoodleUIFixtureScreen") || arguments.contains("-NIUMoodleUIFixtureCalendarUnavailable")
    }
    @State private var repository: MoodleUIFixtureRepository
    private let screen: String
    private let upcomingRepository: MoodleUpcomingRepository
    @StateObject private var upcoming: MoodleUpcomingViewModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "-NIUMoodleUIFixtureScreen")
        let screen = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "home"
        self.screen = screen
        let repository = MoodleUIFixtureRepository(failsNextLoad: screen == "error")
        repository.failsAnnouncements = screen == "course-partial-error"
        _repository = State(initialValue: repository)
        let client = MoodleUIFixtureUpcomingClient(repository: repository,
            calendarUnavailable: arguments.contains("-NIUMoodleUIFixtureCalendarUnavailable"),
            empty: screen == "home-upcoming-empty", failNext: screen == "home-upcoming-error")
        let upcomingRepository = MoodleUpcomingRepository(client: client)
        self.upcomingRepository = upcomingRepository
        _upcoming = StateObject(wrappedValue: MoodleUpcomingViewModel(repository: upcomingRepository,
            clock: { MoodleUIFixtureUpcomingClient.referenceDate }))
    }

    var body: some View {
        NavigationStack {
            // Render the requested screen on the first pass; do not push from a
            // home .task while NavigationStack is still mounting its root.
            if screen.hasPrefix("course"), let course = repository.courses.first {
                MoodleUIFixtureCourseRoot(course: course, repositories: repository.details, screen: screen)
            } else if screen == "assignment", let course = repository.courses.first,
                      let assignment = repository.assignments(courseId: course.id).first {
                MoodleAssignmentView(assignment: assignment, repository: repository)
            } else if screen == "upcoming" {
                MoodleUpcomingListView(model: upcoming, submissionRepository: repository)
                    .task { await upcoming.load(courses: repository.courses.filter { $0.semesterLabel == "115-1" }) }
            } else {
                MoodleView(repository: repository, detailRepositories: repository.details,
                           initialSemester: screen == "empty" ? "113-2" : nil,
                           upcomingRepository: upcomingRepository, clock: { MoodleUIFixtureUpcomingClient.referenceDate })
            }
        }
    }
}
@MainActor
private struct MoodleUIFixtureCourseRoot: View {
    let course: MoodleCourse
    let repositories: MoodleDetailRepositories
    let screen: String
    @StateObject private var model: MoodleCourseDetailViewModel
    init(course: MoodleCourse, repositories: MoodleDetailRepositories, screen: String) {
        self.course = course
        self.repositories = repositories
        self.screen = screen
        _model = StateObject(wrappedValue: MoodleCourseDetailViewModel(course: course, repositories: repositories,
            initialQuery: screen == "course-search" ? "設計" : ""))
    }
    var body: some View {
        switch screen {
        case "course-assignments": MoodleCoursePage(model: model, destination: .assignments)
        case "course-resources": MoodleCoursePage(model: model, destination: .resources)
        case "course-attendance": MoodleCoursePage(model: model, destination: .attendance)
        default:
            MoodleCourseDetailView(model: model)
        }
    }
}
#endif
