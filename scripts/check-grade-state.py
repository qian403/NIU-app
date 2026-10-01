#!/usr/bin/env python3
"""Exercise production grade loading with synthetic responses and isolated storage."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
view = (root / "Features/GradeHistory/Views/GradeHistoryView.swift").read_text()
result_enum = view[view.index("enum GradeHistoryWebResult {"):view.index("private struct GradeHistoryCourseDTO")]
fixture = r'''
import Foundation
@MainActor final class SSOSessionService {
    static let shared = SSOSessionService()
    var requests = 0
    var pending: CheckedContinuation<Bool, Never>?
    var lastFailureMessage: String?
    func requestRefresh(force: Bool) async -> Bool {
        requests += 1
        return await withCheckedContinuation { pending = $0 }
    }
}
@main struct Checks {
    @MainActor static func settle() async throws { try await Task.sleep(for: .milliseconds(40)) }
    @MainActor static func main() async throws {
        let suite = "grade-lifecycle-checks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = GradeHistoryViewModel(cacheDefaults: defaults, account: "synthetic")
        precondition(model.loadState == .idle && !model.showWebView && !model.isRefreshing,
                     "Constructing a navigation destination must not start loading")
        model.startIfNeeded()
        let first = model.webViewID
        precondition(model.loadState == .loading && model.showWebView && model.isRefreshing)
        model.startIfNeeded()
        precondition(model.webViewID == first, "Repeated appearance must not replace the active load")
        model.cancelLoading()
        precondition(model.loadState == .idle && !model.showWebView && !model.isModeLoading)
        model.handleWebResult(.historySuccess(GradeHistoryViewModel.sampleData), requestID: first)
        precondition(model.semesters.isEmpty, "A result after leaving the screen must be ignored")
        model.startIfNeeded()
        precondition(model.webViewID != first && model.isRefreshing, "Reentry must start a fresh request")
        model.handleWebResult(.historySuccess(GradeHistoryViewModel.sampleData), requestID: first)
        precondition(model.isRefreshing && model.semesters.isEmpty)
        model.handleWebResult(.historySuccess(GradeHistoryViewModel.sampleData), requestID: model.webViewID)
        precondition(model.loadState == .loaded && !model.isRefreshing && !model.semesters.isEmpty)
        let completed = model.webViewID
        model.startIfNeeded()
        precondition(!model.isRefreshing && model.webViewID == completed, "A recent cache should avoid a new load")
        model.refresh()
        model.cancelLoading()
        precondition(model.loadState == .loaded && !model.semesters.isEmpty, "Cancellation must preserve cached grades")
        let cached = GradeHistoryViewModel(cacheDefaults: defaults, account: "synthetic")
        precondition(cached.loadState == .loaded && !cached.showWebView && !cached.semesters.isEmpty)
        let other = GradeHistoryViewModel(cacheDefaults: defaults, account: "another")
        precondition(other.semesters.isEmpty && other.loadState == .idle, "Accounts cannot share grade caches")

        model.refresh()
        let historyRequest = model.webViewID
        model.selectMode(.final)
        model.handleWebResult(.historySuccess(GradeHistoryViewModel.sampleData), requestID: historyRequest)
        precondition(model.isRefreshing && model.semesters.isEmpty && model.termSnapshot == nil)
        model.handleWebResult(.termSuccess(GradeHistoryViewModel.sampleTermSnapshot), requestID: model.webViewID)
        precondition(model.loadState == .loaded && model.termSnapshot != nil)
        model.selectMode(.history)
        precondition(!model.isRefreshing && !model.semesters.isEmpty && model.termSnapshot == nil)

        let expired = GradeHistoryViewModel(cacheDefaults: defaults, account: "expired")
        expired.startIfNeeded()
        expired.handleWebResult(.sessionExpired, requestID: expired.webViewID)
        try await settle()
        let service = SSOSessionService.shared
        precondition(service.requests == 1 && service.pending != nil)
        expired.cancelLoading()
        expired.startIfNeeded()
        let replacement = expired.webViewID
        service.pending?.resume(returning: true)
        service.pending = nil
        try await settle()
        precondition(expired.webViewID == replacement && expired.showWebView,
                     "SSO completion from a dismissed screen must not replace its successor")
        expired.handleWebResult(.sessionExpired, requestID: replacement)
        try await settle()
        precondition(service.requests == 2)
        service.pending?.resume(returning: true)
        service.pending = nil
        try await settle()
        precondition(expired.webViewID != replacement && expired.showWebView)
        expired.handleWebResult(.sessionExpired, requestID: expired.webViewID)
        precondition(!expired.isRefreshing && service.requests == 2, "SSO retries must be bounded")

        let timedOut = GradeHistoryViewModel(cacheDefaults: defaults, account: "timeout",
                                            refreshTimeout: .milliseconds(30))
        timedOut.startIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        precondition(!timedOut.isRefreshing && !timedOut.showWebView && timedOut.lastRefreshError != nil)
        timedOut.startIfNeeded()
        precondition(timedOut.isRefreshing, "A timed-out screen must support retry on reentry")
        timedOut.cancelLoading()
        print("PASS: deferred first load, duplicate appearance, cancellation/reentry, stale responses, account cache isolation, mode switching, SSO cancellation/retry budget, timeout")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-grade-state-") as directory:
    folder = Path(directory)
    checks = folder / "Checks.swift"
    checks.write_text(result_enum + fixture)
    binary = folder / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(folder / "ModuleCache"),
        "-parse-as-library", str(root / "Features/GradeHistory/Models/GradeHistoryModels.swift"),
        str(root / "Features/GradeHistory/ViewModels/GradeHistoryViewModel.swift"),
        str(checks), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
