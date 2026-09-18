import SwiftUI

struct LoginView: View {
    @StateObject private var viewModel = LoginViewModel()
    @EnvironmentObject private var appState: AppState
    @FocusState private var focusedField: Field?
    @State private var showPrivacySheet = false
    @State private var animateIn = true

    enum Field: Hashable {
        case username, password
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.08),
                        Color(.systemBackground),
                        Color(.systemBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                // Decorative circles
                Circle()
                    .fill(Color.accentColor.opacity(0.06))
                    .frame(width: 300, height: 300)
                    .offset(x: -80, y: -200)
                    .blur(radius: 60)

                Circle()
                    .fill(Color.accentColor.opacity(0.04))
                    .frame(width: 200, height: 200)
                    .offset(x: 120, y: 100)
                    .blur(radius: 40)

                VStack(spacing: 0) {
                    Spacer()

                    logoSection
                        .opacity(animateIn ? 1 : 0)
                        .offset(y: animateIn ? 0 : 20)
                        .animation(Theme.Animation.slow.delay(0.1), value: animateIn)
                        .padding(.bottom, 48)

                    inputSection
                        .padding(.horizontal, Theme.Spacing.large)
                        .opacity(animateIn ? 1 : 0)
                        .offset(y: animateIn ? 0 : 20)
                        .animation(Theme.Animation.slow.delay(0.2), value: animateIn)

                    loginButton
                        .padding(.horizontal, Theme.Spacing.large)
                        .padding(.top, Theme.Spacing.large)
                        .opacity(animateIn ? 1 : 0)
                        .offset(y: animateIn ? 0 : 20)
                        .animation(Theme.Animation.slow.delay(0.3), value: animateIn)

                    Spacer()

                    footerText
                        .padding(.bottom, Theme.Spacing.large)
                        .opacity(animateIn ? 1 : 0)
                        .animation(Theme.Animation.slow.delay(0.4), value: animateIn)
                }

                if viewModel.ssoLoginStarted && !viewModel.ssoLoginCompleted {
                    SSOLoginWebView(
                        account: viewModel.username,
                        password: viewModel.password
                    ) { result in
                        viewModel.handleSSOLoginResult(result)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color(.systemBackground))
                    .ignoresSafeArea()
                }

            }
        }
        .onTapGesture {
            focusedField = nil
        }
        .onAppear {
            if !appState.didExplicitlyLogout {
                viewModel.autoLogin()
            }
        }
        .onChange(of: viewModel.shouldProceedToHome) { _, shouldProceed in
            if shouldProceed, let result = viewModel.ssoResult {
                if case .success(let info) = result {
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

    // MARK: - Logo Section

    private var logoSection: some View {
        VStack(spacing: Theme.Spacing.medium) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 96, height: 96)

                Circle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 80, height: 80)

                Text("NIU")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 4) {
                Text("NIU APP")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(.label))

                Text("宜蘭大學學生助理")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(.secondaryLabel))
            }
        }
    }

    // MARK: - Input Section

    private var inputSection: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Text("帳號密碼與校務系統相同")
                .font(.system(size: 13))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading)

            NIUTextField(
                placeholder: "輸入學號",
                icon: "person",
                text: $viewModel.username,
                keyboardType: .asciiCapable
            )
            .focused($focusedField, equals: .username)
            .onChange(of: viewModel.username) { _, value in
                let filtered = value.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                if filtered != value {
                    viewModel.username = filtered
                }
            }
            .submitLabel(.next)
            .onSubmit { focusedField = .password }

            NIUTextField(
                placeholder: "密碼",
                icon: "lock",
                text: $viewModel.password,
                isSecure: true
            )
            .focused($focusedField, equals: .password)
            .submitLabel(.go)
            .onSubmit { viewModel.login() }
        }
    }

    // MARK: - Login Button

    private var loginButton: some View {
        NIUButton(
            "登入",
            icon: viewModel.isLoading ? nil : "arrow.right",
            isLoading: viewModel.isLoading
        ) {
            focusedField = nil
            viewModel.login()
        }
        .disabled(viewModel.isLoading || !viewModel.isFormValid)
        .opacity(viewModel.isFormValid ? 1.0 : 0.5)
    }

    // MARK: - Footer

    private var footerText: some View {
        VStack(spacing: 6) {
            Text("本程式為非官方第三方工具，與宜蘭大學官方無關")
                .font(.system(size: 12))
                .foregroundStyle(Color(.tertiaryLabel))

            Button {
                showPrivacySheet = true
            } label: {
                Text("隱私權聲明")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
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
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(AppState())
}

// MARK: - Privacy Policy View

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
            .foregroundColor(.primary.opacity(0.75))
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
