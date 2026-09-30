import Foundation

nonisolated enum CampusMailError: Error, LocalizedError {
    case invalidResponse, invalidCredentials, invalidCaptcha, sessionExpired
    case additionalVerification, twoFactorRequired, invalidTwoFactor, accountMismatch, missingCredentials, captchaRecognitionFailed, server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "校方郵件資料格式無法辨識，請稍後重試或使用校方網站。"
        case .invalidCredentials: return "郵件帳號或密碼不正確，請確認後再試。"
        case .invalidCaptcha: return "驗證碼錯誤或已失效，請輸入重新載入的驗證碼。"
        case .sessionExpired: return "郵件登入已失效，請重新完成驗證。"
        case .additionalVerification: return "校方要求額外驗證或變更密碼，請先至校方郵件網站完成。"
        case .twoFactorRequired: return "校方要求二次驗證，請輸入你的驗證碼。"
        case .invalidTwoFactor: return "二次驗證未通過，請確認驗證碼後重試。"
        case .accountMismatch: return "郵件帳號與目前 App 帳號不一致，請重新登入。"
        case .missingCredentials: return "App 登入資訊不完整，請至設定重新登入 App 後再開啟信箱。"
        case .captchaRecognitionFailed: return "暫時無法自動完成校方驗證，請稍後重試或使用校方網站。"
        case .server(let code): return "校方郵件服務暫時無法使用（\(code)），請稍後重試。"
        }
    }
}

nonisolated struct CampusMailLoginChallenge: Sendable {
    let requiresCaptcha: Bool
    let svg: String?
}

// The browser receives only a verified, account-bound session, never a password.
@MainActor
final class CampusMailWebSession: Identifiable {
    let id = UUID()
    let account: String
    private(set) var cookies: [HTTPCookie]
    private(set) var isValid = true
    var onInvalidate: (() -> Void)?

    init(account: String, cookies: [HTTPCookie]) {
        self.account = account
        self.cookies = cookies
    }

    func invalidate() {
        guard isValid else { return }
        isValid = false
        cookies = []
        onInvalidate?()
        onInvalidate = nil
    }
}

nonisolated enum CampusMailWebPolicy {
    static let origin = URL(string: "https://mail.niu.edu.tw")!
    static let inbox = origin.appendingPathComponent("NUMail/Mobile/Box/INBOX")
    static let desktop = origin.appendingPathComponent("NUMail/Mails/Box/INBOX")
    static let settings = origin.appendingPathComponent("NUMail/Config/General")

    static func isSchool(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == origin.host
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    static func isLogin(_ url: URL) -> Bool {
        isSchool(url) && (url.path == "/NUMail/Login" || url.path.hasPrefix("/NUMail/Login/"))
    }

    static func isSchoolBlob(_ url: URL) -> Bool {
        guard url.scheme == "blob", let inner = URL(string: String(url.absoluteString.dropFirst(5))) else { return false }
        return isSchool(inner)
    }

    static func filename(_ suggested: String) -> String {
        let leaf = suggested.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? ""
        let clean = String(leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "." || clean == ".." ? "附件" : String(clean.prefix(160))
    }
}
