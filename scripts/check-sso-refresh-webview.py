#!/usr/bin/env python3
"""Run production Root/SSO refresh UI against an in-memory school page.

Usage: python3 scripts/check-sso-refresh-webview.py --device <booted simulator UDID>
Uses a separate app, nonpersistent WebKit, synthetic credentials and token stubs.
"""
import argparse
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
bundle = "dev.chien.niuapp.sso-refresh-checks"
service = (root / "Core/Services/SSOSessionService.swift").read_text()
service = service.replace("static let shared = SSOSessionService()", """
static let shared = SSOSessionService(backgroundTimeout: .seconds(3), refreshTimeout: .seconds(18))
""", 1)
screen = (root / "App/RootView.swift").read_text().split("#Preview")[0]
web = (root / "Features/Authentication/Services/SSOLoginWebView.swift").read_text()


def method_bounds(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return start, end


start, end = method_bounds(web, "private func fetchAuthorizationInfo(token:")
web = web[:start] + """private func fetchAuthorizationInfo(token: String) async -> StudentInfo? {
    await Fixture.authorizationInfo()
}""" + web[end:]
web = web.replace("https://ccsys1.niu.edu.tw", "fixture://ccsys1.niu.edu.tw")
web = web.replace("https://ccsys.niu.edu.tw", "fixture://ccsys.niu.edu.tw")
web = web.replace("config.websiteDataStore = .default()", """
config.websiteDataStore = .nonPersistent()
config.setURLSchemeHandler(FixturePortal(), forURLScheme: "fixture")
""")
web = web.replace("let webView = WKWebView(frame:", "let webView = FixtureBrowser(frame:")
# The isolated browser uses an in-memory scheme. Adapt only its scheme check;
# retain the production hostname/path guards and leave the app source untouched.
protocol_guard = "location.protocol !== 'https:'"
assert web.count(protocol_guard) == 1
web = web.replace(protocol_guard, "location.protocol !== 'fixture:'")
source = r'''
import SwiftUI
import WebKit
import UIKit
import Combine

@MainActor enum Fixture {
    enum Mode { case hold, challenge, rejection }
    static var mode = Mode.hold
    static weak var latestBrowser: FixtureBrowser?
    static weak var mainButton: UIButton?
    static weak var appState: AppState?
    static var createdBrowsers = 0
    static var tokenWrites = 0
    static var profileWrites = 0
    static var authorizationCalls = 0
    static var holdAuthorization = false
    static var rejectAuthorization = false
    static var holdFormEvaluation = false
    static var authorizationGate: CheckedContinuation<StudentInfo?, Never>?
    static var phase = "launch"
    static var info: StudentInfo { StudentInfo(name: "Synthetic Student", department: "Fixture", grade: "3") }
    static func authorizationInfo() async -> StudentInfo? {
        authorizationCalls += 1
        if holdAuthorization {
            return await withCheckedContinuation { authorizationGate = $0 }
        }
        return rejectAuthorization ? nil : info
    }
}
@MainActor final class LoginRepository {
    static let shared = LoginRepository()
    func getSavedCredentials() -> (username: String, password: String)? {
        ("synthetic", "fixture-password")
    }
}
@MainActor final class SSOTokenStore {
    static let shared = SSOTokenStore()
    var isLikelyValid = false
    func save(token: String, exp: String?, account: String) { Fixture.tokenWrites += 1 }
}
@MainActor final class MoodleSessionManager {
    static let shared = MoodleSessionManager()
    private(set) var refreshCount = 0
    func fetchEUNILink() { refreshCount += 1 }
}
@MainActor final class SSOCaptchaProcessor {
    static let shared = SSOCaptchaProcessor()
    func recognize(from: UIImage, completion: @escaping (String?) -> Void) {
        fatalError("Real CAPTCHA must not run")
    }
}
extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
@MainActor public final class AppState: ObservableObject {
    @Published var isAuthenticated = true
    @Published var isLoggingOut = false
    init() { Fixture.appState = self }
    func updateProfileFromSSO(_ info: StudentInfo) { Fixture.profileWrites += 1 }
    func applicationDidBecomeActive() async {}
    func applicationDidEnterBackground() {}
}
struct HomeView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("Underlying app", for: .normal)
        Fixture.mainButton = button
        return button
    }
    func updateUIView(_ view: UIButton, context: Context) {}
}
struct LoginView: View { var body: some View { Text("Signed out") } }
@MainActor final class FixtureBrowser: WKWebView {
    var heldForm: (script: String, completion: (@MainActor @Sendable (Any?, Error?) -> Void)?)?
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        Fixture.createdBrowsers += 1
        Fixture.latestBrowser = self
    }
    required init?(coder: NSCoder) { fatalError("No coder") }
    @discardableResult override func load(_ request: URLRequest) -> WKNavigation? {
        precondition(request.url?.scheme == "fixture", "School network is forbidden")
        return super.load(request)
    }
    override func evaluateJavaScript(_ script: String, completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil) {
        if Fixture.holdFormEvaluation && script.contains("const [account, password]") {
            heldForm = (script, completionHandler)
            return
        }
        super.evaluateJavaScript(script, completionHandler: completionHandler)
    }
    func releaseFormEvaluation() {
        guard let held = heldForm else { return }
        heldForm = nil
        Fixture.holdFormEvaluation = false
        super.evaluateJavaScript(held.script, completionHandler: held.completion)
    }
}
@MainActor final class FixturePortal: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url!
        precondition(url.scheme == "fixture" && url.host == "ccsys1.niu.edu.tw" && url.path == "/SSO/login")
        let mode = Fixture.mode == .rejection ? "rejection" : "hold"
        let disabled = Fixture.mode == .challenge ? "disabled" : ""
        let html = """
        <html><meta name="viewport" content="width=device-width"><body>
        <form class="login-form">
        <input id="username"><input id="password" type="password">
        <button type="submit" \(disabled)>Sign in</button></form>
        <div id="failure"></div><script>
        window.fixtureSubmits = 0; window.allowLoginSuccess = false;
        window.finishFixtureLogin = () => sessionStorage.setItem('niu_sso_token', 'synthetic-session-' + Date.now());
        document.querySelector('form').addEventListener('submit', event => {
            event.preventDefault(); window.fixtureSubmits++;
            if (window.allowLoginSuccess) window.finishFixtureLogin();
            else if ('\(mode)' === 'rejection')
                document.getElementById('failure').innerHTML = '<div class="alert-danger">帳號或密碼不正確</div>';
        });
        </script></body></html>
        """
        let data = Data(html.utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
struct CheckFailure: Error { let reason: String }
@main struct ChecksApp: App {
    var body: some Scene { WindowGroup { RootView().task { await runChecks() } } }
    @MainActor func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw CheckFailure(reason: "\(Fixture.phase): \(reason)") }
    }
    @MainActor func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(7)
        while !condition() {
            if ContinuousClock.now > deadline { throw CheckFailure(reason: "\(Fixture.phase): timeout") }
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(80))
    }
    @MainActor func pageReady() async throws -> FixtureBrowser {
        try await waitFor { Fixture.latestBrowser != nil }
        let browser = Fixture.latestBrowser!
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if (try? await browser.evaluateJavaScript("typeof finishFixtureLogin === 'function'")) as? Bool == true {
                return browser
            }
            try await Task.sleep(for: .milliseconds(60))
        }
        throw CheckFailure(reason: "\(Fixture.phase): HTML did not load")
    }
    @MainActor func underlyingAppReceivesTouches() -> Bool {
        guard let button = Fixture.mainButton, let window = button.window else { return false }
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
        guard let hit = window.hitTest(point, with: nil) else { return false }
        return hit === button || hit.isDescendant(of: button)
    }
    @MainActor func reset() async throws {
        SSOSessionService.shared.disableAutoRefresh()
        try await Task.sleep(for: .milliseconds(120))
        SSOSessionService.shared.enableAutoRefresh()
        Fixture.latestBrowser = nil
    }
    @MainActor func runChecks() async {
        let service = SSOSessionService.shared
        var result: [String: String]
        do {
            try await waitFor { UIApplication.shared.applicationState == .active && Fixture.mainButton?.window != nil }
            Fixture.phase = "silent login"
            let silent = Task { await service.requestRefresh(force: true) }
            let browser = try await pageReady()
            try require(service.isRefreshing && !service.showRefreshWebView && underlyingAppReceivesTouches(),
                        "Hidden refresh blocked the app")
            _ = try await browser.evaluateJavaScript("finishFixtureLogin()")
            let silentResult = await silent.value
            try require(silentResult && Fixture.tokenWrites == 1 && Fixture.profileWrites == 1,
                        "Background login did not finish")
            try require(MoodleSessionManager.shared.refreshCount == 1,
                        "Successful SSO refresh must request the EUNI entry once")
            try await reset()

            Fixture.phase = "challenge fallback"
            Fixture.mode = .challenge
            let challenging = Task { await service.requestRefresh() }
            let challengedBrowser = try await pageReady()
            let created = Fixture.createdBrowsers
            try require(!service.showRefreshWebView && underlyingAppReceivesTouches(), "Challenge covered the app immediately")
            try await waitFor { service.showRefreshWebView }
            try require(Fixture.createdBrowsers == created && Fixture.latestBrowser === challengedBrowser,
                        "Revealing the challenge replaced its WebView")
            try require(!underlyingAppReceivesTouches(), "Visible login allowed touches through to the app")
            _ = try await challengedBrowser.evaluateJavaScript("""
                document.getElementById('password').value = 'manual-correction';
                document.querySelector('button').disabled = false;
                """)
            try await Task.sleep(for: .milliseconds(650))
            let submits = try await challengedBrowser.evaluateJavaScript("window.fixtureSubmits") as? Int
            let password = try await challengedBrowser.evaluateJavaScript("document.getElementById('password').value") as? String
            try require(submits == 0 && password == "manual-correction",
                        "Manual mode resubmitted or overwrote user edits")
            _ = try await challengedBrowser.evaluateJavaScript("window.allowLoginSuccess = true; document.querySelector('button').click()")
            let manualResult = await challenging.value
            try require(manualResult && !service.isRefreshing && !service.showRefreshWebView, "Manual success did not resume the query")
            try await reset()

            Fixture.phase = "queued automatic script handoff"
            Fixture.mode = .hold
            Fixture.holdFormEvaluation = true
            let queued = Task { await service.requestRefresh() }
            let queuedBrowser = try await pageReady()
            try await waitFor { queuedBrowser.heldForm != nil }
            service.requireInteraction(requestID: service.refreshID)
            try await Task.sleep(for: .milliseconds(180))
            try require(service.showRefreshWebView && !service.isRefreshPageReadyForInteraction,
                        "Manual interaction opened before queued automatic JavaScript completed")
            queuedBrowser.releaseFormEvaluation()
            try await waitFor { service.isRefreshPageReadyForInteraction }
            _ = try await queuedBrowser.evaluateJavaScript("document.getElementById('password').value = 'user-edit-after-handoff'")
            try await Task.sleep(for: .milliseconds(650))
            let handedOffPassword = try await queuedBrowser.evaluateJavaScript("document.getElementById('password').value") as? String
            let queuedSubmits = try await queuedBrowser.evaluateJavaScript("window.fixtureSubmits") as? Int
            try require(handedOffPassword == "user-edit-after-handoff" && queuedSubmits == 1,
                        "Automatic handoff changed manual form: preserved=\(handedOffPassword == "user-edit-after-handoff"), submits=\(String(describing: queuedSubmits))")
            _ = try await queuedBrowser.evaluateJavaScript("finishFixtureLogin()")
            let queuedResult = await queued.value
            try require(queuedResult, "Queued-script handoff prevented manual recovery")
            try await reset()

            Fixture.phase = "rejection recovery"
            Fixture.mode = .rejection
            let rejected = Task { await service.requestRefresh() }
            let rejectedBrowser = try await pageReady()
            let rejectedCreated = Fixture.createdBrowsers
            try await waitFor { service.showRefreshWebView && service.lastFailureMessage != nil }
            try require(service.isRefreshing && Fixture.createdBrowsers == rejectedCreated,
                        "Failed automatic login closed or reloaded the page")
            service.retryInteractiveLogin()
            try await waitFor { Fixture.createdBrowsers > rejectedCreated }
            let reloadedBrowser = try await pageReady()
            try await waitFor { service.isRefreshPageReadyForInteraction }
            let reloadSubmits = try await reloadedBrowser.evaluateJavaScript("window.fixtureSubmits") as? Int
            try require(reloadedBrowser !== rejectedBrowser && reloadSubmits == 0,
                        "Explicit reload must create a manual page without submitting")
            _ = try await reloadedBrowser.evaluateJavaScript("window.allowLoginSuccess = true; document.querySelector('button').click()")
            let rejectionResult = await rejected.value
            try require(rejectionResult, "A manual login after automatic rejection was not observed")
            try await reset()

            Fixture.phase = "rejected token recovery"
            Fixture.mode = .hold
            Fixture.rejectAuthorization = true
            let badToken = Task { await service.requestRefresh() }
            let badTokenBrowser = try await pageReady()
            _ = try await badTokenBrowser.evaluateJavaScript("finishFixtureLogin()")
            try await waitFor { service.showRefreshWebView && service.lastFailureMessage != nil }
            let authorizationCalls = Fixture.authorizationCalls
            try await Task.sleep(for: .milliseconds(650))
            try require(Fixture.authorizationCalls == authorizationCalls,
                        "The rejected token triggered repeated authorization requests")
            Fixture.rejectAuthorization = false
            _ = try await badTokenBrowser.evaluateJavaScript("finishFixtureLogin()")
            let tokenRecovered = await badToken.value
            try require(tokenRecovered, "A new token could not recover rejected authorization")
            try await reset()

            Fixture.phase = "authorization cancellation"
            Fixture.mode = .hold
            Fixture.holdAuthorization = true
            let pending = Task { await service.requestRefresh() }
            let pendingBrowser = try await pageReady()
            let writesBeforeCancel = Fixture.tokenWrites
            _ = try await pendingBrowser.evaluateJavaScript("finishFixtureLogin()")
            try await waitFor { Fixture.authorizationGate != nil }
            service.cancelRefresh()
            // Complete before SwiftUI gets a chance to dismantle the old WebView.
            Fixture.authorizationGate?.resume(returning: Fixture.info)
            Fixture.authorizationGate = nil
            let cancelled = await pending.value
            try await waitFor { pendingBrowser.navigationDelegate == nil }
            Fixture.holdAuthorization = false
            try await Task.sleep(for: .milliseconds(200))
            try require(!cancelled && Fixture.tokenWrites == writesBeforeCancel,
                        "Cancelled authorization saved an old token")
            try await reset()

            Fixture.phase = "logout cleanup"
            let logout = Task { await service.requestRefresh() }
            let logoutBrowser = try await pageReady()
            service.disableAutoRefresh()
            Fixture.appState?.isAuthenticated = false
            let logoutResult = await logout.value
            try await waitFor { logoutBrowser.navigationDelegate == nil }
            try require(!logoutResult && !service.isRefreshing && !service.showRefreshWebView && service.refreshPassword.isEmpty,
                        "Logout left a refresh page or credentials active")
            result = ["status": "passed", "checks":
                "background touch availability, silent success, same-WebView challenge reveal, queued-script handoff, manual edits/no auto-submit, rejection/reload recovery, rejected-token recovery, cancellation before dismantle, logout cleanup"]
        } catch {
            service.disableAutoRefresh()
            result = ["status": "failed", "reason": String(describing: error)]
        }
        do {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.json")
            try JSONSerialization.data(withJSONObject: result).write(to: url, options: .atomic)
        } catch { print("Unable to write SSO fixture result") }
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-sso-refresh-webview-") as directory:
    folder = Path(directory)
    app = folder / "SSORefreshChecks.app"
    app.mkdir()
    files = []
    for name, contents in [("SSOSessionService.swift", service), ("RootView.swift", screen),
                           ("SSOLoginWebView.swift", web), ("Checks.swift", source)]:
        path = folder / name
        path.write_text(contents)
        files.append(path)
    files += [root / "NIU-LiveActivities/CampusNavigation.swift", root / "Shared/Theme/Theme.swift"]
    (app / "Info.plist").write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier=bundle, CFBundleName="SSORefreshChecks", CFBundleExecutable="SSORefreshChecks",
        CFBundlePackageType="APPL", CFBundleVersion="1", CFBundleShortVersionString="1.0",
        MinimumOSVersion="26.0", LSRequiresIPhoneOS=True, UIDeviceFamily=[1, 2], UILaunchScreen={})))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-sdk", sdk,
                    "-target", "arm64-apple-ios26.0-simulator", "-parse-as-library",
                    "-module-cache-path", str(folder / "ModuleCache"), *map(str, files),
                    "-o", str(app / "SSORefreshChecks")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["xcrun", "simctl", "install", args.device, str(app)], check=True)
    container = Path(subprocess.check_output([
        "xcrun", "simctl", "get_app_container", args.device, bundle, "data"], text=True).strip())
    output = container / "Documents/result.json"
    output.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "launch", args.device, bundle], check=True)
    try:
        deadline = time.monotonic() + 55
        while not output.exists() and time.monotonic() < deadline:
            time.sleep(0.25)
        if not output.exists():
            raise RuntimeError("No SSO simulator result within 55 seconds")
        result = json.loads(output.read_text())
        if result["status"] != "passed":
            raise RuntimeError(result)
        print("PASS: " + result["checks"])
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", args.device, bundle],
                       check=False, capture_output=True)
