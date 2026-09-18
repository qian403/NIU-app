import Foundation
import SwiftUI
import Combine
import UIKit

/// Manages SSO session refresh across all features.
///
/// When a feature WebView detects that the session has expired, it calls
/// `requestRefresh()`. This service triggers a single re-login via the
/// SSOLoginWebView embedded in RootView (using shared WKWebsiteDataStore
/// cookies). The school's interactive verification remains visible.
///
/// Auto-refresh is disabled when the user explicitly logs out and re-enabled
/// on the next successful login.
@MainActor
final class SSOSessionService: ObservableObject {

    static let shared = SSOSessionService()

    // MARK: - Published state (observed by RootView)

    /// When `true`, RootView should show the SSOLoginWebView.
    @Published private(set) var showRefreshWebView = false
    private(set) var refreshID = UUID()
    private(set) var lastFailureMessage: String?

    // MARK: - Internal state

    /// Credentials for re-login, loaded from LoginRepository on demand.
    private(set) var refreshAccount: String = ""
    private(set) var refreshPassword: String = ""

    /// `false` after the user explicitly logs out; `true` again after next login.
    private var autoRefreshEnabled = true

    /// `true` while a refresh is already in progress (used to coalesce requests).
    private var isRefreshing = false

    /// Callers waiting for the current refresh to finish.
    private var pendingContinuations: [CheckedContinuation<Bool, Never>] = []
    private var refreshTimeoutTask: Task<Void, Never>?
    private let refreshTimeoutSeconds: UInt64 = 180

    /// Avoid repeatedly hammering SSO when session is unstable.
    private var lastRefreshAttemptAt: Date?
    private var lastRefreshSuccessAt: Date?
    private var lastRefreshFailureAt: Date?
    private var consecutiveFailures = 0
    private let minAttemptGapSeconds: TimeInterval = 8
    private let successReuseSeconds: TimeInterval = 3600
    private let failureCooldownBaseSeconds: TimeInterval = 45
    private let failureCooldownMaxSeconds: TimeInterval = 300

    private init() {}

    // MARK: - Called by AppState

    func enableAutoRefresh() {
        autoRefreshEnabled = true
    }

    /// Disables refresh and fails any pending refresh requests immediately.
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
        refreshID = UUID()
        refreshPassword = ""
        refreshAccount = ""
        lastFailureMessage = nil
        drainPending(success: false)
    }

    // MARK: - Called by feature ViewModels on session expiry

    /// Re-authenticates using stored credentials in RootView's SSOLoginWebView
    /// (which shares the default cookie store).
    ///
    /// Returns `true` if the session was successfully refreshed.
    /// Multiple concurrent callers are coalesced per attempt: only one SSO login
    /// is performed at a time. Interactive login is attempted once; failures
    /// return to the caller with an actionable explanation.
    /// `force` skips reuse of a recent success when a caller has confirmed
    /// that its session is invalid. Coalescing and failure rate limits remain.
    func requestRefresh(force: Bool = false) async -> Bool {
        guard autoRefreshEnabled else {
            return rejectRefresh("請先登入帳號", reason: "disabled")
        }
        guard isAppActive else {
            return rejectRefresh("請回到 App 後再更新", reason: "inactive")
        }
        guard LoginRepository.shared.getSavedCredentials() != nil else {
            return rejectRefresh("找不到已儲存的登入資料，請到設定重新登入", reason: "missing-credentials")
        }

        let now = Date()

        // Confirmed expiry invalidates the previous success for every caller,
        // including callers that arrive while this forced refresh is running.
        if force { lastRefreshSuccessAt = nil }

        // If refresh is currently running, join existing task queue.
        if isRefreshing {
            return await withCheckedContinuation { continuation in
                pendingContinuations.append(continuation)
            }
        }

        // If we just refreshed successfully, allow caller to proceed without a new captcha run.
        if let lastSuccess = lastRefreshSuccessAt,
           now.timeIntervalSince(lastSuccess) < successReuseSeconds,
           SSOTokenStore.shared.isLikelyValid {
            return true
        }

        // Rate limit refresh trigger frequency.
        if let lastAttempt = lastRefreshAttemptAt,
           now.timeIntervalSince(lastAttempt) < minAttemptGapSeconds {
            return rejectRefresh("登入更新過於頻繁，請等幾秒後重試", reason: "rate-limit")
        }

        // On repeated failures, apply exponential cooldown to reduce 429 risk.
        if let lastFailure = lastRefreshFailureAt {
            let cooldown = min(
                failureCooldownBaseSeconds * pow(2.0, Double(max(consecutiveFailures - 1, 0))),
                failureCooldownMaxSeconds
            )
            if now.timeIntervalSince(lastFailure) < cooldown {
                let seconds = Int(ceil(cooldown - now.timeIntervalSince(lastFailure)))
                return rejectRefresh("上次校務登入未完成，請等 \(seconds) 秒後重試", reason: "cooldown")
            }
        }

        return await requestSingleRefresh()
    }

    private func requestSingleRefresh() async -> Bool {
        guard autoRefreshEnabled else { return false }
        guard isAppActive else { return false }

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
        lastFailureMessage = nil
        refreshID = UUID()
        print("[SSORefresh] 開始更新登入")
        refreshAccount = creds.username
        refreshPassword = creds.password
        isRefreshing = true
        showRefreshWebView = true
        scheduleRefreshTimeout()

        return await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    // MARK: - Called by the SSOLoginWebView in RootView

    func handleRefreshResult(_ result: SSOLoginResult, requestID: UUID) {
        guard isRefreshing, requestID == refreshID else { return }
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil
        showRefreshWebView = false
        isRefreshing = false

        let success: Bool
        switch result {
        case .success, .passwordExpiring:
            success = true
        case .credentialsFailed(let message), .passwordExpired(let message):
            lastFailureMessage = message
            success = false
        case .accountLocked:
            lastFailureMessage = "校務帳號已鎖定，請稍後再登入"
            success = false
        case .generic(_, let message):
            lastFailureMessage = message
            success = false
        case .systemError:
            lastFailureMessage = "校務登入服務暫時無法使用，請稍後重試"
            success = false
        }
        print("[SSORefresh] 完成 success=\(success)")
        refreshPassword = ""
        refreshAccount = ""

        if success {
            lastFailureMessage = nil
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
            print("[SSORefresh] 等待登入逾時")
            self.handleRefreshResult(.generic(title: "登入逾時",
                message: "校務登入逾時，請重新更新並完成登入驗證"), requestID: self.refreshID)
        }
    }

    private func rejectRefresh(_ message: String, reason: String) -> Bool {
        lastFailureMessage = message
        print("[SSORefresh] 未開始 reason=\(reason)")
        return false
    }

    private var isAppActive: Bool {
        UIApplication.shared.applicationState == .active
    }
}
