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
    /// `CustomCourseColor` raw value or a user-picked "#RRGGBB"; nil keeps the name-based schedule colour.
    /// Stored as text so a value from a newer version never fails decoding.
    var colorID: String? = nil

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
                          teacher: value(note), classroom: value(classroom), customCourseID: id,
                          customColorID: colorID)
    }
}

// MARK: - CustomCourseColor

/// Preset colours for custom courses, matching the iOS system colours.
nonisolated enum CustomCourseColor: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: "紅色"
        case .orange: "橘色"
        case .yellow: "黃色"
        case .green: "綠色"
        case .mint: "薄荷綠"
        case .teal: "藍綠色"
        case .cyan: "青色"
        case .blue: "藍色"
        case .indigo: "靛色"
        case .purple: "紫色"
        case .pink: "粉紅色"
        case .brown: "棕色"
        }
    }

    /// sRGB components of the light-appearance system colour, for fixed-colour readers such as the Widget.
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .red: (1.00, 0.23, 0.19)
        case .orange: (1.00, 0.58, 0.00)
        case .yellow: (1.00, 0.80, 0.00)
        case .green: (0.20, 0.78, 0.35)
        case .mint: (0.00, 0.78, 0.75)
        case .teal: (0.19, 0.69, 0.78)
        case .cyan: (0.20, 0.68, 0.90)
        case .blue: (0.00, 0.48, 1.00)
        case .indigo: (0.35, 0.34, 0.84)
        case .purple: (0.69, 0.32, 0.87)
        case .pink: (1.00, 0.18, 0.33)
        case .brown: (0.64, 0.52, 0.37)
        }
    }
}

/// A stored custom course colour: one of the presets or a colour picked from the palette.
nonisolated enum CourseColorChoice: Hashable, Sendable {
    case preset(CustomCourseColor)
    /// 8-bit sRGB components, as stored in "#RRGGBB".
    case custom(red: UInt8, green: UInt8, blue: UInt8)

    /// nil for "自動" and for unrecognised values, which then fall back to the name-based colour.
    init?(id: String?) {
        guard let id else { return nil }
        if let preset = CustomCourseColor(rawValue: id) {
            self = .preset(preset)
            return
        }
        guard id.count == 7, id.hasPrefix("#"), let value = UInt32(id.dropFirst(), radix: 16) else { return nil }
        self = .custom(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }

    /// Components are clamped to 0...1, e.g. for wide-gamut colours from the system picker.
    init(red: Double, green: Double, blue: Double) {
        func byte(_ value: Double) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        self = .custom(red: byte(red), green: byte(green), blue: byte(blue))
    }

    var id: String {
        switch self {
        case .preset(let preset): preset.rawValue
        case let .custom(red, green, blue): String(format: "#%02X%02X%02X", red, green, blue)
        }
    }

    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .preset(let preset): preset.rgb
        case let .custom(red, green, blue): (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
        }
    }
}

extension CustomCourse {
    nonisolated var color: CourseColorChoice? { CourseColorChoice(id: colorID) }
}

extension CourseInfo {
    /// Colour chosen for a custom course; nil for school courses and "自動".
    nonisolated var customColor: CourseColorChoice? { CourseColorChoice(id: customColorID) }
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
    private nonisolated static func mondayIndex(_ header: String) -> Int? {
        ScheduleClock.weekday(header).map { ($0 + 5) % 7 }
    }

    /// Places active custom courses into empty slots of the Monday-based week
    /// containing `date`. School courses keep their slot; a custom course whose
    /// slot is taken is skipped for that day rather than partially shown.
    nonisolated func merging(_ customCourses: [CustomCourse], weekContaining date: Date) -> ClassSchedule {
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
    nonisolated func withCustomCourses(from defaults: UserDefaults?, weekContaining date: Date) -> ClassSchedule {
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
