#!/usr/bin/env python3
"""Compile and exercise anonymous usage reporting with isolated defaults and a fake URL protocol."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Core/Services/UsageHeartbeatClient.swift"
APP_STATE = ROOT / "Core/Models/AppState.swift"

app_state = APP_STATE.read_text()
assert app_state.count("Task { await UsageHeartbeatClient.shared.report() }") == 3
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

@main struct Checks {
    static func main() async throws {
        let suite = "dev.chienniuapp.usage-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("invalid-user-derived-value", forKey: UsageHeartbeatClient.installationKey)
        let first = UsageHeartbeatClient.installationID(in: defaults)
        precondition(UUID(uuidString: first) != nil)
		precondition(first.split(separator: "-")[2].first == "4")
        precondition(UsageHeartbeatClient.installationID(in: defaults) == first)
		defaults.set("123e4567-e89b-12d3-a456-426614174000", forKey: UsageHeartbeatClient.installationKey)
		let replacedV1 = UsageHeartbeatClient.installationID(in: defaults)
		precondition(replacedV1 != "123e4567-e89b-12d3-a456-426614174000")
		precondition(replacedV1.split(separator: "-")[2].first == "4")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let now = Date(timeIntervalSince1970: 1_758_340_800)
        let client = UsageHeartbeatClient(session: session, defaults: defaults, baseURL: URL(string: "https://api.example.test"), now: { now })

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
        precondition(Set(object.keys) == ["installation_id"], "payload must contain only the anonymous UUID")
		precondition(object["installation_id"] as? String == replacedV1)
		precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
		precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        print("PASS: stable UUID, privacy-minimal payload, offline retry and daily idempotence")
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
