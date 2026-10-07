import Foundation

enum GradeQueryMode: String, Codable, CaseIterable, Identifiable {
    case midterm = "期中"
    case final = "期末"
    case history = "歷年"

    var id: String { rawValue }
}

/// 校方未提供 GPA，App 依分數以 4.3 制等第對照自行換算，結果僅供參考。
enum GPAFormula {
    struct Band: Identifiable {
        var id: String { letter }
        let range: String
        let letter: String
        let points: Double
    }

    static let maxGPA = 4.3

    static let bands: [Band] = [
        Band(range: "90–100", letter: "A+", points: 4.3),
        Band(range: "85–89", letter: "A", points: 4.0),
        Band(range: "80–84", letter: "A-", points: 3.7),
        Band(range: "77–79", letter: "B+", points: 3.3),
        Band(range: "73–76", letter: "B", points: 3.0),
        Band(range: "70–72", letter: "B-", points: 2.7),
        Band(range: "67–69", letter: "C+", points: 2.3),
        Band(range: "63–66", letter: "C", points: 2.0),
        Band(range: "60–62", letter: "C-", points: 1.7),
        Band(range: "0–59", letter: "F", points: 0)
    ]

    static func band(for score: Double) -> Band {
        switch score {
        case 90...: return bands[0]
        case 85..<90: return bands[1]
        case 80..<85: return bands[2]
        case 77..<80: return bands[3]
        case 73..<77: return bands[4]
        case 70..<73: return bands[5]
        case 67..<70: return bands[6]
        case 63..<67: return bands[7]
        case 60..<63: return bands[8]
        default: return bands[9]
        }
    }

    static func gpa(from score: Double) -> Double { band(for: score).points }

    /// Σ(績分 × 學分) ÷ Σ學分，只計入有數字成績且學分大於 0 的課程。
    static func weightedGPA(_ courses: [GradeCourse]) -> Double? {
        let graded = courses.filter(\.countsTowardGPA)
        let credits = graded.reduce(0.0) { $0 + $1.credits }
        guard credits > 0 else { return nil }
        return graded.reduce(0.0) { $0 + ($1.gradePoint ?? 0) * $1.credits } / credits
    }

    /// 以學分加權的數字成績平均。
    static func weightedScore(_ courses: [GradeCourse]) -> Double? {
        let graded = courses.filter(\.countsTowardGPA)
        let credits = graded.reduce(0.0) { $0 + $1.credits }
        guard credits > 0 else { return nil }
        return graded.reduce(0.0) { $0 + $1.score * $1.credits } / credits
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
    /// 校方原始成績文字；舊快取沒有此欄位。
    var scoreText: String? = nil

    /// 抵免、通過等非數字成績在解析時記為 0 分並把原文放進備註。
    var hasNumericScore: Bool {
        if let scoreText { return Double(scoreText.trimmingCharacters(in: .whitespaces)) != nil }
        return !(score == 0 && remarks?.isEmpty == false)
    }

    var passed: Bool {
        if hasNumericScore { return score >= 60 }
        let text = scoreText ?? remarks ?? ""
        if text.contains("不通過") || text.contains("不及格") { return false }
        return ["通過", "及格", "抵免", "免修"].contains { text.contains($0) }
    }

    var countsTowardGPA: Bool { credits > 0 && hasNumericScore }
    var gradePoint: Double? { countsTowardGPA ? (gpa ?? GPAFormula.gpa(from: score)) : nil }
    var letterGrade: String? { hasNumericScore ? GPAFormula.band(for: score).letter : nil }
    var displayScore: String {
        if hasNumericScore { return String(format: "%.0f", score) }
        return [scoreText, remarks]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "-"
    }
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
    /// 系排名（名次/人數）；舊快取沒有此欄位。
    var departmentRank: String? = nil
    let courses: [GradeCourse]

    var termTitle: String { "\(year) 學年度\(term == .summer ? "暑期" : "\(term.rawValue)學期")" }
    var shortTitle: String { "\(year)\(term.rawValue)" }
    var earnedCredits: Double { courses.filter(\.passed).reduce(0.0) { $0 + $1.credits } }
    var attemptedCredits: Double { courses.reduce(0.0) { $0 + $1.credits } }
    var failedCount: Int { courses.filter { $0.hasNumericScore && !$0.passed }.count }
    var displayGPA: Double? { gpa ?? GPAFormula.weightedGPA(courses) }
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

    let cumulativeGPA: Double?
    let averageScore: Double?
    let earnedCredits: Double
    let attemptedCredits: Double
    let courseCount: Int
    let trend: [SemesterTrendPoint]

    /// 直接以所有課程加權，避免先算學期 GPA 再以含抵免／通過的學分二次加權。
    static func from(semesters: [SemesterGrade]) -> GradeHistorySummary {
        let ordered = semesters.sorted { lhs, rhs in
            if lhs.year == rhs.year { return lhs.term.order < rhs.term.order }
            return lhs.year < rhs.year
        }
        let courses = ordered.flatMap(\.courses)
        return GradeHistorySummary(
            cumulativeGPA: GPAFormula.weightedGPA(courses),
            averageScore: GPAFormula.weightedScore(courses),
            earnedCredits: ordered.reduce(0.0) { $0 + $1.earnedCredits },
            attemptedCredits: ordered.reduce(0.0) { $0 + $1.attemptedCredits },
            courseCount: courses.count,
            trend: ordered.compactMap { sem in
                sem.displayGPA.map { SemesterTrendPoint(label: sem.shortTitle, gpa: $0) }
            }
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
