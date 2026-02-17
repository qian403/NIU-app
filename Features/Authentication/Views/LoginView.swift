import SwiftUI

struct LoginView: View {
    @StateObject private var viewModel = LoginViewModel()
    @EnvironmentObject private var appState: AppState
    @FocusState private var focusedField: Field?
    
    enum Field: Hashable {
        case username, password
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    Spacer()
                    
                    logoSection
                        .padding(.bottom, 60)
                    
                    inputSection
                        .padding(.horizontal, Theme.Spacing.xlarge)
                    
                    loginButton
                        .padding(.horizontal, Theme.Spacing.xlarge)
                        .padding(.top, Theme.Spacing.xlarge)
                    
                    Spacer()
                    
                    footerText
                        .padding(.bottom, Theme.Spacing.large)
                }
                
                // SSO WebView（隱藏在螢幕外）
                if viewModel.ssoLoginStarted {
                    SSOLoginWebView(
                        account: viewModel.username,
                        password: viewModel.password
                    ) { result in
                        viewModel.handleSSOLoginResult(result)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(x: geometry.size.width * 2, y: 0) // 隱藏在右側螢幕外
                }
                
                // Zuvio WebView（隱藏在螢幕外）
                if viewModel.zuvioLoginStarted {
                    ZuvioLoginWebView(
                        account: viewModel.username,
                        password: viewModel.password
                    ) { success in
                        viewModel.handleZuvioLoginResult(success: success)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(x: geometry.size.width * 3, y: 0) // 隱藏在更右側
                }
            }
        }
        .onTapGesture {
            focusedField = nil
        }
        .onAppear {
            // Skip auto-login if the user explicitly pressed logout,
            // so they are required to press Sign In themselves.
            if !appState.didExplicitlyLogout {
                viewModel.autoLogin()
            }
        }
        .onChange(of: viewModel.shouldProceedToHome) { _, shouldProceed in
            if shouldProceed, let result = viewModel.ssoResult {
                if case .success(let info) = result {
                    // 登入成功，跳轉到主頁
                    let user = User(
                        username: viewModel.username,
                        name: info.name,
                        email: nil,
                        avatarURL: nil,
                        department: info.department,
                        grade: info.grade
                    )
                    appState.login(user: user)
                }
            }
        }
        .alert(item: $viewModel.activeAlert) { alert in
            makeAlert(for: alert)
        }
    }
    
    // MARK: - UI Components
    private var logoSection: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Circle()
                .strokeBorder(Color.black, lineWidth: 2)
                .frame(width: 80, height: 80)
                .overlay(
                    Text("NIU")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                )
            
            Text("NIU APP")
                .font(.system(size: 32, weight: .thin))
                .foregroundColor(.black)
        }
    }
    
    private var inputSection: some View {
        VStack(spacing: Theme.Spacing.medium) {
            MinimalTextField(
                text: $viewModel.username,
                placeholder: "Student ID",
                icon: "person"
            )
            .focused($focusedField, equals: .username)
            .submitLabel(.next)
            .onSubmit { focusedField = .password }
            
            MinimalSecureField(
                text: $viewModel.password,
                placeholder: "Password",
                isVisible: $viewModel.isPasswordVisible,
                icon: "lock"
            )
            .focused($focusedField, equals: .password)
            .submitLabel(.go)
            .onSubmit { viewModel.login() }
        }
    }
    
    private var loginButton: some View {
        Button(action: {
            focusedField = nil
            viewModel.login()
        }) {
            HStack(spacing: 8) {
                if viewModel.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Text("Sign In")
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.black)
            .cornerRadius(26)
        }
        .disabled(viewModel.isLoading || !viewModel.isFormValid)
        .opacity(viewModel.isFormValid ? 1.0 : 0.4)
    }
    
    private var footerText: some View {
        Text("NIU SSO · Secure Login")
            .font(.system(size: 12, weight: .light))
            .foregroundColor(.gray)
    }
    
    // MARK: - Alert Builder
    private func makeAlert(for alert: LoginViewModel.LoginAlert) -> Alert {
        switch alert {
        case .emptyFields:
            return Alert(
                title: Text("輸入錯誤"),
                message: Text("請輸入學號和密碼"),
                dismissButton: .default(Text("確定"))
            )
            
        case .ssoCredentialsFailed(let message):
            return Alert(
                title: Text("登入失敗"),
                message: Text(message),
                dismissButton: .default(Text("確定"))
            )
            
        case .ssoPasswordExpiring(let message):
            return Alert(
                title: Text("密碼即將到期"),
                message: Text(message),
                primaryButton: .default(Text("稍後再說")) {
                    viewModel.proceedWithExpiringPassword()
                },
                secondaryButton: .default(Text("修改密碼")) {
                    viewModel.openPasswordChangePage()
                }
            )
            
        case .ssoPasswordExpired(let message):
            return Alert(
                title: Text("密碼已到期"),
                message: Text(message + "\n\n請先修改密碼後再登入"),
                primaryButton: .default(Text("修改密碼")) {
                    viewModel.openPasswordChangePage()
                },
                secondaryButton: .cancel(Text("取消"))
            )
            
        case .ssoAccountLocked(let lockTime):
            let message = lockTime != nil 
                ? "您的帳號已被鎖定\n鎖定時間：\(lockTime!)" 
                : "您的帳號已被鎖定\n請聯繫系統管理員"
            return Alert(
                title: Text("帳號鎖定"),
                message: Text(message),
                dismissButton: .default(Text("確定"))
            )
            
        case .ssoSystemError:
            return Alert(
                title: Text("系統錯誤"),
                message: Text("SSO 系統暫時無法使用\n請稍後再試"),
                dismissButton: .default(Text("確定"))
            )
            
        case .ssoGeneric(let title, let message):
            return Alert(
                title: Text(title),
                message: Text(message),
                dismissButton: .default(Text("確定"))
            )
            
        case .zuvioCredentialsFailed:
            return Alert(
                title: Text("Zuvio 登入失敗"),
                message: Text("無法登入 Zuvio 系統\n但您仍可使用其他功能"),
                dismissButton: .default(Text("確定"))
            )
            
        case .bothFailed:
            return Alert(
                title: Text("登入失敗"),
                message: Text("無法連接到學校系統\n請檢查網路連線"),
                dismissButton: .default(Text("確定"))
            )
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(AppState())
}
