#!/usr/bin/env python3
"""Offline regression checks for widget destinations and today's course selection.
Run on macOS with Xcode: python3 scripts/check-widgets.py
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "NIU-LiveActivities/NIU_LiveActivities.swift").read_text()
live_activity_source = (root / "NIU-LiveActivities/NIU_LiveActivitiesLiveActivity.swift").read_text()

# The schedule model already normalizes period labels to "第…節". Keep the
# Dynamic Island from adding another prefix/suffix around that display value.
assert 'Label("第\\(context.state.periodLabel)節"' not in live_activity_source
assert 'Label(context.state.periodLabel, systemImage: "clock")' in live_activity_source

def block(marker, text=source):
    start = text.index(marker)
    brace = text.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end].replace("private ", "")

models = "\n".join(block(marker) for marker in [
    "private struct TodayScheduleSummary", "private struct TodayScheduleItem",
    "private extension String", "private func largeScheduleEntryLimit",
    "private func visibleLargeScheduleEntries",
])
methods = "\n".join(block(marker) for marker in [
    "private func loadTodayScheduleSummary", "private func weekdayIndex",
    "private func focusedScheduleItems", "private func minutes(from label",
])
schedule = "import Foundation\n" + models + "\nstruct ScheduleCheck {\nlet fixture: ClassSchedule?\nfunc loadSchedule(at date: Date) -> ClassSchedule? { fixture }\n" + methods + "\n}\n"
schedule += r'''
@main struct ScheduleTests {
    static func main() {
        let course = CourseInfo(name: "Fixture", teacher: nil, classroom: "A101")
        let model = ScheduleCheck(fixture: ClassSchedule(periods: [
            .init(id: "1", timeRange: "09:00~09:50", courses: [0: course, 1: course]),
            .init(id: "3", timeRange: "11:00~11:50", courses: [0: course, 1: course]),
            .init(id: "5", timeRange: "13:00~13:50", courses: [0: course, 1: course]),
            .init(id: "6", timeRange: "14:00~14:50", courses: [0: course, 1: course]),
            .init(id: "7", timeRange: "15:00~15:50", courses: [0: course, 1: course]),
            .init(id: "8", timeRange: "16:00~16:50", courses: [0: course, 1: course])
        ], dayCount: 2, dayHeaders: ["星期五", "星期六"], fetchedAt: Date()))
        func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            ScheduleClock.calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        precondition(model.loadTodayScheduleSummary(now: date(18, 8, 0)).state == "今日第一堂")
        precondition(model.loadTodayScheduleSummary(now: date(18, 8, 0)).entries.count == 6)
        precondition(model.loadTodayScheduleSummary(now: date(18, 9, 0)).entries.first!.isCurrent)
        precondition(model.loadTodayScheduleSummary(now: date(18, 9, 0)).entries.count == 6)
        precondition(model.loadTodayScheduleSummary(now: date(18, 9, 50)).entries.first!.periodLabel == "3")
        precondition(model.loadTodayScheduleSummary(now: date(18, 9, 50)).entries.count == 5)
        precondition(model.loadTodayScheduleSummary(now: date(18, 11, 0)).entries.first!.isCurrent)
        precondition(model.loadTodayScheduleSummary(now: date(18, 11, 50)).entries.first!.periodLabel == "5")
        precondition(model.loadTodayScheduleSummary(now: date(18, 16, 50)).entries.isEmpty)
        precondition(model.loadTodayScheduleSummary(now: date(18, 16, 50)).state == "今日課程結束")
        precondition(model.loadTodayScheduleSummary(now: date(19, 9, 10)).entries.first!.isCurrent)
        precondition(model.loadTodayScheduleSummary(now: date(20, 9, 10)).state == "今日無課")
        precondition(ScheduleCheck(fixture: nil).loadTodayScheduleSummary(now: date(18, 9, 0)).state == "未同步課表")
        let horizon = model.fixture!.timelineDates(after: date(18, 8, 0))
        precondition(horizon.contains(date(19, 9, 0)))
        precondition(horizon.contains(date(19, 11, 50)))
        precondition(horizon.last == date(25, 0, 0))
        precondition(horizon == Array(Set(horizon)).sorted())
        precondition(model.fixture!.sessions(on: date(19, 9, 0)).count == 6)
        precondition(model.fixture!.sessions(on: date(20, 9, 0)).isEmpty)
        precondition(largeScheduleEntryLimit(isAccessibilitySize: false) == 5)
        precondition(largeScheduleEntryLimit(isAccessibilitySize: true) == 3)
        let identifiers = [1, 2, 3, 4, 5, 6]
        precondition(visibleLargeScheduleEntries(identifiers, isAccessibilitySize: false) == [1, 2, 3, 4, 5])
        precondition(visibleLargeScheduleEntries(identifiers, isAccessibilitySize: true) == [1, 2, 3])
        precondition(ClassPeriod(id: "bad", timeRange: "25:00~26:00", courses: [:]).startMinutes == nil)
        let decoded = try! JSONDecoder().decode(ClassSchedule.self, from: JSONEncoder().encode(model.fixture!))
        precondition(decoded.sessions(on: date(19, 9, 0)) == model.fixture!.sessions(on: date(19, 9, 0)))
        let blocks = model.fixture!.sessions(on: date(18, 9, 0)).mergedConsecutiveCourses()
        precondition(blocks.map(\.periods.count) == [1, 1, 4], "Only same-course periods with a short break merge")
        precondition(blocks[2].session.start == date(18, 13, 0) && blocks[2].session.end == date(18, 16, 50))
        precondition(blocks[2].session.periodLabel == "第5–8節")
        precondition(blocks[2].periods.first == date(18, 13, 0)...date(18, 13, 50), "Breaks stay outside period spans")
        precondition(blocks[0].session == model.fixture!.sessions(on: date(18, 9, 0))[0], "Single period stays unchanged")
        let other = CourseInfo(name: "Other", teacher: nil, classroom: "A101")
        let mixed = ClassSchedule(periods: [
            .init(id: "1", timeRange: "08:10~09:00", courses: [0: course]),
            .init(id: "2", timeRange: "09:10~10:00", courses: [0: other]),
            .init(id: "3", timeRange: "10:10~11:00", courses: [0: course]),
            .init(id: "4", timeRange: "11:10~12:00", courses: [0: CourseInfo(name: " Fixture ")]),
        ], dayCount: 1, dayHeaders: ["星期五"], fetchedAt: Date())
        let mixedBlocks = mixed.sessions(on: date(18, 8, 0)).mergedConsecutiveCourses()
        precondition(mixedBlocks.map(\.periods.count) == [1, 1, 2], "A different course in between splits the block")
        precondition(mixedBlocks[2].session.periodLabel == "第3–4節")
        print("PASS: consecutive same-course periods merge; breaks, lunch and other courses split")
        print("PASS: seven-day horizon, shared cache format, Taipei timezone, invalid hours")
        print("PASS: before class, current class, break, end of day, weekend course and missing cache")
    }
}
'''

navigation = r'''
import Foundation

@main struct CheckNavigation {
    @MainActor static func main() async throws {
        for destination in [CampusDestination.classSchedule, .academicCalendar, .attendance, .library, .mail, .moodle] {
            precondition(CampusDestination(url: destination.url) == destination)
        }
        let links: [(String, CampusDestination)] = [("schedule", .classSchedule), ("calendar", .academicCalendar),
            ("attendance", .attendance), ("library", .library), ("mail", .mail), ("moodle", .moodle)]
        for (path, destination) in links {
            for value in ["https://niu-life.app/open/\(path)", "https://NIU-LIFE.app/open/\(path)/",
                          "https://niu-life.app/open/\(path)?fbclid=ignored"] {
                precondition(CampusDestination(universalLink: URL(string: value)!) == destination, value)
            }
        }
        for value in ["https://niu-life.app/download", "https://niu-life.app/", "https://niu-life.app/open/unknown",
                      "https://niu-life.app/open/library/extra", "https://niu-life.app/open", "https://niu-life.app/Open/library",
                      "http://niu-life.app/open/library", "https://www.niu-life.app/open/library",
                      "https://evil.example/open/library", "https://niu-life.app.evil.example/open/library",
                      "https://user:secret@niu-life.app/open/library", "https://niu-life.app:8443/open/library",
                      "niuapp://library"] {
            precondition(CampusDestination(universalLink: URL(string: value)!) == nil, value)
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
        print("PASS: destination allowlist, niu-life.app universal links, repeat requests, pending navigation, and both foreground intents")
    }
}
'''

progress_helpers = "\n".join(block(marker, live_activity_source) for marker in [
    "private struct CourseProgressConfiguration", "private func courseProgressConfiguration",
])
progress = "import Foundation\n" + progress_helpers + r'''
@main struct CheckLiveActivityProgress {
    static func main() {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        for (mode, isStale) in [("current", false), ("upcoming", false)] {
            let configuration = courseProgressConfiguration(
                mode: mode,
                isStale: isStale,
                startDate: start,
                endDate: end
            )
            precondition(configuration?.interval == start...end)
            precondition(configuration?.countsDown == false)
        }
        precondition(courseProgressConfiguration(
            mode: "upcoming",
            isStale: true,
            startDate: start,
            endDate: end
        ) == nil)
        precondition(courseProgressConfiguration(mode: "current", isStale: false, startDate: end, endDate: start) == nil)
        print("PASS: elapsed course progress stays mounted for active/upcoming states; stale state waits for App refresh")
    }
}
'''

watch_source = root / "NIU-LiveActivities/ClassWatchActivityPresentation.swift"
attributes_source = (root / "NIU-LiveActivities/ClassLiveActivityAttributes.swift").read_text()
watch = "import Foundation\nenum ClassLiveActivityAttributes {\n" + block(
    "public struct ContentState", attributes_source
) + "\n}\n" + r'''
@main struct CheckWatchPresentation {
    static func main() {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 3700)
        func presentation(mode: String = "current", stale: Bool = false,
                          name: String = "資訊安全導論", room: String = "工102",
                          period: String = "第3節", from: Date = start,
                          to: Date = end) -> ClassWatchActivityPresentation {
            .init(state: .init(mode: mode, courseName: name, classroom: room,
                               teacher: "合成教師", periodLabel: period,
                               startDate: from, endDate: to), isStale: stale)
        }
        let current = presentation()
        precondition(current.statusLabel == "上課中")
        precondition(current.countdownEnd == end && current.countdownLabel == "下課")
        precondition(current.progressInterval == start...end)
        precondition(current.periodLabel == "第3節", "No duplicate period prefix")
        let upcoming = presentation(mode: "upcoming")
        precondition(upcoming.statusLabel == "下一堂課")
        precondition(upcoming.countdownEnd == start && upcoming.countdownLabel == "上課")
        precondition(upcoming.progressInterval == start...end, "Course progress remains timer-backed")
        for invalid in [presentation(stale: true), presentation(mode: "unknown"),
                        presentation(from: end, to: start), presentation(from: start, to: start)] {
            precondition(invalid.needsRefresh && invalid.statusLabel == "課表待更新")
            precondition(invalid.countdownEnd == nil && invalid.progressInterval == nil,
                         "Stale or malformed state must not show a running countdown")
            precondition(invalid.courseName == "資訊安全導論", "Keep context when asking to refresh")
        }
        let missing = presentation(name: " \n", room: "  ", period: "\n")
        precondition(missing.courseName == "課程名稱未提供")
        precondition(missing.classroom == "教室未提供")
        precondition(missing.periodLabel == nil)
        precondition(presentation(name: "  課程  ", room: " 工102\n").courseName == "課程")
        func t(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        let merged = ClassWatchActivityPresentation(state: .init(
            mode: "current", courseName: "資訊安全導論", classroom: "工102", teacher: "合成教師",
            periodLabel: "第3–5節", startDate: start, endDate: t(10300),
            periodStartDates: [start, t(3700), t(7300)], periodEndDates: [t(3100), t(6700), t(10300)]), isStale: false)
        precondition(merged.progressSegments == [start...t(3100), t(3700)...t(6700), t(7300)...t(10300)], "Breaks are nodes, not bar time")
        precondition(merged.progressInterval == start...Date(timeIntervalSince1970: 10300), "Countdown covers the whole block")
        precondition(current.progressSegments == nil, "One period keeps the single bar")
        for (starts, ends) in [([t(3700), t(7300)], [t(6700), t(10300)]), ([start, t(3700)], [t(3100)]),
                               ([start, t(3700)], [t(4000), t(10300)]), ([start, t(3700)], nil)] {
            let state = ClassLiveActivityAttributes.ContentState(
                mode: "current", courseName: "x", classroom: "x", teacher: "x", periodLabel: "x",
                startDate: start, endDate: t(10300), periodStartDates: starts, periodEndDates: ends)
            precondition(state.progressSegments == [start...t(10300)], "Malformed starts fall back to total bar")
        }
        let legacy = try! JSONDecoder().decode(ClassLiveActivityAttributes.ContentState.self, from: Data(
            #"{"mode":"current","courseName":"x","classroom":"x","teacher":"x","periodLabel":"x","startDate":0,"endDate":60}"#.utf8))
        precondition(legacy.periodStartDates == nil && legacy.progressSegments?.count == 1, "Pushes without period starts still decode")
        precondition(ClassWatchActivityPresentation(state: merged.state, isStale: true).progressSegments == nil)
        print("PASS: merged period segments, malformed fallback and legacy push payloads")
        print("PASS: Watch current/upcoming deadlines, stale/invalid state, missing fields and period labels")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-widget-check-") as directory:
    temporary = Path(directory)
    for name, code, sources in [
        ("navigation", navigation, [str(root / "NIU-LiveActivities/CampusNavigation.swift")]),
        ("schedule", schedule, [str(root / "NIU-LiveActivities/ClassScheduleModels.swift")]),
        ("progress", progress, []),
        ("watch", watch, [str(watch_source)]),
    ]:
        swift = temporary / (name + ".swift")
        binary = temporary / name
        swift.write_text(code)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macos26.0",
                        "-module-cache-path", str(Path(tempfile.gettempdir()) / "niu-widget-module-cache"),
                        *sources, str(swift), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
