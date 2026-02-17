import Foundation

// MARK: - CourseInfo

struct CourseInfo: Codable, Hashable {
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

struct ClassPeriod: Codable, Identifiable {
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
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }

    var endMinutes: Int? {
        guard let (_, end) = splitTime() else { return nil }
        let p = end.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }

    var startTimeLabel: String {
        splitTime()?.start ?? ""
    }

    /// Whether this period is currently in progress
    var isCurrentPeriod: Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        guard let nowH = comps.hour, let nowM = comps.minute,
              let start = startMinutes, let end = endMinutes else { return false }
        let now = nowH * 60 + nowM
        return now >= start && now < end
    }
}

// MARK: - ClassSchedule

struct ClassSchedule: Codable {
    let periods: [ClassPeriod]
    let dayCount: Int
    let dayHeaders: [String]  // e.g. ["星期一", "星期二", ...]
    let fetchedAt: Date

    /// Returns true if the cache is still within the 7-day TTL
    var isCacheValid: Bool {
        Date().timeIntervalSince(fetchedAt) < 7 * 24 * 3600
    }

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
