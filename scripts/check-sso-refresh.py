#!/usr/bin/env python3
"""Exercise production SSO refresh states with synthetic credentials and no Keychain."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
service = (root / "Core/Services/SSOSessionService.swift").read_text().replace("import UIKit\n", "")
view = (root / "Features/Authentication/Services/SSOLoginWebView.swift").read_text()
result_types = view[view.index("public struct StudentInfo"):view.index("private func sso_percentEncodeForm")]
fixture = r'''
import Foundation
@MainActor enum UIApplication {
    enum State { case active }
    static let shared = UIApplicationStub()
}
@MainActor struct UIApplicationStub { let applicationState = UIApplication.State.active }
@MainActor final class LoginRepository {
    static let shared = LoginRepository()
    func getSavedCredentials() -> (username: String, password: String)? {
        fatalError("Real credential providers must not run in fixture")
    }
}
@MainActor final class SSOTokenStore {
    static let shared = SSOTokenStore()
    var isLikelyValid: Bool { fatalError("Real tokens must not be used") }
}
@main struct Checks {
    @MainActor static func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }
    @MainActor static func makeService(background: Duration = .seconds(2),
                                      timeout: Duration = .seconds(3)) -> SSOSessionService {
        SSOSessionService(credentialsProvider: { ("synthetic", "fixture-password") },
                          applicationIsActive: { true }, tokenIsValid: { true },
                          backgroundTimeout: background, refreshTimeout: timeout)
    }
    @MainActor static func main() async throws {
        let info = StudentInfo(name: "Synthetic Student", department: "Fixture", grade: "3")
        let fast = makeService(background: .milliseconds(150))
        let first = Task { await fast.requestRefresh(force: true) }
        try await settle()
        let firstID = fast.refreshID
        precondition(fast.isRefreshing && !fast.showRefreshWebView, "Refresh must start without covering the app")
        let joined = Task { await fast.requestRefresh(force: true) }
        try await settle()
        precondition(fast.refreshID == firstID, "Concurrent callers must share one login")
        fast.handleRefreshResult(.success(info: info), requestID: firstID)
        let firstResult = await first.value
        let joinedResult = await joined.value
        precondition(firstResult && joinedResult && !fast.isRefreshing && !fast.showRefreshWebView)
        precondition(fast.refreshAccount.isEmpty && fast.refreshPassword.isEmpty)
        try await Task.sleep(for: .milliseconds(180))
        precondition(!fast.showRefreshWebView, "A completed background timer must not reveal login")
        let reused = await fast.requestRefresh()
        precondition(reused && !fast.isRefreshing)

        let recovery = makeService()
        let recovering = Task { await recovery.requestRefresh() }
        try await settle()
        let backgroundID = recovery.refreshID
        recovery.handleRefreshResult(.credentialsFailed(message: "Synthetic rejection"), requestID: backgroundID)
        precondition(recovery.isRefreshing && recovery.showRefreshWebView && recovery.refreshID == backgroundID,
                     "Failed automation must reveal the same attempt and keep callers waiting")
        recovery.handleRefreshResult(.systemError, requestID: backgroundID)
        precondition(recovery.isRefreshing && recovery.showRefreshWebView)
        recovery.markInteractionReady(requestID: backgroundID)
        precondition(recovery.isRefreshPageReadyForInteraction)
        recovery.retryInteractiveLogin()
        let manualID = recovery.refreshID
        precondition(manualID != backgroundID && recovery.showRefreshWebView && !recovery.isRefreshPageReadyForInteraction)
        recovery.markInteractionReady(requestID: backgroundID)
        precondition(!recovery.isRefreshPageReadyForInteraction)
        recovery.markInteractionReady(requestID: manualID)
        precondition(recovery.isRefreshPageReadyForInteraction)
        recovery.handleRefreshResult(.success(info: info), requestID: backgroundID)
        precondition(recovery.isRefreshing, "Old page completion must not finish the replacement")
        recovery.handleRefreshResult(.success(info: info), requestID: manualID)
        let recovered = await recovering.value
        precondition(recovered && !recovery.isRefreshing)

        let slow = makeService(background: .milliseconds(40))
        let stalled = Task { await slow.requestRefresh() }
        try await Task.sleep(for: .milliseconds(90))
        precondition(slow.isRefreshing && slow.showRefreshWebView, "Stalled automation needs visible recovery")
        let cancelledID = slow.refreshID
        slow.cancelRefresh()
        let cancelled = await stalled.value
        precondition(!cancelled && !slow.isRefreshing && !slow.showRefreshWebView)
        slow.requireInteraction(requestID: cancelledID)
        precondition(!slow.showRefreshWebView)

        let waiting = makeService()
        let one = Task { await waiting.requestRefresh() }
        try await settle()
        let two = Task { await waiting.requestRefresh() }
        try await settle()
        one.cancel()
        let oneResult = await one.value
        precondition(!oneResult && waiting.isRefreshing, "Cancelling one caller must preserve other callers")
        two.cancel()
        let twoResult = await two.value
        try await settle()
        precondition(!twoResult && !waiting.isRefreshing && waiting.refreshPassword.isEmpty,
                     "No remaining callers must stop the hidden login")

        let logout = makeService(background: .milliseconds(50))
        let pending = Task { await logout.requestRefresh() }
        try await settle()
        let oldID = logout.refreshID
        logout.disableAutoRefresh()
        let loggedOut = await pending.value
        logout.handleRefreshResult(.success(info: info), requestID: oldID)
        try await Task.sleep(for: .milliseconds(80))
        precondition(!loggedOut && !logout.isRefreshing && !logout.showRefreshWebView && logout.refreshPassword.isEmpty)
        logout.enableAutoRefresh()
        let newLogin = Task { await logout.requestRefresh() }
        try await settle()
        logout.handleRefreshResult(.success(info: info), requestID: logout.refreshID)
        let newResult = await newLogin.value
        precondition(newResult, "Logout must reset rate limits for the next account")

        let timeout = makeService(background: .milliseconds(30), timeout: .milliseconds(70))
        let timed = Task { await timeout.requestRefresh() }
        let timedResult = await timed.value
        precondition(!timedResult && !timeout.isRefreshing && !timeout.showRefreshWebView && timeout.lastFailureMessage != nil)
        let cooldown = await timeout.requestRefresh(force: true)
        precondition(!cooldown && !timeout.isRefreshing, "Timeout must retain retry rate limits")
        let reloading = makeService(background: .milliseconds(20), timeout: .milliseconds(150))
        let reloadWaiter = Task { await reloading.requestRefresh() }
        try await Task.sleep(for: .milliseconds(45))
        reloading.retryInteractiveLogin()
        try await Task.sleep(for: .milliseconds(120))
        precondition(!reloading.isRefreshing, "Reload must not extend the original refresh deadline")
        let reloadResult = await reloadWaiter.value
        precondition(!reloadResult)
        let missing = SSOSessionService(credentialsProvider: { nil }, applicationIsActive: { true }, tokenIsValid: { false })
        let unavailable = await missing.requestRefresh()
        precondition(!unavailable && !missing.isRefreshing)
        print("PASS: silent success, request coalescing, manual recovery/reload, stale callbacks/timers, cancellation, logout, overall timeout and rate limits")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-sso-refresh-") as directory:
    folder = Path(directory)
    checks = folder / "Checks.swift"
    checks.write_text(service + result_types + fixture)
    binary = folder / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", str(folder / "ModuleCache"), str(checks), "-o", str(binary)],
                   check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
