import SwiftUI

struct RootView: View {
    @StateObject private var appState = AppState()
    @ObservedObject private var sessionService = SSOSessionService.shared

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
                    SSOSessionService.shared.handleRefreshResult(result)
                }
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
            }
        }
        .environmentObject(appState)
    }
}

#Preview {
    RootView()
}
