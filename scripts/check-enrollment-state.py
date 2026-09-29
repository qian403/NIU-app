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
    var onProgress: ((String) -> Void)?
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
        for raw in ["https://acade.niu.edu.tw/NIU/Login.aspx?GUID=synthetic", "https://acade.niu.edu.tw/NIU/MainFrame.aspx", "https://ccsys.niu.edu.tw/SSO/Std002.aspx", "https://ccsys.niu.edu.tw/SSO/StdMain.aspx", "https://example.com/SSO/login"] {
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
        var loads = 0, refreshes = 0
        let model = EnrollmentCertificateViewModel(currentSession: {"session-A"}, currentAccount: {"t0000001"}, refreshSession: { refreshes += 1; return true }, loadRegistration: { _ in
            loads += 1
            if loads == 1 { throw EnrollmentError.sessionExpired }
            return snapshot
        }, loadPDF: { _ in Data("synthetic-pdf".utf8) })
        await model.refreshAndWait()
        precondition(loads == 2 && refreshes == 1 && model.snapshot?.records == [record] && !model.isLoading)
        model.showCertificate(); try await settle()
        precondition(model.pdfData != nil && !model.isLoadingPDF)
        model.dismissCertificate()
        precondition(model.pdfData == nil)
        model.showCertificate(); try await settle()
        precondition(model.pdfData != nil, "Identical PDF can be opened again after dismissal")
        model.cancel()
        precondition(model.snapshot == nil && model.pdfData == nil && model.updatedAt == nil)

        loads = 0; refreshes = 0
        let expired = EnrollmentCertificateViewModel(currentSession: {"A"}, currentAccount: {"T0000001"}, refreshSession: { refreshes += 1; return true }, loadRegistration: { _ in loads += 1; throw EnrollmentError.sessionExpired })
        await expired.refreshAndWait()
        precondition(loads == 2 && refreshes == 1 && expired.errorMessage != nil && !expired.isLoading)
        var refreshGate: CheckedContinuation<Bool, Never>?
        var cancelledLoads = 0
        let cancelledLogin = EnrollmentCertificateViewModel(currentSession: {"A"}, currentAccount: {"T0000001"}, refreshSession: {
            await withCheckedContinuation { refreshGate = $0 }
        }, loadRegistration: { _ in cancelledLoads += 1; throw EnrollmentError.sessionExpired })
        cancelledLogin.refresh(); try await settle()
        precondition(refreshGate != nil && cancelledLogin.isLoading)
        cancelledLogin.cancel()
        refreshGate?.resume(returning: true); try await settle()
        precondition(cancelledLoads == 1 && !cancelledLogin.isLoading && cancelledLogin.snapshot == nil,
                     "SSO completion after cancellation must not restart the old query")
        refreshes = 0
        let offline = EnrollmentCertificateViewModel(currentSession: {"A"}, currentAccount: {"T0000001"}, refreshSession: { refreshes += 1; return true }, loadRegistration: { _ in throw URLError(.notConnectedToInternet) })
        await offline.refreshAndWait()
        precondition(refreshes == 0 && offline.errorMessage?.contains("連線") == true)

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
        let mvcLogin = EnrollmentCertificateViewModel(currentSession: {"A"}, currentAccount: {"T0000001"}, refreshSession: { fatalError("MvcTeam expiry must not refresh modern SSO") }, loadRegistration: { _ in snapshot }, loadPDF: { _ in throw EnrollmentError.sessionExpired })
        await mvcLogin.refreshAndWait()
        mvcLogin.showCertificate(); try await settle()
        precondition(mvcLogin.certificateLoginURL == pdfURL && !mvcLogin.isLoadingPDF)
        print("PASS: endpoint ownership, bounded SSO recovery, offline classification, cancellation, stale requests, account switch, PDF cancellation, separate MvcTeam login")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='niu-enrollment-state-') as directory:
    folder = Path(directory)
    checks = folder / 'Checks.swift'
    checks.write_text(stubs)
    binary = folder / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(folder / 'ModuleCache'), '-parse-as-library', str(models), str(viewmodel), str(root / 'Core/Services/SSOGUIDBridge.swift'), str(checks), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
