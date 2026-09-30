import Foundation

enum EventTextLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributedText(_ source: String) -> AttributedString {
        let text = source.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        var result = AttributedString(text)
        let matches = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        for match in matches {
            guard let url = match.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: text),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start..<end].link = url
        }
        return result
    }
}

/// 僅由公開活動欄位組成，避免分享個人報名資料或 WebView 的 session URL。
struct EventShareContent {
    let name: String
    let department: String
    let time: String
    let location: String
    let registrationTime: String
    let eventID: String

    var url: URL? {
        // 校方活動編號為 ASCII 數字，不接受路徑、query 或 fragment。
        guard !eventID.isEmpty,
              eventID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Act/Apply/\(eventID)")
    }

    var text: String {
        var lines = [name]
        for (label, value) in [("主辦單位", department), ("活動時間", time),
                               ("活動地點", location), ("報名時間", registrationTime)] {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { lines.append("\(label)：\(value)") }
        }
        if let url { lines.append("活動連結：\(url.absoluteString)") }
        return lines.joined(separator: "\n")
    }
}

extension EventData {
    var shareContent: EventShareContent {
        EventShareContent(name: name, department: department, time: eventTime,
                          location: eventLocation, registrationTime: eventRegisterTime,
                          eventID: eventSerialID)
    }
}

extension EventData_Apply {
    var shareContent: EventShareContent {
        EventShareContent(name: name, department: department, time: eventTime,
                          location: eventLocation, registrationTime: eventRegisterTime,
                          eventID: eventSerialID)
    }
}

// MARK: - 可報名活動資料模型
struct EventData: Identifiable, Codable {
    var id: String { eventSerialID }
    let name: String
    let department: String
    let event_state: String
    let eventSerialID: String
    let eventTime: String
    let eventLocation: String
    let eventRegisterTime: String
    let eventDetail: String
    let contactInfoName: String
    let contactInfoTel: String
    let contactInfoMail: String
    let Related_links: String
    let Multi_factor_authentication: String
    let eventPeople: String
    let Remark: String
}

// MARK: - 已報名活動資料模型
struct EventData_Apply: Identifiable, Codable {
    var id: String { eventSerialID }
    let name: String
    let department: String
    let state: String
    let event_state: String
    let eventSerialID: String
    let eventTime: String
    let eventLocation: String
    let eventRegisterTime: String
    let eventDetail: String
    let contactInfoName: String
    let contactInfoTel: String
    let contactInfoMail: String
    let Related_links: String
    let Multi_factor_authentication: String
    let Remark: String
}

// MARK: - 報名資訊
struct EventInfo: Codable {
    var RequestVerificationToken: String
    var SignId: String
    var role: String
    var classes: String
    var schnum: String
    var name: String
    var Tel: String
    var Mail: String
    var selectedFood: String
    var selectedProof: String
    var Remark: String
}
