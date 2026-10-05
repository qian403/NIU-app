import SwiftUI

struct LoginView: View {
    @StateObject private var viewModel = LoginViewModel()
    @EnvironmentObject private var appState: AppState
    @FocusState private var focusedField: Field?
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

            Link(destination: PrivacyPolicy.url) {
                Text("隱私權聲明")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
            }
            .accessibilityHint("開啟 NIU-Life 隱私權政策網頁")
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

// MARK: - Privacy Policy

enum PrivacyPolicy {
    static let url = URL(string: "https://niu-life.app/privacy")!
}
