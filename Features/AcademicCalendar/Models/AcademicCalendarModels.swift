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
    
    // 計算屬性：轉換為 Date 物件
    var start: Date? {
        ISO8601DateFormatter().date(from: startDate + "T00:00:00Z")
    }
    
    var end: Date? {
        guard let endDate = endDate else { return start }
        return ISO8601DateFormatter().date(from: endDate + "T00:00:00Z")
    }
    
    // 是否為多日事件
    var isMultiDay: Bool {
        endDate != nil && endDate != startDate
    }

    /// Some upstream feeds mis-label midterm/final events as non-exam types.
    /// Use title/description keywords to infer the display/filter type.
    var inferredType: CalendarEventType {
        let text = (title + " " + (description ?? "")).lowercased()
        if text.contains("期中") || text.contains("期末") || text.contains("考試") || text.contains("補考") {
            return .exam
        }
        return type
    }
    
    // 格式化日期顯示
    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        
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
        let calendar = Calendar.current
        
        for event in events {
            if let date = event.start {
                let month = calendar.component(.month, from: date)
                if grouped[month] == nil {
                    grouped[month] = []
                }
                grouped[month]?.append(event)
            }
        }
        
        // 對每個月的事件按日期排序
        for (month, _) in grouped {
            grouped[month]?.sort { ($0.start ?? Date()) < ($1.start ?? Date()) }
        }
        
        return grouped
    }
    
    // 獲取所有包含事件的月份（已排序）
    var monthsWithEvents: [Int] {
        eventsByMonth.keys.sorted()
    }
}

// MARK: - 行事曆資料來源
struct AcademicCalendarData: Codable {
    let calendars: [SemesterCalendar]
    let lastUpdated: String?  // ISO 8601 格式
    
    // 支援兩種 JSON 格式
    enum CodingKeys: String, CodingKey {
        case calendars
        case semesters  // 本地 JSON 使用 "semesters"
        case pages
        case lastUpdated
        case academicYearROC = "academic_year_roc"
        case latestMaintenanceDateISO = "latest_maintenance_date_iso"
    }
    
    // 手動初始化
    init(calendars: [SemesterCalendar], lastUpdated: String?) {
        self.calendars = calendars
        self.lastUpdated = lastUpdated
    }
    
    init(from decoder: Decoder) throws {
        // 嘗試解析最外層
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // 嘗試解析 "calendars" 或 "semesters"
        if let calendars = try? container.decode([SemesterCalendar].self, forKey: .calendars) {
            self.calendars = calendars
        } else if let semesters = try? container.decode([LocalSemesterFormat].self, forKey: .semesters) {
            // 轉換本地格式到標準格式
            self.calendars = semesters.map { local in
                SemesterCalendar(
                    semester: local.name,
                    academicYear: String(local.year),
                    semesterNumber: local.semester,
                    title: "國立宜蘭大學\(local.year)學年度第\(local.semester)學期行事曆",
                    events: local.events
                )
            }
        } else if let pages = try? container.decode([RemoteAcademicCalendarPage].self, forKey: .pages) {
            let explicitAcademicYear = try? container.decode(Int.self, forKey: .academicYearROC)
            let groupedPages = Dictionary(grouping: pages, by: \.semester)
            self.calendars = groupedPages.keys.sorted().compactMap { semesterNumber in
                guard let semesterPages = groupedPages[semesterNumber], !semesterPages.isEmpty else { return nil }
                let firstPage = semesterPages.sorted { $0.pageNumber < $1.pageNumber }.first!
                let startDate = semesterPages
                    .flatMap(\.events)
                    .compactMap(\.start)
                    .sorted()
                    .first
                let rocYear = explicitAcademicYear
                    ?? startDate.map { date -> Int in
                        let year = Calendar.current.component(.year, from: date) - 1911
                        return semesterNumber == 2 ? year - 1 : year
                    }
                    ?? 114
                return SemesterCalendar(
                    semester: "\(rocYear)-\(semesterNumber)",
                    academicYear: String(rocYear),
                    semesterNumber: semesterNumber,
                    title: firstPage.title,
                    events: semesterPages.flatMap(\.convertedEvents)
                )
            }
        } else {
            self.calendars = []
        }

        self.lastUpdated = (try? container.decode(String.self, forKey: .lastUpdated))
            ?? (try? container.decode(String.self, forKey: .latestMaintenanceDateISO))
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(calendars, forKey: .calendars)
        try container.encodeIfPresent(lastUpdated, forKey: .lastUpdated)
    }

    // 根據學期代碼取得行事曆
    func calendar(for semester: String) -> SemesterCalendar? {
        calendars.first { $0.semester == semester }
    }
    
    // 獲取所有可用的學期
    var availableSemesters: [String] {
        calendars.map { $0.semester }.sorted(by: >)
    }
}

// MARK: - Firebase 包裝格式
struct FirebaseCalendarWrapper: Codable {
    let semesters: [LocalSemesterFormat]
}

// MARK: - 本地 JSON 格式支援
struct LocalSemesterFormat: Codable {
    let id: String?
    let name: String
    let year: Int
    let semester: Int
    let events: [CalendarEvent]
}

struct RemoteAcademicCalendarPage: Codable {
    let pageNumber: Int
    let semester: Int
    let title: String
    let events: [RemoteAcademicCalendarEvent]

    enum CodingKeys: String, CodingKey {
        case pageNumber = "page_number"
        case semester
        case title
        case events
    }
}

struct RemoteAcademicCalendarEvent: Codable {
    let dateText: String
    let startDate: String
    let endDate: String
    let description: String
    let isRange: Bool

    enum CodingKeys: String, CodingKey {
        case dateText = "date_text"
        case startDate = "start_date"
        case endDate = "end_date"
        case description
        case isRange = "is_range"
    }

    var start: Date? {
        ISO8601DateFormatter().date(from: startDate + "T00:00:00Z")
    }
}

extension RemoteAcademicCalendarEvent {
    var asCalendarEvent: CalendarEvent {
        CalendarEvent(
            id: "\(startDate)-\(description)",
            title: description,
            description: nil,
            startDate: startDate,
            endDate: endDate == startDate ? nil : endDate,
            type: inferredType
        )
    }

    private var inferredType: CalendarEventType {
        let text = description.lowercased()
        if text.contains("選") || text.contains("加退選") || text.contains("停修") {
            return .registration
        }
        if text.contains("考") || text.contains("評量") || text.contains("預警") {
            return .exam
        }
        if text.contains("放假") || text.contains("假期") || text.contains("春節") || text.contains("端午") || text.contains("中秋") || text.contains("清明") || text.contains("元旦") || text.contains("國慶") {
            return .holiday
        }
        if text.contains("截止") || text.contains("送交") || text.contains("公告") || text.contains("郵寄") {
            return .deadline
        }
        if text.contains("學期") || text.contains("開學") || text.contains("暑假") || text.contains("寒假") {
            return .semester
        }
        if text.contains("校慶") || text.contains("畢業典禮") || text.contains("訓練") || text.contains("營隊") || text.contains("博覽會") || text.contains("薪傳") {
            return .activity
        }
        return .important
    }
}

extension RemoteAcademicCalendarPage {
    var convertedEvents: [CalendarEvent] {
        events.map(\.asCalendarEvent)
    }
}
