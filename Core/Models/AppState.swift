import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {

    @Published var isAuthenticated: Bool = false
    @Published var currentUser: User?

    /// `true` after the user explicitly presses the logout button.
    /// Used by LoginView to suppress automatic re-login.
    @Published private(set) var didExplicitlyLogout: Bool = false
    private var isRefreshingProfile = false

    init() {
        checkAuthenticationStatus()
    }

    func login(user: User) {
        let mergedUser = mergedWithPersistedProfile(user)
        currentUser = mergedUser
        isAuthenticated = true
        didExplicitlyLogout = false
        saveAuthState()
        SSOSessionService.shared.enableAutoRefresh()
        // Extract EUNI redirect link while SSO session is still alive
        MoodleSessionManager.shared.fetchEUNILink()
        print("[App] 使用者已登入: \(mergedUser.name)")
        
        if mergedUser.department?.nilIfEmpty == nil || mergedUser.grade?.nilIfEmpty == nil {
            Task { await refreshProfileIfNeeded(force: true) }
        }
    }

    func logout() {
        currentUser = nil
        isAuthenticated = false
        didExplicitlyLogout = true
        clearAuthState()
        SSOSessionService.shared.disableAutoRefresh()
        MoodleSessionManager.shared.reset()
        print("[App] 使用者已登出")
    }

    private func checkAuthenticationStatus() {
        if let savedUsername = UserDefaults.standard.string(forKey: StorageKeys.username),
           let savedName = UserDefaults.standard.string(forKey: StorageKeys.name),
           !savedUsername.isEmpty {
            let savedDepartment = UserDefaults.standard.string(forKey: StorageKeys.department)
            let savedGrade = UserDefaults.standard.string(forKey: StorageKeys.grade)
            currentUser = User(
                username: savedUsername,
                name: savedName,
                department: savedDepartment?.nilIfEmpty,
                grade: savedGrade?.nilIfEmpty
            )
            isAuthenticated = true
            SSOSessionService.shared.enableAutoRefresh()
            // Try to fetch EUNI link if we don't have one yet
            if SSOEUNISettings.shared.euniFullURL == nil {
                MoodleSessionManager.shared.fetchEUNILink()
            }
            Task { await refreshProfileIfNeeded() }
        }
    }

    private func saveAuthState() {
        guard let user = currentUser else { return }
        UserDefaults.standard.set(user.username, forKey: StorageKeys.username)
        UserDefaults.standard.set(user.name, forKey: StorageKeys.name)
        UserDefaults.standard.set(user.department, forKey: StorageKeys.department)
        UserDefaults.standard.set(user.grade, forKey: StorageKeys.grade)
        UserDefaults.standard.set(Date(), forKey: StorageKeys.loginTime)
    }

    private func clearAuthState() {
        UserDefaults.standard.removeObject(forKey: StorageKeys.username)
        UserDefaults.standard.removeObject(forKey: StorageKeys.name)
        UserDefaults.standard.removeObject(forKey: StorageKeys.department)
        UserDefaults.standard.removeObject(forKey: StorageKeys.grade)
        UserDefaults.standard.removeObject(forKey: StorageKeys.loginTime)
    }

    private func mergedWithPersistedProfile(_ user: User) -> User {
        let savedDepartment = UserDefaults.standard.string(forKey: StorageKeys.department)?.nilIfEmpty
        let savedGrade = UserDefaults.standard.string(forKey: StorageKeys.grade)?.nilIfEmpty
        return User(
            id: user.id,
            username: user.username,
            name: user.name,
            email: user.email,
            avatarURL: user.avatarURL,
            department: user.department?.nilIfEmpty ?? savedDepartment,
            grade: user.grade?.nilIfEmpty ?? savedGrade
        )
    }

    func updateProfileFromSSO(_ info: StudentInfo) {
        guard var user = currentUser else { return }
        user = User(
            id: user.id,
            username: user.username,
            name: info.name.nilIfEmpty ?? user.name,
            email: user.email,
            avatarURL: user.avatarURL,
            department: info.department.nilIfEmpty ?? user.department,
            grade: info.grade.nilIfEmpty ?? user.grade
        )
        currentUser = user
        saveAuthState()
    }

    func refreshProfileIfNeeded(force: Bool = false) async {
        guard isAuthenticated,
              let user = currentUser,
              !isRefreshingProfile else { return }
        let needsRefresh = force || user.department?.nilIfEmpty == nil || user.grade?.nilIfEmpty == nil
        guard needsRefresh else { return }

        isRefreshingProfile = true
        defer { isRefreshingProfile = false }
        _ = await SSOSessionService.shared.requestRefresh()
    }
}

private enum StorageKeys {
    static let username = "app.user.username"
    static let name = "app.user.name"
    static let department = "app.user.department"
    static let grade = "app.user.grade"
    static let loginTime = "app.user.loginTime"
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
