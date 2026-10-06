import Foundation

// MARK: - CustomCourse

/// A course the user adds on this device. It is never sent to the school or
/// written into the school schedule cache; readers merge it for display only.
nonisolated struct CustomCourse: Codable, Identifiable, Hashable, Sendable {
    static let weekdayHeaders = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]

    var id: UUID
    var name: String
    var classroom: String
    var note: String
    /// Monday-based: 0 = 星期一 … 6 = 星期日.
    var weekdays: [Int]
    var startPeriodID: String
    var endPeriodID: String
    /// Inclusive last day in Asia/Taipei, "YYYY-MM-DD".
    var lastDay: String

    static func dayString(_ date: Date) -> String {
        let parts = ScheduleClock.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromDay value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return ScheduleClock.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    func isActive(on date: Date) -> Bool {
        Self.dayString(date) <= lastDay
    }

    /// Row indices in `periods`; nil when either period no longer exists.
    func periodRange(in periods: [ClassPeriod]) -> ClosedRange<Int>? {
        guard let start = periods.firstIndex(where: { $0.id == startPeriodID }),
              let end = periods.firstIndex(where: { $0.id == endPeriodID }),
              start <= end else { return nil }
        return start...end
    }

    var courseInfo: CourseInfo {
        func value(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return CourseInfo(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                          teacher: value(note), classroom: value(classroom), customCourseID: id)
    }
}

/// Current account's courses mirrored into the App Group for Widget/Live Activity readers.
nonisolated struct CustomCourseSnapshot: Codable {
    /// "classSchedule." prefix: removed with the other schedule caches on logout.
    static let key = "classSchedule.customCourses.v1"

    let ownerSessionID: String
    let courses: [CustomCourse]

    static func courses(for schedule: ClassSchedule, in defaults: UserDefaults?) -> [CustomCourse] {
        guard let owner = schedule.ownerSessionID,
              let data = defaults?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(CustomCourseSnapshot.self, from: data),
              snapshot.ownerSessionID == owner else { return [] }
        return snapshot.courses
    }
}

extension ClassSchedule {
    private static func mondayIndex(_ header: String) -> Int? {
        ScheduleClock.weekday(header).map { ($0 + 5) % 7 }
    }

    /// Places active custom courses into empty slots of the Monday-based week
    /// containing `date`. School courses keep their slot; a custom course whose
    /// slot is taken is skipped for that day rather than partially shown.
    func merging(_ customCourses: [CustomCourse], weekContaining date: Date) -> ClassSchedule {
        guard !customCourses.isEmpty else { return self }
        let cal = ScheduleClock.calendar
        let midnight = cal.startOfDay(for: date)
        let monday = cal.date(byAdding: .day, value: -((cal.component(.weekday, from: date) + 5) % 7), to: midnight) ?? midnight

        var placements: [(course: CustomCourse, rows: ClosedRange<Int>, weekday: Int)] = []
        for course in customCourses {
            guard let rows = course.periodRange(in: periods) else { continue }
            for weekday in Set(course.weekdays).sorted() where (0..<7).contains(weekday) {
                guard let day = cal.date(byAdding: .day, value: weekday, to: monday), course.isActive(on: day) else { continue }
                placements.append((course, rows, weekday))
            }
        }
        guard !placements.isEmpty else { return self }

        var headers = dayHeaders
        for weekday in Set(placements.map(\.weekday)).sorted()
            where !headers.contains(where: { Self.mondayIndex($0) == weekday }) {
            headers.append(CustomCourse.weekdayHeaders[weekday])
        }
        var table: [[Int: CourseInfo]] = periods.map { period in
            Dictionary(uniqueKeysWithValues: period.courses.compactMap { key, value in Int(key).map { ($0, value) } })
        }
        for placement in placements {
            guard let column = headers.firstIndex(where: { Self.mondayIndex($0) == placement.weekday }),
                  placement.rows.allSatisfy({ table[$0][column] == nil }) else { continue }
            for row in placement.rows { table[row][column] = placement.course.courseInfo }
        }

        var merged = ClassSchedule(
            periods: zip(periods, table).map { ClassPeriod(id: $0.id, timeRange: $0.timeRange, courses: $1) },
            dayCount: headers.count, dayHeaders: headers, fetchedAt: fetchedAt)
        merged.ownerSessionID = ownerSessionID
        return merged
    }

    /// Display-only schedule with this session's mirrored custom courses. Never cache the result.
    func withCustomCourses(from defaults: UserDefaults?, weekContaining date: Date) -> ClassSchedule {
        merging(CustomCourseSnapshot.courses(for: self, in: defaults), weekContaining: date)
    }

    /// First slot already used by a school course or another unexpired custom
    /// course, as user-facing text; nil when every requested slot is free.
    func conflictMessage(for course: CustomCourse, others: [CustomCourse], today: Date) -> String? {
        guard let rows = course.periodRange(in: periods) else { return "找不到所選節次" }
        let todayString = CustomCourse.dayString(today)
        for weekday in Set(course.weekdays).sorted() where (0..<7).contains(weekday) {
            let dayName = CustomCourse.weekdayHeaders[weekday]
            if let column = dayHeaders.firstIndex(where: { Self.mondayIndex($0) == weekday }) {
                for row in rows {
                    if let existing = periods[row].course(for: column), existing.customCourseID == nil {
                        return "\(dayName)\(periods[row].displayPeriodLabel)已有「\(existing.name)」"
                    }
                }
            }
            for other in others where other.id != course.id && other.lastDay >= todayString && other.weekdays.contains(weekday) {
                guard let otherRows = other.periodRange(in: periods), otherRows.overlaps(rows) else { continue }
                let row = max(rows.lowerBound, otherRows.lowerBound)
                return "\(dayName)\(periods[row].displayPeriodLabel)已有自訂課程「\(other.name)」"
            }
        }
        return nil
    }
}

// MARK: - Display labels

extension CustomCourse {
    static let shortWeekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    /// "每週一、三"
    static func weekdaySummary<S: Sequence>(_ weekdays: S) -> String where S.Element == Int {
        "每週" + Set(weekdays).sorted().filter { (0..<7).contains($0) }
            .map { shortWeekdayLabels[$0] }.joined(separator: "、")
    }

    /// "每週一、三・第7–8節 15:10–16:55"
    func scheduleSummary(in periods: [ClassPeriod]) -> String {
        let days = Self.weekdaySummary(weekdays)
        guard let rows = periodRange(in: periods) else { return days }
        return "\(days)・\(Self.periodSummary(periods[rows]))"
    }

    static func periodSummary(_ periods: ArraySlice<ClassPeriod>) -> String {
        guard let first = periods.first, let last = periods.last else { return "" }
        func core(_ label: String) -> String {
            var value = label
            if value.hasPrefix("第") { value.removeFirst() }
            if value.hasSuffix("節") { value.removeLast() }
            return value
        }
        let label = periods.count == 1 ? first.displayPeriodLabel
            : "第\(core(first.displayPeriodLabel))–\(core(last.displayPeriodLabel))節"
        guard !first.startTimeLabel.isEmpty, !last.endTimeLabel.isEmpty else { return label }
        return "\(label) \(first.startTimeLabel)–\(last.endTimeLabel)"
    }

    var lastDayLabel: String {
        let parts = lastDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return lastDay }
        return "\(parts[0])/\(parts[1])/\(parts[2])"
    }
}
