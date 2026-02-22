import Foundation
import Security

final class LoginRepository {
    static let shared = LoginRepository()
    
    private let loginPrefs = UserDefaults(suiteName: "LoginPrefs")

    private let keyUsername = "username"
    private let keyPassword = "password"
    private let service = Bundle.main.bundleIdentifier ?? "CHIEN.NIU-APP"
    
    private init() {
        migrateFromLegacyUserDefaultsIfNeeded()
    }

    func saveCredentials(username: String, password: String) {
        saveToKeychain(value: username, account: keyUsername)
        saveToKeychain(value: password, account: keyPassword)
    }

    func getSavedCredentials() -> (username: String, password: String)? {
        guard let username = readFromKeychain(account: keyUsername),
              let password = readFromKeychain(account: keyPassword),
              !username.isEmpty, !password.isEmpty else {
            return nil
        }
        return (username, password)
    }
    
    func loadCredentials() -> (username: String, password: String)? {
        return getSavedCredentials()
    }

    func clearCredentials() {
        deleteFromKeychain(account: keyUsername)
        deleteFromKeychain(account: keyPassword)
        loginPrefs?.removeObject(forKey: keyUsername)
        loginPrefs?.removeObject(forKey: keyPassword)
    }

    private func migrateFromLegacyUserDefaultsIfNeeded() {
        guard readFromKeychain(account: keyUsername) == nil ||
                readFromKeychain(account: keyPassword) == nil else {
            return
        }

        guard let username = loginPrefs?.string(forKey: keyUsername),
              let password = loginPrefs?.string(forKey: keyPassword),
              !username.isEmpty, !password.isEmpty else {
            return
        }

        saveCredentials(username: username, password: password)
        loginPrefs?.removeObject(forKey: keyUsername)
        loginPrefs?.removeObject(forKey: keyPassword)
    }

    private func saveToKeychain(value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func readFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private func deleteFromKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
