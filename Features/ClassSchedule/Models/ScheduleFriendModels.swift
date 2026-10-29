import Foundation

// MARK: - Live status

/// What a friend is doing right now, worked out on this device from their shared table.
/// Nothing is sent anywhere; times are minutes after Taipei midnight.
nonisolated enum ScheduleFriendStatus: Equatable, Sendable {
    /// `until` is the end of the course, consecutive periods of the same course included.
    case inClass(course: String, room: String?, until: Int)
    /// Has a class later today, starting at `until`.
    case free(until: Int)
    case doneForToday
    case noClassToday
    /// The shared table does not cover today's weekday, so whether they have class is unknown.
    case notCovered
    case expired
    /// Shared for a semester that has not started yet.
    case upcomingTerm

    /// Lower sorts first: people you could meet now come before people in class.
    var sortRank: Int {
        switch self {
        case .free: 0
        case .doneForToday: 1
        case .noClassToday: 2
        case .inClass: 3
        case .notCovered: 4
        case .upcomingTerm: 5
        case .expired: 6
        }
    }

    var isAvailable: Bool { sortRank <= 2 }
    var isCurrentTerm: Bool { self != .expired && self != .upcomingTerm }
}

extension ScheduleSharePayload {
    /// Monday-based weekday and minutes after midnight in Asia/Taipei.
    nonisolated static func clockPosition(of date: Date) -> (day: Int, minute: Int) {
        let parts = ScheduleClock.calendar.dateComponents([.weekday, .hour, .minute], from: date)
        return (((parts.weekday ?? 2) + 5) % 7, (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    nonisolated static func clockText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    nonisolated func status(at date: Date) -> ScheduleFriendStatus {
        let current = ScheduleShareTerm(containing: date)
        if term < current { return .expired }
        if term > current { return .upcomingTerm }
        let (day, minute) = Self.clockPosition(of: date)
        guard days.contains(day) else { return .notCovered }
        let today = classBlocks(on: day)
        guard !today.isEmpty else { return .noClassToday }
        if let block = today.first(where: { $0.start <= minute && minute < $0.end }) {
            return .inClass(course: block.name, room: block.room, until: block.end)
        }
        if let next = today.first(where: { $0.start > minute }) { return .free(until: next.start) }
        return .doneForToday
    }

    /// One course's consecutive periods on `day`, so a double period and the break inside it read as one class.
    nonisolated struct ClassBlock: Equatable, Sendable {
        let name: String
        let room: String?
        let start: Int
        var end: Int
    }

    nonisolated func classBlocks(on day: Int) -> [ClassBlock] {
        var blocks: [ClassBlock] = []
        for entry in entries(on: day) {
            if let last = blocks.last, last.name == entry.name, entry.period.start - last.end <= Self.maxCoveredBreak {
                blocks[blocks.count - 1].end = max(last.end, entry.period.end)
            } else {
                blocks.append(ClassBlock(name: entry.name, room: entry.room, start: entry.period.start, end: entry.period.end))
            }
        }
        return blocks
    }
}

// MARK: - Common free windows

/// A stretch of consecutive periods where everyone in a comparison is free.
nonisolated struct ScheduleFreeWindow: Equatable, Sendable, Identifiable {
    /// Monday-based: 0 = 星期一 … 6 = 星期日.
    let day: Int
    let start: Int
    let end: Int

    var id: Int { day * 10_000 + start }
    var minutes: Int { end - start }

    var durationText: String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) 分鐘" }
        return rest == 0 ? "\(hours) 小時" : "\(hours) 小時 \(rest) 分"
    }
}

extension ScheduleFreeTime {
    static let weekdayNames = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]

    /// Free periods of `base` shared by everyone, merged across breaks the table covers.
    /// Periods anyone's table leaves out stay unknown and split windows rather than joining them.
    static func windows(base: ScheduleSharePayload, others: [ScheduleSharePayload]) -> [ScheduleFreeWindow] {
        let days = base.days.sorted()
        let cells = grid(base: base, others: others, days: days)
        let order = base.periods.indices.sorted { base.periods[$0].start < base.periods[$1].start }
        var result: [ScheduleFreeWindow] = []
        for (column, day) in days.enumerated() {
            var open: (start: Int, end: Int)?
            for row in order {
                let period = base.periods[row]
                guard cells[row][column] == .free else {
                    if let window = open { result.append(ScheduleFreeWindow(day: day, start: window.start, end: window.end)) }
                    open = nil
                    continue
                }
                if let window = open, period.start - window.end <= ScheduleSharePayload.maxCoveredBreak {
                    open = (window.start, max(window.end, period.end))
                } else {
                    if let window = open { result.append(ScheduleFreeWindow(day: day, start: window.start, end: window.end)) }
                    open = (period.start, period.end)
                }
            }
            if let window = open { result.append(ScheduleFreeWindow(day: day, start: window.start, end: window.end)) }
        }
        return result
    }

    /// Windows from now onward this week first (today's past windows dropped), then the rest of the week.
    static func upcoming(_ windows: [ScheduleFreeWindow], at date: Date) -> [ScheduleFreeWindow] {
        let (today, minute) = ScheduleSharePayload.clockPosition(of: date)
        return windows
            .filter { $0.day != today || $0.end > minute }
            .sorted { (($0.day - today + 7) % 7, $0.start) < (($1.day - today + 7) % 7, $1.start) }
    }
}
