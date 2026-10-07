#!/usr/bin/env python3
"""Exercise 多元時數紀錄 parsing, caching and stale responses with synthetic data, no Keychain or school requests."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
fixture = r'''
import Foundation

@MainActor final class LoginRepository {
    static let shared = LoginRepository()
    func getSavedCredentials() -> (username: String, password: String)? {
        fatalError("Keychain access is forbidden in this fixture")
    }
}

func row(_ start: String, _ end: String, _ title: String, _ ability: String, _ hours: String) -> String {
    """
    <div class="learninghours__tbody-row">
        <div class="learninghours__td">\(start)</div>
        <div class="learninghours__td">\(end)</div>
        <div class="learninghours__td">\(title)
    </div>
        <div class="learninghours__td">\(ability)</div>
        <div class="learninghours__td">\(hours)</div>
    </div>
    """
}

func detail(_ rows: [String], paging: String = "<a class=\"paging__btn paging__btn--active\">1</a>") -> String {
    rows.joined() + "<div id=\"page_html\" style=\"display: none;\">\(paging)</div>"
}

@MainActor final class FakeClient: LearningHoursFetching {
    var result: Result<LearningHoursSnapshot, LearningHoursError> = .failure(.invalidResponse)
    var calls = 0
    var gate: CheckedContinuation<Void, Never>?
    var pause = false

    nonisolated func fetch(username: String, password: String) async throws -> LearningHoursSnapshot {
        try await run()
    }

    private func run() async throws -> LearningHoursSnapshot {
        calls += 1
        let outcome = result
        if pause { await withCheckedContinuation { gate = $0 } }
        return try outcome.get()
    }
}

@main
struct Checks {
    @MainActor static func settle(_ model: LearningHoursViewModel) async {
        for _ in 0..<200 where model.isRefreshing { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor static func main() async throws {
        // Summary JSON: ordering, mixed number/string fields, signed-out array, school error.
        let summary = try LearningHoursParser.parseSummary(Data("""
        {"IsSuccess":true,"Message":"","Data":[
          {"AbilityId":"99","Ability":"彈性綜合","CaHr":0,"TCaHr":40},
          {"AbilityId":"3","Ability":"專業進取","CaHr":"15","TCaHr":20},
          {"AbilityId":1,"Ability":"服務奉獻","CaHr":2.5,"TCaHr":20},
          {"AbilityId":"2","Ability":"多元成長","CaHr":7,"TCaHr":20}]}
        """.utf8))
        precondition(summary.map(\.abilityID) == ["1", "2", "3", "99"], "Summary follows the card order")
        precondition(summary[0].earned == 2.5 && summary[2].earned == 15)
        do { _ = try LearningHoursParser.parseSummary(Data("[]".utf8)); preconditionFailure() }
        catch let error as LearningHoursError { precondition(error == .sessionExpired, "[] means signed out") }
        do { _ = try LearningHoursParser.parseSummary(Data(#"{"IsSuccess":false,"Message":"系統維護"}"#.utf8)); preconditionFailure() }
        catch let error as LearningHoursError { precondition(error == .schoolError("系統維護")) }
        do { _ = try LearningHoursParser.parseSummary(Data("<html>".utf8)); preconditionFailure() }
        catch let error as LearningHoursError { precondition(error == .invalidResponse) }

        // Detail HTML: entities, multi-line titles, cross-day periods, paging and empty pages.
        let page = try LearningHoursParser.parseDetail(detail([
            row("2026/6/3", "2026/6/3", "AI &amp; Canva：<b>網站</b>\n  實作", "專業進取", "2"),
            row("2024/9/1", "2024/10/31", "校園問卷&#35519;查", "服務奉獻", "1.5"),
        ], paging: "<a href=\"https://ep.niu.edu.tw/search/learning_certification?page=1\" class=\"paging__prev\"></a><a class=\"paging__btn paging__btn--active\">1</a><a class=\"paging__btn\" href=\"?page=3\">3</a>"))
        precondition(page.records.count == 2 && page.lastPage == 3)
        precondition(page.records[0].title == "AI & Canva：網站 實作", "Tags stripped, entities decoded")
        precondition(page.records[1].title == "校園問卷調查" && page.records[1].hoursValue == 1.5)
        precondition(page.records[1].endDate == "2024/10/31", "Keep the full period")
        let empty = try LearningHoursParser.parseDetail(detail(["\n 尚無資料 \n"]))
        precondition(empty.records.isEmpty && empty.lastPage == 1)
        do { _ = try LearningHoursParser.parseDetail("<script>alert('登入逾時，請重新登入');location.replace('x');</script>"); preconditionFailure() }
        catch let error as LearningHoursError { precondition(error == .sessionExpired) }
        do { _ = try LearningHoursParser.parseDetail("<div class=\"learninghours__tbody-row\"><div class=\"learninghours__td\">x</div></div>"); preconditionFailure() }
        catch let error as LearningHoursError { precondition(error == .invalidResponse, "Missing paging block is not 'no data'") }
        do { _ = try LearningHoursParser.parseDetail(detail([#"<div class="learninghours__tbody-row"><div class="learninghours__td">x</div></div>"#])); preconditionFailure() }
        catch let error as LearningHoursError { precondition(error == .invalidResponse, "Incomplete rows are rejected") }

        // Form body never leaves reserved characters unescaped.
        let body = String(data: LearningHoursClient.formBody(["student_id": "b1", "password": "a&b=c+d 測"]), encoding: .utf8)!
        precondition(body == "password=a%26b%3Dc%2Bd%20%E6%B8%AC&student_id=b1", body)
        precondition(LearningHoursClient.map(URLError(.timedOut)) as? LearningHoursError == .campusNetworkRequired)
        precondition(LearningHoursClient.map(URLError(.notConnectedToInternet)) as? LearningHoursError == .offline)
        precondition(LearningHoursClient.map(URLError(.cancelled)) is CancellationError)

        // View model: first load fetches, cache survives failures, account isolation, stale responses.
        let defaults = UserDefaults(suiteName: "niu-learning-hours-check")!
        defaults.removePersistentDomain(forName: "niu-learning-hours-check")
        defaults.set("B0001", forKey: "app.user.username")
        var saved: (username: String, password: String)? = ("b0001", "synthetic")
        let client = FakeClient()
        let snapshot = LearningHoursSnapshot(summaries: summary, records: page.records, fetchedAt: Date(timeIntervalSince1970: 1))

        let failing = LearningHoursViewModel(client: client, defaults: defaults, credentials: { saved })
        client.result = .failure(.campusNetworkRequired)
        failing.start()
        await settle(failing)
        precondition(failing.loadState == .error(LearningHoursError.campusNetworkRequired.errorDescription!))
        precondition(defaults.data(forKey: "graduationThreshold.learningHours.v1.b0001") == nil)

        client.result = .success(snapshot)
        await failing.refreshAndWait()
        precondition(failing.loadState == .loaded && failing.snapshot == snapshot && failing.lastRefreshError == nil)
        precondition(defaults.data(forKey: "graduationThreshold.learningHours.v1.b0001") != nil, "Cache key uses the logout-cleared prefix")

        failing.selectedAbility = "服務奉獻"
        precondition(failing.filteredRecords.count == 1)
        client.result = .failure(.campusNetworkRequired)
        await failing.refreshAndWait()
        precondition(failing.snapshot == snapshot && failing.loadState == .loaded, "Failed refresh keeps the cache")
        precondition(failing.lastRefreshError == LearningHoursError.campusNetworkRequired.errorDescription)

        let calls = client.calls
        let cached = LearningHoursViewModel(client: client, defaults: defaults, credentials: { saved })
        cached.start()
        precondition(cached.snapshot == snapshot && client.calls == calls, "Cached data opens without the campus network")

        defaults.set("B0002", forKey: "app.user.username")
        let other = LearningHoursViewModel(client: client, defaults: defaults, credentials: { saved })
        other.start()
        await settle(other)
        precondition(other.snapshot == nil, "Another account never sees the cached hours")
        precondition(other.loadState == .error(LearningHoursError.credentialsMissing.errorDescription!),
                     "Credentials for a different account are not used")

        defaults.set("B0001", forKey: "app.user.username")
        client.result = .success(LearningHoursSnapshot(summaries: [], records: [], fetchedAt: Date()))
        client.pause = true
        cached.refresh()
        for _ in 0..<200 where client.gate == nil { await Task.yield(); try await Task.sleep(for: .milliseconds(1)) }
        defaults.set("B0003", forKey: "app.user.username")
        saved = ("b0003", "synthetic")
        client.gate?.resume()
        client.gate = nil
        client.pause = false
        try await Task.sleep(for: .milliseconds(30))
        precondition(cached.snapshot == snapshot && !cached.isRefreshing, "A response finishing after an account switch is dropped")
        precondition(defaults.data(forKey: "graduationThreshold.learningHours.v1.b0003") == nil)

        defaults.set("B0001", forKey: "app.user.username")
        saved = ("b0001", "synthetic")
        client.pause = true
        cached.refresh()
        for _ in 0..<200 where client.gate == nil { await Task.yield(); try await Task.sleep(for: .milliseconds(1)) }
        cached.stop()
        client.gate?.resume()
        client.gate = nil
        try await Task.sleep(for: .milliseconds(30))
        precondition(cached.snapshot == snapshot && !cached.isRefreshing, "Closing the sheet discards the pending response")

        defaults.removePersistentDomain(forName: "niu-learning-hours-check")
        print("PASS: summary order/flexible numbers, signed-out detection, detail entities/periods/paging, form encoding, network error mapping, cache-first open, failed refresh keeps cache, account isolation, stale and cancelled responses")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-learning-hours-check-") as directory:
    folder = Path(directory)
    checks = folder / "Checks.swift"
    checks.write_text(fixture)
    binary = folder / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(folder / "ModuleCache"),
        "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
        "-parse-as-library",
        str(root / "Features/GraduationThreshold/Models/LearningHoursModels.swift"),
        str(root / "Features/GraduationThreshold/Services/LearningHoursClient.swift"),
        str(root / "Features/GraduationThreshold/ViewModels/LearningHoursViewModel.swift"),
        str(checks), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
