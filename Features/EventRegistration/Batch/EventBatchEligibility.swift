import Foundation

enum EventBatchEligibility: Equatable {
    case eligible(String)
    case excluded(String)

    var canSubmit: Bool { if case .eligible = self { return true }; return false }
    var reason: String {
        switch self { case .eligible(let reason), .excluded(let reason): return reason }
    }

    /// Only fresh school fields are considered. An unknown date is not itself a rejection:
    /// an explicit school "報名中" status can still authorize attempting its registration form.
    static func evaluate(_ event: EventData, appliedIDs: Set<String>, uncertainIDs: Set<String>, now: Date) -> Self {
        let id = event.eventSerialID
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return .excluded("無法判定：活動編號不完整。")
        }
        if appliedIDs.contains(id) { return .excluded("已報名：校方已報名清單已有此活動。") }
        if uncertainIDs.contains(id) { return .excluded("結果不明：本次登入曾送出，請先查看「已報名活動」，勿立即重送。") }
        let state = event.event_state
        if ["截止", "結束", "停止報名"].contains(where: state.contains) { return .excluded("已截止：\(state)") }
        if ["未開放", "尚未開放", "尚未開始報名"].contains(where: state.contains) { return .excluded("未開放：\(state)") }
        if ["額滿", "已滿"].contains(where: state.contains) || explicitlyFull(event.eventPeople) {
            return .excluded("額滿：校方狀態或名額欄位顯示已滿。")
        }
        let dates = registrationDates(event.eventRegisterTime)
        if let start = dates.first, now < start.start { return .excluded("未開放：尚未到校方列出的報名日期。") }
        // Compare at the precision actually published. Do not invent a 23:59:59 deadline.
        if dates.count == 2, let end = dates.last, now >= end.end { return .excluded("已截止：已超過校方列出的報名時間。") }
        guard state.contains("報名中") || state.contains("開放報名") else {
            return .excluded("無法判定：校方未明確顯示可報名（\(state.isEmpty ? "狀態空白" : state)）。")
        }
        return .eligible(dates.count == 2 ? "校方顯示可報名；送出時仍由校方確認資格與名額。" : "校方顯示報名中，日期資料不完整；確認後由校方表單再次判定。")
    }

    private static func explicitlyFull(_ text: String) -> Bool {
        // Unlabelled pairs (e.g. "30人\n10人") have no reliable capacity/count ordering.
        // Only compare numbers whose meaning is present in the source text.
        func number(_ pattern: String) -> Int? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
        if text.contains("額滿") { return true }
        // The public school HTML labels these as 正取：7 / 27，備取：0 / 5.
        // A full regular quota with available standby places is still worth asking school.
        func quota(_ label: String) -> (used: Int, total: Int)? {
            guard let regex = try? NSRegularExpression(pattern: label + "\\s*[:：]\\s*([0-9]+)\\s*/\\s*([0-9]+)"),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let usedRange = Range(match.range(at: 1), in: text), let totalRange = Range(match.range(at: 2), in: text),
                  let used = Int(text[usedRange]), let total = Int(text[totalRange]) else { return nil }
            return (used, total)
        }
        if let regular = quota("正取"), regular.total > 0, regular.used >= regular.total {
            if let standby = quota("備取") { return standby.used >= standby.total }
            return true
        }
        guard let capacity = number("(?:限額|名額|上限)\\s*[:：]?\\s*([0-9]+)"), capacity > 0,
              let registered = number("(?:已報名|報名人數)\\s*[:：]?\\s*([0-9]+)") else { return false }
        return registered >= capacity
    }

    /// School scraper removes spaces before times, so both 2026/10/0412:00 and
    /// 2026/10/04 12:00 are supported. Malformed/reversed ranges remain unknown.
    static func registrationDates(_ text: String) -> [DateInterval] {
        let pattern = #"(?<![0-9])([0-9]{4})[/-]([0-9]{1,2})[/-]([0-9]{2}|[0-9])(?:\s*(上午|下午|AM|PM)?\s*([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?)?(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .gmt
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 2 else { return [] }
        var result: [DateInterval] = []
        for match in matches {
            func value(_ index: Int) -> Int? { Range(match.range(at: index), in: text).flatMap { Int(text[$0]) } }
            let meridiem = Range(match.range(at: 4), in: text).map { String(text[$0]) }
            var hour = value(5) ?? 0
            if let meridiem {
                guard (1...12).contains(hour) else { return [] }
                hour = hour % 12 + (["下午", "PM"].contains(meridiem) ? 12 : 0)
            }
            let parts = DateComponents(year: value(1), month: value(2), day: value(3), hour: hour,
                                       minute: value(6) ?? 0, second: value(7) ?? 0)
            guard let date = calendar.date(from: parts),
                  calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == parts,
                  let interval = calendar.dateInterval(of: value(7) != nil ? .second : (value(5) != nil ? .minute : .day), for: date) else { return [] }
            result.append(interval)
        }
        guard result[0].start <= result[1].start else { return [] }
        return result
    }
}
