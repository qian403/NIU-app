import Foundation
#if DEBUG
import os
#endif

@MainActor
protocol MoodleUpcomingAPIClientProtocol {
    var sessionRevision: Int { get }
    var calendarCapability: MoodleCalendarCapability { get }
    func fetchActionEvents(from: Int, to: Int, after: Int, limit: Int) async throws -> MoodleCalendarActionEvents
    func fetchUpcomingAssignments(courseIDs: [Int]) async throws -> [MoodleAssignment]
    func fetchAssignments(courseId: Int) async throws -> [MoodleAssignment]
    func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus
}

extension MoodleService: MoodleUpcomingAPIClientProtocol {}

@MainActor
protocol MoodleUpcomingRepositoryProtocol {
    var sessionRevision: Int { get }
    func fetchUpcoming(courses: [MoodleCourse], now: Date) async throws -> [MoodleUpcomingItem]
    func resolveAssignment(_ item: MoodleUpcomingItem) async throws -> MoodleAssignment
}

@MainActor
struct MoodleUpcomingRepository: MoodleUpcomingRepositoryProtocol {
    private let client: any MoodleUpcomingAPIClientProtocol
    init(client: (any MoodleUpcomingAPIClientProtocol)? = nil) {
        self.client = client ?? MoodleService.shared
    }
    var sessionRevision: Int { client.sessionRevision }

    private func checkSession(_ revision: Int) throws {
        try Task.checkCancellation()
        guard revision == sessionRevision else { throw CancellationError() }
    }

    func fetchUpcoming(courses: [MoodleCourse], now: Date) async throws -> [MoodleUpcomingItem] {
        let revision = sessionRevision
        try checkSession(revision)
        guard !courses.isEmpty else { return [] }
        if !client.calendarCapability.unavailable {
            do {
                let window = MoodleUpcomingRules.window(now: now)
                var events: [MoodleCalendarActionEvent] = []
                var after = 0
                var cursors: Set<Int> = [0]
                // Moodle supports at most 50 events per page. Never silently truncate.
                for _ in 0..<100 {
                    let page = try await client.fetchActionEvents(from: Int(window.lowerBound.timeIntervalSince1970),
                        to: Int(window.upperBound.timeIntervalSince1970), after: after, limit: 50)
                    try checkSession(revision)
                    events += page.events
                    if page.events.isEmpty {
                        // actionable means "can edit", not "not submitted": unopened or closed
                        // assignments can be false. Confirm those with the submission API.
                        let courseIDs = Set(courses.map(\.id))
                        let nonActionable = Set(events.compactMap { event -> Int? in
                            guard event.modulename == "assign", event.eventtype != "gradingdue",
                                  event.action?.actionable == false,
                                  event.course.map({ courseIDs.contains($0.id) }) == true,
                                  window.contains(Date(timeIntervalSince1970: TimeInterval(event.timesort))) else { return nil }
                            return event.instance
                        })
                        let pending = try await pendingIDs(Array(nonActionable), revision: revision)
                        return try MoodleUpcomingRules.calendarItems(events, courses: courses, now: now, confirmedPending: pending)
                    }
                    guard let next = page.lastid, cursors.insert(next).inserted else {
                        throw MoodleUpcomingError.incompleteResponse
                    }
                    after = next
                }
                throw MoodleUpcomingError.incompleteResponse
            } catch let error as MoodleUpcomingAPIError where error.isCalendarUnavailable {
                try checkSession(revision)
                client.calendarCapability.unavailable = true
            }
        }
        return try await fallback(courses: courses, now: now, revision: revision)
    }

    private func fallback(courses: [MoodleCourse], now: Date, revision: Int) async throws -> [MoodleUpcomingItem] {
        let assignments = try await client.fetchUpcomingAssignments(courseIDs: courses.map(\.id))
        try checkSession(revision)
        let names = Dictionary(courses.map { ($0.id, $0.cleanName) }, uniquingKeysWith: { first, _ in first })
        let candidates = assignments.filter {
            names[$0.course] != nil && $0.dueDateValue.map { MoodleUpcomingRules.window(now: now).contains($0) } == true
        }
        let pending = try await pendingIDs(candidates.map(\.id), revision: revision)
        let items = candidates.compactMap { assignment -> MoodleUpcomingItem? in
            guard pending.contains(assignment.id), let due = assignment.dueDateValue else { return nil }
            return MoodleUpcomingItem(assignmentID: assignment.id, courseID: assignment.course,
                name: assignment.name.htmlDecoded, courseName: names[assignment.course] ?? "", dueDate: due,
                courseModuleID: assignment.cmid)
        }
        try checkSession(revision)
        return MoodleUpcomingRules.sorted(items)
    }

    private func pendingIDs(_ ids: [Int], revision: Int) async throws -> Set<Int> {
        var pending: Set<Int> = []
        // Structured batches bound status requests to four and propagate every error.
        for offset in stride(from: 0, to: ids.count, by: 4) {
            try checkSession(revision)
            let batch = ids[offset..<min(offset + 4, ids.count)]
            let result = try await withThrowingTaskGroup(of: Int?.self) { group in
                for id in batch {
                    group.addTask { @MainActor [client] in
                        try Task.checkCancellation()
                        guard revision == client.sessionRevision else { throw CancellationError() }
                        let status = try await client.fetchSubmissionStatus(assignId: id)
                        try Task.checkCancellation()
                        guard revision == client.sessionRevision else { throw CancellationError() }
                        return try MoodleUpcomingRules.isSubmitted(status) ? nil : id
                    }
                }
                var result: Set<Int> = []
                for try await id in group { if let id { result.insert(id) } }
                return result
            }
            pending.formUnion(result)
        }
        try checkSession(revision)
        return pending
    }

    func resolveAssignment(_ item: MoodleUpcomingItem) async throws -> MoodleAssignment {
        let revision = sessionRevision
        var courseIDPresent = false
        var assignmentIDPresent = false
        do {
            try checkSession(revision)
            let assignments = try await client.fetchAssignments(courseId: item.courseID)
            try checkSession(revision)
            // The single-course client validates the course container, including an empty course.
            courseIDPresent = true
            assignmentIDPresent = assignments.contains { $0.id == item.assignmentID }
            let candidates = assignments.filter { $0.course == item.courseID }
            if let assignment = candidates.first(where: { $0.id == item.assignmentID }) { return assignment }
            if let cmid = item.courseModuleID,
               let assignment = candidates.first(where: { $0.cmid == cmid }) { return assignment }
            throw MoodleUpcomingError.assignmentNotFound
        } catch {
            try checkSession(revision)
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            #if DEBUG
            if let response = error as? MoodleUpcomingAssignmentResponseError {
                courseIDPresent = response.courseIDPresent
                assignmentIDPresent = response.assignmentIDs.contains(item.assignmentID)
            }
            let category = Self.failureCategory(error)
            Self.logger.error("open failed: \(category, privacy: .public) assignmentIDPresent=\(assignmentIDPresent, privacy: .public) courseIDPresent=\(courseIDPresent, privacy: .public)")
            #endif
            throw error
        }
    }

    #if DEBUG
    private static let logger = Logger(subsystem: "dev.chienniuapp", category: "MoodleUpcoming")

    static func failureCategory(_ error: Error) -> String {
        if let response = error as? MoodleUpcomingAssignmentResponseError {
            return response.hasWarnings ? "incompleteResponse(warnings)" : "incompleteResponse"
        }
        if let error = error as? MoodleUpcomingError {
            switch error {
            case .assignmentNotFound: return "assignmentNotFound"
            case .incompleteResponse: return "incompleteResponse"
            }
        }
        if error is URLError { return "network" }
        if error is DecodingError { return "decodeFailed" }
        if let error = error as? MoodleError {
            switch error {
            case .notAuthenticated, .invalidToken, .authFailed: return "authentication"
            case .decodeFailed: return "decodeFailed"
            case .apiError: return "apiError"
            case .serverError: return "network"
            default: return "other"
            }
        }
        return "other"
    }
    #endif
}
