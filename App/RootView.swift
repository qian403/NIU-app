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

            // Session refresh may require interactive verification on the school's page.
            if sessionService.showRefreshWebView {
                let refreshID = sessionService.refreshID
                SSOLoginWebView(
                    account: sessionService.refreshAccount,
                    password: sessionService.refreshPassword
                ) { result in
                    SSOSessionService.shared.handleRefreshResult(result, requestID: refreshID)
                }
                .id(refreshID)
                .background(Color(.systemBackground))
                .ignoresSafeArea()
                .zIndex(1)
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
