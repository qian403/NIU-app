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
            if sessionService.showRefreshWebView {
                let refreshID = sessionService.refreshID
                SSOLoginScreen(
                    account: sessionService.refreshAccount,
                    password: sessionService.refreshPassword
                ) { result in
                    SSOSessionService.shared.handleRefreshResult(result, requestID: refreshID)
                }
                .id(refreshID)
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
