import SwiftUI
import Combine

@MainActor
final class MoodleViewModel: ObservableObject {
    
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }
    
    @Published var loadState: LoadState = .idle
    @Published var coursesBySemester: [(semester: String, courses: [MoodleCourse])] = []
    @Published var selectedSemester: String?
    
    @Published private(set) var isRefreshing = false
    private var requestID = UUID()

    enum ContentState: Equatable {
        case loading, empty, courses
        case error(String)
    }

    var contentState: ContentState {
        if !currentSemesterCourses.isEmpty { return .courses }
        // A loaded empty semester remains visible while other semesters are cached.
        if !coursesBySemester.isEmpty { return .empty }
        switch loadState {
        case .idle, .loading: return .loading
        case .loaded: return .empty
        case .error(let message): return .error(message)
        }
    }

    static func selection(_ current: String?, in semesters: [String]) -> String? {
        let normalized = current?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.flatMap { semesters.contains($0) ? $0 : nil } ?? semesters.first
    }

    private let repository: any MoodleCourseRepositoryProtocol

    init(repository: (any MoodleCourseRepositoryProtocol)? = nil, initialSemester: String? = nil) {
        selectedSemester = initialSemester
        self.repository = repository ?? MoodleCourseRepository()
    }
    
    var currentSemesterCourses: [MoodleCourse] {
        guard let selected = selectedSemester else {
            return coursesBySemester.first?.courses ?? []
        }
        return coursesBySemester.first(where: { $0.semester == selected })?.courses ?? []
    }
    
    var allSemesters: [String] {
        coursesBySemester
            .map(\.semester)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var selectedSemesterDisplay: String? {
        let value = selectedSemester?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var isAuthenticated: Bool { repository.isAuthenticated }
    
    func loadCourses(username: String, password: String) async {
        let request = UUID()
        requestID = request
        let previousState = loadState
        isRefreshing = true
        if coursesBySemester.isEmpty { loadState = .loading }
        defer { if requestID == request { isRefreshing = false } }

        do {
            // Authenticate if needed
            if !repository.isAuthenticated {
                try await repository.authenticate(username: username, password: password)
            }
            
            try Task.checkCancellation()
            guard requestID == request else { return }
            let courses = try await repository.fetchCourses()
            try Task.checkCancellation()
            guard requestID == request else { return }
            
            // Group by semester, sort semesters descending (newest first)
            // Include all courses (not just visible ones) so all semesters show up
            let grouped = Dictionary(grouping: courses) { course in
                Self.normalizedSemesterLabel(for: course)
            }
            var sorted = grouped.sorted { $0.key > $1.key }
                .map { (semester: $0.key.trimmingCharacters(in: .whitespacesAndNewlines), courses: $0.value.sorted { ($0.lastaccess ?? 0) > ($1.lastaccess ?? 0) }) }
                .filter { !$0.semester.isEmpty }

            if sorted.isEmpty, !courses.isEmpty {
                let fallback = Self.inferSemester(from: courses[0].startDate)
                sorted = [(semester: fallback, courses: courses.sorted { ($0.lastaccess ?? 0) > ($1.lastaccess ?? 0) })]
            }
            
            for raw in repository.availableSemesters {
                let semester = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !semester.isEmpty, !sorted.contains(where: { $0.semester == semester }) {
                    sorted.append((semester: semester, courses: []))
                }
            }
            sorted.sort { $0.semester > $1.semester }
            coursesBySemester = sorted
            selectedSemester = Self.selection(selectedSemester, in: sorted.map(\.semester))
            loadState = .loaded
            
        } catch {
            guard requestID == request else { return }
            if Task.isCancelled || error is CancellationError {
                loadState = previousState == .loading ? .idle : previousState
                return
            }
            loadState = .error("課程載入失敗，請稍後重試。")
            // NSError.userInfo can contain credential-bearing URLs. Log only
            // the error category and numeric code, never the complete error.
            let diagnostic = error as NSError
            print("[Moodle] Load courses error: domain=\(diagnostic.domain) code=\(diagnostic.code)")
        }
    }
    
    func refresh(username: String, password: String) async {
        await loadCourses(username: username, password: password)
    }

    private static func inferSemester(from date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .gmt
        let year = cal.component(.year, from: date) - 1911
        let month = cal.component(.month, from: date)
        let term = (month >= 8 || month == 1) ? 1 : 2
        let academicYear = month == 1 ? (year - 1) : year
        return "\(academicYear)-\(term)"
    }

    private static func normalizedSemesterLabel(for course: MoodleCourse) -> String {
        let raw = course.semesterLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? inferSemester(from: course.startDate) : raw
    }
}

// MARK: - Schedule → Moodle course lookup

/// Resolves a course name from the class schedule to the matching Moodle course.
@MainActor
final class MoodleScheduleCourseLookupViewModel: ObservableObject {

    enum State {
        case loading
        case matched(MoodleCourse)
        case multiple([MoodleCourse])
        case notFound
        case error(String)
    }

    @Published private(set) var state: State = .loading

    let courseName: String
    private let repository: any MoodleCourseRepositoryProtocol

    init(courseName: String, repository: (any MoodleCourseRepositoryProtocol)? = nil) {
        self.courseName = courseName
        self.repository = repository ?? MoodleCourseRepository()
    }

    func load() async {
        state = .loading
        do {
            if !repository.isAuthenticated {
                guard let creds = LoginRepository.shared.getSavedCredentials() else {
                    state = .error("找不到登入資料，請登出後重新登入")
                    return
                }
                try await repository.authenticate(username: creds.username, password: creds.password)
            }
            let courses = try await repository.fetchCourses()
            try Task.checkCancellation()

            let matches = Self.matchingCourses(for: courseName, in: courses)
            switch matches.count {
            case 0: state = .notFound
            case 1: state = .matched(matches[0])
            default: state = .multiple(matches)
            }
        } catch is CancellationError {
            // The view went away; nothing to show.
        } catch {
            if Task.isCancelled { return }
            state = .error(error.localizedDescription)
            let diagnostic = error as NSError
            print("[Moodle] Schedule course lookup error: domain=\(diagnostic.domain) code=\(diagnostic.code)")
        }
    }

    /// Courses whose name matches `name`, limited to a single semester:
    /// the current semester when it has matches, otherwise the newest one.
    static func matchingCourses(
        for name: String,
        in courses: [MoodleCourse],
        now: Date = Date()
    ) -> [MoodleCourse] {
        let target = normalizedName(name)
        guard !target.isEmpty else { return [] }

        var matches = courses.filter { normalizedName($0.cleanName) == target }
        if matches.isEmpty {
            matches = courses.filter { course in
                let candidate = normalizedName(course.cleanName)
                guard min(candidate.count, target.count) >= 2 else { return false }
                return candidate.contains(target) || target.contains(candidate)
            }
        }
        guard !matches.isEmpty else { return [] }

        let current = currentSemesterCode(now: now)
        if matches.contains(where: { $0.semesterCode == current }) {
            return matches.filter { $0.semesterCode == current }
        }
        let newest = matches.map(\.semesterCode).max() ?? ""
        return matches.filter { $0.semesterCode == newest }
    }

    /// Semester code like "1141", switching academic year on August 1 (Asia/Taipei).
    static func currentSemesterCode(now: Date) -> String {
        let cal = ScheduleClock.calendar
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        let academicYear = (month >= 8 ? year : year - 1) - 1911
        let term = (month >= 8 || month == 1) ? 1 : 2
        return "\(academicYear)\(term)"
    }

    static func normalizedName(_ name: String) -> String {
        let halfWidth = name.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? name
        let ignored = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return String(String.UnicodeScalarView(
            halfWidth.lowercased().unicodeScalars.filter { !ignored.contains($0) }
        ))
    }
}
