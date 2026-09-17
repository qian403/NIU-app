import SwiftUI
import Combine

@MainActor
final class LoginViewModel: ObservableObject {
    
    // MARK: - Alert Types
    enum LoginAlert: Identifiable {
        case emptyFields
        case ssoCredentialsFailed(message: String)
        case ssoPasswordExpiring(message: String)
        case ssoPasswordExpired(message: String)
        case ssoAccountLocked(lockTime: String?)
        case ssoSystemError
        case ssoGeneric(title: String, message: String)
        
        var id: String {
            switch self {
            case .emptyFields: return "emptyFields"
            case .ssoCredentialsFailed: return "ssoCredentialsFailed"
            case .ssoPasswordExpiring: return "ssoPasswordExpiring"
            case .ssoPasswordExpired: return "ssoPasswordExpired"
            case .ssoAccountLocked: return "ssoAccountLocked"
            case .ssoSystemError: return "ssoSystemError"
            case .ssoGeneric: return "ssoGeneric"
            }
        }
    }
    
    // MARK: - Published Properties
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var isPasswordVisible: Bool = false
    @Published var isLoading: Bool = false
    @Published var activeAlert: LoginAlert?
    
    @Published var ssoLoginStarted: Bool = false
    @Published var ssoLoginCompleted: Bool = false
    @Published var moodleLoginCompleted: Bool = false
    
    // MARK: - Private Properties
    private let loginRepository = LoginRepository.shared
    private var moodleLoginTask: Task<Void, Never>?
    var ssoResult: SSOLoginResult?
    
    // MARK: - Computed Properties
    var isFormValid: Bool {
        !username.isEmpty && !password.isEmpty
    }
    
    var shouldProceedToHome: Bool {
        ssoLoginCompleted && moodleLoginCompleted && ssoResult != nil
    }
    
    // MARK: - Login Functions
    func login() {
        guard isFormValid else {
            activeAlert = .emptyFields
            return
        }
        
        isLoading = true
        ssoLoginStarted = false
        ssoLoginCompleted = false
        moodleLoginCompleted = false
        ssoResult = nil
        moodleLoginTask?.cancel()
        MoodleService.shared.logout()

        let loginUsername = username
        let loginPassword = password
        
        // SSO 與 M 園區各自驗證；SSO 仍是 App 登入的必要條件。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.ssoLoginStarted = true
            self.startMoodleLogin(username: loginUsername, password: loginPassword)
        }
    }

    private func startMoodleLogin(username: String, password: String) {
        moodleLoginTask = Task { [weak self] in
            do {
                try await MoodleService.shared.authenticate(username: username, password: password)
                guard !Task.isCancelled else { return }
                print("[Login] Moodle authentication succeeded")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                print("[Login] Moodle authentication failed: \(type(of: error))")
            }
            self?.moodleLoginCompleted = true
            self?.checkLoginCompletion()
            self?.moodleLoginTask = nil
        }
    }
    
    func autoLogin() {
        guard let credentials = loginRepository.getSavedCredentials() else {
            return
        }
        
        username = credentials.username
        password = credentials.password
        
        // 自動啟動登入
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.login()
        }
    }
    
    // MARK: - Result Handlers
    func handleSSOLoginResult(_ result: SSOLoginResult) {
        ssoResult = result
        ssoLoginCompleted = true
        checkLoginCompletion()
    }
    
    private func checkLoginCompletion() {
        guard ssoLoginCompleted && moodleLoginCompleted else {
            return
        }
        
        isLoading = false
        
        // 檢查 SSO 登入結果
        guard let ssoResult = ssoResult else {
            activeAlert = .ssoSystemError
            return
        }
        
        switch ssoResult {
        case .success(_):
            loginRepository.saveCredentials(username: username, password: password)
            
        case .credentialsFailed(let message):
            // 清除已保存的錯誤憑據
            loginRepository.clearCredentials()
            activeAlert = .ssoCredentialsFailed(message: message)
            
        case .passwordExpiring(let message):
            // 密碼即將到期，詢問用戶
            activeAlert = .ssoPasswordExpiring(message: message)
            
        case .passwordExpired(let message):
            // 密碼已到期，必須修改
            activeAlert = .ssoPasswordExpired(message: message)
            
        case .accountLocked(let lockTime):
            // 帳號鎖定
            activeAlert = .ssoAccountLocked(lockTime: lockTime)
            
        case .systemError:
            // 系統錯誤
            activeAlert = .ssoSystemError
            
        case .generic(let title, let message):
            // 其他錯誤
            activeAlert = .ssoGeneric(title: title, message: message)
        }
    }
    
    // MARK: - Alert Actions
    func proceedWithExpiringPassword() {
        // 用戶選擇稍後再改密碼，繼續登入
        loginRepository.saveCredentials(username: username, password: password)
        activeAlert = nil
    }
    
    func openPasswordChangePage() {
        // 開啟 SSO 密碼修改頁面
        if let url = URL(string: "https://ccsys.niu.edu.tw/SSO/ChgPwd.aspx") {
            #if os(iOS)
            UIApplication.shared.open(url)
            #endif
        }
        activeAlert = nil
    }
}
