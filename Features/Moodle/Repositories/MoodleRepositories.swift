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
    var sessionRevision: Int { get }
    func fetchForumDiscussions(forumId: Int, page: Int) async throws -> MoodleDiscussionsResponse
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
    /// Optional catalog entries, including semesters with no enrolled courses.
    var availableSemesters: [String] { get }

    func authenticate(username: String, password: String) async throws
    func fetchCourses() async throws -> [MoodleCourse]
}

extension MoodleCourseRepositoryProtocol {
    var availableSemesters: [String] { [] }
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
    func fetchCompleteAnnouncements(courseId: Int, cached: [MoodleDiscussion]) async throws -> [MoodleDiscussion]
    func fetchDiscussions(forumId: Int) async throws -> MoodleDiscussionsResponse
}

@MainActor
final class MoodleAnnouncementsRepository: MoodleAnnouncementsRepositoryProtocol {
    private let client: any MoodleForumAPIClientProtocol
    private struct Preview {
        let revision: Int
        let forumsWithMore: [Int]
    }
    private var previews: [Int: Preview] = [:]

    init(client: (any MoodleForumAPIClientProtocol)? = nil) {
        self.client = client ?? MoodleService.shared
    }

    func fetchAnnouncements(courseId: Int) async throws -> [MoodleDiscussion] {
        let revision = client.sessionRevision
        let forums = try await client.fetchForumsByCourse(courseId: courseId)
        let announcementForums = forums.filter { $0.type == "news" || $0.name.contains("公告") }
        let targets = announcementForums.isEmpty ? forums.filter { $0.type == "news" } : announcementForums

        var discussions: [MoodleDiscussion] = []
        var forumsWithMore: [Int] = []
        for forum in targets {
            let response = try await client.fetchForumDiscussions(forumId: forum.id)
            guard let consumed = response.consumedPageCount else { throw MoodleUpcomingError.incompleteResponse }
            discussions.append(contentsOf: response.discussions)
            if consumed >= 20 { forumsWithMore.append(forum.id) }
        }
        try Task.checkCancellation()
        guard revision == client.sessionRevision else { throw CancellationError() }
        previews[courseId] = Preview(revision: revision, forumsWithMore: forumsWithMore)
        return discussions
            .filter { !$0.plainMessage.contains("API 錯誤") }
            .sorted { $0.timemodified > $1.timemodified }
    }

    func fetchCompleteAnnouncements(courseId: Int, cached: [MoodleDiscussion]) async throws -> [MoodleDiscussion] {
        let initial: [MoodleDiscussion]
        if previews[courseId]?.revision == client.sessionRevision {
            initial = cached
        } else {
            initial = try await fetchAnnouncements(courseId: courseId)
        }
        guard let preview = previews[courseId] else { return initial }
        var discussions = Dictionary(initial.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for forumID in preview.forumsWithMore {
            var seenPages = Set<String>()
            // Bound malformed pagination; an incomplete result must remain an error.
            for page in 1...100 {
                try Task.checkCancellation()
                guard preview.revision == client.sessionRevision else { throw CancellationError() }
                let response = try await client.fetchForumDiscussions(forumId: forumID, page: page)
                try Task.checkCancellation()
                guard preview.revision == client.sessionRevision else { throw CancellationError() }
                guard let consumed = response.consumedPageCount,
                      seenPages.insert(response.pageFingerprint).inserted else {
                    throw MoodleUpcomingError.incompleteResponse
                }
                let newItems = response.discussions.filter { discussions[$0.id] == nil }
                for item in newItems { discussions[item.id] = item }
                if consumed < 20 { break }
                guard (!newItems.isEmpty || !(response.warnings ?? []).isEmpty), page < 100 else {
                    throw MoodleUpcomingError.incompleteResponse
                }
            }
        }
        return discussions.values.filter { !$0.plainMessage.contains("API 錯誤") }
            .sorted { $0.timemodified == $1.timemodified ? $0.id < $1.id : $0.timemodified > $1.timemodified }
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
        var statuses: [Int: Bool] = [:]
        for offset in stride(from: 0, to: assignments.count, by: 4) {
            try Task.checkCancellation()
            let batch = assignments[offset..<min(offset + 4, assignments.count)]
            let result = try await withThrowingTaskGroup(of: (Int, Bool?).self) { group in
                for assignment in batch {
                    let id = assignment.id
                    group.addTask { [self, id] in try await submissionStatus(for: id) }
                }
                var result: [Int: Bool] = [:]
                for try await (id, isSubmitted) in group { result[id] = isSubmitted }
                return result
            }
            statuses.merge(result) { _, new in new }
        }
        try Task.checkCancellation()
        return MoodleAssignmentsSnapshot(assignments: assignments, submittedStatus: statuses)
    }

    private func submissionStatus(for id: Int) async throws -> (Int, Bool?) {
        try Task.checkCancellation()
        do {
            let status = try await client.fetchSubmissionStatus(assignId: id)
            try Task.checkCancellation()
            return (id, try MoodleUpcomingRules.isSubmitted(status))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            // Missing role-specific status or a failed item must not hide the course list.
            return (id, nil)
        }
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

/// Shared dependencies follow navigation into detail screens without global overrides.
@MainActor
struct MoodleDetailRepositories {
    let announcements: any MoodleAnnouncementsRepositoryProtocol
    let assignments: any MoodleAssignmentsRepositoryProtocol
    let resources: any MoodleResourcesRepositoryProtocol
    let questions: any MoodleQuestionsRepositoryProtocol
    let attendance: any MoodleAttendanceRepositoryProtocol
    let grades: any MoodleGradesRepositoryProtocol
    let submission: any MoodleSubmissionRepositoryProtocol
    let posts: any MoodleDiscussionPostsRepositoryProtocol

    static var live: Self {
        Self(announcements: MoodleAnnouncementsRepository(), assignments: MoodleAssignmentsRepository(),
             resources: MoodleResourcesRepository(), questions: MoodleQuestionsRepository(client: MoodleService.shared),
             attendance: MoodleAttendanceRepository(), grades: MoodleGradesRepository(),
             submission: MoodleSubmissionRepository(), posts: MoodleDiscussionPostsRepository())
    }
}

@MainActor
protocol MoodleDiscussionPostsRepositoryProtocol {
    func fetchPosts(discussionId: Int) async throws -> [MoodlePost]
}

@MainActor
struct MoodleDiscussionPostsRepository: MoodleDiscussionPostsRepositoryProtocol {
    func fetchPosts(discussionId: Int) async throws -> [MoodlePost] {
        try await MoodleService.shared.fetchDiscussionPosts(discussionId: discussionId).posts
    }
}

@MainActor
protocol MoodleSubmissionRepositoryProtocol {
    var sessionRevision: Int { get }
    func webSubmissionURL(for assignment: MoodleAssignment) -> String?
    func fetchStatus(assignment: MoodleAssignment) async throws -> MoodleSubmissionStatus
    func fetchGrades(courseId: Int) async throws -> [MoodleGradeItem]
    func fileURL(for rawURL: String) -> URL?
    func clear(assignment: MoodleAssignment) async throws
    func submit(assignment: MoodleAssignment) async throws
    func upload(assignment: MoodleAssignment, localFileURL: URL) async throws
}

@MainActor
struct MoodleSubmissionRepository: MoodleSubmissionRepositoryProtocol {
    var sessionRevision: Int { MoodleService.shared.sessionRevision }
    func webSubmissionURL(for assignment: MoodleAssignment) -> String? {
        "https://euni.niu.edu.tw/mod/assign/view.php?id=\(assignment.cmid)&action=editsubmission"
    }
    func fetchStatus(assignment: MoodleAssignment) async throws -> MoodleSubmissionStatus {
        try await MoodleService.shared.fetchSubmissionStatus(assignId: assignment.id)
    }
    func fetchGrades(courseId: Int) async throws -> [MoodleGradeItem] {
        try await MoodleService.shared.fetchGradeItems(courseId: courseId)
    }
    func fileURL(for rawURL: String) -> URL? { MoodleService.shared.fileURL(for: rawURL) }
    func clear(assignment: MoodleAssignment) async throws {
        try await MoodleService.shared.clearAssignmentSubmission(assignId: assignment.id)
    }
    func submit(assignment: MoodleAssignment) async throws {
        try await MoodleService.shared.submitAssignmentForGrading(assignId: assignment.id, acceptSubmissionStatement: true)
    }
    func upload(assignment: MoodleAssignment, localFileURL: URL) async throws {
        _ = try await MoodleService.shared.uploadAssignmentSubmissionFile(
            assignId: assignment.id, assignmentCMID: assignment.cmid,
            assignmentCourseID: assignment.course, localFileURL: localFileURL)
    }
}
