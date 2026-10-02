import SwiftUI

struct RootView: View {
    @StateObject private var appState = AppState()
    @StateObject private var router = CampusRouter.shared
    @ObservedObject private var sessionService = SSOSessionService.shared
    @AppStorage("app.appearance.mode") private var appearanceModeRaw = AppAppearanceMode.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Group {
                if appState.isLoggingOut {
                    ProgressView("正在清除登入資料…")
                } else if appState.isAuthenticated {
                    HomeView()
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
                            Text(sessionService.lastFailureMessage ?? "無法自動完成登入，請在下方完成校方驗證。")
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
            guard let destination = CampusDestination(url: url) else { return }
            router.open(destination)
        }
        .preferredColorScheme(currentAppearanceMode.colorScheme)
        .task(id: appState.isAuthenticated && scenePhase == .active) {
            guard appState.isAuthenticated, scenePhase == .active else { return }
            await sessionService.refreshIfNeeded()
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

    private var currentAppearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }
}

#Preview {
    RootView()
}
