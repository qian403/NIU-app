#!/usr/bin/env python3
"""Exercise production PDF validation offline. Never requests a real certificate."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = r'''
import Foundation
import CoreGraphics
@MainActor enum SSOGUIDBridge {
    static func requestGUID(account: String) async throws -> String { fatalError("No live GUID requests") }
    static func acadeLoginURL(guid: String) -> URL? { nil }
    static func isSessionExpiredURL(_ url: URL) -> Bool { false }
}
@main struct Checks {
    static func expect(_ expected: EnrollmentError, _ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection: \(expected)") }
        catch { precondition(error as? EnrollmentError == expected) }
    }
    static func main() throws {
        let account = "T0000001"
        for domain in ["ccsys.niu.edu.tw", ".ccsys.niu.edu.tw", ".CCSYS.NIU.EDU.TW", ".niu.edu.tw"] {
            precondition(EnrollmentPDFService.isCertificateCookieDomain(domain))
        }
        for domain in ["ccsys1.niu.edu.tw", "ccsys.niu.edu.tw.example.com", ".edu.tw", "niu.edu.tw"] {
            precondition(!EnrollmentPDFService.isCertificateCookieDomain(domain))
        }
        let url = EnrollmentEndpoint.certificate(studentID: account)!
        func response(_ status: Int = 200, _ type: String = "application/pdf", _ location: String? = nil, _ length: String? = nil, _ destination: URL? = nil) -> HTTPURLResponse {
            var headers = ["Content-Type": type]
            headers["Location"] = location
            headers["Content-Length"] = length
            return HTTPURLResponse(url: destination ?? url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        try EnrollmentPDFService.validateResponse(response(), studentID: account)
        expect(.invalidResponse) { try EnrollmentPDFService.validateResponse(response(200, "text/html"), studentID: account) }
        expect(.unavailable) { try EnrollmentPDFService.validateResponse(response(503), studentID: account) }
        expect(.unavailable) { try EnrollmentPDFService.validateResponse(response(403), studentID: account) }
        expect(.sessionExpired) { try EnrollmentPDFService.validateResponse(response(401), studentID: account) }
        expect(.sessionExpired) { try EnrollmentPDFService.validateResponse(response(302, "text/html", "/MvcTeam/Account/Login?ReturnUrl=%2FMvcTeam"), studentID: account) }
        expect(.invalidResponse) { try EnrollmentPDFService.validateResponse(response(302, "text/html", "https://example.com/MvcTeam/Account/Login"), studentID: account) }
        expect(.invalidResponse) { try EnrollmentPDFService.validateResponse(response(302, "text/html", "/unrelated"), studentID: account) }
        expect(.tooLarge) { try EnrollmentPDFService.validateResponse(response(200, "application/pdf", nil, "99999999"), studentID: account) }
        expect(.invalidResponse) { try EnrollmentPDFService.validateResponse(response(200, "application/pdf", nil, nil, EnrollmentEndpoint.certificate(studentID: "T0000002")!), studentID: account) }
        expect(.invalidResponse) { try EnrollmentPDFService.validateDocument(Data("<html>登入頁</html>".utf8)) }
        expect(.invalidResponse) { try EnrollmentPDFService.validateDocument(Data("%PDF-invalid".utf8)) }
        expect(.tooLarge) { try EnrollmentPDFService.validateDocument(Data(repeating: 0, count: EnrollmentPDFService.sizeLimit + 1)) }
        let bytes = NSMutableData()
        let consumer = CGDataConsumer(data: bytes)!
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        try EnrollmentPDFService.validateDocument(bytes as Data)
        print("PASS: PDF MIME/signature/document, size limit, HTTP failures, login redirects, foreign redirects and account ownership")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='niu-enrollment-pdf-') as directory:
    folder = Path(directory)
    checks = folder / 'Checks.swift'
    checks.write_text(source)
    binary = folder / 'checks'
    files = [root / 'Features/EnrollmentCertificate/Models/EnrollmentCertificateModels.swift', root / 'Features/EnrollmentCertificate/Services/EnrollmentCertificateService.swift']
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(folder / 'ModuleCache'), *map(str, files), str(checks), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
