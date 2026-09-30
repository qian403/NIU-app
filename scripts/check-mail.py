#!/usr/bin/env python3
"""Exercise production Mail code with synthetic responses, no Keychain or school requests."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
checks = r'''
import Foundation
import Combine
import CoreText

@MainActor enum StorageKeys { static let authSessionID = "mail-tests-only" }
@MainActor struct LoginRepository {
    static let shared = Self()
    func getSavedCredentials() -> (username: String, password: String)? {
        fatalError("Tests must not read real credentials")
    }
}

func syntheticSVG() -> String {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil)
    var paths: [String] = []
    for (index, character) in "123456".utf16.enumerated() {
        var input = character
        var glyph: CGGlyph = 0
        precondition(CTFontGetGlyphsForCharacters(font, &input, &glyph, 1))
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: CGFloat(3 + index * 24), ty: 40)
        let path = CTFontCreatePathForGlyph(font, glyph, &transform)!
        var data = ""
        func point(_ p: CGPoint) -> String { "\(p.x) \(p.y)" }
        path.applyWithBlock { item in
            let element = item.pointee
            switch element.type {
            case .moveToPoint: data += "M" + point(element.points[0])
            case .addLineToPoint: data += "L" + point(element.points[0])
            case .addQuadCurveToPoint: data += "Q" + point(element.points[0]) + " " + point(element.points[1])
            case .addCurveToPoint: data += "C" + point(element.points[0]) + " " + point(element.points[1]) + " " + point(element.points[2])
            case .closeSubpath: data += "Z"
            @unknown default: fatalError("Unexpected path")
            }
        }
        paths.append("<path fill='#222' d='\(data)'/>")
    }
    return "<svg width='150' height='50' viewBox='0,0,150,50'>" + paths.joined()
        + "<path fill='none' stroke='#555' d='M0 20L150 25'/></svg>"
}

final class FixtureProtocol: URLProtocol {
    // The request fixture is changed only between completed requests.
    static var handler: ((URLRequest) throws -> (Int, String, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { fatalError("No live request permitted") }
            let (status, mime, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": mime])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

actor ControlledMail: CampusMailServing {
    var loginWaiter: CheckedContinuation<Void, Error>?
    var loginCount = 0
    var delayLogin = false
    var loginError: CampusMailError?
    var delayChallenge = false
    var challengeWaiter: CheckedContinuation<CampusMailLoginChallenge, Error>?
    var delayCookies = false
    var cookieWaiter: CheckedContinuation<[HTTPCookie], Error>?
    func configure(delayLogin: Bool = false, delayChallenge: Bool = false, error: CampusMailError? = nil) {
        self.delayLogin = delayLogin; self.delayChallenge = delayChallenge; loginError = error
    }
    func challenge() async throws -> CampusMailLoginChallenge {
        if delayChallenge {
            return try await withCheckedThrowingContinuation { challengeWaiter = $0 }
        }
        return CampusMailLoginChallenge(requiresCaptcha: true, svg: "<svg></svg>")
    }
    func login(account: String, password: String, captcha: String) async throws {
        loginCount += 1
        if let loginError { throw loginError }
        if delayLogin { try await withCheckedThrowingContinuation { loginWaiter = $0 } }
    }
    func completeTwoFactor(account: String, token: String) async throws {
        if token != "123456" { throw CampusMailError.invalidTwoFactor }
    }
    nonisolated func invalidate() {}
    func webCookies() async throws -> [HTTPCookie] {
        if delayCookies { return try await withCheckedThrowingContinuation { cookieWaiter = $0 } }
        return []
    }
    func delayCookieExport() { delayCookies = true }
    func completeCookies() { cookieWaiter?.resume(returning: []); cookieWaiter = nil }
    func completeLogin() { loginWaiter?.resume(); loginWaiter = nil }
    func completeChallenge(_ svg: String) {
        challengeWaiter?.resume(returning: CampusMailLoginChallenge(requiresCaptcha: true, svg: svg))
        challengeWaiter = nil
    }
}

@main struct Checks {
    @MainActor static func settle() async throws { try await Task.sleep(for: .milliseconds(35)) }

    static func assertError(_ expected: String, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            fatalError("Expected \(expected)")
        } catch {
            precondition(String(describing: error) == expected, "Unexpected error \(error)")
        }
    }

    @MainActor static func main() async throws {
        precondition(MailCaptchaRecognizer.candidate(from: "12 34 56") == "123456")
        precondition(MailCaptchaRecognizer.candidate(from: "A1b2C3") == "A1b2C3")
        for invalid in ["12345", "1234567", "12345!", "１２３４５６"] {
            precondition(MailCaptchaRecognizer.candidate(from: invalid) == nil)
        }
        let svg = syntheticSVG()
        let image = try MailCaptchaRecognizer.rasterize(svg: svg)
        precondition(image.width == 600 && image.height == 200)
        let recognized = try await MailCaptchaRecognizer.recognize(svg: svg)
        precondition(recognized == "123456", "Synthetic six-digit OCR must work")
        for malicious in [
            "<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg/>",
            svg.replacingOccurrences(of: "</svg>", with: "<script>evil()</script></svg>"),
            svg.replacingOccurrences(of: "M", with: "m"),
            svg.replacingOccurrences(of: "0,0,150,50", with: "0,0,99999,99999")
        ] {
            do { _ = try MailCaptchaRecognizer.rasterize(svg: malicious); fatalError("Unsupported SVG must fail closed") }
            catch { precondition(error is CampusMailError) }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let service = CampusMailService(configuration: config)
        defer { service.invalidate() }
        FixtureProtocol.handler = { request in
            precondition(request.url?.host == "mail.niu.edu.tw" && request.url?.scheme == "https")
            precondition(request.value(forHTTPHeaderField: "X-XSRF-TOKEN")?.isEmpty == false)
            switch request.url?.path {
            case "/api/config/NUMail": return (200, "application/json", #"{"LOGIN_NEED_VERIFICATION_CODE":true}"#)
            case "/api/auth/captcha": return (200, "image/svg+xml", "<svg></svg>")
            default: fatalError("Unexpected request")
            }
        }
        let challenge = try await service.challenge()
        precondition(challenge.requiresCaptcha && challenge.svg == "<svg></svg>")
        for (reason, expected) in [
            ("validation error", "invalidCaptcha"), ("Unauthorized", "invalidCredentials"),
            ("two factor authentication require", "twoFactorRequired"),
            ("please change password first", "additionalVerification"), ("ad password expired", "additionalVerification")
        ] {
            FixtureProtocol.handler = { _ in (401, "application/json", "{\"error\":{\"message\":\"\(reason)\"}}") }
            await assertError(expected) { try await service.login(account: "student", password: "synthetic", captcha: "ABC123") }
        }
        FixtureProtocol.handler = { request in
            if request.url?.path == "/api/auth/login" {
                precondition(request.httpMethod == "POST")
                return (200, "application/json", "{}")
            }
            return (200, "application/json", #"{"username":"another-student"}"#)
        }
        await assertError("accountMismatch") { try await service.login(account: "student", password: "synthetic", captcha: "ABC123") }
        FixtureProtocol.handler = { request in
            if request.url?.path == "/api/auth/login" { return (200, "application/json", "{}") }
            return (401, "application/json", "{}")
        }
        await assertError("sessionExpired") { try await service.login(account: "student", password: "synthetic", captcha: "ABC123") }
        FixtureProtocol.handler = { _ in (200, "text/html", "<html>Login</html>") }
        await assertError("invalidResponse") { _ = try await service.login(account: "student", password: "synthetic", captcha: "123456") }
        FixtureProtocol.handler = { _ in (302, "text/html", "") }
        await assertError("sessionExpired") { _ = try await service.login(account: "student", password: "synthetic", captcha: "123456") }
        FixtureProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await service.login(account: "student", password: "synthetic", captcha: "123456"); fatalError("Expected offline") }
        catch { precondition((error as? URLError)?.code == .notConnectedToInternet) }
        FixtureProtocol.handler = { request in
            if request.url?.path == "/api/auth/2FA/validate" {
                precondition(request.httpMethod == "POST")
                return (200, "application/json", "{}")
            }
            precondition(request.url?.path == "/api/auth/user")
            return (200, "application/json", #"{"username":"student"}"#)
        }
        try await service.completeTwoFactor(account: "student", token: "123456")
        FixtureProtocol.handler = { _ in (401, "application/json", #"{"error":{"message":"Unauthorized"}}"#) }
        await assertError("invalidTwoFactor") { try await service.completeTwoFactor(account: "student", token: "wrong") }

        for (raw, allowed) in [
            ("https://mail.niu.edu.tw/NUMail/Mobile/Box/INBOX", true),
            ("https://mail.niu.edu.tw:443/NUMail/Config/General", true),
            ("https://mail.niu.edu.tw.evil.invalid/NUMail", false),
            ("http://mail.niu.edu.tw/NUMail", false),
            ("https://user:secret@mail.niu.edu.tw/", false),
            ("https://mail.niu.edu.tw:444/", false),
            ("file:///private/tmp/secret", false),
            ("javascript:alert(1)", false)
        ] {
            precondition(CampusMailWebPolicy.isSchool(URL(string: raw)!) == allowed)
        }
        precondition(CampusMailWebPolicy.isLogin(URL(string: "https://mail.niu.edu.tw/NUMail/Login/2FA")!))
        precondition(!CampusMailWebPolicy.isLogin(CampusMailWebPolicy.inbox))
        precondition(CampusMailWebPolicy.isSchoolBlob(URL(string: "blob:https://mail.niu.edu.tw/abc")!))
        precondition(!CampusMailWebPolicy.isSchoolBlob(URL(string: "blob:https://elsewhere.invalid/abc")!))
        precondition(CampusMailWebPolicy.filename("../../secret.txt") == "secret.txt")
        precondition(CampusMailWebPolicy.filename("..\\..\\secret.txt") == "secret.txt")
        precondition(CampusMailWebPolicy.filename("\u{0}../") == "附件")
        precondition(CampusMailWebPolicy.filename("公告.pdf") == "公告.pdf")
        for domain in [".niu.edu.tw", "unrelated.invalid"] {
            config.httpCookieStorage?.setCookie(HTTPCookie(properties: [
                .domain: domain, .path: "/", .name: "synthetic", .value: "not-a-real-session"
            ])!)
        }
        let exported = try await service.webCookies()
        precondition(exported.contains { $0.name == "synthetic" })
        precondition(exported.allSatisfy { $0.domain == "mail.niu.edu.tw" && $0.isSecure })
        let snapshot = CampusMailWebSession(account: "student", cookies: exported)
        var invalidations = 0
        snapshot.onInvalidate = { invalidations += 1 }
        snapshot.invalidate()
        snapshot.invalidate()
        precondition(!snapshot.isValid && snapshot.cookies.isEmpty && invalidations == 1)

        let fullService = ControlledMail()
        let full = MailViewModel(makeService: { fullService }, currentSession: { "A" },
            savedCredentials: { ("student", "synthetic") }, recognizeCaptcha: { _ in "123456" })
        full.prepare(account: "student")
        try await settle()
        precondition(full.isAuthenticated && !full.isBusy && full.webSession?.account == "student")
        let originalSession = full.webSession!
        full.webSessionExpired(id: UUID())
        precondition(full.webSession === originalSession, "Stale browser callbacks cannot expire the current account")
        full.suspend()
        precondition(originalSession.isValid && full.webSession === originalSession,
                     "Leaving the screen must preserve the workspace and unsaved drafts")
        full.reset()
        precondition(!originalSession.isValid && full.webSession == nil && !full.isAuthenticated)
        full.prepare(account: "student")
        try await settle()
        full.webSessionExpired(id: full.webSession!.id, accountMismatch: true)
        precondition(full.webSession == nil && !full.isAuthenticated && full.errorMessage == CampusMailError.accountMismatch.errorDescription)
        let fullAttempts = await fullService.loginCount
        precondition(fullAttempts == 2, "Browser expiry must not automatically replay a pending send")
        let lateCookies = ControlledMail()
        await lateCookies.delayCookieExport()
        let cookieRace = MailViewModel(makeService: { lateCookies }, currentSession: { "A" },
            savedCredentials: { ("student", "synthetic") }, recognizeCaptcha: { _ in "123456" })
        cookieRace.prepare(account: "student")
        try await settle()
        cookieRace.reset()
        await lateCookies.completeCookies()
        try await settle()
        precondition(cookieRace.webSession == nil && !cookieRace.isAuthenticated, "Logout must invalidate in-flight cookie export")
        let twoFactorService = ControlledMail()
        await twoFactorService.configure(error: .twoFactorRequired)
        let twoFactor = MailViewModel(makeService: { twoFactorService }, currentSession: { "A" },
            savedCredentials: { ("student", "synthetic") }, recognizeCaptcha: { _ in "123456" })
        twoFactor.prepare(account: "student")
        try await settle()
        precondition(twoFactor.needsTwoFactor && !twoFactor.isBusy && !twoFactor.isAuthenticated)
        twoFactor.submitTwoFactor("wrong")
        try await settle()
        precondition(twoFactor.needsTwoFactor && twoFactor.webSession == nil && twoFactor.errorMessage != nil)
        twoFactor.submitTwoFactor("123456")
        try await settle()
        precondition(twoFactor.isAuthenticated && twoFactor.webSession != nil && !twoFactor.needsTwoFactor)
        twoFactor.reset()

        let delayed = ControlledMail()
        await delayed.configure(delayLogin: true)
        let loginRace = MailViewModel(makeService: { delayed }, currentSession: { "A" },
            savedCredentials: { ("student", "synthetic") }, recognizeCaptcha: { _ in "123456" })
        loginRace.prepare(account: "student")
        try await settle()
        loginRace.suspend()
        await delayed.completeLogin()
        try await settle()
        precondition(!loginRace.isAuthenticated && !loginRace.isBusy)

        let oldChallenge = ControlledMail()
        await oldChallenge.configure(delayChallenge: true)
        let freshChallenge = ControlledMail()
        var factoryCalls = 0
        let captchaRace = MailViewModel(makeService: {
            factoryCalls += 1
            return factoryCalls == 1 ? oldChallenge : freshChallenge
        }, currentSession: { "A" }, savedCredentials: { ("student", "synthetic") }, recognizeCaptcha: { _ in "123456" })
        captchaRace.prepare(account: "student")
        try await settle()
        captchaRace.suspend()
        captchaRace.prepare(account: "student")
        try await settle()
        await oldChallenge.completeChallenge("<svg>STALE</svg>")
        try await settle()
        let oldAttempts = await oldChallenge.loginCount
        precondition(oldAttempts == 0 && captchaRace.isAuthenticated, "Old CAPTCHA must not submit credentials")
        try await settle()

        let rejected = ControlledMail()
        await rejected.configure(error: .invalidCaptcha)
        let retry = MailViewModel(makeService: { rejected }, currentSession: { "A" },
            savedCredentials: { ("student", "synthetic") }, recognizeCaptcha: { _ in "123456" })
        retry.prepare(account: "student")
        try await settle()
        let attempts = await rejected.loginCount
        precondition(attempts == 3 && !retry.isAuthenticated && !retry.isBusy && retry.errorMessage != nil,
                     "CAPTCHA retries must stop after three attempts")

        for failure in [CampusMailError.invalidCredentials, .additionalVerification] {
            let badCredentials = ControlledMail()
            await badCredentials.configure(error: failure)
            let stopped = MailViewModel(makeService: { badCredentials }, currentSession: { "A" },
                savedCredentials: { ("student", "synthetic") }, recognizeCaptcha: { _ in "123456" })
            stopped.prepare(account: "student")
            try await settle()
            let count = await badCredentials.loginCount
            precondition(count == 1 && !stopped.isBusy && stopped.errorMessage != nil,
                         "Wrong password/additional verification must not be retried")
        }
        let unrecognized = ControlledMail()
        let noOCR = MailViewModel(makeService: { unrecognized }, currentSession: { "A" },
            savedCredentials: { ("student", "synthetic") }, recognizeCaptcha: { _ in nil })
        noOCR.prepare(account: "student")
        try await settle()
        let noAttempts = await unrecognized.loginCount
        precondition(noAttempts == 0 && !noOCR.isBusy && noOCR.errorMessage != nil)
        print("PASS: automatic Mail login/OCR, bounded retries, 2FA, identity/errors, stale requests, logout, WebKit session handoff/lifetime, cookie scope, URL/filename policy")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-mail-check-") as directory:
    temp = Path(directory)
    source = temp / "Checks.swift"
    source.write_text(checks)
    binary = temp / "checks"
    files = [
        root / "Features/Mail/Models/MailModels.swift",
        root / "Features/Mail/Services/MailService.swift",
        root / "Features/Mail/Services/MailCaptchaRecognizer.swift",
        root / "Features/Mail/ViewModels/MailViewModel.swift",
    ]
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(temp / "ModuleCache"),
        "-parse-as-library", *map(str, files), str(source), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
