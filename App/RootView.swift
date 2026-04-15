import SwiftUI

struct RootView: View {
    @StateObject private var appState = AppState()
    @ObservedObject private var sessionService = SSOSessionService.shared
    @AppStorage("app.appearance.mode") private var appearanceModeRaw = AppAppearanceMode.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if appState.isAuthenticated {
                HomeView()
            } else {
                LoginView()
            }

            // Invisible WebView that silently re-authenticates via SSO when any
            // feature detects session expiry. Uses the shared WKWebsiteDataStore
            // so refreshed cookies are immediately available to all feature WebViews.
            if sessionService.showRefreshWebView {
                SSOLoginWebView(
                    account: sessionService.refreshAccount,
                    password: sessionService.refreshPassword
                ) { result in
                    // Silent refresh should only restore session cookies.
                    // Updating app-level profile here can rebuild root navigation
                    // and unexpectedly pop the current feature page.
                    SSOSessionService.shared.handleRefreshResult(result)
                }
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
            }
        }
        .environmentObject(appState)
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
