import Combine
import Foundation

@MainActor
final class MoodleAttendanceViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var sections: [MoodleAttendanceSection] = []
    @Published private(set) var lastErrorMessage: String?

    private let repository: any MoodleAttendanceRepositoryProtocol
    private var hasLoaded = false

    init(repository: (any MoodleAttendanceRepositoryProtocol)? = nil) {
        self.repository = repository ?? MoodleAttendanceRepository()
    }

    func loadCourse(_ courseId: Int, force: Bool = false) async {
        await load(force: force) {
            try await repository.fetchCourseAttendance(courseId: courseId)
        }
    }

    func loadModule(
        _ module: MoodleModule,
        attendanceId: Int?,
        courseModuleId: Int?,
        force: Bool = false
    ) async {
        await load(force: force) {
            let section = try await repository.fetchAttendance(
                module: module,
                sectionName: "",
                attendanceId: attendanceId,
                courseModuleId: courseModuleId
            )
            return [section]
        }
    }

    private func load(
        force: Bool,
        operation: () async throws -> [MoodleAttendanceSection]
    ) async {
        guard force || !hasLoaded else { return }

        state = .loading
        lastErrorMessage = nil

        do {
            sections = try await operation()
            hasLoaded = true
            state = .loaded
        } catch is CancellationError {
            state = sections.isEmpty ? .idle : .loaded
        } catch {
            lastErrorMessage = error.localizedDescription
            state = sections.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
    }
}
