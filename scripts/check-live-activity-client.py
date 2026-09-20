#!/usr/bin/env python3
"""Execute production remote-client lifecycle logic with synthetic I/O only.
No real Keychain, App Group, school account, API, or APNs access occurs.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Core/Services/LiveActivityRemoteClient.swift').read_text()

def replace_block(text, marker, replacement):
    start = text.index(marker)
    brace = text.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[:start] + replacement + text[end:]

source = source.replace('import ActivityKit\n', '').replace('import Security\n', '')
source = replace_block(source, '    static var baseURL:', '    static var baseURL: URL? { URL(string: "https://activity.example.test") }')
source = replace_block(source, '    private func request(', '''    private func request(endpoint: String, path: String, method: String, token: String? = nil, body: Data? = nil) async throws -> Data {
        try await Fixture.request(method: method, path: path, token: token, body: body)
    }''')
start = source.index('    private var keychainQuery:')
source = source[:start] + '''    private func readKeychain() throws -> Data { Fixture.saved }
    private func persist() throws { Fixture.saved = try JSONEncoder().encode(records) }
    func simulateRelaunch() { task?.cancel(); uploadTask?.cancel(); observedID = nil; pushToken = nil }
}
'''
source = source.replace('UserDefaults.standard', 'Fixture.defaults').replace('UserDefaults(suiteName: "group.dev.chien.niuapp")?', 'Optional(Fixture.defaults)?')
fixtures = r'''
import Foundation
@MainActor enum Fixture {
    static let defaults = UserDefaults(suiteName: "test.niu.activity." + UUID().uuidString)!
    static var saved = Data("[]".utf8)
    static var posts = 0
    static var puts = 0
    static var deletes: [String] = []
    static var holdDelete = false
    static var holdPost = false
    static var deleteGate: CheckedContinuation<Data, Never>?
    static var postGate: CheckedContinuation<Data, Never>?
    static func response(_ token: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["token": token, "expires_at": Date().addingTimeInterval(86400).timeIntervalSince1970])
    }
    static func request(method: String, path: String, token: String?, body: Data?) async throws -> Data {
        if method == "POST" {
            posts += 1
            if holdPost { return await withCheckedContinuation { postGate = $0 } }
            return response("fixture-\(posts)")
        }
        if method == "PUT" {
            puts += 1
            let data = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
            precondition(data["installation_id"] == nil)
            precondition(data["sessions"] != nil && data["update_token"] != nil)
            return Data()
        }
        precondition(method == "DELETE")
        deletes.append(token!)
        if holdDelete { holdDelete = false; return await withCheckedContinuation { deleteGate = $0 } }
        return Data()
    }
}
nonisolated struct ClassLiveActivityAttributes { let startedAt: Date }
@MainActor final class Activity<T> {
    enum State { case active, stale, ended }
    let id: String
    let attributes: ClassLiveActivityAttributes
    var activityState = State.active
    var pushToken: Data? = Data(repeating: 0xab, count: 32)
    let pushTokenUpdates: AsyncStream<Data> = AsyncStream { _ in }
    init(_ id: String) { self.id = id; attributes = ClassLiveActivityAttributes(startedAt: Date()) }
}
@main struct Checks {
    @MainActor static func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<2000 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(1)) }
        preconditionFailure("fixture timed out")
    }
    @MainActor static func main() async throws {
        let now = Date()
        let cal = ScheduleClock.calendar
        let mins = cal.component(.hour, from: now)*60 + cal.component(.minute, from: now)
        // At the end of day no valid future period exists; use the next full
        // minute, capped at 23:59, and skip only the final minute of a Taipei day.
        guard mins < 1438 else { print("SKIP: midnight fixture window"); return }
        let start = max(0, mins-1), end = min(1439, mins+10)
        let range = String(format:"%02d:%02d~%02d:%02d",start/60,start%60,end/60,end%60)
        let headers = ["星期日","星期一","星期二","星期三","星期四","星期五","星期六"]
        let fixture = ClassSchedule(periods: [.init(id:"1",timeRange:range,courses:[0:CourseInfo(name:"Synthetic")])],dayCount:1,dayHeaders:[headers[cal.component(.weekday,from:now)-1]],fetchedAt:now)
        Fixture.defaults.set(try JSONEncoder().encode(fixture),forKey:"classSchedule.v2.cachedData")
        let client = LiveActivityRemoteClient.shared
        let a = Activity<ClassLiveActivityAttributes>("A")
        client.observe(a)
        try await Task.sleep(for:.milliseconds(10))
        precondition(Fixture.posts == 0 && Fixture.puts == 0, "no consent must mean no upload")
        Fixture.defaults.set(true,forKey:LiveActivityRemoteClient.consentKey)
        client.observe(a)
        await waitFor { Fixture.puts == 1 }
        client.simulateRelaunch()
        client.observe(a)
        await waitFor { Fixture.puts == 2 }
        precondition(Fixture.posts == 1 && Fixture.deletes.isEmpty, "relaunch must reuse credential")

        Fixture.holdDelete = true
        client.observe(Activity<ClassLiveActivityAttributes>("B"))
        await waitFor { Fixture.deleteGate != nil && Fixture.puts == 3 }
        client.disable()
        Fixture.deleteGate?.resume(returning: Data()); Fixture.deleteGate = nil
        await waitFor { Fixture.deletes.count == 2 }
        precondition(Set(Fixture.deletes) == ["fixture-1","fixture-2"], "cleanup must drain new revocations")

        Fixture.defaults.set(true,forKey:LiveActivityRemoteClient.consentKey)
        Fixture.holdPost = true
        client.observe(Activity<ClassLiveActivityAttributes>("C"))
        await waitFor { Fixture.postGate != nil }
        client.disable()
        Fixture.postGate?.resume(returning: Fixture.response("late-registration")); Fixture.postGate = nil
        await waitFor { Fixture.deletes.contains("late-registration") }
        precondition(Fixture.puts == 3, "late registration must never upload after logout")
        print("PASS: consent, cold-start credential reuse, concurrent revocation drain, late registration after logout")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='niu-remote-client-') as directory:
    path = Path(directory)
    code = path / 'checks.swift'; code.write_text(source + fixtures)
    binary = path / 'checks'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-target','arm64-apple-macos26.0',
                    '-module-cache-path',str(Path(tempfile.gettempdir())/'niu-widget-module-cache'),
                    str(root/'NIU-LiveActivities/ClassScheduleModels.swift'),str(code),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
