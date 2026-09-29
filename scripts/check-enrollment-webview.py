#!/usr/bin/env python3
"""Run real SwiftUI/WKWebView lifecycle checks in an explicitly selected simulator.

Uses a separate app, synthetic HTML and SSO stubs. No school requests or Keychain.
Usage: python3 scripts/check-enrollment-webview.py --device <booted simulator UDID>
"""
import argparse
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
bundle = 'dev.chien.niuapp.enrollment-lifecycle-checks'
source = r'''
import SwiftUI
import WebKit

@MainActor enum Theme { enum Spacing { static let medium: CGFloat = 12 } }
@MainActor enum StorageKeys { static let authSessionID = "isolated-ui-test" }
@MainActor enum SSOGUIDBridge {
    static var requests = 0
    static func requestGUID(account: String) async throws -> String {
        requests += 1
        try await Task.sleep(for: .milliseconds(100))
        return "synthetic-guid"
    }
    static func acadeLoginURL(guid: String) -> URL? { URL(string: "fixture://acade.niu.edu.tw/NIU/Login.aspx?GUID=synthetic") }
    static func isSessionExpiredURL(_ url: URL) -> Bool {
        url.path.lowercased().hasSuffix("/default.aspx") || url.path.lowercased() == "/sso/login"
    }
}
@MainActor final class SSOSessionService {
    static let shared = SSOSessionService()
    func requestRefresh(force: Bool) async -> Bool { fatalError("Live SSO forbidden in fixture") }
}
struct User { let username: String }
@MainActor final class AppState: ObservableObject {
    @Published var currentUser: User? = User(username: "T0000001")
    @Published var isAuthenticated = true
}

// All fixture URLs use a private URL scheme served in memory. Real WKWebView
// performs the iframe loads/redirects; no request can reach a school server.
@MainActor final class FixtureBrowser: WKWebView {
    private(set) var stopCount = 0
    override func stopLoading() { stopCount += 1; super.stopLoading() }
}
@MainActor final class FixturePortal: NSObject, WKURLSchemeHandler {
    static var expireNext = false
    static var expireRegistrationNext = false
    static var crossOriginExpiryNext = false
    static var staleDocumentNext = false
    private var expired: Bool
    private var registrationExpired: Bool
    private var crossOriginExpiry: Bool
    private let staleDocument: Bool
    init(expired: Bool, registrationExpired: Bool, crossOriginExpiry: Bool, staleDocument: Bool) {
        self.expired = expired
        self.registrationExpired = registrationExpired
        self.crossOriginExpiry = crossOriginExpiry
        self.staleDocument = staleDocument
    }
    static func service() -> EnrollmentRegistrationService {
        let handler = FixturePortal(expired: expireNext, registrationExpired: expireRegistrationNext,
                                    crossOriginExpiry: crossOriginExpiryNext, staleDocument: staleDocumentNext)
        expireNext = false; expireRegistrationNext = false; crossOriginExpiryNext = false; staleDocumentNext = false
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: "fixture")
        let web = FixtureBrowser(frame: CGRect(x: 0, y: 0, width: 360, height: 640), configuration: config)
        return EnrollmentRegistrationService(webView: web,
            mainFrameURL: URL(string: "fixture://acade.niu.edu.tw/NIU/MainFrame.aspx"),
            allowsNavigation: { ($0.scheme == "fixture" && $0.host == "acade.niu.edu.tw") || $0.absoluteString == "about:blank" })
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        precondition(url.host == "acade.niu.edu.tw", "Cross-origin login should be intercepted, not loaded")
        let path = url.path.lowercased()
        let body: String
        switch path {
        case "/niu/mainframe.aspx" where expired:
            expired = false
            body = "<script>location.replace('/NIU/Default.aspx')</script>"
        case "/niu/login.aspx":
            body = "<script>location.replace('/NIU/MainFrame.aspx')</script>"
        case "/niu/mainframe.aspx": body = Self.portalHTML
        case "/niu/menu.aspx" where staleDocument:
            body = #"<a href="/NIU/Application/ENR/ENR50/ENR5020_.aspx?progcd=ENR5020" target="mainFrame" onclick="event.preventDefault();setTimeout(() => top.frames.mainFrame.location.href = this.href, 1200)">查詢註冊</a>"#
        case "/niu/menu.aspx":
            body = #"<a href="/NIU/Application/ENR/ENR50/ENR5020_.aspx?progcd=ENR5020" target="mainFrame">查詢註冊</a>"#
        case "/niu/blank.aspx" where staleDocument:
            body = #"<iframe name="oldRecord" src="Application/ENR/ENR50/ENR5020_01.aspx?old=1"></iframe>"#
        case "/niu/blank.aspx": body = "<p>首頁</p>"
        case "/niu/default.aspx": body = "<p>登入逾時</p>"
        case "/niu/application/enr/enr50/enr5020_.aspx" where crossOriginExpiry:
            crossOriginExpiry = false
            body = "<script>location.replace('fixture://ccsys1.niu.edu.tw/SSO/login')</script>"
        case "/niu/application/enr/enr50/enr5020_.aspx" where registrationExpired:
            registrationExpired = false
            body = "<script>location.replace('/NIU/Default.aspx')</script>"
        case "/niu/application/enr/enr50/enr5020_.aspx":
            body = #"<script>if (!top.frames.menuFrame) throw Error('Missing portal context')</script><iframe name="recordFrame" src="ENR5020_01.aspx"></iframe>"#
        case "/niu/application/enr/enr50/enr5020_01.aspx" where url.query == "old=1":
            body = Self.recordHTML.replacingOccurrences(of: "測試學生", with: "舊資料") + "<script>finishFixture()</script>"
        case "/niu/application/enr/enr50/enr5020_01.aspx": body = Self.recordHTML
        default:
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
        }
        let data = Data(("<!doctype html><meta charset=\"utf-8\">" + body).utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    static let portalHTML = #"""
    <iframe name="menuFrame" src="Menu.aspx"></iframe>
    <iframe name="mainFrame" src="Blank.aspx"></iframe>
    <iframe name="hiddenTimeout" src="Default.aspx" hidden></iframe>
    <iframe name="hiddenSSO" src="fixture://ccsys1.niu.edu.tw/SSO/login" hidden></iframe>
    <script>
    function finishRegistrationFixture() {
        if (!window.frames.menuFrame || !window.frames.mainFrame.frames.recordFrame) throw Error('Missing portal frame context');
        window.frames.mainFrame.frames.recordFrame.finishFixture();
        return true;
    }
    </script>
    """#
    static let recordHTML = #"""
    <body><p>載入中</p><script>
    function finishFixture() {
        document.body.innerHTML = '<table id="DataGrid"><tr><th>註冊學年期</th><th>學號</th><th>姓名</th><th>系所</th><th>年級</th><th>在學狀態</th><th>註冊狀態</th><th>註冊日期</th></tr><tr><td>1151</td><td>T0000001</td><td>測試學生</td><td>測試學系</td><td>3</td><td>在學</td><td>已註冊</td><td>115/08/31</td></tr></table><button id="GoToPrint">列印在學證明</button>';
    }
    </script></body>
    """#
}

@main struct EnrollmentLifecycleChecks: App {
    @StateObject private var state = AppState()
    @StateObject private var model = EnrollmentCertificateViewModel(
        currentSession: { "synthetic-session" }, currentAccount: { "T0000001" },
        makeRegistrationService: { FixturePortal.service() },
        loadPDF: { _ in fatalError("No PDF request in fixture") })
    var body: some Scene {
        WindowGroup {
            NavigationStack { EnrollmentCertificateView(model: model) }
                .environmentObject(state)
                .task { await check() }
        }
    }
    @MainActor private func waitFor(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CheckFailure(reason: "Timed out waiting for lifecycle transition at Swift line \(line)")
    }
    struct CheckFailure: Error { let reason: String }
    @MainActor private func require(_ value: Bool, _ reason: String) throws {
        if !value { throw CheckFailure(reason: reason) }
    }
    @MainActor private func check() async {
        var result: [String: String]
        do {
            try await waitFor { model.registrationWebView?.window != nil }
            guard let first = model.registrationWebView else { throw CheckFailure(reason: "Missing WebView") }
            try require(first.bounds.width > 300 && first.bounds.height > 300, "WebView has no usable layout")
            try require(!first.isHidden && first.alpha == 1, "WebView must remain visible behind native List")
            // Exercise the actual automatic reveal without rebuilding the browser session.
            try await Task.sleep(for: .seconds(9))
            try require(model.registrationWebView === first && first.window != nil, "Revealing school page replaced the WebView")
            try require(first.url?.path.lowercased() == "/niu/mainframe.aspx", "Query replaced the MainFrame shell")
            try require(SSOGUIDBridge.requests == 0, "An existing acade session must not request a new GUID")
            _ = try await first.evaluateJavaScript("finishRegistrationFixture()")
            try await waitFor { model.snapshot != nil || !model.isLoading }
            try require(model.snapshot?.records.first?.studentID == "T0000001", "Actual WebKit parser did not return synthetic record")
            try require(model.snapshot?.canPrint == true && model.errorMessage == nil, "Registration result invalid")
            try await waitFor { first.window == nil }
            try require(model.registrationWebView == nil && first.navigationDelegate == nil, "Completed WebView still active")
            model.refresh()
            try await waitFor { model.registrationWebView?.window != nil }
            guard let second = model.registrationWebView else { throw CheckFailure(reason: "Missing second WebView") }
            model.refresh()
            try await waitFor { model.registrationWebView != nil && model.registrationWebView !== second && model.registrationWebView?.window != nil }
            try await waitFor { second.navigationDelegate == nil && second.window == nil }
            // WebKit may leave isLoading true after cancelling a custom-scheme
            // provisional load. Check the stop request and owner cleanup instead.
            try require((second as? FixtureBrowser)?.stopCount ?? 0 > 0, "Superseded browser was not stopped")
            guard let third = model.registrationWebView else { throw CheckFailure(reason: "Missing third WebView") }
            model.cancel()
            try await waitFor { third.window == nil }
            try await Task.sleep(for: .milliseconds(300))
            try require(model.registrationWebView == nil && model.snapshot == nil && !model.isLoading, "Cancelled request restored state")
            try require(third.navigationDelegate == nil && ((third as? FixtureBrowser)?.stopCount ?? 0) > 0, "Cancelled browser was not stopped")
            FixturePortal.expireNext = true
            model.refresh()
            try await waitFor { SSOGUIDBridge.requests == 1 && model.registrationWebView?.url?.path.lowercased() == "/niu/mainframe.aspx" }
            guard let recovered = model.registrationWebView else { throw CheckFailure(reason: "Missing recovered browser") }
            try await Task.sleep(for: .seconds(1))
            _ = try await recovered.evaluateJavaScript("finishRegistrationFixture()")
            try await waitFor { model.snapshot != nil || !model.isLoading }
            try require(model.snapshot?.canPrint == true && SSOGUIDBridge.requests == 1, "Expired acade session should reuse SSO exactly once")
            FixturePortal.expireRegistrationNext = true
            model.refresh()
            try await waitFor { SSOGUIDBridge.requests == 2 && model.registrationWebView?.url?.path.lowercased() == "/niu/mainframe.aspx" }
            guard let recoveredFrame = model.registrationWebView else { throw CheckFailure(reason: "Missing recovered registration frame") }
            try await Task.sleep(for: .seconds(1))
            _ = try await recoveredFrame.evaluateJavaScript("finishRegistrationFixture()")
            try await waitFor { model.snapshot != nil || !model.isLoading }
            try require(model.snapshot?.canPrint == true && SSOGUIDBridge.requests == 2, "Only the active registration frame should trigger recovery")
            FixturePortal.crossOriginExpiryNext = true
            model.refresh()
            try await waitFor { SSOGUIDBridge.requests == 3 && model.registrationWebView?.url?.path.lowercased() == "/niu/mainframe.aspx" }
            guard let crossOriginRecovered = model.registrationWebView else { throw CheckFailure(reason: "Missing cross-origin recovery") }
            try await Task.sleep(for: .seconds(1))
            _ = try await crossOriginRecovered.evaluateJavaScript("finishRegistrationFixture()")
            try await waitFor { model.snapshot != nil || !model.isLoading }
            try require(model.snapshot?.canPrint == true && SSOGUIDBridge.requests == 3, "Cross-origin target expiry should recover exactly once")
            FixturePortal.staleDocumentNext = true
            model.refresh()
            try await waitFor { model.registrationWebView?.window != nil }
            try await Task.sleep(for: .seconds(1))
            try require(model.snapshot == nil && model.isLoading, "Old child document was accepted before target navigation committed")
            guard let fresh = model.registrationWebView else { throw CheckFailure(reason: "Missing fresh query") }
            try await Task.sleep(for: .seconds(1.5))
            _ = try await fresh.evaluateJavaScript("finishRegistrationFixture()")
            try await waitFor { model.snapshot != nil || !model.isLoading }
            try require(model.snapshot?.records.first?.name == "測試學生" && SSOGUIDBridge.requests == 3, "Fresh document must replace the previous record without re-login")
            result = ["status": "passed", "checks": "mounted WebView, retained MainFrame/menu context, real nested-frame parsing, shared-session reuse with no GUID, bounded expired-session bridge, cleanup, replacement, cancellation"]

        } catch {
            model.cancel()
            result = ["status": "failed", "reason": String(describing: error)]
        }
        do {
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.json")
            try JSONSerialization.data(withJSONObject: result).write(to: output, options: .atomic)
        } catch { print("Could not write fixture result") }
    }
}
'''

def run(*command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='niu-enrollment-lifecycle-') as temp:
    folder = Path(temp)
    app = folder / 'EnrollmentLifecycleChecks.app'
    app.mkdir()
    swift = folder / 'Checks.swift'
    swift.write_text(source)
    plist = dict(CFBundleIdentifier=bundle, CFBundleName='EnrollmentLifecycleChecks',
                 CFBundleExecutable='EnrollmentLifecycleChecks', CFBundlePackageType='APPL',
                 CFBundleVersion='1', CFBundleShortVersionString='1.0', MinimumOSVersion='26.0',
                 LSRequiresIPhoneOS=True, UIDeviceFamily=[1, 2], UILaunchScreen={})
    (app / 'Info.plist').write_bytes(plistlib.dumps(plist))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    files = sorted((root / 'Features/EnrollmentCertificate').rglob('*.swift'))
    run('xcrun', 'swiftc', '-swift-version', '5', '-sdk', sdk,
        '-target', 'arm64-apple-ios26.0-simulator', '-parse-as-library',
        '-module-cache-path', str(folder / 'ModuleCache'), *map(str, files), str(swift),
        '-o', str(app / 'EnrollmentLifecycleChecks'))
    run('codesign', '--force', '--sign', '-', str(app), stdout=subprocess.DEVNULL)
    # A unique test bundle cannot replace the user's app or share its WK data store.
    run('xcrun', 'simctl', 'install', args.device, str(app))
    container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.device, bundle, 'data'], text=True).strip())
    output = container / 'Documents/result.json'
    output.unlink(missing_ok=True)
    run('xcrun', 'simctl', 'launch', args.device, bundle)
    try:
        deadline = time.monotonic() + 55
        while not output.exists() and time.monotonic() < deadline:
            time.sleep(0.25)
        if not output.exists():
            raise RuntimeError('Simulator did not return a test result within 55 seconds')
        result = json.loads(output.read_text())
        if result['status'] != 'passed':
            diagnostic = Path('/private/tmp/niu-enrollment-webview-failure.swift')
            diagnostic.write_text(source)
            raise RuntimeError(result)
        print('PASS: ' + result['checks'])
    finally:
        subprocess.run(['xcrun', 'simctl', 'terminate', args.device, bundle], check=False, capture_output=True)
