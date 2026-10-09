#!/usr/bin/env python3
"""Compile and exercise anonymous usage reporting with isolated defaults, an in-memory ID store and a fake URL protocol."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Core/Services/UsageHeartbeatClient.swift"
APP_STATE = ROOT / "Core/Models/AppState.swift"
ROOT_VIEW = ROOT / "App/RootView.swift"

app_state = APP_STATE.read_text()
# Login, restored login, foreground while signed in, and a day change while in the foreground.
assert app_state.count("Task { await UsageHeartbeatClient.shared.report() }") == 4
assert "func significantTimeChanged() {\n        guard isAuthenticated else { return }" in app_state
root_view = ROOT_VIEW.read_text()
assert "UIApplication.significantTimeChangeNotification" in root_view
assert "guard scenePhase == .active else { return }\n            appState.significantTimeChanged()" in root_view
assert "await UsageHeartbeatClient.shared.report()" not in app_state.replace(
    "Task { await UsageHeartbeatClient.shared.report() }", ""
)

FIXTURE = r'''
import Foundation

final class FixtureProtocol: URLProtocol {
    static var requests: [URLRequest] = []
	static var bodies: [Data] = []
    static var shouldFail = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
		Self.bodies.append(Self.readBody(from: request))
        if Self.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
	private static func readBody(from request: URLRequest) -> Data {
		if let body = request.httpBody { return body }
		guard let stream = request.httpBodyStream else { return Data() }
		stream.open()
		defer { stream.close() }
		var result = Data()
		var buffer = [UInt8](repeating: 0, count: 1024)
		while stream.hasBytesAvailable {
			let count = stream.read(&buffer, maxLength: buffer.count)
			if count <= 0 { break }
			result.append(buffer, count: count)
		}
		return result
	}
}

final class MemoryIDStore: UsageInstallationIDStore, @unchecked Sendable {
    // Test double only: the checks call it sequentially from one task.
    var value: String?
    var writable = true
    var writes = 0
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { value }
    func write(_ value: String) -> Bool {
        writes += 1
        guard writable else { return false }
        self.value = value
        return true
    }
}

@main struct Checks {
    static func main() async throws {
        let suite = "dev.chienniuapp.usage-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let isV4 = { (value: String) in UUID(uuidString: value) != nil && value == value.lowercased() && value.split(separator: "-")[2].first == "4" }

        // An existing device keeps its UUID when it moves from UserDefaults to the Keychain.
        let legacy = "3f1d0c3e-8b6a-4e0f-9d2c-1a5b7c9e0f42"
        defaults.set(legacy.uppercased(), forKey: UsageHeartbeatClient.installationKey)
        let migrated = MemoryIDStore()
        precondition(UsageHeartbeatClient.installationID(store: migrated, defaults: defaults) == legacy)
        precondition(migrated.value == legacy)
        precondition(defaults.string(forKey: UsageHeartbeatClient.installationKey) == nil, "legacy copy must be removed after migration")
        precondition(UsageHeartbeatClient.installationID(store: migrated, defaults: defaults) == legacy)
        precondition(migrated.writes == 1)

        // Without a usable Keychain the value stays in UserDefaults instead of changing every launch.
        let locked = MemoryIDStore()
        locked.writable = false
        let fallback = UsageHeartbeatClient.installationID(store: locked, defaults: defaults)
        precondition(isV4(fallback))
        precondition(UsageHeartbeatClient.installationID(store: locked, defaults: defaults) == fallback)
        locked.writable = true
        precondition(UsageHeartbeatClient.installationID(store: locked, defaults: defaults) == fallback, "later Keychain access must keep the same UUID")
        precondition(defaults.string(forKey: UsageHeartbeatClient.installationKey) == nil)

        // Invalid or non-random stored values are replaced by a fresh v4 UUID.
        defaults.set("invalid-user-derived-value", forKey: UsageHeartbeatClient.installationKey)
        let invalid = MemoryIDStore("123e4567-e89b-12d3-a456-426614174000")
        let replaced = UsageHeartbeatClient.installationID(store: invalid, defaults: defaults)
        precondition(isV4(replaced) && replaced != "123e4567-e89b-12d3-a456-426614174000")
        precondition(UsageHeartbeatClient.installationID(store: invalid, defaults: defaults) == replaced)

        for (input, expected) in [("1.4.0", "1.4.0"), ("2", "2"), ("10.12", "10.12"), ("1.4.0-beta", nil), ("1.2.3.4", nil), ("", nil), ("1..0", nil), ("１.0", nil), ("12345.0", nil)] as [(String, String?)] {
            precondition(UsageHeartbeatClient.reportableVersion(input) == expected, "version \(input)")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let now = Date(timeIntervalSince1970: 1_758_340_800)
        let store = MemoryIDStore(legacy)
        let client = UsageHeartbeatClient(session: session, defaults: defaults, idStore: store, baseURL: URL(string: "https://api.example.test"), appVersion: "1.4.0", now: { now })

        await client.report()
        precondition(defaults.string(forKey: UsageHeartbeatClient.lastReportedDayKey) == nil, "failure must remain retryable")
        precondition(FixtureProtocol.requests.count == 1)

        FixtureProtocol.shouldFail = false
        await client.report()
        precondition(defaults.string(forKey: UsageHeartbeatClient.lastReportedDayKey) != nil)
        precondition(FixtureProtocol.requests.count == 2)
        await client.report()
        precondition(FixtureProtocol.requests.count == 2, "successful day must be idempotent")

        let request = FixtureProtocol.requests.last!
        precondition(request.url?.absoluteString == "https://api.example.test/v1/usage/heartbeat")
        precondition(request.httpMethod == "POST")
        let body = FixtureProtocol.bodies.last!
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        precondition(Set(object.keys) == ["installation_id", "platform", "app_version"], "payload must contain only the anonymous UUID, platform and version")
        precondition(object["installation_id"] as? String == legacy)
        precondition(object["platform"] as? String == "ios")
        precondition(object["app_version"] as? String == "1.4.0")
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)

        // A version the API would reject is omitted, not sent.
        let unversioned = try JSONSerialization.jsonObject(with: UsageHeartbeatClient.heartbeatBody(installationID: legacy, appVersion: UsageHeartbeatClient.reportableVersion("1.4.0-beta"))) as! [String: Any]
        precondition(Set(unversioned.keys) == ["installation_id", "platform"])
        print("PASS: Keychain migration and fallback, stable UUID, platform/version payload, offline retry and daily idempotence")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-usage-heartbeat-") as directory:
    directory = Path(directory)
    fixture = directory / "Checks.swift"
    fixture.write_text(FIXTURE)
    binary = directory / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "ModuleCache"),
        str(SOURCE), str(fixture), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
