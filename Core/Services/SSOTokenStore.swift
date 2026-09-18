import Foundation

/// Holds the JWT issued by the modern SSO (`POST /SSO/API/Login`) so feature
/// WebViews can hand it to `SSOGUIDBridge` and obtain a fresh GUID for the
/// legacy `acade.niu.edu.tw` / `ccsys.niu.edu.tw/MvcTeam` portals.
///
/// The token lives in memory plus UserDefaults; UserDefaults is sufficient
/// because the only thing it grants is the GUID-bridge exchange, which still
/// requires a valid SSO session on the server side.
final class SSOTokenStore {
    static let shared = SSOTokenStore()

    private let tokenKey = "app.sso.token"
    private let expKey = "app.sso.token.exp"
    private let accountKey = "app.sso.token.account"
    private let queue = DispatchQueue(label: "SSOTokenStore.queue")

    private init() {}

    func save(token: String, exp: String?, account: String) {
        queue.sync {
            UserDefaults.standard.set(token, forKey: tokenKey)
            UserDefaults.standard.set(exp, forKey: expKey)
            UserDefaults.standard.set(account.lowercased(), forKey: accountKey)
        }
    }

    func clear() {
        queue.sync {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: expKey)
            UserDefaults.standard.removeObject(forKey: accountKey)
        }
    }

    /// A delayed 401 from an old request must not erase a newer login.
    func clear(ifMatching rejectedToken: String) {
        queue.sync {
            guard UserDefaults.standard.string(forKey: tokenKey) == rejectedToken else { return }
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: expKey)
            UserDefaults.standard.removeObject(forKey: accountKey)
        }
    }

    var token: String? {
        UserDefaults.standard.string(forKey: tokenKey)?.nilIfEmpty
    }

    var account: String? {
        UserDefaults.standard.string(forKey: accountKey)?.nilIfEmpty
    }

    /// Parsed expiry date (server returns ISO8601 with `+08:00`).
    var expiration: Date? {
        guard let raw = UserDefaults.standard.string(forKey: expKey)?.nilIfEmpty else {
            return nil
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFormatter.date(from: raw) { return d }
        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: raw)
    }

    var isLikelyValid: Bool {
        guard token != nil else { return false }
        guard let exp = expiration else { return true } // unknown exp → optimistic
        return exp.timeIntervalSinceNow > 30
    }
}
