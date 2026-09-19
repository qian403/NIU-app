import Foundation

// MARK: - 行事曆事件類型
enum CalendarEventType: String, Codable, CaseIterable {
    case registration = "選課"
    case exam = "考試"
    case holiday = "假期"
    case important = "重要日期"
    case semester = "學期"
    case activity = "活動"
    case deadline = "截止日期"
    case academic = "教務"

    /// JSON 中使用的型別代碼（腳本/遠端資料多半是英文代碼）
    private var code: String {
        switch self {
        case .registration: return "registration"
        case .exam: return "exam"
        case .holiday: return "holiday"
        case .important: return "important"
        case .semester: return "semester"
        case .activity: return "activity"
        case .deadline: return "deadline"
        case .academic: return "academic"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        // 支援舊版（中文 rawValue）
        if let direct = CalendarEventType(rawValue: value) {
            self = direct
            return
        }

        // 支援新版/腳本（英文代碼）
        switch value.lowercased() {
        case "registration": self = .registration
        case "exam": self = .exam
        case "holiday": self = .holiday
        case "important": self = .important
        case "semester": self = .semester
        case "activity": self = .activity
        case "deadline": self = .deadline
        case "academic": self = .academic
        case "other": self = .important
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown calendar event type: \(value)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // 以英文代碼輸出，避免和資料檔不一致
        try container.encode(code)
    }
    
    var color: String {
        switch self {
        case .registration: return "blue"
        case .exam: return "red"
        case .holiday: return "green"
        case .important: return "orange"
        case .semester: return "purple"
        case .activity: return "cyan"
        case .deadline: return "pink"
        case .academic: return "indigo"
        }
    }
    
    var icon: String {
        switch self {
        case .registration: return "pencil.and.list.clipboard"
        case .exam: return "doc.text.magnifyingglass"
        case .holiday: return "sun.max.fill"
        case .important: return "exclamationmark.circle.fill"
        case .semester: return "calendar"
        case .activity: return "party.popper"
        case .deadline: return "clock.fill"
        case .academic: return "book.closed"
        }
    }
}

// MARK: - 行事曆事件
struct CalendarEvent: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let startDate: String  // ISO 8601 格式: "2024-09-01"
    let endDate: String?   // 可選，如果是單日事件可為 nil
    let type: CalendarEventType
    var sourceURL: URL? = nil
    var sourceText: String? = nil
    
    // 計算屬性：轉換為 Date 物件
    var start: Date? {
        CampusCalendarDate.parse(startDate)
    }
    
    var end: Date? {
        guard let endDate = endDate else { return start }
        return CampusCalendarDate.parse(endDate)
    }
    
    // 是否為多日事件
    var isMultiDay: Bool {
        endDate != nil && endDate != startDate
    }

    // The reviewed feed owns classification; do not turn "期中預警" into an exam.
    var inferredType: CalendarEventType { type }

    func contains(_ date: Date) -> Bool {
        let day = CampusCalendarDate.dayKey(date)
        return startDate <= day && day <= (endDate ?? startDate)
    }

    /// A period's opening/closing days are distinct from days within that period.
    func isBoundary(on date: Date) -> Bool {
        let key = CampusCalendarDate.dayKey(date)
        return key == startDate || key == (endDate ?? startDate)
    }

    var displayTitle: String {
        if isMultiDay && title.hasSuffix("開始") {
            return String(title.dropLast(2)) + "期間"
        }
        return title
    }

    var months: [Int] {
        guard let start, let end else { return [] }
        let calendar = CampusCalendarDate.calendar
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: start))!
        var result: [Int] = []
        while cursor <= end {
            result.append(calendar.component(.month, from: cursor))
            cursor = calendar.date(byAdding: .month, value: 1, to: cursor)!
        }
        return result
    }

    // 格式化日期顯示
    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        formatter.calendar = CampusCalendarDate.calendar
        formatter.timeZone = CampusCalendarDate.calendar.timeZone
        
        guard let startDate = start else { return "" }
        
        if let endDate = end, isMultiDay {
            return "\(formatter.string(from: startDate)) - \(formatter.string(from: endDate))"
        } else {
            return formatter.string(from: startDate)
        }
    }
}

// MARK: - 學期行事曆
struct SemesterCalendar: Codable {
    let semester: String           // 例如: "114-1" (114學年度第1學期)
    let academicYear: String       // 例如: "114"
    let semesterNumber: Int        // 1 或 2
    let title: String              // 例如: "國立宜蘭大學114學年度第1學期行事曆"
    let events: [CalendarEvent]
    
    // 按月份分組事件
    var eventsByMonth: [Int: [CalendarEvent]] {
        var grouped: [Int: [CalendarEvent]] = [:]
        for event in events {
            for month in event.months { grouped[month, default: []].append(event) }
        }

        // 對每個月的事件按日期排序
        for (month, _) in grouped {
            grouped[month]?.sort { ($0.start ?? Date()) < ($1.start ?? Date()) }
        }
        
        return grouped
    }
    
    // 獲取所有包含事件的月份（已排序）
    var monthsWithEvents: [Int] {
        CampusCalendarDate.monthOrder.filter { eventsByMonth[$0] != nil }
    }
}


extension CalendarEvent {
    init(_ event: CampusCalendarEvent, document: CampusCalendarDocument) {
        id = event.id
        title = event.title
        description = event.note
        startDate = event.startDate
        endDate = event.endDate
        switch event.category {
        case .semester: type = .semester
        case .registration: type = .registration
        case .exam: type = .exam
        case .holiday: type = .holiday
        case .deadline: type = .deadline
        case .activity: type = .activity
        case .academic: type = .academic
        case .other: type = .important
        }
        sourceText = event.sourceText
        sourceURL = document.sources.first(where: { $0.id == event.sourceId }).flatMap { URL(string: $0.url) }
    }
}

/// A Sunday-first month, always interpreted in the school's time zone.
struct AcademicCalendarMonth {
    let start: Date
    let days: [Date]
    let leadingEmptyDays: Int

    init(academicYear: Int, month: Int) {
        let calendar = CampusCalendarDate.calendar
        let year = academicYear + 1911 + (month < 8 ? 1 : 0)
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        self.start = start
        leadingEmptyDays = calendar.component(.weekday, from: start) - 1
        days = calendar.range(of: .day, in: .month, for: start)!.map {
            calendar.date(byAdding: .day, value: $0 - 1, to: start)!
        }
    }

    var cells: [Date?] {
        let count = leadingEmptyDays + days.count
        let trailing = (7 - count % 7) % 7
        return Array(repeating: nil, count: leadingEmptyDays) + days.map(Optional.some)
            + Array(repeating: nil, count: trailing)
    }

    /// Each event appears once: carry-over periods first, then events by start day.
    func eventSections(_ events: [CalendarEvent]) -> [AcademicCalendarEventSection] {
        let firstDay = CampusCalendarDate.dayKey(start)
        let lastDay = CampusCalendarDate.dayKey(days.last!)
        let matching = events.filter {
            $0.startDate <= lastDay && ($0.endDate ?? $0.startDate) >= firstDay
        }.sorted { ($0.startDate, $0.id) < ($1.startDate, $1.id) }
        let carryover = matching.filter { $0.startDate < firstDay }
        var sections: [AcademicCalendarEventSection] = carryover.isEmpty ? [] : [
            AcademicCalendarEventSection(date: nil, events: carryover)
        ]
        let startsInMonth = Dictionary(grouping: matching.filter { $0.startDate >= firstDay }, by: \.startDate)
        for key in startsInMonth.keys.sorted() {
            sections.append(AcademicCalendarEventSection(date: CampusCalendarDate.parse(key), events: startsInMonth[key]!))
        }
        return sections
    }

    func selectedDate(day: Int?, now: Date = Date()) -> Date {
        let calendar = CampusCalendarDate.calendar
        let defaultDay = calendar.isDate(now, equalTo: start, toGranularity: .month)
            ? calendar.component(.day, from: now) : 1
        return days[min(max((day ?? defaultDay) - 1, 0), days.count - 1)]
    }
}

struct AcademicCalendarEventSection: Identifiable {
    /// nil identifies periods carried over from an earlier month.
    let date: Date?
    let events: [CalendarEvent]
    var id: String { date.map(CampusCalendarDate.dayKey) ?? "carryover" }
}
