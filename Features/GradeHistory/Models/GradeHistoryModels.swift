import Foundation

enum GradeQueryMode: String, Codable, CaseIterable, Identifiable {
    case midterm = "期中"
    case final = "期末"
    case history = "歷年"

    var id: String { rawValue }
}

enum GPAFormula {
    /// NIU commonly uses a 4.3 scale converted from numeric score.
    static func gpa(from score: Double) -> Double {
        switch score {
        case 90...100: return 4.3
        case 85..<90: return 4.0
        case 80..<85: return 3.7
        case 77..<80: return 3.3
        case 73..<77: return 3.0
        case 70..<73: return 2.7
        case 67..<70: return 2.3
        case 63..<67: return 2.0
        case 60..<63: return 1.7
        default: return 0.0
        }
    }
}

enum CourseCategory: String, Codable, CaseIterable, Identifiable {
    case all = "全部"
    case required = "必修"
    case elective = "選修"
    case general = "通識"
    case physical = "體育"
    case other = "其他"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .all: return "全部"
        case .required: return "必修"
        case .elective: return "選修"
        case .general: return "通識"
        case .physical: return "體育"
        case .other: return "其他"
        }
    }
}

struct GradeCourse: Identifiable, Codable {
    var id: String { code + name }
    let code: String
    let name: String
    let category: CourseCategory
    let credits: Double
    let score: Double
    let gpa: Double?
    let remarks: String?

    var passed: Bool { score >= 60 }
    var computedGPA: Double { gpa ?? GPAFormula.gpa(from: score) }
}

enum SemesterTerm: String, Codable, CaseIterable, Identifiable {
    case fall = "上"
    case spring = "下"
    case summer = "暑"

    var id: String { rawValue }
    var order: Int {
        switch self {
        case .fall: return 0
        case .spring: return 1
        case .summer: return 2
        }
    }
    var label: String { rawValue }
}

struct SemesterGrade: Identifiable, Codable {
    var id: String { "\(year)-\(term.rawValue)" }
    let year: Int        // e.g. 112
    let term: SemesterTerm
    let averageScore: Double
    let gpa: Double?
    let creditsTaken: Double
    let creditsPassed: Double
    let classRank: String?
    let courses: [GradeCourse]

    var termTitle: String { "\(year) 學年度第 \(term.rawValue) 學期" }
    var passRate: Double { creditsTaken == 0 ? 0 : creditsPassed / creditsTaken }
    var displayGPA: Double { gpa ?? computedGPA }

    /// Computed from score + credits when source GPA is unavailable.
    var computedGPA: Double {
        let graded = courses.filter { $0.credits > 0 }
        let totalCredits = graded.reduce(0.0) { $0 + $1.credits }
        let weighted = graded.reduce(0.0) { $0 + ($1.computedGPA * $1.credits) }
        return totalCredits == 0 ? 0 : weighted / totalCredits
    }

    /// Returns a copy with courses filtered by category and stats recalculated from the filtered list.
    func filtered(by category: CourseCategory) -> SemesterGrade {
        guard category != .all else { return self }
        let filteredCourses = courses.filter { $0.category == category }
        let credits = filteredCourses.reduce(0.0) { $0 + $1.credits }
        let passedCredits = filteredCourses.filter { $0.passed }.reduce(0.0) { $0 + $1.credits }
        let weightedTotal = filteredCourses.reduce(0.0) { $0 + ($1.score * $1.credits) }
        let average = credits == 0 ? 0 : (weightedTotal / credits)
        let weightedGPA = filteredCourses.reduce(0.0) { $0 + ($1.computedGPA * $1.credits) }
        let gpa = credits == 0 ? 0 : weightedGPA / credits
        return SemesterGrade(
            year: year,
            term: term,
            averageScore: average,
            gpa: gpa,
            creditsTaken: credits,
            creditsPassed: passedCredits,
            classRank: classRank,
            courses: filteredCourses
        )
    }
}

struct TermScoreCourse: Identifiable, Codable {
    var id: String { name + type + scoreText }
    let type: String
    let name: String
    let scoreText: String
}

struct TermScoreSnapshot: Codable {
    let mode: GradeQueryMode
    let semesterTitle: String?
    let averageText: String?
    let rankText: String?
    let courses: [TermScoreCourse]
}

struct GradeHistorySummary {
    struct SemesterTrendPoint: Identifiable {
        var id: String { label }
        let label: String
        let gpa: Double
    }

    let cumulativeGPA: Double
    let averageScore: Double
    let totalCredits: Double
    let passedCredits: Double
    let passRate: Double
    let trend: [SemesterTrendPoint]

    static func from(semesters: [SemesterGrade]) -> GradeHistorySummary {
        guard !semesters.isEmpty else {
            return GradeHistorySummary(
                cumulativeGPA: 0,
                averageScore: 0,
                totalCredits: 0,
                passedCredits: 0,
                passRate: 0,
                trend: []
            )
        }

        let ordered = semesters.sorted { lhs, rhs in
            if lhs.year == rhs.year { return lhs.term.order < rhs.term.order }
            return lhs.year < rhs.year
        }

        let totalCredits = semesters.reduce(0.0) { $0 + $1.creditsTaken }
        let passedCredits = semesters.reduce(0.0) { $0 + $1.creditsPassed }

        // Weighted average by credits
        let weightedScoreSum = semesters.reduce(0.0) { partial, sem in
            partial + (sem.averageScore * sem.creditsTaken)
        }
        let averageScore = totalCredits == 0 ? 0 : weightedScoreSum / totalCredits

        // GPA average weighted by credits
        let weightedGPASum = semesters.reduce(0.0) { partial, sem in
            partial + (sem.displayGPA * sem.creditsTaken)
        }
        let cumulativeGPA = totalCredits == 0 ? 0 : weightedGPASum / totalCredits

        let trend = ordered.map { sem in
            SemesterTrendPoint(label: "\(sem.year % 100)-\(sem.term.label)", gpa: sem.displayGPA)
        }

        return GradeHistorySummary(
            cumulativeGPA: cumulativeGPA,
            averageScore: averageScore,
            totalCredits: totalCredits,
            passedCredits: passedCredits,
            passRate: totalCredits == 0 ? 0 : passedCredits / totalCredits,
            trend: trend
        )
    }
}

extension Array where Element == SemesterGrade {
    func groupedByYearDescending() -> [(year: Int, semesters: [SemesterGrade])] {
        let grouped = Dictionary(grouping: self) { $0.year }
        return grouped.keys.sorted(by: >).map { year in
            let list = grouped[year]?.sorted { lhs, rhs in
                if lhs.year == rhs.year { return lhs.term.order < rhs.term.order }
                return lhs.year < rhs.year
            } ?? []
            return (year, list)
        }
    }
}
