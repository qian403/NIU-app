import Foundation
import Security

/// The SSO bearer token grants access to the academic GUID bridge. Store it with
/// the same device-only protection as the other login credentials.
@MainActor
final class SSOTokenStore {
    static let shared = SSOTokenStore()

    private struct Session: Codable {
        let token: String
        let expiration: String?
        let account: String
    }

    private let service = (Bundle.main.bundleIdentifier ?? "dev.chienniuapp") + ".sso"
    private let keychainAccount = "session"
    private var session: Session?

    private init() {
        session = readSession()
        let defaults = UserDefaults.standard
        if session == nil, let token = defaults.string(forKey: "app.sso.token"),
           let account = defaults.string(forKey: "app.sso.token.account") {
            save(token: token, exp: defaults.string(forKey: "app.sso.token.exp"), account: account)
        }
        // If Keychain is unavailable, the user can authenticate again; never
        // retain a plaintext fallback of this bearer credential.
        for key in ["app.sso.token", "app.sso.token.exp", "app.sso.token.account"] {
            defaults.removeObject(forKey: key)
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: keychainAccount]
    }

    func save(token: String, exp: String?, account: String) {
        let value = Session(token: token, expiration: exp, account: account.lowercased())
        guard let data = try? JSONEncoder().encode(value) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        if status == errSecSuccess { session = value }
    }

    func clear() {
        session = nil
        SecItemDelete(query as CFDictionary)
    }

    /// A delayed rejection must not erase a newer login.
    func clear(ifMatching rejectedToken: String) {
        guard session?.token == rejectedToken else { return }
        clear()
    }

    var token: String? { session?.token.nilIfEmpty }
    var account: String? { session?.account.nilIfEmpty }

    var expiration: Date? {
        guard let raw = session?.expiration?.nilIfEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    var isLikelyValid: Bool {
        guard token != nil else { return false }
        guard let expiration else { return true }
        return expiration.timeIntervalSinceNow > 30
    }

    private func readSession() -> Session? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }
}
