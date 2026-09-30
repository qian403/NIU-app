#!/usr/bin/env python3
"""Run production Moodle question filtering and request lifecycle with synthetic data."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHECKS = r'''
import Foundation

@MainActor final class MoodleService {
    var sessionRevision = 0
    func fetchCourseContents(courseId: Int) async throws -> [MoodleCourseSection] {
        fatalError("Real Moodle requests are forbidden in this fixture")
    }
}

func module(_ id: Int, _ kind: String = "quiz", extra: [String: Any] = [:]) throws -> MoodleModule {
    var value: [String: Any] = ["id": id, "name": "合成活動 \(id)", "modname": kind, "instance": 9000 + id]
    value.merge(extra) { _, new in new }
    return try JSONDecoder().decode(MoodleModule.self, from: JSONSerialization.data(withJSONObject: value))
}
func section(_ id: Int, _ modules: [MoodleModule], visible: Int? = nil) -> MoodleCourseSection {
    MoodleCourseSection(id: id, name: "合成主題", visible: visible, summary: "", modules: modules)
}
@MainActor final class Client: MoodleQuestionsAPIClientProtocol {
    var sessionRevision = 1
    var pending: [Int: CheckedContinuation<[MoodleCourseSection], Error>] = [:]
    var courses: [Int] = []
    func fetchCourseContents(courseId: Int) async throws -> [MoodleCourseSection] {
        let index = courses.count
        courses.append(courseId)
        // Deliberately ignore cancellation to exercise stale response protection.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func complete(_ index: Int, _ contents: [MoodleCourseSection]) {
        pending.removeValue(forKey: index)!.resume(returning: contents)
    }
    func fail(_ index: Int, _ error: Error) {
        pending.removeValue(forKey: index)!.resume(throwing: error)
    }
    func wait(_ index: Int) async {
        for _ in 0..<100_000 {
            if pending[index] != nil { return }
            await Task.yield()
        }
        preconditionFailure("Request did not start")
    }
}

@main struct Checks {
    @MainActor static func main() async throws {
        let kinds = MoodleQuestionActivityKind.allCases
        let activities = try kinds.enumerated().map { try module($0.offset + 1, $0.element.rawValue) }
        let contents = [
            section(1, activities + [try module(20, "forum"), try module(21, "assign"),
                                      try module(22, "resource"), try module(23, "label"),
                                      try module(24, "quiz", extra: ["visible": 0])]),
            section(2, [try module(1), try module(30, "quiz", extra: ["uservisible": false])]),
            section(3, [try module(40)], visible: 0)
        ]
        let filtered = MoodleQuestionSection.sections(from: contents)
        precondition(filtered.map(\.id) == [1, 2])
        precondition(filtered[0].modules.map(\.id) == [1, 2, 3, 4, 5, 6])
        precondition(filtered[1].modules.map(\.id) == [30], "Locked activities retained; duplicate removed")
        precondition(filtered[1].modules[0].questionActivityURL == nil)
        for (index, activity) in activities.enumerated() {
            precondition(activity.questionActivityURL?.absoluteString ==
                "https://euni.niu.edu.tw/mod/\(kinds[index].rawValue)/view.php?id=\(index + 1)",
                "Missing URL uses course-module ID, never instance")
        }
        check(try module(44, "QUIZ").questionActivityKind == .quiz)
        check(try module(45, extra: ["url": "javascript:alert(1)"]).questionActivityURL?.scheme == "https")
        check(try module(46, extra: ["availabilityinfo": "<p>尚未開放</p>"]).questionActivityURL == nil)
        check(try module(47, extra: ["availabilityinfo": "限制說明", "uservisible": true]).questionActivityURL != nil)
        check(try module(48, extra: ["visible": 0]).questionActivityURL == nil)
        check(try module(0).questionActivityURL == nil)
        check(try module(49, "unknown").questionActivityURL == nil)
        precondition(MoodleQuestionActivityKind.matches(URL(string: "https://euni.niu.edu.tw/mod/quiz/view.php?id=1")!))
        precondition(!MoodleQuestionActivityKind.matches(URL(string: "https://euni.niu.edu.tw.evil.test/mod/quiz/view.php")!))
        precondition(!MoodleQuestionActivityKind.matches(URL(string: "https://euni.niu.edu.tw:444/mod/quiz/view.php")!))
        print("PASS: activity types, hidden/locked activities, stable IDs and canonical URLs")

        let client = Client()
        let repository = MoodleQuestionsRepository(client: client)
        let model = MoodleQuestionsViewModel(repository: repository)
        let first = Task { await model.load(courseId: 10) }
        await client.wait(0)
        client.complete(0, contents)
        await first.value
        precondition(model.sections.count == 2 && !model.isLoading && model.errorMessage == nil)
        await model.load(courseId: 10)
        precondition(client.courses.count == 1, "Same course uses valid in-memory data")

        let offline = Task { await model.load(courseId: 10, force: true) }
        await client.wait(1)
        client.fail(1, URLError(.notConnectedToInternet))
        await offline.value
        precondition(model.sections.count == 2 && model.errorMessage?.contains("網路") == true)
        let timeout = Task { await model.load(courseId: 10, force: true) }
        await client.wait(2)
        client.fail(2, URLError(.timedOut))
        await timeout.value
        precondition(model.errorMessage?.contains("逾時") == true)

        let old = Task { await model.load(courseId: 10, force: true) }
        await client.wait(3)
        let new = Task { await model.load(courseId: 10, force: true) }
        await client.wait(4)
        client.complete(4, [section(4, [try module(51)])])
        await new.value
        client.complete(3, contents)
        await old.value
        precondition(model.sections[0].modules[0].id == 51 && !model.isLoading,
                     "A late response cannot overwrite a newer refresh")

        let cancelled = Task { await model.load(courseId: 10, force: true) }
        await client.wait(5)
        model.cancel()
        client.complete(5, [])
        await cancelled.value
        precondition(model.sections.count == 1 && model.errorMessage == nil && !model.isLoading)
        let parentCancelled = Task { await model.load(courseId: 10, force: true) }
        await client.wait(6)
        parentCancelled.cancel()
        client.complete(6, [])
        await parentCancelled.value
        precondition(model.sections.count == 1 && model.errorMessage == nil && !model.isLoading)
        print("PASS: offline cache, timeout, refresh race, screen and parent task cancellation")

        let switchCourse = Task { await model.load(courseId: 11) }
        await client.wait(7)
        precondition(model.sections.isEmpty, "Course switch immediately clears prior course")
        client.complete(7, [])
        await switchCourse.value
        await model.load(courseId: 11)
        precondition(client.courses.count == 8, "Empty success is cached")

        let beforeLogout = Task { await model.load(courseId: 11, force: true) }
        await client.wait(8)
        client.sessionRevision += 1
        client.complete(8, contents)
        await beforeLogout.value
        precondition(model.sections.isEmpty && model.errorMessage == nil && !model.isLoading,
                     "Logout invalidates requests without publishing personal data")
        let newSession = Task { await model.load(courseId: 11) }
        await client.wait(9)
        client.complete(9, contents)
        await newSession.value
        client.sessionRevision += 1
        let accountSwitch = Task { await model.load(courseId: 11) }
        await client.wait(10)
        precondition(model.sections.isEmpty, "New account cannot see prior cached sections")
        client.fail(10, URLError(.cancelled))
        await accountSwitch.value
        precondition(model.errorMessage == nil && !model.isLoading)
        print("PASS: course switching, empty state, logout and account switching")
        checkWebLogin()
        checkRepeatedOpen()
    }
}
'''

WEB_FIXTURE = r'''
func check(_ value: Bool) { precondition(value) }
@MainActor final class WKWebView {
    var url: URL?
    var navigationDelegate: AnyObject?
    var uiDelegate: AnyObject?
    var requests: [URLRequest] = []
    func load(_ request: URLRequest) { requests.append(request); url = request.url }
    func stopLoading() {}
}
final class WKNavigation {}
@MainActor final class SSOEUNISettings {
    static let shared = SSOEUNISettings()
    func clear() {}
}
@MainActor final class WebFixture {
    enum Phase { case idle, resolvingEuni, ssoRedirect, loadingTarget, done }
    struct Outcome { var isTerminal = false }
    var phase: Phase = .ssoRedirect
    var hasStarted = true
    var storedWebView: WKWebView?
    var isAttendanceQRTarget = false
    var attendanceOutcome: Outcome?
    var isQuestionActivityTarget = true
    var isAssignmentUploadTarget = false
    var isAutologinSupported = true
    var isPageReady = false
    var errorMessage: String?
    var targetLoads = 0
    var attemptedQuestionLogin = false
    var questionNeedsWebInteraction = false
    var questionTimeoutTask: Task<Void, Never>?
    var questionRecoveries = 0
    func recoverQuestionLogin() {
        attemptedQuestionLogin = true
        questionRecoveries += 1
        showQuestionLogin()
    }
    func showQuestionLogin() { questionNeedsWebInteraction = true; isPageReady = true }
    func isLoginPage(_ value: String) -> Bool { value.contains("/login/") }
    func isSSODefaultPage(_ value: String) -> Bool { value.contains("Default.aspx") }
    func handleAttendanceLoginPage(_ web: WKWebView) { fatalError("Unrelated attendance path") }
    func extractEUNIRedirectPath(from web: WKWebView) { fatalError("Unrelated SSO extraction") }
    func fallbackToTargetAfterSSOFailure() { fatalError("Unexpected fallback") }
    func attemptSilentRefreshAndRetry(_ reason: String) { fatalError("Login must remain visible") }
    func resolveEuniInSameWebViewForUpload(reason: String) { fatalError("Unrelated upload path") }
    func finishLoading() { phase = .done; isPageReady = true }
    func inspectAttendancePage(_ web: WKWebView) { fatalError("Unrelated attendance path") }
    func failAsNeedsRelogin() { fatalError("Login must remain visible") }
    func retryUsingAutologin() { fatalError("Login must not loop") }
    func loadCurrentTarget() { targetLoads += 1 }
    // PRODUCTION_DID_FINISH
}
@MainActor func checkWebLogin() {
    for initialPhase in [WebFixture.Phase.ssoRedirect, .resolvingEuni, .loadingTarget, .done] {
        let manager = WebFixture()
        let web = WKWebView()
        manager.storedWebView = web
        manager.phase = initialPhase
        web.url = URL(string: "https://euni.niu.edu.tw/login/index.php")
        manager.webView(web, didFinish: nil)
        precondition(manager.isPageReady && manager.targetLoads == 0)
        manager.webView(web, didFinish: nil)
        precondition(manager.questionRecoveries == 1 && manager.questionNeedsWebInteraction,
                     "Retry login once, then expose required school interaction")
        web.url = URL(string: "https://euni.niu.edu.tw/")
        manager.webView(web, didFinish: nil)
        let needsInitialTarget = initialPhase == .ssoRedirect || initialPhase == .resolvingEuni
        precondition(manager.targetLoads == (needsInitialTarget ? 1 : 0),
                     "Only initial SSO login should reopen the selected activity")
        web.url = URL(string: "https://euni.niu.edu.tw/mod/quiz/view.php?id=1")
        manager.webView(web, didFinish: nil)
        precondition(manager.isPageReady && manager.phase == .done)
        let loads = manager.targetLoads
        web.url = URL(string: "https://euni.niu.edu.tw/mod/quiz/summary.php?attempt=1")
        manager.webView(web, didFinish: nil)
        precondition(manager.targetLoads == loads, "Never replay the target during an attempt")
    }
    print("PASS: visible manual login, initial SSO return target and no attempt replay")
}
'''
web_source = (ROOT / "Features/Moodle/Views/MoodleWebView.swift").read_text()
start = web_source.index("    func webView(_ wv: WKWebView, didFinish navigation:")
end = web_source.index("    func webView(_ wv: WKWebView, didFail navigation:", start)
CHECKS += WEB_FIXTURE.replace("    // PRODUCTION_DID_FINISH", web_source[start:end])

STARTUP = r'''
@MainActor final class DialogFixture { func cancel() {} }
@MainActor final class StartupFixture {
    enum Phase { case idle, loadingTarget }
    var phase: Phase = .idle
    var storedWebView: WKWebView? = WKWebView()
    var webView: WKWebView { storedWebView! }
    var hasStarted = false
    var isPageReady = false
    var targetURL: String?
    var originalTargetURL: String?
    var externalOpenURL: URL?
    var errorMessage: String?
    var attendanceOutcome: String?
    var questionNeedsWebInteraction = false
    var attemptedQuestionLogin = false
    var questionUIDelegate = DialogFixture()
    var loadingTask: Task<Void, Never>?
    var questionTimeoutTask: Task<Void, Never>?
    var loadGeneration = 0
    var attendanceNavigationGeneration = 0
    var assignmentResolveAttempts = 0
    var attendanceLoginAttempts = 0
    var retriedAfterLoginRedirect = false
    var hasTriedSilentRefresh = false
    var webContentRecoveryAttempts = 0
    var resolutions = 0
    var timeoutStarts = 0
    func startQuestionTimeout() { timeoutStarts += 1 }
    func resolveTargetURL(from raw: String) async -> URL { resolutions += 1; return URL(string: raw)! }
    func targetURLReady(_ url: URL) { webView.load(URLRequest(url: url)) }
    // PRODUCTION_STARTUP
}
@MainActor func checkRepeatedOpen() {
    for kind in MoodleQuestionActivityKind.allCases {
        let manager = StartupFixture()
        let target = "https://euni.niu.edu.tw/mod/\(kind.rawValue)/view.php?id=10"
        manager.loadWithSSO(targetURL: target)
        precondition(manager.webView.requests.count == 1 && manager.webView.url?.absoluteString == target)
        manager.loadWithSSO(targetURL: target)
        precondition(manager.webView.requests.count == 1, "Repeated appearance cannot duplicate the request")
        manager.cancel()
        precondition(manager.webView.navigationDelegate == nil && manager.webView.uiDelegate == nil)
        manager.loadWithSSO(targetURL: target)
        precondition(manager.webView.requests.count == 2 && manager.webView.url?.absoluteString == target)
        precondition(manager.webView.navigationDelegate === manager && manager.webView.uiDelegate != nil)
        precondition(manager.resolutions == 0 && manager.timeoutStarts == 2,
                     "Each opening reuses cookies directly, never eagerly requesting another one-time key")
        manager.cancel()
    }
    print("PASS: first/second opening for every activity, reusable cookie entry, delegate reattachment and bounded loads")
}
'''

def method(marker):
    start = web_source.index(marker)
    brace = web_source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (web_source[end] == "{") - (web_source[end] == "}")
        end += 1
    return web_source[start:end]

startup_methods = "\n".join(method(marker) for marker in [
    "    func loadWithSSO(targetURL:", "    func cancel()",
    "    private var isQuestionActivityTarget:",
])
CHECKS += STARTUP.replace("    // PRODUCTION_STARTUP", startup_methods)
with tempfile.TemporaryDirectory(prefix="niu-moodle-questions-") as directory:
    folder = Path(directory)
    harness = folder / "Checks.swift"
    harness.write_text(CHECKS)
    executable = folder / "checks"
    sources = [
        "Features/Moodle/Models/MoodleModels.swift",
        "Features/Moodle/Questions/MoodleQuestionActivity.swift",
        "Features/Moodle/Questions/MoodleQuestionsRepository.swift",
        "Features/Moodle/Questions/MoodleQuestionsViewModel.swift",
    ]
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
        "-default-isolation", "MainActor",
        "-module-cache-path", str(folder / "modules"),
        *[str(ROOT / source) for source in sources],
        str(harness), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
