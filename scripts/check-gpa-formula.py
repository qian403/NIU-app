#!/usr/bin/env python3
"""Check the app's estimated GPA with synthetic courses; no account or network."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
fixture = r'''
@main struct Checks {
    static func course(_ name: String, _ credits: Double, _ score: Double,
                       text: String? = nil, remarks: String? = nil) -> GradeCourse {
        GradeCourse(code: name, name: name, category: .required, credits: credits, score: score,
                    gpa: nil, remarks: remarks, scoreText: text ?? String(format: "%.0f", score))
    }
    static func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.0001 } ?? false }

    static func main() {
        precondition(GPAFormula.gpa(from: 100) == 4.3 && GPAFormula.gpa(from: 90) == 4.3)
        precondition(GPAFormula.gpa(from: 89) == 4.0 && GPAFormula.gpa(from: 60) == 1.7)
        precondition(GPAFormula.gpa(from: 59) == 0 && GPAFormula.gpa(from: 101) == 4.3)

        // Example shown in the info sheet: (4.0×3 + 2.7×2) ÷ 5 = 3.48
        let fall = SemesterGrade(year: 113, term: .fall, averageScore: 79.8, gpa: nil,
            creditsTaken: 10, creditsPassed: 5, classRank: nil, courses: [
                course("A", 3, 85), course("B", 2, 72),
                course("Credited", 3, 0, text: "抵免", remarks: "抵免"),
                course("Pass", 2, 0, text: "通過", remarks: "通過"),
                course("Zero credit", 0, 40)
            ])
        precondition(near(fall.displayGPA, 3.48), "非數字成績與 0 學分課程不得計入 GPA")
        precondition(fall.earnedCredits == 10 && fall.attemptedCredits == 10, "抵免／通過應算實得學分")
        precondition(fall.failedCount == 1)

        // Legacy caches have no scoreText; non-numeric results were stored as 0 + remark.
        let legacy = GradeCourse(code: "L", name: "L", category: .other, credits: 2, score: 0,
                                 gpa: nil, remarks: "抵免")
        precondition(!legacy.hasNumericScore && legacy.passed && legacy.gradePoint == nil)

        let spring = SemesterGrade(year: 113, term: .spring, averageScore: 50, gpa: nil,
            creditsTaken: 1, creditsPassed: 0, classRank: nil, courses: [course("F", 1, 50)])
        precondition(near(spring.displayGPA, 0), "不及格以 0 績分計入")
        let summary = GradeHistorySummary.from(semesters: [spring, fall])
        precondition(near(summary.cumulativeGPA, 17.4 / 6), "累計 GPA 應以所有課程直接加權")
        precondition(summary.trend.map(\.label) == ["113上", "113下"])

        let empty = SemesterGrade(year: 112, term: .summer, averageScore: 0, gpa: nil, creditsTaken: 2,
            creditsPassed: 2, classRank: nil, courses: [course("P", 2, 0, text: "通過", remarks: "通過")])
        precondition(empty.displayGPA == nil && GradeHistorySummary.from(semesters: [empty]).trend.isEmpty)
        print("PASS: 4.3 scale bands, credit-weighted GPA, non-numeric/zero-credit exclusion, failing grades, legacy cache, cumulative GPA")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-gpa-") as directory:
    folder = Path(directory)
    (folder / "Checks.swift").write_text(fixture)
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(folder / "ModuleCache"),
        "-parse-as-library", str(root / "Features/GradeHistory/Models/GradeHistoryModels.swift"),
        str(folder / "Checks.swift"), "-o", str(folder / "checks"),
    ], check=True)
    subprocess.run([str(folder / "checks")], check=True, timeout=15)
