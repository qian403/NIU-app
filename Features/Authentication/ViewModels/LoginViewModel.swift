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
        case zuvioCredentialsFailed
        case bothFailed
        
        var id: String {
            switch self {
            case .emptyFields: return "emptyFields"
            case .ssoCredentialsFailed: return "ssoCredentialsFailed"
            case .ssoPasswordExpiring: return "ssoPasswordExpiring"
            case .ssoPasswordExpired: return "ssoPasswordExpired"
            case .ssoAccountLocked: return "ssoAccountLocked"
            case .ssoSystemError: return "ssoSystemError"
            case .ssoGeneric: return "ssoGeneric"
            case .zuvioCredentialsFailed: return "zuvioCredentialsFailed"
            case .bothFailed: return "bothFailed"
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
    @Published var zuvioLoginStarted: Bool = false
    @Published var ssoLoginCompleted: Bool = false
    @Published var zuvioLoginCompleted: Bool = false
    
    // MARK: - Private Properties
    private let loginRepository = LoginRepository.shared
    var ssoResult: SSOLoginResult?
    private var zuvioSuccess: Bool = false
    
    // MARK: - Computed Properties
    var isFormValid: Bool {
        !username.isEmpty && !password.isEmpty
    }
    
    var shouldProceedToHome: Bool {
        ssoLoginCompleted && zuvioLoginCompleted && ssoResult != nil
    }
    
    // MARK: - Login Functions
    func login() {
        guard isFormValid else {
            activeAlert = .emptyFields
            return
        }
        
        isLoading = true
        ssoLoginStarted = false
        zuvioLoginStarted = false
        ssoLoginCompleted = false
        zuvioLoginCompleted = false
        ssoResult = nil
        zuvioSuccess = false
        
        // 同時啟動兩個登入流程
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.ssoLoginStarted = true
            self.zuvioLoginStarted = true
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
    
    func handleZuvioLoginResult(success: Bool) {
        zuvioSuccess = success
        zuvioLoginCompleted = true
        checkLoginCompletion()
    }
    
    private func checkLoginCompletion() {
        guard ssoLoginCompleted && zuvioLoginCompleted else {
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
            // SSO 成功，檢查 Zuvio
            if zuvioSuccess {
                // 兩個都成功，保存憑據
                loginRepository.saveCredentials(username: username, password: password)
                // HomeView 會自動偵測 shouldProceedToHome
            } else {
                // SSO 成功但 Zuvio 失敗
                // 仍然允許登入，因為主要是 SSO
                loginRepository.saveCredentials(username: username, password: password)
            }
            
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
