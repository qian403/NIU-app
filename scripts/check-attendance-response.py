#!/usr/bin/env python3
"""Compile and exercise the production attendance parser, offline, without an account.
Usage: python3 scripts/check-attendance-response.py
"""
from pathlib import Path
import base64
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Features/Moodle/Views/MoodleWebView.swift").read_text()
scanner = (root / "Features/Moodle/Views/MoodleAttendanceScannerView.swift").read_text()
outcome = source[source.index("struct MoodleAttendanceWebOutcome"):source.index("/// Moodle page viewer.")]
snapshots = source[source.index("    private struct AttendancePageNotification"):source.index("    private func inspectAttendancePage")]
parser = source[source.index("    private func makeAttendanceOutcome"):source.index("    private func failAsNeedsRelogin")]
qr = scanner[scanner.index("enum MoodleAttendanceQRCode"):scanner.index("@MainActor\nfinal class MoodleAttendanceScanner")]
fixture = "import Foundation\n" + outcome + qr + "\nstruct Parser {\nvar originalTargetURL: String?\n" + snapshots + parser + "\n}\n"
fixture = fixture.replace("private ", "")
fixture += r'''
let original = "https://euni.niu.edu.tw/mod/attendance/attendance.php?qrpass=fixture-only&sessid=123"
let parser = Parser(originalTargetURL: original)
var checks = 0
func check(_ expected: MoodleAttendanceWebOutcome.Kind, _ text: String = "", url: String = original,
           form: Bool = false, codes: [String] = [], notification: Bool = true) {
    let snapshot = Parser.AttendancePageSnapshot(url: url, body: text, hasAttendanceForm: form,
        notifications: notification ? [.init(text: text, className: "alert", type: "")] : [], errorCodes: codes)
    let result = parser.makeAttendanceOutcome(from: snapshot)
    precondition(result.kind == expected, "Expected \(expected), got \(result.kind)")
    precondition(result.opensWebResponseAutomatically == (expected == .requiresAction))
    checks += 1
}
check(.expired, "The QR code has expired, please scan the QR code again.")
check(.expired, "QR session has expired.")
check(.expired, "QR Code 已過期，請重新掃描。")
check(.expired, "QR碼已過期")
check(.expired, "QR\n代碼 已過期")
check(.expired, "二維碼已過期")
check(.expired, "Unrecognised translation", codes: ["qr_pass_wrong"])
check(.expired, "Unrecognised translation", codes: ["qr_cookie_error"])
check(.expired, "QR code has expired", form: true)
check(.requiresAction, "You have entered an incorrect password and your attendance has not been recorded.", form: true)
check(.failed, "You have entered an incorrect password and your attendance has not been recorded.")
check(.alreadyRecorded, "您的出缺席已經設置好了。")
check(.alreadyRecorded, "Your attendance has already been marked as Late.")
check(.recorded, "Your attendance in this session has been recorded.",
      url: "https://euni.niu.edu.tw/mod/attendance/view.php?id=8")
check(.unknown, "Your attendance in this session has been recorded.",
      url: "https://euni.niu.edu.tw/my/")
check(.unknown, "Your attendance in this session has been recorded.",
      url: "https://euni.niu.edu.tw/mod/attendance/view.php?id=8", notification: false)
check(.unknown, "Dashboard", url: "https://euni.niu.edu.tw/my/")
check(.unknown, "", url: "https://euni.niu.edu.tw/mod/attendance/view.php?id=8")
check(.requiresAction, "Choose a status", form: true)
check(.unknown, "QR code has expired", url: "https://example.org/", codes: ["qr_pass_wrong"])
for kind in [MoodleAttendanceWebOutcome.Kind.expired, .failed, .recorded, .alreadyRecorded] {
    let outcome = MoodleAttendanceWebOutcome(kind: kind, message: "", courseModuleID: nil)
    precondition(outcome.isTerminal)
    precondition(outcome.allowsAttendanceLinkSharing == (kind == .recorded || kind == .alreadyRecorded))
}
for kind in [MoodleAttendanceWebOutcome.Kind.requiresAction, .unknown] {
    let outcome = MoodleAttendanceWebOutcome(kind: kind, message: "", courseModuleID: nil)
    precondition(!outcome.isTerminal)
    precondition(!outcome.allowsAttendanceLinkSharing)
}
let sharedLink = "https://euni.niu.edu.tw/mod/attendance/attendance.php?qrpass=RAjWP5gHWP6P6Jg&sessid=3032"
for text in [sharedLink, "  \(sharedLink)\n", "點名連結：\(sharedLink) 快點",
             "「\(sharedLink)」", "euni.niu.edu.tw/mod/attendance/attendance.php?qrpass=RAjWP5gHWP6P6Jg&sessid=3032"] {
    precondition(MoodleAttendanceQRCode.validatedURL(fromSharedText: text)?.absoluteString == sharedLink, text)
    checks += 1
}
for text in ["", "http://euni.niu.edu.tw/mod/attendance/attendance.php?qrpass=a&sessid=1",
             "https://example.org/mod/attendance/attendance.php?qrpass=a&sessid=1",
             "https://euni.niu.edu.tw/mod/attendance/attendance.php?qrpass=a&sessid=0",
             "https://euni.niu.edu.tw/mod/attendance/attendance.php?qrpass=a&sessid=1&next=https://x",
             "https://euni.niu.edu.tw/my/"] {
    precondition(MoodleAttendanceQRCode.validatedURL(fromSharedText: text) == nil, text)
    checks += 1
}
print("PASS: \(checks) attendance response and shared link cases; only real forms open automatically")
'''
# Exercise the production DOM extractor in WebKit without account/network access.
script = re.search(r'let script = """\n(.*?)\n\s*"""',
                   source[source.index("    private func inspectAttendancePage"):], re.S).group(1)
# The script is a Swift string literal; run the JavaScript WebKit receives in the app.
assert set(re.findall(r'\\.', script)) <= {'\\\\'}, "unsupported Swift escape in extraction script"
script = script.replace('\\\\', '\\')
encoded = base64.b64encode(script.encode()).decode()
fixture += '\nimport AppKit\nimport WebKit\nlet extractionScript = String(data: Data(base64Encoded: "' + encoded + '")!, encoding: .utf8)!\n'
fixture += r'''
@MainActor final class DOMChecks: NSObject, WKNavigationDelegate {
    let webView = WKWebView()
    var index = 0
    let cases: [(String, String, MoodleAttendanceWebOutcome.Kind)] = [
        ("localized error identifier", "<div id='region-main'><div class='errorbox'>Unknown translation</div><a href='https://docs.moodle.org/en/error/attendance/qr_pass_wrong'>Help</a></div>", .expired),
        ("error past long menu", "<nav>" + String(repeating: "navigation ", count: 1500) + "</nav><main id='region-main'><div class='errormessage'>QR Code 已過期</div></main>", .expired),
        ("cookie expired", "<div data-rel='fatalerror'>QR session has expired.</div>", .expired),
        ("hidden session is not a form", "<input name='sessid' value='123'><form action='/login/index.php'><input name='username'><button type='submit'>Login</button></form>", .unknown),
        ("real status form", "<form action='/mod/attendance/attendance.php'><input name='sessid' value='123'><input type='radio' name='status' value='1'><button type='submit'>Submit</button></form>", .requiresAction),
        ("correctable password", "<div class='alert'>Incorrect password, attendance not recorded.</div><form action='/mod/attendance/attendance.php'><input name='sessid' value='123'><input name='studentpassword'><input type='submit'></form>", .requiresAction),
        ("unknown redirect", "<main id='region-main'>Dashboard</main>", .unknown),
        ("recorded with hidden Moodle chrome", "<div id='user-notifications'><div class='alert alert-success' role='alert'>您在此上課時段的出席已被記錄。<button type='button' class='close' data-dismiss='alert'><span aria-hidden='true'>&times;</span><span class='sr-only'>取消此通知</span></button></div></div><div data-region='message-drawer'><div data-region='confirm-dialogue' role='alert' hidden><label>為我和其他人刪除</label>\n\n\n<button>封鎖</button></div></div><div class='alert' style='display:none'>封鎖</div><main id='region-main'>出缺席</main>", .recorded),
        ("recorded whitespace collapses", "<div class='alert alert-success'>Your attendance\n\n\tin this   session has been recorded.</div>", .recorded),
        ("hidden error inside recorded alert", "<div class='alert alert-success'>您在此上課時段的出席已被記錄。<span style='display:none'>Incorrect password</span><span style='visibility:hidden'>密碼錯誤</span></div><main id='region-main'>出缺席</main>", .recorded),
        ("drawers layout keeps main alert", "<div id='page' class='drawers'><div class='drawer drawer-left'><div class='alert'>封鎖</div></div><div id='region-main'><div class='alert alert-success'>您在此上課時段的出席已被記錄。</div></div></div>", .recorded),
        ("br separates words", "<div class='alert alert-success'>Your attendance<br>in this session has been recorded.</div>", .recorded),
        ("blocks separate words", "<div class='alert alert-success'><p>Your attendance in this</p><p>session has been recorded.</p></div>", .recorded),
        ("hidden br stays joined", "<div class='alert alert-success'>您在此上課時段的出席已被<span hidden><br></span><span style='display:none'><br></span><br hidden><br style='display:none'><br aria-hidden='true'><br style='visibility:hidden'>記錄。</div>", .recorded),
        ("inline tags stay joined", "<div class='alert alert-success'>您在此<strong>上課</strong>時段的出席已被<span>記錄</span>。</div>", .recorded),
        ("expired notification outside main", "<div id='user-notifications'><div class='alert alert-danger'>QR Code 已過期</div></div><main id='region-main'>出缺席</main>", .expired),
        ("password notification outside main", "<div id='user-notifications'><div class='alert alert-danger'>密碼錯誤</div></div><main id='region-main'>出缺席</main>", .failed),
        ("already recorded outside main", "<div id='user-notifications'><div class='alert alert-info'>您的出缺席已經設置好了。</div></div><main id='region-main'>出缺席</main>", .alreadyRecorded),
    ]
    let expectedMessages = [
        "recorded with hidden Moodle chrome": "您在此上課時段的出席已被記錄。",
        "recorded whitespace collapses": "Your attendance in this session has been recorded.",
        "hidden error inside recorded alert": "您在此上課時段的出席已被記錄。",
        "drawers layout keeps main alert": "您在此上課時段的出席已被記錄。",
        "br separates words": "Your attendance in this session has been recorded.",
        "blocks separate words": "Your attendance in this session has been recorded.",
        "inline tags stay joined": "您在此上課時段的出席已被記錄。",
        "hidden br stays joined": "您在此上課時段的出席已被記錄。",
        "already recorded outside main": "您的出缺席已經設置好了。",
    ]
    let recordedURL = "https://euni.niu.edu.tw/mod/attendance/view.php?id=8"
    func next() {
        guard index < cases.count else {
            print("PASS: \(cases.count) WebKit HTML fixtures using production extraction and parser")
            exit(0)
        }
        webView.loadHTMLString(cases[index].1, baseURL: URL(string: original))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(extractionScript) { [self] value, error in
            precondition(error == nil, "DOM extraction failed")
            let data = (value as! String).data(using: .utf8)!
            let snapshot = try! JSONDecoder().decode(Parser.AttendancePageSnapshot.self, from: data)
            let response = Parser.AttendancePageSnapshot(url: cases[index].2 == .recorded ? recordedURL : original, body: snapshot.body,
                hasAttendanceForm: snapshot.hasAttendanceForm, notifications: snapshot.notifications,
                errorCodes: snapshot.errorCodes)
            let result = parser.makeAttendanceOutcome(from: response)
            precondition(result.kind == cases[index].2, "DOM fixture failed: \(cases[index].0)")
            if let expected = expectedMessages[cases[index].0] {
                precondition(result.message == expected,
                    "hidden or duplicated page text leaked in \(cases[index].0): \(result.message)")
            }
            index += 1
            next()
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let domChecks = MainActor.assumeIsolated {
    let checks = DOMChecks()
    checks.webView.navigationDelegate = checks
    checks.next()
    return checks
}
DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
    fputs("FAIL: WebKit fixture timeout\n", stderr)
    exit(1)
}
app.run()
'''
with tempfile.TemporaryDirectory(prefix="niu-attendance-test-") as directory:
    swift = Path(directory) / "main.swift"
    binary = Path(directory) / "check"
    swift.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(Path(tempfile.gettempdir()) / "niu-attendance-module-cache"),
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
