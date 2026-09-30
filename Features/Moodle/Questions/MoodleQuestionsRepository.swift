import Foundation

@MainActor
protocol MoodleQuestionsAPIClientProtocol {
    var sessionRevision: Int { get }
    func fetchCourseContents(courseId: Int) async throws -> [MoodleCourseSection]
}

extension MoodleService: MoodleQuestionsAPIClientProtocol {}

@MainActor
protocol MoodleQuestionsRepositoryProtocol {
    var sessionRevision: Int { get }
    func fetchSections(courseId: Int) async throws -> [MoodleQuestionSection]
}

@MainActor
struct MoodleQuestionsRepository: MoodleQuestionsRepositoryProtocol {
    private let client: any MoodleQuestionsAPIClientProtocol

    init(client: any MoodleQuestionsAPIClientProtocol) {
        self.client = client
    }

    var sessionRevision: Int { client.sessionRevision }

    func fetchSections(courseId: Int) async throws -> [MoodleQuestionSection] {
        let revision = sessionRevision
        let contents = try await client.fetchCourseContents(courseId: courseId)
        try Task.checkCancellation()
        guard revision == sessionRevision else { throw CancellationError() }
        return MoodleQuestionSection.sections(from: contents)
    }
}
