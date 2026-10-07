#!/usr/bin/env python3
"""Compile and exercise the production ViewModel using isolated synthetic dependencies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
models = root / 'Features/EnrollmentCertificate/Models/EnrollmentCertificateModels.swift'
viewmodel = root / 'Features/EnrollmentCertificate/ViewModels/EnrollmentCertificateViewModel.swift'
stubs = r'''
import Foundation
import WebKit
// The production bridge is compiled for URL classification only; never load a real token.
enum SSOTokenStore {
    static let shared = SSOTokenStoreStub()
}
struct SSOTokenStoreStub {
    var token: String? { nil }
    func clear(ifMatching: String) { fatalError("No Keychain in fixture") }
}
extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
@MainActor enum StorageKeys { static let authSessionID = "test-only" }
@MainActor final class SSOSessionService {
    static let shared = SSOSessionService()
    func requestRefresh(force: Bool) async -> Bool { fatalError("Live SSO must not be used") }
}
@MainActor final class EnrollmentRegistrationService {
    var webView: WKWebView { fatalError("Live WebView must not be used") }
    var onProgress: ((EnrollmentLoadStage) -> Void)?
    func load(account: String) async throws -> EnrollmentSnapshot { fatalError("Live registration must not be used") }
    func cancel() {}
}
nonisolated struct EnrollmentPDFService {
    init(studentID: String) {}
    func load(cookies: [HTTPCookie]) async throws -> Data { fatalError("Live PDF must not be used") }
}
@MainActor final class Gate {
    var waiting: [CheckedContinuation<EnrollmentSnapshot, Error>] = []
    func load() async throws -> EnrollmentSnapshot {
        try await withCheckedThrowingContinuation { waiting.append($0) }
    }
}
@main struct Checks {
    @MainActor static func settle() async throws { try await Task.sleep(for: .milliseconds(40)) }
    @MainActor static func main() async throws {
        let record = EnrollmentRecord(semester: "1151", studentID: "T0000001", name: "測試學生", department: "測試學系", grade: "3", studentStatus: "在學", registrationStatus: "已註冊(繳費)", registrationDate: "115/08/31")
        let snapshot = EnrollmentSnapshot(records: [record], canPrint: true)
        precondition(record.semesterTitle == "115 學年度第 1 學期")
        for host in ["ccsys.niu.edu.tw", "ccsys1.niu.edu.tw"] {
            precondition(SSOGUIDBridge.isSessionExpiredURL(URL(string: "https://" + host + "/SSO/login")!))
        }
        for raw in ["https://acade.niu.edu.tw/NIU/logout.aspx", "https://ACADE.niu.edu.tw/NIU/Logout.aspx?GUID=synthetic"] {
            precondition(SSOGUIDBridge.isSessionExpiredURL(URL(string: raw)!))
        }
        for raw in ["https://example.com/NIU/logout.aspx", "https://ccsys.niu.edu.tw/NIU/logout.aspx", "https://euni.niu.edu.tw/login/logout.php", "https://acade.niu.edu.tw/other/logout.aspx", "https://acade.niu.edu.tw/NIU/Login.aspx?GUID=synthetic", "https://acade.niu.edu.tw/NIU/MainFrame.aspx", "https://ccsys.niu.edu.tw/SSO/Std002.aspx", "https://ccsys.niu.edu.tw/SSO/StdMain.aspx", "https://example.com/SSO/login"] {
            precondition(!SSOGUIDBridge.isSessionExpiredURL(URL(string: raw)!))
        }
        for path in ["/SSO/Std002.aspx", "/SSO/StdMain.aspx"] {
            let entry = URL(string: "https://ccsys.niu.edu.tw" + path)!
            precondition(EnrollmentEndpoint.isLegacyPortalLanding(entry))
            precondition(EnrollmentEndpoint.allowsRegistrationNavigation(entry), "Portal fallback must reach didFinish instead of timing out")
        }
        for raw in ["http://ccsys.niu.edu.tw/SSO/Std002.aspx", "https://example.com/SSO/StdMain.aspx", "https://ccsys.niu.edu.tw/unexpected"] {
            precondition(!EnrollmentEndpoint.allowsRegistrationNavigation(URL(string: raw)!))
        }
        precondition(EnrollmentEndpoint.certificate(studentID: "../other") == nil)
        let pdfURL = EnrollmentEndpoint.certificate(studentID: record.studentID)!
        precondition(EnrollmentEndpoint.isCertificate(pdfURL, studentID: record.studentID))
        for raw in ["http://ccsys.niu.edu.tw/MvcTeam/AcadeExport/StudyProved/T0000001", "https://example.com/MvcTeam/AcadeExport/StudyProved/T0000001", "https://ccsys.niu.edu.tw/MvcTeam/AcadeExport/StudyProved/T0000002", pdfURL.absoluteString + "?token=invalid"] {
            precondition(!EnrollmentEndpoint.isCertificate(URL(string: raw)!, studentID: record.studentID))
        }
        precondition(!EnrollmentEndpoint.isCertificateLogin(URL(string: "https://example.com/MvcTeam/Account/Login")!))
        var loads = 0
        let model = EnrollmentCertificateViewModel(currentSession: {"session-A"}, currentAccount: {"t0000001"}, loadRegistration: { _ in
            loads += 1
            return snapshot
        }, loadPDF: { _ in Data("synthetic-pdf".utf8) })
        await model.refreshAndWait()
        precondition(loads == 1 && model.snapshot?.records == [record] && !model.isLoading)
        model.showCertificate(); try await settle()
        precondition(model.pdfData != nil && !model.isLoadingPDF)
        model.dismissCertificate()
        precondition(model.pdfData == nil)
        model.showCertificate(); try await settle()
        precondition(model.pdfData != nil, "Identical PDF can be opened again after dismissal")
        model.cancel()
        precondition(model.snapshot == nil && model.pdfData == nil && model.updatedAt == nil)
        precondition(model.loadStage == .connecting, "Cancellation resets query progress")

        loads = 0
        let expired = EnrollmentCertificateViewModel(currentSession: {"A"}, currentAccount: {"T0000001"}, loadRegistration: { _ in loads += 1; throw EnrollmentError.sessionExpired })
        await expired.refreshAndWait()
        precondition(loads == 1 && expired.errorMessage != nil && !expired.isLoading,
                     "The service already refreshed SSO; the ViewModel must not restart the whole query")
        let offline = EnrollmentCertificateViewModel(currentSession: {"A"}, currentAccount: {"T0000001"}, loadRegistration: { _ in throw URLError(.notConnectedToInternet) })
        await offline.refreshAndWait()
        precondition(offline.errorMessage?.contains("連線") == true)

        let gate = Gate()
        var session = "A"
        let racing = EnrollmentCertificateViewModel(currentSession: {session}, currentAccount: {"T0000001"}, loadRegistration: { _ in try await gate.load() })
        racing.refresh(); try await settle()
        racing.refresh(); try await settle()
        precondition(gate.waiting.count == 2)
        gate.waiting[0].resume(returning: snapshot); try await settle()
        precondition(racing.snapshot == nil && racing.isLoading, "Superseded response must be ignored")
        session = "B"
        gate.waiting[1].resume(returning: snapshot); try await settle()
        precondition(racing.snapshot == nil, "Old login session cannot publish data")
        racing.cancel()
        racing.refresh(); try await settle()
        racing.cancel()
        gate.waiting[2].resume(returning: snapshot); try await settle()
        precondition(racing.snapshot == nil && !racing.isLoading)

        let mismatched = EnrollmentCertificateViewModel(currentSession: {"A"}, currentAccount: {"T0000002"}, loadRegistration: { _ in snapshot })
        await mismatched.refreshAndWait()
        precondition(mismatched.snapshot == nil && mismatched.errorMessage != nil)
        var pdfGate: CheckedContinuation<Data, Error>?
        let pendingPDF = EnrollmentCertificateViewModel(currentSession: {"A"}, currentAccount: {"T0000001"}, loadRegistration: { _ in snapshot }, loadPDF: { _ in try await withCheckedThrowingContinuation { pdfGate = $0 } })
        await pendingPDF.refreshAndWait()
        pendingPDF.showCertificate(); try await settle()
        pendingPDF.cancel()
        pdfGate?.resume(returning: Data("old-pdf".utf8)); try await settle()
        precondition(pendingPDF.pdfData == nil && !pendingPDF.isLoadingPDF)
        let mvcLogin = EnrollmentCertificateViewModel(currentSession: {"A"}, currentAccount: {"T0000001"}, loadRegistration: { _ in snapshot }, loadPDF: { _ in throw EnrollmentError.sessionExpired })
        await mvcLogin.refreshAndWait()
        mvcLogin.showCertificate(); try await settle()
        precondition(mvcLogin.certificateLoginURL == pdfURL && !mvcLogin.isLoadingPDF)
        print("PASS: endpoint ownership, single-pass expiry, offline classification, cancellation, stale requests, account switch, PDF cancellation, separate MvcTeam login")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='niu-enrollment-state-') as directory:
    folder = Path(directory)
    checks = folder / 'Checks.swift'
    # Compile the production stage enum alongside the isolated service stub.
    service = (root / 'Features/EnrollmentCertificate/Services/EnrollmentCertificateService.swift').read_text()
    stage = service.split('@MainActor\nfinal class EnrollmentRegistrationService', 1)[0]
    checks.write_text(stage + stubs)
    binary = folder / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-D', 'DEBUG', '-swift-version', '5', '-module-cache-path', str(folder / 'ModuleCache'), '-parse-as-library', str(models), str(viewmodel), str(root / 'Core/Services/SSOGUIDBridge.swift'), str(checks), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)

# Run the actual registration state machine and GUID HTTP handling with fake WebKit
# and transport objects. No school network, real token, cookies or Keychain is used.
bridge_fixture = r'''
import Foundation
import CoreGraphics
extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
final class SSOTokenStore {
    static let shared = SSOTokenStore()
    var token: String? = "synthetic-token"
    func clear(ifMatching value: String) { if token == value { token = nil } }
}
@MainActor final class SSOSessionService {
    static let shared = SSOSessionService()
    func requestRefresh(force: Bool) async -> Bool { fatalError("Live SSO must not be used") }
}
enum FixtureHTTP {
    static var status = 200
    static var calls = 0
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        return (Data(#"{"guid":"synthetic"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
protocol WKNavigationDelegate {}
final class WKNavigation {}
enum WKNavigationActionPolicy { case allow, cancel }
final class WKFrameInfo { var isMainFrame = true }
final class WKNavigationAction {
    let request: URLRequest
    let targetFrame: WKFrameInfo? = WKFrameInfo()
    init(_ url: URL) { request = URLRequest(url: url) }
}
struct WKContentWorld { static let page = WKContentWorld() }
final class WKWebsiteDataStore { static func `default`() -> WKWebsiteDataStore { WKWebsiteDataStore() } }
final class WKWebViewConfiguration { var websiteDataStore = WKWebsiteDataStore.default() }
@MainActor final class WKWebView {
    var navigationDelegate: (any WKNavigationDelegate)?
    var url: URL?
    var requests: [URLRequest] = []
    init(frame: CGRect, configuration: WKWebViewConfiguration) {}
    func load(_ request: URLRequest) { requests.append(request); url = request.url }
    func stopLoading() {}
    func evaluateJavaScript(_ script: String) async throws -> Any? { nil }
    func evaluateJavaScript(_ script: String, in frame: WKFrameInfo, in world: WKContentWorld,
                            completionHandler: (Result<Any, Error>) -> Void) { completionHandler(.success(false)) }
}
@main struct BridgeChecks {
    @MainActor static func settle() async throws { try await Task.sleep(for: .milliseconds(20)) }
    @MainActor static func redirect(_ service: EnrollmentRegistrationService, _ path: String) {
        let url = URL(string: "https://acade.niu.edu.tw" + path)!
        service.webView(service.webView, decidePolicyFor: WKNavigationAction(url)) { policy in
            precondition(policy == .cancel)
        }
    }
    @MainActor static func reset(status: Int) {
        FixtureHTTP.status = status
        FixtureHTTP.calls = 0
        SSOTokenStore.shared.token = "synthetic-token"
    }
    /// Starts a load that must end in sessionExpired; `completed` flips when it does.
    @MainActor static func expectExpiry(_ service: EnrollmentRegistrationService) -> (Task<Void, Never>, () -> Bool) {
        var completed = false
        let load = Task {
            defer { completed = true }
            do { _ = try await service.load(account: "synthetic"); fatalError("Expected expired session") }
            catch { precondition(error as? EnrollmentError == .sessionExpired, "\(error)") }
        }
        return (load, { completed })
    }
    @MainActor static func main() async throws {
        // GUID 401 and SSO refresh fails: stop before loading any acade bridge.
        reset(status: 401)
        var refreshes = 0
        var service = EnrollmentRegistrationService(refreshSSO: { refreshes += 1; return false })
        var (load, completed) = expectExpiry(service)
        try await settle()
        redirect(service, "/NIU/Default.aspx")
        try await settle()
        precondition(completed() && FixtureHTTP.calls == 1 && refreshes == 1 && service.webView.requests.count == 1,
                     "401 with failed refresh must end without a bridge")
        precondition(SSOTokenStore.shared.token == nil)
        await load.value

        // GUID 401, SSO refresh succeeds: retry GUID in the same WebView without reloading MainFrame.
        reset(status: 401)
        refreshes = 0
        var stages: [EnrollmentLoadStage] = []
        service = EnrollmentRegistrationService(refreshSSO: {
            refreshes += 1
            SSOTokenStore.shared.token = "fresh-token"
            FixtureHTTP.status = 200
            return true
        })
        service.onProgress = { stages.append($0) }
        (load, completed) = expectExpiry(service)
        try await settle()
        redirect(service, "/NIU/Default.aspx")
        try await settle()
        precondition(!completed() && refreshes == 1 && FixtureHTTP.calls == 2 && service.webView.requests.count == 2,
                     "Refreshed SSO must exchange a GUID within the same query")
        precondition(service.webView.requests.last?.url?.path == "/NIU/Login.aspx")
        // Logout after a bridge built from a fresh token cannot refresh again.
        redirect(service, "/NIU/logout.aspx")
        try await settle()
        precondition(completed() && refreshes == 1 && FixtureHTTP.calls == 2 && service.webView.requests.count == 2)
        precondition(stages == [.connecting, .signingIn], "Progress must not restart: \(stages)")
        await load.value

        // GUID 200 then logout: refresh SSO once, bridge once more, then stop.
        reset(status: 200)
        refreshes = 0
        service = EnrollmentRegistrationService(refreshSSO: { refreshes += 1; return true })
        (load, completed) = expectExpiry(service)
        try await settle()
        redirect(service, "/NIU/Default.aspx")
        try await settle()
        precondition(!completed() && FixtureHTTP.calls == 1 && service.webView.requests.count == 2)
        // A GUID-bearing Login.aspx finishing is not a failure yet.
        service.webView(service.webView, didFinish: nil)
        precondition(!completed())
        // An unrelated hidden subframe must not expire the session.
        let hidden = WKNavigationAction(URL(string: "https://acade.niu.edu.tw/NIU/logout.aspx")!)
        hidden.targetFrame?.isMainFrame = false
        service.webView(service.webView, decidePolicyFor: hidden) { precondition($0 == .allow) }
        precondition(!completed())
        redirect(service, "/NIU/logout.aspx")
        try await settle()
        precondition(!completed() && refreshes == 1 && FixtureHTTP.calls == 2 && service.webView.requests.count == 3,
                     "A stale token gets exactly one SSO refresh and one more bridge")
        redirect(service, "/NIU/logout.aspx")
        try await settle()
        precondition(completed() && refreshes == 1 && FixtureHTTP.calls == 2 && service.webView.requests.count == 3,
                     "Recovery is bounded to one refresh and two bridges")
        await load.value

        // Cancelling while SSO refresh is pending must not request a GUID or load a bridge afterwards.
        reset(status: 401)
        var gate: CheckedContinuation<Bool, Never>?
        service = EnrollmentRegistrationService(refreshSSO: { await withCheckedContinuation { gate = $0 } })
        let cancelled = Task {
            do { _ = try await service.load(account: "synthetic"); fatalError("Expected cancellation") }
            catch { precondition(error is CancellationError) }
        }
        try await settle()
        redirect(service, "/NIU/Default.aspx")
        try await settle()
        precondition(gate != nil && FixtureHTTP.calls == 1)
        service.cancel()
        await cancelled.value
        FixtureHTTP.status = 200
        gate?.resume(returning: true)
        try await settle()
        precondition(FixtureHTTP.calls == 1 && service.webView.requests.count == 1,
                     "SSO completion after cancellation must not resume the old query")

        // The didFinish fallback must also detect logout without waiting for a timeout.
        reset(status: 200)
        service = EnrollmentRegistrationService(refreshSSO: { false })
        (load, completed) = expectExpiry(service)
        try await settle()
        redirect(service, "/NIU/Default.aspx")
        try await settle()
        service.webView.url = URL(string: "https://acade.niu.edu.tw/NIU/logout.aspx")!
        service.webView(service.webView, didFinish: nil)
        try await settle()
        precondition(completed())
        await load.value
        print("PASS: in-query SSO refresh, bounded bridges, cancellation during refresh, monotonic progress, unrelated-frame isolation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='niu-enrollment-bridge-') as directory:
    folder = Path(directory)
    registration = service.split('/// A per-request ephemeral session', 1)[0]
    registration = registration.replace('import WebKit\n', '').replace('import PDFKit\n', '')
    bridge = (root / 'Core/Services/SSOGUIDBridge.swift').read_text()
    bridge = bridge.replace('URLSession.shared.data(for: request)', 'FixtureHTTP.data(for: request)')
    assert 'URLSession.' not in bridge, 'Offline fixture must replace all live GUID transport'
    checks = folder / 'Checks.swift'
    checks.write_text(registration + bridge + bridge_fixture)
    binary = folder / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-D', 'DEBUG', '-swift-version', '5', '-module-cache-path',
                    str(folder / 'ModuleCache'), '-parse-as-library', str(models), str(checks),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
