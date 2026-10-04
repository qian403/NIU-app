#!/usr/bin/env python3
"""Drive the production EventRegistrationClient in a real WKWebView against a local synthetic
activity system: sign-in retries, shared sign-in, session expiry, and verified outcomes for
registration, cancellation and edits. No school servers, Keychain or real accounts are used."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import html
import json
import secrets
import subprocess
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[1]
ACCOUNT, PASSWORD = "synthetic", "fixture+pass&1"
state = {
    "sessions": set(), "applied": {}, "login_posts": 0, "apply_posts": 0, "empty_login_pages": 0,
    "register_mode": "normal", "forms": {},
    "slow_images": False, "images_finished": 0,
    "slow_html": False, "slow_html_started": 0,
}
lock = threading.Lock()


def table(detail):
    rows = [("活動類別", "講座"), ("活動對象", "本校在校生"), ("活動名稱", "x"), ("活動說明", detail),
            ("費用", "免費"), ("聯絡資訊", "王小明<br>03-1234567<br>test@example.com"),
            ("相關連結", "https://example.com"), ("備註", "無"), ("多元認證", "已認證，服務學習"),
            ("報名時間", "2099/10/01 08:00 ~ 2099/10/09 17:00")]
    return "<table class='table'>" + "".join(f"<tr><td>{k}</td><td>{v}</td></tr>" for k, v in rows) + "</table>"


def event_row(event_id, name, extra=""):
    return f"""
    <div class="row enr-list-sec">
      <h3>{name}</h3>
      <div class="col-sm-3 text-center enr-list-dep-nam hidden-xs" title="主辦單位：資訊中心"></div>
      <span class="badge alert-danger">報名中</span>
      <p>活動編號：{event_id} 詳細</p>
      <div><i class="fa-id-badge"></i>本校在校生</div>
      <div><i class="fa-calendar"></i>2099/10/10 10:00 ~ 2099/10/10 12:00</div>
      <div><i class="fa-map-marker"></i>綜合大樓</div>
      <div><i class="fa-user-plus"></i>30，10</div>
      {extra}
      {table("說明 " + name)}
    </div>"""


def page(body):
    image = "<img src='/slow-image'>" if state["slow_images"] else ""
    return f"<!doctype html><html><head><meta charset='utf-8'></head><body>{body}{image}</body></html>"


def list_page(rows, states=""):
    return page(f"{states}<div class='col-md-11 col-md-offset-1 col-sm-10 col-xs-12 col-xs-offset-0'>{rows}</div>")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def session(self):
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            name, _, value = part.strip().partition("=")
            if name == "sid" and value in state["sessions"]:
                return value
        return None

    def send(self, status, body="", headers=None):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # The client may navigate away without waiting for the synthetic image.

    def redirect(self, location, cookie=None):
        headers = {"Location": location}
        if cookie:
            headers["Set-Cookie"] = cookie
        self.send(302, "", headers)

    def login_page(self, message=""):
        with lock:
            if state["empty_login_pages"] > 0:
                state["empty_login_pages"] -= 1
                return self.send(200, page(""))
        self.send(200, page(f"""
            <div class="validation-summary-errors">{message}</div>
            <form method="post" action="/MvcTeam/Account/Login">
              <input type="text" name="Account" id="Account"><input type="password" name="Password" id="Password">
              <input type="submit" value="登入">
            </form>"""))

    def form_fields(self):
        length = int(self.headers.get("Content-Length", "0"))
        return {k: v[0] for k, v in parse_qs(self.rfile.read(length).decode(), keep_blank_values=True).items()}

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/slow-image":
            time.sleep(2)
            with lock:
                state["images_finished"] += 1
            return self.send(200, "")
        if path == "/__control":
            query = {k: v[0] for k, v in parse_qs(url.query).items()}
            with lock:
                if query.get("expire"):
                    state["sessions"].clear()
                if "empty" in query:
                    state["empty_login_pages"] = int(query["empty"])
                if "register" in query:
                    state["register_mode"] = query["register"]
                if "js_redirect" in query:
                    state["js_redirect"] = query["js_redirect"] == "1"
                if "settle" in query:
                    state["applied"][query["settle"]] = "已報名"
                if "slow_images" in query:
                    state["slow_images"] = query["slow_images"] == "1"
                if "slow_html" in query:
                    state["slow_html"] = query["slow_html"] == "1"
                snapshot = {k: (sorted(v) if isinstance(v, set) else v) for k, v in state.items() if k != "sessions"}
            return self.send(200, json.dumps(snapshot, ensure_ascii=False))
        if path.startswith("/MvcTeam/Account/Login"):
            return self.login_page()
        if not self.session():
            return self.redirect("/MvcTeam/Account/Login?ReturnUrl=" + path)
        if path == "/MvcTeam/Act":
            if state.get("js_redirect") and "replacement=1" not in url.query:
                return self.send(200, page("<script>location.replace('/MvcTeam/Act?replacement=1')</script><img src='/slow-image'>"))
            with lock:
                slow_html = state["slow_html"]
                if slow_html:
                    state["slow_html_started"] += 1
            if slow_html:
                time.sleep(0.5)
            rows = event_row("12345", "Swift 工作坊") + event_row("22222", "攝影講座") + event_row("33333", "寫作營")
            return self.send(200, list_page(rows))
        if path == "/MvcTeam/Act/ApplyMe":
            with lock:
                applied = dict(state["applied"])
            rows = "".join(event_row(i, f"活動 {i}", "<a class='btn btn-danger'>進行中</a>") for i in applied)
            states = "".join(f"<div class='row bg-warning'><span class='text-danger text-shadow'>報名狀態：{s}</span></div>"
                             for s in applied.values())
            return self.send(200, list_page(rows, states))
        if path.startswith("/MvcTeam/Act/Apply/"):
            return self.send(200, page(f"""<form method="post"><input type="hidden" name="__RequestVerificationToken"
                value="tok+en/1="><input type="submit" name="action" value="我要報名"></form>"""))
        if path.startswith("/MvcTeam/Act/RegData/"):
            event_id = path.rsplit("/", 1)[1]
            with lock:
                saved = state["forms"].get(event_id, {"SignTEL": "0900000000", "SignEmail": "a@example.com",
                                                      "SignMemo": "", "Food": "3", "Proof": "1"})
            radios = lambda name, values: "".join(
                f"<input type='radio' name='{name}' value='{v}' {'checked' if saved[name] == v else ''}>" for v in values)
            return self.send(200, page(f"""
                <form method="post" action="/MvcTeam/Act/RegData/{event_id}">
                  <input type="hidden" name="__RequestVerificationToken" value="tok+en/1=">
                  <input type="hidden" name="SignId" value="{event_id}"><input type="hidden" name="ApplyId" value="{event_id}">
                  <label>姓名</label><span>測試生</span><div>B1234567</div>
                  <input name="SignTEL" value="{html.escape(saved['SignTEL'], quote=True)}">
                  <input name="SignEmail" value="{html.escape(saved['SignEmail'], quote=True)}">
                  <textarea name="SignMemo">{html.escape(saved['SignMemo'])}</textarea>
                  {radios('Food', '123')}{radios('Proof', '123')}
                  <input type="submit" name="action" value="儲存修改">
                  <input type="submit" name="action" value="取消報名" onclick="return confirm('確定取消報名？')">
                </form>"""))
        self.send(404, page("not found"))

    def do_POST(self):
        path = urlparse(self.path).path
        fields = self.form_fields()
        if path == "/MvcTeam/Account/Login":
            with lock:
                state["login_posts"] += 1
            if fields.get("Account") == ACCOUNT and fields.get("Password") == PASSWORD:
                sid = secrets.token_hex(8)
                with lock:
                    state["sessions"].add(sid)
                return self.redirect("/MvcTeam/Act", f"sid={sid}; Path=/")
            return self.login_page("帳號或密碼錯誤")
        if not self.session():
            return self.redirect("/MvcTeam/Account/Login")
        if path.startswith("/MvcTeam/Act/Apply/"):
            event_id = path.rsplit("/", 1)[1]
            with lock:
                state["apply_posts"] += 1
                mode = state["register_mode"]
            if fields.get("__RequestVerificationToken") != "tok+en/1=" or fields.get("id") != event_id:
                return self.send(400, page("<div class='alert-danger'>表單錯誤</div>"))
            if mode == "reject":
                return self.send(200, page("<div class='validation-summary-errors'>報名失敗：名額已滿</div>"))
            if mode == "silent":
                return self.send(200, page("處理中"))
            with lock:
                state["applied"][event_id] = "已報名"
            if mode == "server-error":
                return self.send(500, page("Server Error"))
            return self.redirect("/MvcTeam/Act/ApplyMe")
        if path.startswith("/MvcTeam/Act/RegData/"):
            event_id = path.rsplit("/", 1)[1]
            if fields.get("action") == "取消報名":
                with lock:
                    state["applied"].pop(event_id, None)
                return self.redirect("/MvcTeam/Act/ApplyMe")
            with lock:
                state["forms"][event_id] = {k: fields.get(k, "") for k in ["SignTEL", "SignEmail", "SignMemo", "Food", "Proof"]}
            return self.redirect(f"/MvcTeam/Act/RegData/{event_id}")
        self.send(404, page("not found"))


fixture = r'''
import Foundation
import WebKit

@MainActor final class LoginRepository {
    static let shared = LoginRepository()
    func getSavedCredentials() -> (username: String, password: String)? {
        fatalError("Keychain access is forbidden in this fixture")
    }
}

@MainActor enum Checks {
    static let origin = URL(string: "http://127.0.0.1:" + ProcessInfo.processInfo.environment["PORT"]!)!

    static func control(_ query: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(origin)/__control?\(query)")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func client(password: String = "fixture+pass&1") -> EventRegistrationClient {
        EventRegistrationClient(origin: origin, dataStore: .nonPersistent(),
                                credentials: { ("synthetic", password) })
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    static func run() async throws {
        let shared = client()
        _ = try await control("empty=1")
        async let available = shared.availableEvents()
        async let applied = shared.appliedEvents()
        let (events, records) = try await (available, applied)
        var state = try await control("")
        expect(events.map(\.eventSerialID) == ["12345", "22222", "33333"], "available list decoded")
        expect(events.first?.department == "資訊中心" && events.first?.contactInfoTel == "03-1234567", "available fields")
        expect(records.isEmpty, "applied list starts empty")
        expect(state["login_posts"] as? Int == 1, "two concurrent tabs share one sign-in, rendering retry included")

        _ = try await control("expire=1")
        _ = try await shared.availableEvents()
        state = try await control("")
        expect(state["login_posts"] as? Int == 2, "expired session signs in again quietly")

        _ = try await control("js_redirect=1")
        let redirected = try await shared.availableEvents()
        expect(redirected.count == 3, "superseding JavaScript main-frame navigation completes within the same read")
        _ = try await control("js_redirect=0")
        _ = try await control("slow_html=1")
        try await shared.checkLateUnknownNavigation()
        _ = try await control("slow_html=0")
        state = try await control("")
        expect(state["login_posts"] as? Int == 2, "replacing explicit-load views preserves the authenticated cookie store")
        try shared.checkNavigationReplacement()
        print("PASS: JS main-frame replacement, -999/102 replacement, old revision/session callback fencing")

        let registered = try await shared.register(eventID: "12345")
        guard case .confirmed(let message) = registered, message.contains("已報名") else {
            return expect(false, "registration verified from applied list: \(registered)")
        }
        let again = try await shared.register(eventID: "12345")
        state = try await control("")
        guard case .confirmed = again, state["apply_posts"] as? Int == 1 else {
            return expect(false, "an existing registration is not submitted twice")
        }

        _ = try await control("register=reject")
        let rejected = try await shared.register(eventID: "22222")
        guard case .rejected(let reason) = rejected, reason.contains("名額已滿") else {
            return expect(false, "school failure is reported as rejected: \(rejected)")
        }
        _ = try await control("register=silent")
        let silent = try await shared.register(eventID: "22222")
        guard case .uncertain = silent else { return expect(false, "an unverifiable response is never success: \(silent)") }
        _ = try await shared.appliedEvents()
        expect(EventRegistrationSubmission.shared.blockedIDs(session: shared.sessionRevision).contains("22222"), "fresh absence retains uncertainty for school lag")
        _ = try await control("settle=22222")
        _ = try await shared.appliedEvents()
        expect(!EventRegistrationSubmission.shared.blockedIDs(session: shared.sessionRevision).contains("22222"), "fresh registered row resolves same-session uncertainty")
        _ = try await shared.cancelRegistration(eventID: "22222")
        print("PASS: fresh applied read resolves registered uncertainty; absence retains reservation")
        _ = try await control("register=server-error")
        let serverError = try await shared.register(eventID: "33333")
        guard case .confirmed = serverError else {
            return expect(false, "a saved registration is confirmed despite an error page: \(serverError)")
        }
        _ = try await control("register=normal")

        var form = try await shared.registrationForm(eventID: "12345")
        expect(form.name == "測試生" && form.studentID == "B1234567" && form.food == "3", "registration form decoded")
        form.tel = "+886 912&345"
        form.memo = "a+b=c&d\n第二行"
        form.food = "2"
        form.proof = "3"
        let modified = try await shared.modifyRegistration(eventID: "12345", form: form)
        guard case .confirmed = modified else { return expect(false, "edit verified by reloading the form: \(modified)") }
        state = try await control("")
        let saved = (state["forms"] as? [String: [String: String]])?["12345"]
        expect(saved?["SignTEL"] == "+886 912&345" && saved?["SignMemo"] == "a+b=c&d\n第二行", "form encoding keeps + & =")

        let cancelled = try await shared.cancelRegistration(eventID: "12345")
        guard case .confirmed = cancelled else { return expect(false, "cancellation answers the confirm() and verifies: \(cancelled)") }
        let remaining = try await shared.appliedEvents()
        expect(!remaining.contains { $0.eventSerialID == "12345" }, "cancelled registration removed")

        state = try await control("")
        let posts = state["login_posts"] as! Int
        do {
            _ = try await client(password: "wrong").availableEvents()
            expect(false, "wrong password must fail")
        } catch {
            expect(error as? EventRegistrationError == .invalidCredentials, "wrong password reported: \(error)")
        }
        state = try await control("")
        expect(state["login_posts"] as? Int == posts + 1, "a rejected password is never resubmitted")

        let resetting = client()
        let pending = Task { try await resetting.availableEvents() }
        try await Task.sleep(for: .milliseconds(50))
        resetting.reset()
        do { _ = try await pending.value; expect(false, "reset must cancel") }
        catch { expect(error is CancellationError, "logout reset cancels in-flight work: \(error)") }

        let offline = EventRegistrationClient(origin: URL(string: "http://127.0.0.1:9")!, dataStore: .nonPersistent(),
                                              credentials: { ("synthetic", "x") })
        do { _ = try await offline.availableEvents(); expect(false, "unreachable server must fail") }
        catch { expect(error as? EventRegistrationError == .unavailable, "unreachable server is unavailable, not empty: \(error)") }

        // Real WebKit, main DOM available immediately but each image stalls for two seconds.
        // Before the fix the login + redirected list waited over four seconds for those images.
        _ = try await control("slow_images=1")
        let fast = client()
        let started = ContinuousClock.now
        let fastEvents = try await fast.availableEvents()
        let elapsed = started.duration(to: .now)
        state = try await control("")
        expect(fastEvents.count == 3, "document-ready path still parses the complete list")
        expect(state["images_finished"] as? Int == 0, "login and list must finish before delayed images")
        print("PERF: first login + activity list with two-second images: \(elapsed)")
        // Reuse the browser while old image loads finish; late callbacks must not satisfy a new read.
        let fastApplied = try await fast.appliedEvents()
        expect(fastApplied.contains { $0.eventSerialID == "33333" }, "next navigation reads its own applied list")
        do {
            _ = try await client(password: "wrong").availableEvents()
            expect(false, "document-ready must not accept a rejected login")
        } catch {
            expect(error as? EventRegistrationError == .invalidCredentials, "slow images do not hide login rejection")
        }
        // POSTs retain full navigation completion and verification, even with the faster read path.
        let slowRegistration = try await fast.register(eventID: "22222")
        guard case .confirmed = slowRegistration else {
            return expect(false, "slow resources cannot bypass registration verification")
        }
        _ = try await control("slow_html=1&slow_images=0")
        let cancelledRead = Task { try await fast.availableEvents() }
        var didStartSlowHTML = false
        for _ in 0..<100 {
            state = try await control("")
            if (state["slow_html_started"] as? Int ?? 0) > 0 { didStartSlowHTML = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        expect(didStartSlowHTML, "cancel fixture waits for a real pending main-document request")
        cancelledRead.cancel()
        do { _ = try await cancelledRead.value; expect(false, "pre-commit cancellation must fail") }
        catch { expect(error is CancellationError, "pre-commit cancellation remains cancellation") }
        // Let the old HTML response arrive before using the same client again.
        try await Task.sleep(for: .milliseconds(600))
        _ = try await control("slow_html=0")
        let afterCancellation = try await fast.appliedEvents()
        expect(afterCancellation.contains { $0.eventSerialID == "22222" }, "cancelled navigation cannot overwrite the next read")
        fast.reset()
        _ = try await control("slow_images=0")

        print("PASS: rendering retry, shared sign-in, quiet re-sign-in, verified register/duplicate/reject/uncertain/error-page, form encoding, confirm() cancellation, no password resubmission, logout cancellation, unreachable server")
    }
}

@main struct Main {
    static func main() {
        Task { @MainActor in
            do { try await Checks.run(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
        }
        RunLoop.main.run()
    }
}
'''

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="niu-event-registration-") as directory:
        folder = Path(directory)
        source = folder / "Checks.swift"
        source.write_text(fixture)
        client_source = folder / "EventRegistrationClient.swift"
        client_source.write_text((root / "Features/EventRegistration/Services/EventRegistrationClient.swift").read_text() + r'''

extension EventRegistrationClient {
    func checkLateUnknownNavigation() async throws {
        let oldView = try page()
        let tokens = WKWebView(frame: .zero)
        let unknown = tokens.loadHTMLString("<html></html>", baseURL: nil)!
        // Do not register unknown with didStart before the new load: its first
        // callback is precisely the missing-provenance race under test.
        let loading = Task { try await self.load(URLRequest(url: Checks.origin.appendingPathComponent("MvcTeam/Act"))) }
        for _ in 0..<100 {
            if let view = self.webView, view !== oldView, currentNavigation != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let view = self.webView, let current = currentNavigation else { fatalError("new navigation did not start") }
        precondition(view !== oldView && view.configuration.websiteDataStore === oldView.configuration.websiteDataStore)
        self.webView(oldView, didStartProvisionalNavigation: unknown)
        self.webView(oldView, didCommit: unknown)
        self.webView(oldView, didFinish: unknown)
        self.webView(oldView, didFailProvisionalNavigation: unknown, withError: URLError(.cancelled))
        precondition(currentNavigation === current && !navigationCompleted && documentReadyTask == nil,
                     "unknown old-page navigation cannot adopt, complete or cancel the new load")
        _ = try await loading.value
        precondition(navigationCompleted)
        tokens.stopLoading()
        print("PASS: delayed first callback from old page is fenced while explicit load preserves session cookies")
    }

    func checkNavigationReplacement() throws {
        let view = try page()
        let tokens = WKWebView(frame: .zero)
        func navigation() -> WKNavigation { tokens.loadHTMLString("<html></html>", baseURL: nil)! }
        prepareNavigation(acceptDocumentReady: true)
        let old = navigation()
        self.webView(view, didStartProvisionalNavigation: old)
        prepareNavigation(acceptDocumentReady: true)
        let first = navigation()
        self.webView(view, didStartProvisionalNavigation: first)
        self.webView(view, didStartProvisionalNavigation: old)
        self.webView(view, didFinish: old)
        precondition(currentNavigation === first && !navigationCompleted, "pre-prepare callbacks cannot finish or replace current navigation")
        for error in [NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), NSError(domain: "WebKitErrorDomain", code: 102)] {
            let previous = currentNavigation!
            self.webView(view, didCommit: previous)
            self.webView(view, didFailProvisionalNavigation: previous, withError: error)
            precondition(documentReadyTask == nil && !navigationCompleted)
            let next = navigation()
            self.webView(view, didStartProvisionalNavigation: next)
            self.webView(view, didFinish: previous)
            precondition(currentNavigation === next && !navigationCompleted, "cancelled load cannot finish replacement")
        }
        let previous = currentNavigation!
        self.webView(view, didCommit: previous)
        let replacement = navigation()
        self.webView(view, didStartProvisionalNavigation: replacement)
        precondition(currentNavigation === replacement && documentReadyTask == nil, "replacement cancels old document-ready polling")
        self.webView(view, didFail: previous, withError: URLError(.badServerResponse))
        precondition(!navigationCompleted)
        self.webView(view, didFinish: replacement)
        precondition(navigationCompleted, "replacement completes current read")
        tokens.stopLoading()
        reset()
        let freshView = try page()
        prepareNavigation(acceptDocumentReady: true)
        self.webView(view, didStartProvisionalNavigation: replacement)
        precondition(currentNavigation == nil && !navigationCompleted, "old session web view cannot be adopted")
        freshView.stopLoading()
    }
}
''')
        binary = folder / "checks"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(folder / "ModuleCache"),
            str(root / "Features/EventRegistration/Models/EventRegistrationModels.swift"),
            str(client_source),
            str(source), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=180,
                       env={"PORT": str(server.server_address[1]), "PATH": "/usr/bin:/bin"})
finally:
    server.shutdown()
