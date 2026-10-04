#!/usr/bin/env python3
"""Compile production batch state machine with synthetic services; never contact school or Keychain."""
from pathlib import Path
import subprocess
import tempfile
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

root = Path(__file__).resolve().parents[1]
state = {"posts": 0, "cookies": [], "delay_get": False, "delay_post": False, "gets": 0}
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def send(self, body, cookie=False):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        if cookie:
            self.send_header("Set-Cookie", "activity=old-session; Path=/")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def do_GET(self):
        path = urlparse(self.path)
        if path.path == "/control":
            for key, value in parse_qs(path.query).items():
                state[key] = value[0] == "1"
            return self.send(json.dumps(state))
        state["gets"] += 1
        state["cookies"].append(self.headers.get("Cookie", ""))
        if state["delay_get"]:
            time.sleep(0.4)
        if path.path.endswith("ApplyMe") and state.get("malformed", False):
            return self.send('<div class="col-md-11 col-md-offset-1 col-sm-10 col-xs-12 col-xs-offset-0"><div class="row enr-list-sec"><h3>incomplete fixture</h3></div></div>')
        if "/Apply/" in path.path:
            return self.send('<input name="__RequestVerificationToken" value="synthetic-token">')
        self.send('<div class="col-md-11 col-md-offset-1 col-sm-10 col-xs-12 col-xs-offset-0"></div>', cookie=True)
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        state["posts"] += 1
        if state["delay_post"]:
            time.sleep(0.4)
        self.send("synthetic pending response")

fixture = r'''
import Foundation
import Combine

@MainActor final class LoginRepository {
    static let shared = LoginRepository()
    func getSavedCredentials() -> (username: String, password: String)? { nil }
}
@MainActor final class Fake: EventRegistrationServing {
    var available = [EventBatchPreviewFixtures.event("1"), EventBatchPreviewFixtures.event("2"), EventBatchPreviewFixtures.event("3")]
    var applied: [EventData_Apply] = []
    var calls: [String] = []
    var reads = 0
    var readError = false
    var readHold = false
    var readGate: CheckedContinuation<[EventData], Error>?
    var gate: CheckedContinuation<EventActionOutcome, Error>?
    var hold = false
    var outcome: EventActionOutcome = .confirmed("verified")
    var throwTimeout = false
    var inFlight = 0
    var maxInFlight = 0
    func availableEvents() async throws -> [EventData] {
        reads += 1
        if readHold { return try await withCheckedThrowingContinuation { readGate = $0 } }
        return available
    }
    func appliedEvents() async throws -> [EventData_Apply] {
        reads += 1
        if readError { throw EventRegistrationError.offline }
        return applied
    }
    func register(eventID: String) async throws -> EventActionOutcome {
        calls.append(eventID)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if hold { return try await withCheckedThrowingContinuation { gate = $0 } }
        if throwTimeout { throw EventRegistrationError.timedOut }
        await Task.yield()
        return outcome
    }
    func release(_ outcome: EventActionOutcome = .confirmed("verified")) { gate?.resume(returning: outcome); gate = nil }
    func cancelRegistration(eventID: String) async throws -> EventActionOutcome { fatalError("unexpected mutation") }
    func registrationForm(eventID: String) async throws -> EventRegistrationForm { fatalError("unexpected form") }
    func modifyRegistration(eventID: String, form: EventRegistrationForm) async throws -> EventActionOutcome { fatalError("unexpected mutation") }
}
@MainActor enum Checks {
    static func expect(_ value: Bool, _ reason: String) { if !value { print("FAIL: \(reason)"); exit(1) } }
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        expect(false, "async operation did not settle")
    }
    static func model(_ fake: Fake, revision: UUID = UUID()) -> EventBatchRegistrationViewModel {
        EventBatchRegistrationViewModel(events: fake.available + fake.available, service: fake, sessionRevision: { revision })
    }
    static func ready(_ model: EventBatchRegistrationViewModel) async { model.check(); await until { model.phase == .ready } }

    static func clientChecks() async throws {
        let origin = URL(string: "http://127.0.0.1:" + ProcessInfo.processInfo.environment["PORT"]!)!
        func control(_ query: String = "") async throws -> [String: Any] {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "\(origin)/control?\(query)")!)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func waitForPosts(_ count: Int) async throws {
            for _ in 0..<500 {
                if try await control()["posts"] as? Int == count { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            expect(false, "POST boundary did not arrive")
        }
        var account = "synthetic-a"
        let client = EventRegistrationClient(origin: origin, credentials: { (account, "synthetic-only") })
        _ = try await client.availableEvents()
        _ = try await client.availableEvents()
        var snapshot = try await control()
        expect((snapshot["cookies"] as! [String]).last?.contains("activity=old-session") == true, "cookie fixture establishes initial session")
        let old = client.sessionRevision
        client.reset()
        expect(client.sessionRevision != old, "reset advances client session revision synchronously")
        account = "synthetic-b"
        _ = try await client.availableEvents()
        snapshot = try await control()
        expect((snapshot["cookies"] as! [String]).last == "", "replacement gets clean activity cookie store")

        _ = try await control("malformed=1")
        do { _ = try await client.appliedEvents(); expect(false, "malformed applied row must not become empty list") }
        catch { expect(error as? EventRegistrationError == .invalidResponse, "malformed applied read remains error") }
        _ = try await control("malformed=0")

        _ = try await control("delay_get=1")
        let read = Task { try await client.availableEvents() }
        try await Task.sleep(for: .milliseconds(30))
        let queued = Task { try await client.register(eventID: "1") }
        try await Task.sleep(for: .milliseconds(30))
        client.reset()
        _ = try? await read.value
        do { _ = try await queued.value; expect(false, "queued old-session mutation must cancel") }
        catch { expect(error is CancellationError, "queued old-session mutation throws cancellation") }
        snapshot = try await control("delay_get=0")
        expect(snapshot["posts"] as? Int == 0, "reset queue never reaches mutation boundary")

        let beforePost = Task { try await client.register(eventID: "1") }
        beforePost.cancel()
        do { _ = try await beforePost.value; expect(false, "cancel-before-send must throw") }
        catch { expect(error is CancellationError, "pre-boundary cancellation") }
        snapshot = try await control()
        expect(snapshot["posts"] as? Int == 0, "pre-boundary cancel cannot send POST")

        _ = try await control("delay_post=1")
        let afterPost = Task { try await client.register(eventID: "1") }
        try await waitForPosts(1)
        afterPost.cancel()
        let outcome = try await afterPost.value
        if case .uncertain = outcome {} else { expect(false, "post-boundary cancellation remains uncertain") }
        try await Task.sleep(for: .milliseconds(450))
        snapshot = try await control()
        expect(snapshot["posts"] as? Int == 1, "cancelled mutation never automatically resubmits")

        let swapped = Task { try await client.register(eventID: "2") }
        try await waitForPosts(2)
        client.reset(); account = "synthetic-c"
        do { _ = try await swapped.value; expect(false, "old-session result must not return into new session") }
        catch { expect(error is CancellationError, "old-session result fenced after POST") }
        print("PASS: client cookie isolation, revision, queued/logout cancellation, pre/post mutation boundary, no automatic resubmit")
    }
    static func run() async {
        let fake = Fake()
        let first = model(fake)
        first.confirm()
        expect(fake.calls.isEmpty, "idle confirmation cannot mutate")
        await ready(first)
        expect(fake.calls.isEmpty && fake.reads == 2, "both read-only lists complete before confirmation")
        expect(first.items.count == 3, "selected duplicate IDs removed")
        var refreshes = 0
        let refreshObserver = NotificationCenter.default.publisher(for: .didChangeEventRegistration).sink { _ in refreshes += 1 }
        defer { refreshObserver.cancel() }
        first.confirm(); first.confirm(); first.check()
        await until { first.phase == .finished }
        expect(fake.calls == ["1", "2", "3"] && fake.maxInFlight == 1, "strict sequential requests and double-start prevention")
        expect(refreshes == 3, "each completed item publishes refresh notification")
        first.confirm(); first.check()
        expect(fake.calls.count == 3, "completed batch cannot retry mutations")

        let reading = Fake(); reading.readHold = true
        var readRevision = UUID()
        let staleRead = EventBatchRegistrationViewModel(events: reading.available, service: reading, sessionRevision: { readRevision })
        staleRead.check(); await until { reading.readGate != nil }
        readRevision = UUID(); staleRead.sessionDidChange()
        reading.readGate?.resume(returning: reading.available); reading.readGate = nil
        await Task.yield()
        expect(staleRead.items.isEmpty && staleRead.phase == .sessionChanged && reading.reads == 1, "stale read cannot publish or proceed to next read")

        let dismissed = Fake(); dismissed.readHold = true
        let dismissedRead = model(dismissed)
        dismissedRead.check(); await until { dismissed.readGate != nil }
        dismissedRead.leave(); dismissed.readGate?.resume(returning: dismissed.available); dismissed.readGate = nil
        await Task.yield()
        expect(dismissedRead.items.isEmpty && dismissedRead.phase == .idle, "leaving cancels read publication")

        let missing = Fake()
        let missingModel = model(missing)
        missing.available = [missing.available[0], missing.available[0]]
        await ready(missingModel)
        expect(missingModel.eligibleCount == 0, "missing or duplicate server IDs excluded")

        let excluded = Fake()
        excluded.available = EventBatchPreviewFixtures.events
        excluded.applied = [EventBatchPreviewFixtures.applied(EventBatchPreviewFixtures.event("91004"))]
        let exclusion = model(excluded)
        await ready(exclusion)
        expect(exclusion.eligibleCount == 3 && exclusion.items.filter { !$0.eligibility.canSubmit }.count == 4, "already applied, closed, full, unopened excluded")
        exclusion.confirm(); await until { exclusion.phase == .finished }
        expect(excluded.calls == ["91001", "91002", "91003"], "only eligible IDs submitted")

        let errors = Fake(); errors.readError = true
        let retry = model(errors)
        retry.check(); await until { if case .failed = retry.phase { return true }; return false }
        expect(errors.calls.isEmpty && retry.items.isEmpty && !retry.canConfirm, "failed applied read never becomes an empty successful list")
        errors.readError = false
        await ready(retry)
        expect(errors.calls.isEmpty && errors.reads == 4, "retry performs reads only")

        let stopped = Fake(); stopped.hold = true
        let stop = model(stopped); await ready(stop); stop.confirm()
        await until { stopped.gate != nil }
        stop.stop(); expect(stop.isSubmitting, "stop waits for current request")
        stopped.release(); await until { stop.phase == .finished }
        expect(stopped.calls == ["1"], "stop prevents remaining requests")
        expect(stop.items[1].result == .notSent("已停止，沒有送出此活動。"), "unsubmitted reason retained")
        expect(stop.items[0].result == .confirmed("verified"), "current request result retained after stop")

        let leaving = Fake(); leaving.hold = true
        let leave = model(leaving); await ready(leave); leave.confirm()
        await until { leaving.gate != nil }; leave.leave(); leaving.release(.uncertain("unknown"))
        await until { leave.phase == .finished }
        expect(leaving.calls == ["1"] && leave.items[0].result == .uncertain("unknown"), "leaving keeps current outcome and stops next")

        for label in ["logout", "replaced login"] {
            let swapped = Fake(); swapped.hold = true
            var revision = UUID()
            let old = EventBatchRegistrationViewModel(events: swapped.available, service: swapped, sessionRevision: { revision })
            await ready(old); old.confirm(); await until { swapped.gate != nil }
            revision = UUID(); old.sessionDidChange()
            expect(old.items.isEmpty && old.phase == .sessionChanged, "\(label) clears old account UI immediately")
            swapped.release(); await until { swapped.inFlight == 0 }
            await Task.yield()
            expect(swapped.calls == ["1"] && old.items.isEmpty && old.phase == .sessionChanged, "\(label) ignores late result and never sends next")
        }
        let before = Fake(); var revision = UUID()
        let beforeConfirm = EventBatchRegistrationViewModel(events: before.available, service: before, sessionRevision: { revision })
        await ready(beforeConfirm); revision = UUID(); beforeConfirm.confirm()
        expect(before.calls.isEmpty && beforeConfirm.phase == .sessionChanged, "session replacement before confirmation cannot mutate")

        for outcome in [EventActionOutcome.rejected("school refusal"), .uncertain("unknown")] {
            let f = Fake(); f.outcome = outcome
            let state = model(f); await ready(state); state.confirm(); await until { state.phase == .finished }
            if case .rejected = outcome { expect(state.items[0].result == .rejected("school refusal"), "explicit school failure remains rejected") }
            else { expect(state.items[0].result == .uncertain("unknown"), "unverified response remains uncertain") }
        }
        let unknown = Fake(); unknown.throwTimeout = true
        let session = UUID()
        let timeout = model(unknown, revision: session); await ready(timeout); timeout.confirm()
        await until { timeout.phase == .finished }
        if case .uncertain = timeout.items[0].result {} else { expect(false, "timeout cannot be definite failure") }
        let reopened = model(unknown, revision: session); await ready(reopened)
        expect(reopened.eligibleCount == 0, "session uncertain registry survives reopening sheet")
        reopened.confirm(); expect(unknown.calls.count == 3, "uncertain IDs cannot immediately resend")
        NotificationCenter.default.post(name: .didChangeEventRegistrationSession, object: nil)
        let clearedSession = model(unknown, revision: session); await ready(clearedSession)
        expect(clearedSession.eligibleCount == 3, "session reset notification erases uncertain registry")
        let freshSession = model(unknown); await ready(freshSession)
        expect(freshSession.eligibleCount == 3, "uncertain registry does not leak to new session")

        let localized = EventBatchEligibility.registrationDates("2026/9/21上午08:00:00起\n2026/10/1下午12:00:00止")
        expect(localized.count == 2 && localized[1].duration == 1, "actual school Chinese AM/PM timestamps preserve seconds")
        var taipei = Calendar(identifier: .gregorian); taipei.timeZone = TimeZone(identifier: "Asia/Taipei")!
        expect(taipei.component(.hour, from: localized[1].start) == 12, "school afternoon 12 is noon")
        let midnight = EventBatchEligibility.registrationDates("2026/10/1 上午 12:00 ~ 2026/10/1 下午 06:00")
        expect(midnight.count == 2 && taipei.component(.hour, from: midnight[0].start) == 0 && taipei.component(.hour, from: midnight[1].start) == 18, "school midnight and evening converted")
        expect(!EventBatchEligibility.evaluate(EventBatchPreviewFixtures.event("1", people: "正取：27/27人\n備取：5/5人"), appliedIDs: [], uncertainIDs: [], now: Date()).canSubmit, "actual school regular plus standby full excludes")
        expect(EventBatchEligibility.evaluate(EventBatchPreviewFixtures.event("1", people: "正取：27/27人\n備取：0/5人"), appliedIDs: [], uncertainIDs: [], now: Date()).canSubmit, "available standby places remain eligible")
        let dates = EventBatchEligibility.registrationDates("2026/10/0408:00起\n2026/10/0417:00止")
        expect(dates.count == 2, "scraper compact timestamps parsed")
        let day = EventBatchEligibility.registrationDates("2026/10/04 ~ 2026/10/04")
        expect(day.count == 2 && day[1].duration == 86400, "date-only source precision retained")
        expect(EventBatchEligibility.registrationDates("2026/02/30 ~ 2026/03/01").isEmpty, "invalid dates stay unknown")
        expect(EventBatchEligibility.registrationDates("2026/10/05 ~ 2026/10/04").isEmpty, "reversed dates stay unknown")
        let event = EventBatchPreviewFixtures.event("1", dates: "2026/10/0408:00起\n2026/10/0417:00止")
        expect(!EventBatchEligibility.evaluate(event, appliedIDs: [], uncertainIDs: [], now: dates[0].start.addingTimeInterval(-1)).canSubmit, "not yet open")
        expect(EventBatchEligibility.evaluate(event, appliedIDs: [], uncertainIDs: [], now: dates[1].start.addingTimeInterval(30)).canSubmit, "minute precision does not invent deadline seconds")
        expect(!EventBatchEligibility.evaluate(event, appliedIDs: [], uncertainIDs: [], now: dates[1].end).canSubmit, "definitely past published minute excluded")
        expect(EventBatchEligibility.evaluate(EventBatchPreviewFixtures.event("1", people: "30人\n80人"), appliedIDs: [], uncertainIDs: [], now: Date()).canSubmit, "unlabelled counts not guessed")
        expect(!EventBatchEligibility.evaluate(EventBatchPreviewFixtures.event("1", state: "未知"), appliedIDs: [], uncertainIDs: [], now: Date()).canSubmit, "unknown school state excluded")
        print("PASS: sequential, explicit confirmation, deduplication, exclusions, readonly retry, rejected/uncertain/timeout, stop/leave, logout/replaced session, uncertain resend fence, date precision")
    }
}
@main struct Main {
    static func main() {
        Task { @MainActor in
            await Checks.run()
            do { try await Checks.clientChecks(); exit(0) }
            catch { print("FAIL: client regression: \(error)"); exit(1) }
        }
        RunLoop.main.run()
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-event-batch-") as directory:
    folder = Path(directory)
    source = folder / "Checks.swift"
    source.write_text(fixture)
    binary = folder / "checks"
    sources = ["Models/EventRegistrationModels.swift", "Services/EventRegistrationClient.swift",
               "ViewModels/EventRegistrationViewModel.swift", "Batch/EventBatchEligibility.swift",
               "Batch/EventBatchRegistrationViewModel.swift", "Batch/EventBatchPreviewFixtures.swift"]
    subprocess.run(["xcrun", "swiftc", "-DDEBUG", "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", str(folder / "ModuleCache"),
                    *[str(root / "Features/EventRegistration" / p) for p in sources],
                    str(source), "-o", str(binary)], check=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run([str(binary)], check=True, timeout=60,
                       env={**os.environ, "PORT": str(server.server_address[1])})
    finally:
        server.shutdown()
