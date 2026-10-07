import Foundation

// MARK: - Learning Hours (ep.niu.edu.tw 多元學習認證)

/// One domain total from `/Api/MultLearn`, e.g. 服務奉獻 2 / 20.
nonisolated struct LearningHoursSummary: Codable, Equatable, Sendable, Identifiable {
    let abilityID: String
    let ability: String
    let earned: Double
    let required: Double

    var id: String { abilityID }
}

/// One certified activity row from `/Api/MultLearnDetail`. Dates and texts keep
/// the school's original wording (dates look like `2024/9/3`).
nonisolated struct LearningHoursRecord: Codable, Equatable, Sendable {
    let startDate: String
    let endDate: String
    let title: String
    let ability: String
    let hours: String

    var hoursValue: Double { Double(hours) ?? 0 }
}

nonisolated struct LearningHoursSnapshot: Codable, Equatable, Sendable {
    let summaries: [LearningHoursSummary]
    let records: [LearningHoursRecord]
    let fetchedAt: Date
}

nonisolated enum LearningHoursError: LocalizedError, Equatable {
    case credentialsMissing
    case invalidCredentials
    case campusNetworkRequired
    case offline
    case sessionExpired
    case schoolError(String)
    case invalidResponse
    case tooManyPages

    var errorDescription: String? {
        switch self {
        case .credentialsMissing: return "找不到已儲存的登入資訊，請重新登入 App 後再試。"
        case .invalidCredentials: return "學生服務平台登入失敗，請確認帳號密碼；若最近改過密碼，請重新登入 App。"
        case .campusNetworkRequired: return "無法連線至學生服務平台，請連接校園網路後再更新。"
        case .offline: return "目前沒有網路連線，請連線後重試。"
        case .sessionExpired: return "學生服務平台登入已逾時，請稍後重試。"
        case .schoolError(let message): return "學生服務平台回報錯誤：\(message)"
        case .invalidResponse: return "無法辨識學生服務平台的資料格式，請稍後重試。"
        case .tooManyPages: return "時數紀錄頁數異常，已停止讀取，請稍後重試。"
        }
    }
}

// MARK: - Parser

nonisolated enum LearningHoursParser {
    /// Display order matching the graduation card: 服務、多元、專業、綜合.
    static let abilityOrder = ["1", "2", "3", "99"]

    private struct SummaryEnvelope: Decodable {
        let IsSuccess: Bool
        let Message: String?
        let Data: [Item]?

        struct Item: Decodable {
            let AbilityId: FlexibleString
            let Ability: String
            let CaHr: FlexibleNumber
            let TCaHr: FlexibleNumber
        }
    }

    /// The API answers `[]` instead of an error when the session cookie is
    /// missing or expired, so an array root means "not signed in".
    static func parseSummary(_ data: Data) throws -> [LearningHoursSummary] {
        let root = try? JSONSerialization.jsonObject(with: data)
        if root is [Any] { throw LearningHoursError.sessionExpired }
        guard root is [String: Any],
              let envelope = try? JSONDecoder().decode(SummaryEnvelope.self, from: data)
        else { throw LearningHoursError.invalidResponse }
        guard envelope.IsSuccess else {
            let message = envelope.Message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw message.isEmpty ? LearningHoursError.invalidResponse : LearningHoursError.schoolError(message)
        }
        let items = (envelope.Data ?? []).map {
            LearningHoursSummary(abilityID: $0.AbilityId.value, ability: $0.Ability,
                                 earned: $0.CaHr.value, required: $0.TCaHr.value)
        }
        return items.sorted { order(of: $0.abilityID) < order(of: $1.abilityID) }
    }

    struct DetailPage: Equatable {
        let records: [LearningHoursRecord]
        let lastPage: Int
    }

    static func parseDetail(_ html: String) throws -> DetailPage {
        if html.contains("登入逾時") || html.contains("location.replace") {
            throw LearningHoursError.sessionExpired
        }
        guard let pagingRange = html.range(of: "id=\"page_html\"") else {
            throw LearningHoursError.invalidResponse
        }
        let body = String(html[..<pagingRange.lowerBound])
        let paging = String(html[pagingRange.upperBound...])

        var records: [LearningHoursRecord] = []
        let chunks = body.components(separatedBy: "learninghours__tbody-row").dropFirst()
        for chunk in chunks {
            let cells = matches(#"class="learninghours__td"[^>]*>([\s\S]*?)</div>"#, in: chunk).map(cleanText)
            guard cells.count >= 5 else { throw LearningHoursError.invalidResponse }
            records.append(LearningHoursRecord(startDate: cells[0], endDate: cells[1], title: cells[2],
                                               ability: cells[3], hours: cells[4]))
        }

        let pageNumbers = (matches(#"[?&]page=(\d+)"#, in: paging)
            + matches(#"paging__btn[^"]*"[^>]*>\s*(\d+)\s*<"#, in: paging)).compactMap { Int($0) }
        return DetailPage(records: records, lastPage: max(1, pageNumbers.max() ?? 1))
    }

    private static func order(of abilityID: String) -> Int {
        abilityOrder.firstIndex(of: abilityID) ?? abilityOrder.count
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    static func cleanText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        for code in matches(#"&#(\d+);"#, in: text) {
            if let scalar = UInt32(code).flatMap(Unicode.Scalar.init) {
                text = text.replacingOccurrences(of: "&#\(code);", with: String(Character(scalar)))
            }
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The school API mixes JSON strings and numbers for the same fields.
private nonisolated struct FlexibleString: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { value = string }
        else if let int = try? container.decode(Int.self) { value = String(int) }
        else { value = String(try container.decode(Double.self)) }
    }
}

private nonisolated struct FlexibleNumber: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) { value = number; return }
        let string = try container.decode(String.self).trimmingCharacters(in: .whitespaces)
        guard let number = Double(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a number")
        }
        value = number
    }
}
