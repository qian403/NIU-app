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
fixture = (BASE / "Fixtures/MoodleUIFixture.swift").read_text().split("@MainActor\nstruct MoodleUIFixtureRoot")[0]+"\n#endif\n"
service = (BASE / "Services/MoodleService.swift").read_text()
moodle_error = service[service.index("enum MoodleError: LocalizedError"):service.index("// MARK: - String Extension")]
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
    func authenticate(username: String, password: String) async throws { fatalError("Unexpected authentication") }
    func fetchCourses() async throws -> [MoodleCourse] {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func take(_ count: Int) async { while pending.count < count { await Task.yield() } }
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
    source.write_text("\n".join([checks, moodle_error, protocols, extension, snapshot, container, attendance, questions, model, fixture]))
    binary = folder / "checks"
    subprocess.run(["xcrun", "swiftc", "-D", "DEBUG", "-parse-as-library", "-swift-version", "5",
                    "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
                    "-module-cache-path", str(folder / "ModuleCache"),
                    str(BASE / "Models/MoodleModels.swift"), str(BASE / "Attendance/MoodleAttendanceModels.swift"),
                    str(BASE / "Upcoming/MoodleUpcomingModels.swift"), str(BASE / "Upcoming/MoodleUpcomingRepository.swift"),
                    str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
