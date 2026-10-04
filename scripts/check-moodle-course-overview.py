#!/usr/bin/env python3
"""Execute production overview, six models and DEBUG fixtures entirely offline."""
import ast
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'Features/Moodle'
# Reuse the small repository doubles, never execute the other test on import.
tree = ast.parse((ROOT / 'scripts/check-moodle-search.py').read_text())
search_checks = next(ast.literal_eval(node.value) for node in tree.body
                     if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'CHECKS' for t in node.targets))
stubs = search_checks.split('@main struct Checks')[0]

def model(path, name):
    source = (BASE / path).read_text()
    start = source.index('@MainActor\nfinal class ' + name)
    end = source.find('\nstruct ', start)
    return source[start:end] if end >= 0 else source[start:]

models = '\n'.join(model(path, name) for path, name in [
    ('CourseDetail/MoodleCourseTabViews.swift', 'MoodleAnnouncementsViewModel'),
    ('CourseDetail/MoodleCourseTabViews.swift', 'MoodleAssignmentsListViewModel'),
    ('CourseDetail/MoodleCourseTabViews.swift', 'MoodleGradesViewModel'),
    ('CourseDetail/MoodleCourseResourcesView.swift', 'MoodleResourcesViewModel'),
    ('Attendance/MoodleAttendanceViewModel.swift', 'MoodleAttendanceViewModel'),
    ('Questions/MoodleQuestionsViewModel.swift', 'MoodleQuestionsViewModel'),
])
repositories = (BASE / 'Repositories/MoodleRepositories.swift').read_text()
container = repositories[repositories.index('@MainActor\nstruct MoodleDetailRepositories'):repositories.index('    static var live:')] + '}\n'
fixture = (BASE / 'Fixtures/MoodleUIFixture.swift').read_text().split('/// Use the production repository')[0].replace('import SwiftUI', 'import Combine') + '\n#endif\n'
assignment_protocol = re.search(r'@MainActor\nprotocol MoodleAssignmentAPIClientProtocol.*?\n\}', repositories, re.S)[0]
assignment_repository = repositories[repositories.index('@MainActor\nstruct MoodleAssignmentsRepository:'):repositories.index('@MainActor\nprotocol MoodleResourcesRepositoryProtocol')].replace('struct MoodleAssignmentsRepository:', 'struct ProductionAssignmentsRepository:')
forum_protocol = re.search(r'@MainActor\nprotocol MoodleForumAPIClientProtocol.*?\n\}', repositories, re.S)[0]
forum_repository = repositories[repositories.index('@MainActor\nfinal class MoodleAnnouncementsRepository:'):repositories.index('struct MoodleAssignmentsSnapshot')].replace('class MoodleAnnouncementsRepository:', 'class ProductionAnnouncementsRepository:')
checks = r'''
@MainActor final class ForumClient: MoodleForumAPIClientProtocol {
    var sessionRevision = 0
    var calls: [Int] = []
    var repeatPage = false
    var failPage: Int?
    var hiddenIDs = Set<Int>()
    var total = 25
    var unknownWarning = false
    var forumCalls = 0
    func fetchForumsByCourse(courseId: Int) async throws -> [MoodleForum] {
        forumCalls += 1
        return [.init(id: 1, course: courseId, name: "公告", type: "news", intro: "")]
    }
    func fetchForumDiscussions(forumId: Int) async throws -> MoodleDiscussionsResponse {
        try await fetchForumDiscussions(forumId: forumId, page: 0)
    }
    func fetchForumDiscussions(forumId: Int, page: Int) async throws -> MoodleDiscussionsResponse {
        calls.append(page)
        if page == failPage { throw URLError(.timedOut) }
        let page = repeatPage ? 0 : page
        let range = min(page * 20, total)..<min((page + 1) * 20, total)
        let warnings: [MoodleDiscussionsResponse.Warning] = unknownWarning
            ? [.init(item: "forum", itemid: 1, warningcode: "unknown")]
            : range.filter { hiddenIDs.contains($0) }.map { .init(item: "post", itemid: $0, warningcode: "1") }
        return .init(discussions: range.filter { !hiddenIDs.contains($0) }.map { id in
            MoodleDiscussion(id: id, name: "公告", subject: id == 24 ? "較早的設計公告" : "課程公告",
                message: "合成資料", timemodified: 100 - id, userfullname: "教師", created: 100 - id,
                numreplies: 0, pinned: false)
        }, warnings: warnings)
    }
}

@MainActor final class MoodleService: MoodleAssignmentAPIClientProtocol, MoodleForumAPIClientProtocol {
    var sessionRevision: Int { 0 }
    func fetchForumsByCourse(courseId: Int) async throws -> [MoodleForum] { fatalError() }
    func fetchForumDiscussions(forumId: Int) async throws -> MoodleDiscussionsResponse { fatalError() }
    func fetchForumDiscussions(forumId: Int, page: Int) async throws -> MoodleDiscussionsResponse { fatalError() }
    static var shared: MoodleService { fatalError("Offline tests must never create the live client") }
    func fetchAssignments(courseId: Int) async throws -> [MoodleAssignment] { fatalError() }
    func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus { fatalError() }
}
@MainActor final class AssignmentClient: MoodleAssignmentAPIClientProtocol {
    let fixture = MoodleUIFixtureRepository()
    var failID: Int?
    var statusError: Error = URLError(.timedOut)
    var listError: Error?
    var unknown: [Int: String] = [:]
    var active = 0
    var peak = 0
    func fetchAssignments(courseId: Int) async throws -> [MoodleAssignment] {
        if let listError { throw listError }
        return fixture.assignments(courseId: courseId)
    }
    func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        if assignId == failID { throw statusError }
        if let json = unknown[assignId] { return try decode(json) }
        if assignId == 2 {
            return try decode(#"{"lastattempt":{"teamsubmission":{"id":2,"status":"submitted"}}}"#)
        }
        return try await fixture.fetchStatus(assignment: fixture.assignments(courseId: 1).first { $0.id == assignId }!)
    }
}

@MainActor protocol MoodleCourseRepositoryProtocol {}
@MainActor protocol MoodleSubmissionRepositoryProtocol {}
@MainActor protocol MoodleDiscussionPostsRepositoryProtocol {}

@MainActor final class PendingCompleteAnnouncements: MoodleAnnouncementsRepositoryProtocol {
    var preview: [MoodleDiscussion] = []
    var pending: [CheckedContinuation<[MoodleDiscussion], Error>] = []
    func fetchAnnouncements(courseId: Int) async throws -> [MoodleDiscussion] { preview }
    func fetchCompleteAnnouncements(courseId: Int, cached: [MoodleDiscussion]) async throws -> [MoodleDiscussion] {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func waitFor(_ count: Int) async { while pending.count < count { await Task.yield() } }
}
@MainActor final class PendingQuestions: MoodleQuestionsRepositoryProtocol {
    var sessionRevision = 0
    var pending: [CheckedContinuation<[MoodleQuestionSection], Error>] = []
    func fetchSections(courseId: Int) async throws -> [MoodleQuestionSection] {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func waitFor(_ count: Int) async { while pending.count < count { await Task.yield() } }
}

@MainActor final class CountedAnnouncements: MoodleAnnouncementsRepositoryProtocol {
    let fixture: MoodleUIFixtureRepository
    var calls = 0
    init(_ fixture: MoodleUIFixtureRepository) { self.fixture = fixture }
    func fetchAnnouncements(courseId: Int) async throws -> [MoodleDiscussion] {
        calls += 1
        return try await fixture.fetchAnnouncements(courseId: courseId)
    }
}
@MainActor final class CountedAssignments: MoodleAssignmentsRepositoryProtocol {
    let fixture: MoodleUIFixtureRepository
    var calls = 0
    var empty = false
    init(_ fixture: MoodleUIFixtureRepository) { self.fixture = fixture }
    func fetchAssignments(courseId: Int) async throws -> MoodleAssignmentsSnapshot {
        calls += 1
        if empty { return .init(assignments: [], submittedStatus: [:]) }
        return try await fixture.fetchAssignments(courseId: courseId)
    }
}

@main struct Checks {
    @MainActor static func main() async throws {
        let forumClient = ForumClient()
        let forumRepo = ProductionAnnouncementsRepository(client: forumClient)
        let paged = MoodleAnnouncementsViewModel(repository: forumRepo)
        await paged.load(courseId: 1)
        precondition(paged.discussions.count == 20 && !paged.hasLoadedAll && forumClient.calls == [0])
        paged.searchText = "設計"
        await paged.loadComplete(courseId: 1)
        precondition(paged.discussions.count == 25 && paged.hasLoadedAll && forumClient.calls == [0, 1])
        precondition(paged.filteredDiscussions.map(\.id) == [24] && forumClient.forumCalls == 1)
        await paged.loadComplete(courseId: 1)
        precondition(forumClient.calls == [0, 1])
        forumClient.failPage = 1
        await paged.loadComplete(courseId: 1, force: true)
        precondition(paged.errorMessage != nil && !paged.hasLoadedAll && paged.discussions.count == 20)
        forumClient.failPage = nil
        await paged.loadComplete(courseId: 1, force: true)
        precondition(paged.errorMessage == nil && paged.hasLoadedAll)
        forumClient.repeatPage = true
        await paged.loadComplete(courseId: 1, force: true)
        precondition(paged.errorMessage != nil && !paged.hasLoadedAll)
        print("PASS: announcement preview=20, full/search pagination=25, no refetch of first page, older search hit, partial failure/retry, repeated-page bound")
        let filteredClient = ForumClient()
        filteredClient.hiddenIDs = [0]
        let filtered = MoodleAnnouncementsViewModel(repository: ProductionAnnouncementsRepository(client: filteredClient))
        await filtered.loadComplete(courseId: 1)
        precondition(filtered.discussions.count == 24 && filtered.hasLoadedAll && filteredClient.calls == [0, 1])
        filteredClient.total = 45
        filteredClient.hiddenIDs = Set(20..<40)
        filteredClient.calls = []
        await filtered.loadComplete(courseId: 1, force: true)
        precondition(filtered.discussions.count == 25 && filtered.hasLoadedAll && filteredClient.calls == [0, 1, 2])
        filteredClient.hiddenIDs = Set(0..<20)
        filteredClient.calls = []
        await filtered.loadComplete(courseId: 1, force: true)
        precondition(filtered.discussions.count == 25 && filtered.hasLoadedAll && filteredClient.calls == [0, 1, 2])
        filteredClient.repeatPage = true
        await filtered.loadComplete(courseId: 1, force: true)
        precondition(filtered.errorMessage != nil && !filtered.hasLoadedAll)
        filteredClient.repeatPage = false
        filteredClient.unknownWarning = true
        await filtered.loadComplete(courseId: 1, force: true)
        precondition(filtered.errorMessage != nil && !filtered.hasLoadedAll)
        let hiddenPage = try JSONDecoder().decode(MoodleDiscussionsResponse.self,
            from: Data(#"{"discussions":[],"warnings":[{"item":"post","itemid":1,"warningcode":"1","message":"hidden"}]}"#.utf8))
        precondition(hiddenPage.consumedPageCount == 1)
        print("PASS: permission-filtered short/empty pages continue pagination; repeated hidden pages and unknown warnings remain errors")
        let client = AssignmentClient()
        let repository = ProductionAssignmentsRepository(client: client)
        let snapshot = try await repository.fetchAssignments(courseId: 1)
        precondition(snapshot.submittedStatus[1] == true && snapshot.submittedStatus[2] == true)
        precondition(snapshot.submittedStatus[3] == false && client.peak == 4)
        client.failID = 3
        let partialStatus = try await repository.fetchAssignments(courseId: 1)
        precondition(partialStatus.assignments.count == 5 && partialStatus.submittedStatus[3] == nil)
        precondition(partialStatus.submittedStatus[1] == true && partialStatus.submittedStatus[4] == false)
        client.unknown = [1: #"{}"#, 2: #"{"lastattempt":{}}"#,
                          4: #"{"lastattempt":{"submission":{"status":"future-state"}}}"#]
        let unknown = try await repository.fetchAssignments(courseId: 1)
        precondition(unknown.assignments.count == 5 && unknown.submittedStatus == [5: false])
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            client.statusError = error
            do { _ = try await repository.fetchAssignments(courseId: 1); fatalError("Cancellation swallowed") }
            catch is CancellationError {} catch let error as URLError { precondition(error.code == .cancelled) }
        }
        client.listError = URLError(.timedOut)
        do { _ = try await repository.fetchAssignments(courseId: 1); fatalError("List failure swallowed") }
        catch let error as URLError { precondition(error.code == .timedOut) }
        let unknownRepo = MoodleAssignmentsRepository()
        unknownRepo.result = unknown.assignments
        let unknownDeps = client.fixture.details
        let unknownModel = MoodleCourseDetailViewModel(course: client.fixture.courses[0], repositories: .init(
            announcements: unknownDeps.announcements, assignments: unknownRepo, resources: unknownDeps.resources,
            questions: unknownDeps.questions, attendance: unknownDeps.attendance, grades: unknownDeps.grades,
            submission: unknownDeps.submission, posts: unknownDeps.posts))
        await unknownModel.loadOverview()
        precondition(unknownModel.assignments.assignments.count == 5 && unknownModel.pendingAssignments.isEmpty)
        precondition(unknownModel.unknownSubmissionCount == 5)
        precondition(unknownModel.detail(.assignments) == "5 份狀態未知")
        precondition(unknownModel.pendingEmptyMessage == "5 份作業狀態未知，請到作業頁確認")
        precondition(unknownModel.nextDeadline(now: Date()) == "狀態未知")
        unknownModel.assignments.updateSubmission(assignmentID: 1, submitted: true)
        precondition(unknownModel.unknownSubmissionCount == 4 && unknownModel.pendingAssignments.isEmpty)
        precondition(unknownModel.detail(.assignments) == "4 份狀態未知")
        precondition(unknownModel.pendingEmptyMessage == "4 份作業狀態未知，請到作業頁確認")
        precondition(unknownModel.nextDeadline(now: Date()) == "狀態未知")
        unknownModel.assignments.updateSubmission(assignmentID: 4, submitted: false)
        precondition(unknownModel.unknownSubmissionCount == 3 && unknownModel.pendingAssignments.map(\.id) == [4])
        precondition(unknownModel.detail(.assignments) == "1 份待繳、3 份狀態未知")
        precondition(unknownModel.nextDeadline(now: Date()) == "未設定截止日")
        for assignment in unknownModel.assignments.assignments {
            unknownModel.assignments.updateSubmission(assignmentID: assignment.id, submitted: true)
        }
        precondition(unknownModel.unknownSubmissionCount == 0 && unknownModel.pendingAssignments.isEmpty)
        precondition(unknownModel.detail(.assignments) == "0 份待繳")
        precondition(unknownModel.pendingEmptyMessage == "沒有待繳作業")
        precondition(unknownModel.nextDeadline(now: Date()) == "無待繳")
        unknownRepo.result = []
        await unknownModel.assignments.load(courseId: 1, force: true)
        precondition(unknownModel.unknownSubmissionCount == 0 && unknownModel.pendingEmptyMessage == "沒有待繳作業")
        print("PASS: unknown-only and submitted/unknown overview never claim no pending; known pending, all submitted and empty remain distinct")
        print("PASS: mixed submitted/team/pending/unknown statuses retain all assignments; unknown excluded from pending; list errors and both cancellations propagate")
        let fixture = MoodleUIFixtureRepository()
        let ann = CountedAnnouncements(fixture)
        let assignments = CountedAssignments(fixture)
        let course = fixture.courses[0]
        let deps = fixture.details
        let model = MoodleCourseDetailViewModel(course: course, repositories: .init(
            announcements: ann, assignments: assignments, resources: deps.resources,
            questions: deps.questions, attendance: deps.attendance, grades: deps.grades,
            submission: deps.submission, posts: deps.posts))
        precondition(model.resources == nil && model.questions == nil)
        for destination in MoodleCourseDetailViewModel.Destination.allCases {
            precondition(model.detail(destination) == nil)
        }
        await model.loadOverview()
        precondition(model.resources == nil && model.questions == nil)
        precondition(model.pendingAssignments.count == 4 && model.pendingPreview.count == 3)
        precondition(model.pendingAssignments.map(\.id) == [3, 2, 5, 4])
        precondition(model.nextAssignment?.id == 3)
        precondition(model.nextDeadline(now: Date()).contains("已逾期"))
        precondition(model.attendancePercent == 80 && model.currentGrade == "92")
        precondition(model.latestAnnouncements.map(\.id) == [1, 2, 3])
        precondition(model.detail(.assignments) == "4 份待繳")
        model.assignments.updateSubmission(assignmentID: 3, submitted: true)
        precondition(model.pendingAssignments.count == 3 && model.nextAssignment?.id == 2)
        model.assignments.updateSubmission(assignmentID: 3, submitted: false)
        precondition(model.pendingAssignments.count == 4 && model.nextAssignment?.id == 3)
        // Full pages call the same load methods: no second repository request.
        await model.assignments.load(courseId: course.id)
        await model.announcements.load(courseId: course.id)
        await model.loadOverview()
        precondition(assignments.calls == 1 && ann.calls == 1)
        print("PASS: overview loads only four models; summary, chronological pending/undated-last, preview=3, total=4, cached child reuse")

        let overdue = model.assignments.assignments.first { $0.id == 3 }!.dueDateValue!
        precondition(model.nextAssignment(now: overdue.addingTimeInterval(7 * 86400))?.id == 3)
        precondition(model.nextAssignment(now: overdue.addingTimeInterval(7 * 86400 + 1))?.id == 2)
        precondition(model.nextDeadline(now: overdue.addingTimeInterval(7 * 86400 + 1)) != "已逾期 7 天")
        precondition(model.nextAssignment(now: overdue.addingTimeInterval(40 * 86400))?.id == 4)
        precondition(model.pendingAssignments.map(\.id) == [3, 2, 5, 4])
        precondition(model.assignments.assignments.count == 5)
        print("PASS: next deadline excludes >7-day overdue at exact boundary; full pending/assignment lists retain old and undated work")

        model.preparePage(.resources, query: "資源")
        model.preparePage(.questions, query: "問題")
        let resourceIdentity = model.resources!
        let questionIdentity = model.questions!
        var bodyPublications = 0
        let observation = model.objectWillChange.sink { bodyPublications += 1 }
        for _ in 0..<5 { _ = model.resources; _ = model.questions }
        precondition(bodyPublications == 0)
        model.preparePage(.resources, query: "設計")
        model.preparePage(.questions, query: "設計")
        precondition(model.resources === resourceIdentity && model.questions === questionIdentity)
        precondition(resourceIdentity.searchText == "設計" && questionIdentity.searchText == "設計")
        withExtendedLifetime(observation) {}
        print("PASS: lifecycle page preparation reuses child models; body reads publish nothing; initial queries apply")

        model.searchText = "設計"
        await model.loadSearchExtras()
        precondition(model.resources != nil && model.questions != nil && model.searchComplete)
        let groups = model.searchGroups
        precondition(groups.map(\.count) == [5, 4, 3, 1, 5, 1])
        precondition(groups.map { $0.preview.count } == [3, 3, 3, 1, 3, 1])
        precondition(Set(groups.flatMap { group in group.results.map { "\(group.id)-\($0.id)" } }).count == 19)
        model.assignments.searchText = "其他"
        precondition(model.assignments.filteredAssignments.isEmpty)
        model.updateSearch()
        precondition(model.assignments.filteredAssignments.count == 5)
        model.assignments.setSortOrder(.dueLatestFirst)
        precondition(model.assignments.filteredAssignments.first?.id == 5)
        precondition(model.pendingAssignments.first?.id == 3) // Overview always uses earliest due.
        model.searchText = "不存在"
        precondition(model.searchGroups.allSatisfy { $0.count == 0 } && model.searchComplete)
        print("PASS: six grouped search counts/previews, scoped IDs, restored overview query, independent child sorting, no results")

        fixture.failsAnnouncements = true
        await model.refresh()
        precondition(model.error(.announcements) != nil)
        precondition(model.latestAnnouncements.count == 3) // Preserve last good data.
        for destination in [MoodleCourseDetailViewModel.Destination.assignments, .attendance, .grades, .resources, .questions] {
            precondition(model.hasLoaded(destination) && model.error(destination) == nil)
        }
        let previousAssignmentCalls = assignments.calls
        await model.retry(.announcements)
        precondition(model.error(.announcements) == nil && assignments.calls == previousAssignmentCalls)
        let partialFixture = MoodleUIFixtureRepository()
        partialFixture.failsAnnouncements = true
        let partial = MoodleCourseDetailViewModel(course: course, repositories: partialFixture.details)
        await partial.loadOverview()
        precondition(!partial.announcements.hasLoaded && partial.error(.announcements) != nil)
        precondition(partial.pendingAssignments.count == 4 && partial.attendancePercent == 80 && partial.currentGrade == "92")
        print("PASS: first-load/refresh partial failure stays local, cached data survives, retry only failed section")

        let emptyGrades = MoodleGradesRepository()
        let emptyAttendance = MoodleAttendanceRepository()
        assignments.empty = true
        let empty = MoodleCourseDetailViewModel(course: course, repositories: .init(
            announcements: ann, assignments: assignments, resources: deps.resources, questions: deps.questions,
            attendance: emptyAttendance, grades: emptyGrades, submission: deps.submission, posts: deps.posts))
        await empty.loadOverview()
        precondition(empty.nextAssignment == nil && empty.nextDeadline(now: Date()) == "無待繳")
        precondition(empty.attendancePercent == nil && empty.currentGrade == nil)
        emptyGrades.result = try decode("""[{"id":1,"itemtype":"category","gradeformatted":"88"}]""")
        await empty.grades.load(courseId: course.id, force: true)
        precondition(empty.currentGrade == nil)
        emptyGrades.result = try decode("""[{"id":1,"itemtype":"course","gradeformatted":"-"}]""")
        await empty.grades.load(courseId: course.id, force: true)
        precondition(empty.currentGrade == nil)
        emptyGrades.result = try decode("""[{"id":1,"itemtype":"course","gradeformatted":"0.00"}]""")
        await empty.grades.load(courseId: course.id, force: true)
        precondition(empty.currentGrade == "0")
        emptyAttendance.result = [.init(id: 1, sectionName: "", moduleName: "", records: [
            .init(id: 1, date: Date(), timeText: "", description: nil, statusLabel: "尚未點名", scoreText: nil,
                  remarks: nil, status: .pending)], total: 1, source: .webService)]
        await empty.attendance.loadCourse(course.id, force: true)
        precondition(empty.attendancePercent == nil)
        print("PASS: empty pending, missing/category/ungraded course totals hidden, zero grade retained, unresolved attendance hidden")

        // A full-page/search consumer must follow a forced preview replacement,
        // then complete pagination, even if the superseded response finishes first.
        let paginationRaceRepo = PendingAnnouncements()
        let paginationRace = MoodleAnnouncementsViewModel(repository: paginationRaceRepo)
        let fullLoad = Task { await paginationRace.loadComplete(courseId: 1) }
        await paginationRaceRepo.waitFor(1)
        let replacedPreview = Task { await paginationRace.load(courseId: 1, force: true) }
        await paginationRaceRepo.waitFor(2)
        paginationRaceRepo.pending[0].resume(returning: [])
        for _ in 0..<20 { await Task.yield() }
        paginationRaceRepo.pending[1].resume(returning: model.announcements.discussions)
        await replacedPreview.value
        await fullLoad.value
        precondition(paginationRace.hasLoadedAll && paginationRace.discussions.count == 5)
        print("PASS: complete-announcement consumer follows forced preview replacement and still completes its own phase")

        let latePageRepo = PendingCompleteAnnouncements()
        latePageRepo.preview = Array(model.announcements.discussions.prefix(1))
        let latePage = MoodleAnnouncementsViewModel(repository: latePageRepo)
        let completePage = Task { await latePage.loadComplete(courseId: 1) }
        await latePageRepo.waitFor(1)
        await latePage.load(courseId: 1, force: true) // New preview completes first.
        latePageRepo.pending[0].resume(returning: []) // Superseded pagination arrives last.
        await latePageRepo.waitFor(2)
        latePageRepo.pending[1].resume(returning: model.announcements.discussions)
        await completePage.value
        precondition(latePage.hasLoadedAll && latePage.discussions.count == 5)
        let stopped = Task { await latePage.loadComplete(courseId: 1, force: true) }
        await latePageRepo.waitFor(3)
        latePageRepo.pending[2].resume(throwing: CancellationError())
        await stopped.value
        precondition(latePage.errorMessage != nil && latePageRepo.pending.count == 3)
        print("PASS: newer preview finishes before stale pagination; complete consumer resumes; repository cancellation does not loop")

        let switchingRepo = PendingQuestions()
        let switching = MoodleQuestionsViewModel(repository: switchingRepo)
        let firstCourse = Task { await switching.load(courseId: 1) }
        await switchingRepo.waitFor(1)
        let secondCourse = Task { await switching.load(courseId: 2) }
        await switchingRepo.waitFor(2)
        switchingRepo.pending[1].resume(returning: [.init(id: 2, name: "新課程", modules: [])])
        await secondCourse.value
        switchingRepo.pending[0].resume(returning: [.init(id: 1, name: "舊課程", modules: [])])
        await firstCourse.value
        precondition(switching.sections.map(\.id) == [2])
        let oldAccount = Task { await switching.load(courseId: 2, force: true) }
        await switchingRepo.waitFor(3)
        switchingRepo.sessionRevision += 1
        let newAccount = Task { await switching.load(courseId: 2) }
        await switchingRepo.waitFor(4)
        switchingRepo.pending[3].resume(returning: [])
        await newAccount.value
        switchingRepo.pending[2].resume(returning: [.init(id: 2, name: "舊帳號", modules: [])])
        await oldAccount.value
        precondition(switching.sections.isEmpty && switching.errorMessage == nil)
        print("PASS: in-flight question requests do not coalesce across courses or account revisions")

        let pending = PendingAnnouncements()
        let shared = MoodleAnnouncementsViewModel(repository: pending)
        let overview = Task { await shared.load(courseId: 1) }
        await pending.waitFor(1)
        let child = Task { await shared.load(courseId: 1) }
        for _ in 0..<20 { await Task.yield() }
        precondition(pending.pending.count == 1)
        overview.cancel()
        for _ in 0..<20 { await Task.yield() }
        pending.pending[0].resume(returning: model.announcements.discussions)
        await child.value
        await overview.value
        precondition(shared.hasLoaded && shared.discussions.count == 5)
        let older = Task { await shared.load(courseId: 1, force: true) }
        await pending.waitFor(2)
        let newer = Task { await shared.load(courseId: 1, force: true) }
        await pending.waitFor(3)
        pending.pending[2].resume(returning: Array(model.announcements.discussions.prefix(1)))
        await newer.value
        pending.pending[1].resume(throwing: URLError(.timedOut))
        await older.value
        precondition(shared.discussions.count == 1 && shared.errorMessage == nil && !shared.isLoading)
        let cancel = Task { await shared.load(courseId: 1, force: true) }
        await pending.waitFor(4)
        cancel.cancel()
        for _ in 0..<20 { await Task.yield() }
        pending.pending[3].resume(returning: [])
        await cancel.value
        precondition(shared.discussions.count == 1 && shared.errorMessage == nil)
        print("PASS: concurrent overview/child coalesce; one cancellation preserves another consumer; forced refresh rejects stale errors; last-consumer cancellation preserves cache")
    }
}
'''
# Swift single-line raw JSON strings.
checks = checks.replace('decode("""[', 'decode(#"[').replace(']""")', ']"#)')
with tempfile.TemporaryDirectory(prefix='niu-moodle-overview-') as directory:
    folder = Path(directory)
    source = folder / 'Checks.swift'
    source.write_text('\n'.join([stubs, assignment_protocol, assignment_repository, forum_protocol, forum_repository, container, models, fixture, checks]))
    binary = folder / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-D', 'DEBUG', '-parse-as-library', '-swift-version', '6',
                    '-default-isolation', 'MainActor', '-enable-upcoming-feature', 'NonisolatedNonsendingByDefault',
                    '-module-cache-path', str(folder / 'ModuleCache'),
                    *[str(BASE / p) for p in ['Models/MoodleModels.swift', 'Models/MoodleSearch.swift',
                       'Questions/MoodleQuestionActivity.swift', 'Attendance/MoodleAttendanceModels.swift',
                       'Upcoming/MoodleUpcomingModels.swift', 'ViewModels/MoodleCourseDetailViewModel.swift']],
                    str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)

view = (BASE / 'Views/MoodleCourseDetailView.swift').read_text()
assert 'TabView(' not in view and 'tabSwipeGesture' not in view and 'selectedTab' not in view
assert '.listStyle(.insetGrouped)' in view and '.glassEffect' not in view
assert 'ContentUnavailableView.search' in view and 'prompt: "搜尋整門課"' in view
assert 'dynamicTypeSize > .large' in view and '.font(.title2.bold())' in view
assert 'showsCourseName: false' in view and 'pendingAssignments.count > 3' in view
assert 'Text(viewModel.pendingEmptyMessage).foregroundStyle(.secondary).frame(minHeight: 44)' in view
for path, titles in [('CourseDetail/MoodleCourseTabViews.swift', ['作業', '公告', '成績']),
                     ('CourseDetail/MoodleCourseResourcesView.swift', ['資源']),
                     ('Questions/MoodleCourseQuestionsView.swift', ['問答']),
                     ('Attendance/MoodleAttendanceView.swift', ['出缺席'])]:
    text = (BASE / path).read_text()
    for title in titles:
        assert f'.navigationTitle("{title}")' in text and f'prompt: "搜尋{title}"' in text
fixture_text = (BASE / 'Fixtures/MoodleUIFixture.swift').read_text()
for screen in ['course-search', 'course-assignments', 'course-resources', 'course-attendance', 'course-partial-error']:
    assert f'"{screen}"' in fixture_text
print('PASS: native overview, child navigation/search, Dynamic Type, shared deadline row and six DEBUG fixture routes')
