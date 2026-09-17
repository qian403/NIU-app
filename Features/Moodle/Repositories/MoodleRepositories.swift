import Foundation

@MainActor
protocol MoodleSessionProviding {
    var isAuthenticated: Bool { get }
    func authenticate(username: String, password: String) async throws
}

@MainActor
protocol MoodleCourseListAPIClientProtocol: MoodleSessionProviding {
    func fetchCourses() async throws -> [MoodleCourse]
}

@MainActor
protocol MoodleForumAPIClientProtocol {
    func fetchForumsByCourse(courseId: Int) async throws -> [MoodleForum]
    func fetchForumDiscussions(forumId: Int) async throws -> MoodleDiscussionsResponse
}

@MainActor
protocol MoodleAssignmentAPIClientProtocol {
    func fetchAssignments(courseId: Int) async throws -> [MoodleAssignment]
    func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus
}

@MainActor
protocol MoodleResourceAPIClientProtocol {
    func fetchCourseContents(courseId: Int) async throws -> [MoodleCourseSection]
    func fetchPages(courseId: Int) async throws -> [MoodlePage]
    func fileURL(for rawURL: String) -> URL?
}

@MainActor
protocol MoodleGradeAPIClientProtocol {
    func fetchGradeItems(courseId: Int) async throws -> [MoodleGradeItem]
}

@MainActor
protocol MoodleAttendanceAPIClientProtocol {
    func fetchCourseContents(courseId: Int) async throws -> [MoodleCourseSection]
    func fetchAttendanceUserSessions(attendanceId: Int) async throws -> MoodleAttendanceUserSessionsResponse
    func fetchAttendanceFromHTML(attendanceId: Int?, courseModuleId: Int?) async throws -> MoodleAttendanceHTMLResult
    func resolveAttendanceInstanceId(courseModuleId: Int) async throws -> Int?
}

/// Complete transport façade supplied by `MoodleService`. Each repository uses
/// only the smaller capability protocol it needs, keeping test doubles small.
@MainActor
protocol MoodleAPIClientProtocol:
    MoodleCourseListAPIClientProtocol,
    MoodleForumAPIClientProtocol,
    MoodleAssignmentAPIClientProtocol,
    MoodleResourceAPIClientProtocol,
    MoodleGradeAPIClientProtocol,
    MoodleAttendanceAPIClientProtocol {}

extension MoodleService: MoodleAPIClientProtocol {}

/// Course-list boundary used by `MoodleViewModel`.
///
/// Keeping authentication behind this protocol lets previews and tests supply
/// deterministic course data without creating a real Moodle session.
@MainActor
protocol MoodleCourseRepositoryProtocol {
    var isAuthenticated: Bool { get }

    func authenticate(username: String, password: String) async throws
    func fetchCourses() async throws -> [MoodleCourse]
}

@MainActor
struct MoodleCourseRepository: MoodleCourseRepositoryProtocol {
    private let client: any MoodleCourseListAPIClientProtocol

    init(client: (any MoodleCourseListAPIClientProtocol)? = nil) {
        self.client = client ?? MoodleService.shared
    }

    var isAuthenticated: Bool { client.isAuthenticated }

    func authenticate(username: String, password: String) async throws {
        try await client.authenticate(username: username, password: password)
    }

    func fetchCourses() async throws -> [MoodleCourse] {
        try await client.fetchCourses()
    }
}

@MainActor
protocol MoodleAnnouncementsRepositoryProtocol {
    func fetchAnnouncements(courseId: Int) async throws -> [MoodleDiscussion]
    func fetchDiscussions(forumId: Int) async throws -> MoodleDiscussionsResponse
}

@MainActor
struct MoodleAnnouncementsRepository: MoodleAnnouncementsRepositoryProtocol {
    private let client: any MoodleForumAPIClientProtocol

    init(client: (any MoodleForumAPIClientProtocol)? = nil) {
        self.client = client ?? MoodleService.shared
    }

    func fetchAnnouncements(courseId: Int) async throws -> [MoodleDiscussion] {
        let forums = try await client.fetchForumsByCourse(courseId: courseId)
        let announcementForums = forums.filter { $0.type == "news" || $0.name.contains("公告") }
        let targets = announcementForums.isEmpty ? forums.filter { $0.type == "news" } : announcementForums

        var discussions: [MoodleDiscussion] = []
        for forum in targets {
            let response = try await client.fetchForumDiscussions(forumId: forum.id)
            discussions.append(contentsOf: response.discussions)
        }
        return discussions
            .filter { !$0.plainMessage.contains("API 錯誤") }
            .sorted { $0.timemodified > $1.timemodified }
    }

    func fetchDiscussions(forumId: Int) async throws -> MoodleDiscussionsResponse {
        try await client.fetchForumDiscussions(forumId: forumId)
    }
}

struct MoodleAssignmentsSnapshot {
    let assignments: [MoodleAssignment]
    let submittedStatus: [Int: Bool]
}

@MainActor
protocol MoodleAssignmentsRepositoryProtocol {
    func fetchAssignments(courseId: Int) async throws -> MoodleAssignmentsSnapshot
    func findAssignment(courseId: Int, module: MoodleModule) async throws -> MoodleAssignment?
}

@MainActor
struct MoodleAssignmentsRepository: MoodleAssignmentsRepositoryProtocol {
    private let client: any MoodleAssignmentAPIClientProtocol

    init(client: (any MoodleAssignmentAPIClientProtocol)? = nil) {
        self.client = client ?? MoodleService.shared
    }

    func fetchAssignments(courseId: Int) async throws -> MoodleAssignmentsSnapshot {
        let assignments = try await client.fetchAssignments(courseId: courseId)
            .sorted { lhs, rhs in
                if lhs.duedate == 0 { return false }
                if rhs.duedate == 0 { return true }
                return lhs.duedate > rhs.duedate
            }
        let statuses = await withTaskGroup(of: (Int, Bool).self) { group in
            for assignment in assignments {
                group.addTask { @MainActor [client] in
                    do {
                        let status = try await client.fetchSubmissionStatus(assignId: assignment.id)
                        return (assignment.id, status.lastattempt?.submission?.status == "submitted")
                    } catch {
                        return (assignment.id, false)
                    }
                }
            }
            var result: [Int: Bool] = [:]
            for await (id, isSubmitted) in group { result[id] = isSubmitted }
            return result
        }
        return MoodleAssignmentsSnapshot(assignments: assignments, submittedStatus: statuses)
    }

    func findAssignment(courseId: Int, module: MoodleModule) async throws -> MoodleAssignment? {
        let assignments = try await client.fetchAssignments(courseId: courseId)
        if let instance = module.instance,
           let assignment = assignments.first(where: { $0.id == instance }) {
            return assignment
        }
        return assignments.first(where: { $0.cmid == module.id }) ??
            assignments.first(where: { $0.name == module.name })
    }
}

@MainActor
protocol MoodleResourcesRepositoryProtocol {
    func fetchSections(courseId: Int) async throws -> [MoodleCourseSection]
    func fetchPages(courseId: Int) async throws -> [MoodlePage]
    func authenticatedFileURL(for rawURL: String) -> URL?
}

@MainActor
struct MoodleResourcesRepository: MoodleResourcesRepositoryProtocol {
    private let client: any MoodleResourceAPIClientProtocol

    init(client: (any MoodleResourceAPIClientProtocol)? = nil) {
        self.client = client ?? MoodleService.shared
    }

    func fetchSections(courseId: Int) async throws -> [MoodleCourseSection] {
        try await client.fetchCourseContents(courseId: courseId).filter { section in
            !section.modules.isEmpty && section.modules.contains { $0.modname != "label" }
        }
    }

    func fetchPages(courseId: Int) async throws -> [MoodlePage] {
        try await client.fetchPages(courseId: courseId)
    }

    func authenticatedFileURL(for rawURL: String) -> URL? {
        let rewritten = rawURL.contains("/pluginfile.php") &&
            !rawURL.contains("/webservice/pluginfile.php")
            ? rawURL.replacingOccurrences(of: "/pluginfile.php", with: "/webservice/pluginfile.php")
            : rawURL
        return client.fileURL(for: rewritten)
    }
}

@MainActor
protocol MoodleGradesRepositoryProtocol {
    func fetchGrades(courseId: Int) async throws -> [MoodleGradeItem]
}

@MainActor
struct MoodleGradesRepository: MoodleGradesRepositoryProtocol {
    private let client: any MoodleGradeAPIClientProtocol

    init(client: (any MoodleGradeAPIClientProtocol)? = nil) {
        self.client = client ?? MoodleService.shared
    }

    func fetchGrades(courseId: Int) async throws -> [MoodleGradeItem] {
        try await client.fetchGradeItems(courseId: courseId)
    }
}
