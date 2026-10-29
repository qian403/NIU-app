#!/usr/bin/env python3
"""Compile the real friend status and common free-window logic and check it with synthetic tables."""
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
// Taipei = UTC+8. 2026-10-05 is a Monday in semester 115-1.
func taipei(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
    instant(String(format: "2026-10-%02dT%02d:%02d:00Z", 5 + day, hour, minute)).addingTimeInterval(-8 * 3600)
}
let term = ScheduleShareTerm(academicYear: 115, semester: 1)
let periods = (1...8).map { ScheduleSharePayload.Period(id: "\($0)", start: ($0 + 7) * 60 + 10, end: ($0 + 8) * 60) }
func payload(_ classes: [(day: Int, row: Int, name: Int, room: Int?)], days: [Int] = [0, 1, 2, 3, 4],
             term: ScheduleShareTerm = term, nickname: String = "甲", custom: [ScheduleSharePayload.Period]? = nil) -> ScheduleSharePayload {
    ScheduleSharePayload(shareID: UUID(), term: term, createdAt: taipei(0, 8, 0), nickname: nickname, days: days,
                         periods: custom ?? periods, names: ["微積分", "物理", "英文"], rooms: ["E201"], teachers: [],
                         slots: classes.map { .init(day: $0.day, period: $0.row, name: $0.name, room: $0.room, teacher: nil) })
}

@main struct Checks {
    static func main() {
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        // Monday: 微積分 rows 1–2 (09:10–11:00) in E201, 物理 row 5 (13:10–14:00), no room shared.
        let friend = payload([(0, 1, 0, 0), (0, 2, 0, 0), (0, 5, 1, nil)])

        require(friend.status(at: taipei(0, 8, 30)) == .free(until: 550), "before first class: free until 09:10")
        require(friend.status(at: taipei(0, 9, 30)) == .inClass(course: "微積分", room: "E201", until: 660),
                "double period is one class until 11:00 with the shared room")
        require(friend.status(at: taipei(0, 10, 5)) == .inClass(course: "微積分", room: "E201", until: 660),
                "the break inside a double period still counts as class")
        require(friend.status(at: taipei(0, 11, 30)) == .free(until: 790), "lunch: free until 13:10")
        require(friend.status(at: taipei(0, 13, 30)) == .inClass(course: "物理", room: nil, until: 840),
                "no room when the friend did not share rooms")
        require(friend.status(at: taipei(0, 14, 0)) == .doneForToday, "end is exclusive")
        require(friend.status(at: taipei(1, 10, 0)) == .noClassToday, "covered day without classes")
        require(friend.status(at: taipei(5, 10, 0)) == .notCovered, "Saturday outside the shared table is unknown")
        print("PASS: free, in class across a double period, lunch, end boundary, no class, uncovered day")

        // Taipei civil time on a foreign device: 2026-10-05 01:30 UTC is 09:30 Monday in Taipei.
        require(friend.status(at: instant("2026-10-05T01:30:00Z")).sortRank == 3, "Taipei clock, not device clock")
        let ended = payload([(0, 1, 0, nil)], term: ScheduleShareTerm(academicYear: 114, semester: 2))
        let next = payload([(0, 1, 0, nil)], term: ScheduleShareTerm(academicYear: 115, semester: 2))
        require(ended.status(at: taipei(0, 9, 30)) == .expired, "previous term")
        require(next.status(at: taipei(0, 9, 30)) == .upcomingTerm, "next term is not shown as current")
        require(!ScheduleFriendStatus.expired.isCurrentTerm && ScheduleFriendStatus.noClassToday.isAvailable, "flags")
        let ranks = [ScheduleFriendStatus.inClass(course: "", room: nil, until: 0), .free(until: 0), .expired, .doneForToday]
            .sorted { $0.sortRank < $1.sortRank }
        require(ranks == [.free(until: 0), .doneForToday, .inClass(course: "", room: nil, until: 0), .expired], "available first")
        print("PASS: Taipei time zone, expired and upcoming terms, availability ordering")

        // Common free windows between me and the friend on Monday.
        let me = payload([(0, 0, 2, nil), (0, 6, 2, nil)], nickname: "我")
        let monday = ScheduleFreeTime.windows(base: me, others: [friend]).filter { $0.day == 0 }
        require(monday == [ScheduleFreeWindow(day: 0, start: 670, end: 780), ScheduleFreeWindow(day: 0, start: 910, end: 960)],
                "merge 11:10–13:00 across the break; 14:10 is my class, 15:10–16:00 last free row")
        require(monday[0].durationText == "1 小時 50 分" && ScheduleFreeWindow(day: 0, start: 600, end: 720).durationText == "2 小時" && ScheduleFreeWindow(day: 0, start: 600, end: 650).durationText == "50 分鐘"
                && ScheduleFreeWindow(day: 0, start: 600, end: 690).durationText == "1 小時 30 分", "durations")
        let tuesday = ScheduleFreeTime.windows(base: me, others: [friend]).filter { $0.day == 1 }
        require(tuesday == [ScheduleFreeWindow(day: 1, start: 490, end: 960)], "a whole free day is one window")
        let saturday = payload([], days: [0, 1, 2, 3, 4, 5])
        require(ScheduleFreeTime.windows(base: saturday, others: [friend]).allSatisfy { $0.day != 5 },
                "a day the friend's table does not cover is never free")
        let gap = [ScheduleSharePayload.Period(id: "1", start: 490, end: 540), .init(id: "2", start: 600, end: 650)]
        require(ScheduleFreeTime.windows(base: payload([], custom: gap), others: []).filter { $0.day == 0 }.count == 2,
                "a break longer than 20 minutes splits windows")
        print("PASS: common free windows merge short breaks, respect classes, coverage and long gaps")

        let all = ScheduleFreeTime.windows(base: me, others: [friend])
        let upcoming = ScheduleFreeTime.upcoming(all, at: taipei(0, 14, 30))
        require(upcoming.first == ScheduleFreeWindow(day: 0, start: 910, end: 960), "today's remaining window first")
        require(!upcoming.contains(ScheduleFreeWindow(day: 0, start: 670, end: 780)), "today's past window dropped")
        require(upcoming.last?.day == 4, "then Tuesday through Friday")
        let fromFriday = ScheduleFreeTime.upcoming(all, at: taipei(4, 20, 0))
        require(fromFriday.first?.day == 0, "after Friday's last window the list wraps to next Monday")
        print("PASS: upcoming order from today, past windows dropped, wraps to next week")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-schedule-friends-") as folder:
    temp = Path(folder)
    main = temp / "Checks.swift"
    main.write_text(CHECKS)
    binary = temp / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(temp / "module-cache"),
        str(ROOT / "NIU-LiveActivities/ClassScheduleModels.swift"),
        str(ROOT / "Features/ClassSchedule/Models/ScheduleShareModels.swift"),
        str(ROOT / "Features/ClassSchedule/Models/ScheduleFriendModels.swift"),
        str(main), "-o", str(binary),
    ], check=True)
    print(subprocess.check_output([str(binary)], text=True), end="")
