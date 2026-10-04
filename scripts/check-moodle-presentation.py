#!/usr/bin/env python3
"""Exercise production Chinese date/grade presentation with an English process locale."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "Features/Moodle"
CHECKS = r'''
import Foundation
@main struct Checks {
    @MainActor static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 14, minute: 50))!
        precondition(MoodlePresentation.dateTime(date) == "2026年10月5日 下午2:50")
        precondition(MoodlePresentation.time(date) == "下午2:50")
        precondition(MoodlePresentation.month(date) == "2026年10月")
        precondition(MoodlePresentation.weekday(date).contains("一"))
        precondition(MoodlePresentation.fullDate(date).contains("2026年10月5日"))
        precondition(MoodlePresentation.numericDate(date) == "2026/10/05")
        precondition(MoodlePresentation.isoDate(date) == "2026-10-05")
        for context in [MoodlePresentation.RelativeTimeContext.publication, .deadline] {
            for seconds: Double in [-60, -59.9, -15, -0.1, 0, 0.1, 15, 59.9, 60] {
                precondition(MoodlePresentation.relativeTime(date.addingTimeInterval(seconds), now: date, context: context) == "剛剛")
            }
            for (seconds, expected): (Double, String) in [(-61, "1分鐘前"), (-172800, "2天前")] {
                precondition(MoodlePresentation.relativeTime(date.addingTimeInterval(seconds), now: date, context: context).filter { !$0.isWhitespace } == expected)
            }
        }
        for (seconds, expected): (Double, String) in [(61, "1分鐘後"), (172800, "2天後")] {
            let future = date.addingTimeInterval(seconds)
            precondition(MoodlePresentation.relativeTime(future, now: date) == "剛剛")
            precondition(MoodlePresentation.relativeTime(future, now: date, context: .publication) == "剛剛")
            precondition(MoodlePresentation.relativeTime(future, now: date, context: .deadline).filter { !$0.isWhitespace } == expected)
        }
        let notification = MoodlePopupNotification(id: 1, subject: "", message: "",
            timeCreated: Date().addingTimeInterval(-172800), timeCreatedPretty: "2 days",
            contextURL: nil, component: nil, isRead: false)
        precondition(notification.timeText.filter { !$0.isWhitespace } == "2天前")
        for seconds: Double in [15, 172800] {
            let futureNotification = MoodlePopupNotification(id: 2, subject: "", message: "",
                timeCreated: Date().addingTimeInterval(seconds), timeCreatedPretty: "in 2 days",
                contextURL: nil, component: nil, isRead: false)
            precondition(futureNotification.timeText == "剛剛")
        }
        print("PASS: zh_TW dates, ±60-second boundary, publication/deadline relative times and notifications")

        func item(_ formatted: String?, raw: Double? = nil) throws -> MoodleGradeItem {
            var object: [String: Any] = ["id": 1, "itemtype": "mod", "grademax": 100]
            object["gradeformatted"] = formatted
            object["graderaw"] = raw
            return try JSONDecoder().decode(MoodleGradeItem.self, from: JSONSerialization.data(withJSONObject: object))
        }
        func checkGrade(_ formatted: String?, raw: Double? = nil, expected: String?) throws {
            let actual = MoodlePresentation.assignmentGrade(try item(formatted, raw: raw))
            precondition(actual == expected, "Unexpected grade: \(String(describing: actual))")
        }
        try checkGrade("92.00", expected: "92")
        try checkGrade("92.123400", expected: "92.1234")
        try checkGrade("0.00", expected: "0")
        try checkGrade("100.00", expected: "100")
        try checkGrade("<b>A+</b>", expected: "A+")
        try checkGrade("-", expected: nil)
        try checkGrade(nil, raw: 92, expected: "92 / 100")
        try checkGrade(nil, raw: 92.125, expected: "92.125 / 100")
        precondition(MoodlePresentation.assignmentGrade(nil) == nil)
        precondition(MoodlePresentation.gradingStatus(graded: true, grade: "92") == nil)
        precondition(MoodlePresentation.gradingStatus(graded: false, grade: "0") == nil)
        precondition(MoodlePresentation.gradingStatus(graded: false, grade: nil) == "尚未評分")
        precondition(MoodlePresentation.gradingStatus(graded: true, grade: nil) == "已評分")
        precondition(MoodlePresentation.gradingStatus(graded: nil, grade: nil) == nil)
        print("PASS: score precedence, pending/unknown status, integer grades and preserved decimal/scale precision")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-moodle-presentation-") as directory:
    folder = Path(directory)
    source = folder / "Checks.swift"
    source.write_text(CHECKS)
    binary = folder / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-module-cache-path", str(folder / "ModuleCache"),
                    str(BASE / "Models/MoodleModels.swift"), str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary), "-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
                   env={**os.environ, "TZ": "Asia/Taipei", "LANG": "en_US.UTF-8"}, check=True, timeout=30)

for file in BASE.rglob("*.swift"):
    text = file.read_text()
    assert not re.search(r'\.formatted\(\s*(?:date:|\.dateTime|Date\.ISO8601)', text), file
    assert not re.search(r'Text\([^\n]*,\s*(?:style:\s*\.(?:relative|date|time)|format:\s*\.dateTime)', text), file
assignment = (BASE / "Views/MoodleAssignmentView.swift").read_text()
assert 'title: "已評分"' not in assignment and 'graded ? "是" : "否"' not in assignment
assert 'MoodlePresentation.assignmentGrade(gradeItem)' in assignment
assert '} else if let status = MoodlePresentation.gradingStatus(' in assignment
fixture = (BASE / "Fixtures/MoodleUIFixture.swift").read_text()
assert '.navigationDestination(isPresented:' not in fixture and 'opensDetail' not in fixture
assert 'screen.hasPrefix("course")' in fixture
course = (BASE / "Views/MoodleCourseDetailView.swift").read_text()
assert '.listStyle(.insetGrouped)' in course
assert 'MoodleCoursePage(model:' in course
assert 'TabView(selection:' not in course
assert 'tabSwipeGesture' not in course and 'selectedTab' not in course
print("PASS: all Moodle dates use shared presentation; grade rows and immediate fixture/lazy page wiring")
