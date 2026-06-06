import SwiftUI

// MARK: - Tab Navigation

enum NIUTab: String, CaseIterable {
    case home
    case courses
    case schedule
    case calendar
    case settings

    var title: LocalizedStringKey {
        switch self {
        case .home: return "首頁"
        case .courses: return "M 園區"
        case .schedule: return "課表"
        case .calendar: return "行事曆"
        case .settings: return "設定"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .courses: return "graduationcap.fill"
        case .schedule: return "tablecells"
        case .calendar: return "calendar"
        case .settings: return "gearshape.fill"
        }
    }
}

struct NIUTabNavigationView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label(NIUTab.home.title, systemImage: NIUTab.home.icon)
                }
                .tag(NIUTab.home)

            MoodleView()
                .tabItem {
                    Label(NIUTab.courses.title, systemImage: NIUTab.courses.icon)
                }
                .tag(NIUTab.courses)

            ClassScheduleView()
                .tabItem {
                    Label(NIUTab.schedule.title, systemImage: NIUTab.schedule.icon)
                }
                .tag(NIUTab.schedule)

            AcademicCalendarView()
                .tabItem {
                    Label(NIUTab.calendar.title, systemImage: NIUTab.calendar.icon)
                }
                .tag(NIUTab.calendar)

            SettingsView()
                .tabItem {
                    Label(NIUTab.settings.title, systemImage: NIUTab.settings.icon)
                }
                .tag(NIUTab.settings)
        }
        .tint(.accentColor)
    }
}
