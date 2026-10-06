#!/usr/bin/env python3
"""Exercise daily update checks with isolated defaults and offline App Store fixtures."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import Foundation

final class FixtureProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var status = 200
    static var offline = false
    static var body = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct Checks {
    @MainActor static func main() async {
        for (candidate, installed, expected) in [
            ("1.10.0", "1.9.9", true), ("2.0", "1.99.99", true),
            ("1.1.1", "1.1.0", true), ("1.1", "1.1.0", false),
            ("1.1.0", "1.1", false), ("1.0.9", "1.1.0", false),
            ("1.1.0", "1.1.0", false), ("1..2", "1.0", false),
            ("latest", "1.0", false), ("", "1.0", false),
            ("2.0", "", false), ("2.0-beta", "1.0", false)
        ] {
            precondition(AppUpdateChecker.isNewer(candidate, than: installed) == expected)
        }
        let suite = "dev.chienniuapp.update-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        // One second before local midnight, not a rolling 24-hour interval.
        var date = ISO8601DateFormatter().date(from: "2026-10-03T15:59:59Z")!
        func checker() -> AppUpdateChecker {
            AppUpdateChecker(session: session, defaults: defaults, bundleID: "dev.chienniuapp",
                             currentVersion: "1.1.0", now: { date }, calendar: { calendar })
        }
        func response(version: String = "1.2.0", bundleID: String = "dev.chienniuapp",
                      url: String = "https://apps.apple.com/tw/app/niu-life/id6813616626") -> String {
            """
            {"results":[{"bundleId":"\(bundleID)","version":"\(version)","trackViewUrl":"\(url)"}]}
            """
        }
        FixtureProtocol.body = response()
        let first = checker()
        async let a: Void = first.checkIfNeeded()
        async let b: Void = first.checkIfNeeded()
        _ = await (a, b)
        precondition(FixtureProtocol.requests.count == 1, "overlapping activations must be deduplicated")
        precondition(first.availableUpdate?.version == "1.2.0")
        precondition(first.availableUpdate?.url.absoluteString == "https://apps.apple.com/tw/app/niu-life/id6813616626")
        let request = FixtureProtocol.requests[0]
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.contains(URLQueryItem(name: "bundleId", value: "dev.chienniuapp")))
        precondition(query.contains(URLQueryItem(name: "country", value: "tw")))
        precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
        first.dismissUpdate()
        await first.checkIfNeeded()
        precondition(first.availableUpdate == nil)
        let relaunched = checker()
        await relaunched.checkIfNeeded()
        precondition(FixtureProtocol.requests.count == 1, "dismissal and relaunch must preserve today's check")
        date = date.addingTimeInterval(1)
        await relaunched.checkIfNeeded()
        precondition(FixtureProtocol.requests.count == 2, "local midnight permits a new check")
        precondition(relaunched.availableUpdate != nil)
        // (body, status, offline, answered): an answered lookup ends the day; a failure may retry.
        let cases: [(String, Int, Bool, Bool)] = [
            (response(version: "1.1.0"), 200, false, true),
            (response(version: "1.0.0"), 200, false, true),
            (response(version: "invalid"), 200, false, true),
            (response(bundleID: "another.app"), 200, false, true),
            (response(url: "https://example.com/update"), 200, false, true),
            (response(url: "http://apps.apple.com/tw/app/test"), 200, false, true),
            ("{\"results\":[]}", 200, false, true),
            ("not json", 200, false, false),
            (response(), 503, false, false),
            (response(), 200, true, false)
        ]
        for (body, status, offline, answered) in cases {
            date = calendar.date(byAdding: .day, value: 1, to: date)!
            FixtureProtocol.body = body
            FixtureProtocol.status = status
            FixtureProtocol.offline = offline
            let next = checker()
            let count = FixtureProtocol.requests.count
            await next.checkIfNeeded()
            await next.checkIfNeeded()
            precondition(next.availableUpdate == nil, "invalid or non-newer listings must not prompt")
            precondition(FixtureProtocol.requests.count == count + (answered ? 1 : 2),
                         "only failed lookups are retried the same day")
        }
        // Failures retry on later activations, are capped per day, and the cap survives relaunch.
        date = calendar.date(byAdding: .day, value: 1, to: date)!
        FixtureProtocol.status = 200
        FixtureProtocol.offline = true
        var count = FixtureProtocol.requests.count
        let flaky = checker()
        for _ in 0..<5 { await flaky.checkIfNeeded() }
        await checker().checkIfNeeded()
        precondition(FixtureProtocol.requests.count == count + AppUpdateChecker.maxDailyAttempts,
                     "same-day failed attempts are capped, including across relaunches")
        // A retry that succeeds prompts and then ends the day.
        date = calendar.date(byAdding: .day, value: 1, to: date)!
        count = FixtureProtocol.requests.count
        let retried = checker()
        await retried.checkIfNeeded()
        FixtureProtocol.offline = false
        FixtureProtocol.body = response()
        await retried.checkIfNeeded()
        precondition(retried.availableUpdate != nil, "a same-day retry after a failure can prompt")
        retried.dismissUpdate()
        await checker().checkIfNeeded()
        precondition(FixtureProtocol.requests.count == count + 2, "a successful retry completes the day")
        date = calendar.date(byAdding: .day, value: 1, to: date)!
        FixtureProtocol.offline = false
        FixtureProtocol.body = response()
        let recovered = checker()
        await recovered.checkIfNeeded()
        precondition(recovered.availableUpdate != nil, "network failure must not suppress future days")
        print("PASS: numeric versions, concurrent checks, dismissal/relaunch, local midnight, lookup validation, same-day failure retry limit, offline recovery")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-app-update-") as directory:
    directory = Path(directory)
    fixture = directory / "Checks.swift"
    fixture.write_text(FIXTURE)
    binary = directory / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "ModuleCache"),
        str(ROOT / "Core/Services/AppUpdateChecker.swift"), str(fixture), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
