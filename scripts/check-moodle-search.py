#!/usr/bin/env python3
"""Compile production Moodle search and all six ViewModels with offline fixtures."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "Features/Moodle"

def model(file, name):
    source = (BASE / file).read_text()
    start = source.index(f"@MainActor\nfinal class {name}")
    end = source.find("\nstruct ", start)
    return source[start:end] if end != -1 else source[start:]

MODELS = "\n".join([
    model("CourseDetail/MoodleCourseTabViews.swift", "MoodleAnnouncementsViewModel"),
    model("CourseDetail/MoodleCourseTabViews.swift", "MoodleAssignmentsListViewModel"),
    model("CourseDetail/MoodleCourseTabViews.swift", "MoodleGradesViewModel"),
    model("CourseDetail/MoodleCourseResourcesView.swift", "MoodleResourcesViewModel"),
    model("Questions/MoodleQuestionsViewModel.swift", "MoodleQuestionsViewModel"),
    model("Attendance/MoodleAttendanceViewModel.swift", "MoodleAttendanceViewModel"),
])

CHECKS = r'''
import Foundation
import Combine

@MainActor protocol MoodleAnnouncementsRepositoryProtocol {
    func fetchAnnouncements(courseId: Int) async throws -> [MoodleDiscussion]
    func fetchCompleteAnnouncements(courseId: Int, cached: [MoodleDiscussion]) async throws -> [MoodleDiscussion]
}
extension MoodleAnnouncementsRepositoryProtocol {
    func fetchCompleteAnnouncements(courseId: Int, cached: [MoodleDiscussion]) async throws -> [MoodleDiscussion] { cached }
}
@MainActor final class MoodleAnnouncementsRepository: MoodleAnnouncementsRepositoryProtocol {
    var result: [MoodleDiscussion] = []
    func fetchAnnouncements(courseId: Int) async throws -> [MoodleDiscussion] { result }
}
struct MoodleAssignmentsSnapshot {
    let assignments: [MoodleAssignment]
    let submittedStatus: [Int: Bool]
}
@MainActor protocol MoodleAssignmentsRepositoryProtocol {
    func fetchAssignments(courseId: Int) async throws -> MoodleAssignmentsSnapshot
}
@MainActor final class MoodleAssignmentsRepository: MoodleAssignmentsRepositoryProtocol {
    var result: [MoodleAssignment] = []
    func fetchAssignments(courseId: Int) async throws -> MoodleAssignmentsSnapshot {
        MoodleAssignmentsSnapshot(assignments: result, submittedStatus: [:])
    }
}
@MainActor protocol MoodleGradesRepositoryProtocol {
    func fetchGrades(courseId: Int) async throws -> [MoodleGradeItem]
}
@MainActor final class MoodleGradesRepository: MoodleGradesRepositoryProtocol {
    var result: [MoodleGradeItem] = []
    func fetchGrades(courseId: Int) async throws -> [MoodleGradeItem] { result }
}
@MainActor protocol MoodleResourcesRepositoryProtocol {
    func fetchSections(courseId: Int) async throws -> [MoodleCourseSection]
}
@MainActor final class ResourceRepository: MoodleResourcesRepositoryProtocol {
    var result: [MoodleCourseSection] = []
    func fetchSections(courseId: Int) async throws -> [MoodleCourseSection] { result }
}
@MainActor protocol MoodleQuestionsRepositoryProtocol {
    var sessionRevision: Int { get }
    func fetchSections(courseId: Int) async throws -> [MoodleQuestionSection]
}
@MainActor final class QuestionRepository: MoodleQuestionsRepositoryProtocol {
    var result: [MoodleQuestionSection] = []
    var sessionRevision = 0
    func fetchSections(courseId: Int) async throws -> [MoodleQuestionSection] { result }
}
@MainActor protocol MoodleAttendanceRepositoryProtocol {
    func fetchCourseAttendance(courseId: Int) async throws -> [MoodleAttendanceSection]
    func fetchAttendance(module: MoodleModule, sectionName: String,
                         attendanceId: Int?, courseModuleId: Int?) async throws -> MoodleAttendanceSection
}
@MainActor final class MoodleAttendanceRepository: MoodleAttendanceRepositoryProtocol {
    var result: [MoodleAttendanceSection] = []
    func fetchCourseAttendance(courseId: Int) async throws -> [MoodleAttendanceSection] { result }
    func fetchAttendance(module: MoodleModule, sectionName: String,
                         attendanceId: Int?, courseModuleId: Int?) async throws -> MoodleAttendanceSection { result[0] }
}

func decode<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@MainActor final class PendingAnnouncements: MoodleAnnouncementsRepositoryProtocol {
    var pending: [CheckedContinuation<[MoodleDiscussion], Error>] = []
    func fetchAnnouncements(courseId: Int) async throws -> [MoodleDiscussion] {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func waitFor(_ count: Int) async { while pending.count < count { await Task.yield() } }
}
@MainActor final class PendingAttendance: MoodleAttendanceRepositoryProtocol {
    var pending: [CheckedContinuation<[MoodleAttendanceSection], Error>] = []
    func fetchCourseAttendance(courseId: Int) async throws -> [MoodleAttendanceSection] {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func fetchAttendance(module: MoodleModule, sectionName: String,
                         attendanceId: Int?, courseModuleId: Int?) async throws -> MoodleAttendanceSection {
        fatalError("Unexpected module load")
    }
    func waitFor(_ count: Int) async { while pending.count < count { await Task.yield() } }
}

@main struct Checks {
    @MainActor static func main() async throws {
        precondition(MoodleSearch.matches(query: "　 sWiFt \n 王老師\t", fields: ["Swift 入門", "王老師"]))
        precondition(!MoodleSearch.matches(query: "Swift 王老師", fields: ["Swift 入門"]))
        precondition(MoodleSearch.trimmed("　 \n Swift\t　") == "Swift")
        precondition(MoodleSearch.matches(query: "　\n\t ", fields: []))
        precondition(MoodleSearch.matches(query: "cafe", fields: ["Café"]))
        print("PASS: AND keywords across fields, case/diacritic insensitive, full/half-width whitespace, empty query")

        let html = "<script>secret</script><style>hidden</style><p>Sw<strong>if</strong>t&nbsp;課程</p><p>王&#x8001;&#24107; &amp; &lt;教材&gt;</p>"
        let plain = MoodleSearch.plainText(html)
        precondition(plain == "Swift 課程 王老師 & <教材>")
        precondition(MoodleSearch.matches(query: "swift 王老師 <教材>", fields: [plain]))
        precondition(!MoodleSearch.matches(query: "script", fields: [plain]))
        precondition(!MoodleSearch.matches(query: "secret", fields: [plain]))
        precondition(MoodleSearch.plainText("<a href='private'>講義</a><!-- secret -->") == "講義")
        print("PASS: HTML block/inline text, entities, escaped text, markup/scripts excluded")

        let sections: [MoodleCourseSection] = try decode("""
        [{"id":1,"name":"第一週 Swift","summary":"","modules":[
          {"id":11,"name":"課程講義","modname":"resource"},
          {"id":12,"name":"參考連結","modname":"url"}]},
         {"id":2,"name":"第二週","summary":"","modules":[
          {"id":21,"name":"Swift 講義","modname":"page"},
          {"id":22,"name":"錄影","modname":"url"}]}]
        """)
        let index = MoodleResourceSearchIndex(sections)
        let results = index.filter(sections, query: "swift")
        precondition(results.map(\.id) == [1, 2])
        precondition(results[0].modules.map(\.id) == [11, 12])
        precondition(results[1].modules.map(\.id) == [21] && results[1].name == "第二週")
        precondition(index.filter(sections, query: "swift 講義").map(\.id) == [2])
        precondition(index.filter(sections, query: "missing").isEmpty)
        precondition(index.filter(sections, query: "　\t").flatMap(\.modules).count == 4)
        print("PASS: matching section retains all modules; module match keeps title; AND and empty-resource query")

        let announcementRepo = MoodleAnnouncementsRepository()
        announcementRepo.result = try decode("""
        [{"id":1,"name":"公告","subject":"課程異動","message":"<p>Sw<b>if</b>t &amp; 教材</p>",
          "timemodified":0,"userfullname":"王老師","created":0}]
        """)
        let announcements = MoodleAnnouncementsViewModel(repository: announcementRepo)
        announcements.searchText = "王老師 swift"
        await announcements.load(courseId: 1)
        precondition(announcements.filteredDiscussions.map(\.id) == [1])
        announcements.searchText = "missing"
        precondition(announcements.filteredDiscussions.isEmpty && announcements.discussions.count == 1)
        announcements.searchText = " "
        precondition(announcements.filteredDiscussions.count == 1)

        let assignmentRepo = MoodleAssignmentsRepository()
        assignmentRepo.result = [300, 100, 0].enumerated().map { id, due in
            MoodleAssignment(id: id, cmid: id, course: 1, name: "作業", intro: "<p>Swift&nbsp;練習</p>",
                             duedate: due, allowsubmissionsfromdate: 0, grade: nil, timemodified: 0)
        }
        let assignments = MoodleAssignmentsListViewModel(repository: assignmentRepo)
        assignments.searchText = "作業 swift"
        await assignments.load(courseId: 1)
        precondition(assignments.filteredAssignments.map(\.id) == [1, 0, 2])
        assignments.setSortOrder(.dueLatestFirst)
        precondition(assignments.filteredAssignments.map(\.id) == [0, 1, 2])
        assignmentRepo.result = []
        await assignments.load(courseId: 1, force: true)
        precondition(assignments.filteredAssignments.isEmpty)

        let resourceRepo = ResourceRepository()
        resourceRepo.result = sections
        let resources = MoodleResourcesViewModel(repository: resourceRepo)
        resources.searchText = "swift"
        await resources.load(courseId: 1)
        precondition(resources.filteredSections.flatMap(\.modules).map(\.id) == [11, 12, 21])
        resources.searchText = " "
        precondition(resources.filteredSections.flatMap(\.modules).count == 4)

        let questionRepo = QuestionRepository()
        let modules: [MoodleModule] = try decode("""
        [{"id":1,"name":"期中測驗","description":"<p>Swift&nbsp;基礎</p>","modname":"quiz"}]
        """)
        questionRepo.result = [MoodleQuestionSection(id: 1, name: "第一週", modules: modules)]
        let questions = MoodleQuestionsViewModel(repository: questionRepo)
        questions.searchText = "測驗 swift"
        await questions.load(courseId: 1)
        precondition(questions.filteredSections.flatMap(\.modules).map(\.id) == [1])
        questions.searchText = "第一週"
        precondition(questions.filteredSections.isEmpty)
        questions.searchText = " "
        precondition(questions.filteredSections.count == 1)
        questionRepo.result = []
        questionRepo.sessionRevision += 1
        await questions.load(courseId: 1)
        precondition(questions.filteredSections.isEmpty)

        let gradeRepo = MoodleGradesRepository()
        gradeRepo.result = try decode("""
        [{"id":1,"itemname":"<b>期中</b>測驗","itemtype":"mod"}, {"id":2,"itemtype":"course"}]
        """)
        let grades = MoodleGradesViewModel(repository: gradeRepo)
        grades.searchText = "期中"
        await grades.load(courseId: 1)
        precondition(grades.filteredItems.map(\.id) == [1])
        grades.searchText = "課程總分"
        precondition(grades.filteredItems.map(\.id) == [2])
        grades.searchText = "　"
        precondition(grades.filteredItems.count == 2)

        let attendanceRepo = MoodleAttendanceRepository()
        NSTimeZone.default = TimeZone(identifier: "Asia/Taipei")!
        // HTML attendance rows without a time are parsed at local midnight.
        let date = Date(timeIntervalSince1970: 1_791_043_200) // 2026-10-04 00:00 Taipei
        attendanceRepo.result = (1...2).map { id in
            MoodleAttendanceSection(id: id, sectionName: "週次", moduleName: "點名冊", records: [
                MoodleAttendanceRecord(id: 1, date: date, timeText: "09:10–10:00", description: "<b>第\(id)節</b>",
                                       statusLabel: id == 1 ? "出席" : "缺席", scoreText: nil, remarks: nil,
                                       status: id == 1 ? .present : .absent)
            ], total: 10, source: .webService)
        }
        let attendance = MoodleAttendanceViewModel(repository: attendanceRepo)
        attendance.searchText = "第1節 出席 09:10"
        await attendance.loadCourse(1)
        precondition(attendance.filteredSections.map(\.id) == [1])
        precondition(attendance.sections[0].total == 10)
        attendance.searchText = "2026-10-04"
        precondition(attendance.filteredSections.count == 2)
        attendance.searchText = "2026-10-03"
        precondition(attendance.filteredSections.isEmpty)
        attendance.searchText = "第2節 缺席"
        precondition(attendance.filteredSections.map(\.id) == [2])
        attendance.searchText = "　"
        precondition(attendance.filteredSections.count == 2)
        print("PASS: all six ViewModels, query before load, refresh/session replacement, sort retention, attendance ID scoping")

        let pendingAnnouncements = PendingAnnouncements()
        let switchingAnnouncements = MoodleAnnouncementsViewModel(repository: pendingAnnouncements)
        let old = Task { await switchingAnnouncements.load(courseId: 1) }
        await pendingAnnouncements.waitFor(1)
        old.cancel()
        let current = Task { await switchingAnnouncements.load(courseId: 1, force: true) }
        await pendingAnnouncements.waitFor(2)
        pendingAnnouncements.pending[0].resume(returning: [])
        await old.value
        precondition(switchingAnnouncements.isLoading) // Old cancellation cannot hide the new spinner.
        pendingAnnouncements.pending[1].resume(returning: announcements.discussions)
        await current.value
        precondition(!switchingAnnouncements.discussions.isEmpty && !switchingAnnouncements.isLoading)
        let cancelledRefresh = Task { await switchingAnnouncements.load(courseId: 1, force: true) }
        await pendingAnnouncements.waitFor(3)
        cancelledRefresh.cancel()
        pendingAnnouncements.pending[2].resume(returning: [])
        await cancelledRefresh.value
        precondition(!switchingAnnouncements.discussions.isEmpty && !switchingAnnouncements.isLoading)

        let pendingAttendance = PendingAttendance()
        let switchingAttendance = MoodleAttendanceViewModel(repository: pendingAttendance)
        let previousVisit = Task { await switchingAttendance.loadCourse(1) }
        await pendingAttendance.waitFor(1)
        let latestVisit = Task { await switchingAttendance.loadCourse(1, force: true) }
        await pendingAttendance.waitFor(2)
        pendingAttendance.pending[1].resume(returning: attendanceRepo.result)
        await latestVisit.value
        pendingAttendance.pending[0].resume(throwing: URLError(.timedOut))
        await previousVisit.value
        precondition(switchingAttendance.sections.count == 2 && switchingAttendance.lastErrorMessage == nil)
        print("PASS: refresh/navigation cancels stale work, preserves cached results and keeps the latest loading/error state")

    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-moodle-search-") as directory:
    folder = Path(directory)
    checks = folder / "Checks.swift"
    checks.write_text(CHECKS + "\n" + MODELS)
    binary = folder / "checks"
    sources = ["Models/MoodleModels.swift", "Models/MoodleSearch.swift",
               "Questions/MoodleQuestionActivity.swift", "Attendance/MoodleAttendanceModels.swift"]
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
        "-module-cache-path", str(folder / "ModuleCache"),
        *[str(BASE / source) for source in sources], str(checks), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
