#!/usr/bin/env python3
"""Exercise the production SSO token renewer with synthetic tokens, an in-memory
store and a scripted transport. No Keychain, account or network is used."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
renewer = (root / "Core/Services/SSOTokenRenewer.swift").read_text()

# Source guard for 8c0aede: foreground must never open the login WebView, because a
# Turnstile failure starts the refresh cooldown and blocks every feature.
app_state = (root / "Core/Models/AppState.swift").read_text()
foreground = app_state[app_state.index("func applicationDidBecomeActive"):
                       app_state.index("func significantTimeChanged")]
assert "requestRefresh" not in foreground, "Foreground must not start an SSO login (see 8c0aede)"

fixture = r'''
import Foundation
extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
@MainActor final class SSOTokenStore {
    static let shared = SSOTokenStore()
    var token: String?
    var account: String?
    var expiration: String?
    var needsRenewal = true
    var saves = 0
    func save(token: String, exp: String?, account: String) {
        self.token = token; self.expiration = exp; self.account = account.lowercased(); saves += 1
    }
    func clear() { token = nil; account = nil; expiration = nil }
    func clear(ifMatching rejected: String) { if token == rejected { clear() } }
    static func jwtExpiration(_ token: String) -> String? {
        token.hasPrefix("jwt-") ? "2099-01-01T00:00:00Z" : nil
    }
}
@MainActor final class Gate {
    var continuations: [CheckedContinuation<Void, Never>] = []
    var requests = 0
    func wait() async {
        requests += 1
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() { continuations.forEach { $0.resume() }; continuations = [] }
}
@MainActor func response(_ status: Int, _ body: String) -> (Data, URLResponse) {
    let url = URL(string: "https://ccsys1.niu.edu.tw/SSO/API/Login/refreshToken")!
    return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
}
/// Replies to each transport call in order, holding it until `release(index:)`.
@MainActor final class Sequencer {
    var replies: [(Int, String)] = []
    var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    var requests = 0
    func send() async -> (Data, URLResponse) {
        let index = requests
        requests += 1
        await withCheckedContinuation { waiting[index] = $0 }
        let (status, body) = replies[index]
        return response(status, body)
    }
    func release(_ index: Int) { waiting.removeValue(forKey: index)?.resume() }
}
/// Waits for a condition instead of a fixed number of yields; fails if it never holds.
@MainActor func waitUntil(_ reason: String, _ condition: () -> Bool) async {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    preconditionFailure("Timed out waiting: " + reason)
}
@MainActor func settle() async { for _ in 0..<20 { await Task.yield() } }
@MainActor func reset(_ token: String? = "old-token", account: String? = "fixture") {
    let store = SSOTokenStore.shared
    store.token = token; store.account = account; store.expiration = nil
    store.needsRenewal = true; store.saves = 0
}

@main struct Checks {
    @MainActor static func main() async {
        let store = SSOTokenStore.shared

        // Success: JWT expiry wins, account binding is kept, the request carries the bearer token.
        reset()
        var sentAuthorization: String?
        var renewer = SSOTokenRenewer { request in
            sentAuthorization = request.value(forHTTPHeaderField: "Authorization")
            return response(200, #"{"token":"jwt-new","exp":"garbage"}"#)
        }
        let result1 = await renewer.renew()
        precondition(result1)
        precondition(store.token == "jwt-new" && store.account == "fixture"
                     && store.expiration == "2099-01-01T00:00:00Z")
        precondition(sentAuthorization == "Bearer old-token")

        // Non-JWT token falls back to the payload exp; .NET fractions are trimmed.
        reset()
        renewer = SSOTokenRenewer { _ in response(200, #"{"token":"opaque","exp":"2099-01-01T00:00:00.1234567Z"}"#) }
        let result2 = await renewer.renew()
        precondition(result2 && store.expiration == "2099-01-01T00:00:00Z")
        precondition(SSOTokenRenewer.normalizedExpiration("4070908800") == "2099-01-01T00:00:00Z")
        precondition(SSOTokenRenewer.normalizedExpiration("not a date") == nil,
                     "Unreadable expiry must not be stored as a raw string")

        // Not near expiry: no request at all.
        reset()
        store.needsRenewal = false
        var calls = 0
        renewer = SSOTokenRenewer { _ in calls += 1; return response(200, #"{"token":"jwt-x"}"#) }
        let result3 = await renewer.renewIfNeeded()
        precondition(!result3 && calls == 0 && store.token == "old-token")

        // Rejected (401) clears only that token; other failures keep it.
        reset()
        renewer = SSOTokenRenewer { _ in response(401, "") }
        let result4 = await renewer.renew()
        precondition(!result4 && store.token == nil)
        reset()
        renewer = SSOTokenRenewer { _ in response(500, "") }
        let result5 = await renewer.renew()
        precondition(!result5 && store.token == "old-token" && store.saves == 0)
        reset()
        renewer = SSOTokenRenewer { _ in throw URLError(.notConnectedToInternet) }
        let result6 = await renewer.renew()
        precondition(!result6 && store.token == "old-token")
        reset()
        renewer = SSOTokenRenewer { _ in response(200, #"{"unexpected":true}"#) }
        let result7 = await renewer.renew()
        precondition(!result7 && store.token == "old-token" && store.saves == 0)
        reset(account: nil)
        renewer = SSOTokenRenewer { _ in calls += 1; return response(200, #"{"token":"jwt-x"}"#) }
        calls = 0
        let result8 = await renewer.renew()
        precondition(!result8 && calls == 0, "Never renew without an account binding")

        // Concurrent callers share a single request.
        reset()
        let gate = Gate()
        renewer = SSOTokenRenewer { _ in await gate.wait(); return response(200, #"{"token":"jwt-shared"}"#) }
        let first = Task { [renewer] in await renewer.renew() }
        let second = Task { [renewer] in await renewer.renew() }
        await settle()
        precondition(gate.requests == 1, "Concurrent renewals must be coalesced")
        gate.release()
        let firstResult = await first.value
        let secondResult = await second.value
        precondition(firstResult && secondResult && store.saves == 1 && store.token == "jwt-shared")

        // Logout while waiting: the late response must not restore the token.
        reset()
        let logoutGate = Gate()
        renewer = SSOTokenRenewer { _ in await logoutGate.wait(); return response(200, #"{"token":"jwt-late"}"#) }
        let loggedOut = Task { [renewer] in await renewer.renew() }
        await settle()
        renewer.cancel()
        store.clear()
        logoutGate.release()
        let result9 = await loggedOut.value
        precondition(!result9 && store.token == nil && store.saves == 0,
                     "A renewal finishing after logout must not save")

        // Account switch while waiting: A's renewal must not overwrite B's session.
        reset()
        let switchGate = Gate()
        renewer = SSOTokenRenewer { _ in await switchGate.wait(); return response(200, #"{"token":"jwt-a"}"#) }
        let switched = Task { [renewer] in await renewer.renew() }
        await settle()
        store.save(token: "token-b", exp: nil, account: "other")
        switchGate.release()
        let result10 = await switched.value
        precondition(!result10 && store.token == "token-b" && store.account == "other",
                     "A late renewal must not replace a newer login")

        // A late 401 for the old token must not clear a newer login either.
        reset()
        let rejectGate = Gate()
        renewer = SSOTokenRenewer { _ in await rejectGate.wait(); return response(401, "") }
        let rejected = Task { [renewer] in await renewer.renew() }
        await settle()
        store.save(token: "token-b", exp: nil, account: "fixture")
        rejectGate.release()
        let result11 = await rejected.value
        precondition(!result11 && store.token == "token-b")

        // After cancel, a new renewal starts its own request.
        reset()
        var restarts = 0
        renewer = SSOTokenRenewer { _ in restarts += 1; return response(200, #"{"token":"jwt-again"}"#) }
        renewer.cancel()
        let result12 = await renewer.renew()
        precondition(result12 && restarts == 1)

        // Payload exp may be numeric or another type; a JWT exp still wins.
        reset()
        renewer = SSOTokenRenewer { _ in response(200, #"{"token":"opaque","exp":4070908800}"#) }
        let numericExp = await renewer.renew()
        precondition(numericExp && store.expiration == "2099-01-01T00:00:00Z", "Numeric exp must be accepted")
        reset()
        renewer = SSOTokenRenewer { _ in response(200, #"{"token":"jwt-typed","exp":{"unexpected":1}}"#) }
        let oddExp = await renewer.renew()
        precondition(oddExp && store.token == "jwt-typed" && store.expiration == "2099-01-01T00:00:00Z",
                     "An unexpected exp type must not discard a valid JWT")
        // A valid token with no readable expiry is still saved (later 401 triggers login).
        reset()
        renewer = SSOTokenRenewer { _ in response(200, #"{"token":"opaque-no-exp","exp":"soon"}"#) }
        let noExp = await renewer.renew()
        precondition(noExp && store.token == "opaque-no-exp" && store.expiration == nil)

        // A waits → cancel → B starts → A returns → C joins B, not a third request.
        for staleStatus in [200, 401] {
            reset()
            let sequencer = Sequencer()
            sequencer.replies = [(staleStatus, #"{"token":"jwt-stale"}"#), (200, #"{"token":"jwt-fresh"}"#)]
            let overlapping = SSOTokenRenewer { _ in await sequencer.send() }
            let a = Task { await overlapping.renew() }
            await waitUntil("A request started") { sequencer.requests == 1 }
            overlapping.cancel()
            let b = Task { await overlapping.renew() }
            await waitUntil("B request started") { sequencer.requests == 2 }
            sequencer.release(0)
            let aResult = await a.value
            precondition(!aResult && store.token == "old-token" && store.saves == 0,
                         "A cancelled renewal (status \(staleStatus)) must not save or clear")
            // renew() checks inFlight before its first suspension, so once C has
            // entered, it has either joined B or started a third request.
            var cEntered = false
            let c = Task { cEntered = true; return await overlapping.renew() }
            await waitUntil("C entered renew()") { cEntered }
            precondition(sequencer.requests == 2, "C must join B after A's stale completion")
            sequencer.release(1)
            let bResult = await b.value
            let cResult = await c.value
            precondition(bResult && cResult && store.token == "jwt-fresh" && store.saves == 1)
        }

        print("PASS: JWT/payload expiry, renewal window, 401 vs transient failures, malformed response, coalescing, cancel/restart overlap, logout and account-switch races")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-sso-renewal-") as directory:
    folder = Path(directory)
    files = []
    for name, contents in [("SSOTokenRenewer.swift", renewer), ("Checks.swift", fixture)]:
        path = folder / name
        path.write_text(contents)
        files.append(str(path))
    binary = folder / "checks"
    # Match the app target (Swift 5, MainActor default isolation, approachable
    # concurrency) and turn on complete strict-concurrency checking as errors.
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    "-default-isolation", "MainActor", "-strict-concurrency=complete",
                    "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
                    "-enable-upcoming-feature", "InferIsolatedConformances",
                    "-warnings-as-errors",
                    "-module-cache-path", str(folder / "ModuleCache"), *files, "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
