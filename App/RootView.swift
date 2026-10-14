import SwiftUI

struct RootView: View {
    @StateObject private var appState = AppState()
    @StateObject private var router = CampusRouter.shared
    @StateObject private var updateChecker = AppUpdateChecker.shared
    @StateObject private var whatsNew = WhatsNewStore.shared
    @ObservedObject private var sessionService = SSOSessionService.shared
    @AppStorage(StorageKeys.authSessionID) private var authSessionID = ""
    @AppStorage("app.appearance.mode") private var appearanceModeRaw = AppAppearanceMode.system.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Group {
                if appState.isLoggingOut {
                    ProgressView("正在清除登入資料…")
                } else if appState.isAuthenticated {
                    HomeView()
                        .id(authSessionID)
                } else {
                    LoginView()
                }
            }
            .accessibilityHidden(sessionService.showRefreshWebView)
            .allowsHitTesting(!sessionService.showRefreshWebView)

            // Session refresh may require interactive verification on the school's page.
            if sessionService.isRefreshing {
                let refreshID = sessionService.refreshID
                SSOLoginWebView(
                    account: sessionService.refreshAccount,
                    password: sessionService.refreshPassword,
                    automaticallySubmits: !sessionService.showRefreshWebView,
                    submitsAfterVerification: sessionService.resumesAfterVerification,
                    onInteractionRequired: {
                        sessionService.requireInteraction(requestID: refreshID)
                    },
                    onInteractionReady: {
                        sessionService.markInteractionReady(requestID: refreshID)
                    },
                    isAttemptCurrent: {
                        sessionService.isRefreshing && sessionService.refreshID == refreshID
                    }
                ) { result in
                    sessionService.handleRefreshResult(result, requestID: refreshID)
                }
                .id(refreshID)
                .allowsHitTesting(sessionService.isRefreshPageReadyForInteraction)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if sessionService.showRefreshWebView {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("請完成校務登入").font(.headline)
                                Spacer()
                                Button("取消", action: sessionService.cancelRefresh)
                                    .frame(minHeight: 44)
                            }
                            Text(sessionService.lastFailureMessage
                                 ?? (sessionService.resumesAfterVerification
                                     ? "點一下下方的驗證框，通過後會自動登入。"
                                     : "無法自動完成登入，請在下方完成校方驗證。"))
                                .font(.footnote).foregroundStyle(.secondary)
                            if !sessionService.isRefreshPageReadyForInteraction {
                                ProgressView("正在準備登入頁…").font(.footnote)
                            }
                            Button("重新載入登入頁", action: sessionService.retryInteractiveLogin)
                                .font(.footnote)
                                .frame(minHeight: 44)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                    }
                }
                .opacity(sessionService.showRefreshWebView ? 1 : 0)
                .accessibilityHidden(!sessionService.showRefreshWebView)
                .allowsHitTesting(sessionService.showRefreshWebView)
                .zIndex(1)
            }
        }
        .environmentObject(appState)
        .environmentObject(router)
        .onOpenURL { url in
            guard let destination = CampusDestination(url: url) ?? CampusDestination(universalLink: url) else { return }
            router.open(destination)
        }
        .preferredColorScheme(currentAppearanceMode.colorScheme)
        .sheet(isPresented: Binding(
            get: { isWhatsNewPresented },
            // Only a user dismissal reaches here; hiding it for login or a session refresh keeps it pending.
            set: { if !$0 { whatsNew.markSeen() } }
        )) {
            WhatsNewView(notes: whatsNew.pendingNotes, onContinue: whatsNew.markSeen)
        }
        .alert("有新版本可下載", isPresented: Binding(
            get: { updateChecker.availableUpdate != nil && !isWhatsNewPresented },
            set: { if !$0 { updateChecker.dismissUpdate() } }
        ), presenting: updateChecker.availableUpdate) { update in
            Button("前往更新") {
                openURL(update.url)
                updateChecker.dismissUpdate()
            }
            Button("我知道了", role: .cancel) {
                updateChecker.dismissUpdate()
            }
        } message: { update in
            Text("NIU-Life \(update.version) 已推出，前往 App Store 下載最新版本。")
        }
        .onChange(of: scenePhase, initial: true) { _, newValue in
            guard newValue == .active else { return }
            Task { await updateChecker.checkIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            guard scenePhase == .active else { return }
            appState.significantTimeChanged()
        }
        .onChange(of: scenePhase) { _, newValue in
            switch newValue {
            case .active:
                Task { await appState.applicationDidBecomeActive() }
            case .background:
                appState.applicationDidEnterBackground()
            default:
                break
            }
        }
    }

    /// Introduces this version once the user reaches the home screen, never over login or school verification.
    private var isWhatsNewPresented: Bool {
        !whatsNew.pendingNotes.isEmpty
            && appState.isAuthenticated
            && !appState.isLoggingOut
            && !sessionService.isRefreshing
    }

    private var currentAppearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }
}

#Preview {
    RootView()
}
