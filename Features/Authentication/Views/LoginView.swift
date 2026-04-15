import SwiftUI

struct LoginView: View {
    @StateObject private var viewModel = LoginViewModel()
    @EnvironmentObject private var appState: AppState
    @FocusState private var focusedField: Field?
    @State private var showPrivacySheet = false
    
    enum Field: Hashable {
        case username, password
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                
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
        .sheet(isPresented: $showPrivacySheet) {
            NavigationStack {
                PrivacyPolicyView()
            }
        }
    }
    
    // MARK: - UI Components
    private var logoSection: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Circle()
                .strokeBorder(Color.primary, lineWidth: 2)
                .frame(width: 80, height: 80)
                .overlay(
                    Text("NIU")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                )
            
            Text("NIU APP")
                .font(.system(size: 32, weight: .thin))
                .foregroundColor(.primary)
        }
    }
    
    private var inputSection: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Text("帳號密碼與校務系統相同")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.black.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)

            MinimalTextField(
                text: $viewModel.username,
                placeholder: "bXXXXXXX",
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
            .background(Color.accentColor)
            .cornerRadius(26)
        }
        .disabled(viewModel.isLoading || !viewModel.isFormValid)
        .opacity(viewModel.isFormValid ? 1.0 : 0.4)
    }
    
    private var footerText: some View {
        VStack(spacing: 8) {
            Text("本程式為非官方第三方工具，與宜蘭大學官方無關")
                .font(.system(size: 12, weight: .light))
                .foregroundColor(.gray)

            Button {
                showPrivacySheet = true
            } label: {
                Text("隱私權聲明")
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.gray)
            }
        }
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
                ? "您的帳號已被鎖定\n鎖定時間：\(lockTime ?? "")"
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

private struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Group {
                    Text("隱私權聲明 (Privacy Policy)")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primary)

                    Text("感謝您下載並使用本應用程式（以下簡稱「本 App」）。本 App 致力於保護您的個人隱私，並確保您在使用校務相關功能時的資訊安全。在使用本 App 前，請詳閱以下聲明：")

                    Text("一、重要聲明：非官方性質")
                        .font(.system(size: 17, weight: .semibold))
                    Text("本 App 為個人開發之第三方校務輔助工具，與「國立宜蘭大學 (NIU)」官方並無任何隸屬、合作或授權關係。本 App 透過原生介面整合校務入口，提供課表/成績查詢、Moodle 整合、活動報名、行事曆匯出與通知管理等功能，以提升行動端使用體驗。")

                    Text("二、帳號登入與個人資料處理")
                        .font(.system(size: 17, weight: .semibold))
                    Text("登入資訊：當您登入校務帳號時，您的帳號與密碼將直接傳送至學校官方伺服器進行身分驗證。為了提供自動登入與工作階段續期功能，本 App 會將帳號與密碼加密儲存在 iOS Keychain（僅於您的裝置本機）。本 App 不會將您的帳號與密碼上傳到開發者伺服器。")
                    Text("校務資料存取：本 App 獲取之課表、成績、缺曠課等個人資訊，僅限於提供您在行動裝置上查看與管理之用。")

                    Text("三、資料儲存與保護機制")
                        .font(.system(size: 17, weight: .semibold))
                    Text("本地存儲 (Local Storage)：為提升使用流暢度，您的基本校務資訊（如課表、姓名等）會儲存在您的行動裝置本地端；登入帳密則儲存在 iOS Keychain。")
                    Text("Session 與 Cookie：系統會暫存必要的 Session 資訊以維持登入狀態。您隨時可以透過 App 內的「登出」功能，立即清除本機端儲存的所有登入資訊與暫存檔案。")

                    Text("四、數據收集與技術分析")
                        .font(.system(size: 17, weight: .semibold))
                    Text("為了持續優化 App 品質，我們會收集部分匿名且無法辨識個人身分的統計數據，包括：")
                    Text("使用統計：例如每日活躍人數 (DAU)、各功能點擊頻率。")
                    Text("錯誤回報：App 閃退或載入失敗時的去識別化系統錯誤紀錄。")
                    Text("上述數據僅用於技術改善與效能優化，不包含任何姓名、學號或敏感個資。")

                    Text("五、第三方連結與免責聲明")
                        .font(.system(size: 17, weight: .semibold))
                    Text("外部連結：本 App 部分功能可能導向學校官方網頁。對於外部網站的隱私權政策，本 App 不負任何法律責任。")
                    Text("資料準確性：所有校務資訊均同步自學校伺服器，若資料有誤，請以學校官方行政系統為準。")
                    Text("安全風險：請確保您的行動裝置環境安全。若因裝置遭惡意程式入侵或遺失而導致資料流失，開發者概不負責。")

                    Text("六、隱私權聲明之修改")
                        .font(.system(size: 17, weight: .semibold))
                    Text("開發者保留隨時修改本聲明之權利。修改後的條款將直接更新於本 App 內，不另行個別通知，建議您定期查看。")

                    Text("七、聯繫方式")
                        .font(.system(size: 17, weight: .semibold))
                    Text("若您對本隱私權聲明或資料處理方式有任何疑問、建議或發現潛在漏洞，歡迎透過以下方式聯繫開發者：")
                    Text("開發者聯絡信箱：hi@chien.dev")
                    Text("GitHub 專案頁面：https://github.com/qian403/NIU-app")
                }
            }
            .font(.system(size: 15))
            .foregroundColor(.black.opacity(0.75))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.large)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("隱私權聲明")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("關閉") {
                    dismiss()
                }
                .foregroundColor(.primary)
            }
        }
    }
}
