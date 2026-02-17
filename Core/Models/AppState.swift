import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {

    @Published var isAuthenticated: Bool = false
    @Published var currentUser: User?

    /// `true` after the user explicitly presses the logout button.
    /// Used by LoginView to suppress automatic re-login.
    @Published private(set) var didExplicitlyLogout: Bool = false

    init() {
        checkAuthenticationStatus()
    }

    func login(user: User) {
        currentUser = user
        isAuthenticated = true
        didExplicitlyLogout = false
        saveAuthState()
        SSOSessionService.shared.enableAutoRefresh()
        print("[App] 使用者已登入: \(user.name)")
    }

    func logout() {
        currentUser = nil
        isAuthenticated = false
        didExplicitlyLogout = true
        clearAuthState()
        SSOSessionService.shared.disableAutoRefresh()
        print("[App] 使用者已登出")
    }

    private func checkAuthenticationStatus() {
        if let savedUsername = UserDefaults.standard.string(forKey: StorageKeys.username),
           let savedName = UserDefaults.standard.string(forKey: StorageKeys.name),
           !savedUsername.isEmpty {
            currentUser = User(username: savedUsername, name: savedName)
            isAuthenticated = true
        }
    }

    private func saveAuthState() {
        guard let user = currentUser else { return }
        UserDefaults.standard.set(user.username, forKey: StorageKeys.username)
        UserDefaults.standard.set(user.name, forKey: StorageKeys.name)
        UserDefaults.standard.set(Date(), forKey: StorageKeys.loginTime)
    }

    private func clearAuthState() {
        UserDefaults.standard.removeObject(forKey: StorageKeys.username)
        UserDefaults.standard.removeObject(forKey: StorageKeys.name)
        UserDefaults.standard.removeObject(forKey: StorageKeys.loginTime)
    }
}

private enum StorageKeys {
    static let username = "app.user.username"
    static let name = "app.user.name"
    static let loginTime = "app.user.loginTime"
}
