#!/usr/bin/env python3
"""Run production Codable, repository, presentation and ViewModel against isolated Swift doubles."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "Features/Moodle"
repositories = (BASE / "Repositories/MoodleRepositories.swift").read_text()
protocols = "\n".join(re.findall(r"@MainActor\nprotocol Moodle\w*RepositoryProtocol[^\n]*\{.*?\n\}", repositories, re.S))
extension = repositories[repositories.index("extension MoodleCourseRepositoryProtocol"):repositories.index("@MainActor\nstruct MoodleCourseRepository")]
snapshot = repositories[repositories.index("struct MoodleAssignmentsSnapshot"):repositories.index("@MainActor\nprotocol MoodleAssignmentsRepositoryProtocol")]
container = repositories[repositories.index("@MainActor\nstruct MoodleDetailRepositories"):repositories.index("    static var live:")] + "}\n"
attendance = (BASE / "Attendance/MoodleAttendanceRepository.swift").read_text().split("@MainActor\nstruct")[0]
questions = re.search(r"@MainActor\nprotocol MoodleQuestionsRepositoryProtocol.*?\n\}", (BASE / "Questions/MoodleQuestionsRepository.swift").read_text(), re.S)[0]
fixture = (BASE / "Fixtures/MoodleUIFixture.swift").read_text().split("@MainActor\nstruct MoodleUIFixtureRoot")[0] + "\n#endif\n"
service = (BASE / "Services/MoodleService.swift").read_text()
moodle_error = service[service.index("enum MoodleError: LocalizedError"):service.index("// MARK: - String Extension")]
checks = r'''
import Foundation
import Combine
struct MoodleQuestionSection { let id: Int; let name: String; let modules: [MoodleModule] }
@MainActor final class MoodleService {
    static var shared: MoodleService { fatalError("Live service must never be created") }
    var sessionRevision: Int { 0 }
    let calendarCapability = MoodleCalendarCapability()
    // PRODUCTION_CALENDAR_METHOD
    var responseData = Data()
    var functions: [String] = []
    var parameters: [[String: String]] = []
    private func callAPI<T: Decodable>(function: String, params: [String: String]) async throws -> T {
        functions.append(function); parameters.append(params)
        let data = responseData
        // PRODUCTION_ERROR_HANDLING
        return try JSONDecoder().decode(T.self, from: data)
    }
    // PRODUCTION_ASSIGNMENT_METHODS
    func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus {
        .init(lastattempt: .init(submission: .init(id: assignId, status: "draft", timemodified: nil, plugins: nil), graded: false))
    }
}
@MainActor final class Client: MoodleUpcomingAPIClientProtocol {
    var sessionRevision = 0
    let calendarCapability = MoodleCalendarCapability()
    var pages: [MoodleCalendarActionEvents] = []
    var assignments: [MoodleAssignment] = []
    var singleCourseCalls = 0
    var includeOtherCourses = false
    var calendarError: Error?
    var statusError: Error?
    var calendarCalls = 0
    var assignmentCalls = 0
    var requestedCourses: [Int] = []
    var cursors: [Int] = []
    var submitted: Set<Int> = []
    var unknownStatus: Set<Int> = []
    var statusIDs: [Int] = []
    var active = 0
    var peak = 0
    func fetchActionEvents(from: Int, to: Int, after: Int, limit: Int) async throws -> MoodleCalendarActionEvents {
        precondition(limit == 50 && to - from == 21 * 86400)
        calendarCalls += 1
        cursors.append(after)
        if let calendarError { throw calendarError }
        return pages.isEmpty ? .init(events: [], lastid: nil) : pages.removeFirst()
    }
    func fetchAssignments(courseId: Int) async throws -> [MoodleAssignment] {
        singleCourseCalls += 1
        return includeOtherCourses ? assignments : assignments.filter { $0.course == courseId }
    }
    func fetchUpcomingAssignments(courseIDs: [Int]) async throws -> [MoodleAssignment] {
        assignmentCalls += 1; requestedCourses = courseIDs
        return assignments
    }
    func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus {
        statusIDs.append(assignId); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        if let statusError { throw statusError }
        if unknownStatus.contains(assignId) { return .init(lastattempt: nil) }
        return .init(lastattempt: .init(submission: .init(id: assignId, status: submitted.contains(assignId) ? "submitted" : "draft", timemodified: nil, plugins: nil), graded: false))
    }
    func logout() {
        sessionRevision += 1; calendarCapability.reset()
        NotificationCenter.default.post(name: .moodleSessionDidChange, object: self)
    }
}
@MainActor final class DelayedRepository: MoodleUpcomingRepositoryProtocol {
    var sessionRevision = 0
    var cancelledReturns = 0
    var pending: [CheckedContinuation<[MoodleUpcomingItem], Error>] = []
    var opening: [CheckedContinuation<MoodleAssignment, Error>] = []
    func fetchUpcoming(courses: [MoodleCourse], now: Date) async throws -> [MoodleUpcomingItem] {
        let result = try await withCheckedThrowingContinuation { pending.append($0) }
        if Task.isCancelled { cancelledReturns += 1 }
        return result
    }
    func resolveAssignment(_ item: MoodleUpcomingItem) async throws -> MoodleAssignment {
        try await withCheckedThrowingContinuation { opening.append($0) }
    }
    func wait(_ count: Int, navigation: Bool = false) async {
        while (navigation ? opening.count : pending.count) < count { await Task.yield() }
    }
    func logout() {
        sessionRevision += 1
        NotificationCenter.default.post(name: .moodleSessionDidChange, object: self)
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let now = date("2026-10-05T12:00:00+08:00")
        let fixture = MoodleUIFixtureRepository()
        let courses = fixture.courses.filter { $0.semesterLabel == "115-1" }
        func event(_ id: Int, module: String = "assign", actionable: Bool = true, offset: Int = 3600, course: Int = 1, type: String = "due") throws -> MoodleCalendarActionEvent {
            let data = """
            {"id":\(id),"name":"作業 &amp; 練習","timesort":\(Int(now.timeIntervalSince1970) + offset),"modulename":"\(module)","instance":\(id),"course":{"id":\(course),"fullname":"課程"},"action":{"actionable":\(actionable),"url":"https://example.invalid/mod/assign/view.php?id=100"},"eventtype":"\(type)","unknown":"tolerated"}
            """
            return try JSONDecoder().decode(MoodleCalendarActionEvent.self, from: Data(data.utf8))
        }
        let events = try [event(1), event(2, module: "quiz"), event(3, actionable: false),
            event(4, offset: -7 * 86400), event(5, offset: 14 * 86400),
            event(6, offset: -7 * 86400 - 1), event(7, offset: 14 * 86400 + 1), event(8, course: 11), event(1)]
        let items = try MoodleUpcomingRules.calendarItems(events, courses: courses, now: now)
        precondition(items.map(\.id) == [4, 1, 5] && items[1].name == "作業 & 練習")
        let otherEvents = try [event(1, offset: 1, type: "expectcompletionon"),
            event(40, actionable: false, type: "expectcompletionon"), event(41, type: "gradingdue"),
            event(42, type: "unknown"), event(43, type: ""), event(44, module: "quiz"),
            MoodleCalendarActionEvent(id: 46, name: "無事件類別", timesort: Int(now.timeIntervalSince1970),
                modulename: "assign", instance: 46, course: .init(id: 1), action: nil, url: nil, eventtype: nil)]
        let onlyDue = try MoodleUpcomingRules.calendarItems(otherEvents + [event(1)], courses: courses, now: now)
        precondition(onlyDue.map(\.id) == [1] && onlyDue[0].dueDate == now.addingTimeInterval(3600))
        let dueClient = Client()
        dueClient.pages = [.init(events: otherEvents + [try event(45, actionable: false)], lastid: 45)]
        let dueItems = try await MoodleUpcomingRepository(client: dueClient).fetchUpcoming(courses: courses, now: now)
        precondition(dueItems.map(\.id) == [45] && dueClient.statusIDs == [45])
        print("PASS: assignment deadlines accept only due; completion/grading/unknown and other modules neither override deadlines nor trigger status requests")

        let response = try JSONDecoder().decode(MoodleCalendarActionEvents.self, from: Data("{\"events\":[],\"firstid\":null,\"lastid\":null,\"extra\":true}".utf8))
        precondition(response.events.isEmpty)
        let missing = MoodleCalendarActionEvent(id: 9, name: "missing", timesort: Int(now.timeIntervalSince1970), modulename: "assign", instance: 9, course: .init(id: 1), action: nil, url: nil, eventtype: "due")
        do { _ = try MoodleUpcomingRules.calendarItems([missing], courses: courses, now: now); fatalError("Missing action became empty") } catch MoodleUpcomingError.incompleteResponse {}
        print("PASS: Codable/unknown fields, assign/actionable/course filtering, deduplication and inclusive 7/14-day window")

        precondition(MoodleUpcomingRules.group(due: date("2026-10-05T11:59:59+08:00"), now: now) == .overdue)
        precondition(MoodleUpcomingRules.group(due: now, now: now) == .today)
        precondition(MoodleUpcomingRules.group(due: date("2026-10-11T23:59:59+08:00"), now: now) == .thisWeek)
        precondition(MoodleUpcomingRules.group(due: date("2026-10-12T00:00:00+08:00"), now: now) == .later)
        let sunday = date("2026-10-04T23:59:59+08:00")
        precondition(MoodleUpcomingRules.group(due: date("2026-10-05T00:00:00+08:00"), now: sunday) == .later)
        let deadlineCases = [("2026-10-05T23:59:00+08:00", "今天 23:59"), ("2026-10-06T18:00:00+08:00", "明天 18:00"), ("2026-10-08T18:00:00+08:00", "3 天後"), ("2026-10-03T18:00:00+08:00", "已逾期 2 天"), ("2026-10-05T11:00:00+08:00", "已逾期・今天 11:00")]
        for (value, text) in deadlineCases { precondition(MoodlePresentation.upcomingDeadline(date(value), now: now) == text) }
        precondition(MoodlePresentation.upcomingDeadline(date("2026-10-06T18:00:00+08:00"), now: now, accessibility: true) == "明天 下午6:00")
        precondition(MoodlePresentation.upcomingDeadline(date("2026-10-05T00:00:00+08:00"), now: sunday) == "明天 00:00")
        print("PASS: Asia/Taipei midnight, Monday week boundary, exact deadline and zh_TW visual/VoiceOver text (process TZ=UTC)")

        let client = Client()
        client.pages = [.init(events: [try event(1)], lastid: 1), .init(events: [try event(5)], lastid: 5), .init(events: [], lastid: nil)]
        let repo = MoodleUpcomingRepository(client: client)
        let paged = try await repo.fetchUpcoming(courses: courses, now: now)
        precondition(paged.count == 2 && client.cursors == [0, 1, 5] && client.assignmentCalls == 1)
        client.pages = [.init(events: [try event(1)], lastid: 1), .init(events: [try event(1)], lastid: 1)]
        do { _ = try await repo.fetchUpcoming(courses: courses, now: now); fatalError("Repeated cursor accepted") } catch MoodleUpcomingError.incompleteResponse {}
        client.pages = [.init(events: [try event(10, actionable: false), try event(11, actionable: false)], lastid: 11)]
        client.submitted = [11]
        let notEditable = try await repo.fetchUpcoming(courses: courses, now: now)
        precondition(notEditable.map(\.id) == [10])
        let hiddenIntro = try JSONDecoder().decode(MoodleUpcomingAssignmentsResponse.self, from: Data("{\"courses\":[{\"id\":1,\"assignments\":[{\"id\":1,\"cmid\":101,\"course\":1,\"name\":\"未開放說明\",\"duedate\":1791172800,\"allowsubmissionsfromdate\":1791172800,\"timemodified\":1791172800}]}],\"warnings\":[]}".utf8))
        precondition(hiddenIntro.courses[0].assignments[0].intro.isEmpty)

        let assignmentService = MoodleService()
        let serviceRepo = MoodleUpcomingRepository(client: assignmentService)
        for code in ["invalidtoken", "InvalidToken"] {
            assignmentService.responseData = Data("{\"exception\":\"moodle_exception\",\"errorcode\":\"\(code)\"}".utf8)
            do { _ = try await assignmentService.fetchActionEvents(from: 0, to: 1, after: 0, limit: 50); fatalError("Token error not mapped") }
            catch MoodleError.invalidToken {}
        }
        assignmentService.responseData = Data(#"{"exception":"webservice_access_exception","errorcode":"accessexception"}"#.utf8)
        do { _ = try await assignmentService.fetchActionEvents(from: 0, to: 1, after: 0, limit: 50); fatalError() }
        catch let error as MoodleUpcomingAPIError { precondition(error.isCalendarUnavailable) }
        assignmentService.functions = []; assignmentService.parameters = []
        print("PASS: production calendar API maps invalidtoken to authentication error and retains capability fallback")

        let warningResponse = MoodleUpcomingAssignmentsResponse(courses: hiddenIntro.courses,
            warnings: [.init(warningcode: "unrelated_permission")])
        assignmentService.responseData = try JSONEncoder().encode(warningResponse)
        let directItem = MoodleUpcomingItem(assignmentID: 1, courseID: 1, name: "", courseName: "", dueDate: now,
            courseModuleID: 999)
        let direct = try await serviceRepo.resolveAssignment(directItem)
        precondition(direct.id == 1) // ID wins even when calendar cmid differs.
        precondition(assignmentService.functions == ["mod_assign_get_assignments"])
        precondition(assignmentService.parameters == [["courseids[0]": "1"]])
        let warningAssignments = try await assignmentService.fetchUpcomingAssignments(courseIDs: [1])
        precondition(warningAssignments.map(\.id) == [1])
        assignmentService.calendarCapability.unavailable = true
        let warningFallback = try await serviceRepo.fetchUpcoming(courses: Array(courses.prefix(1)), now: now)
        precondition(warningFallback.map(\.id) == [1])

        var cmidEvent = try event(999)
        cmidEvent.cmid = 101
        let cmidItems = try MoodleUpcomingRules.calendarItems([cmidEvent], courses: courses, now: now)
        precondition(cmidItems[0].courseModuleID == 101)
        let byCMID = try await serviceRepo.resolveAssignment(cmidItems[0])
        precondition(byCMID.id == 1)
        let urlEventData = """
        {"id":998,"name":"","timesort":\(Int(now.timeIntervalSince1970)),"modulename":"assign","instance":998,"course":{"id":1},"action":{"actionable":true,"url":"https://example.invalid/moodle/mod/assign/view.php?id=101&ignored=synthetic"},"eventtype":"due"}
        """
        let urlEvent = try JSONDecoder().decode(MoodleCalendarActionEvent.self, from: Data(urlEventData.utf8))
        let urlItems = try MoodleUpcomingRules.calendarItems([urlEvent], courses: courses, now: now)
        let byURL = try await serviceRepo.resolveAssignment(urlItems[0])
        precondition(byURL.cmid == 101)
        let primaryClient = Client()
        primaryClient.assignments = hiddenIntro.courses[0].assignments + [
            .init(id: 2, cmid: 999, course: 1, name: "", intro: "", duedate: 0,
                  allowsubmissionsfromdate: 0, grade: nil, timemodified: 0)]
        let primaryAssignment = try await MoodleUpcomingRepository(client: primaryClient).resolveAssignment(directItem)
        precondition(primaryAssignment.id == 1 && primaryClient.singleCourseCalls == 1 && primaryClient.assignmentCalls == 0)
        primaryClient.includeOtherCourses = true
        primaryClient.assignments = [.init(id: 1, cmid: 999, course: 2, name: "", intro: "", duedate: 0,
            allowsubmissionsfromdate: 0, grade: nil, timemodified: 0)]
        do { _ = try await MoodleUpcomingRepository(client: primaryClient).resolveAssignment(directItem); fatalError("Cross-course ID/cmid accepted") }
        catch MoodleUpcomingError.assignmentNotFound {}
        let mismatchedCourse = MoodleAssignmentCourse(id: 1, assignments: primaryClient.assignments)
        for malformedCourses in [hiddenIntro.courses + hiddenIntro.courses, [mismatchedCourse]] {
            assignmentService.responseData = try JSONEncoder().encode(MoodleUpcomingAssignmentsResponse(
                courses: malformedCourses, warnings: warningResponse.warnings))
            do { _ = try await serviceRepo.resolveAssignment(directItem); fatalError("Inconsistent course container accepted") }
            catch let error as MoodleUpcomingAssignmentResponseError {
                precondition(error.courseIDPresent && error.hasWarnings)
            }
        }
        assignmentService.responseData = try JSONEncoder().encode(warningResponse)
        let missingItem = MoodleUpcomingItem(assignmentID: 999, courseID: 1, name: "", courseName: "", dueDate: now)
        do { _ = try await serviceRepo.resolveAssignment(missingItem); fatalError("Missing assignment opened") }
        catch MoodleUpcomingError.assignmentNotFound {}
        for warnings in [[], warningResponse.warnings!] {
            assignmentService.responseData = try JSONEncoder().encode(MoodleUpcomingAssignmentsResponse(
                courses: [], warnings: warnings))
            do { _ = try await serviceRepo.resolveAssignment(directItem); fatalError("Missing course accepted") }
            catch let error as MoodleUpcomingAssignmentResponseError {
                precondition(!error.courseIDPresent && error.hasWarnings == !warnings.isEmpty)
            }
            do { _ = try await assignmentService.fetchUpcomingAssignments(courseIDs: [1]); fatalError("Missing fallback course accepted") }
            catch is MoodleUpcomingAssignmentResponseError {}
        }
        assignmentService.responseData = try JSONEncoder().encode(MoodleUpcomingAssignmentsResponse(
            courses: [.init(id: 1, assignments: [])], warnings: warningResponse.warnings))
        do { _ = try await serviceRepo.resolveAssignment(directItem); fatalError("Empty course opened") }
        catch MoodleUpcomingError.assignmentNotFound {}
        assignmentService.responseData = Data("{\"courses\":[{\"id\":1}],\"warnings\":[]}".utf8)
        do { _ = try await serviceRepo.resolveAssignment(directItem); fatalError("Malformed response accepted") }
        catch is DecodingError {}
        precondition(MoodleUpcomingViewModel.openingErrorMessage(MoodleUpcomingError.assignmentNotFound) == "這份作業可能已被移除或尚未開放")
        for error in [MoodleError.notAuthenticated, .invalidToken, .serverError] {
            precondition(MoodleUpcomingViewModel.openingErrorMessage(error) == error.localizedDescription)
        }
        let networkError = URLError(.notConnectedToInternet)
        precondition(MoodleUpcomingViewModel.openingErrorMessage(networkError) == networkError.localizedDescription)
        precondition(MoodleUpcomingRepository.failureCategory(MoodleError.apiError("private message")) == "apiError")
        precondition(MoodleUpcomingRepository.failureCategory(MoodleError.decodeFailed("private message")) == "decodeFailed")
        precondition(MoodleUpcomingRepository.failureCategory(networkError) == "network")
        print("PASS: production single/bulk service warnings, missing course, malformed data, ID priority, explicit/URL cmid fallback and safe error classification")
        print("PASS: non-actionable pending vs submitted, optional assignment intro")
        print("PASS: lastid pagination including short pages, repeated-cursor failure instead of partial success")

        let fallbackClient = Client()
        let fixtureClient = MoodleUIFixtureUpcomingClient(repository: fixture)
        precondition(MoodleUIFixtureUpcomingClient.referenceDate == now)
        fallbackClient.assignments = fixtureClient.assignments
        for (id, course, due) in [(900, 1, 0), (901, 1, Int(now.timeIntervalSince1970) - 8 * 86400),
                                  (902, 1, Int(now.timeIntervalSince1970) + 15 * 86400),
                                  (903, 11, Int(now.timeIntervalSince1970) + 3600)] {
            fallbackClient.assignments.append(.init(id: id, cmid: id, course: course, name: "排除", intro: "",
                duedate: due, allowsubmissionsfromdate: 0, grade: nil, timemodified: 0))
        }
        fallbackClient.calendarError = MoodleUpcomingAPIError(exception: "webservice_access_exception", errorcode: "accessexception")
        fallbackClient.submitted = [801, 802]
        let fallbackRepo = MoodleUpcomingRepository(client: fallbackClient)
        let pending = try await fallbackRepo.fetchUpcoming(courses: courses, now: now)
        precondition(pending.count == 5 && !pending.contains(where: { [801, 802].contains($0.id) }))
        precondition(fallbackClient.peak == 4 && fallbackClient.requestedCourses == courses.map(\.id))
        precondition(Set(fallbackClient.statusIDs) == Set(800...806))
        _ = try await fallbackRepo.fetchUpcoming(courses: courses, now: now)
        precondition(fallbackClient.calendarCalls == 1)
        fallbackClient.statusError = URLError(.notConnectedToInternet)
        do { _ = try await fallbackRepo.fetchUpcoming(courses: courses, now: now); fatalError("Network error became empty") } catch is URLError {}
        fallbackClient.logout()
        precondition(!fallbackClient.calendarCapability.unavailable)
        fallbackClient.statusError = nil
        _ = try await fallbackRepo.fetchUpcoming(courses: courses, now: now)
        precondition(fallbackClient.calendarCalls == 2)
        let transportFailure = Client()
        transportFailure.calendarError = URLError(.timedOut)
        do { _ = try await MoodleUpcomingRepository(client: transportFailure).fetchUpcoming(courses: courses, now: now); fatalError() } catch is URLError {}
        precondition(transportFailure.assignmentCalls == 0 && !transportFailure.calendarCapability.unavailable)
        for code in ["accessexception", "servicenotavailable", "invalidrecord", "nopermissions"] {
            precondition(MoodleUpcomingAPIError(exception: "moodle_exception", errorcode: code).isCalendarUnavailable)
        }
        precondition(!MoodleUpcomingAPIError(exception: "moodle_exception", errorcode: "invalidtoken").isCalendarUnavailable)
        let team = try JSONDecoder().decode(MoodleSubmissionStatus.self, from: Data("{\"lastattempt\":{\"submission\":null,\"teamsubmission\":{\"status\":\"submitted\"}}}".utf8))
        let teamSubmitted = try MoodleUpcomingRules.isSubmitted(team)
        precondition(teamSubmitted)
        do { _ = try MoodleUpcomingRules.isSubmitted(.init(lastattempt: nil)); fatalError("Unknown status became pending") } catch MoodleUpcomingError.incompleteResponse {}
        print("PASS: unavailable fallback cached once/session, reset on logout, bulk course request, concurrency=4, individual/team submission exclusion, failures stay failures")

        func assignment(_ id: Int, course: Int = 1, offset: Int = 3600) -> MoodleAssignment {
            .init(id: id, cmid: 1000 + id, course: course, name: "作業 \(id)", intro: "",
                  duedate: Int(now.timeIntervalSince1970) + offset, allowsubmissionsfromdate: 0, grade: nil, timemodified: 0)
        }
        let omittedClient = Client()
        omittedClient.pages = [.init(events: [try event(1)], lastid: 1)]
        // 20: completion hid it but nothing submitted; 21: submitted; 22: outside window;
        // 23: course not in the semester; 24: no attempt for this user.
        omittedClient.assignments = [assignment(1), assignment(20, offset: 7200), assignment(21),
            assignment(22, offset: 15 * 86400), assignment(23, course: 11), assignment(24)]
        omittedClient.submitted = [21]
        omittedClient.unknownStatus = [24]
        let recovered = try await MoodleUpcomingRepository(client: omittedClient).fetchUpcoming(courses: courses, now: now)
        precondition(recovered.map(\.id) == [1, 20] && recovered[1].courseModuleID == 1020)
        precondition(Set(omittedClient.statusIDs) == [20, 21, 24] && omittedClient.requestedCourses == courses.map(\.id))
        omittedClient.pages = [.init(events: [try event(1)], lastid: 1)]
        omittedClient.statusError = URLError(.notConnectedToInternet)
        do { _ = try await MoodleUpcomingRepository(client: omittedClient).fetchUpcoming(courses: courses, now: now); fatalError("Status failure hidden") } catch is URLError {}
        let unknownFallback = Client()
        unknownFallback.calendarError = MoodleUpcomingAPIError(exception: "webservice_access_exception", errorcode: "accessexception")
        unknownFallback.assignments = [assignment(24)]
        unknownFallback.unknownStatus = [24]
        do { _ = try await MoodleUpcomingRepository(client: unknownFallback).fetchUpcoming(courses: courses, now: now); fatalError("Unknown fallback status became empty") } catch MoodleUpcomingError.incompleteResponse {}
        let hiddenCourse = MoodleUpcomingAssignmentsResponse(courses: [.init(id: 1, assignments: [assignment(1)])],
            warnings: [.init(warningcode: "1", item: "course", itemid: 2)])
        assignmentService.responseData = try JSONEncoder().encode(hiddenCourse)
        let visibleOnly = try await assignmentService.fetchUpcomingAssignments(courseIDs: [1, 2])
        precondition(visibleOnly.map(\.id) == [1])
        do { _ = try await assignmentService.fetchUpcomingAssignments(courseIDs: [1, 3]); fatalError("Unexplained missing course accepted") }
        catch is MoodleUpcomingAssignmentResponseError {}
        do { _ = try hiddenCourse.assignments(courseIDs: [1, 2]); fatalError("Single-course strictness relaxed") }
        catch is MoodleUpcomingAssignmentResponseError {}
        print("PASS: timeline-omitted (completion-hidden) unsubmitted assignments recovered; submitted/out-of-window/other-course excluded; unknown attempt skipped only for recovery; course warnings tolerated only when named")

        let delayed = DelayedRepository()
        let model = MoodleUpcomingViewModel(repository: delayed, clock: { now })
        let first = Task { await model.load(courses: courses) }
        await delayed.wait(1)
        let second = Task { await model.load(courses: Array(courses.prefix(1))) }
        await delayed.wait(2)
        delayed.pending[1].resume(returning: items)
        await second.value
        delayed.pending[0].resume(returning: [])
        await first.value
        precondition(model.items == items && model.preview(limit: 2).count == 2 && model.grouped.count == 3)
        await model.loadIfNeeded(courses: Array(courses.prefix(1)))
        precondition(delayed.pending.count == 2 && model.items == items)
        let refresh = Task { await model.reload() }
        await delayed.wait(3)
        precondition(model.items == items) // No skeleton while refreshing cached data.
        let newer = Task { await model.reload() }
        await delayed.wait(4)
        delayed.pending[3].resume(returning: [])
        await newer.value
        delayed.pending[2].resume(throwing: URLError(.timedOut))
        await refresh.value
        precondition(model.state == .empty)
        let failure = Task { await model.reload() }
        await delayed.wait(5)
        delayed.pending[4].resume(throwing: URLError(.notConnectedToInternet))
        await failure.value
        if case .failed = model.state {} else { fatalError("Failure became empty") }
        let loggingOut = Task { await model.reload() }
        await delayed.wait(6)
        delayed.logout()
        delayed.pending[5].resume(returning: items)
        await loggingOut.value
        precondition(model.items.isEmpty && model.state == .loading)
        let cancelled = Task { await model.load(courses: courses) }
        await delayed.wait(7)
        cancelled.cancel()
        delayed.pending[6].resume(returning: items)
        await cancelled.value
        precondition(model.items.isEmpty)
        print("PASS: semester switch, overlapping refresh, failed vs empty, logout clearing and parent cancellation discard stale results")

        let reentryRepo = DelayedRepository()
        let reentryModel = MoodleUpcomingViewModel(repository: reentryRepo, clock: { now })
        let disappearing = Task { await reentryModel.loadIfNeeded(courses: courses) }
        await reentryRepo.wait(1)
        disappearing.cancel()
        let reappearing = Task { await reentryModel.loadIfNeeded(courses: courses) }
        for _ in 0..<20 { await Task.yield() }
        reentryRepo.pending[0].resume(returning: [])
        await reentryRepo.wait(2)
        reentryRepo.pending[1].resume(returning: items)
        await disappearing.value; await reappearing.value
        precondition(reentryModel.items == items && reentryRepo.pending.count == 2)
        print("PASS: reappearance during cancelled load retries once and leaves loading state")

        let submissionRepo = DelayedRepository()
        let submissionModel = MoodleUpcomingViewModel(repository: submissionRepo, clock: { now })
        let initialSubmission = Task { await submissionModel.load(courses: courses) }
        await submissionRepo.wait(1)
        submissionRepo.pending[0].resume(returning: items)
        await initialSubmission.value
        submissionModel.assignment = fixtureClient.assignments[0]
        func notifySubmission(_ submitted: Bool, revision: Int = 0, courseID: Int? = nil) {
            NotificationCenter.default.post(name: .moodleSubmissionDidChange, object: MoodleSubmissionChange(
                assignmentID: items[0].assignmentID, courseID: courseID ?? courses[0].id,
                submitted: submitted, sessionRevision: revision))
        }
        notifySubmission(true, revision: -1)
        notifySubmission(true, courseID: -1)
        for _ in 0..<20 { await Task.yield() }
        precondition(submissionRepo.pending.count == 1 && submissionModel.items == items)
        notifySubmission(true)
        precondition(submissionModel.items == Array(items.dropFirst())) // Synchronous removal, no skeleton.
        await submissionRepo.wait(2)
        precondition(!submissionModel.items.contains { $0.id == items[0].id })
        precondition(submissionModel.assignment != nil) // Refresh must not pop the detail.
        submissionRepo.pending[1].resume(returning: Array(items.dropFirst()))
        for _ in 0..<30 { await Task.yield() }
        notifySubmission(false)
        await submissionRepo.wait(3)
        submissionRepo.pending[2].resume(returning: items)
        while submissionModel.items != items { await Task.yield() }
        let failedRefresh = Task { await submissionModel.reload() }
        await submissionRepo.wait(4)
        precondition(submissionModel.items == items)
        submissionRepo.pending[3].resume(throwing: URLError(.timedOut))
        await failedRefresh.value
        precondition(submissionModel.items == items && submissionModel.refreshError != nil)
        print("PASS: cross-entry submit/undo notification refreshes once without skeleton or dismissing detail; stale-session/unrelated-course signals ignored; failure preserves rows")

        submissionModel.assignment = nil
        submissionModel.open(items[0], owner: UUID())
        await submissionRepo.wait(1, navigation: true)
        let refreshWhileOpening = Task { await submissionModel.reload() }
        await submissionRepo.wait(5)
        precondition(submissionModel.openingID == nil)
        submissionRepo.opening[0].resume(returning: fixtureClient.assignments[0])
        submissionRepo.pending[4].resume(returning: items)
        await refreshWhileOpening.value
        precondition(submissionModel.assignment == nil && submissionModel.openingID == nil)
        print("PASS: refresh cancels in-flight detail resolution and clears opening indicator")

        notifySubmission(true)
        await submissionRepo.wait(6)
        notifySubmission(false)
        await submissionRepo.wait(7)
        submissionRepo.pending[6].resume(returning: items)
        while submissionModel.items != items { await Task.yield() }
        submissionRepo.pending[5].resume(returning: [])
        while submissionRepo.cancelledReturns < 1 { await Task.yield() }
        precondition(submissionModel.items == items)
        notifySubmission(true)
        await submissionRepo.wait(8)
        submissionRepo.logout()
        notifySubmission(true)
        submissionRepo.pending[7].resume(returning: items)
        while submissionRepo.cancelledReturns < 2 { await Task.yield() }
        precondition(submissionModel.state == .loading && submissionRepo.pending.count == 8)
        print("PASS: replacement notification fences old responses; session reset cancels notification refresh and rejects late results/signals")

        let lifetimeRepo = DelayedRepository()
        var lifetimeModel: MoodleUpcomingViewModel? = MoodleUpcomingViewModel(repository: lifetimeRepo, clock: { now })
        weak let releasedModel = lifetimeModel
        let lifetimeLoad = Task { await lifetimeModel?.load(courses: courses) }
        await lifetimeRepo.wait(1)
        lifetimeRepo.pending[0].resume(returning: items)
        await lifetimeLoad.value
        notifySubmission(true)
        await lifetimeRepo.wait(2)
        lifetimeModel = nil
        precondition(releasedModel == nil)
        lifetimeRepo.pending[1].resume(returning: items)
        while lifetimeRepo.cancelledReturns < 1 { await Task.yield() }
        notifySubmission(false)
        for _ in 0..<20 { await Task.yield() }
        precondition(lifetimeRepo.pending.count == 2)
        print("PASS: deinit releases notification observer and cancels in-flight submission refresh")

        let owner = UUID()
        model.open(items[0], owner: owner)
        await delayed.wait(1, navigation: true)
        model.open(items[1], owner: owner)
        await delayed.wait(2, navigation: true)
        delayed.opening[1].resume(returning: fixtureClient.assignments[1])
        while model.openingID != nil { await Task.yield() }
        delayed.opening[0].resume(returning: fixtureClient.assignments[0])
        for _ in 0..<20 { await Task.yield() }
        precondition(model.assignment?.id == 801)
        model.assignment = nil
        model.open(items[0], owner: owner)
        await delayed.wait(3, navigation: true)
        delayed.opening[2].resume(throwing: MoodleUpcomingError.assignmentNotFound)
        while model.openingID != nil { await Task.yield() }
        precondition(model.assignment == nil && model.navigationError == "這份作業可能已被移除或尚未開放")
        model.open(items[0], owner: owner)
        await delayed.wait(4, navigation: true)
        delayed.logout()
        delayed.opening[3].resume(returning: fixtureClient.assignments[0])
        for _ in 0..<20 { await Task.yield() }
        precondition(model.assignment == nil && model.navigationError == nil)
        print("PASS: detail resolution before navigation, superseded taps, failed resolution and logout during navigation")

        for unavailable in [false, true] {
            let fixtureClient = MoodleUIFixtureUpcomingClient(repository: fixture, calendarUnavailable: unavailable)
            precondition(fixtureClient.assignmentResponse(courseIDs: courses.map(\.id)).warnings?.count == 1)
            let fixtureRepo = MoodleUpcomingRepository(client: fixtureClient)
            let fixtureModel = MoodleUpcomingViewModel(repository: fixtureRepo, clock: { now })
            await fixtureModel.load(courses: courses)
            precondition(fixtureModel.items.count == 7 && fixtureModel.preview().count == 5)
            precondition(fixtureModel.grouped.map { $0.items.count } == [1, 1, 3, 2])
            precondition((fixtureClient.statusCalls == 7) == unavailable)
            let assignment = try await fixtureRepo.resolveAssignment(fixtureModel.items[0])
            precondition(assignment.id == 800)
        }
        let emptyClient = MoodleUIFixtureUpcomingClient(repository: fixture, empty: true)
        let emptyModel = MoodleUpcomingViewModel(repository: MoodleUpcomingRepository(client: emptyClient), clock: { now })
        await emptyModel.load(courses: courses)
        precondition(emptyModel.state == .empty)
        let errorClient = MoodleUIFixtureUpcomingClient(repository: fixture, failNext: true)
        let errorModel = MoodleUpcomingViewModel(repository: MoodleUpcomingRepository(client: errorClient), clock: { now })
        await errorModel.load(courses: courses)
        if case .failed = errorModel.state {} else { fatalError() }
        await errorModel.reload()
        precondition(errorModel.items.count == 7)
        print("PASS: DEBUG calendar/fallback fixtures, seven items/four groups, empty, error/retry and detail resolution without network/Keychain")
    }
}
'''
assignment_methods = "\n".join(re.search(r"    func " + name + r"\(.*?\n    \}", service, re.S)[0]
                               for name in ["fetchAssignments", "fetchUpcomingAssignments"])
checks = checks.replace("    // PRODUCTION_ASSIGNMENT_METHODS", assignment_methods)
calendar_method = re.search(r"    func fetchActionEvents\(.*?\n    \}", service, re.S)[0]
error_handling = service[service.index('        if function == "core_calendar_get_action_events_by_timesort"'):service.index('        do {\n            return try JSONDecoder().decode(T.self, from: data)')]
checks = checks.replace("    // PRODUCTION_CALENDAR_METHOD", calendar_method)
checks = checks.replace("        // PRODUCTION_ERROR_HANDLING", error_handling)

with tempfile.TemporaryDirectory(prefix="niu-moodle-upcoming-") as directory:
    folder = Path(directory)
    source = folder / "Checks.swift"
    source.write_text("\n".join([checks, moodle_error, protocols, extension, snapshot, container, attendance, questions, fixture]))
    binary = folder / "checks"
    subprocess.run(["xcrun", "swiftc", "-D", "DEBUG", "-parse-as-library", "-swift-version", "5",
                    "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
                    "-module-cache-path", str(folder / "ModuleCache"),
                    str(BASE / "Models/MoodleModels.swift"), str(BASE / "Attendance/MoodleAttendanceModels.swift"),
                    *[str(BASE / "Upcoming" / name) for name in ["MoodleUpcomingModels.swift", "MoodleUpcomingRepository.swift", "MoodleUpcomingViewModel.swift"]],
                    str(source), "-o", str(binary)], check=True)
    import os
    subprocess.run([str(binary), "-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
                   env={**os.environ, "TZ": "UTC"}, check=True, timeout=30)

service = (BASE / "Services/MoodleService.swift").read_text()
for name in ["authenticate(username:", "logout()"]:
    section = service[service.index("func " + name):].split("\n    }", 1)[0]
    assert "calendarCapability.reset()" in section and ".moodleSessionDidChange" in section
assert 'function: "core_calendar_get_action_events_by_timesort"' in service
assert 'params: params' in service and 'response.warnings?.isEmpty != false' not in service
view = (BASE / "Upcoming/MoodleUpcomingViews.swift").read_text()
assert 'model.submissionDidChange(' not in view, 'Notification is the only upcoming refresh path'
assignment_view = (BASE / 'Views/MoodleAssignmentView.swift').read_text()
assert 'NotificationCenter.default.post(name: .moodleSubmissionDidChange' in assignment_view
assert 'repository.sessionRevision == sessionRevision' in assignment_view
assert 'model.preview(limit: 5)' in view and 'model.items.count > 5' in view
assert '.redacted(reason: .placeholder)' in view and '.accessibilityElement(children: .ignore)' in view
assert 'dynamicTypeSize > .large' in view and 'minHeight: 44' in view
row = view.split('struct MoodleUpcomingRow: View {', 1)[1].split('struct MoodleUpcomingNavigation:', 1)[0]
assert 'ViewThatFits' not in row, 'Deadline placement must not depend on individual row content width'
assert view.count('MoodleUpcomingRow(item:') == 2, 'Home and full list must share the row'
assert 'Text(item.name).font(.headline).lineLimit(2)' in row
metadata = row.split('metadataLayout {', 1)[1].split('.font(.subheadline)', 1)[0]
assert metadata.index('deadline') < metadata.index('Text("·")') < metadata.index('Text(item.courseName)')
assert '.lineLimit(1)' in metadata and '.foregroundStyle(.secondary)' in metadata
assert 'AnyLayout(VStackLayout(alignment: .leading' in row and 'AnyLayout(HStackLayout(alignment: .firstTextBaseline' in row
deadline = row.split('private var deadline: some View {', 1)[1].split('var body:', 1)[0]
assert '.lineLimit(nil)' in deadline and '.fixedSize(horizontal: false, vertical: true)' in deadline and '.layoutPriority(1)' in deadline
assert '"exclamationmark.circle" : "clock"' in deadline and 'Color.red : Color.orange' in deadline and 'Color.secondary' in deadline
assert r'.accessibilityLabel("\(item.name)，\(showsCourseName ? item.courseName + "，" : "")截止：\(MoodlePresentation.upcomingDeadline(item.dueDate, now: now, accessibility: true))")' in row
home = (BASE / "Views/MoodleView.swift").read_text()
assert home.index('semesterSection\n') < home.index('MoodleUpcomingSection(') < home.index('switch viewModel.contentState')
fixture_source = (BASE / "Fixtures/MoodleUIFixture.swift").read_text()
assert fixture_source.startswith('#if DEBUG') and fixture_source.rstrip().endswith('#endif')
for flag in ['-NIUMoodleUIFixtureCalendarUnavailable', '"upcoming"', '"home-upcoming-empty"', '"home-upcoming-error"']:
    assert flag in fixture_source
print("PASS: production session reset, secure transport, warnings, home placement, accessibility and DEBUG fixture wiring")
