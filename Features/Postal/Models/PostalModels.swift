import Foundation

nonisolated enum PostalStatus: String, CaseIterable, Identifiable, Sendable {
    case waiting = ""
    case collected = "Y"
    case returned = "R"

    var id: String { title }
    var title: String {
        switch self {
        case .waiting: return "未領取"
        case .collected: return "已領取"
        case .returned: return "退件"
        }
    }
    var symbol: String {
        switch self {
        case .waiting: return "shippingbox"
        case .collected: return "checkmark.circle"
        case .returned: return "arrow.uturn.backward.circle"
        }
    }
}

nonisolated struct PostalQuery: Equatable, Sendable {
    var name = ""
    var phone = ""
    var trackingNumber = ""
    var status = PostalStatus.waiting

    var normalized: Self {
        Self(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
             phone: phone.trimmingCharacters(in: .whitespacesAndNewlines),
             trackingNumber: trackingNumber.trimmingCharacters(in: .whitespacesAndNewlines),
             status: status)
    }
    var canSearch: Bool {
        let query = normalized
        return !query.name.isEmpty || !query.phone.isEmpty || !query.trackingNumber.isEmpty
    }
}

nonisolated struct PostalRecord: Identifiable, Equatable, Sendable {
    let sequence: String
    let receivedDate: String
    let trackingNumber: String
    let unit: String
    let recipient: String
    let category: String
    let quantity: String
    let signature: String
    let completedDate: String
    let note: String
    let status: PostalStatus

    var id: String { [sequence, receivedDate, trackingNumber, recipient, unit].joined(separator: "|") }
}

nonisolated struct PostalPage: Sendable {
    let records: [PostalRecord]
    let query: PostalQuery
    let pageIndex: Int
    let pageCount: Int
    let nextForm: [String: String]?
}

nonisolated enum PostalError: Error {
    case invalidResponse
    case unavailable
    case sessionExpired
}

/// A changed WebForms/Telerik contract is an error, never an empty result.
nonisolated enum PostalHTML {
    static func form(in html: String) throws -> [String: String] {
        var fields: [String: String] = [:]
        var names = Set<String>()
        for input in matches(#"<input\b([^>]*)>"#, in: html) {
            let attrs = attributes(input[1])
            guard let name = attrs["name"] else { continue }
            names.insert(name)
            if attrs["type"]?.lowercased() == "hidden" {
                fields[name] = attrs["value"] ?? ""
            }
        }
        guard names.contains("Key_name"), names.contains("Btn_Search"),
              !(fields["__VIEWSTATE"] ?? "").isEmpty,
              !(fields["__EVENTVALIDATION"] ?? "").isEmpty else { throw PostalError.invalidResponse }
        return fields
    }

    static func searchForm(_ fields: [String: String], query: PostalQuery) -> [String: String] {
        var fields = fields
        fields["__EVENTTARGET"] = ""
        fields["__EVENTARGUMENT"] = ""
        fields["DL_Status"] = query.status.rawValue
        fields["CB_Kind"] = ""
        fields["CB_Unit"] = ""
        fields["RB_Date"] = "0"
        fields["Key_name"] = query.name
        fields["Key_Phone"] = query.phone
        fields["Key_BillID"] = query.trackingNumber
        fields["Btn_Search"] = "開始查詢"
        return fields
    }

    static func page(_ html: String, query: PostalQuery) throws -> PostalPage {
        let fields = try form(in: html)
        guard let gridStart = matches(#"<table\b[^>]*\bid=["']RadGrid1_ctl00["'][^>]*>"#, in: html).first?.first,
              let range = html.range(of: gridStart) else { throw PostalError.invalidResponse }
        let grid = String(html[range.upperBound...])
        let headers = matches(#"<th\b[^>]*>(.*?)</th>"#, in: grid).map { text($0[1]) }
        let expected = ["序號", "收件日期", "郵件號碼", "收件單位", "收件者",
                        "類別", "數量", "是否簽收", "簽收(退件)日期", "備註"]
        guard Array(headers.prefix(10)) == expected else { throw PostalError.invalidResponse }

        var records: [PostalRecord] = []
        var explicitlyEmpty = false
        for row in matches(#"<tr\b([^>]*)>(.*?)</tr>"#, in: grid) {
            let classes = Set((attributes(row[1])["class"] ?? "").split(separator: " ").map(String.init))
            if classes.contains("rgNoRecords") { explicitlyEmpty = text(row[2]).contains("查無資料") }
            guard !classes.isDisjoint(with: ["rgRow", "rgAltRow"]) else { continue }
            let cells = matches(#"<td\b[^>]*>(.*?)</td>"#, in: row[2]).map { text($0[1]) }
            guard cells.count == 10, !cells[0].isEmpty,
                  !cells[1].isEmpty, !cells[4].isEmpty else { throw PostalError.invalidResponse }
            records.append(PostalRecord(
                sequence: cells[0], receivedDate: cells[1], trackingNumber: cells[2],
                unit: cells[3], recipient: cells[4], category: cells[5], quantity: cells[6],
                signature: cells[7], completedDate: cells[8], note: cells[9], status: query.status
            ))
        }
        guard (!records.isEmpty && !explicitlyEmpty) || (records.isEmpty && explicitlyEmpty),
              Set(records.map(\.id)).count == records.count else { throw PostalError.invalidResponse }

        struct Grid: Decodable {
            let ClientID: String
            let PageCount: Int
            let CurrentPageIndex: Int
        }
        guard let encoded = matches(#""_gridTableViewsData"\s*:\s*("(?:\\.|[^"\\])*")"#, in: html).first?[1],
              let encodedData = encoded.data(using: .utf8),
              let json = try? JSONDecoder().decode(String.self, from: encodedData),
              let data = json.data(using: .utf8),
              let grids = try? JSONDecoder().decode([Grid].self, from: data),
              let metadata = grids.first(where: { $0.ClientID == "RadGrid1_ctl00" }),
              metadata.PageCount >= 0, metadata.CurrentPageIndex >= 0,
              metadata.CurrentPageIndex < max(1, metadata.PageCount) else { throw PostalError.invalidResponse }

        var nextForm: [String: String]?
        if metadata.CurrentPageIndex + 1 < metadata.PageCount {
            var next = searchForm(fields, query: query)
            next.removeValue(forKey: "Btn_Search")
            // Replay the server-rendered paging control with fresh WebForms state.
            for input in matches(#"<input\b([^>]*)>"#, in: grid) {
                let attrs = attributes(input[1])
                if (attrs["class"] ?? "").split(separator: " ").contains("rgPageNext"),
                   attrs["disabled"] == nil, attrs["type"]?.lowercased() == "submit",
                   let name = attrs["name"] {
                    next[name] = attrs["value"] ?? ""
                    nextForm = next
                    break
                }
            }
        }
        return PostalPage(records: records, query: query, pageIndex: metadata.CurrentPageIndex,
                          pageCount: max(1, metadata.PageCount), nextForm: nextForm)
    }

    static func encodeForm(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func matches(_ pattern: String, in value: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { match in
            (0..<match.numberOfRanges).map {
                Range(match.range(at: $0), in: value).map { String(value[$0]) } ?? ""
            }
        }
    }

    private static func attributes(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in matches(#"([a-z_:][a-z0-9_:.-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#, in: value) {
            result[match[1].lowercased()] = entities(match[2...4].first(where: { !$0.isEmpty }) ?? "")
        }
        return result
    }

    private static func text(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return entities(stripped).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func entities(_ value: String) -> String {
        var result = value
        for entity in matches(#"&#(x[0-9a-f]+|[0-9]+);"#, in: value) {
            let code = entity[1].lowercased()
            let number = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let number, let scalar = UnicodeScalar(number) {
                result = result.replacingOccurrences(of: entity[0], with: String(scalar))
            }
        }
        for (entity, replacement) in [("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"),
                                       ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
