import Foundation

// MARK: - CourseInfo

nonisolated struct CourseInfo: Codable, Hashable {
    let name: String        // Course name (課程名稱)
    let teacher: String?    // Instructor name (授課教師)
    let classroom: String?  // Room / location (上課地點)

    /// Combined detail string shown in the schedule card.
    var details: String? {
        let parts = [teacher, classroom].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// Parse a raw table-cell string.
    ///
    /// NIU academic schedule cell format (newline-separated):
    ///   1 line  → courseName
    ///   2 lines → teacher · courseName
    ///   3+ lines→ teacher · courseName · classroom…
    init(raw: String) {
        let lines = raw
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        switch lines.count {
        case 0:
            name = raw; teacher = nil; classroom = nil
        case 1:
            name = lines[0]; teacher = nil; classroom = nil
        case 2:
            teacher = lines[0]; name = lines[1]; classroom = nil
        default:
            teacher   = lines[0]
            name      = lines[1]
            classroom = lines.dropFirst(2).joined(separator: " ")
        }
    }

    init(name: String, teacher: String? = nil, classroom: String? = nil) {
        self.name      = name
        self.teacher   = teacher
        self.classroom = classroom
    }
}

// MARK: - ClassPeriod

nonisolated struct ClassPeriod: Codable, Identifiable {
    let id: String          // e.g. "1", "2", "A", "B"
    let timeRange: String   // e.g. "08:10~09:00"
    let courses: [String: CourseInfo]  // "0"=Mon, "1"=Tue, ...

    init(id: String, timeRange: String, courses: [Int: CourseInfo]) {
        self.id = id
        self.timeRange = timeRange
        self.courses = Dictionary(
            uniqueKeysWithValues: courses.map { (String($0.key), $0.value) }
        )
    }

    func course(for dayIndex: Int) -> CourseInfo? {
        courses[String(dayIndex)]
    }

    // Parse start time components from "HH:mm~HH:mm" or "HH:mm-HH:mm"
    private func splitTime() -> (start: String, end: String)? {
        let separators = CharacterSet(charactersIn: "~-")
        let parts = timeRange.components(separatedBy: separators)
        guard parts.count >= 2 else { return nil }
        return (parts[0].trimmingCharacters(in: .whitespaces),
                parts[1].trimmingCharacters(in: .whitespaces))
    }

    var startMinutes: Int? {
        guard let (start, _) = splitTime() else { return nil }
        let p = start.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    var endMinutes: Int? {
        guard let (_, end) = splitTime() else { return nil }
        let p = end.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    var startTimeLabel: String {
        splitTime()?.start ?? ""
    }

    var endTimeLabel: String {
        splitTime()?.end ?? ""
    }

    /// A normalized period label for display. The portal may return either a
    /// complete label (for example, "第二節") or only an identifier ("2").
    var displayPeriodLabel: String {
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.hasSuffix("節") { return value }
        if value.hasPrefix("第") { return "\(value)節" }
        return "第\(value)節"
    }

    /// Whether this period is currently in progress
    var startLabel: String { startTimeLabel }
    var endLabel: String { endTimeLabel }
    var isCurrentPeriod: Bool { contains(now: Date()) }

    func contains(now date: Date) -> Bool {
        let comps = ScheduleClock.calendar.dateComponents([.hour, .minute], from: date)
        guard let nowH = comps.hour, let nowM = comps.minute,
              let start = startMinutes, let end = endMinutes else { return false }
        let now = nowH * 60 + nowM
        return now >= start && now < end
    }
}

// MARK: - ClassSchedule

nonisolated struct ClassSchedule: Codable {
    let periods: [ClassPeriod]
    let dayCount: Int
    let dayHeaders: [String]  // e.g. ["星期一", "星期二", ...]
    let fetchedAt: Date
    var ownerSessionID: String?

    /// Short single-character day labels (e.g. ["一","二","三","四","五"])
    var shortDayLabels: [String] {
        dayHeaders.map { header -> String in
            guard header.count >= 1 else { return header }
            return String(header.suffix(1))
        }
    }

    func courses(for dayIndex: Int) -> [(period: ClassPeriod, course: CourseInfo)] {
        periods.compactMap { period in
            guard let course = period.course(for: dayIndex) else { return nil }
            return (period, course)
        }
    }
}


/// Shared civil-time rules for App, Widget and uploaded activity windows.
nonisolated enum ScheduleClock {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Taipei") ?? TimeZone(secondsFromGMT: 28800)!
        return value
    }
    static func weekday(_ header: String) -> Int? {
        for (word, index) in [("一", 2), ("二", 3), ("三", 4), ("四", 5), ("五", 6), ("六", 7), ("日", 1), ("天", 1)] {
            if header.contains(word) { return index }
        }
        return nil
    }
}

nonisolated struct ScheduleSession: Codable, Equatable, Sendable {
    let courseName: String
    let classroom: String
    let teacher: String
    let periodLabel: String
    let start: Date
    let end: Date
}

/// Consecutive periods of one course, presented as a single Live Activity span.
nonisolated struct ScheduleBlock: Equatable, Sendable {
    /// Runs from the first period's start to the last period's end.
    let session: ScheduleSession
    /// Class time of each period inside the block, excluding the breaks between
    /// them; a single element for one period.
    let periods: [ClosedRange<Date>]
}

extension Array where Element == ScheduleSession {
    /// Merge adjacent periods that share a course name. The break limit keeps a
    /// lunch break or a later repeat of the same course as separate blocks.
    nonisolated func mergedConsecutiveCourses(maxBreak: TimeInterval = 20 * 60) -> [ScheduleBlock] {
        var groups: [[ScheduleSession]] = []
        for session in sorted(by: { $0.start < $1.start }) {
            if let previous = groups.last?.last,
               Self.courseKey(previous) == Self.courseKey(session),
               !Self.courseKey(session).isEmpty,
               session.start >= previous.end,
               session.start.timeIntervalSince(previous.end) <= maxBreak {
                groups[groups.count - 1].append(session)
            } else {
                groups.append([session])
            }
        }
        return groups.map { group in
            let first = group[0], last = group[group.count - 1]
            guard group.count > 1 else { return ScheduleBlock(session: first, periods: [first.start...first.end]) }
            return ScheduleBlock(
                session: ScheduleSession(courseName: first.courseName, classroom: first.classroom,
                                         teacher: first.teacher,
                                         periodLabel: Self.periodRangeLabel(first.periodLabel, last.periodLabel),
                                         start: first.start, end: last.end),
                periods: group.map { $0.start...$0.end }
            )
        }
    }

    private nonisolated static func courseKey(_ session: ScheduleSession) -> String {
        session.courseName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "第3節" + "第5節" → "第3–5節".
    private nonisolated static func periodRangeLabel(_ first: String, _ last: String) -> String {
        func core(_ label: String) -> String {
            var value = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("第") { value.removeFirst() }
            if value.hasSuffix("節") { value.removeLast() }
            return value
        }
        let start = core(first), end = core(last)
        guard !start.isEmpty, !end.isEmpty else { return first }
        return "第\(start)–\(end)節"
    }
}

extension ClassSchedule {
    func sessions(on date: Date) -> [ScheduleSession] {
        let cal = ScheduleClock.calendar
        guard let column = dayHeaders.firstIndex(where: { ScheduleClock.weekday($0) == cal.component(.weekday, from: date) }) else { return [] }
        let midnight = cal.startOfDay(for: date)
        return periods.compactMap { period in
            guard let course = period.course(for: column), let start = period.startMinutes,
                  let end = period.endMinutes, end > start,
                  let startDate = cal.date(byAdding: .minute, value: start, to: midnight),
                  let endDate = cal.date(byAdding: .minute, value: end, to: midnight) else { return nil }
            return ScheduleSession(courseName: course.name, classroom: course.classroom ?? "教室待確認",
                                   teacher: course.teacher ?? "授課教師待確認", periodLabel: period.displayPeriodLabel,
                                   start: startDate, end: endDate)
        }.sorted { ($0.start, $0.periodLabel) < ($1.start, $1.periodLabel) }
    }

    func timelineDates(after now: Date, days: Int = 7) -> [Date] {
        let cal = ScheduleClock.calendar
        let midnight = cal.startOfDay(for: now)
        var dates: Set<Date> = [now]
        for offset in 0...max(1, min(days, 7)) {
            guard let day = cal.date(byAdding: .day, value: offset, to: midnight) else { continue }
            if day > now { dates.insert(day) }
            if offset < days {
                for session in sessions(on: day) {
                    for boundary in [session.start, session.end] where boundary > now { dates.insert(boundary) }
                }
            }
        }
        return dates.sorted()
    }
}
