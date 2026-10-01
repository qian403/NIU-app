#!/usr/bin/env python3
"""Exercise the production CAPTCHA processor with synthetic images, offline."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Features/Moodle/Views/MoodleWebView.swift").read_text()
manager_fixture = r'''
import Foundation
@MainActor final class WKWebView {
    var isUserInteractionEnabled = true
    var pending: ((Any?, Error?) -> Void)?
    var requests: [URLRequest] = []
    func evaluateJavaScript(_ script: String, completionHandler: @escaping (Any?, Error?) -> Void) {
        pending = completionHandler
    }
    func load(_ request: URLRequest) { requests.append(request) }
    func finish(_ result: Any?) {
        let completion = pending
        pending = nil
        completion?(result, nil)
    }
}
@MainActor final class Model {
    var hasStarted = true
    var loadGeneration = 0
    var attendanceNavigationGeneration = 0
    var attendanceLoginAttempts = 1
    let maxAttendanceLoginAttempts = 3
    var attendanceUsesManualLogin = false
    var storedWebView: WKWebView? = WKWebView()
    var checks = 0
    func showAttendanceLoginPage() { attendanceUsesManualLogin = true }
    func checkAttendanceLoginSubmission(_ webView: WKWebView, generation: Int, navigationGeneration: Int) {
        checks += 1
    }
'''
for start, end in [
    ("    private struct AttendanceLoginSubmission", "    private func handleAttendanceLoginPage"),
    ("    private func retryAttendanceLoginPage", "    private func captureAttendanceCaptcha"),
    ("    private func submitAttendanceLogin", "    private func checkAttendanceLoginSubmission"),
    ("    private func javascriptLiteral", "    private func showAttendanceLoginPage"),
]:
    manager_fixture += source[source.index(start):source.index(end)].replace("private ", "")
manager_fixture += r'''
}
@main struct ManagerChecks {
    @MainActor static func main() {
        let ready = #"{"status":"ready","action":"https://euni.niu.edu.tw/login/index.php","body":"logintoken=synthetic&captcha=12345"}"#
        func prepare(_ model: Model) {
            model.submitAttendanceLogin(model.storedWebView!, username: #""synthetic""#,
                password: #""synthetic""#, captcha: "12345", captchaDataURL: "synthetic",
                generation: 0, navigationGeneration: 0)
            precondition(!model.storedWebView!.isUserInteractionEnabled,
                "Image refresh and manual edits must pause during form preparation")
        }
        for change in 0..<3 {
            let model = Model()
            prepare(model)
            if change == 0 { model.hasStarted = false }
            if change == 1 { model.loadGeneration += 1 }
            if change == 2 { model.attendanceNavigationGeneration += 1 }
            model.storedWebView!.finish(ready)
            precondition(model.storedWebView!.requests.isEmpty,
                "Queued form preparation must not submit after cancellation/navigation")
        }
        let model = Model()
        prepare(model)
        model.storedWebView!.finish(ready)
        precondition(model.storedWebView!.isUserInteractionEnabled)
        let request = model.storedWebView!.requests.first!
        precondition(request.httpMethod == "POST")
        precondition(String(data: request.httpBody!, encoding: .utf8) == "logintoken=synthetic&captcha=12345")
        precondition(model.checks == 1)
        for action in ["http://euni.niu.edu.tw/login/index.php",
            "https://example.org/login/index.php", "https://euni.niu.edu.tw/mod/attendance/attendance.php",
            "https://user:secret@euni.niu.edu.tw/login/index.php", "https://euni.niu.edu.tw:444/login/index.php"] {
            precondition(model.attendanceLoginRequest(from: .init(status: "ready", action: action, body: "")) == nil)
        }
        for manual in [false, true] {
            let retry = Model()
            retry.retryAttendanceLoginPage(retry.storedWebView!, generation: 0, navigationGeneration: 0)
            retry.storedWebView!.finish(manual)
            precondition(retry.attendanceUsesManualLogin == manual)
            precondition(retry.storedWebView!.requests.count == (manual ? 0 : 1))
            if !manual {
                precondition(retry.storedWebView!.requests[0].httpMethod == "GET",
                    "Retry must not replay rejected POST credentials")
            }
        }
        let staleRetry = Model()
        staleRetry.retryAttendanceLoginPage(staleRetry.storedWebView!, generation: 0, navigationGeneration: 0)
        staleRetry.hasStarted = false
        staleRetry.storedWebView!.finish(false)
        precondition(staleRetry.storedWebView!.requests.isEmpty)
        print("PASS: queued preparation cancellation/navigation, native POST validation, manual retry and fresh GET")
    }
}
'''
fixture = r'''
import AppKit
import CoreText

// NSImage exposes this as a method; the app uses UIImage's cgImage property.
extension NSImage {
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}

@main struct Checks {
    static func candidate(_ digits: String, _ family: String, _ confidence: Float = 1)
        -> SSOCaptchaProcessor.AttendanceCandidate {
        .init(family: family, digits: digits, confidence: confidence)
    }

    static func image(_ text: String, noisy: Bool) -> NSImage {
        let context = CGContext(data: nil, width: 180, height: 40, bitsPerComponent: 8,
            bytesPerRow: 720, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 180, height: 40))
        if noisy {
            context.setFillColor(CGColor(red: 174/255.0, green: 207/255.0, blue: 155/255.0, alpha: 1))
            context.fill(CGRect(x: 90, y: 4, width: 22, height: 18))
            context.fill(CGRect(x: 140, y: 10, width: 20, height: 18))
            context.setFillColor(CGColor(red: 21/255.0, green: 106/255.0, blue: 235/255.0, alpha: 1))
            for index in 0..<100 {
                context.fill(CGRect(x: (index * 37) % 180, y: (index * 13) % 40, width: 1, height: 1))
            }
        }
        let font = CTFontCreateWithName("TimesNewRomanPS-BoldMT" as CFString, 28, nil)
        let color = noisy ? CGColor(red: 35/255.0, green: 99/255.0, blue: 25/255.0, alpha: 1)
            : CGColor(gray: 0, alpha: 1)
        for (index, digit) in text.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): color
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(digit), attributes: attributes))
            context.textPosition = CGPoint(x: 8 + index * 28, y: noisy ? 4 + (index * 3) % 8 : 8)
            CTLineDraw(line, context)
        }
        let cg = context.makeImage()!
        return NSImage(cgImage: cg, size: NSSize(width: 180, height: 40))
    }

    static func main() async {
        setbuf(stdout, nil)
        let select = SSOCaptchaProcessor.selectAttendanceCandidate
        precondition(select([candidate("12345", "green")]) == nil, "Length alone must not pass")
        let literalGreen = SSOCaptchaProcessor.AttendanceCandidate(
            family: "green", digits: "12345", confidence: 1, unmodifiedDigits: true)
        precondition(select([literalGreen]) == "12345", "Clean literal ink can survive unreadable backgrounds")
        precondition(select([literalGreen, candidate("67890", "original")]) == nil,
            "Literal ink must not override disagreement")
        precondition(select([literalGreen, candidate("67890", "original", 0.34)]) == nil,
            "Single-ink fallback must also respect low-confidence complete disagreement")
        precondition(select([candidate("12345", "green"), candidate("12345", "green")]) == nil,
            "Duplicate image treatments must not add votes")
        precondition(select([candidate("12345", "green"), candidate("12345", "original")]) == "12345")
        precondition(select([candidate("12345", "green"), candidate("67890", "original")]) == nil)
        precondition(select([candidate("12345", "green"), candidate("12345", "original"),
            candidate("67890", "cleaned")]) == "12345")
        precondition(select([candidate("12345", "green"), candidate("12345", "original"),
            candidate("67890", "cleaned"), candidate("67890", "luminance")]) == nil, "Ties must not pass")
        precondition(select([candidate("12345", "green"), candidate("12345", "original", 0.2)]) == nil)
        for invalid in ["1234", "123456", "1234x", "１２３４５"] {
            precondition(select([candidate(invalid, "green"), candidate(invalid, "original")]) == nil)
        }
        precondition(SSOCaptchaProcessor.mapAttendanceCharacters(" O I S B Z ") == "01582")
        for invalid in ["A2345", "12>45", "12345?", "123e5", "１２３４５"] {
            precondition(SSOCaptchaProcessor.mapAttendanceCharacters(invalid).isEmpty)
        }
        print("PASS: agreement, disagreement, ties, duplicate treatments, confidence and character validation")

        let processor = SSOCaptchaProcessor.shared
        for text in ["52131", "80609", "17042", "95368"] {
            let result = await processor.recognizeAttendance(from: image(text, noisy: true))
            precondition(result == text, "Synthetic colored CAPTCHA mismatch: \(text), got \(result ?? "nil")")
        }
        let monochrome = await processor.recognizeAttendance(from: image("12345", noisy: false))
        precondition(monochrome == "12345", "Monochrome fallback must still work")
        let blank = await processor.recognizeAttendance(from: image("", noisy: false))
        precondition(blank == nil, "Blank image must not yield a code")
        let invalidLength = await processor.recognize(from: image("12345", noisy: false), expectedLength: 0)
        precondition(invalidLength == nil)
        let sso = await processor.recognize(from: image("123456", noisy: false))
        precondition(sso == "123456", "Default six-digit SSO recognition must remain supported")
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return await processor.recognizeAttendance(from: image("52131", noisy: true))
        }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil, "Cancelled OCR must not yield a usable code")
        print("PASS: four noisy colored images, monochrome fallback, blank, SSO and cancellation")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-captcha-test-") as directory:
    directory = Path(directory)
    manager_swift = directory / "ManagerChecks.swift"
    manager_swift.write_text(manager_fixture)
    manager_binary = directory / "manager-checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "ModuleCache"),
        str(manager_swift), "-o", str(manager_binary),
    ], check=True)
    subprocess.run([str(manager_binary)], check=True, timeout=10)
    swift = directory / "Checks.swift"
    swift.write_text(fixture)
    binary = directory / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "ModuleCache"),
        str(root / "Core/Services/SSOCaptchaProcessor.swift"), str(swift), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=120)
