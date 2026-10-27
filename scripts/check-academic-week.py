#!/usr/bin/env python3
"""Compile the real AcademicWeekResolver and exercise it against the published 115 calendar."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CALENDAR = ROOT / "calendar-data/years/115.json"
CHECKS = r'''
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func taipeiDay(_ text: String) -> Date { CampusCalendarDate.parse(text)! }
func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@main struct Checks {
    static func main() {
        // A foreign device time zone must not shift which Taipei day/week we land on.
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        let path = ProcessInfo.processInfo.environment["NIU_CAL"]!
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        let doc = try! JSONDecoder().decode(CampusCalendarDocument.self, from: data)
        require(doc.academicYear == 115, "fixture is the 115 academic year")

        // Teaching week → 第 N 週, carrying the resolved year/semester.
        let w8 = AcademicWeekResolver.week(for: taipeiDay("2026-10-27"), in: doc)!
        require(w8.kind == "teaching" && w8.number == 8 && w8.semester == 1, "teaching week 8 in semester 1")
        require(w8.academicYear == 115 && w8.weekText == "第 8 週", "teaching weekText")

        // Taipei civil-day boundary, evaluated on an America/Los_Angeles device.
        require(AcademicWeekResolver.week(for: instant("2026-10-24T16:30:00Z"), in: doc)!.number == 8,
                "00:30 Taipei belongs to week 8 even while UTC is the previous day")
        require(AcademicWeekResolver.week(for: instant("2026-10-24T15:30:00Z"), in: doc)!.number == 7,
                "23:30 Taipei the night before is still week 7")

        // Summer/winter weeks keep the school's label instead of a misleading 第 N 週.
        let summer = AcademicWeekResolver.week(for: taipeiDay("2026-08-01"), in: doc)!
        require(summer.kind == "summer" && summer.number == 5 && summer.weekText == "暑五", "summer uses its label")
        let winter = AcademicWeekResolver.week(for: taipeiDay("2027-01-10"), in: doc)!
        require(winter.kind == "winter" && winter.weekText == "寒一", "winter uses its label")

        // Preparation week has no number and must not render 第 nil 週.
        let prep = AcademicWeekResolver.week(for: taipeiDay("2026-08-30"), in: doc)!
        require(prep.kind == "preparation" && prep.number == nil && prep.weekText == "預備週", "preparation stays blank-numbered")

        // Second semester restarts the teaching count at 第 1 週.
        let sem2 = AcademicWeekResolver.week(for: taipeiDay("2027-02-21"), in: doc)!
        require(sem2.semester == 2 && sem2.number == 1 && sem2.weekText == "第 1 週", "semester 2 week 1")

        // Missing data and out-of-range dates leave the week blank (nil), never fabricated.
        require(AcademicWeekResolver.week(for: taipeiDay("2026-10-27"), in: nil) == nil, "nil document → nil")
        require(AcademicWeekResolver.week(for: taipeiDay("2027-09-01"), in: doc) == nil, "next year is outside this document")
        require(AcademicWeekResolver.week(for: taipeiDay("2026-08-01"), in: doc) != nil, "first covered day resolves")
        require(AcademicWeekResolver.week(for: taipeiDay("2027-07-31"), in: doc) != nil, "last covered day resolves")

        print("PASS: teaching/summer/winter/preparation labels, Taipei boundary, semester reset, nil & out-of-range")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-academic-week-") as folder:
    temp = Path(folder)
    main = temp / "Checks.swift"
    main.write_text(CHECKS)
    binary = temp / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(temp / "module-cache"),
        str(ROOT / "NIU-LiveActivities/AcademicCalendarStore.swift"),
        str(ROOT / "NIU-LiveActivities/AcademicWeekResolver.swift"),
        str(main), "-o", str(binary),
    ], check=True)
    print(subprocess.check_output([str(binary)], text=True,
          env={**os.environ, "NIU_CAL": str(CALENDAR)}), end="")
