#!/usr/bin/env python3
"""Exercise connection checks and stale-result handling without credentials or live services."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import Foundation

final class FixtureProtocol: URLProtocol {
    private var pending: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        precondition(request.httpMethod == "GET")
        precondition(request.httpBody == nil)
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.url?.query == nil)
        precondition(request.httpShouldHandleCookies == false)
        precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
        let host = request.url!.host!
        if host == "offline.test" || host == "timeout.test" || host == "cancelled.test" {
            let code: URLError.Code = host == "offline.test" ? .notConnectedToInternet :
                (host == "timeout.test" ? .timedOut : .cancelled)
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        if host == "slow.test" {
            let work = DispatchWorkItem { [weak self] in self?.respond() }
            pending = work
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        respond()
    }

    private func respond() {
        let url = request.url!
        let host = url.host!
        let responseURL = host == "redirect.test" ? URL(string: "https://unexpected.test")! : url
        let isBackend = url.path == "/v1/usage/heartbeat"
        let statusCode = host == "failure.test" ? 503 : (isBackend && host != "unready.test" ? 405 : 200)
        let response = HTTPURLResponse(url: responseURL, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        let body = host == "invalid.test" ? "<html>not ready</html>" :
            (host == "wrongerror.test" ? "{\"error\":{\"code\":\"unknown\"}}" :
            "{\"error\":{\"code\":\"method_not_allowed\"}}")
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        pending?.cancel()
        pending = nil
    }
}

@main struct Checks {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let expectations: [(String, ConnectionStatus)] = [
            ("ready", .connected), ("failure", .unavailable), ("invalid", .unavailable),
            ("unready", .unavailable), ("offline", .offline), ("timeout", .timedOut),
            ("redirect", .unavailable), ("wrongerror", .unavailable)
        ]
        for (host, expected) in expectations {
            let service = ConnectionStatusService(backendURL: URL(string: "https://\(host).test"), session: session)
            let actual = try await service.check(.backend)
            precondition(actual == expected, "unexpected state for \(host)")
        }
        let service = ConnectionStatusService(backendURL: nil, session: session)
        let missing = try await service.check(.backend)
        let academic = try await service.check(.academic)
        let moodle = try await service.check(.moodle)
        precondition(missing == .notConfigured)
        precondition(academic == .connected && moodle == .connected)

        let cancelledService = ConnectionStatusService(backendURL: URL(string: "https://cancelled.test"), session: session)
        do {
            _ = try await cancelledService.check(.backend)
            preconditionFailure("cancellation must not be reported as a connection failure")
        } catch is CancellationError {}

        let model = SettingsConnectionViewModel(service: service)
        await model.refresh()
        precondition(model.statuses[.academic] == .connected)
        precondition(model.statuses[.moodle] == .connected)
        precondition(model.statuses[.backend] == .notConfigured)

        let slowService = ConnectionStatusService(backendURL: URL(string: "https://slow.test"), session: session)
        let slowModel = SettingsConnectionViewModel(service: slowService)
        let outdated = Task { await slowModel.refresh() }
        try await Task.sleep(for: .milliseconds(30))
        slowModel.reset()
        await outdated.value
        precondition(slowModel.statuses.isEmpty, "old responses must not repopulate a dismissed/reset screen")

        let cancelled = Task { await slowModel.refresh() }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        let newest = Task { await slowModel.refresh() }
        await cancelled.value
        await newest.value
        precondition(slowModel.statuses.values.allSatisfy { $0 == .connected })
        precondition(slowModel.statuses.count == 3, "cancelled requests must not clear newer results")

        let pending = Task { await slowModel.refresh() }
        try await Task.sleep(for: .milliseconds(30))
        pending.cancel()
        await pending.value
        precondition(slowModel.statuses.isEmpty)
        print("PASS: three services, backend response validation, offline, timeout, cancellation, stale responses, and anonymous requests")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-settings-connections-") as directory:
    directory = Path(directory)
    fixture = directory / "Checks.swift"
    fixture.write_text(FIXTURE)
    binary = directory / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "ModuleCache"),
        str(ROOT / "Core/Services/ConnectionStatusService.swift"),
        str(ROOT / "Features/Home/ViewModels/SettingsConnectionViewModel.swift"),
        str(fixture), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
