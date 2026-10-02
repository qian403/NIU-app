#!/usr/bin/env python3
"""Exercise the production CAPTCHA processor with synthetic images, offline.

--benchmark reports 120 deterministic samples; --manifest accepts a JSON array
[{"path":"sample.png","expected":"12345"}] with paths relative to that file.
Keep real images/labels outside the repository. No login requests are submitted.
--processor selects an older source snapshot for comparable benchmark runs.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--benchmark", action="store_true", help="Report OCR accuracy and latency on 120 deterministic synthetic images")
parser.add_argument("--manifest", type=Path, help="Offline JSON array of {path, expected}; run benchmark instead of regression checks")
parser.add_argument("--processor", type=Path, help="Processor snapshot for before/after benchmarking")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = (root / "Features/Moodle/Views/MoodleWebView.swift").read_text()
manager_fixture = r'''
import Foundation
@MainActor final class WKWebView {
    var url = URL(string: "https://euni.niu.edu.tw/login/index.php")
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
    ("    private func isTrustedAttendanceLoginPage", "    private struct AttendanceCaptchaPayload"),
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

    static func image(_ text: String, noisy: Bool, seed: Int = 0) -> NSImage {
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
        let inks: [(Double, Double, Double)] = [
            (35, 99, 25), (130, 7, 135), (167, 50, 15), (17, 139, 194),
            (172, 141, 159), (1, 47, 76), (149, 163, 99), (9, 6, 6)
        ]
        let ink = inks[seed % inks.count]
        let color = noisy ? CGColor(red: ink.0/255, green: ink.1/255, blue: ink.2/255, alpha: 1)
            : CGColor(gray: 0, alpha: 1)
        for (index, digit) in text.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): color
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(digit), attributes: attributes))
            context.textPosition = CGPoint(x: 8 + index * (seed == 0 ? 28 : 18 + seed % 10), y: noisy ? 4 + (index * 3 + seed) % 12 : 8)
            CTLineDraw(line, context)
        }
        let cg = context.makeImage()!
        return NSImage(cgImage: cg, size: NSSize(width: 180, height: 40))
    }

    struct Sample: Decodable { let path: String; let expected: String }

    static func benchmark(_ manifest: String?) async throws {
        var samples: [(NSImage, String)] = []
        if let manifest {
            let url = URL(fileURLWithPath: manifest)
            let items = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
            for item in items {
                guard item.expected.count == 5, item.expected.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                      let image = NSImage(contentsOf: URL(fileURLWithPath: item.path, relativeTo: url.deletingLastPathComponent()))
                else { fatalError("Invalid offline sample") }
                samples.append((image, item.expected))
            }
        } else {
            for index in 0..<120 {
                let digits = String(format: "%05d", (index * 7919 + 52131) % 100000)
                samples.append((image(digits, noisy: true, seed: index), digits))
            }
        }
        precondition(!samples.isEmpty)
        var correct = 0, wrong = 0, rejected = 0
        var times: [Double] = []
        for (image, expected) in samples {
            let start = ProcessInfo.processInfo.systemUptime
            let result = await SSOCaptchaProcessor.shared.recognizeAttendance(from: image)
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            if result == expected { correct += 1 }
            else if result == nil { rejected += 1 }
            else { wrong += 1 }
        }
        let warm = Array(times.dropFirst()).sorted()
        func percentile(_ fraction: Double) -> Double {
            warm.isEmpty ? 0 : warm[min(warm.count - 1, Int(ceil(Double(warm.count) * fraction)) - 1)]
        }
        let report: [String: Any] = ["samples": samples.count, "correct": correct, "wrong": wrong,
            "rejected": rejected, "first_ms": times[0], "warm_p50_ms": percentile(0.5),
            "warm_p95_ms": percentile(0.95), "dataset": manifest == nil ? "synthetic" : "offline-manifest"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("BENCHMARK " + String(decoding: data, as: UTF8.self))
    }

    static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count > 1 {
            try await benchmark(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil)
            return
        }
        #if !BENCHMARK
        // Exhaustively compare early exits with all possible later votes. This
        // includes low confidence, invalid digits and the literal-ink fallback.
        let possibilities = [
            candidate("12345", ""), candidate("67890", ""), candidate("11111", ""),
            candidate("12345", "", 0.2), candidate("67890", "", 0.34), candidate("1234x", ""),
            SSOCaptchaProcessor.AttendanceCandidate(family: "", digits: "12345", confidence: 1, unmodifiedDigits: true)
        ]
        func verifyPrefixes(_ prefix: [SSOCaptchaProcessor.AttendanceCandidate]) {
            let remaining = 4 - prefix.count
            if let early = SSOCaptchaProcessor.stableAttendanceCandidate(prefix, remaining: remaining) {
                func complete(_ values: [SSOCaptchaProcessor.AttendanceCandidate]) {
                    if values.count == 4 {
                        precondition(SSOCaptchaProcessor.selectAttendanceCandidate(values) == early,
                            "Early exit must equal the full vote")
                        return
                    }
                    for option in possibilities {
                        let next = SSOCaptchaProcessor.AttendanceCandidate(family: "family-\(values.count)",
                            digits: option.digits, confidence: option.confidence, unmodifiedDigits: option.unmodifiedDigits)
                        complete(values + [next])
                    }
                }
                complete(prefix)
            }
            if remaining > 0 {
                for option in possibilities {
                    let next = SSOCaptchaProcessor.AttendanceCandidate(family: prefix.isEmpty ? "ink" : "family-\(prefix.count)",
                        digits: option.digits, confidence: option.confidence, unmodifiedDigits: option.unmodifiedDigits)
                    verifyPrefixes(prefix + [next])
                }
            }
        }
        verifyPrefixes([])
        precondition(SSOCaptchaProcessor.stableAttendanceCandidate(
            [candidate("12345", "ink"), candidate("12345", "ink")], remaining: 1) == nil)
        let literalInk = SSOCaptchaProcessor.AttendanceCandidate(family: "ink", digits: "12345", confidence: 1, unmodifiedDigits: true)
        precondition(SSOCaptchaProcessor.selectAttendanceCandidate([literalInk]) == "12345")
        precondition(SSOCaptchaProcessor.selectAttendanceCandidate([literalInk, candidate("67890", "original", 0.2)]) == nil)
        let erodedInk = SSOCaptchaProcessor.AttendanceCandidate(family: "ink-core", digits: "12345", confidence: 1, unmodifiedDigits: true)
        precondition(SSOCaptchaProcessor.selectAttendanceCandidate([erodedInk]) == nil,
            "Eroded digit strokes require corroboration, even with confidence 1.0")
        precondition(SSOCaptchaProcessor.selectAttendanceCandidate([erodedInk, candidate("12345", "original")]) == "12345")
        #endif
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
        for seed in 1..<8 {
            let result = await processor.recognizeAttendance(from: image("52131", noisy: true, seed: seed))
            precondition(result == "52131", "Non-green ink regression for palette \(seed)")
        }
        let monochrome = await processor.recognizeAttendance(from: image("12345", noisy: false))
        precondition(monochrome == "12345", "Monochrome fallback must still work")
        let blank = await processor.recognizeAttendance(from: image("", noisy: false))
        precondition(blank == nil, "Blank image must not yield a code")
        let shapes = await processor.recognizeAttendance(from: image("", noisy: true, seed: 6))
        precondition(shapes == nil, "Colored background shapes must not produce a code")
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
        print("PASS: noisy images across eight ink colors, monochrome fallback, blank, SSO and cancellation")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-captcha-test-") as directory:
    directory = Path(directory)
    manager_swift = directory / "ManagerChecks.swift"
    manager_swift.write_text(manager_fixture)
    manager_binary = directory / "manager-checks"
    if not (args.benchmark or args.manifest):
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "ModuleCache"),
            str(manager_swift), "-o", str(manager_binary),
        ], check=True)
        subprocess.run([str(manager_binary)], check=True, timeout=10)
    swift = directory / "Checks.swift"
    swift.write_text(fixture)
    binary = directory / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-O", "-parse-as-library", "-module-cache-path", str(directory / "ModuleCache"),
        *(["-D", "BENCHMARK"] if args.benchmark or args.manifest else []),
        str(args.processor or root / "Core/Services/SSOCaptchaProcessor.swift"), str(swift), "-o", str(binary),
    ], check=True)
    benchmark_arguments = ["--benchmark"] if args.benchmark or args.manifest else []
    if args.manifest:
        benchmark_arguments.append(str(args.manifest.resolve()))
    subprocess.run([str(binary), *benchmark_arguments], check=True, timeout=180)
