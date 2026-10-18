import ActivityKit
import Foundation

nonisolated enum ClassScheduleCache {
    static let key = "classSchedule.v2.cachedData"
    static let appGroupIdentifier = "group.dev.chien.niuapp"

    static func loadBase(sessionID: String) -> (schedule: ClassSchedule, customCourses: [CustomCourse])? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: key),
              let cached = try? JSONDecoder().decode(ClassSchedule.self, from: data),
              cached.ownerSessionID == sessionID else { return nil }
        return (cached, CustomCourseSnapshot.courses(for: cached, in: defaults))
    }

    static func load(sessionID: String, now: Date) -> ClassSchedule? {
        guard let base = loadBase(sessionID: sessionID) else { return nil }
        return base.schedule.merging(base.customCourses, weekContaining: now)
    }
}

enum CampusShortcutError: LocalizedError {
    case loginRequired, scheduleRequired, activitiesDisabled, featureDisabled
    case updateFailed, sessionChanged

    var errorDescription: String? {
        switch self {
        case .loginRequired: "請先開啟 NIU-Life 並登入，再執行這個捷徑。"
        case .scheduleRequired: "尚未儲存目前帳號的課表，請先開啟 NIU-Life 的課表並完成載入。"
        case .activitiesDisabled: "iOS 尚未允許即時動態，請至系統設定開啟 NIU-Life 的即時動態。"
        case .featureDisabled: "課表即時動態尚未啟用，請先執行「啟動課表即時動態」或在 App 的通知設定啟用。"
        case .updateFailed: "無法更新即時動態，請開啟 NIU-Life 後再試一次。"
        case .sessionChanged: "登入狀態或即時動態設定已變更，請重新執行捷徑。"
        }
    }
}

@MainActor
enum CampusShortcutService {
    static func authenticatedSession() throws -> String {
        guard !UserDefaults.standard.bool(forKey: "app.logoutCleanupPending"),
              let username = UserDefaults.standard.string(forKey: StorageKeys.username), !username.isEmpty,
              let session = UserDefaults.standard.string(forKey: StorageKeys.authSessionID) else {
            throw CampusShortcutError.loginRequired
        }
        return session
    }

    static func schedule(session: String, now: Date) async throws -> ClassSchedule {
        let cached = await Task.detached(priority: .userInitiated) {
            ClassScheduleCache.load(sessionID: session, now: now)
        }.value
        try Task.checkCancellation()
        guard (try authenticatedSession()) == session else { throw CampusShortcutError.sessionChanged }
        guard let cached else { throw CampusShortcutError.scheduleRequired }
        return cached
    }

    static func refreshActivity(startIfNeeded: Bool) async throws -> String {
        let session = try authenticatedSession()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw CampusShortcutError.activitiesDisabled }
        let result = await ClassLiveActivityCoordinator.shared.refreshFromScheduleCache(
            enableIfNeeded: startIfNeeded,
            shortcutRequest: true
        )
        try Task.checkCancellation()
        guard (try authenticatedSession()) == session else { throw CampusShortcutError.sessionChanged }
        ClassLiveActivityBackgroundRefreshCoordinator.shared.scheduleIfNeeded()
        switch result {
        case .updated:
            guard NotificationSettings.load().classLiveActivityEnabled else { throw CampusShortcutError.featureDisabled }
            return "已依儲存的課表更新鎖定畫面與靈動島。"
        case .outsideDisplayWindow:
            guard NotificationSettings.load().classLiveActivityEnabled else { throw CampusShortcutError.featureDisabled }
            return "課表即時動態已啟用，但目前不在顯示時段。顯示時段為當天第一堂課前 30 分鐘至最後一堂課結束；舊動態已清除。"
        case .noSchedule: throw CampusShortcutError.scheduleRequired
        case .notAuthorized: throw CampusShortcutError.activitiesDisabled
        case .disabled: throw CampusShortcutError.featureDisabled
        case .notAuthenticated: throw CampusShortcutError.loginRequired
        case .superseded: return "另一個即時動態操作已接手處理，請稍後查看鎖定畫面或重新執行捷徑。"
        case .failed: throw CampusShortcutError.updateFailed
        }
    }

    static func stopActivity() async throws -> String {
        try Task.checkCancellation()
        NotificationSettings.setClassLiveActivityEnabled(false)
        ClassLiveActivityBackgroundRefreshCoordinator.shared.cancel()
        await ClassLiveActivityCoordinator.shared.endAll()
        try Task.checkCancellation()
        guard !NotificationSettings.load().classLiveActivityEnabled else { throw CampusShortcutError.sessionChanged }
        return "已關閉課表即時動態。再次執行「啟動課表即時動態」即可恢復。"
    }

    static func todaySchedule() async throws -> String {
        let session = try authenticatedSession()
        let now = Date()
        let cached = try await schedule(session: session, now: now)
        let courses = cached.sessions(on: now).mergedConsecutiveCourses().map(\.session)
        let date = dateLabel(now)
        let content = courses.isEmpty ? "\(date) 的儲存課表沒有課程。" :
            "\(date) 的課表：\n" + courses.map(courseLabel).joined(separator: "\n")
        return content + "\n課表更新時間：\(dateLabel(cached.fetchedAt))"
    }

    static func nextClass() async throws -> String {
        let session = try authenticatedSession()
        let now = Date()
        guard let horizon = ScheduleClock.calendar.date(byAdding: .day, value: 7, to: now) else {
            throw CampusShortcutError.updateFailed
        }
        for offset in 0...7 {
            guard let day = ScheduleClock.calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let cached = try await schedule(session: session, now: day)
            if let course = cached.sessions(on: day).mergedConsecutiveCourses()
                .map(\.session).first(where: { $0.start > now && $0.start <= horizon }) {
                return "\(dateLabel(course.start))\n\(courseLabel(course))\n課表更新時間：\(dateLabel(cached.fetchedAt))"
            }
        }
        return "未來 7 天的儲存課表沒有尚未開始的課程。"
    }

    private static func courseLabel(_ course: ScheduleSession) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.calendar = ScheduleClock.calendar
        formatter.timeZone = ScheduleClock.calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: course.start))–\(formatter.string(from: course.end)) \(course.courseName)・\(course.classroom)・\(course.periodLabel)"
    }

    private static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.calendar = ScheduleClock.calendar
        formatter.timeZone = ScheduleClock.calendar.timeZone
        formatter.dateFormat = "yyyy 年 M 月 d 日 EEEE HH:mm"
        return formatter.string(from: date)
    }
}

enum PostalShortcutError: LocalizedError {
    case nameRequired, recipientRequired, failed(String)

    var errorDescription: String? {
        switch self {
        case .nameRequired: "尚未取得目前帳號的姓名，請開啟 NIU-Life 的郵件查詢確認個人資料後再試。"
        case .recipientRequired: "請填寫收件人姓名或手機號碼其中一項。"
        case .failed(let message): message
        }
    }
}

@MainActor
enum PostalShortcutService {
    static let maxPages = 5

    /// `ownMail` searches the signed-in account's name; otherwise the given name or phone.
    static func search(ownMail: Bool, name: String?, phone: String?,
                       status: PostalStatus) async throws -> (records: [PostalRecord], query: PostalQuery, truncated: Bool) {
        var session: String?
        let query: PostalQuery
        if ownMail {
            session = try CampusShortcutService.authenticatedSession()
            query = PostalQuery(name: try ownName(), status: status)
        } else {
            query = PostalQuery(name: name ?? "", phone: phone ?? "", status: status).normalized
            guard query.canSearch else { throw PostalShortcutError.recipientRequired }
        }
        let service = await PostalService.make()
        defer { service.invalidate() }
        do {
            var page = try await service.search(query)
            var records = page.records
            var pages = 1
            while page.nextForm != nil, pages < maxPages {
                try Task.checkCancellation()
                page = try await service.nextPage(after: page)
                let known = Set(records.map(\.id))
                records += page.records.filter { !known.contains($0.id) }
                pages += 1
            }
            try Task.checkCancellation()
            // A logout or account switch during the request must not reveal the previous user's mail.
            if let session, (try CampusShortcutService.authenticatedSession()) != session {
                throw CampusShortcutError.sessionChanged
            }
            return (records, query, page.nextForm != nil)
        } catch let error as CampusShortcutError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PostalShortcutError.failed(PostalQueryViewModel.message(for: error))
        }
    }

    static func ownName() throws -> String {
        let defaults = UserDefaults.standard
        let account = defaults.string(forKey: StorageKeys.username)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = defaults.string(forKey: StorageKeys.name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, name.lowercased() != account.lowercased() else { throw PostalShortcutError.nameRequired }
        return name
    }

    static func summary(_ records: [PostalRecord], query: PostalQuery, truncated: Bool) -> String {
        let target = query.name.isEmpty ? "指定手機號碼" : query.name
        guard !records.isEmpty else { return "查無\(target)的\(query.status.title)郵件。" }
        let shown = records.prefix(10).map { record in
            var parts = ["\(record.receivedDate) 收件", record.category, record.recipient]
            if !record.trackingNumber.isEmpty { parts.append("號碼 \(record.trackingNumber)") }
            if !record.unit.isEmpty { parts.append(record.unit) }
            if !record.note.isEmpty { parts.append(record.note) }
            return "• " + parts.filter { !$0.isEmpty }.joined(separator: "・")
        }
        var lines = ["\(target)有 \(records.count)\(truncated ? " 筆以上" : " 筆")\(query.status.title)郵件："] + shown
        if records.count > shown.count { lines.append("其餘 \(records.count - shown.count) 筆請在 App 的郵件查詢查看。") }
        return lines.joined(separator: "\n")
    }
}

extension Notification.Name {
    static let classLiveActivitySettingDidChange = Notification.Name("classLiveActivitySettingDidChange")
}
