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

    private var isShowingSSO: Bool {
        viewModel.ssoLoginStarted && !viewModel.ssoLoginCompleted
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
                .accessibilityHidden(isShowingSSO)
                .allowsHitTesting(!isShowingSSO)

                if isShowingSSO {
                    SSOLoginScreen(
                        account: viewModel.username,
                        password: viewModel.password
                    ) { result in
                        viewModel.handleSSOLoginResult(result)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
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

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(String, String)] = [
        ("非官方校務工具", "本 App 為個人開發的第三方校務輔助工具，與國立宜蘭大學並無隸屬、合作或授權關係。校務資訊與服務狀態請以學校官方系統為準。"),
        ("登入與校務資料", "本 App 使用您既有的學校帳號，不建立新帳號。帳號、密碼及登入憑證只用於連線至學校的校務、M 園區與圖書館服務，不傳送至開發者伺服器。登入憑證儲存在裝置 Keychain；姓名、課表、成績與畢業門檻等資料會在裝置上暫存，供查詢與重新整理使用。學校服務對連線與帳號資料的處理，依各服務的隱私政策辦理。"),
        ("小工具、通知與即時動態", "課表可在 App 與本機 Widget 間共用，並顯示於主畫面或鎖定畫面。通知由裝置本機排程；課表即時動態由 App 在可執行時更新，背景更新時間由系統決定。本版本不向開發者後端同步課表、裝置識別碼或推播憑證。請依您的隱私需求選擇是否啟用鎖定畫面顯示。"),
        ("裝置權限", "相機僅供掃描課堂點名 QR Code，不儲存或上傳相機影像。匯出課表時會要求行事曆寫入權限；啟用提醒時會要求通知權限。您可拒絕或在系統設定中撤回權限。圖書館通行碼只在記憶體顯示，離頁或進入背景時隱藏。"),
        ("登出與資料清除", "在設定中登出，會移除本機登入憑證、校務快取、Widget 課表、網站登入資料、下載預覽暫存及已排程的通知，並結束課表即時動態。您自行匯出至行事曆、檔案或分享給其他 App 的副本須在目的 App 中刪除。登出不會刪除您的學校帳號或校方保存的資料；如需處理校方帳號，請聯絡學校。"),
        ("分析與第三方服務", "本版本未整合廣告、跨 App 追蹤或開發者使用行為分析服務。您透過問題回報主動寄出的內容，會用於回覆與處理該問題；寄送前可自行編輯。系統診斷與分享設定依 Apple 的政策辦理。開啟外部網站時，請另行參閱該網站的隱私政策。"),
        ("聯絡與更新", "若對資料處理有疑問，請寄信至 hi@chien.dev。政策更新會同步至 App 與公開政策頁面。更新日期：2026-09-18。")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                ForEach(sections, id: \.0) { title, text in
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(text).font(.body).foregroundStyle(.secondary)
                }
                Link("聯絡開發者", destination: URL(string: "mailto:hi@chien.dev")!)
                Link("專案與支援", destination: URL(string: "https://github.com/qian403/NIU-app")!)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.large)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("隱私權聲明")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("關閉") { dismiss() }
            }
        }
    }
}
