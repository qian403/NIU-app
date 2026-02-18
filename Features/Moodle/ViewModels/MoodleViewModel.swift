import SwiftUI
import Combine

@MainActor
final class MoodleViewModel: ObservableObject {
    
    enum LoadState {
        case idle
        case loading
        case loaded
        case error(String)
    }
    
    @Published var loadState: LoadState = .idle
    @Published var coursesBySemester: [(semester: String, courses: [MoodleCourse])] = []
    @Published var selectedSemester: String?
    
    private let service = MoodleService.shared
    
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
    
    func loadCourses(username: String, password: String) async {
        let isFirstLoad = coursesBySemester.isEmpty
        if isFirstLoad {
            loadState = .loading
        }
        
        do {
            // Authenticate if needed
            if !service.isAuthenticated {
                try await service.authenticate(username: username, password: password)
            }
            
            let courses = try await service.fetchCourses()
            
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
            
            coursesBySemester = sorted
            // Only set selectedSemester on first load, or if current selection is no longer valid
            let currentSelected = selectedSemester?.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentSelected == nil || currentSelected?.isEmpty == true || !sorted.contains(where: { $0.semester == currentSelected }) {
                selectedSemester = sorted.first?.semester
            }
            loadState = .loaded
            
        } catch {
            // Only show error if we have no data yet
            if isFirstLoad {
                loadState = .error(error.localizedDescription)
            }
            print("[Moodle] Load courses error: \(error)")
        }
    }
    
    func refresh(username: String, password: String) async {
        await loadCourses(username: username, password: password)
    }

    private static func inferSemester(from date: Date) -> String {
        let cal = Calendar.current
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
