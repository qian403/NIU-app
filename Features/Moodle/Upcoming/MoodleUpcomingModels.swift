import Foundation

struct MoodleCalendarActionEvents: Codable {
    let events: [MoodleCalendarActionEvent]
    let lastid: Int?
}

struct MoodleCalendarActionEvent: Codable {
    struct Course: Codable { let id: Int }
    struct Action: Codable { let actionable: Bool; let url: String? }
    let id: Int
    let name: String
    let timesort: Int
    let modulename: String?
    let instance: Int?
    let course: Course?
    let action: Action?
    let url: String?
    let eventtype: String?
    var cmid: Int? = nil

    var courseModuleID: Int? {
        if let cmid, cmid > 0 { return cmid }
        // Retain only the module ID, never the calendar URL or its other query values.
        for raw in [url, action?.url].compactMap({ $0 }) {
            guard let components = URLComponents(string: raw),
                  components.path.hasSuffix("/mod/assign/view.php"),
                  let value = components.queryItems?.first(where: { $0.name == "id" })?.value,
                  let id = Int(value), id > 0 else { continue }
            return id
        }
        return nil
    }
}

/// Keep machine-readable codes, never server messages or credential-bearing URLs.
struct MoodleUpcomingAPIError: Error, Codable {
    let exception: String?
    let errorcode: String?

    var isCalendarUnavailable: Bool {
        let codes = ["accessexception", "servicenotavailable", "invalidrecord", "nopermissions",
                     "required_capability_exception", "webservice_access_exception", "functionnotavailable"]
        return [exception, errorcode].compactMap { $0?.lowercased() }.contains { codes.contains($0) }
    }
}

enum MoodleUpcomingError: Error {
    case incompleteResponse, assignmentNotFound
}

/// Owned by the authenticated client; reset when authentication generation changes.
@MainActor
final class MoodleCalendarCapability {
    var unavailable = false
    func reset() { unavailable = false }
}

extension Notification.Name {
    static let moodleSessionDidChange = Notification.Name("NIUMoodleSessionDidChange")
    static let moodleSubmissionDidChange = Notification.Name("NIUMoodleSubmissionDidChange")
}

/// Posted synchronously on the main actor after a confirmed status response.
struct MoodleSubmissionChange {
    let assignmentID: Int
    let courseID: Int
    let submitted: Bool
    let sessionRevision: Int
}

struct MoodleUpcomingItem: Identifiable, Equatable {
    let assignmentID: Int
    let courseID: Int
    let name: String
    let courseName: String
    let dueDate: Date
    var courseModuleID: Int? = nil
    var id: Int { assignmentID }
}

enum MoodleUpcomingGroup: String, CaseIterable {
    case overdue = "已逾期", today = "今天", thisWeek = "本週", later = "之後"
}

enum MoodleUpcomingRules {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .gmt
        calendar.locale = Locale(identifier: "zh_TW")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func window(now: Date) -> ClosedRange<Date> {
        now.addingTimeInterval(-7 * 86400)...now.addingTimeInterval(14 * 86400)
    }

    static func group(due: Date, now: Date) -> MoodleUpcomingGroup {
        if due < now { return .overdue }
        if calendar.isDate(due, inSameDayAs: now) { return .today }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), due < week.end { return .thisWeek }
        return .later
    }

    static func calendarItems(_ events: [MoodleCalendarActionEvent], courses: [MoodleCourse], now: Date, confirmedPending: Set<Int> = []) throws -> [MoodleUpcomingItem] {
        let courseNames = Dictionary(courses.map { ($0.id, $0.cleanName) }, uniquingKeysWith: { first, _ in first })
        var items: [Int: MoodleUpcomingItem] = [:]
        for event in events where event.modulename == "assign" && event.eventtype == "due" {
            guard let course = event.course, let courseName = courseNames[course.id] else { continue }
            // Missing action information must not silently become an empty list.
            guard let action = event.action else { throw MoodleUpcomingError.incompleteResponse }
            guard let assignmentID = event.instance, assignmentID > 0 else { throw MoodleUpcomingError.incompleteResponse }
            guard action.actionable || confirmedPending.contains(assignmentID) else { continue }
            let due = Date(timeIntervalSince1970: TimeInterval(event.timesort))
            guard window(now: now).contains(due) else { continue }
            let item = MoodleUpcomingItem(assignmentID: assignmentID, courseID: course.id,
                name: event.name.htmlDecoded, courseName: courseName, dueDate: due,
                courseModuleID: event.courseModuleID)
            if items[assignmentID].map({ due < $0.dueDate }) ?? true { items[assignmentID] = item }
        }
        return sorted(Array(items.values))
    }

    static func sorted(_ items: [MoodleUpcomingItem]) -> [MoodleUpcomingItem] {
        items.sorted { $0.dueDate == $1.dueDate ? $0.id < $1.id : $0.dueDate < $1.dueDate }
    }

    static func isSubmitted(_ status: MoodleSubmissionStatus) throws -> Bool {
        guard let attempt = status.lastattempt else { throw MoodleUpcomingError.incompleteResponse }
        let states = [attempt.submission?.status, attempt.teamsubmission?.status].compactMap { $0 }
        guard !states.isEmpty, states.allSatisfy({ ["new", "draft", "reopened", "submitted"].contains($0) }) else {
            throw MoodleUpcomingError.incompleteResponse
        }
        return states.contains("submitted")
    }
}

extension MoodlePresentation {
    static func upcomingDeadline(_ due: Date, now: Date, accessibility: Bool = false) -> String {
        let calendar = MoodleUpcomingRules.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = accessibility ? "ah:mm" : "HH:mm"
        let time = formatter.string(from: due)
        if due < now {
            if days == 0 { return "已逾期・今天 \(time)" }
            return accessibility ? "已逾期 \(-days) 天，\(time)" : "已逾期 \(-days) 天"
        }
        if days == 0 { return "今天 \(time)" }
        if days == 1 { return "明天 \(time)" }
        if accessibility {
            formatter.dateFormat = "M月d日 EEEE ah:mm"
            return formatter.string(from: due)
        }
        return "\(days) 天後"
    }
}

struct MoodleUpcomingAssignmentsResponse: Codable {
    struct Warning: Codable {
        let warningcode: String
        var item: String? = nil
        var itemid: Int? = nil
    }
    let courses: [MoodleAssignmentCourse]
    let warnings: [Warning]?

    /// `skippingInaccessibleCourses` accepts a missing course only when Moodle names it in a
    /// course warning (hidden or no longer enrolled); an unexplained omission stays an error.
    func assignments(courseIDs: [Int], skippingInaccessibleCourses: Bool = false) throws -> [MoodleAssignment] {
        let requested = Set(courseIDs)
        let matching = courses.filter { requested.contains($0.id) }
        let inaccessible = skippingInaccessibleCourses
            ? Set((warnings ?? []).compactMap { $0.item == "course" ? $0.itemid : nil }) : []
        let courseIDPresent = requested.subtracting(inaccessible).isSubset(of: Set(matching.map(\.id)))
        guard courseIDPresent,
              Set(matching.map(\.id)).count == matching.count,
              matching.allSatisfy({ course in course.assignments.allSatisfy { $0.course == course.id } }) else {
            throw MoodleUpcomingAssignmentResponseError(hasWarnings: warnings?.isEmpty == false,
                courseIDPresent: courseIDPresent, assignmentIDs: Set(courses.flatMap(\.assignments).map(\.id)))
        }
        // Warnings may concern unrelated permissions; validate the requested data itself.
        return matching.flatMap(\.assignments)
    }
}

struct MoodleUpcomingAssignmentResponseError: Error {
    let hasWarnings: Bool
    let courseIDPresent: Bool
    let assignmentIDs: Set<Int>
}
