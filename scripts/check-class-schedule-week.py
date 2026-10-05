#!/usr/bin/env python3
"""Compile the real UI-free weekly layout and exercise it with synthetic data only."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHECKS = r'''
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
func day(_ date: Date) -> String {
    let f = DateFormatter()
    f.calendar = ScheduleClock.calendar
    f.timeZone = ScheduleClock.calendar.timeZone
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}
let headers = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
let monday = instant("2026-10-05T00:35:00Z") // Taipei 08:35
func schedule(_ periods: [ClassPeriod], _ days: [String] = Array(headers.prefix(5))) -> ClassSchedule {
    ClassSchedule(periods: periods, dayCount: days.count, dayHeaders: days, fetchedAt: monday)
}
func layout(_ value: ClassSchedule, _ display: [String] = Array(headers.prefix(5)), _ now: Date = monday) -> ClassScheduleWeekLayout {
    ClassScheduleWeekLayout(schedule: value, displayDayHeaders: display, now: now)
}
func period(_ id: String, _ time: String, _ courses: [Int: CourseInfo] = [:]) -> ClassPeriod {
    ClassPeriod(id: id, timeRange: time, courses: courses)
}

@main struct Checks {
    static func main() {
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        let mondayWeek = ClassScheduleWeekLayout.weekDates(containing: monday).map(day)
        require(mondayWeek == ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11"], "Monday based dates")
        require(ClassScheduleWeekLayout.weekDates(containing: instant("2026-10-11T15:59:59Z")).map(day) == mondayWeek, "Sunday stays in preceding Monday week")
        require(day(ClassScheduleWeekLayout.weekDates(containing: instant("2026-10-11T16:00:00Z"))[0]) == "2026-10-12", "Taipei Monday midnight")
        require(ClassScheduleWeekLayout.weekDates(containing: instant("2027-01-01T04:00:00Z")).map(day) == ["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02", "2027-01-03"], "year rollover")
        require(day(ClassScheduleWeekLayout.weekDates(containing: instant("2026-11-01T04:00:00Z"))[0]) == "2026-10-26", "month rollover on Sunday")
        print("PASS: Taipei Monday/Sunday, month/year rollover and foreign device timezone")

        let a = CourseInfo(name: " 資料結構 \n", teacher: "教師甲", classroom: "101")
        let a2 = CourseInfo(name: "資料結構", teacher: "教師乙", classroom: "102")
        let b = CourseInfo(name: "程式設計")
        let periods = [period("0", "07:10~08:00"),
                       period("1", "08:10~09:00", [0:a, 1:a]),
                       period("第二節", "09:10~10:00", [0:a2, 1:b]),
                       period("3", "10:10~11:00"),
                       period("4", "11:10~12:00", [0:a]),
                       period("5", "時間待定", [2:b]),
                       period("6", "14:10~15:00")]
        let value = layout(schedule(periods))
        require(value.visibleRows == 0..<7, "preserve every period, including empty first/last rows and unknown times")
        require(value.blocks.count == 5, "same name adjacent merges, different/gap/column stays separate")
        let merged = value.blocks.first!
        require(merged.rows == 1..<3 && merged.course.name == "資料結構", "trim name before merge")
        require(merged.classrooms == ["101", "102"] && merged.teachers == ["教師甲", "教師乙"], "retain distinct merged details")
        require(value.accessibilityLabel(for: merged, periods: periods) == "星期一，第1–二節，08:10到10:00，資料結構，101、102，教師甲、教師乙", "accessible range with normalized portal IDs")
        require(value.blocks.contains { $0.column == 0 && $0.rows == 4..<5 }, "gap breaks merge")
        require(value.blocks.contains { $0.column == 2 && $0.rows == 5..<6 }, "unknown times retain row")
        let empty = layout(schedule([period("1", ""), period("2", "")]))
        require(empty.visibleRows == 0..<2 && empty.blocks.isEmpty, "empty week retains all rows")
        require(layout(schedule([])).visibleRows.isEmpty, "zero periods safe")
        print("PASS: adjacent merge, column isolation, gaps, unknown times, complete/empty rows, accessibility")

        let separated = layout(schedule([
            period("1", "11:10~12:00", [0:a]), period("2", "13:10~14:00", [0:a]),
            period("3", "時間待定", [0:a]), period("4", "15:10~16:00", [0:a]),
        ]))
        require(separated.blocks.count == 4, "lunch breaks and unknown times must not become one continuous course")
        print("PASS: long breaks and unknown times split course blocks")

        for width in [320.0, 375.0, 393.0, 430.0, 768.0] {
            for height in [320.0, 480.0, 640.0, 900.0] {
                for columns in [5, 6, 7] {
                    for rows in [1, 8, 12, 16] {
                        let metrics = ClassScheduleWeekLayout.GridMetrics(
                            availableSize: CGSize(width: width, height: height), columns: columns,
                            rows: rows, expanded: false)
                        require(abs(metrics.gridHeight + 16 + 28 + 8 - height) < 0.001,
                                "the entire grid and footer fit vertically, including a dense schedule")
                        require(abs(metrics.gutterWidth + Double(columns) * metrics.columnWidth + 16 - width) < 0.001,
                                "five through seven days fit without horizontal scrolling")
                    }
                }
            }
        }
        let accessible = ClassScheduleWeekLayout.GridMetrics(
            availableSize: CGSize(width: 320, height: 480), columns: 7, rows: 16,
            expanded: true, preferredRowHeight: 132, minimumColumnWidth: 150)
        require(accessible.rowHeight == 132 && accessible.columnWidth == 150,
                "accessibility text preserves spacious cells instead of shrinking to the viewport")
        let zero = ClassScheduleWeekLayout.GridMetrics(
            availableSize: CGSize(width: 0, height: 0), columns: 0, rows: 0, expanded: false)
        require(zero.gridHeight.isFinite && zero.columnWidth.isFinite, "empty/transient size safe")
        print("PASS: viewport fitting on narrow/tall/tablet screens, five/seven days, 16 periods and accessible scrolling")

        // Display columns follow the VM, even if portal columns have a different order.
        let weekendSchedule = schedule([period("1", "08:10~09:00", [0:b, 1:a])], ["星期日", "星期六"])
        let all = layout(weekendSchedule, headers, instant("2026-10-11T00:35:00Z"))
        require(all.columns.count == 7 && all.columns[0].scheduleIndex == nil, "weekday placeholders")
        require(all.columns[5].scheduleIndex == 1 && all.columns[6].scheduleIndex == 0, "weekend column mapping")
        require(all.todayColumn(at: instant("2026-10-11T00:35:00Z"))?.id == 6, "Sunday today column")
        let saturday = layout(schedule([], Array(headers.prefix(6))), Array(headers.prefix(6)))
        require(saturday.columns.count == 6 && saturday.columns.last?.dateLabel == "10/10", "Saturday only")
        let sundayOnly = layout(weekendSchedule, Array(headers.prefix(5)) + ["星期日"])
        require(sundayOnly.columns.last?.dateLabel == "10/11", "Sunday without Saturday uses correct offset")
        print("PASS: five/six/seven columns, reordered school columns, missing weekdays and Sunday-only offset")

        require(value.nowLinePosition(periods: periods, at: monday) == 1.5, "interpolation after the empty first row")
        require(value.nowLinePosition(periods: periods, at: instant("2026-10-05T01:05:00Z")) == 2, "break at row boundary")
        require(value.nowLinePosition(periods: periods, at: instant("2026-10-05T01:10:00Z")) == 2, "next period start")
        require(value.nowLinePosition(periods: periods, at: instant("2026-10-04T23:09:59Z")) == nil, "before visible range")
        require(value.nowLinePosition(periods: periods, at: instant("2026-10-05T04:00:01Z")) == nil, "unknown next time cannot extend line")
        require(value.nowLinePosition(periods: periods, at: instant("2026-10-05T08:00:00Z")) == nil, "after visible range")
        require(value.nowLinePosition(periods: periods, at: instant("2026-10-11T00:35:00Z")) == nil, "today absent")
        require(all.nowLinePosition(periods: weekendSchedule.periods, at: instant("2026-10-11T00:35:00Z")) == 0.5, "Sunday interpolation")
        require(empty.nowLinePosition(periods: [period("1", ""), period("2", "")], at: monday) == nil, "unparseable periods")
        print("PASS: now-line in period/break/boundary/outside, hidden today, unknown times")

        let names = ["資料結構", "程式設計", "跨領域人工智慧專題", "A", "", "👩🏽‍💻"]
        let colours = names.map { ClassScheduleWeekLayout.stableColourIndex(for: $0, paletteCount: 7) }
        require(colours == [6, 5, 2, 3, 2, 4], "fixed FNV-1a UTF-8 vectors")
        require(colours.allSatisfy { (0..<7).contains($0) }, "palette bounds")
        require(ClassScheduleWeekLayout.stableColourIndex(for: a.name, paletteCount: 7) == colours[0], "trimmed name colour")
        require(ClassScheduleWeekLayout.stableColourIndex(for: "A", paletteCount: 0) == 0, "empty palette guard")
        print("COLOURS: \(colours)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-schedule-week-") as folder:
    temp = Path(folder)
    main = temp / "Checks.swift"
    main.write_text(CHECKS)
    binary = temp / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(temp / "module-cache"),
        str(ROOT / "NIU-LiveActivities/ClassScheduleModels.swift"),
        str(ROOT / "Features/ClassSchedule/Models/ClassScheduleWeekLayout.swift"),
        str(main), "-o", str(binary),
    ], check=True)
    outputs = [subprocess.check_output([str(binary)], text=True,
               env={**os.environ, "SWIFT_DETERMINISTIC_HASHING": seed}) for seed in ["0", "1", "0"]]
    assert len(set(outputs)) == 1, "Colour hash must match across independent processes"
    print(outputs[0], end="")
    print("PASS: stable colour indices across three separate launches")
