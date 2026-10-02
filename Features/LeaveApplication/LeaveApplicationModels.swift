import Foundation

nonisolated struct LeaveOption: Decodable, Identifiable {
    let id: String
    let title: String
}

nonisolated struct LeavePeriod: Decodable, Identifiable {
    let id: String
    let date: String
    let period: String
    let course: String
    let teacher: String
    let room: String
}

nonisolated struct LeavePage: Decodable {
    let kind: String
    var notice: String?
    var studentID: String?
    var options: [LeaveOption]?
    var periods: [LeavePeriod]?
    var attachmentNames: [String]?
    var selected: String?
    /// The school's hidden `Mode`: empty or `ADD` for a new application, `MOD`, or `DETAIL`.
    var mode: String?
    var formNo: String?
    var submitLabel: String?
    var editable: Bool?
    var current: LeaveCurrentValues?
    var existingPeriods: [LeaveExistingPeriod]?
}

/// Values already saved on an existing leave form (modify / supplement / detail).
nonisolated struct LeaveCurrentValues: Decodable, Equatable {
    let leaveType: String
    let startDate: String
    let endDate: String
    let reason: String
    let supplementLater: Bool
}

/// A row of the school's「本次請假日期與節次明細」.
nonisolated struct LeaveExistingPeriod: Decodable, Identifiable, Hashable {
    let date: String
    let period: String
    let course: String
    let courseNo: String
    let teacher: String
    var id: String { "\(date)|\(period)|\(courseNo)" }

    /// Matches the period picker's value (`1151008|10|…`) by date and period number.
    func matches(_ periodID: String) -> Bool {
        let parts = periodID.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return String(parts[0]) == date.replacingOccurrences(of: "/", with: "") && String(parts[1]) == period
    }
}

/// Which school form a leave screen works on.
nonisolated enum LeaveEntry: Hashable {
    case apply
    case modify(formNo: String)
    case supplement(formNo: String)

    var formNo: String? {
        switch self {
        case .apply: return nil
        case .modify(let formNo), .supplement(let formNo): return formNo
        }
    }
    var title: String {
        switch self {
        case .apply: return "請假申請"
        case .modify: return "修改假單"
        case .supplement: return "補交證明文件"
        }
    }
}

/// A row of 請假紀錄 (SEC4030); school wording is kept as-is.
nonisolated struct LeaveRecord: Decodable, Identifiable, Equatable {
    let formNo: String
    let appliedDate: String
    let type: String
    let startDate: String
    let endDate: String
    let startPeriod: String
    let endPeriod: String
    let totalPeriods: String
    let status: String
    var id: String { formNo }
}

/// What 學生請假修改 (SEC2015) currently allows for a form.
nonisolated struct LeaveRecordActions: Decodable, Equatable {
    let formNo: String
    let withdraw: Bool
    let modify: Bool
    let supplement: Bool
    static let none = LeaveRecordActions(formNo: "", withdraw: false, modify: false, supplement: false)
    var any: Bool { withdraw || modify || supplement }
}

nonisolated struct LeaveListPage: Decodable {
    let kind: String
    var records: [LeaveRecord]?
    var actions: [LeaveRecordActions]?
}

nonisolated enum LeaveApplicationError: LocalizedError, Equatable {
    case expired, unavailable, changed, invalidFile, recordMissing
    var errorDescription: String? {
        switch self {
        case .expired: return "教務系統登入已失效，請重新連線；若仍失敗，請到設定重新登入。"
        case .unavailable: return "無法開啟校方請假表單，請稍後重試或前往校務系統。"
        case .changed: return "校方表單內容與預期不同，請前往校務系統完成申請。"
        case .invalidFile: return "請選擇 PDF、JPG、JPEG 或 PNG，單一檔案限 10 MB。"
        case .recordMissing: return "校方目前沒有列出這張假單的這項操作，可能已撤回或審核狀態已變更。請重新整理。"
        }
    }

    /// Separates offline, timeout and login failures so the UI can offer the right action.
    static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "目前沒有網路連線，請連上網路後重試。"
            case .timedOut: return "校方系統回應逾時，請稍後重試。"
            case .userAuthenticationRequired: return LeaveApplicationError.expired.localizedDescription
            default: return "無法連線到校方系統，請稍後重試。"
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? LeaveApplicationError.unavailable.localizedDescription
    }
}

nonisolated enum LeaveApplicationDate {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        return calendar
    }

    /// The school form expects ROC dates such as `115/10/05`.
    static func string(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%03d/%02d/%02d", (parts.year ?? 1912) - 1911, parts.month ?? 1, parts.day ?? 1)
    }

    static func date(fromROC value: String) -> Date? {
        let parts = value.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0] + 1911, month: parts[1], day: parts[2]))
    }

    /// `115/10/05` → `10 月 5 日（一）`; unknown formats keep the school's original text.
    static func display(roc value: String) -> String {
        guard let date = date(fromROC: value) else { return value }
        let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = weekdays[((parts.weekday ?? 1) - 1) % 7]
        return "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日（\(weekday)）"
    }

    static func dayCount(from start: Date, to end: Date) -> Int {
        let calendar = calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        return max(days + 1, 1)
    }
}

/// The real phases of reaching the school's leave form, in order.
nonisolated enum LeaveLoadStage: Int, CaseIterable {
    case connecting, signingIn, opening, reading
    var title: String {
        switch self {
        case .connecting: return "連接教務系統"
        case .signingIn: return "確認登入狀態"
        case .opening: return "開啟請假申請"
        case .reading: return "讀取請假表單"
        }
    }
}

nonisolated enum LeaveSchoolPage {
    static let apply = "/NIU/Application/SEC/SEC20/SEC2010_.aspx?progcd=SEC2010"
    static let manage = "/NIU/Application/SEC/SEC20/SEC2015_.aspx?progcd=SEC2015"
    static let records = "/NIU/Application/SEC/SEC40/SEC4030_.aspx?progcd=SEC4030"
    static let manageList = "/SEC2015_01.aspx"
    static let recordsList = "/SEC4030_01.aspx"
}

nonisolated enum LeaveApplicationCopy {
    static let acknowledgement = "我會在送出之後親自前往校務系統，確認請假附件以及資料已經正確送出。"
    static let dashboard = URL(string: "https://ccsys1.niu.edu.tw/SSO/dashboard/student")!
}
