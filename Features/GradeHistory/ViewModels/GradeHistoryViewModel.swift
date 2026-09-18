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
        case idle, loading, loaded
        case error(String)
    }

    @Published var loadState: LoadState = .idle
    @Published var selectedMode: GradeQueryMode = .history
    @Published var semesters: [SemesterGrade] = []
    @Published var termSnapshot: TermScoreSnapshot?
    @Published var selectedSemesterID: String?
    @Published var expandedSemesters: Set<String> = []
    @Published var showWebView = false
    @Published private(set) var isModeLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var webViewID = UUID()
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastRefreshError: String?

    private var sessionRefreshAttempted = false
    private var operationID = UUID()
    private var loadingMode: GradeQueryMode?
    private var sessionRefreshTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var termCache: [GradeQueryMode: CachedTermEntry] = [:]
    private var historyCache: CachedHistoryEntry?
    private let cacheDefaults: UserDefaults
    private let cacheKey: String?
    private let historyCacheKey: String?
    private let refreshTimeout: Duration
    private let autoRefreshInterval: TimeInterval = 24 * 60 * 60

    // MARK: - Derived data

    var displayedSemesters: [SemesterGrade] {
        let filtered: [SemesterGrade]
        if let id = selectedSemesterID {
            filtered = semesters.filter { $0.id == id }
        } else {
            filtered = semesters
        }
        return filtered.sorted { lhs, rhs in
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

    init(cacheDefaults: UserDefaults = .standard, account: String? = nil,
         refreshTimeout: Duration = .seconds(120)) {
        self.cacheDefaults = cacheDefaults
        self.refreshTimeout = refreshTimeout
        let owner = (account ?? cacheDefaults.string(forKey: "app.user.username") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cacheKey = owner.isEmpty ? nil : "grade_history.term_cache.v2.\(owner)"
        historyCacheKey = owner.isEmpty ? nil : "grade_history.history_cache.v2.\(owner)"
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            semesters = Self.sampleData
            termSnapshot = Self.sampleTermSnapshot
            loadState = .loaded
        } else {
            loadPersistedCache()
            loadGrades()
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        loadGrades(force: true)
    }

    func refreshAndWait() async {
        refresh()
        let operation = operationID
        while isRefreshing && operationID == operation && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    func selectMode(_ mode: GradeQueryMode) {
        finishOperation()
        selectedMode = mode
        selectedSemesterID = nil
        expandedSemesters = []
        loadGrades()
    }

    func toggle(_ semester: SemesterGrade) {
        if expandedSemesters.contains(semester.id) {
            expandedSemesters.remove(semester.id)
        } else {
            expandedSemesters.insert(semester.id)
        }
    }

    /// Restore even an old cache before networking, so outages never erase data.
    private func restoreDisplayedCache() -> Bool {
        semesters = []
        termSnapshot = nil
        lastUpdated = nil
        if selectedMode == .history, let cache = historyCache,
           Self.hasMeaningfulHistory(cache.semesters) {
            semesters = cache.semesters
            lastUpdated = cache.fetchedAt
            if expandedSemesters.isEmpty, let latest = semesters.first {
                expandedSemesters = [latest.id]
            }
        } else if selectedMode != .history, let cache = termCache[selectedMode] {
            termSnapshot = cache.snapshot
            lastUpdated = cache.fetchedAt
        }
        return lastUpdated != nil
    }

    private func loadGrades(force: Bool = false) {
        lastRefreshError = nil
        let hasCache = restoreDisplayedCache()
        loadState = hasCache ? .loaded : .loading
        if !force, let lastUpdated, Date().timeIntervalSince(lastUpdated) <= autoRefreshInterval {
            return
        }
        operationID = UUID()
        webViewID = UUID()
        loadingMode = selectedMode
        sessionRefreshAttempted = false
        isRefreshing = true
        isModeLoading = true
        showWebView = true
        scheduleLoadTimeout()
    }

    /// Network loading has its own budget; interactive SSO has a separate timeout.
    private func scheduleLoadTimeout() {
        let operation = operationID
        let timeout = refreshTimeout
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.operationID == operation, self.isRefreshing else { return }
            self.fail("成績更新逾時，請稍後重試")
        }
    }

    func handleWebResult(_ result: GradeHistoryWebResult, requestID: UUID) {
        guard isRefreshing, showWebView, requestID == webViewID,
              loadingMode == selectedMode else { return }
        showWebView = false
        switch result {
        case .historySuccess(let fetched):
            guard selectedMode == .history else { fail("成績查詢模式不符，請重試"); return }
            let sorted = fetched.sorted {
                $0.year == $1.year ? $0.term.order > $1.term.order : $0.year > $1.year
            }
            guard Self.hasMeaningfulHistory(sorted) else {
                fail("歷年成績資料格式異常，請稍後重試")
                return
            }
            semesters = sorted
            termSnapshot = nil
            let date = Date()
            historyCache = CachedHistoryEntry(fetchedAt: date, semesters: sorted)
            lastUpdated = date
            if let key = historyCacheKey, let data = try? JSONEncoder().encode(historyCache) {
                cacheDefaults.set(data, forKey: key)
            }
            if let selectedSemesterID, !sorted.contains(where: { $0.id == selectedSemesterID }) {
                self.selectedSemesterID = nil
            }
            if let latest = sorted.first { expandedSemesters.insert(latest.id) }
            finishOperation()
            loadState = .loaded

        case .termSuccess(let snapshot):
            guard snapshot.mode == selectedMode else { fail("成績查詢模式不符，請重試"); return }
            semesters = []
            termSnapshot = snapshot
            let date = Date()
            termCache[snapshot.mode] = CachedTermEntry(fetchedAt: date, snapshot: snapshot)
            lastUpdated = date
            persistTermCache()
            finishOperation()
            loadState = .loaded

        case .sessionExpired:
            guard !sessionRefreshAttempted else {
                fail("教務系統登入仍已逾時，請稍後重試，或到設定重新登入")
                return
            }
            sessionRefreshAttempted = true
            let operation = operationID
            timeoutTask?.cancel()
            timeoutTask = nil
            sessionRefreshTask = Task { [weak self] in
                let refreshed = await SSOSessionService.shared.requestRefresh(force: true)
                guard !Task.isCancelled, let self, self.isRefreshing,
                      self.operationID == operation else { return }
                if refreshed {
                    self.scheduleLoadTimeout()
                    self.webViewID = UUID()
                    self.showWebView = true
                } else {
                    self.fail(SSOSessionService.shared.lastFailureMessage
                    ?? "無法更新校務登入，請稍後重試，或到設定重新登入")
                }
            }

        case .failure(let message):
            fail(message)
        }
    }

    private func finishOperation() {
        operationID = UUID()
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        showWebView = false
        isRefreshing = false
        isModeLoading = false
        loadingMode = nil
        sessionRefreshAttempted = false
    }

    private func fail(_ message: String) {
        finishOperation()
        lastRefreshError = message
        loadState = lastUpdated != nil ? .loaded : .error(message)
    }

    private func loadPersistedCache() {
        // v1 caches had no account owner; do not display another user's records.
        if let key = cacheKey, let data = cacheDefaults.data(forKey: key),
           let entries = try? JSONDecoder().decode([String: CachedTermEntry].self, from: data) {
            termCache = Dictionary(uniqueKeysWithValues: entries.compactMap { key, value in
                guard let mode = GradeQueryMode(rawValue: key), mode == value.snapshot.mode else { return nil }
                return (mode, value)
            })
        }
        if let key = historyCacheKey, let data = cacheDefaults.data(forKey: key),
           let history = try? JSONDecoder().decode(CachedHistoryEntry.self, from: data) {
            historyCache = history
        }
    }

    private func persistTermCache() {
        let encoded = Dictionary(uniqueKeysWithValues: termCache.map { ($0.key.rawValue, $0.value) })
        guard let key = cacheKey, let data = try? JSONEncoder().encode(encoded) else { return }
        cacheDefaults.set(data, forKey: key)
    }

    private static func hasMeaningfulHistory(_ semesters: [SemesterGrade]) -> Bool {
        semesters.contains { semester in
            semester.creditsTaken >= 6 && semester.averageScore > 1 && !semester.courses.isEmpty
                && semester.courses.filter { $0.credits > 0 && $0.score > 0 }.count >= 2
        }
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
