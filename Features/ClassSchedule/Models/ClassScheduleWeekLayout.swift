import Foundation

/// Row-based geometry shared by the weekly view and offline checks. No UI or storage.
nonisolated struct ClassScheduleWeekLayout {
    struct GridMetrics {
        let gutterWidth: CGFloat
        let columnWidth: CGFloat
        let headerHeight: CGFloat
        let rowHeight: CGFloat
        let gridHeight: CGFloat

        init(availableSize: CGSize, columns: Int, rows: Int, expanded: Bool,
             preferredRowHeight: CGFloat = 88, gutterWidth: CGFloat = 38,
             minimumColumnWidth: CGFloat = 100, statusHeight: CGFloat = 28) {
            self.gutterWidth = gutterWidth
            let gridSpace = max(0, availableSize.height - 16 - statusHeight - 8)
            headerHeight = expanded ? max(60, preferredRowHeight * 0.75) : min(48, gridSpace)
            rowHeight = expanded ? preferredRowHeight : max(0, gridSpace - headerHeight) / CGFloat(max(1, rows))
            columnWidth = expanded ? minimumColumnWidth :
                max(1, (availableSize.width - 16 - gutterWidth) / CGFloat(max(1, columns)))
            gridHeight = headerHeight + CGFloat(rows) * rowHeight
        }
    }

    struct Column: Identifiable {
        let id: Int // Display index, independent of the school's column order.
        let header: String
        let date: Date
        let scheduleIndex: Int?

        var shortLabel: String { String(header.suffix(1)) }
        var dateLabel: String {
            let parts = ScheduleClock.calendar.dateComponents([.month, .day], from: date)
            return "\(parts.month ?? 1)/\(parts.day ?? 1)"
        }
    }

    struct Block: Identifiable {
        let column: Int
        let rows: Range<Int> // Absolute indices in schedule.periods; end is exclusive.
        let course: CourseInfo
        let classrooms: [String]
        let teachers: [String]
        var id: String { "\(column):\(rows.lowerBound)" }
    }

    let columns: [Column]
    let visibleRows: Range<Int>
    let blocks: [Block]

    init(schedule: ClassSchedule, displayDayHeaders: [String], now: Date) {
        let dates = Self.weekDates(containing: now)
        let columns: [Column] = displayDayHeaders.enumerated().compactMap { index, header in
            guard let weekday = ScheduleClock.weekday(header) else { return nil }
            return Column(id: index, header: header, date: dates[(weekday + 5) % 7],
                          scheduleIndex: schedule.dayHeaders.firstIndex(of: header))
        }
        self.columns = columns
        visibleRows = schedule.periods.indices

        var result: [Block] = []
        for column in columns {
            guard let source = column.scheduleIndex else { continue }
            var row = visibleRows.lowerBound
            while row < visibleRows.upperBound {
                guard let course = schedule.periods[row].course(for: source) else {
                    row += 1
                    continue
                }
                let name = Self.courseKey(course.name)
                let first = row
                var courses = [course]
                row += 1
                while row < visibleRows.upperBound,
                      let next = schedule.periods[row].course(for: source),
                      !name.isEmpty, Self.courseKey(next.name) == name, next.customCourseID == course.customCourseID,
                      Self.canMerge(schedule.periods[row - 1], schedule.periods[row]) {
                    courses.append(next)
                    row += 1
                }
                result.append(Block(column: column.id, rows: first..<row,
                                    course: CourseInfo(name: name, teacher: course.teacher, classroom: course.classroom,
                                                       customCourseID: course.customCourseID,
                                                       customColorID: course.customColorID),
                                    classrooms: Self.unique(courses.compactMap(\.classroom)),
                                    teachers: Self.unique(courses.compactMap(\.teacher))))
            }
        }
        blocks = result
    }

    /// Explicit Monday offset avoids dependence on locale firstWeekday/week-year rules.
    static func weekDates(containing date: Date) -> [Date] {
        let calendar = ScheduleClock.calendar
        let offset = (calendar.component(.weekday, from: date) + 5) % 7
        let midnight = calendar.startOfDay(for: date)
        guard let monday = calendar.date(byAdding: .day, value: -offset, to: midnight) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    func todayColumn(at date: Date) -> Column? {
        columns.first { ScheduleClock.calendar.isDate($0.date, inSameDayAs: date) }
    }

    /// Units are visible rows, not minutes. Unknown times still occupy a complete row.
    /// In a break, hold at the preceding row's lower edge; never guess unknown times.
    func nowLinePosition(periods: [ClassPeriod], at date: Date) -> Double? {
        guard todayColumn(at: date) != nil else { return nil }
        let parts = ScheduleClock.calendar.dateComponents([.hour, .minute, .second], from: date)
        let minutes = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        for row in visibleRows {
            let period = periods[row]
            guard let start = period.startMinutes, let end = period.endMinutes, end > start else { continue }
            if minutes >= Double(start), minutes <= Double(end) {
                return Double(row - visibleRows.lowerBound) + (minutes - Double(start)) / Double(end - start)
            }
            if row + 1 < visibleRows.upperBound,
               let nextStart = periods[row + 1].startMinutes,
               nextStart > end, minutes > Double(end), minutes < Double(nextStart) {
                return Double(row + 1 - visibleRows.lowerBound)
            }
        }
        return nil
    }

    /// FNV-1a over normalized UTF-8, with specified wrapping arithmetic across launches.
    static func stableColourIndex(for name: String, paletteCount: Int) -> Int {
        guard paletteCount > 0 else { return 0 }
        var hash: UInt64 = 14695981039346656037
        for byte in courseKey(name).utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return Int(hash % UInt64(paletteCount))
    }

    func accessibilityLabel(for block: Block, periods: [ClassPeriod]) -> String {
        let first = periods[block.rows.lowerBound], last = periods[block.rows.upperBound - 1]
        func core(_ value: String) -> String {
            var label = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.hasPrefix("第") { label.removeFirst() }
            if label.hasSuffix("節") { label.removeLast() }
            return label
        }
        let period = block.rows.count == 1 ? "第\(core(first.id))節" : "第\(core(first.id))–\(core(last.id))節"
        let time = first.startTimeLabel.isEmpty || last.endTimeLabel.isEmpty
            ? "時間待確認" : "\(first.startTimeLabel)到\(last.endTimeLabel)"
        let header = columns.first { $0.id == block.column }?.header ?? ""
        return [header, period, time, block.course.name,
                block.classrooms.isEmpty ? "教室待確認" : block.classrooms.joined(separator: "、"),
                block.teachers.isEmpty ? "教師待確認" : block.teachers.joined(separator: "、")].joined(separator: "，")
    }

    private static func courseKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canMerge(_ previous: ClassPeriod, _ next: ClassPeriod) -> Bool {
        guard let start = previous.startMinutes, let end = previous.endMinutes, end > start,
              let nextStart = next.startMinutes, let nextEnd = next.endMinutes, nextEnd > nextStart else { return false }
        return (0...20).contains(nextStart - end)
    }

    private static func unique(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in
            let trimmed = courseKey(value)
            if !trimmed.isEmpty, !result.contains(trimmed) { result.append(trimmed) }
        }
    }
}
