#!/usr/bin/env python3
"""Compile the real custom course model and exercise merge, expiry and conflicts with synthetic data only."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHECKS = r'''
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
let monday = instant("2026-10-05T00:35:00Z")    // Taipei Mon 2026-10-05 08:35
let wednesday = instant("2026-10-07T02:00:00Z") // Taipei Wed 2026-10-07 10:00
let school = CourseInfo(name: "微積分", teacher: "教師甲", classroom: "E101")
let periods = (1...8).map { row -> ClassPeriod in
    let hour = row + 7
    var courses: [Int: CourseInfo] = [:]
    if row == 2 || row == 3 { courses[0] = school }   // 星期一 第2–3節
    return ClassPeriod(id: "\(row)", timeRange: String(format: "%02d:10~%02d:00", hour, hour + 1), courses: courses)
}
var base = ClassSchedule(periods: periods, dayCount: 5,
                         dayHeaders: ["星期一", "星期二", "星期三", "星期四", "星期五"], fetchedAt: monday)
func course(_ name: String, _ weekdays: [Int], _ start: String, _ end: String, until lastDay: String = "2027-01-31") -> CustomCourse {
    CustomCourse(id: UUID(), name: name, classroom: " 社辦 ", note: "", weekdays: weekdays,
                 startPeriodID: start, endPeriodID: end, lastDay: lastDay)
}

@main struct Checks {
    static func main() {
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        base.ownerSessionID = "session-a"

        require(CustomCourse.dayString(instant("2026-10-06T16:30:00Z")) == "2026-10-07", "Taipei date, not device date")
        require(CustomCourse.dayString(CustomCourse.date(fromDay: "2027-01-31")!) == "2027-01-31", "day string round trip")
        let club = course("社團", [2], "7", "8")
        require(club.isActive(on: wednesday), "active before last day")
        require(course("x", [2], "1", "1", until: "2026-10-07").isActive(on: instant("2026-10-07T15:59:59Z")), "last day inclusive")
        require(!course("x", [2], "1", "1", until: "2026-10-07").isActive(on: instant("2026-10-07T16:00:00Z")), "hidden after last day")
        require(club.periodRange(in: periods) == 6...7, "period IDs resolve to rows")
        require(course("x", [0], "5", "3").periodRange(in: periods) == nil, "reversed range rejected")
        require(course("x", [0], "1", "99").periodRange(in: periods) == nil, "missing period rejected")
        print("PASS: Taipei dates, inclusive expiry, period resolution")

        let merged = base.merging([club], weekContaining: wednesday)
        require(merged.periods[6].course(for: 2)?.name == "社團" && merged.periods[7].course(for: 2)?.customCourseID == club.id, "placed on 星期三 第7–8節")
        require(merged.periods[6].course(for: 2)?.classroom == "社辦", "fields trimmed for display")
        require(merged.ownerSessionID == "session-a" && merged.dayHeaders == base.dayHeaders, "owner and headers kept")
        require(base.periods[6].course(for: 2) == nil, "source schedule unchanged")
        require(base.merging([], weekContaining: wednesday).periods.allSatisfy { $0.courses.values.allSatisfy { $0.customCourseID == nil } }, "no courses is identity")
        let sessions = merged.sessions(on: wednesday)
        require(sessions.map(\.courseName) == ["社團", "社團"] && sessions.mergedConsecutiveCourses().count == 1, "Live Activity sessions merge consecutive custom periods")
        print("PASS: merge into empty slots, display copy only, Live Activity sessions")

        // Expires on Tuesday: shown for Monday/Tuesday of that week, not Wednesday.
        let shortLived = course("補課", [1, 2], "5", "5", until: "2026-10-06")
        let week = base.merging([shortLived], weekContaining: wednesday)
        require(week.periods[4].course(for: 1)?.name == "補課", "Tuesday before expiry kept")
        require(week.periods[4].course(for: 2) == nil, "Wednesday after expiry hidden")
        require(base.merging([shortLived], weekContaining: instant("2026-10-12T02:00:00Z")).periods[4].course(for: 1) == nil, "next week hidden")
        print("PASS: per-day expiry within the displayed week")

        let weekend = base.merging([course("家教", [6], "1", "1"), course("打工", [5], "2", "2")], weekContaining: wednesday)
        require(weekend.dayHeaders == ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"], "missing weekend columns appended in order")
        require(weekend.dayCount == 7 && weekend.periods[0].course(for: 6)?.name == "家教" && weekend.periods[1].course(for: 5)?.name == "打工", "weekend courses placed")
        require(weekend.sessions(on: instant("2026-10-11T00:30:00Z")).first?.courseName == "家教", "Sunday sessions for widget/Live Activity")
        require(base.merging([course("x", [6], "1", "1", until: "2026-10-01")], weekContaining: wednesday).dayHeaders.count == 5, "expired weekend course adds no column")
        print("PASS: weekend columns only when something is shown")

        let clash = course("自習", [0], "3", "4")
        require(base.conflictMessage(for: clash, others: [], today: wednesday) == "星期一第3節已有「微積分」", "school conflict message")
        let clashed = base.merging([clash], weekContaining: wednesday)
        require(clashed.periods[2].course(for: 0)?.name == "微積分", "school course wins")
        require(clashed.periods[3].course(for: 0) == nil, "no partial placement in the free 第4節")
        require(base.conflictMessage(for: course("y", [2], "8", "8"), others: [club], today: wednesday) == "星期三第8節已有自訂課程「社團」", "custom conflict")
        require(base.conflictMessage(for: club, others: [club], today: wednesday) == nil, "editing itself is not a conflict")
        require(base.conflictMessage(for: course("y", [2], "8", "8"), others: [course("old", [2], "8", "8", until: "2026-10-01")], today: wednesday) == nil, "expired courses do not block")
        require(base.conflictMessage(for: course("y", [5], "2", "3"), others: [], today: wednesday) == nil, "weekend without school column is free")
        let overlapping = [course("A", [1], "4", "5"), course("B", [1], "5", "6")]
        let firstWins = base.merging(overlapping, weekContaining: wednesday)
        require(firstWins.periods[4].course(for: 1)?.name == "A" && firstWins.periods[5].course(for: 1) == nil, "overlapping custom courses never mix")
        print("PASS: school/custom conflicts and no partial placement")

        let defaults = UserDefaults(suiteName: "niu-custom-course-check-\(UUID().uuidString)")!
        let data = try! JSONEncoder().encode(CustomCourseSnapshot(ownerSessionID: "session-a", courses: [club]))
        defaults.set(data, forKey: CustomCourseSnapshot.key)
        require(base.withCustomCourses(from: defaults, weekContaining: wednesday).periods[6].course(for: 2)?.name == "社團", "snapshot for this session")
        var other = base; other.ownerSessionID = "session-b"
        require(other.withCustomCourses(from: defaults, weekContaining: wednesday).periods[6].course(for: 2) == nil, "other session ignored")
        var unowned = base; unowned.ownerSessionID = nil
        require(unowned.withCustomCourses(from: defaults, weekContaining: wednesday).periods[6].course(for: 2) == nil, "unowned schedule ignored")
        require(CustomCourseSnapshot.key.hasPrefix("classSchedule."), "mirror cleared with schedule caches on logout")

        let legacy = #"{"name":"舊快取","teacher":null,"classroom":"A1"}"#.data(using: .utf8)!
        require((try? JSONDecoder().decode(CourseInfo.self, from: legacy))?.customCourseID == nil, "existing caches still decode")
        print("PASS: session-scoped App Group snapshot and cache compatibility")

        require(club.scheduleSummary(in: periods) == "每週三・第7–8節 14:10–16:00", "summary label")
        require(CustomCourse.weekdaySummary([4, 0, 0, 9]) == "每週一、五", "weekday summary dedupes and bounds")
        print("PASS: display labels")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-custom-courses-") as folder:
    temp = Path(folder)
    main = temp / "Checks.swift"
    main.write_text(CHECKS)
    binary = temp / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(temp / "module-cache"),
        str(ROOT / "NIU-LiveActivities/ClassScheduleModels.swift"),
        str(ROOT / "NIU-LiveActivities/CustomCourseModels.swift"),
        str(main), "-o", str(binary),
    ], check=True)
    print(subprocess.check_output([str(binary)], text=True), end="")
