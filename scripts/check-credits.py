#!/usr/bin/env python3
"""Compile the production credits store and test updates using isolated fixtures."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHECKS = r'''
import Foundation

func require(_ value: Bool, _ label: String) { precondition(value, label) }
func edited(_ data: Data, revision: Int, empty: Bool = false) throws -> Data {
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    json["revision"] = revision
    if empty { json["entries"] = [] }
    return try JSONSerialization.data(withJSONObject: json)
}
actor Server {
    var data: Data
    var error: URLError?
    var calls = 0
    init(_ data: Data) { self.data = data }
    func set(_ data: Data, offline: Bool = false) {
        self.data = data; error = offline ? URLError(.notConnectedToInternet) : nil
    }
    func fetch() throws -> Data {
        calls += 1
        if let error { throw error }
        return data
    }
}
actor Race {
    let old: Data
    let new: Data
    var continuation: CheckedContinuation<Data, Never>?
    var first = true
    init(old: Data, new: Data) { self.old = old; self.new = new }
    func fetch() async -> Data {
        if first {
            first = false
            return await withCheckedContinuation { continuation = $0 }
        }
        return new
    }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(returning: old); continuation = nil }
}
@main struct Checks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let bundle = root.appendingPathComponent("app-content/credits.json")
        let published = try Data(contentsOf: bundle)
        _ = try CreditsDocument.decode(published)
        // Keep behavioral fixtures independent of the maintained contributor list.
        let fixture: [String: Any] = [
            "schemaVersion": 1, "revision": 1, "introduction": "合成測試名單",
            "entries": [["id": "fixture", "name": "測試作者", "description": "測試貢獻",
                         "projectName": "Fixture", "url": "https://example.com/project", "order": 10]]
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        let fixtureBundle = directory.appendingPathComponent("bundled.json")
        try data.write(to: fixtureBundle)
        let doc = try CreditsDocument.decode(data)
        let nextRevision = doc.revision + 1
        let next = try edited(data, revision: nextRevision)
        let cache = directory.appendingPathComponent("cache/credits.json")
        let server = Server(data)
        let store = CreditsStore(cacheURL: cache, bundleURL: fixtureBundle, fetch: { try await server.fetch() })
        require(await store.local().document == doc, "bundled initial content")
        await server.set(data, offline: true)
        let offline = try await store.refresh()
        require(offline.document == doc && offline.message != nil, "first offline preserves bundled content")
        await server.set(next)
        let updated = try await store.refresh(force: true)
        require(updated.document?.revision == nextRevision && updated.source == .remote, "remote update")
        let calls = await server.calls
        _ = try await store.refresh()
        require(await server.calls == calls, "six-hour cache interval")
        _ = try await store.refresh(force: true)
        require(await server.calls == calls + 1, "pull refresh bypasses interval")
        let reloaded = CreditsStore(cacheURL: cache, bundleURL: fixtureBundle, fetch: { throw URLError(.notConnectedToInternet) })
        require(await reloaded.local().document?.revision == nextRevision, "persisted cache selected")
        require(try await reloaded.refresh().document?.revision == nextRevision, "offline retains downloaded content")
        await server.set(data)
        let downgrade = try await store.refresh(force: true)
        require(downgrade.document?.revision == nextRevision && downgrade.message != nil, "reject revision downgrade")
        await server.set(try edited(data, revision: nextRevision, empty: true))
        require(try await store.refresh(force: true).document?.entries == doc.entries, "same revision conflict")
        await server.set(Data("not json".utf8))
        require(try await store.refresh(force: true).document?.revision == nextRevision, "malformed response retained")
        require(try CreditsDocument.decode(Data(contentsOf: cache)).revision == nextRevision, "invalid response never persisted")
        await server.set(try edited(data, revision: nextRevision + 1, empty: true))
        require(try await store.refresh(force: true).document?.entries.isEmpty == true, "new revision removes entries")

        // Corrupt cache falls back to bundled data.
        try Data("broken".utf8).write(to: cache)
        let corrupt = CreditsStore(cacheURL: cache, bundleURL: fixtureBundle)
        require(await corrupt.local().document == doc, "corrupt cache fallback")
        for transform in [
            { (j: inout [String: Any]) in j["schemaVersion"] = 99 },
            { j in j["revision"] = 0 },
            { j in let e = j["entries"] as! [[String: Any]]; j["entries"] = e + e },
            { j in var e = j["entries"] as! [[String: Any]]; e[0]["url"] = "javascript:alert(1)"; j["entries"] = e },
            { j in var e = j["entries"] as! [[String: Any]]; e[0]["url"] = "https://user:secret@example.com"; j["entries"] = e }
        ] {
            var invalid = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            transform(&invalid)
            let decoded = try? CreditsDocument.decode(JSONSerialization.data(withJSONObject: invalid))
            require(decoded == nil, "invalid schema, ID or URL rejected")
        }
        require((try? CreditsDocument.decode(Data(repeating: 32, count: 131_073))) == nil, "size limit")

        // A request that ignores cancellation must still not overwrite a newer response.
        let race = Race(old: data, new: next)
        let racing = CreditsStore(cacheURL: directory.appendingPathComponent("race.json"), bundleURL: fixtureBundle,
                                  fetch: { await race.fetch() })
        let oldTask = Task { try await racing.refresh(force: true) }
        while !(await race.waiting()) { await Task.yield() }
        _ = try await racing.refresh(force: true)
        await race.release()
        do { _ = try await oldTask.value; preconditionFailure("stale response must cancel") }
        catch is CancellationError { }
        require(await racing.local().document?.revision == nextRevision, "late response does not downgrade")

        let cancelledRace = Race(old: next, new: next)
        let cancelled = CreditsStore(cacheURL: directory.appendingPathComponent("cancelled.json"), bundleURL: fixtureBundle,
                                     fetch: { await cancelledRace.fetch() })
        let vm = CreditsViewModel(store: cancelled)
        let load = Task { await vm.load(force: true) }
        while !(await cancelledRace.waiting()) { await Task.yield() }
        vm.cancel()
        await cancelledRace.release()
        await load.value
        require(!vm.isLoading && vm.snapshot?.document == doc, "cancelled screen retains original data")
        require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled.json").path), "cancelled request not persisted")
        print("PASS: credits validation, offline fallback, refresh interval, persistence, replacement, revision conflicts, races and cancellation")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-credits-check-") as temp:
    folder = Path(temp)
    harness = folder / "Checks.swift"
    harness.write_text(CHECKS)
    executable = folder / "check"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
        "-module-cache-path", str(folder / "modules"),
        str(ROOT / "Features/Home/Services/CreditsStore.swift"),
        str(ROOT / "Features/Home/ViewModels/CreditsViewModel.swift"),
        str(harness), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable), str(ROOT), str(folder)], check=True)
