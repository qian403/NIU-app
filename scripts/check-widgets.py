#!/usr/bin/env python3
"""Offline regression checks for widget destinations and today's course selection.
Run on macOS with Xcode: python3 scripts/check-widgets.py
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "NIU-LiveActivities/NIU_LiveActivities.swift").read_text()

def block(marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private ", "")

models = "\n".join(block(marker) for marker in [
    "private struct TodayScheduleSummary", "private struct TodayScheduleItem",
    "private struct WidgetClassSchedule", "private struct WidgetClassPeriod",
    "private struct WidgetCourseInfo", "private extension String",
])
methods = "\n".join(block(marker) for marker in [
    "private func loadTodayScheduleSummary", "private func weekdayIndex",
    "private func focusedScheduleItems", "private func minutes(from label",
])
schedule = "import Foundation\n" + models + "\nstruct ScheduleCheck {\nlet fixture: WidgetClassSchedule?\nfunc loadSchedule() -> WidgetClassSchedule? { fixture }\n" + methods + "\n}\n"
schedule += r'''
@main struct ScheduleTests {
    static func main() {
        let course = WidgetCourseInfo(name: "Fixture", classroom: "A101", teacher: nil)
        let model = ScheduleCheck(fixture: WidgetClassSchedule(periods: [
            .init(id: "1", timeRange: "09:00~09:50", courses: ["0": course, "1": course]),
            .init(id: "3", timeRange: "11:00~11:50", courses: ["0": course, "1": course])
        ], dayHeaders: ["星期五", "星期六"]))
        func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        precondition(model.loadTodayScheduleSummary(now: date(18, 8, 0)).state == "今日第一堂")
        precondition(model.loadTodayScheduleSummary(now: date(18, 9, 0)).entries.first!.isCurrent)
        precondition(model.loadTodayScheduleSummary(now: date(18, 9, 50)).entries.first!.periodLabel == "3")
        precondition(model.loadTodayScheduleSummary(now: date(18, 11, 0)).entries.first!.isCurrent)
        precondition(model.loadTodayScheduleSummary(now: date(18, 11, 50)).entries.isEmpty)
        precondition(model.loadTodayScheduleSummary(now: date(18, 11, 50)).state == "今日課程結束")
        precondition(model.loadTodayScheduleSummary(now: date(19, 9, 10)).entries.first!.isCurrent)
        precondition(model.loadTodayScheduleSummary(now: date(20, 9, 10)).state == "今日無課")
        precondition(ScheduleCheck(fixture: nil).loadTodayScheduleSummary(now: date(18, 9, 0)).state == "未同步課表")
        print("PASS: before class, current class, break, end of day, weekend course and missing cache")
    }
}
'''

navigation = r'''
import Foundation

@main struct CheckNavigation {
    @MainActor static func main() async throws {
        for destination in [CampusDestination.classSchedule, .academicCalendar, .attendance, .library] {
            precondition(CampusDestination(url: destination.url) == destination)
        }
        for value in ["https://example.org/attendance", "niuapp://attendance?qrpass=bad", "niuapp://library/anything", "niuapp://unknown", "niuapp://user:password@library", "niuapp://library:99", "niuapp://attendance#scan"] {
            precondition(CampusDestination(url: URL(string: value)!) == nil)
        }
        let router = CampusRouter.shared
        router.open(.library)
        let firstID = router.pendingRequest!.id
        // The pending destination survives until the authenticated Home consumes it.
        precondition(router.pendingRequest?.destination == .library)
        router.open(.library)
        precondition(router.pendingRequest!.id != firstID)
        precondition(router.pendingRequest?.destination == .library)
        router.pendingRequest = nil
        _ = try await OpenCampusIntent(.attendance).perform()
        precondition(router.pendingRequest?.destination == .attendance)
        _ = try await OpenCampusIntent(.library).perform()
        precondition(router.pendingRequest?.destination == .library)
        print("PASS: destination allowlist, repeat requests, pending navigation, and both foreground intents")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-widget-check-") as directory:
    temporary = Path(directory)
    for name, code, sources in [
        ("navigation", navigation, [str(root / "NIU-LiveActivities/CampusNavigation.swift")]),
        ("schedule", schedule, []),
    ]:
        swift = temporary / (name + ".swift")
        binary = temporary / name
        swift.write_text(code)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macos26.0",
                        "-module-cache-path", str(Path(tempfile.gettempdir()) / "niu-widget-module-cache"),
                        *sources, str(swift), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
