import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    
    @Published var isAuthenticated: Bool = false
    @Published var currentUser: User?
    
    init() {
        checkAuthenticationStatus()
    }
    
    func login(user: User) {
        currentUser = user
        isAuthenticated = true
        saveAuthState()
        print("[App] 使用者已登入: \(user.name)")
    }
    
    func logout() {
        currentUser = nil
        isAuthenticated = false
        clearAuthState()
        print("[App] 使用者已登出")
    }
    
    private func checkAuthenticationStatus() {
        // 检查本地存储的认证状态
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
