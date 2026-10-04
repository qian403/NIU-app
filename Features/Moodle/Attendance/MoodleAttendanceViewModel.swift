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
    @Published private(set) var sections: [MoodleAttendanceSection] = [] {
        didSet {
            // Session IDs may repeat between attendance modules, so index per section.
            searchIndexes = sections.reduce(into: [:]) { indexes, section in
                indexes[section.id] = MoodleSearchIndex(section.records) { record in
                    [MoodlePresentation.fullDate(record.date),
                     MoodlePresentation.numericDate(record.date),
                     MoodlePresentation.isoDate(record.date),
                     record.timeText, record.description ?? "課堂點名", record.statusLabel]
                        .map(MoodleSearch.plainText)
                }
            }
            updateSearch()
        }
    }
    @Published var searchText = "" { didSet { updateSearch() } }
    @Published private(set) var filteredSections: [MoodleAttendanceSection] = []
    private var searchIndexes: [Int: MoodleSearchIndex] = [:]

    private func updateSearch() {
        guard !MoodleSearch.trimmed(searchText).isEmpty else {
            filteredSections = sections
            return
        }
        filteredSections = sections.compactMap { section in
            let records = searchIndexes[section.id]?.filter(section.records, query: searchText) ?? []
            guard !records.isEmpty else { return nil }
            return MoodleAttendanceSection(id: section.id, sectionName: section.sectionName,
                                           moduleName: section.moduleName, records: records,
                                           total: section.total, source: section.source)
        }
    }
    @Published private(set) var lastErrorMessage: String?

    private let repository: any MoodleAttendanceRepositoryProtocol
    private(set) var hasLoaded = false
    private let loads = MoodleCourseLoadCoordinator()
    private var loadGeneration = 0

    init(repository: (any MoodleAttendanceRepositoryProtocol)? = nil) {
        self.repository = repository ?? MoodleAttendanceRepository()
    }

    func loadCourse(_ courseId: Int, force: Bool = false) async {
        await load(force: force) {
            try await self.repository.fetchCourseAttendance(courseId: courseId)
        }
    }

    func loadModule(
        _ module: MoodleModule,
        attendanceId: Int?,
        courseModuleId: Int?,
        force: Bool = false
    ) async {
        await load(force: force) {
            let section = try await self.repository.fetchAttendance(
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
        operation: @escaping @MainActor () async throws -> [MoodleAttendanceSection]
    ) async {
        await loads.run(force: force) { [self] in
            await performLoad(force: force, operation: operation)
        }
    }

    private func performLoad(force: Bool, operation: () async throws -> [MoodleAttendanceSection]) async {
        guard force || !hasLoaded else { return }

        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        lastErrorMessage = nil

        do {
            let result = try await operation()
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            sections = result
            hasLoaded = true
            state = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            if Task.isCancelled || error is CancellationError {
                state = sections.isEmpty ? .idle : .loaded
                return
            }
            lastErrorMessage = error.localizedDescription
            state = sections.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
    }
}
