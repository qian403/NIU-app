import Foundation
import EventKit

// MARK: - Export Result

enum ExportResult {
    case success(eventCount: Int)
    case permissionDenied
    case failure(String)
}

// MARK: - ClassScheduleExportService

final class ClassScheduleExportService {

    private let eventStore = EKEventStore()

    // MARK: - Authorization

    func requestAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            do {
                return try await eventStore.requestWriteOnlyAccessToEvents()
            } catch {
                return false
            }
        } else {
            return await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Export

    /// Creates recurring weekly EKEvents for each course in the schedule.
    ///
    /// - Parameters:
    ///   - schedule:       The parsed class schedule.
    ///   - semesterStart:  The first day of the semester (the week that contains the first class).
    ///   - weekCount:      How many weeks the semester spans (typically 18).
    ///   - calendarName:   The EKCalendar display name to create or reuse.
    func export(
        schedule: ClassSchedule,
        semesterStart: Date,
        weekCount: Int,
        calendarName: String
    ) async -> ExportResult {
        guard await requestAccess() else { return .permissionDenied }

        do {
            let calendar = try getOrCreateCalendar(name: calendarName)
            let semesterEnd = endDate(from: semesterStart, weekCount: weekCount)
            var created = 0

            // Mapping from Chinese weekday name → EKWeekday raw value (Sun=1…Sat=7)
            let nameToEKWeekday: [String: EKWeekday] = [
                "星期一": .monday,
                "星期二": .tuesday,
                "星期三": .wednesday,
                "星期四": .thursday,
                "星期五": .friday,
                "星期六": .saturday,
                "星期日": .sunday,
            ]

            for (dayIndex, dayHeader) in schedule.dayHeaders.enumerated() {
                guard let ekWeekday = nameToEKWeekday[dayHeader] else { continue }

                // Group consecutive periods for the same course into a single time block
                let blocks = courseBlocks(for: dayIndex, in: schedule)

                for block in blocks {
                    // Find the first occurrence of this weekday on or after semesterStart
                    guard let firstDate = firstOccurrence(of: ekWeekday, onOrAfter: semesterStart),
                          let eventStart = combining(date: firstDate, minutes: block.startMinutes),
                          let eventEnd   = combining(date: firstDate, minutes: block.endMinutes)
                    else { continue }

                    let event = EKEvent(eventStore: eventStore)
                    event.title    = block.courseName
                    event.location = block.courseClassroom
                    event.notes    = block.courseTeacher
                    event.startDate = eventStart
                    event.endDate   = eventEnd
                    event.calendar  = calendar

                    let rule = EKRecurrenceRule(
                        recurrenceWith: .weekly,
                        interval: 1,
                        end: EKRecurrenceEnd(end: semesterEnd)
                    )
                    event.addRecurrenceRule(rule)

                    try eventStore.save(event, span: .futureEvents, commit: false)
                    created += 1
                }
            }

            try eventStore.commit()
            return .success(eventCount: created)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func getOrCreateCalendar(name: String) throws -> EKCalendar {
        // Reuse an existing calendar with the same title if found
        if let existing = eventStore.calendars(for: .event).first(where: { $0.title == name }) {
            return existing
        }

        // Try each writable source in preference order: local first, then calDAV.
        // Some accounts (Exchange, managed iCloud, subscribed calendars) reject
        // calendar creation with EKErrorCalendarIsImmutable – skip those silently.
        let orderedSources = eventStore.sources.sorted { a, _ in a.sourceType == .local }
        for source in orderedSources where source.sourceType == .local || source.sourceType == .calDAV {
            let cal = EKCalendar(for: .event, eventStore: eventStore)
            cal.title = name
            cal.source = source
            do {
                try eventStore.saveCalendar(cal, commit: true)
                return cal
            } catch {
                continue   // this source doesn't allow calendar creation; try the next
            }
        }

        // All writable sources rejected creation – fall back to the system default calendar
        if let defaultCal = eventStore.defaultCalendarForNewEvents {
            return defaultCal
        }

        throw NSError(
            domain: EKErrorDomain, code: 17,
            userInfo: [NSLocalizedDescriptionKey: "無法建立行事曆，請至「設定 → 行事曆 → 預設行事曆」確認帳號設定。"]
        )
    }

    private func endDate(from start: Date, weekCount: Int) -> Date {
        Calendar.current.date(byAdding: .weekOfYear, value: weekCount, to: start) ?? start
    }

    private func firstOccurrence(of weekday: EKWeekday, onOrAfter date: Date) -> Date? {
        let cal = Calendar.current
        // EKWeekday raw: Sun=1, Mon=2, …, Sat=7
        let targetWeekday = weekday.rawValue  // 1-indexed, Sun=1
        let comps = cal.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let currentWeekday = comps.weekday else { return nil }
        let diff = (targetWeekday - currentWeekday + 7) % 7
        return cal.date(byAdding: .day, value: diff, to: date)
    }

    private func combining(date: Date, minutes: Int) -> Date? {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        comps.hour   = minutes / 60
        comps.minute = minutes % 60
        comps.second = 0
        return Calendar.current.date(from: comps)
    }

    // MARK: - Block grouping

    struct CourseBlock {
        let courseName: String
        let courseTeacher: String?
        let courseClassroom: String?
        let startMinutes: Int
        let endMinutes: Int
    }

    /// Merges consecutive periods of the same course into single time blocks.
    func courseBlocks(for dayIndex: Int, in schedule: ClassSchedule) -> [CourseBlock] {
        var blocks: [CourseBlock] = []
        var current: CourseBlock?

        for period in schedule.periods {
            guard let course = period.course(for: dayIndex),
                  let start = period.startMinutes,
                  let end   = period.endMinutes
            else {
                // Empty period – commit any open block
                if let b = current { blocks.append(b); current = nil }
                continue
            }

            if let b = current, b.courseName == course.name {
                // Extend the current block's end time
                current = CourseBlock(
                    courseName: b.courseName,
                    courseTeacher: b.courseTeacher,
                    courseClassroom: b.courseClassroom,
                    startMinutes: b.startMinutes,
                    endMinutes: end
                )
            } else {
                if let b = current { blocks.append(b) }
                current = CourseBlock(
                    courseName: course.name,
                    courseTeacher: course.teacher,
                    courseClassroom: course.classroom,
                    startMinutes: start,
                    endMinutes: end
                )
            }
        }
        if let b = current { blocks.append(b) }
        return blocks
    }
}
