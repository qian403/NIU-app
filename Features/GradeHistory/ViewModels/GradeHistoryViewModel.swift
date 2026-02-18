import SwiftUI
import Combine

@MainActor
final class GradeHistoryViewModel: ObservableObject {
    private struct CachedTermEntry: Codable {
        let fetchedAt: Date
        let snapshot: TermScoreSnapshot
    }
    private struct CachedHistoryEntry: Codable {
        let fetchedAt: Date
        let semesters: [SemesterGrade]
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Published var loadState: LoadState = .idle
    @Published var selectedMode: GradeQueryMode = .history
    @Published var semesters: [SemesterGrade] = []
    @Published var termSnapshot: TermScoreSnapshot?
    @Published var selectedCategory: CourseCategory = .all
    @Published var expandedSemesters: Set<String> = []
    @Published var showWebView = false

    private var sessionRefreshAttempted = false
    private var termCache: [GradeQueryMode: CachedTermEntry] = [:]
    private var historyCache: CachedHistoryEntry?
    private let cacheKey = "grade_history.term_cache.v1"
    private let historyCacheKey = "grade_history.history_cache.v1"
    private let autoRefreshInterval: TimeInterval = 24 * 60 * 60

    // MARK: - Derived data

    var displayedSemesters: [SemesterGrade] {
        semesters
            .map { $0.filtered(by: selectedCategory) }
            .filter { selectedCategory == .all || !$0.courses.isEmpty }
            .sorted { lhs, rhs in
                if lhs.year == rhs.year { return lhs.term.order > rhs.term.order }
                return lhs.year > rhs.year
            }
    }

    var summary: GradeHistorySummary {
        GradeHistorySummary.from(semesters: displayedSemesters)
    }

    var yearSections: [(year: Int, semesters: [SemesterGrade])] {
        displayedSemesters.groupedByYearDescending()
    }

    // MARK: - Life cycle

    init() {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            semesters = Self.sampleData
            termSnapshot = Self.sampleTermSnapshot
            loadState = .loaded
            if let latest = semesters.first {
                expandedSemesters = [latest.id]
            }
        } else {
            loadPersistedCache()
            loadGrades()
        }
    }

    func refresh() {
        if selectedMode == .history {
            sessionRefreshAttempted = false
            loadGrades(force: true)
        } else {
            semesters = []
            termSnapshot = nil
            expandedSemesters = []
            sessionRefreshAttempted = false
            termCache[selectedMode] = nil
            persistCache()
            loadGrades(force: true)
        }
    }

    func selectMode(_ mode: GradeQueryMode) {
        if selectedMode != mode {
            selectedMode = mode
        }

        if mode == .history {
            if let cache = historyCache {
                if Self.hasMeaningfulHistory(cache.semesters) {
                    semesters = cache.semesters
                    loadState = .loaded
                    showWebView = false
                    if let latest = semesters.first {
                        expandedSemesters = [latest.id]
                    }
                    if Date().timeIntervalSince(cache.fetchedAt) <= autoRefreshInterval {
                        return
                    }
                } else {
                    historyCache = nil
                    UserDefaults.standard.removeObject(forKey: historyCacheKey)
                }
            } else {
                semesters = []
            }
            loadGrades()
            return
        }

        if let cache = termCache[mode] {
            termSnapshot = cache.snapshot
            loadState = .loaded
            showWebView = false
            if Date().timeIntervalSince(cache.fetchedAt) <= autoRefreshInterval {
                return
            }
        } else {
            termSnapshot = nil
        }

        loadGrades()
    }

    // MARK: - Expand / collapse

    func toggle(_ semester: SemesterGrade) {
        if expandedSemesters.contains(semester.id) {
            expandedSemesters.remove(semester.id)
        } else {
            expandedSemesters.insert(semester.id)
        }
    }

    // MARK: - Data loading

    private func loadGrades(force: Bool = false) {
        if selectedMode == .history {
            if let cache = historyCache,
               !force,
               Date().timeIntervalSince(cache.fetchedAt) <= autoRefreshInterval,
               Self.hasMeaningfulHistory(cache.semesters) {
                    semesters = cache.semesters
                    loadState = .loaded
                    showWebView = false
                    if let latest = semesters.first {
                        expandedSemesters = [latest.id]
                    }
                    return
            }
            loadState = .loading
            showWebView = true
            return
        }

        if let cache = termCache[selectedMode],
           !force,
           Date().timeIntervalSince(cache.fetchedAt) <= autoRefreshInterval {
            termSnapshot = cache.snapshot
            loadState = .loaded
            showWebView = false
            return
        }

        loadState = .loading
        showWebView = true
    }

    func handleWebResult(_ result: GradeHistoryWebResult) {
        showWebView = false

        switch result {
        case .historySuccess(let fetchedSemesters):
            sessionRefreshAttempted = false
            let sorted = fetchedSemesters.sorted { lhs, rhs in
                if lhs.year == rhs.year { return lhs.term.order > rhs.term.order }
                return lhs.year > rhs.year
            }
            guard Self.hasMeaningfulHistory(sorted) else {
                if let cache = historyCache, Self.hasMeaningfulHistory(cache.semesters) {
                    semesters = cache.semesters
                    loadState = .loaded
                } else {
                    loadState = .error("歷年成績資料格式異常，請稍後重試")
                }
                return
            }
            termSnapshot = nil
            semesters = sorted
            historyCache = CachedHistoryEntry(fetchedAt: Date(), semesters: semesters)
            if let data = try? JSONEncoder().encode(historyCache) {
                UserDefaults.standard.set(data, forKey: historyCacheKey)
            }
            loadState = .loaded
            if let latest = semesters.first {
                expandedSemesters = [latest.id]
            }

        case .termSuccess(let snapshot):
            sessionRefreshAttempted = false
            semesters = []
            termSnapshot = snapshot
            termCache[snapshot.mode] = CachedTermEntry(fetchedAt: Date(), snapshot: snapshot)
            persistCache()
            loadState = .loaded

        case .sessionExpired:
            if !sessionRefreshAttempted {
                sessionRefreshAttempted = true
                Task {
                    let refreshed = await SSOSessionService.shared.requestRefresh()
                    if refreshed {
                        self.showWebView = true
                    } else {
                        self.loadState = .error("登入工作階段已過期，請重新登入")
                    }
                }
            } else {
                sessionRefreshAttempted = false
                loadState = .error("登入工作階段已過期，請重新登入")
            }

        case .failure(let message):
            sessionRefreshAttempted = false
            if selectedMode == .history,
               let cache = historyCache,
               Self.hasMeaningfulHistory(cache.semesters) {
                semesters = cache.semesters
                loadState = .loaded
            } else {
                loadState = .error(message)
            }
        }
    }

    private func loadPersistedCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let entries = try? JSONDecoder().decode([String: CachedTermEntry].self, from: data) else {
            if let historyData = UserDefaults.standard.data(forKey: historyCacheKey),
               let history = try? JSONDecoder().decode(CachedHistoryEntry.self, from: historyData) {
                historyCache = history
            }
            return
        }
        termCache = Dictionary(uniqueKeysWithValues: entries.compactMap { key, value in
            guard let mode = GradeQueryMode(rawValue: key) else { return nil }
            return (mode, value)
        })
        if let historyData = UserDefaults.standard.data(forKey: historyCacheKey),
           let history = try? JSONDecoder().decode(CachedHistoryEntry.self, from: historyData) {
            historyCache = history
        }
    }

    private func persistCache() {
        let encoded = Dictionary(uniqueKeysWithValues: termCache.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private static func hasMeaningfulHistory(_ semesters: [SemesterGrade]) -> Bool {
        for sem in semesters where sem.creditsTaken >= 6 && sem.averageScore > 1 && !sem.courses.isEmpty {
            let gradedCount = sem.courses.filter { $0.credits > 0 && $0.score > 0 }.count
            if gradedCount >= 2 {
                return true
            }
        }
        return false
    }
}

// MARK: - Preview sample data

extension GradeHistoryViewModel {
    static let sampleData: [SemesterGrade] = [
        SemesterGrade(
            year: 113,
            term: .spring,
            averageScore: 86.4,
            gpa: nil,
            creditsTaken: 18,
            creditsPassed: 18,
            classRank: "4 / 43",
            courses: [
                GradeCourse(code: "CS3007", name: "作業系統", category: .required, credits: 3, score: 88, gpa: nil, remarks: nil),
                GradeCourse(code: "CS3103", name: "人工智慧導論", category: .required, credits: 3, score: 90, gpa: nil, remarks: "優秀"),
                GradeCourse(code: "CS3201", name: "行動應用開發", category: .elective, credits: 3, score: 85, gpa: nil, remarks: nil),
                GradeCourse(code: "CS2040", name: "機率與統計", category: .required, credits: 3, score: 82, gpa: nil, remarks: nil),
                GradeCourse(code: "GE2015", name: "科技與社會", category: .general, credits: 2, score: 84, gpa: nil, remarks: nil),
                GradeCourse(code: "PE2010", name: "體育：羽球", category: .physical, credits: 2, score: 79, gpa: nil, remarks: "通過")
            ]
        ),
        SemesterGrade(
            year: 113,
            term: .fall,
            averageScore: 82.7,
            gpa: nil,
            creditsTaken: 20,
            creditsPassed: 18,
            classRank: "7 / 43",
            courses: [
                GradeCourse(code: "CS2801", name: "演算法", category: .required, credits: 3, score: 83, gpa: nil, remarks: nil),
                GradeCourse(code: "CS2305", name: "資料庫系統", category: .required, credits: 3, score: 87, gpa: nil, remarks: nil),
                GradeCourse(code: "CS2402", name: "網路概論", category: .required, credits: 3, score: 81, gpa: nil, remarks: nil),
                GradeCourse(code: "CS3506", name: "資訊安全概論", category: .elective, credits: 3, score: 74, gpa: nil, remarks: "需補強"),
                GradeCourse(code: "GE1013", name: "哲學思辨", category: .general, credits: 2, score: 78, gpa: nil, remarks: nil),
                GradeCourse(code: "GE1021", name: "媒體素養", category: .general, credits: 2, score: 80, gpa: nil, remarks: nil),
                GradeCourse(code: "EL1005", name: "專業英文", category: .elective, credits: 2, score: 68, gpa: nil, remarks: "通過"),
                GradeCourse(code: "PE1020", name: "體育：游泳", category: .physical, credits: 2, score: 62, gpa: nil, remarks: "通過"),
                GradeCourse(code: "CS0000", name: "服務學習", category: .other, credits: 0, score: 100, gpa: nil, remarks: "已完成")
            ]
        ),
        SemesterGrade(
            year: 112,
            term: .spring,
            averageScore: 79.5,
            gpa: nil,
            creditsTaken: 18,
            creditsPassed: 16,
            classRank: "10 / 41",
            courses: [
                GradeCourse(code: "CS1503", name: "離散數學", category: .required, credits: 3, score: 76, gpa: nil, remarks: nil),
                GradeCourse(code: "CS1201", name: "物件導向程式設計", category: .required, credits: 3, score: 81, gpa: nil, remarks: nil),
                GradeCourse(code: "CS2102", name: "資料結構", category: .required, credits: 3, score: 78, gpa: nil, remarks: nil),
                GradeCourse(code: "MA1203", name: "線性代數", category: .elective, credits: 3, score: 73, gpa: nil, remarks: "重點加強"),
                GradeCourse(code: "GE1008", name: "社會觀察", category: .general, credits: 2, score: 75, gpa: nil, remarks: nil),
                GradeCourse(code: "GE1009", name: "美學欣賞", category: .general, credits: 2, score: 85, gpa: nil, remarks: nil),
                GradeCourse(code: "EL1001", name: "英文(一)", category: .elective, credits: 2, score: 58, gpa: nil, remarks: "需重修"),
                GradeCourse(code: "PE1001", name: "體育：籃球", category: .physical, credits: 0, score: 90, gpa: nil, remarks: "及格")
            ]
        )
    ]

    static let sampleTermSnapshot = TermScoreSnapshot(
        mode: .final,
        semesterTitle: "113 學年度第 上 學期",
        averageText: "84.6",
        rankText: "7",
        courses: [
            TermScoreCourse(type: "必修", name: "演算法", scoreText: "83"),
            TermScoreCourse(type: "必修", name: "資料庫系統", scoreText: "87"),
            TermScoreCourse(type: "選修", name: "資訊安全概論", scoreText: "74"),
            TermScoreCourse(type: "通識", name: "媒體素養", scoreText: "80")
        ]
    )
}
