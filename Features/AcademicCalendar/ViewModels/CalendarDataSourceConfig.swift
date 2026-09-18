import Foundation

/// Source and rollover policy are shared with the widget in AcademicCalendarStore.
struct CalendarDataSourceConfig {
    static func currentAcademicYearROC(from date: Date = Date()) -> Int {
        CampusCalendarDate.academicYear(at: date)
    }
}
