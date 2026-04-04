import Foundation
import SwiftUI
import Combine

@MainActor
final class ClassScheduleViewModel: ObservableObject {

    // MARK: - State

    enum LoadState: Equatable {
        case idle
        case loading
        case cached    // Showing valid cached data
        case fresh     // Just fetched from network
        case error(String)
    }

    @Published var schedule: ClassSchedule?
    @Published var loadState: LoadState = .idle
    @Published var selectedDayIndex: Int = 0
    @Published var isFetchingInBackground = false  // background refresh while showing cache

    // Controls whether the invisible WebView is in the hierarchy
    @Published var showWebView = false

    /// Guard to prevent infinite retry loops if re-auth succeeds but schedule
    /// fetch still fails due to a server-side issue.
    private var sessionRefreshAttempted = false

    private let cacheKey = "classSchedule.v2.cachedData"
    private let appGroupIdentifier = "group.CHIEN.NIU-APP"

    // MARK: - Computed helpers

    private static let weekdayNames = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
    private static let shortNames    = ["一", "二", "三", "四", "五", "六", "日"]

    /// Fixed Mon–Fri tabs, plus any weekend days actually present in the fetched schedule.
    /// This guarantees Monday is always visible even when the school table omits it.
    var displayDayHeaders: [String] {
        let base = Array(Self.weekdayNames.prefix(5))   // always Mon-Fri
        let extra = Self.weekdayNames.dropFirst(5).filter { day in
            schedule?.dayHeaders.contains(day) == true
        }
        return base + Array(extra)
    }

    var displayShortLabels: [String] {
        displayDayHeaders.map { day in
            Self.shortNames[Self.weekdayNames.firstIndex(of: day) ?? 0]
        }
    }

    /// For a given tab index in `displayDayHeaders`, returns the column index
    /// inside `schedule.dayHeaders` (nil if that weekday isn't in the fetched schedule).
    func scheduleColumnIndex(for displayIndex: Int) -> Int? {
        guard displayIndex < displayDayHeaders.count else { return nil }
        let day = displayDayHeaders[displayIndex]
        return schedule?.dayHeaders.firstIndex(of: day)
    }

    var periods: [ClassPeriod] {
        schedule?.periods ?? []
    }

    /// Relative time string for cache age, e.g. "3 小時前"
    var cacheAgeText: String? {
        guard let schedule = schedule else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: schedule.fetchedAt, relativeTo: Date())
    }

    /// Today's display-tab index (index into displayDayHeaders).
    /// Always returns a valid value (Mon–Fri are always in displayDayHeaders).
    var todayDayIndex: Int {
        let weekday = Calendar.current.component(.weekday, from: Date())
        let mondayBased = (weekday + 5) % 7   // 0=Mon…6=Sun
        let todayName = mondayBased < Self.weekdayNames.count
            ? Self.weekdayNames[mondayBased] : "星期一"
        return displayDayHeaders.firstIndex(of: todayName) ?? 0
    }

    // MARK: - Load

    func loadSchedule() {
        if let cached = loadFromCache() {
            schedule = cached
            selectedDayIndex = todayDayIndex
            if cached.isCacheValid {
                loadState = .cached
                return  // Cache is fresh – no need to fetch
            }
            // Cache exists but stale – show it while fetching in background
            loadState = .cached
            isFetchingInBackground = true
            showWebView = true
        } else {
            loadState = .loading
            showWebView = true
        }
    }

    func refresh() {
        clearCache()
        schedule = nil
        loadState = .loading
        isFetchingInBackground = false
        sessionRefreshAttempted = false
        showWebView = true
    }

    // MARK: - WebView result handler

    func handleWebResult(_ result: ClassScheduleWebResult) {
        showWebView = false

        switch result {
        case .success(let rows):
            isFetchingInBackground = false
            sessionRefreshAttempted = false
            let parsed = parseTableRows(rows)
            schedule = parsed
            // Recalculate today's index now that we have the real day headers
            selectedDayIndex = todayDayIndex
            saveToCache(parsed)
            NotificationCenter.default.post(name: .classScheduleDidUpdate, object: nil)
            loadState = .fresh

        case .notAvailable(let message):
            isFetchingInBackground = false
            sessionRefreshAttempted = false
            if schedule == nil {
                loadState = .error(message)
            }

        case .sessionExpired:
            // Try a transparent SSO re-login first (only once per operation).
            // While re-auth is happening the user still sees the cached schedule
            // (or the loading spinner if there is no cache yet).
            if !sessionRefreshAttempted {
                sessionRefreshAttempted = true
                Task {
                    let refreshed = await SSOSessionService.shared.requestRefresh()
                    if refreshed {
                        // Shared cookie store is now refreshed – retry the schedule fetch
                        showWebView = true
                    } else {
                        isFetchingInBackground = false
                        if schedule == nil {
                            loadState = .error("登入工作階段已過期，請重新登入")
                        }
                        // If cached data exists, keep showing it silently
                    }
                }
            } else {
                // Second expiry after a successful re-auth – give up
                sessionRefreshAttempted = false
                isFetchingInBackground = false
                if schedule == nil {
                    loadState = .error("登入工作階段已過期，請重新登入")
                }
            }

        case .failure(let message):
            isFetchingInBackground = false
            sessionRefreshAttempted = false
            if schedule == nil {
                loadState = .error(message)
            }
        }
    }

    // MARK: - HTML table → model

    private func parseTableRows(_ rows: [[String]]) -> ClassSchedule {
        guard rows.count > 1 else {
            return ClassSchedule(
                periods: [], dayCount: 5, dayHeaders: [], fetchedAt: Date())
        }

        // Header row can be either:
        //   ["節次", "時間", "星期一", …]  (2 leading columns)
        //   ["節次時間", "星期一", …]       (1 combined leading column)
        // Dynamically find where the weekday columns start.
        let header = rows[0]
        let firstDayColumnIndex = header.firstIndex { $0.contains("星期") } ?? 2
        let dayHeaders = Array(header[firstDayColumnIndex...])
        let dayCount = dayHeaders.count

        var periods: [ClassPeriod] = []

        for row in rows.dropFirst() {
            guard row.count > firstDayColumnIndex else { continue }

            let periodId: String
            let timeRange: String

            if firstDayColumnIndex >= 2 {
                // Two separate leading columns: [period, time, courses...]
                periodId = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
                timeRange = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Single combined leading column: "第1節\n08:10~09:00"
                let combined = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = combined
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                periodId = parts.first ?? combined
                timeRange = parts.dropFirst().joined(separator: "\n")
            }

            guard !periodId.isEmpty else { continue }

            var courses: [Int: CourseInfo] = [:]
            for (dayIndex, cellText) in row.dropFirst(firstDayColumnIndex).enumerated() {
                guard dayIndex < dayCount else { break }
                let text = cellText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    courses[dayIndex] = CourseInfo(raw: text)
                }
            }

            periods.append(ClassPeriod(id: periodId, timeRange: timeRange, courses: courses))
        }

        return ClassSchedule(
            periods: periods,
            dayCount: dayCount,
            dayHeaders: dayHeaders,
            fetchedAt: Date()
        )
    }

    // MARK: - Cache

    private func loadFromCache() -> ClassSchedule? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode(ClassSchedule.self, from: data)
        else { return nil }
        return decoded
    }

    private func saveToCache(_ schedule: ClassSchedule) {
        if let data = try? JSONEncoder().encode(schedule) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults(suiteName: appGroupIdentifier)?.set(data, forKey: cacheKey)
        }
    }

    private func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults(suiteName: appGroupIdentifier)?.removeObject(forKey: cacheKey)
    }
}
