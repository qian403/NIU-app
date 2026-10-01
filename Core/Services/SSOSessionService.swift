import Foundation
import SwiftUI
import Combine
import UIKit

/// Manages SSO session refresh across all features.
///
/// When a feature WebView detects that the session has expired, it calls
/// `requestRefresh()`. This service triggers a single re-login via the
/// SSOLoginWebView embedded in RootView (using shared WKWebsiteDataStore
/// cookies). Refresh runs behind the current screen; only failed or stalled
/// automatic sign-ins reveal the school page for manual recovery.
///
/// Auto-refresh is disabled when the user explicitly logs out and re-enabled
/// on the next successful login.
@MainActor
final class SSOSessionService: ObservableObject {

    static let shared = SSOSessionService()

    // MARK: - Published state (observed by RootView)

    /// The WebView remains mounted while refreshing, independently of presentation.
    @Published private(set) var isRefreshing = false
    /// Only interactive recovery covers the current screen.
    @Published private(set) var showRefreshWebView = false
    @Published private(set) var isRefreshPageReadyForInteraction = false
    @Published private(set) var refreshID = UUID()
    @Published private(set) var lastFailureMessage: String?

    // MARK: - Internal state

    /// Credentials for re-login, loaded from LoginRepository on demand.
    private(set) var refreshAccount: String = ""
    private(set) var refreshPassword: String = ""

    /// `false` after the user explicitly logs out; `true` again after next login.
    private var autoRefreshEnabled = true

    /// Callers waiting for the current refresh to finish.
    private var pendingContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var refreshTimeoutTask: Task<Void, Never>?
    private var backgroundTimeoutTask: Task<Void, Never>?
    private var refreshDeadline: ContinuousClock.Instant?
    private let backgroundTimeout: Duration
    private let refreshTimeout: Duration
    private let credentialsProvider: @MainActor () -> (username: String, password: String)?
    private let applicationIsActive: @MainActor () -> Bool
    private let tokenIsValid: @MainActor () -> Bool

    /// Avoid repeatedly hammering SSO when session is unstable.
    private var lastRefreshAttemptAt: Date?
    private var lastRefreshSuccessAt: Date?
    private var lastRefreshFailureAt: Date?
    private var consecutiveFailures = 0
    private let minAttemptGapSeconds: TimeInterval = 8
    private let successReuseSeconds: TimeInterval = 3600
    private let failureCooldownBaseSeconds: TimeInterval = 45
    private let failureCooldownMaxSeconds: TimeInterval = 300

    init(
        credentialsProvider: @escaping @MainActor () -> (username: String, password: String)? = {
            LoginRepository.shared.getSavedCredentials()
        },
        applicationIsActive: @escaping @MainActor () -> Bool = {
            UIApplication.shared.applicationState == .active
        },
        tokenIsValid: @escaping @MainActor () -> Bool = { SSOTokenStore.shared.isLikelyValid },
        backgroundTimeout: Duration = .seconds(15),
        refreshTimeout: Duration = .seconds(180)
    ) {
        self.credentialsProvider = credentialsProvider
        self.applicationIsActive = applicationIsActive
        self.tokenIsValid = tokenIsValid
        self.backgroundTimeout = backgroundTimeout
        self.refreshTimeout = refreshTimeout
    }

    // MARK: - Called by AppState

    func enableAutoRefresh() {
        autoRefreshEnabled = true
    }

    /// Disables refresh and fails any pending refresh requests immediately.
    func disableAutoRefresh() {
        autoRefreshEnabled = false
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil
        backgroundTimeoutTask?.cancel()
        backgroundTimeoutTask = nil
        refreshDeadline = nil
        showRefreshWebView = false
        isRefreshPageReadyForInteraction = false
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
    /// is performed at a time. Failed automatic login reveals manual recovery;
    /// callers resume on success, cancellation or the overall timeout.
    /// `force` skips reuse of a recent success when a caller has confirmed
    /// that its session is invalid. Coalescing and failure rate limits remain.
    func requestRefresh(force: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard autoRefreshEnabled else {
            return rejectRefresh("請先登入帳號", reason: "disabled")
        }
        guard applicationIsActive() else {
            return rejectRefresh("請回到 App 後再更新", reason: "inactive")
        }
        guard credentialsProvider() != nil else {
            return rejectRefresh("找不到已儲存的登入資料，請到設定重新登入", reason: "missing-credentials")
        }

        let now = Date()

        // Confirmed expiry invalidates the previous success for every caller,
        // including callers that arrive while this forced refresh is running.
        if force { lastRefreshSuccessAt = nil }

        // If refresh is currently running, join existing task queue.
        if isRefreshing {
            return await waitForRefresh()
        }

        // If we just refreshed successfully, allow caller to proceed without a new captcha run.
        if let lastSuccess = lastRefreshSuccessAt,
           now.timeIntervalSince(lastSuccess) < successReuseSeconds,
           tokenIsValid() {
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
        guard applicationIsActive() else { return false }

        guard let creds = credentialsProvider() else {
            return false
        }

        if isRefreshing {
            // Another refresh is already in progress – join the queue
            return await waitForRefresh()
        }

        lastRefreshAttemptAt = Date()
        lastFailureMessage = nil
        refreshID = UUID()
        print("[SSORefresh] 開始更新登入")
        refreshAccount = creds.username
        refreshPassword = creds.password
        isRefreshing = true
        showRefreshWebView = false
        isRefreshPageReadyForInteraction = false
        refreshDeadline = ContinuousClock.now + refreshTimeout
        scheduleRefreshTimeout()
        scheduleBackgroundTimeout()

        return await waitForRefresh()
    }

    private func waitForRefresh() async -> Bool {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    if pendingContinuations.isEmpty {
                        completeRefresh(success: false, recordFailure: false)
                    }
                    return
                }
                pendingContinuations[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let continuation = self.pendingContinuations.removeValue(forKey: waiterID) else { return }
                continuation.resume(returning: false)
                if self.pendingContinuations.isEmpty {
                    self.completeRefresh(success: false, recordFailure: false)
                }
            }
        }
    }

    // MARK: - Called by the SSOLoginWebView in RootView

    func handleRefreshResult(_ result: SSOLoginResult, requestID: UUID) {
        guard isRefreshing, requestID == refreshID else { return }
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
        guard success else {
            requireInteraction(requestID: requestID)
            return
        }
        completeRefresh(success: true)
    }

    func requireInteraction(requestID: UUID) {
        guard isRefreshing, requestID == refreshID else { return }
        backgroundTimeoutTask?.cancel()
        backgroundTimeoutTask = nil
        showRefreshWebView = true
    }

    func retryInteractiveLogin() {
        guard isRefreshing, showRefreshWebView else { return }
        isRefreshPageReadyForInteraction = false
        refreshID = UUID()
        lastFailureMessage = nil
        scheduleRefreshTimeout()
    }

    func markInteractionReady(requestID: UUID) {
        guard isRefreshing, showRefreshWebView, requestID == refreshID else { return }
        isRefreshPageReadyForInteraction = true
    }

    func cancelRefresh() {
        guard isRefreshing else { return }
        lastFailureMessage = "已取消登入更新，可稍後重新整理再試"
        completeRefresh(success: false, recordFailure: false)
    }

    private func completeRefresh(success: Bool, recordFailure: Bool = true) {
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil
        backgroundTimeoutTask?.cancel()
        backgroundTimeoutTask = nil
        refreshDeadline = nil
        showRefreshWebView = false
        isRefreshPageReadyForInteraction = false
        isRefreshing = false
        refreshID = UUID()
        print("[SSORefresh] 完成 success=\(success)")
        refreshPassword = ""
        refreshAccount = ""

        if success {
            lastFailureMessage = nil
            lastRefreshSuccessAt = Date()
            lastRefreshFailureAt = nil
            consecutiveFailures = 0
        } else if recordFailure {
            lastRefreshFailureAt = Date()
            consecutiveFailures += 1
        }

        drainPending(success: success)
    }

    // MARK: - Private helpers

    private func drainPending(success: Bool) {
        let continuations = pendingContinuations
        pendingContinuations = [:]
        for c in continuations.values { c.resume(returning: success) }
    }

    private func scheduleRefreshTimeout() {
        refreshTimeoutTask?.cancel()
        guard let deadline = refreshDeadline else { return }
        let requestID = refreshID
        refreshTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self, self.isRefreshing, self.refreshID == requestID else { return }
            print("[SSORefresh] 等待登入逾時")
            self.lastFailureMessage = "校務登入逾時，請重新更新並完成登入驗證"
            self.completeRefresh(success: false)
        }
    }

    private func scheduleBackgroundTimeout() {
        backgroundTimeoutTask?.cancel()
        let requestID = refreshID
        let timeout = backgroundTimeout
        backgroundTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.isRefreshing, self.refreshID == requestID else { return }
            self.requireInteraction(requestID: requestID)
        }
    }

    private func rejectRefresh(_ message: String, reason: String) -> Bool {
        lastFailureMessage = message
        print("[SSORefresh] 未開始 reason=\(reason)")
        return false
    }

}
