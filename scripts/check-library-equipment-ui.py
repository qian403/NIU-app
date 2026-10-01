#!/usr/bin/env python3
"""Verify the real equipment SwiftUI view and WK scripts in an isolated simulator app.

All responses are synthetic and WK fetch is replaced in memory; no school or Keychain access.
Usage: python3 scripts/check-library-equipment-ui.py --device <booted simulator UDID>
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
parser.add_argument("--screenshot", default="/private/tmp/niu-equipment-ui.png")
parser.add_argument("--dark", action="store_true")
parser.add_argument("--large-text", action="store_true")
parser.add_argument("--records", action="store_true", help="Show synthetic reservation cards for visual QA")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
bundle = "dev.chien.niuapp.equipment-fixture"
service = (root / "Features/Library/LibraryEquipmentService.swift").read_text()
protocol = service[service.index("@MainActor\nprotocol"):service.index("@MainActor\nfinal class")]
javascript = service[service.index("nonisolated enum LibraryEquipmentJavaScript"):service.index("nonisolated enum LibraryEquipmentQueries")]
fixture = r'''
import SwiftUI
import WebKit
@MainActor enum StorageKeys {
    static let username = "synthetic-account"
    static let authSessionID = "synthetic-session"
}
@MainActor final class LoginRepository {
    static let shared = LoginRepository()
    func getSavedCredentials() -> (username: String, password: String)? { fatalError("Keychain forbidden") }
}
struct User { let username: String }
@MainActor final class AppState: ObservableObject {
    @Published var isAuthenticated = true
    @Published var currentUser: User? = User(username: "synthetic")
}
@MainActor final class LibraryEquipmentService: LibraryEquipmentServing {
    var webView: WKWebView?
    var onWebViewCreated: ((WKWebView) -> Void)?
    var connections = 0
    var records: [LibraryEquipmentReservation] = []
    let group = LibraryEquipmentGroup(id: 5, name: "宜思智慧小間（測試）", timeType: 0, total: 1, available: 1)
    let item = LibraryEquipmentItem(id: 56, name: "iSmart 504（測試）")
    func connect(account: String, password: String?) async throws {
        connections += 1
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        webView = view
        onWebViewCreated?(view)
        view.loadHTMLString(Self.html, baseURL: URL(string: "https://webpacx.niu.edu.tw"))
        for _ in 0..<100 {
            if !view.isLoading { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw connections == 1 ? LibraryEquipmentError.unavailable : LibraryEquipmentError.loginRequired
    }
    func resumeLogin() async throws {}
    func groups() async throws -> [LibraryEquipmentGroup] { [group] }
    func schedule(groupID: Int, date: Date) async throws -> LibraryEquipmentSchedule {
        LibraryEquipmentSchedule(equipment: [item], occupied: [
            LibraryEquipmentInterval(equipmentID: 56,
                start: LibraryEquipmentDate.at(600, on: date), end: LibraryEquipmentDate.at(660, on: date))
        ])
    }
    func policy(groupID: Int, equipmentID: Int, date: Date) async throws -> LibraryEquipmentPolicy {
        LibraryEquipmentPolicy(minimumHours: 1, maximumHours: 4, remainingHours: 28,
                               openMinute: 480, closeMinute: 1290)
    }
    func reservations() async throws -> [LibraryEquipmentReservation] { records }
    func reserve(_ draft: LibraryEquipmentDraft) async throws {
        records = [LibraryEquipmentReservation(id: 901, equipmentID: draft.equipment.id,
            equipmentName: draft.equipment.name, start: draft.start, end: draft.end, keepUntil: nil)]
    }
    func cancelReservation(_ reservation: LibraryEquipmentReservation) async throws { records = [] }
    func close() { webView?.stopLoading(); webView = nil }
    static let html = #"""
    <!doctype html><meta charset="utf-8"><h1>圖書館登入測試</h1>
    <label>帳號<input id="logxinid"></label><label>密碼<input id="pincode" type="password"></label>
    <input id="captcha"><input type="submit" value="登入" onclick="window.submitted=true">
    <script>
    window.readerCode='synthetic';
    window.fetch=async (path,options)=>{
      if(path==='/equipment') return {
        ok:true,text:async()=>'<script id="__NEXT_DATA__" type="application/json">'+
        JSON.stringify({props:{pageProps:{auth:true,session:{readerCode:window.readerCode,csrfToken:'fixture-token'}}}})+
        '<'+'/script>'
      };
      window.requestOptions=options;
      return {status:200,text:async()=>JSON.stringify({data:{fixture:true}})};
    };
    </script>
    """#
}
struct CheckFailure: Error { let reason: String }
@main struct FixtureApp: App {
    @StateObject private var appState = AppState()
    private let service: LibraryEquipmentService
    private let model: LibraryEquipmentViewModel
    init() {
        let service = LibraryEquipmentService()
        self.service = service
        model = LibraryEquipmentViewModel(service: service, currentAccount: { "synthetic" },
            currentSession: { "fixture" }, password: { _ in nil })
    }
    var body: some Scene {
        WindowGroup {
            NavigationStack { LibraryEquipmentView(model: model) }
                .environmentObject(appState)
                .preferredColorScheme(FIXTURE_COLOR)
                .dynamicTypeSize(FIXTURE_TYPE)
                .task { await check() }
        }
    }
    private func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw CheckFailure(reason: reason) }
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw CheckFailure(reason: "UI state timed out")
    }
    private func script(_ web: WKWebView, _ source: String, _ arguments: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
    }
    private func resetScreenshotScroll() {
        func reset(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.bounds.height > 100 {
                scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            }
            view.subviews.forEach(reset)
        }
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).forEach(reset)
    }
    private func alertTitle() -> String? {
        func find(_ controller: UIViewController) -> String? {
            if let alert = controller as? UIAlertController { return alert.title }
            if let presented = controller.presentedViewController, let title = find(presented) { return title }
            return controller.children.compactMap(find).first
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).compactMap(\.rootViewController).compactMap(find).first
    }
    private func check() async {
        var result: [String: String]
        var stage = "mount"
        do {
            try await waitFor { !model.isLoading && model.errorMessage != nil && model.webView?.window != nil }
            try require(!model.needsLogin, "Initial network failure with an existing WK is not required login")
            let failedBrowser = model.webView
            model.refresh()
            stage = "reconnect"
            try await waitFor { model.needsLogin && model.webView?.window != nil }
            guard let web = model.webView else { throw CheckFailure(reason: "Missing mounted browser") }
            try require(web !== failedBrowser && failedBrowser?.superview == nil,
                        "Reconnect must detach the prior browser from its container")
            stage = "visible layout"
            try await waitFor { web.bounds.width > 300 && web.bounds.height > 300 }
            try require(web.alpha == 1 && !web.isHidden, "Required login must be visible")
            stage = "CAPTCHA"
            let interactive = try await script(web, LibraryEquipmentJavaScript.login,
                ["account": "synthetic", "password": "fixture-password", "requestID": "login"])
            try require(interactive as? String == "interactive", "CAPTCHA must require manual login")
            let values = try await web.evaluateJavaScript("[document.querySelector('#logxinid').value,document.querySelector('#pincode').value]")
            try require(values as? [String] == ["synthetic", ""], "Do not fill password across CAPTCHA")
            _ = try await web.evaluateJavaScript("document.querySelector('#captcha').remove()")
            let submitted = try await script(web, LibraryEquipmentJavaScript.login,
                ["account": "synthetic", "password": "fixture-password", "requestID": "login2"])
            try require(submitted as? String == "submitted", "Normal login must submit school's form")
            for code in ["synthetic", "other", ""] {
                _ = try await script(web, "window.readerCode = code; return '';",
                    ["code": code])
                let auth = try await script(web, LibraryEquipmentJavaScript.authentication,
                    ["account": "synthetic", "requestID": "auth"])
                let object = try JSONSerialization.jsonObject(with: Data((auth as! String).utf8)) as! [String: Any]
                try require(object["authenticated"] as? Bool == (code == "synthetic"),
                            "Missing/mismatched school account must be rejected")
            }
            _ = try await script(web, LibraryEquipmentJavaScript.request,
                ["path": "/api/HyLibWS/graphql", "body": #"{"fixture":true}"#,
                 "csrf": "fixture-token", "requestID": "query"])
            let sent = try await web.evaluateJavaScript("requestOptions.method==='POST' && requestOptions.credentials==='include' && requestOptions.headers['X-CSRF-Token']==='fixture-token' && window.__niuEquipmentRequests.size===0")
            try require(sent as? Bool == true, "POST/CSRF/cookies/controller cleanup")
            model.resumeLogin()
            stage = "native data"
            try await waitFor { model.policy != nil && !model.isLoading && !model.needsLogin }
            stage = "native mount"
            try await waitFor { web.window != nil && web.bounds.width < 5 }
            try require(model.webView === web && service.connections == 2,
                        "Manual-to-native transition must retain the same session browser")
            model.select(date: LibraryEquipmentDate.parse("2099/10/01 00:00")!)
            stage = "selection"
            try await waitFor { !model.isLoading && model.policy != nil }
            try require(model.selectedStartMinute == nil, "Screen must ask for a start time")
            model.selectStart(480)
            try require(model.maximumDuration == 120, "Slider must stop at the next occupied interval")
            model.setDuration(90)
            try require(model.selectedTimeLabel == "08:00–09:30", "Duration changes must update the full selected interval")
            model.prepareConfirmation()
            stage = "confirmation"
            try await waitFor { model.confirmation != nil }
            try require(model.confirmation?.equipment.id == 56, "Native confirmation uses selected equipment")
            try await Task.sleep(for: .milliseconds(500))
            model.submit()
            stage = "success alert"
            try await waitFor { alertTitle() == "預約完成" }
            model.dismissCompletion()
            try await waitFor { alertTitle() == nil }
            try await Task.sleep(for: .milliseconds(500))
            guard let record = model.reservations.first else { throw CheckFailure(reason: "Missing synthetic reservation") }
            model.cancel(record)
            stage = "cancel alert"
            try await waitFor { alertTitle() == "已取消預約" }
            model.dismissCompletion()
            try await waitFor { alertTitle() == nil }
            if FIXTURE_RECORDS {
                let day = LibraryEquipmentDate.parse("2099/10/01 00:00")!
                service.records = [
                    LibraryEquipmentReservation(id: 910, equipmentID: 56, equipmentName: "iSmart 504（測試）",
                        start: LibraryEquipmentDate.at(480, on: day), end: LibraryEquipmentDate.at(570, on: day), keepUntil: LibraryEquipmentDate.at(490, on: day)),
                    LibraryEquipmentReservation(id: 911, equipmentID: 57, equipmentName: "大型討論室（測試）",
                        start: LibraryEquipmentDate.at(780, on: day), end: LibraryEquipmentDate.at(900, on: day), keepUntil: nil)
                ]
                model.refresh()
                try await waitFor { !model.isLoading && model.reservations.count == 2 }
                model.reservationQuery = "iSmart"
                try require(model.filteredReservations.count == 1, "Search filters synthetic cards")
                model.resetReservationFilters()
            }
            try await Task.sleep(for: .milliseconds(500))
            resetScreenshotScroll()
            try await Task.sleep(for: .milliseconds(200))
            result = ["status": "passed", "checks": "first-load failure with mounted WK/reconnect, old browser detachment, visible login, CAPTCHA interaction, school's input events, strict session account check, WK POST/CSRF, request cleanup, native confirmation, visible booking/cancellation success alerts, reservation search/cards"]
        } catch {
            result = ["status": "failed", "reason": "\(stage): \(error); needsLogin=\(model.needsLogin), loading=\(model.isLoading), browser=\(model.webView != nil), window=\(model.webView?.window != nil), bounds=\(String(describing: model.webView?.bounds))"]
        }
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("result.json")
        do { try JSONSerialization.data(withJSONObject: result).write(to: output) }
        catch { print("Fixture result unavailable") }
    }
}
'''

def run(*command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix="niu-equipment-ui-") as directory:
    folder = Path(directory)
    app = folder / "EquipmentChecks.app"
    app.mkdir()
    source = folder / "Checks.swift"
    rendered_fixture = fixture.replace("FIXTURE_COLOR", ".dark" if args.dark else ".light")
    rendered_fixture = rendered_fixture.replace("FIXTURE_TYPE", ".accessibility2" if args.large_text else ".large")
    rendered_fixture = rendered_fixture.replace("FIXTURE_RECORDS", "true" if args.records else "false")
    source.write_text("import WebKit\n" + protocol + javascript + rendered_fixture)
    (app / "Info.plist").write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier=bundle, CFBundleName="EquipmentChecks", CFBundleExecutable="EquipmentChecks",
        CFBundlePackageType="APPL", CFBundleVersion="1", CFBundleShortVersionString="1.0",
        MinimumOSVersion="26.0", LSRequiresIPhoneOS=True, UIDeviceFamily=[1, 2], UILaunchScreen={}
    )))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    files = [root / "Features/Library" / f"LibraryEquipment{name}.swift"
             for name in ["Models", "ViewModel", "Components", "BookingViews", "ReservationViews"]]
    view = folder / "LibraryEquipmentView.swift"
    view_source = (root / "Features/Library/LibraryEquipmentView.swift").read_text()
    if args.records:
        view_source = view_source.replace("@State private var showReservations = false", "@State private var showReservations = true")
    view.write_text(view_source)
    files.append(view)
    run("xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "5", "-sdk", sdk, "-target", "arm64-apple-ios26.0-simulator",
        "-parse-as-library", "-module-cache-path", str(folder / "ModuleCache"),
        *map(str, files), str(root / "Shared/Theme/Theme.swift"), str(source),
        "-o", str(app / "EquipmentChecks"))
    run("codesign", "--force", "--sign", "-", str(app), stdout=subprocess.DEVNULL)
    run("xcrun", "simctl", "install", args.device, str(app))
    container = Path(subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", args.device, bundle, "data"], text=True).strip())
    output = container / "Documents/result.json"
    output.unlink(missing_ok=True)
    run("xcrun", "simctl", "launch", args.device, bundle)
    try:
        deadline = time.monotonic() + 40
        while not output.exists() and time.monotonic() < deadline:
            time.sleep(0.25)
        if not output.exists():
            raise RuntimeError("Equipment UI fixture did not return a result")
        result = json.loads(output.read_text())
        run("xcrun", "simctl", "io", args.device, "screenshot", args.screenshot, stdout=subprocess.DEVNULL)
        if result["status"] != "passed":
            raise RuntimeError(result)
        print("PASS: " + result["checks"])
        print("Screenshot: " + args.screenshot)
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", args.device, bundle], check=False, capture_output=True)
