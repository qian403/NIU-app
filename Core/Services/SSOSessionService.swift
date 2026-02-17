import Foundation
import SwiftUI
import Combine

/// Manages transparent SSO session refresh across all features.
///
/// When a feature WebView detects that the session has expired, it calls
/// `requestRefresh()`. This service triggers a single invisible re-login via
/// the SSOLoginWebView embedded in RootView (using shared WKWebsiteDataStore
/// cookies), so every subsequent feature WebView automatically benefits from
/// the refreshed session without any visible interruption.
///
/// Auto-refresh is disabled when the user explicitly logs out and re-enabled
/// on the next successful login.
@MainActor
final class SSOSessionService: ObservableObject {

    static let shared = SSOSessionService()

    // MARK: - Published state (observed by RootView)

    /// When `true`, RootView should show the invisible SSOLoginWebView.
    @Published private(set) var showRefreshWebView = false

    // MARK: - Internal state

    /// Credentials for the silent re-login, loaded from LoginRepository on demand.
    private(set) var refreshAccount: String = ""
    private(set) var refreshPassword: String = ""

    /// `false` after the user explicitly logs out; `true` again after next login.
    private var autoRefreshEnabled = true

    /// `true` while a refresh is already in progress (used to coalesce requests).
    private var isRefreshing = false

    /// Callers waiting for the current refresh to finish.
    private var pendingContinuations: [CheckedContinuation<Bool, Never>] = []

    private init() {}

    // MARK: - Called by AppState

    func enableAutoRefresh() {
        autoRefreshEnabled = true
    }

    /// Disables silent refresh and fails any pending refresh requests immediately.
    func disableAutoRefresh() {
        autoRefreshEnabled = false
        drainPending(success: false)
    }

    // MARK: - Called by feature ViewModels on session expiry

    /// Silently re-authenticates using stored credentials by showing an invisible
    /// SSOLoginWebView in RootView (which shares the default cookie store).
    ///
    /// Returns `true` if the session was successfully refreshed.
    /// Multiple concurrent callers are coalesced: only one SSO login is performed.
    func requestRefresh() async -> Bool {
        guard autoRefreshEnabled else { return false }

        guard let creds = LoginRepository.shared.getSavedCredentials() else {
            return false
        }

        if isRefreshing {
            // Another refresh is already in progress – join the queue
            return await withCheckedContinuation { continuation in
                pendingContinuations.append(continuation)
            }
        }

        refreshAccount = creds.username
        refreshPassword = creds.password
        isRefreshing = true
        showRefreshWebView = true

        return await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    // MARK: - Called by the invisible SSOLoginWebView in RootView

    func handleRefreshResult(_ result: SSOLoginResult) {
        showRefreshWebView = false
        isRefreshing = false

        let success: Bool
        switch result {
        case .success, .passwordExpiring:
            success = true
        default:
            success = false
        }

        drainPending(success: success)
    }

    // MARK: - Private helpers

    private func drainPending(success: Bool) {
        let continuations = pendingContinuations
        pendingContinuations = []
        for c in continuations { c.resume(returning: success) }
    }
}
