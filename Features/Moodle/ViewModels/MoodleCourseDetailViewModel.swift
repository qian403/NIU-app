import SwiftUI
import Combine

@MainActor
final class MoodleCourseDetailViewModel: ObservableObject {
    struct AttendanceSection: Identifiable {
        let id: Int
        let sectionName: String
        let moduleName: String
        let records: [AttendanceRecord]
        let total: Int
        let presentCount: Int
        let absentCount: Int
    }
    
    struct AttendanceRecord: Identifiable {
        let id: Int
        let date: Date
        let timeText: String
        let description: String?
        let statusLabel: String
        let scoreText: String?
        let remarks: String?
        let isPresent: Bool
    }
    
    enum Tab: String, CaseIterable {
        case announcements = "公告"
        case assignments = "作業"
        case resources = "資源"
        case attendance = "出缺席"
        case grades = "成績"
    }
    
    @Published var selectedTab: Tab = .announcements
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // Announcements
    @Published var forums: [MoodleForum] = []
    @Published var discussions: [MoodleDiscussion] = []
    
    // Assignments
    @Published var assignments: [MoodleAssignment] = []
    @Published var assignmentSubmittedStatus: [Int: Bool] = [:]
    
    // Resources
    @Published var sections: [MoodleCourseSection] = []
    
    // Attendance
    @Published var attendanceSections: [AttendanceSection] = []
    
    // Grades
    @Published var gradeItems: [MoodleGradeItem] = []
    
    let course: MoodleCourse
    private let service = MoodleService.shared
    
    private var loadedTabs: Set<Tab> = []
    
    init(course: MoodleCourse) {
        self.course = course
    }
    
    func loadCurrentTab() async {
        // Don't reload if already loaded
        guard !loadedTabs.contains(selectedTab) else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            switch selectedTab {
            case .announcements:
                try await loadAnnouncements()
            case .assignments:
                try await loadAssignments()
            case .resources:
                try await loadResources()
            case .attendance:
                try await loadAttendance()
            case .grades:
                try await loadGrades()
            }
            loadedTabs.insert(selectedTab)
        } catch {
            errorMessage = error.localizedDescription
            print("[Moodle] Load \(selectedTab.rawValue) error: \(error)")
        }
        
        isLoading = false
    }
    
    func forceReload() async {
        loadedTabs.remove(selectedTab)
        await loadCurrentTab()
    }
    
    // MARK: - Data Loading
    
    private func loadAnnouncements() async throws {
        let allForums = try await service.fetchForumsByCourse(courseId: course.id)
        forums = allForums

        // Only include announcement-like forums to avoid mixing with Q&A/一般討論區.
        let announcementForums = allForums.filter {
            $0.type == "news" || $0.name.contains("公告")
        }
        let targetForums = announcementForums.isEmpty ? allForums.filter { $0.type == "news" } : announcementForums

        var allDiscussions: [MoodleDiscussion] = []
        for forum in targetForums {
            let resp = try await service.fetchForumDiscussions(forumId: forum.id)
            allDiscussions.append(contentsOf: resp.discussions)
        }

        discussions = allDiscussions
            .filter { !$0.plainMessage.contains("API 錯誤") }
            .sorted { $0.timemodified > $1.timemodified }
    }
    
    private func loadAssignments() async throws {
        assignments = try await service.fetchAssignments(courseId: course.id)
            .sorted { a1, a2 in
                // Upcoming due dates first, then past
                if a1.duedate == 0 { return false }
                if a2.duedate == 0 { return true }
                return a1.duedate > a2.duedate
            }
        assignmentSubmittedStatus = await fetchSubmittedStatusMap(for: assignments)
    }

    private func fetchSubmittedStatusMap(for assignments: [MoodleAssignment]) async -> [Int: Bool] {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for assignment in assignments {
                group.addTask { [service] in
                    do {
                        let status = try await service.fetchSubmissionStatus(assignId: assignment.id)
                        let submitted = status.lastattempt?.submission?.status == "submitted"
                        return (assignment.id, submitted)
                    } catch {
                        return (assignment.id, false)
                    }
                }
            }

            var result: [Int: Bool] = [:]
            for await (assignmentId, isSubmitted) in group {
                result[assignmentId] = isSubmitted
            }
            return result
        }
    }
    
    private func loadResources() async throws {
        let allSections = try await service.fetchCourseContents(courseId: course.id)
        // Filter out empty sections and label-only sections
        sections = allSections.filter { section in
            !section.modules.isEmpty && section.modules.contains(where: { $0.modname != "label" })
        }
    }
    
    private func loadAttendance() async throws {
        let allSections = try await service.fetchCourseContents(courseId: course.id)
        var items: [AttendanceSection] = []
        for section in allSections {
            for module in section.modules where module.modname == "attendance" {
                do {
                    let htmlResult = try await service.fetchAttendanceFromHTML(
                        attendanceId: module.instance,
                        courseModuleId: module.id
                    )
                    let records = htmlResult.records.map { record in
                        AttendanceRecord(
                            id: record.id,
                            date: record.date,
                            timeText: record.timeText,
                            description: record.description,
                            statusLabel: record.statusLabel,
                            scoreText: record.scoreText,
                            remarks: record.remarks,
                            isPresent: record.isPresent
                        )
                    }
                    let presentCount = records.filter { $0.isPresent }.count
                    let absentCount = max(htmlResult.total - presentCount, 0)
                    items.append(
                        AttendanceSection(
                            id: module.id,
                            sectionName: section.name,
                            moduleName: module.name,
                            records: records,
                            total: htmlResult.total,
                            presentCount: presentCount,
                            absentCount: absentCount
                        )
                    )
                } catch {
                    // Keep UI resilient but avoid masking auth/parser failures as "0 records".
                    print("[Moodle][Attendance] load failed for module=\(module.id): \(error)")
                }
            }
        }

        if items.isEmpty {
            throw MoodleError.apiError("出缺席資料載入失敗（尚未取得有效資料）")
        }
        attendanceSections = items
    }
    
    private func loadGrades() async throws {
        gradeItems = try await service.fetchGradeItems(courseId: course.id)
    }
}
