#!/usr/bin/env python3
"""Run production reminder logic offline with fake notification center/service/clock/session.
No Keychain, network, simulator or real notification center is used.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
fixture = r'''
import Foundation

@MainActor final class FakeCenter: ReminderNotificationCenter {
    var authorized = true
    var requests: [String: PendingManagedNotification] = [:]
    var addCalls = 0
    var maxCount = 0
    var failAdd = false
    var holdAdd = false
    var addGate: CheckedContinuation<Void, Never>?
    func isAuthorized() async -> Bool { authorized }
    func pending() async -> [PendingManagedNotification] { Array(requests.values) }
    func add(_ value: ManagedNotification, session: String) async throws {
        addCalls += 1
        if holdAdd { await withCheckedContinuation { addGate = $0 } }
        if failAdd { throw URLError(.unknown) }
        requests[value.id] = PendingManagedNotification(id: value.id, session: session, value: value)
        maxCount = max(maxCount, requests.count)
    }
    func remove(_ ids: [String]) { for id in ids { requests.removeValue(forKey: id) } }
    func removeDelivered(_ ids: [String]) {}
}

@MainActor final class Fixture {
    let center = FakeCenter()
    var owner: String? = "session-A"
    var clock = EventReminderDate.start("2026/12/30 09:00")!
    var cache: Data?
    var records = [record("1", "2027/01/01 10:30起\n2027/01/01 12:00止")]
    var failRead = false
    var calls = 0
    var holdRead = false
    var gate: CheckedContinuation<[EventReminderRecord], Error>?
    var status = ""
    lazy var scheduler: EventReminderScheduler = {
        let scheduler = EventReminderScheduler(center: center, session: { self.owner }, now: { self.clock },
            loadCache: { self.cache }, saveCache: { self.cache = $0 }, events: {
                self.calls += 1
                if self.holdRead { return try await withCheckedThrowingContinuation { self.gate = $0 } }
                if self.failRead { throw URLError(.notConnectedToInternet) }
                return self.records
            })
        scheduler.statusChanged = { self.status = $0 }
        return scheduler
    }()
    func refresh(_ lead: EventReminderLeadTime = .oneDay, enabled: Set<ManagedNotificationCategory> = [.event]) async {
        await scheduler.refresh(enabled: enabled, lead: lead)
    }
}

func record(_ id: String, _ date: String, state: String = "已報名", eventState: String = "未開始") -> EventReminderRecord {
    EventReminderRecord(id: id, title: "合成活動 \(id)", eventTime: date, registrationState: state, eventState: eventState)
}
func require(_ result: @autoclosure () -> Bool, _ message: String) {
    if !result() { fatalError(message) }
}
@MainActor func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<10000 { if condition() { return }; await Task.yield() }
    fatalError("fixture gate was never reached")
}

@main struct Tests {
    @MainActor static func main() async {
        let suiteName = "dev.chien.niuapp.reminder-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var settings = NotificationSettings.load(defaults: defaults)
        require(!settings.eventReminderEnabled && settings.eventReminderLeadTime == .oneDay, "opt-in defaults")
        settings.eventReminderEnabled = true; settings.eventReminderLeadTime = .thirtyMinutes
        settings.save(defaults: defaults)
        require(NotificationSettings.load(defaults: defaults).eventReminderLeadTime == .thirtyMinutes, "setting persistence")
        defaults.set(-1, forKey: "app.notification.eventReminderLeadTime")
        require(NotificationSettings.load(defaults: defaults).eventReminderLeadTime == .oneDay, "invalid stored lead uses default")
        let expected = ISO8601DateFormatter().date(from: "2026-12-31T02:30:00Z")!
        require(EventReminderDate.start("2026/12/31 10:30起\n2027/1/1 12:00止") == expected, "Taipei + cross year")
        require(EventReminderDate.start("2026/12/3110:30起\n2027/1/112:00止") == expected, "scraper compact format")
        require(EventReminderDate.start("2026-12-31 10:30:00 ~ 2027-01-01 12:00") == expected, "explicit seconds and separator")
        require(EventReminderDate.start("2024/02/29 00:00") != nil, "leap day")
        for (input, expected) in [
            ("2026/9/21 上午 08:00:00起", "2026/09/21 08:00:00"),
            ("2026/9/21下午08:00:00起", "2026/09/21 20:00:00"),
            ("2026/9/21上午12:00:00起", "2026/09/21 00:00:00"),
            ("2026/9/21下午12:00:00起", "2026/09/21 12:00:00"),
            ("2026/1/1下午1:05:09起", "2026/01/01 13:05:09")
        ] {
            require(EventReminderDate.start(input) == EventReminderDate.start(expected), "school AM/PM conversion: \(input)")
        }
        for bad in ["2026/9/21上午00:00:00", "2026/9/21下午13:00:00", "2026/9/21上午24:00:00"] {
            require(EventReminderDate.start(bad) == nil, "invalid AM/PM hour: \(bad)")
        }
        for bad in ["2026/02/29 10:00", "2026/04/31 10:00", "2026/01/01 24:00", "2026/01/01 10:60",
                    "2026/01/01 10:00:60", "2026/13/01 10:00", "2026/00/01 10:00", "2026/01/00 10:00",
                    "2026/12/31", "115/12/31 10:00", "12/31 10:00", "明天 10:00", "2026/12/31 10:30PM", ""] {
            require(EventReminderDate.start(bad) == nil, "reject \(bad)")
        }
        for state in ["候補", "備取", "取消報名", "未報名", "", "未知", "待審核", "尚未錄取", "正取（已取消）"] {
            require(!record("x", "", state: state).isRegistered, "strict state \(state)")
        }
        require(!record("x", "", eventState: "活動取消").isRegistered, "cancelled activity")
        let f = Fixture()
        await f.refresh()
        require(f.center.requests.count == 1, "schedule confirmed record")
        require(f.center.requests["notify.event.1"]?.value?.fireDate == expected, "default one day crosses year")
        await f.refresh(.oneHour)
        require(f.center.requests.count == 1, "replace time without duplicate")
        require(f.center.requests["notify.event.1"]?.value?.fireDate == EventReminderDate.start("2027/01/01 09:30"), "one hour")
        f.failRead = true
        await f.refresh(.thirtyMinutes)
        require(f.center.requests.count == 1 && f.status.contains("保留有效快取"), "offline cache retained")
        require(f.center.requests["notify.event.1"]?.value?.fireDate == EventReminderDate.start("2027/01/01 10:00"), "offline setting change uses cached event time")
        let restarted = EventReminderScheduler(center: f.center, session: { f.owner }, now: { f.clock },
            loadCache: { f.cache }, saveCache: { f.cache = $0 }, events: { throw URLError(.notConnectedToInternet) })
        await restarted.refresh(enabled: [.event], lead: .oneDay)
        require(f.center.requests["notify.event.1"]?.value?.fireDate == expected, "restart offline restores session-scoped cache")
        f.failRead = false; f.records = []
        await f.refresh()
        require(f.center.requests.isEmpty, "successful cancellation removes pending")
        f.records = [record("1", "2027/01/01 10:30"), record("2", "2026/12/30 10:00"), record("3", "2027/01/01")]
        await f.refresh()
        require(f.center.requests.count == 1 && f.status.contains("提醒時間已過") && f.status.contains("可辨識"), "elapsed and invalid status")
        await f.refresh(enabled: [])
        require(f.center.requests.isEmpty && f.status.contains("已關閉"), "toggle off removes")
        f.center.authorized = false
        let calls = f.calls
        await f.refresh()
        require(f.calls == calls && f.center.requests.isEmpty && f.status.contains("尚未允許"), "denied no false scheduled state or service fetch")
        f.center.authorized = true; f.center.failAdd = true
        await f.refresh()
        require(f.status.contains("已安排 0") && f.status.contains("無法更新"), "add failure not claimed as scheduled")

        let cancelled = Fixture()
        await cancelled.refresh()
        cancelled.scheduler.removeConfirmedEvent("1")
        require(cancelled.center.requests.isEmpty, "confirmed cancel immediately removes pending")
        require(!String(data: cancelled.cache!, encoding: .utf8)!.contains("合成活動 1"), "confirmed cancel removes cached row")
        cancelled.failRead = true
        await cancelled.refresh()
        require(cancelled.center.requests.isEmpty, "failed post-cancel refresh cannot resurrect reminders")
        let missing = Fixture()
        await missing.refresh()
        missing.center.requests.removeAll() // stale cache alone must never create a new request offline
        missing.failRead = true
        await missing.refresh()
        require(missing.center.requests.isEmpty, "offline cache requires an existing pending ID")
        let cancelRace = Fixture()
        cancelRace.center.holdAdd = true
        let adding = Task { await cancelRace.refresh() }
        await waitUntil { cancelRace.center.addGate != nil }
        cancelRace.scheduler.removeConfirmedEvent("1")
        cancelRace.center.holdAdd = false; cancelRace.failRead = true
        let refreshAfterCancel = Task { await cancelRace.refresh() }
        cancelRace.center.addGate?.resume(); cancelRace.center.addGate = nil
        await adding.value; await refreshAfterCancel.value
        require(cancelRace.center.requests.isEmpty, "late add after cancellation cannot resurrect request")

        let legacy = Fixture()
        for category in [ManagedNotificationCategory.assignment, .calendar, .class] {
            let id = category.prefix + "legacy"
            legacy.center.requests[id] = PendingManagedNotification(id: id, session: nil, value: nil)
        }
        legacy.center.requests["notify.assignment.foreign"] = PendingManagedNotification(id: "notify.assignment.foreign", session: "session-B", value: nil)
        let unavailable: EventReminderScheduler.Source = { throw URLError(.notConnectedToInternet) }
        await legacy.scheduler.refresh(enabled: [.assignment, .calendar, .class], lead: .oneDay,
            sources: [.assignment: unavailable, .calendar: unavailable, .class: unavailable])
        require(legacy.center.requests.count == 3, "offline upgrade keeps legacy requests but removes explicit old session")
        await legacy.scheduler.refresh(enabled: [.assignment, .calendar, .class], lead: .oneDay,
            sources: [.assignment: { [] }, .calendar: unavailable])
        require(Set(legacy.center.requests.keys) == ["notify.calendar.legacy", "notify.class.legacy"], "fresh category replaces legacy; absent/failed sources preserve others")
        let legacyBudget = Fixture()
        legacyBudget.records = (0..<70).map { record(String($0), "2027/01/01 10:30") }
        for category in [ManagedNotificationCategory.assignment, .calendar, .class] {
            let id = category.prefix + "legacy"
            legacyBudget.center.requests[id] = PendingManagedNotification(id: id, session: nil, value: nil)
        }
        await legacyBudget.scheduler.refresh(enabled: Set(ManagedNotificationCategory.allCases), lead: .oneDay,
            sources: [.assignment: unavailable, .calendar: unavailable, .class: unavailable])
        require(legacyBudget.center.requests.count == 60 && legacyBudget.center.maxCount <= 60, "legacy requests reserve budget before fresh events are added")
        require(legacyBudget.status.contains("13 個活動提醒因通知容量限制"), "legacy slots included in capacity accounting")
        require(legacyBudget.center.requests["notify.class.legacy"] != nil, "events cannot crowd out opaque legacy requests before successful refresh")
        legacy.scheduler.invalidateSession()
        await legacy.scheduler.waitForIdle()
        require(legacy.center.requests.isEmpty, "logout removes metadata-free legacy requests")
        print("PASS: confirmed cancellation/cache eviction, late-add barrier, offline no resurrection, legacy offline upgrade/replacement/logout")

        let r = Fixture()
        r.holdRead = true
        let old = Task { await r.refresh() }
        await waitUntil { r.gate != nil }
        r.scheduler.invalidateSession(); r.owner = nil
        r.gate?.resume(returning: r.records); r.gate = nil
        await old.value; await r.scheduler.waitForIdle()
        require(r.center.requests.isEmpty && r.cache == nil, "logout rejects delayed fetch/cache")
        r.owner = "session-B"; r.holdRead = false; r.failRead = true
        await r.refresh()
        require(r.center.requests.isEmpty, "new session cannot reuse old cache")

        let a = Fixture()
        a.center.holdAdd = true
        let oldAdd = Task { await a.refresh() }
        await waitUntil { a.center.addGate != nil }
        a.scheduler.invalidateSession(); a.owner = "session-B"
        a.center.holdAdd = false
        a.records = [record("1", "2027/01/02 10:30")]
        let replacement = Task { await a.refresh() }
        a.center.addGate?.resume(); a.center.addGate = nil
        await oldAdd.value; await replacement.value
        require(a.center.requests.count == 1 && a.center.requests["notify.event.1"]?.session == "session-B", "late center.add cannot resurrect old session or remove replacement")
        require(a.center.requests["notify.event.1"]?.value?.fireDate == EventReminderDate.start("2027/01/01 10:30"), "new session value wins")
        a.scheduler.invalidateSession() // client reset without changing the app session
        a.failRead = true
        await a.refresh()
        require(a.center.requests.isEmpty && a.cache == nil, "same app session client reset cannot reuse old requests")

        let race = Fixture()
        race.holdRead = true
        let before = Task { await race.refresh() }
        await waitUntil { race.gate != nil }
        race.holdRead = false; race.records = []
        let after = Task { await race.refresh(enabled: []) }
        await Task.yield()
        race.gate?.resume(returning: [record("1", "2027/01/01 10:30")]); race.gate = nil
        await before.value; await after.value
        require(race.center.requests.isEmpty, "setting change rejects late event response")

        var candidates: [ManagedNotification] = []
        for category in ManagedNotificationCategory.allCases {
            for index in 0..<70 {
                candidates.append(ManagedNotification(id: "\(category.prefix)\(index)", category: category,
                    title: "test", body: "", fireDate: f.clock.addingTimeInterval(Double(index + 1) * 60)))
            }
        }
        let chosen = NotificationBudget.select(candidates.reversed(), unmanagedCount: 5, now: f.clock)
        require(chosen.count == 55 && chosen.allSatisfy { $0.category == .event }, "global 60 budget reserves events")
        require(chosen.map(\.fireDate) == chosen.map(\.fireDate).sorted(), "earliest first")
        require(NotificationBudget.select(candidates, unmanagedCount: 64, now: f.clock).isEmpty, "unmanaged requests count against budget")
        let budget = Fixture()
        for index in 0..<5 { budget.center.requests["external.\(index)"] = PendingManagedNotification(id: "external.\(index)", session: nil, value: nil) }
        budget.records = (0..<70).flatMap { [record(String($0), "2027/01/01 10:30"), record(String($0), "2027/01/01 10:30")] }
        await budget.scheduler.refresh(enabled: Set(ManagedNotificationCategory.allCases), lead: .oneDay,
            sources: [.assignment: { candidates.filter { $0.category == .assignment } },
                      .calendar: { candidates.filter { $0.category == .calendar } },
                      .class: { candidates.filter { $0.category == .class } }])
        require(budget.center.requests.count == 60 && budget.center.maxCount <= 60, "actual sink never exceeds global budget")
        require(budget.status.contains("15 個活動提醒因通知容量限制"), "deferral counts unique IDs")
        for label in ["作業", "行事曆", "課程"] {
            require(budget.status.contains("70 個\(label)提醒因通知容量限制"), "non-event drops visible: \(label)")
        }
        let duplicate = Fixture()
        duplicate.records += duplicate.records
        await duplicate.refresh()
        require(!duplicate.status.contains("容量限制"), "duplicate source rows are not capacity drops")
        let eventOff = Fixture()
        await eventOff.scheduler.refresh(enabled: [.class], lead: .oneDay,
            sources: [.class: { candidates.filter { $0.category == .class } }])
        require(eventOff.status.contains("活動提醒已關閉") && eventOff.status.contains("10 個課程提醒因通知容量限制"), "non-event drops visible even when events disabled")
        print("PASS: deduplicated budget count and per-category dropped-reminder status, including events disabled")
        let kept = budget.center.requests.keys.sorted()
        budget.failRead = true
        await budget.refresh()
        require(budget.center.requests.keys.sorted() == kept, "failed fetch retains budgeted valid event cache")
        print("PASS: strict Taipei dates, leap/cross-year, registered-only states, lead settings, cancellation, failure/cache/restart, authorization, session and add races, global budget")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-reminder-tests-") as temp:
    temp = Path(temp)
    source = temp / "Tests.swift"
    app_state = (root / "Core/Models/AppState.swift").read_text()
    settings_source = app_state[app_state.index("struct NotificationSettings {"):app_state.index("@MainActor\nprivate final class NotificationScheduler")]
    source.write_text(fixture + "\n" + settings_source)
    executable = temp / "checks"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", str(root / "Features/EventRegistration/Reminders/EventReminderScheduler.swift"), str(source), "-o", str(executable)], check=True)
    for timezone in ["Asia/Taipei", "America/Los_Angeles", "Pacific/Kiritimati"]:
        subprocess.run([str(executable)], env={**os.environ, "TZ": timezone}, check=True)
        print(f"Device timezone fixture: {timezone}")
