#!/usr/bin/env python3
"""Compile the production home ViewModel and DEBUG repositories; never access a service or Keychain."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "Features/Moodle"
repositories = (BASE / "Repositories/MoodleRepositories.swift").read_text()
protocols = "\n".join(re.findall(r"@MainActor\nprotocol Moodle\w*RepositoryProtocol[^\n]*\{.*?\n\}", repositories, re.S))
# Include the production default catalog and snapshot shape.
extension = repositories[repositories.index("extension MoodleCourseRepositoryProtocol"):repositories.index("@MainActor\nstruct MoodleCourseRepository")]
snapshot = repositories[repositories.index("struct MoodleAssignmentsSnapshot"):repositories.index("@MainActor\nprotocol MoodleAssignmentsRepositoryProtocol")]
container = repositories[repositories.index("@MainActor\nstruct MoodleDetailRepositories"):repositories.index("    static var live:")]+"}\n"
attendance = (BASE / "Attendance/MoodleAttendanceRepository.swift").read_text().split("@MainActor\nstruct")[0]
questions = (BASE / "Questions/MoodleQuestionsRepository.swift").read_text()
questions = re.search(r"@MainActor\nprotocol MoodleQuestionsRepositoryProtocol.*?\n\}", questions, re.S)[0]
model = (BASE / "ViewModels/MoodleViewModel.swift").read_text().split("// MARK: - Schedule")[0]
semester_method = re.search(r"    static func currentSemesterCode\(.*?\n    \}", (BASE / "ViewModels/MoodleViewModel.swift").read_text(), re.S)[0]
model += "\nenum MoodleScheduleCourseLookupViewModel {\n" + semester_method + "\n}\n"
clock_source = (ROOT / "NIU-LiveActivities/ClassScheduleModels.swift").read_text()
model += re.search(r"nonisolated enum ScheduleClock \{.*?\n\}", clock_source, re.S)[0]

fixture = (BASE / "Fixtures/MoodleUIFixture.swift").read_text().split("@MainActor\nstruct MoodleUIFixtureRoot")[0]+"\n#endif\n"
service = (BASE / "Services/MoodleService.swift").read_text()
moodle_error = service[service.index("enum MoodleError: LocalizedError"):service.index("// MARK: - String Extension")]
assignment_view = (BASE / "Views/MoodleAssignmentView.swift").read_text()
load_submission = assignment_view[assignment_view.index("    private func loadSubmission()"):
                                  assignment_view.index("    private func clearSubmissionFiles()")]
# Execute the production status/callback/notification path without SwiftUI or a live service.
submission_harness = '''
@MainActor final class SubmissionViewHarness {
    let repository: any MoodleSubmissionRepositoryProtocol
    let assignment: MoodleAssignment
    let sessionRevision: Int
    var onSubmissionChange: ((Bool) -> Void)?
    var submissionRequestID = UUID()
    var submissionStatus: MoodleSubmissionStatus?
    var gradeItem: MoodleGradeItem?
    var isLoading = true
    var actionMessage: String?
    init(assignment: MoodleAssignment, repository: any MoodleSubmissionRepositoryProtocol) {
        self.assignment = assignment
        self.repository = repository
        self.sessionRevision = repository.sessionRevision
    }
    private func findAssignmentGrade(in items: [MoodleGradeItem]) -> MoodleGradeItem? { nil }
''' + load_submission.replace('private func loadSubmission', 'func loadSubmission') + '}\n'
checks = r'''
import Foundation
import Combine
struct MoodleQuestionSection { let id: Int; let name: String; let modules: [MoodleModule] }
@MainActor final class MoodleService {
    static var shared: MoodleService { fatalError("Live service in fixture") }
    var sessionRevision: Int { 0 }
    var calendarCapability: MoodleCalendarCapability { fatalError("Live capability") }
    func fetchActionEvents(from: Int, to: Int, after: Int, limit: Int) async throws -> MoodleCalendarActionEvents { fatalError() }
    func fetchAssignments(courseId: Int) async throws -> [MoodleAssignment] { fatalError() }
    func fetchUpcomingAssignments(courseIDs: [Int]) async throws -> [MoodleAssignment] { fatalError() }
    func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus { fatalError() }
}
typealias MoodleCourseRepository = MoodleUIFixtureRepository
@MainActor final class ScriptedCourses: MoodleCourseRepositoryProtocol {
    var isAuthenticated = true
    var availableSemesters: [String] = []
    var pending: [CheckedContinuation<[MoodleCourse], Error>] = []
    func authenticate(username: String, password: String) async throws { throw MoodleError.authFailed("合成登入失敗") }
    func fetchCourses() async throws -> [MoodleCourse] {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func take(_ count: Int) async { while pending.count < count { await Task.yield() } }
}
@MainActor final class HomeUpcoming: MoodleUpcomingRepositoryProtocol {
    var sessionRevision = 0
    var calls: [[Int]] = []
    var pending: [CheckedContinuation<[MoodleUpcomingItem], Error>] = []
    var delayed = false
    var items: [MoodleUpcomingItem] = []
    func fetchUpcoming(courses: [MoodleCourse], now: Date) async throws -> [MoodleUpcomingItem] {
        calls.append(courses.map(\.id))
        if delayed { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return items
    }
    func resolveAssignment(_ item: MoodleUpcomingItem) async throws -> MoodleAssignment { fatalError() }
    func wait(_ count: Int) async { while pending.count < count { await Task.yield() } }
}
@main struct Checks {
    @MainActor static func main() async throws {
        let fixture = MoodleUIFixtureRepository()
        let model = MoodleViewModel(repository: fixture)
        precondition(model.contentState == .loading)
        await model.loadCourses(username: "", password: "")
        precondition(model.allSemesters == ["115-1", "114-2", "113-2"])
        precondition(model.contentState == .courses && model.currentSemesterCourses.count == 5)
        model.selectedSemester = "114-2"
        await model.refresh(username: "", password: "")
        precondition(model.selectedSemester == "114-2")
        model.selectedSemester = " 114-2 \n"
        await model.refresh(username: "", password: "")
        precondition(model.selectedSemester == "114-2" && model.currentSemesterCourses.count == 5)
        model.selectedSemester = "113-2"
        precondition(model.contentState == .empty)
        await model.refresh(username: "", password: "")
        precondition(model.selectedSemester == "113-2" && model.contentState == .empty)
        model.selectedSemester = "removed"
        await model.refresh(username: "", password: "")
        precondition(model.selectedSemester == "115-1")
        precondition(MoodleViewModel.selection("115-1", in: []) == nil)
        print("PASS: semester catalog, empty semester, preserved/normalized selection and removed selection fallback")

        let failed = MoodleViewModel(repository: MoodleUIFixtureRepository(failsNextLoad: true))
        await failed.loadCourses(username: "", password: "")
        if case .error = failed.contentState {} else { preconditionFailure("Expected error") }
        await failed.loadCourses(username: "", password: "")
        precondition(failed.contentState == .courses)

        let repo = ScriptedCourses()
        let concurrent = MoodleViewModel(repository: repo)
        let first = Task { await concurrent.loadCourses(username: "", password: "") }
        await repo.take(1)
        precondition(concurrent.contentState == .loading && concurrent.isRefreshing)
        repo.pending[0].resume(returning: fixture.courses)
        await first.value
        concurrent.selectedSemester = "114-2"
        let refresh = Task { await concurrent.refresh(username: "", password: "") }
        await repo.take(2)
        precondition(concurrent.contentState == .courses && concurrent.isRefreshing)
        concurrent.selectedSemester = "115-1"
        repo.pending[1].resume(throwing: URLError(.notConnectedToInternet))
        await refresh.value
        precondition(concurrent.contentState == .courses && !concurrent.isRefreshing)
        if case .error = concurrent.loadState {} else { preconditionFailure("Expected cached refresh error") }
        let older = Task { await concurrent.refresh(username: "", password: "") }
        await repo.take(3)
        let newer = Task { await concurrent.refresh(username: "", password: "") }
        await repo.take(4)
        repo.pending[3].resume(returning: fixture.courses.filter { $0.semesterLabel == "114-2" })
        await newer.value
        precondition(concurrent.selectedSemester == "114-2")
        repo.pending[2].resume(returning: fixture.courses)
        await older.value
        precondition(concurrent.allSemesters == ["114-2"] && !concurrent.isRefreshing)
        let cancelled = Task { await concurrent.refresh(username: "", password: "") }
        await repo.take(5)
        cancelled.cancel()
        repo.pending[4].resume(returning: [])
        await cancelled.value
        precondition(concurrent.currentSemesterCourses.count == 5 && !concurrent.isRefreshing)
        let empty = Task { await concurrent.refresh(username: "", password: "") }
        await repo.take(6)
        repo.pending[5].resume(returning: [])
        await empty.value
        precondition(concurrent.contentState == .empty && concurrent.selectedSemester == nil)
        print("PASS: loading/error/retry/empty, cached refresh failure, out-of-order results and cancellation")

        let homeCourses = ScriptedCourses()
        let homeRepo = HomeUpcoming()
        let home = MoodleViewModel(repository: homeCourses)
        let upcoming = MoodleUpcomingViewModel(repository: homeRepo)
        let firstHome = Task { await home.loadHome(upcoming: upcoming, request: 0) { nil } }
        await homeCourses.take(1)
        homeCourses.pending[0].resume(returning: fixture.courses)
        await firstHome.value
        precondition(homeRepo.calls.count == 1 && upcoming.state == .empty)
        await home.loadHome(upcoming: upcoming, request: 0) { nil }
        precondition(homeCourses.pending.count == 1 && homeRepo.calls.count == 1)
        home.selectedSemester = "114-2"
        upcoming.invalidate()
        await home.loadHome(upcoming: upcoming, request: 0) { nil }
        await home.loadHome(upcoming: upcoming, request: 0) { nil }
        precondition(homeCourses.pending.count == 1 && homeRepo.calls.count == 2)
        precondition(homeRepo.calls[1] == home.currentSemesterCourses.map(\.id))
        homeRepo.items = [.init(assignmentID: 7, courseID: 11, name: "保留", courseName: "課程", dueDate: Date())]
        await upcoming.reload()
        let cachedItems = upcoming.items
        let refreshHome = Task { await home.loadHome(upcoming: upcoming, request: 0, force: true) { nil } }
        await homeCourses.take(2)
        precondition(upcoming.items == cachedItems)
        homeRepo.delayed = true
        homeCourses.pending[1].resume(returning: fixture.courses)
        await homeRepo.wait(1)
        precondition(upcoming.items == cachedItems)
        homeRepo.pending[0].resume(returning: cachedItems)
        await refreshHome.value
        precondition(homeRepo.calls.count == 4)
        // An old semester is cancelled while its replacement is loading.
        home.selectedSemester = "115-1"; upcoming.invalidate()
        let oldSemester = Task { await home.loadHome(upcoming: upcoming, request: 0) { nil } }
        await homeRepo.wait(2)
        oldSemester.cancel()
        home.selectedSemester = "114-2"; upcoming.invalidate()
        let newSemester = Task { await home.loadHome(upcoming: upcoming, request: 0) { nil } }
        await homeRepo.wait(3)
        homeRepo.pending[2].resume(returning: cachedItems)
        await newSemester.value
        homeRepo.pending[1].resume(returning: [])
        await oldSemester.value
        precondition(upcoming.items == cachedItems && homeCourses.pending.count == 2)
        print("PASS: home reappearance and semester return skip duplicate loads; one semester request; refresh preserves rows; cancelled semester cannot overwrite replacement")

        // A course-entry detail has no callback to this home model.
        let beforeSubmissionCalls = homeRepo.calls.count
        let courseAssignment = MoodleAssignment(id: cachedItems[0].assignmentID, cmid: 7,
            course: home.currentSemesterCourses[0].id, name: "合成作業", intro: "",
            duedate: 0, allowsubmissionsfromdate: 0, grade: nil, timemodified: 0)
        let courseDetail = SubmissionViewHarness(assignment: courseAssignment, repository: fixture)
        var courseCallbackCount = 0
        courseDetail.onSubmissionChange = { submitted in
            precondition(submitted)
            courseCallbackCount += 1
        }
        try await fixture.submit(assignment: courseAssignment)
        await courseDetail.loadSubmission()
        precondition(courseCallbackCount == 1)
        precondition(upcoming.state == .empty)
        await homeRepo.wait(4)
        precondition(upcoming.state == .empty && homeRepo.calls.count == beforeSubmissionCalls + 1)
        homeRepo.pending[3].resume(returning: [])
        await home.loadHome(upcoming: upcoming, request: 0) { nil }
        precondition(upcoming.state == .empty && homeCourses.pending.count == 2)
        precondition(homeRepo.calls.count == beforeSubmissionCalls + 1)
        print("PASS: course-entry submission updates cached home through notification; revisit does not duplicate refresh or restore submitted row")

        let loggedOut = ScriptedCourses(); loggedOut.isAuthenticated = false
        let loggedOutHome = MoodleViewModel(repository: loggedOut)
        let loggedOutUpcoming = MoodleUpcomingViewModel(repository: homeRepo)
        await loggedOutHome.loadHome(upcoming: loggedOutUpcoming, request: 0) { nil }
        if case .failed = loggedOutUpcoming.state {} else { fatalError("Missing credentials left spinner") }
        await loggedOutHome.loadHome(upcoming: loggedOutUpcoming, request: 1) { ("synthetic", "synthetic") }
        if case .failed = loggedOutUpcoming.state {} else { fatalError("Authentication failure left spinner") }
        precondition(loggedOut.pending.isEmpty)
        print("PASS: missing credentials and failed authentication end upcoming loading without network/Keychain")

        for (day, expected) in [("2026-01-01T00:00:00+08:00", "114-1"),
            ("2026-02-01T00:00:00+08:00", "114-2"), ("2026-03-01T00:00:00+08:00", "114-2"),
            ("2026-07-31T23:59:59+08:00", "114-2"), ("2026-08-01T00:00:00+08:00", "115-1")] {
            let date = ISO8601DateFormatter().date(from: day)!
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.courses[0])) as! [String: Any]
            json["idnumber"] = ""; json["startdate"] = Int(date.timeIntervalSince1970)
            let course = try JSONDecoder().decode(MoodleCourse.self, from: JSONSerialization.data(withJSONObject: json))
            let datesRepo = ScriptedCourses()
            let dates = MoodleViewModel(repository: datesRepo)
            let load = Task { await dates.loadCourses(username: "", password: "") }
            await datesRepo.take(1); datesRepo.pending[0].resume(returning: [course]); await load.value
            precondition(dates.allSemesters == [expected])
        }
        print("PASS: inferred semester uses shared Taipei Gregorian rule for January, February, March, July/August boundary")

        let assignments = try await fixture.fetchAssignments(courseId: 1)
        precondition(assignments.assignments.count == 5 && assignments.submittedStatus[1] == true)
        precondition(fixture.webSubmissionURL(for: assignments.assignments[0]) == nil)
        precondition(assignments.submittedStatus[2] == false && assignments.assignments[2].isOverdue)
        precondition(assignments.assignments[3].dueDateValue == nil)
        let announcements = try await fixture.fetchAnnouncements(courseId: 1)
        let resources = try await fixture.fetchSections(courseId: 1)
        let attendance = try await fixture.fetchCourseAttendance(courseId: 1)
        let grades = try await fixture.fetchGrades(courseId: 1)
        precondition(!announcements.isEmpty && resources.count == 3)
        precondition(attendance.first?.absentCount == 1 && !grades.isEmpty)
        precondition(fixture.authenticatedFileURL(for: "https://example.com") == nil)
        print("PASS: offline fixture courses, announcements, assignment states, resources, attendance and grades")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-moodle-home-") as directory:
    folder = Path(directory)
    source = folder / "Checks.swift"
    source.write_text("\n".join([checks, moodle_error, protocols, extension, snapshot, container, attendance, questions, model, fixture, submission_harness]))
    binary = folder / "checks"
    subprocess.run(["xcrun", "swiftc", "-D", "DEBUG", "-parse-as-library", "-swift-version", "5",
                    "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
                    "-module-cache-path", str(folder / "ModuleCache"),
                    str(BASE / "Models/MoodleModels.swift"), str(BASE / "Attendance/MoodleAttendanceModels.swift"),
                    str(BASE / "Upcoming/MoodleUpcomingModels.swift"), str(BASE / "Upcoming/MoodleUpcomingRepository.swift"),
                    str(BASE / "Upcoming/MoodleUpcomingViewModel.swift"),
                    str(source), "-o", str(binary)], check=True)
    import os
    subprocess.run([str(binary)], env={**os.environ, "TZ": "UTC"}, check=True, timeout=30)
