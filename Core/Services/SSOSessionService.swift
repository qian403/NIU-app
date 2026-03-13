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
    private var refreshTimeoutTask: Task<Void, Never>?
    private let refreshTimeoutSeconds: UInt64 = 35
    private let maxRefreshAttempts = 1
    private let retryBackoffNanoseconds: UInt64 = 2_000_000_000

    /// Avoid repeatedly hammering SSO when session is unstable.
    private var lastRefreshAttemptAt: Date?
    private var lastRefreshSuccessAt: Date?
    private var lastRefreshFailureAt: Date?
    private var consecutiveFailures = 0
    private let minAttemptGapSeconds: TimeInterval = 8
    private let successReuseSeconds: TimeInterval = 90
    private let failureCooldownBaseSeconds: TimeInterval = 45
    private let failureCooldownMaxSeconds: TimeInterval = 300

    private init() {}

    // MARK: - Called by AppState

    func enableAutoRefresh() {
        autoRefreshEnabled = true
    }

    /// Disables silent refresh and fails any pending refresh requests immediately.
    func disableAutoRefresh() {
        autoRefreshEnabled = false
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil
        showRefreshWebView = false
        isRefreshing = false
        consecutiveFailures = 0
        lastRefreshAttemptAt = nil
        lastRefreshFailureAt = nil
        lastRefreshSuccessAt = nil
        drainPending(success: false)
    }

    // MARK: - Called by feature ViewModels on session expiry

    /// Silently re-authenticates using stored credentials by showing an invisible
    /// SSOLoginWebView in RootView (which shares the default cookie store).
    ///
    /// Returns `true` if the session was successfully refreshed.
    /// Multiple concurrent callers are coalesced per attempt: only one SSO login
    /// is performed at a time. If an attempt fails, the service retries in
    /// background automatically a few times before returning `false`.
    func requestRefresh() async -> Bool {
        guard autoRefreshEnabled else { return false }
        guard LoginRepository.shared.getSavedCredentials() != nil else { return false }

        let now = Date()

        // If we just refreshed successfully, allow caller to proceed without a new captcha run.
        if let lastSuccess = lastRefreshSuccessAt,
           now.timeIntervalSince(lastSuccess) < successReuseSeconds {
            return true
        }

        // If refresh is currently running, join existing task queue.
        if isRefreshing {
            return await withCheckedContinuation { continuation in
                pendingContinuations.append(continuation)
            }
        }

        // Rate limit refresh trigger frequency.
        if let lastAttempt = lastRefreshAttemptAt,
           now.timeIntervalSince(lastAttempt) < minAttemptGapSeconds {
            return false
        }

        // On repeated failures, apply exponential cooldown to reduce 429 risk.
        if let lastFailure = lastRefreshFailureAt {
            let cooldown = min(
                failureCooldownBaseSeconds * pow(2.0, Double(max(consecutiveFailures - 1, 0))),
                failureCooldownMaxSeconds
            )
            if now.timeIntervalSince(lastFailure) < cooldown {
                return false
            }
        }

        var attempt = 1
        while attempt <= maxRefreshAttempts {
            let refreshed = await requestSingleRefresh()
            if refreshed {
                return true
            }

            attempt += 1
            guard attempt <= maxRefreshAttempts else { break }
            try? await Task.sleep(nanoseconds: retryBackoffNanoseconds)
        }

        return false
    }

    private func requestSingleRefresh() async -> Bool {
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

        lastRefreshAttemptAt = Date()
        refreshAccount = creds.username
        refreshPassword = creds.password
        isRefreshing = true
        showRefreshWebView = true
        scheduleRefreshTimeout()

        return await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    // MARK: - Called by the invisible SSOLoginWebView in RootView

    func handleRefreshResult(_ result: SSOLoginResult) {
        guard isRefreshing else { return }
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil
        showRefreshWebView = false
        isRefreshing = false

        let success: Bool
        switch result {
        case .success, .passwordExpiring:
            success = true
        default:
            success = false
        }

        if success {
            lastRefreshSuccessAt = Date()
            lastRefreshFailureAt = nil
            consecutiveFailures = 0
        } else {
            lastRefreshFailureAt = Date()
            consecutiveFailures += 1
        }

        drainPending(success: success)
    }

    // MARK: - Private helpers

    private func drainPending(success: Bool) {
        let continuations = pendingContinuations
        pendingContinuations = []
        for c in continuations { c.resume(returning: success) }
    }

    private func scheduleRefreshTimeout() {
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: refreshTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard self.isRefreshing else { return }
            self.showRefreshWebView = false
            self.isRefreshing = false
            self.lastRefreshFailureAt = Date()
            self.consecutiveFailures += 1
            self.drainPending(success: false)
        }
    }
}
