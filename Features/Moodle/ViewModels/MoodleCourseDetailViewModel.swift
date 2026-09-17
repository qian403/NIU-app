import Combine
import SwiftUI

/// Navigation state for the course-detail shell.
/// Each tab owns its data, loading, error, and refresh state in its feature
/// view model instead of accumulating unrelated state here.
@MainActor
final class MoodleCourseDetailViewModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case announcements = "公告"
        case assignments = "作業"
        case resources = "資源"
        case attendance = "出缺席"
        case grades = "成績"

        var iconName: String {
            switch self {
            case .announcements: "megaphone"
            case .assignments: "checklist"
            case .resources: "folder"
            case .attendance: "person.badge.clock"
            case .grades: "chart.bar"
            }
        }
    }

    @Published var selectedTab: Tab = .announcements
}
