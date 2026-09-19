#!/usr/bin/env python3
"""Run real Swift calendar store/date/view-model/widget presentation regressions offline."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'NIU-LiveActivities/NIU_LiveActivities.swift').read_text()


def block(marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '')


widget = '\n'.join(block(m) for m in ['private struct CalendarSummary', 'private struct CalendarItem'])
widget += '\nstruct WidgetCalendarCheck {\n' + '\n'.join(block(m) for m in [
    'private func calendarSummary', 'private func makeCalendarItem', 'private func displayDateRange',
    'private func dayLabel', 'private func monthLabel']) + '\n}\n'

checks = r'''
import Foundation
import CryptoKit

func require(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
}
func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func encoded(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
func entry(_ data: Data) throws -> [String: Any] {
    let doc = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let year = doc["academicYear"] as! Int
    return ["academicYear": year, "revision": doc["revision"]!, "path": "years/\(year).json", "sha256": digest(data)]
}
func catalog(_ documents: [Data]) throws -> Data {
    try encoded(["schemaVersion": 1, "calendars": documents.map { try entry($0) }])
}
actor FixtureServer {
    var index: Data
    var documents: [String: Data]
    var failing = false
    var calls = 0
    init(index: Data, documents: [String: Data]) { self.index = index; self.documents = documents }
    func set(index: Data? = nil, documents: [String: Data]? = nil, failing: Bool = false) {
        if let index { self.index = index }
        if let documents { self.documents = documents }
        self.failing = failing
    }
    func fetch(_ url: URL) throws -> Data {
        calls += 1
        if failing { throw URLError(.notConnectedToInternet) }
        if url.lastPathComponent == "index.json" { return index }
        guard let data = documents[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
        return data
    }
}

actor CatalogRaceServer {
    let oldIndex: Data
    let newIndex: Data
    let documents: [String: Data]
    private var first = true
    private var continuation: CheckedContinuation<Data, Never>?
    init(oldIndex: Data, newIndex: Data, documents: [String: Data]) {
        self.oldIndex = oldIndex; self.newIndex = newIndex; self.documents = documents
    }
    func fetch(_ url: URL) async throws -> Data {
        if url.lastPathComponent != "index.json" { return documents[url.lastPathComponent]! }
        if first {
            first = false
            return await withCheckedContinuation { continuation = $0 }
        }
        return newIndex
    }
    func isWaiting() -> Bool { continuation != nil }
    func releaseOldResponse() { continuation?.resume(returning: oldIndex); continuation = nil }
}

actor DocumentRaceServer {
    let oldIndex: Data
    let newIndex: Data
    let documents: [String: Data]
    private var firstIndex = true
    private var continuation: CheckedContinuation<Data, Never>?
    init(oldIndex: Data, newIndex: Data, documents: [String: Data]) {
        self.oldIndex = oldIndex; self.newIndex = newIndex; self.documents = documents
    }
    func fetch(_ url: URL) async throws -> Data {
        if url.lastPathComponent == "index.json" {
            if firstIndex { firstIndex = false; return oldIndex }
            return newIndex
        }
        if url.lastPathComponent == "114.json" {
            return await withCheckedContinuation { continuation = $0 }
        }
        return documents[url.lastPathComponent]!
    }
    func isWaiting() -> Bool { continuation != nil }
    func releaseDocument() { continuation?.resume(returning: documents["114.json"]!); continuation = nil }
}

@main struct CalendarClientChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundle = root.appendingPathComponent("Resources/AcademicCalendar")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("niu-calendar-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let d114 = try Data(contentsOf: bundle.appendingPathComponent("years/114.json"))
        let d115 = try Data(contentsOf: bundle.appendingPathComponent("years/115.json"))
        let indexData = try Data(contentsOf: bundle.appendingPathComponent("index.json"))
        let index = try JSONDecoder().decode(CampusCalendarIndex.self, from: indexData)
        try index.validate()
        let doc = try CampusCalendarDocument.decode(d115, entry: index.calendars.first { $0.academicYear == 115 }!)
        let server = FixtureServer(index: indexData, documents: ["114.json": d114, "115.json": d115])
        let store = AcademicCalendarStore(directory: temp, bundleDirectory: bundle, fetch: { try await server.fetch($0) })
        let sep = instant("2026-09-19T04:00:00Z")
        let aug = instant("2027-07-31T16:00:00Z")

        // January is inside the same academic year; August switches at Taiwan midnight.
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        require(CampusCalendarDate.academicYear(at: instant("2026-12-31T15:59:59Z")) == 115, "Dec31")
        require(CampusCalendarDate.academicYear(at: instant("2026-12-31T16:00:00Z")) == 115, "Jan1 same school year")
        require(CampusCalendarDate.academicYear(at: aug.addingTimeInterval(-1)) == 115, "July31")
        require(CampusCalendarDate.academicYear(at: aug) == 116, "Aug1 Taipei year rollover")
        require(CampusCalendarDate.parse("2027-02-29") == nil, "reject normalized invalid date")
        require(CampusCalendarDate.parse("2028-02-29") != nil, "accept leap day")
        require(CampusCalendarDate.tomorrow(after: instant("2027-07-31T15:59:59Z")) == aug, "midnight widget boundary")
        let exam = doc.events.first { $0.title == "期末考試" && $0.semester == 1 }!
        require(exam.contains(instant("2027-01-10T15:59:59Z")), "inclusive last day")
        require(!exam.contains(instant("2027-01-10T16:00:00Z")), "following day excluded")
        let uiExam = CalendarEvent(exam, document: doc)
        require(uiExam.months == [12, 1], "cross-year event in both months")
        require(uiExam.dateString == "12/21 - 01/10", "device timezone cannot shift displayed dates")
        let warning = doc.events.first { $0.title == "期中預警開始" }!
        require(CalendarEvent(warning, document: doc).inferredType == .academic, "do not infer exam from 期中")
        require(CampusCalendarDate.monthOrder == [8,9,10,11,12,1,2,3,4,5,6,7], "academic month order")

        let offline = await store.cached(year: 115)
        require(offline.document?.academicYear == 115 && offline.origin == .bundled, "offline current-year bundle")
        let missingCache = await store.cached(year: 116)
        require(missingCache.document == nil, "never fall back to wrong bundled year")
        let online = await store.refresh(year: 115, now: sep)
        require(online.document?.revision == 1 && online.notice == nil, "verified catalog refresh")
        let calls1 = await server.calls
        _ = await store.refresh(year: 115, now: sep.addingTimeInterval(1800))
        let calls2 = await server.calls
        require(calls1 == calls2, "bounded automatic refresh")
        _ = await store.refresh(year: 115, now: sep.addingTimeInterval(3600), force: true)
        let calls3 = await server.calls
        require(calls3 > calls2, "pull-to-refresh ignores index TTL")
        let unavailable = await store.refresh(year: 116, now: aug)
        require(unavailable.document == nil && unavailable.isNotPublished, "new year not published explicitly")
        let calls4 = await server.calls
        require(calls4 > calls3, "rollover forces fresh catalog")
        require(unavailable.availableYears.contains(114) && unavailable.availableYears.contains(115), "history remains selectable")
        let widget = WidgetCalendarCheck()
        let missingSummary = widget.calendarSummary(result: unavailable, now: aug)
        require(missingSummary.title == "行事曆尚未公布" && missingSummary.state == "116 學年度", "widget missing-year state")
        let summary = widget.calendarSummary(result: online, now: instant("2027-01-10T15:00:00Z"))
        require(summary.entries.contains { $0.title == "期末考試" }, "widget includes final day of exam")

        // A future year in the index must not become today's default.
        let viewModel = AcademicCalendarViewModel(store: store, now: instant("2026-07-30T04:00:00Z"))
        await viewModel.reload(now: instant("2026-07-30T04:00:00Z"))
        require(viewModel.currentSemester == "114" && viewModel.availableYears.contains(115), "future announced year is selectable, not default")
        require(viewModel.handleDateChange(now: instant("2026-07-31T16:00:00Z")), "visible view follows August rollover")
        await viewModel.reload(now: instant("2026-07-31T16:00:00Z"))
        require(viewModel.currentCalendar?.academicYear == "115", "new-year view loads new data")
        _ = viewModel.handleDateChange(now: instant("2026-12-15T04:00:00Z"))
        viewModel.selectMonth(12)
        require(!viewModel.handleDateChange(now: instant("2026-12-31T16:00:00Z")), "Jan rollover does not change academic year")
        require(viewModel.selectedMonth == 1, "month follows January")
        viewModel.switchSemester(to: "114")
        require(!viewModel.handleDateChange(now: aug), "manual historical selection is preserved")
        require(viewModel.currentSemester == "114", "do not switch history under user")
        viewModel.switchSemester(to: "116")
        await viewModel.reload(now: aug)
        require(viewModel.currentCalendar == nil && viewModel.isNotPublished, "no stale currentCalendar under missing year")

        // Valid updates replace the complete snapshot, including deleted entries.
        var newer = try JSONSerialization.jsonObject(with: d115) as! [String: Any]
        newer["revision"] = 2
        newer["updatedAt"] = "2026-09-20T00:00:00Z"
        var events = newer["events"] as! [[String: Any]]
        let removedID = events.removeFirst()["id"] as! String
        newer["events"] = events
        let d2 = try encoded(newer)
        await server.set(index: try catalog([d114, d2]), documents: ["114.json":d114, "115.json":d2])
        let updated = await store.refresh(year: 115, now: sep.addingTimeInterval(86400), force: true)
        require(updated.document?.revision == 2 && updated.document?.events.contains { $0.id == removedID } == false, "complete snapshot replacement")
        let cold = AcademicCalendarStore(directory: temp, bundleDirectory: bundle, fetch: { try await server.fetch($0) })
        let persisted = await cold.cached(year: 115)
        require(persisted.document?.revision == 2 && persisted.origin == .cached, "cache survives process restart")
        await server.set(failing: true)
        let failure = await cold.refresh(year: 115, now: sep.addingTimeInterval(86401), force: true)
        require(failure.document?.revision == 2 && failure.notice != nil, "offline retains newest matching-year cache")
        let newYearOffline = await cold.refresh(year: 116, now: aug, force: true)
        require(newYearOffline.document == nil && !newYearOffline.isNotPublished, "network error cannot claim not-published")
        await server.set(index: indexData, documents: ["114.json":d114,"115.json":d115])
        let rollback = await cold.refresh(year: 115, now: sep.addingTimeInterval(86402), force: true)
        require(rollback.document?.revision == 2 && rollback.notice != nil, "old CDN catalog cannot downgrade revision")
        // Hash mismatch must not contaminate persisted cache.
        newer["revision"] = 3
        let d3 = try encoded(newer)
        await server.set(index: try catalog([d114, d3]), documents: ["114.json":d114,"115.json":d115])
        let corrupt = await cold.refresh(year: 115, now: sep.addingTimeInterval(86403), force: true)
        require(corrupt.document?.revision == 2 && corrupt.notice != nil, "hash mismatch keeps valid cache")
        await server.set(index: try encoded(["schemaVersion":2,"calendars":[]]))
        let unsupported = await cold.refresh(year: 115, now: sep.addingTimeInterval(86404), force: true)
        require(unsupported.document?.revision == 2 && unsupported.notice?.contains("更新 App") == true, "future schema retains readable cache")

        // Separate store instances model app/widget sharing the same filesystem cache.
        let raceServer = CatalogRaceServer(oldIndex: try catalog([d114]), newIndex: indexData,
                                          documents: ["114.json":d114, "115.json":d115])
        let racePath = temp.appendingPathComponent("race")
        let raceA = AcademicCalendarStore(directory: racePath, bundleDirectory: nil, fetch: { try await raceServer.fetch($0) })
        let raceB = AcademicCalendarStore(directory: racePath, bundleDirectory: nil, fetch: { try await raceServer.fetch($0) })
        let slow = Task { await raceA.refresh(year: 114, now: sep, force: true) }
        while !(await raceServer.isWaiting()) { await Task.yield() }
        let fast = await raceB.refresh(year: 114, now: sep.addingTimeInterval(1), force: true)
        require(fast.availableYears.contains(115), "new catalog discovered future year")
        await raceServer.releaseOldResponse()
        let slowResult = await slow.value
        require(slowResult.availableYears.contains(115), "late old response cannot hide discovered year")
        let raceReload = await raceA.refresh(year: 115, now: sep.addingTimeInterval(2))
        require(raceReload.document?.academicYear == 115 && !raceReload.isNotPublished, "cross-store catalog remains monotonic")
        let documentRace = DocumentRaceServer(oldIndex: try catalog([d114]), newIndex: indexData,
                                              documents: ["114.json":d114,"115.json":d115])
        let documentPath = temp.appendingPathComponent("document-race")
        let documentA = AcademicCalendarStore(directory: documentPath, bundleDirectory: nil, fetch: { try await documentRace.fetch($0) })
        let documentB = AcademicCalendarStore(directory: documentPath, bundleDirectory: nil, fetch: { try await documentRace.fetch($0) })
        let delayedDocument = Task { await documentA.refresh(year: 114, now: sep, force: true) }
        while !(await documentRace.isWaiting()) { await Task.yield() }
        _ = await documentB.refresh(year: 115, now: sep.addingTimeInterval(1), force: true)
        await documentRace.releaseDocument()
        let afterDocument = await delayedDocument.value
        require(afterDocument.availableYears.contains(115), "late document response retains concurrently discovered year")
        print("PASS: concurrent old/new catalogs from independent app/widget stores")

        let warningPeriod = CalendarEvent(id: "period", title: "期中預警開始", description: nil,
                                    startDate: "2026-09-21", endDate: "2026-11-20", type: .academic)
        require(warningPeriod.displayTitle == "期中預警期間" && warningPeriod.title == "期中預警開始", "period presentation preserves official title")
        require(warningPeriod.isBoundary(on: instant("2026-09-20T16:00:00Z")), "opening is a daily item")
        require(warningPeriod.isBoundary(on: instant("2026-11-19T16:00:00Z")), "inclusive closing is a daily item")
        require(warningPeriod.contains(instant("2026-10-01T00:00:00Z")) && !warningPeriod.isBoundary(on: instant("2026-10-01T00:00:00Z")), "interior days are ongoing only")
        let feb = AcademicCalendarMonth(academicYear: 116, month: 2)
        require(feb.days.count == 29 && CampusCalendarDate.dayKey(feb.start) == "2028-02-01", "leap February belongs to next civil year")
        require(feb.cells.count % 7 == 0 && feb.cells.compactMap { $0 }.count == 29, "grid includes each day once with whole weeks")
        let august = AcademicCalendarMonth(academicYear: 115, month: 8)
        require(august.leadingEmptyDays == 6 && august.cells.count == 42, "Saturday-start month needs six rows")
        let sunday = AcademicCalendarMonth(academicYear: 114, month: 2)
        require(sunday.leadingEmptyDays == 0 && sunday.cells.count == 28, "Sunday-start February needs no leading/trailing week")
        require(CampusCalendarDate.dayKey(feb.selectedDate(day: 31)) == "2028-02-29", "selection clamps in shorter months")
        require(CampusCalendarDate.dayKey(august.selectedDate(day: nil, now: instant("2026-08-14T16:01:00Z"))) == "2026-08-15", "month opens at Taipei today")
        require(CampusCalendarDate.dayKey(feb.selectedDate(day: nil, now: sep)) == "2028-02-01", "other month opens at first day")
        let october = AcademicCalendarMonth(academicYear: 115, month: 10)
        let oneDay = CalendarEvent(id: "one-day", title: "單日測試", description: nil,
                                  startDate: "2026-10-05", endDate: nil, type: .academic)
        let closesFirst = CalendarEvent(id: "closes-first", title: "跨月測試", description: nil,
                                       startDate: "2026-09-30", endDate: "2026-10-01", type: .registration)
        let endsBefore = CalendarEvent(id: "past", title: "已結束", description: nil,
                                      startDate: "2026-09-01", endDate: "2026-09-30", type: .activity)
        let nextMonth = CalendarEvent(id: "future", title: "下月事件", description: nil,
                                     startDate: "2026-11-01", endDate: nil, type: .exam)
        let eventSections = october.eventSections([nextMonth, oneDay, endsBefore, warningPeriod, closesFirst])
        require(eventSections.count == 2 && eventSections[0].date == nil, "carry-over periods grouped before monthly start dates")
        require(eventSections.flatMap(\.events).map(\.id) == ["period", "closes-first", "one-day"], "monthly list includes overlapping periods once, excludes other months, sorts chronologically")
        require(october.eventSections([]).isEmpty, "empty month/filter produces no sections")
        let januarySections = AcademicCalendarMonth(academicYear: 115, month: 1).eventSections([uiExam])
        require(januarySections.count == 1 && januarySections[0].date == nil, "December to January carry-over stays in same academic year")
        print("PASS: monthly event list, inclusive overlaps, carry-over periods without daily duplicates")
        print("PASS: month grid alignment, leap day, academic/civil year and selected date")

        print("PASS: Taipei January/August rollover, month spans, inclusive dates, widget states, future-year selection")
        print("PASS: shared cache restart, forced/periodic refresh, unpublished vs offline, revisions, deletions, SHA/schema rejection")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='niu-calendar-swift-') as folder:
    path = Path(folder)
    main = path / 'Checks.swift'
    main.write_text(checks.replace('@main struct CalendarClientChecks', widget + '\n@main struct CalendarClientChecks'))
    binary = path / 'checks'
    sources = ['NIU-LiveActivities/AcademicCalendarStore.swift',
               'Features/AcademicCalendar/Models/AcademicCalendarModels.swift',
               'Features/AcademicCalendar/ViewModels/AcademicCalendarViewModel.swift']
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-target', 'arm64-apple-macos26.0',
                    '-module-cache-path', '/tmp/niu-calendar-module-cache',
                    *[str(ROOT / s) for s in sources], str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(ROOT)], check=True)
