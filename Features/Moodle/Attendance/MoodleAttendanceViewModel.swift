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
                    [record.date.formatted(date: .complete, time: .omitted),
                     record.date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)),
                     record.date.formatted(Date.ISO8601FormatStyle(timeZone: .autoupdatingCurrent).year().month().day().dateSeparator(.dash)),
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
