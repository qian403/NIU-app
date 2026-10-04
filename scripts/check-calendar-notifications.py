#!/usr/bin/env python3
"""Exercise the production calendar notification source with synthetic academic years."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = (root / 'Core/Models/AppState.swift').read_text()
helper = app[app.index('@MainActor\nenum CalendarNotificationSource'):app.index('public extension String {')]
fixture = r'''
import Foundation
func date(_ day: String) -> Date { CampusCalendarDate.parse(day)! }
func document(_ year: Int, _ day: String, _ id: String) -> CampusCalendarDocument {
    CampusCalendarDocument(schemaVersion: 1, academicYear: year, revision: 1, updatedAt: "", timeZone: "Asia/Taipei",
        startDate: "", endDate: "", sources: [], semesters: [], events: [
            CampusCalendarEvent(id: id, title: "合成截止事項", startDate: day, endDate: day, category: .deadline,
                semester: 2, note: nil, sourceId: "fixture", sourcePage: 1, sourceText: "合成資料")], weeks: [])
}
func pending(_ id: String, _ day: String, owner: String = "A") -> PendingManagedNotification {
    PendingManagedNotification(id: id, session: owner, value: ManagedNotification(id: id, category: .calendar,
        title: "合成提醒", body: "", fireDate: date(day)))
}
@main struct Checks {
    @MainActor static func main() async throws {
        let now = date("2026-07-15")
        let current = document(114, "2026-07-25", "july")
        let next = document(115, "2026-08-05", "august")
        let first = try await CalendarNotificationSource.load(now: now, existing: [], owner: "A") { year, _ in
            year == 114 ? current : nil
        }
        precondition(first.count == 1 && first[0].id == "notify.calendar.july")
        precondition(CampusCalendarDate.format(first[0].fireDate, "yyyy-MM-dd HH:mm") == "2026-07-24 08:00")
        let old = [pending("notify.calendar.next", "2026-08-03"),
                   pending("notify.calendar.removed", "2026-07-23"),
                   pending("notify.calendar.foreign", "2026-08-04", owner: "B"),
                   pending("notify.calendar.elapsed", "2025-08-03")]
        let partial = try await CalendarNotificationSource.load(now: now, existing: old, owner: "A") { year, _ in
            year == 114 ? current : nil
        }
        precondition(Set(partial.map(\.id)) == ["notify.calendar.july", "notify.calendar.next"])
        let complete = try await CalendarNotificationSource.load(now: now, existing: old, owner: "A") { year, _ in
            year == 114 ? current : next
        }
        precondition(Set(complete.map(\.id)) == ["notify.calendar.july", "notify.calendar.august"])
        let futureOnly = try await CalendarNotificationSource.load(now: now, existing: old, owner: "A") { year, _ in
            year == 115 ? next : nil
        }
        precondition(Set(futureOnly.map(\.id)) == ["notify.calendar.removed", "notify.calendar.august"])
        do {
            _ = try await CalendarNotificationSource.load(now: now, existing: old, owner: "A") { _, _ in nil }
            preconditionFailure("all unavailable must preserve category through reconciler error")
        } catch is URLError {}
        print("PASS: July/August partial success, first-enable current-year reminder, unavailable-year retention, successful-year deletion, session isolation, all-unavailable error")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='niu-calendar-notifications-') as directory:
    directory = Path(directory)
    source = directory / 'Checks.swift'
    source.write_text(fixture + '\n' + helper)
    binary = directory / 'checks'
    files = ['NIU-LiveActivities/AcademicCalendarStore.swift',
             'Features/AcademicCalendar/Models/AcademicCalendarModels.swift',
             'Features/EventRegistration/Reminders/EventReminderScheduler.swift']
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                    *[str(root / path) for path in files], str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
