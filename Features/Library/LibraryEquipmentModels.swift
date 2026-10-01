import Foundation

nonisolated enum LibraryEquipmentError: LocalizedError, Equatable {
    case loginRequired
    case invalidResponse
    case unavailable
    case timedOut
    case rejected(String)
    case uncertainMutation

    var errorDescription: String? {
        switch self {
        case .loginRequired: return "請使用目前 App 的帳號完成圖書館登入或人機驗證，再繼續預約。"
        case .invalidResponse: return "無法辨識校方設備資料，請稍後重新整理。"
        case .unavailable: return "目前無法連線至圖書館，請稍後再試。"
        case .timedOut: return "圖書館回應逾時，請稍後再試。"
        case .rejected(let message): return message
        case .uncertainMutation: return "尚無法確認校方是否完成操作。請先重新整理「我的預約」核對，勿立即重複送出。"
        }
    }
}

nonisolated enum LibraryEquipmentDate {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .gmt
        return value
    }

    static func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    static func at(_ minute: Int, on date: Date) -> Date {
        day(date).addingTimeInterval(TimeInterval(minute * 60))
    }
    static func format(_ date: Date, pattern: String = "yyyy/MM/dd") -> String {
        (displayFormatters[pattern] ?? formatter(pattern)).string(from: date)
    }
    static func time(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
    static func weekday(_ date: Date) -> String {
        let names = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        return names[calendar.component(.weekday, from: date) - 1]
    }
    static func minute(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0..<60).contains(minute),
              hour != 24 || minute == 0 else { return nil }
        return hour * 60 + minute
    }
    static func parse(_ text: String) -> Date? {
        for iso in isoParsers {
            if let date = iso.date(from: text) { return date }
        }
        for formatter in timestampParsers {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // Formatters are configured once and only read afterwards; Foundation
    // documents DateFormatter/ISO8601DateFormatter as thread-safe for that use.
    private static let displayFormatters = Dictionary(uniqueKeysWithValues: [
        "yyyy/MM/dd", "yyyy/MM/dd HH:mm", "yyyy-MM-dd", "MM/dd HH:mm",
        "HH:mm", "M/d", "M月", "M月d日", "d"
    ].map { ($0, formatter($0)) })

    private static let isoParsers = [
        [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]
    ].map { (options: ISO8601DateFormatter.Options) in
        let iso = ISO8601DateFormatter()
        iso.formatOptions = options
        return iso
    }

    private static let timestampParsers = [
        "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
        "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"
    ].map { pattern in
        let formatter = formatter(pattern)
        formatter.isLenient = false
        return formatter
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter
    }
}

nonisolated struct LibraryEquipmentGroup: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let timeType: Int
    let total: Int
    let available: Int
}

nonisolated struct LibraryEquipmentItem: Identifiable, Decodable, Equatable, Sendable {
    let id: Int
    let name: String
}

nonisolated struct LibraryEquipmentInterval: Equatable, Sendable {
    let equipmentID: Int
    let start: Date
    let end: Date

    func overlaps(start otherStart: Date, end otherEnd: Date) -> Bool {
        start < otherEnd && otherStart < end
    }
}

nonisolated struct LibraryEquipmentSchedule: Equatable, Sendable {
    let equipment: [LibraryEquipmentItem]
    let occupied: [LibraryEquipmentInterval]

    func isAvailable(equipmentID: Int, start: Date, end: Date, now: Date = Date()) -> Bool {
        start >= now && end > start && !occupied.contains {
            $0.equipmentID == equipmentID && $0.overlaps(start: start, end: end)
        }
    }
}

nonisolated struct LibraryEquipmentPolicy: Equatable, Sendable {
    let minimumHours: Double
    let maximumHours: Double
    let remainingHours: Double
    let openMinute: Int
    let closeMinute: Int

    func validate(_ draft: LibraryEquipmentDraft, schedule: LibraryEquipmentSchedule,
                  now: Date = Date()) throws {
        let hours = Double(draft.endMinute - draft.startMinute) / 60
        guard draft.startMinute % 30 == 0, draft.endMinute % 30 == 0,
              draft.startMinute >= openMinute, draft.endMinute <= closeMinute,
              hours >= minimumHours, hours <= maximumHours, hours <= remainingHours else {
            throw LibraryEquipmentError.rejected("所選時段不符合校方使用時間或剩餘額度，請重新選擇。")
        }
        guard schedule.equipment.contains(where: { $0.id == draft.equipment.id }),
              schedule.isAvailable(equipmentID: draft.equipment.id, start: draft.start,
                                   end: draft.end, now: now) else {
            throw LibraryEquipmentError.rejected("所選時段已開始或已被預約，請重新整理後選擇其他時段。")
        }
    }
}

nonisolated struct LibraryEquipmentDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let group: LibraryEquipmentGroup
    let equipment: LibraryEquipmentItem
    let date: Date
    let startMinute: Int
    let endMinute: Int
    let policy: LibraryEquipmentPolicy

    init(group: LibraryEquipmentGroup, equipment: LibraryEquipmentItem, date: Date,
         startMinute: Int, endMinute: Int, policy: LibraryEquipmentPolicy) {
        id = UUID()
        self.group = group
        self.equipment = equipment
        self.date = LibraryEquipmentDate.day(date)
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.policy = policy
    }
    var start: Date { LibraryEquipmentDate.at(startMinute, on: date) }
    var end: Date { LibraryEquipmentDate.at(endMinute, on: date) }
    var timeLabel: String {
        "\(LibraryEquipmentDate.time(startMinute))–\(LibraryEquipmentDate.time(endMinute))"
    }
}

nonisolated struct LibraryEquipmentReservation: Identifiable, Equatable, Sendable {
    // The website cancels equipmentCirContent.id, not equipmentCir.id.
    let id: Int
    let equipmentID: Int
    let equipmentName: String
    let start: Date
    let end: Date
    let keepUntil: Date?
}

nonisolated struct LibraryEquipmentCompletion: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case reserved, cancelled }
    let id = UUID()
    let kind: Kind
    let equipmentName: String
    let start: Date
    let end: Date
    var refreshFailed = false

    var title: String { kind == .reserved ? "預約完成" : "已取消預約" }
    var message: String {
        let details = "\(equipmentName)\n\(LibraryEquipmentDate.format(start)) \(LibraryEquipmentDate.format(start, pattern: "HH:mm"))–\(LibraryEquipmentDate.format(end, pattern: "HH:mm"))"
        let result = kind == .reserved ? "請依圖書館規定報到，可至「我的預約」查看。" : "此筆預約已由校方確認取消。"
        return details + "\n" + result + (refreshFailed ? "\n操作已成功，但清單更新失敗，請重新整理。" : "")
    }
}

nonisolated enum LibraryReservationPeriod: String, CaseIterable, Identifiable, Sendable {
    case all, today, tomorrow, week
    var id: Self { self }
    var title: String {
        switch self {
        case .all: return "全部日期"
        case .today: return "今天"
        case .tomorrow: return "明天"
        case .week: return "一週"
        }
    }
}

nonisolated enum LibraryReservationSearch {
    static func filter(_ records: [LibraryEquipmentReservation], query: String,
                       period: LibraryReservationPeriod, equipmentID: Int?,
                       now: Date = Date()) -> [LibraryEquipmentReservation] {
        let today = LibraryEquipmentDate.day(now)
        let tomorrow = LibraryEquipmentDate.calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let dayAfterTomorrow = LibraryEquipmentDate.calendar.date(byAdding: .day, value: 2, to: today) ?? tomorrow
        let nextWeek = LibraryEquipmentDate.calendar.date(byAdding: .day, value: 7, to: today) ?? tomorrow
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return records.filter { record in
            guard equipmentID == nil || record.equipmentID == equipmentID else { return false }
            switch period {
            case .all: break
            case .today: guard record.start < tomorrow && record.end > today else { return false }
            case .tomorrow: guard record.start < dayAfterTomorrow && record.end > tomorrow else { return false }
            case .week: guard record.start < nextWeek && record.end > today else { return false }
            }
            let searchable = [record.equipmentName,
                LibraryEquipmentDate.format(record.start, pattern: "yyyy/MM/dd HH:mm"),
                LibraryEquipmentDate.format(record.end, pattern: "yyyy/MM/dd HH:mm"),
                LibraryEquipmentDate.format(record.start, pattern: "yyyy-MM-dd"),
                LibraryEquipmentDate.format(record.end, pattern: "yyyy-MM-dd"),
                LibraryEquipmentDate.weekday(record.start)].joined(separator: " ")
            return terms.allSatisfy { searchable.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}

nonisolated struct LibraryEquipmentSlot: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case available, occupied, past, tooShort, quotaUnavailable
    }
    let minute: Int
    let state: State
    let continuousMinutes: Int
    let isSelected: Bool
    let isStart: Bool
    var id: Int { minute }
}

nonisolated enum LibraryEquipmentDecoding {
    struct GroupResult: Decodable, Sendable {
        let getEquipmentGroupInfo: GroupList
        struct GroupList: Decodable, Sendable { let eqgroupitemlist: [Entry] }
        struct Entry: Decodable, Sendable {
            let equipmentGroup: Group
            let ebPolicy: Policy?
            let useNum: Int
            let equipmentNum: Int
        }
        struct Group: Decodable, Sendable { let id: Int; let name: String }
        struct Policy: Decodable, Sendable { let timeType: Int }
        var groups: [LibraryEquipmentGroup] {
            getEquipmentGroupInfo.eqgroupitemlist.compactMap { row in
                guard let policy = row.ebPolicy, policy.timeType == 0 else { return nil }
                return LibraryEquipmentGroup(id: row.equipmentGroup.id, name: row.equipmentGroup.name,
                                             timeType: policy.timeType, total: row.equipmentNum,
                                             available: max(0, row.equipmentNum - row.useNum))
            }
        }
    }

    struct Timestamp: Decodable, Sendable {
        let date: Date
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self),
               let date = LibraryEquipmentDate.parse(text) {
                self.date = date
            } else if let number = try? container.decode(Double.self), number.isFinite {
                date = Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
            } else { throw LibraryEquipmentError.invalidResponse }
        }
    }

    struct ScheduleResult: Decodable, Sendable {
        let getEquipmentInfoList: EquipmentList
        let getReserveEquipmentList: ReserveList
        struct EquipmentList: Decodable, Sendable { let eqgroupitemlist: [EquipmentEntry] }
        struct EquipmentEntry: Decodable, Sendable { let equipment: LibraryEquipmentItem }
        struct ReserveList: Decodable, Sendable { let eqgroupitemlist: [ReserveEntry] }
        struct ReserveEntry: Decodable, Sendable { let equipmentCir: Circulation? }
        struct Circulation: Decodable, Sendable {
            let equipmentId: Int
            let startDate: Timestamp
            let endDate: Timestamp
        }
        func schedule() throws -> LibraryEquipmentSchedule {
            let occupied = try getReserveEquipmentList.eqgroupitemlist.compactMap { row -> LibraryEquipmentInterval? in
                guard let interval = row.equipmentCir else { return nil }
                guard interval.endDate.date > interval.startDate.date else {
                    throw LibraryEquipmentError.invalidResponse
                }
                return LibraryEquipmentInterval(equipmentID: interval.equipmentId,
                                                start: interval.startDate.date, end: interval.endDate.date)
            }
            return LibraryEquipmentSchedule(equipment: getEquipmentInfoList.eqgroupitemlist.map(\.equipment),
                                            occupied: occupied)
        }
    }

    struct PolicyResult: Decodable, Sendable {
        let getDayReservedByReader: Result
        struct Result: Decodable, Sendable { let success: Bool; let data: String?; let message: String? }
        func policy() throws -> LibraryEquipmentPolicy {
            let result = getDayReservedByReader
            guard result.success, let text = result.data, let data = text.data(using: .utf8) else {
                throw LibraryEquipmentError.rejected("校方未開放此設備或日期的預約，請選擇其他設備或日期。")
            }
            struct Rules: Decodable {
                let canReserveMinUnit: Number
                let canReserveMaxUnit: Number
                let maxCanReserveTotalUnit: Number
                let inReserve: Number
                let openTime: String
                let closeTime: String
            }
            let rules = try JSONDecoder().decode(Rules.self, from: data)
            guard rules.canReserveMinUnit.value > 0,
                  rules.canReserveMaxUnit.value >= rules.canReserveMinUnit.value,
                  rules.maxCanReserveTotalUnit.value >= 0, rules.inReserve.value >= 0,
                  let open = LibraryEquipmentDate.minute(rules.openTime),
                  let close = LibraryEquipmentDate.minute(rules.closeTime), close > open else {
                throw LibraryEquipmentError.invalidResponse
            }
            return LibraryEquipmentPolicy(minimumHours: rules.canReserveMinUnit.value,
                                          maximumHours: rules.canReserveMaxUnit.value,
                                          remainingHours: max(0, rules.maxCanReserveTotalUnit.value - rules.inReserve.value),
                                          openMinute: open, closeMinute: close)
        }
    }

    struct Number: Decodable, Sendable {
        let value: Double
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let number: Double?
            if let value = try? container.decode(Double.self) { number = value }
            else if let text = try? container.decode(String.self) { number = Double(text) }
            else { number = nil }
            guard let number, number.isFinite else { throw LibraryEquipmentError.invalidResponse }
            value = number
        }
    }

    struct ReservationsResult: Decodable, Sendable {
        let reservelist: List
        struct List: Decodable, Sendable { let success: Bool; let eqgroupitemlist: [Entry]? }
        struct Entry: Decodable, Sendable {
            let equipment: LibraryEquipmentItem
            let equipmentCir: Circulation
            let equipmentCirContent: Content
        }
        struct Circulation: Decodable, Sendable {
            let startDate: Timestamp
            let endDate: Timestamp
            let reserveKeepDate: Timestamp?
        }
        struct Content: Decodable, Sendable { let id: Int }
        func reservations() throws -> [LibraryEquipmentReservation] {
            guard let rows = reservelist.eqgroupitemlist,
                  reservelist.success || rows.isEmpty else {
                throw LibraryEquipmentError.invalidResponse
            }
            return try rows.map { row in
                guard row.equipmentCir.endDate.date > row.equipmentCir.startDate.date else {
                    throw LibraryEquipmentError.invalidResponse
                }
                return LibraryEquipmentReservation(id: row.equipmentCirContent.id,
                    equipmentID: row.equipment.id, equipmentName: row.equipment.name,
                    start: row.equipmentCir.startDate.date, end: row.equipmentCir.endDate.date,
                    keepUntil: row.equipmentCir.reserveKeepDate?.date)
            }.sorted { $0.start < $1.start }
        }
    }

    struct MutationResult: Decodable, Sendable {
        let reserveEquipmentCir: Mutation?
        let cancelEquipmentCir: Mutation?
        struct Mutation: Decodable, Sendable { let success: Bool; let message: String? }
    }
}
