import SwiftUI
import Combine
import BackgroundTasks
import UserNotifications
#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
final class AppState: ObservableObject {

    @Published var isAuthenticated: Bool = false
    @Published var currentUser: User?
    @Published var notificationSettings = NotificationSettings.load()

    /// `true` after the user explicitly presses the logout button.
    /// Used by LoginView to suppress automatic re-login.
    @Published private(set) var didExplicitlyLogout: Bool = false
    private var isRefreshingProfile = false
    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        observeClassScheduleUpdates()
        checkAuthenticationStatus()
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func login(user: User) {
        let mergedUser = mergedWithPersistedProfile(user)
        currentUser = mergedUser
        isAuthenticated = true
        didExplicitlyLogout = false
        saveAuthState()
        SSOSessionService.shared.enableAutoRefresh()
        // Extract EUNI redirect link while SSO session is still alive
        MoodleSessionManager.shared.fetchEUNILink()
        print("[App] 使用者已登入: \(mergedUser.name)")
        Task { await refreshNotificationSchedules() }
        
        if mergedUser.department?.nilIfEmpty == nil || mergedUser.grade?.nilIfEmpty == nil {
            Task { await refreshProfileIfNeeded(force: true) }
        }
    }

    func logout() {
        currentUser = nil
        isAuthenticated = false
        didExplicitlyLogout = true
        clearAuthState()
        SSOSessionService.shared.disableAutoRefresh()
        MoodleSessionManager.shared.reset()
        NotificationScheduler.shared.clearAllManagedNotifications()
        ClassLiveActivityBackgroundRefreshCoordinator.shared.cancel()
        Task { await ClassLiveActivityCoordinator.shared.endAll() }
        print("[App] 使用者已登出")
    }

    private func checkAuthenticationStatus() {
        if let savedUsername = UserDefaults.standard.string(forKey: StorageKeys.username),
           let savedName = UserDefaults.standard.string(forKey: StorageKeys.name),
           !savedUsername.isEmpty {
            let savedDepartment = UserDefaults.standard.string(forKey: StorageKeys.department)
            let savedGrade = UserDefaults.standard.string(forKey: StorageKeys.grade)
            currentUser = User(
                username: savedUsername,
                name: savedName,
                department: savedDepartment?.nilIfEmpty,
                grade: savedGrade?.nilIfEmpty
            )
            isAuthenticated = true
            SSOSessionService.shared.enableAutoRefresh()
            // Try to fetch EUNI link if we don't have one yet
            if SSOEUNISettings.shared.euniFullURL == nil {
                MoodleSessionManager.shared.fetchEUNILink()
            }
            Task { await refreshNotificationSchedules() }
            Task { await refreshClassLiveActivitiesIfNeeded() }
            Task { await refreshProfileIfNeeded() }
        }
    }

    private func saveAuthState() {
        guard let user = currentUser else { return }
        UserDefaults.standard.set(user.username, forKey: StorageKeys.username)
        UserDefaults.standard.set(user.name, forKey: StorageKeys.name)
        UserDefaults.standard.set(user.department, forKey: StorageKeys.department)
        UserDefaults.standard.set(user.grade, forKey: StorageKeys.grade)
        UserDefaults.standard.set(Date(), forKey: StorageKeys.loginTime)
    }

    private func clearAuthState() {
        UserDefaults.standard.removeObject(forKey: StorageKeys.username)
        UserDefaults.standard.removeObject(forKey: StorageKeys.name)
        UserDefaults.standard.removeObject(forKey: StorageKeys.department)
        UserDefaults.standard.removeObject(forKey: StorageKeys.grade)
        UserDefaults.standard.removeObject(forKey: StorageKeys.loginTime)
    }

    private func mergedWithPersistedProfile(_ user: User) -> User {
        let savedDepartment = UserDefaults.standard.string(forKey: StorageKeys.department)?.nilIfEmpty
        let savedGrade = UserDefaults.standard.string(forKey: StorageKeys.grade)?.nilIfEmpty
        return User(
            id: user.id,
            username: user.username,
            name: user.name,
            email: user.email,
            avatarURL: user.avatarURL,
            department: user.department?.nilIfEmpty ?? savedDepartment,
            grade: user.grade?.nilIfEmpty ?? savedGrade
        )
    }

    func updateProfileFromSSO(_ info: StudentInfo) {
        guard var user = currentUser else { return }
        user = User(
            id: user.id,
            username: user.username,
            name: info.name.nilIfEmpty ?? user.name,
            email: user.email,
            avatarURL: user.avatarURL,
            department: info.department.nilIfEmpty ?? user.department,
            grade: info.grade.nilIfEmpty ?? user.grade
        )
        currentUser = user
        saveAuthState()
    }

    func refreshProfileIfNeeded(force: Bool = false) async {
        guard isAuthenticated,
              let user = currentUser,
              !isRefreshingProfile else { return }
        let needsRefresh = force || user.department?.nilIfEmpty == nil || user.grade?.nilIfEmpty == nil
        guard needsRefresh else { return }

        isRefreshingProfile = true
        defer { isRefreshingProfile = false }
        _ = await SSOSessionService.shared.requestRefresh()
    }

    func setAssignmentNotificationsEnabled(_ enabled: Bool) async {
        notificationSettings.assignmentDeadlineEnabled = enabled
        notificationSettings.save()
        if enabled {
            _ = await NotificationScheduler.shared.requestAuthorizationIfNeeded()
        }
        await refreshNotificationSchedules()
    }

    func setCalendarNotificationsEnabled(_ enabled: Bool) async {
        notificationSettings.academicCalendarEnabled = enabled
        notificationSettings.save()
        if enabled {
            _ = await NotificationScheduler.shared.requestAuthorizationIfNeeded()
        }
        await refreshNotificationSchedules()
    }

    func setClassRemindersEnabled(_ enabled: Bool) async {
        notificationSettings.classReminderEnabled = enabled
        notificationSettings.save()
        if enabled {
            _ = await NotificationScheduler.shared.requestAuthorizationIfNeeded()
        }
        await refreshNotificationSchedules()
    }

    func setClassLiveActivityEnabled(_ enabled: Bool) async {
        notificationSettings.classLiveActivityEnabled = enabled
        notificationSettings.save()
        if enabled {
            await refreshClassLiveActivitiesIfNeeded(forceRebuild: true)
            ClassLiveActivityBackgroundRefreshCoordinator.shared.scheduleIfNeeded()
        } else {
            ClassLiveActivityBackgroundRefreshCoordinator.shared.cancel()
            await ClassLiveActivityCoordinator.shared.endAll()
        }
    }

    func refreshNotificationSchedules() async {
        guard isAuthenticated else { return }
        guard let credentials = LoginRepository.shared.getSavedCredentials() else { return }
        await NotificationScheduler.shared.scheduleAll(
            settings: notificationSettings,
            username: credentials.username,
            password: credentials.password
        )
        await refreshClassLiveActivitiesIfNeeded()
        ClassLiveActivityBackgroundRefreshCoordinator.shared.scheduleIfNeeded()
    }

    func applicationDidBecomeActive() async {
        await refreshClassLiveActivitiesIfNeeded(forceRebuild: true)
        ClassLiveActivityBackgroundRefreshCoordinator.shared.scheduleIfNeeded()
    }

    func applicationDidEnterBackground() {
        ClassLiveActivityBackgroundRefreshCoordinator.shared.scheduleIfNeeded()
    }


    private func observeClassScheduleUpdates() {
        let observer = NotificationCenter.default.addObserver(
            forName: .classScheduleDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.refreshNotificationSchedules()
                await self.refreshClassLiveActivitiesIfNeeded()
            }
        }
        notificationObservers.append(observer)

    }

    private func refreshClassLiveActivitiesIfNeeded(forceRebuild: Bool = false) async {
        guard isAuthenticated else { return }
        guard notificationSettings.classLiveActivityEnabled else { return }
        await ClassLiveActivityCoordinator.shared.refreshFromScheduleCache(forceRebuild: forceRebuild)
    }
}

private enum StorageKeys {
    static let username = "app.user.username"
    static let name = "app.user.name"
    static let department = "app.user.department"
    static let grade = "app.user.grade"
    static let loginTime = "app.user.loginTime"
}

struct NotificationSettings {
    var assignmentDeadlineEnabled: Bool
    var academicCalendarEnabled: Bool
    var classReminderEnabled: Bool
    var classLiveActivityEnabled: Bool

    static func load() -> NotificationSettings {
        let defaults = UserDefaults.standard
        return NotificationSettings(
            assignmentDeadlineEnabled: defaults.object(forKey: NotificationKeys.assignmentDeadlineEnabled) as? Bool ?? false,
            academicCalendarEnabled: defaults.object(forKey: NotificationKeys.academicCalendarEnabled) as? Bool ?? false,
            classReminderEnabled: defaults.object(forKey: NotificationKeys.classReminderEnabled) as? Bool ?? false,
            classLiveActivityEnabled: defaults.object(forKey: NotificationKeys.classLiveActivityEnabled) as? Bool ?? false
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(assignmentDeadlineEnabled, forKey: NotificationKeys.assignmentDeadlineEnabled)
        defaults.set(academicCalendarEnabled, forKey: NotificationKeys.academicCalendarEnabled)
        defaults.set(classReminderEnabled, forKey: NotificationKeys.classReminderEnabled)
        defaults.set(classLiveActivityEnabled, forKey: NotificationKeys.classLiveActivityEnabled)
    }
}

private enum NotificationKeys {
    static let assignmentDeadlineEnabled = "app.notification.assignmentDeadlineEnabled"
    static let academicCalendarEnabled = "app.notification.academicCalendarEnabled"
    static let classReminderEnabled = "app.notification.classReminderEnabled"
    static let classLiveActivityEnabled = "app.notification.classLiveActivityEnabled"
}

@MainActor
private final class NotificationScheduler {
    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()
    private let assignmentPrefix = "notify.assignment."
    private let calendarPrefix = "notify.calendar."
    private let classReminderPrefix = "notify.class."
    private let classScheduleCacheKey = "classSchedule.v2.cachedData"

    private init() {}

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await currentNotificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    func clearAllManagedNotifications() {
        Task {
            let pending = await pendingRequests()
            let ids = pending
                .map(\.identifier)
                .filter {
                    $0.hasPrefix(assignmentPrefix) ||
                    $0.hasPrefix(calendarPrefix) ||
                    $0.hasPrefix(classReminderPrefix)
                }
            guard !ids.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func scheduleAll(settings: NotificationSettings, username: String, password: String) async {
        await clear(byPrefix: assignmentPrefix)
        await clear(byPrefix: calendarPrefix)
        await clear(byPrefix: classReminderPrefix)

        guard settings.assignmentDeadlineEnabled || settings.academicCalendarEnabled || settings.classReminderEnabled else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        if settings.assignmentDeadlineEnabled {
            await scheduleAssignmentDeadlines(username: username, password: password)
        }
        if settings.academicCalendarEnabled {
            await scheduleAcademicCalendarEvents()
        }
        if settings.classReminderEnabled {
            await scheduleClassReminders()
        }
    }

    private func clear(byPrefix prefix: String) async {
        let pending = await pendingRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func scheduleAssignmentDeadlines(username: String, password: String) async {
        do {
            if !MoodleService.shared.isAuthenticated {
                try await MoodleService.shared.authenticate(username: username, password: password)
            }
            let courses = try await MoodleService.shared.fetchCourses()
            var allAssignments: [(courseName: String, assignment: MoodleAssignment)] = []
            for course in courses {
                let assignments = try await MoodleService.shared.fetchAssignments(courseId: course.id)
                for assignment in assignments {
                    allAssignments.append((course.cleanName, assignment))
                }
            }

            let now = Date()
            let upperBound = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
            let candidates = allAssignments
                .filter {
                    guard let due = $0.assignment.dueDateValue else { return false }
                    return due > now && due <= upperBound
                }
                .sorted {
                    ($0.assignment.dueDateValue ?? .distantFuture) < ($1.assignment.dueDateValue ?? .distantFuture)
                }
                .prefix(20)

            for item in candidates {
                guard let due = item.assignment.dueDateValue else { continue }
                let fireDate = due.addingTimeInterval(-24 * 60 * 60)
                guard fireDate > now else { continue }
                await addNotification(
                    identifier: "\(assignmentPrefix)\(item.assignment.id)",
                    title: "作業即將截止",
                    body: "\(item.assignment.name)（\(item.courseName)）將於 \(due.formatted(date: .abbreviated, time: .shortened)) 截止",
                    date: fireDate
                )
            }
        } catch {
            print("[Notification] 排程作業通知失敗: \(error.localizedDescription)")
        }
    }

    private func scheduleAcademicCalendarEvents() async {
        guard let url = Bundle.main.url(forResource: "academic_calendar", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(AcademicCalendarData.self, from: data) else {
            return
        }

        let semester = currentAcademicSemester()
        let calendar = parsed.calendar(for: semester) ?? parsed.calendars.first
        let events = calendar?.events ?? []
        let now = Date()
        let upperBound = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now

        let candidates = events
            .filter { event in
                let type = event.inferredType
                guard type == .important || type == .deadline else { return false }
                guard let start = event.start else { return false }
                return start >= now && start <= upperBound
            }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            .prefix(20)

        for event in candidates {
            guard let start = event.start else { continue }
            let fireDate = Calendar.current.date(byAdding: .day, value: -1, to: start) ?? start
            guard fireDate > now else { continue }
            await addNotification(
                identifier: "\(calendarPrefix)\(event.id)",
                title: "重要日期提醒",
                body: "\(event.title)（\(event.dateString)）即將到來",
                date: fireDate
            )
        }
    }

    private func scheduleClassReminders() async {
        guard let data = UserDefaults.standard.data(forKey: classScheduleCacheKey),
              let schedule = try? JSONDecoder().decode(ClassSchedule.self, from: data) else {
            return
        }

        let reminderMinutes = 10
        for (dayOffset, dayHeader) in schedule.dayHeaders.enumerated() {
            guard let weekday = weekdayIndex(from: dayHeader) else { continue }
            for period in schedule.periods {
                guard let course = period.course(for: dayOffset),
                      let start = period.startMinutes,
                      start >= reminderMinutes else { continue }

                let fireMinutes = start - reminderMinutes
                let hour = fireMinutes / 60
                let minute = fireMinutes % 60

                let room = course.classroom?.nilIfEmpty ?? "教室資訊未提供"
                let body = "\(course.name)（\(room)）將於 \(period.startTimeLabel) 上課"
                let courseToken = stableToken("\(course.name)-\(period.id)-\(dayOffset)")
                await addRepeatingNotification(
                    identifier: "\(classReminderPrefix)\(weekday).\(period.id).\(courseToken)",
                    title: "即將上課",
                    body: body,
                    weekday: weekday,
                    hour: hour,
                    minute: minute
                )
            }
        }
    }

    private func addNotification(identifier: String, title: String, body: String, date: Date) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await add(request: request)
        } catch {
            print("[Notification] 新增通知失敗 (\(identifier)): \(error.localizedDescription)")
        }
    }

    private func addRepeatingNotification(
        identifier: String,
        title: String,
        body: String,
        weekday: Int,
        hour: Int,
        minute: Int
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await add(request: request)
        } catch {
            print("[Notification] 新增重複課程通知失敗 (\(identifier)): \(error.localizedDescription)")
        }
    }

    private func weekdayIndex(from dayHeader: String) -> Int? {
        if dayHeader.contains("一") { return 2 }
        if dayHeader.contains("二") { return 3 }
        if dayHeader.contains("三") { return 4 }
        if dayHeader.contains("四") { return 5 }
        if dayHeader.contains("五") { return 6 }
        if dayHeader.contains("六") { return 7 }
        if dayHeader.contains("日") || dayHeader.contains("天") { return 1 }
        return nil
    }

    private func stableToken(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return String(scalars)
    }

    private func currentAcademicSemester() -> String {
        let now = Date()
        let calendar = Calendar.current
        let year = calendar.component(.year, from: now) - 1911
        let month = calendar.component(.month, from: now)
        if month >= 8 { return "\(year)-1" }
        if month >= 2 { return "\(year - 1)-2" }
        return "\(year - 1)-1"
    }

    private func currentNotificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func pendingRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private func add(request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

public extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Notification.Name {
    static let classScheduleDidUpdate = Notification.Name("classScheduleDidUpdate")
}

#if canImport(ActivityKit)
@available(iOS 16.1, *)
struct ClassLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let mode: String // "current" or "upcoming"
        let courseName: String
        let classroom: String
        let teacher: String
        let periodLabel: String
        let startDate: Date
        let endDate: Date
    }

    let token: String
}

@MainActor
final class ClassLiveActivityCoordinator {
    static let shared = ClassLiveActivityCoordinator()
    private let cacheKey = "classSchedule.v2.cachedData"
    private let appGroupIdentifier = "group.CHIEN.NIU-APP"
    private let stalePaddingMinutes = 20

    private init() {}

    func refreshFromScheduleCache(forceRebuild: Bool = false) async {
        guard #available(iOS 16.1, *) else { return }
        let now = Date()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAll()
            return
        }
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        guard let data = defaults.data(forKey: cacheKey),
              let schedule = try? JSONDecoder().decode(ClassSchedule.self, from: data),
              let snapshot = classSnapshot(from: schedule, now: now) else {
            await endAll()
            return
        }

        let state = ClassLiveActivityAttributes.ContentState(
            mode: snapshot.mode,
            courseName: snapshot.primary.courseName,
            classroom: snapshot.primary.classroom,
            teacher: snapshot.primary.teacher,
            periodLabel: snapshot.primary.periodLabel,
            startDate: snapshot.primary.start,
            endDate: snapshot.primary.end
        )

        let token = stableToken("class-live-activity")
        let attributes = ClassLiveActivityAttributes(token: token)
        let staleDate = calendarStaleDate(for: snapshot)
        let content = ActivityContent(state: state, staleDate: staleDate)

        if forceRebuild {
            await endAll()
        }

        let activities = Activity<ClassLiveActivityAttributes>.activities

        if activities.count > 1 {
            for activity in activities {
                let final = ActivityContent(state: activity.content.state, staleDate: Date())
                await activity.end(final, dismissalPolicy: .immediate)
            }

            do {
                _ = try Activity<ClassLiveActivityAttributes>.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            } catch {
                print("[LiveActivity] 重建失敗: \(error.localizedDescription)")
            }

            return
        }

        if let activity = activities.first {
            await activity.update(content)

            return
        }

        do {
            _ = try Activity<ClassLiveActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            print("[LiveActivity] 啟動失敗: \(error.localizedDescription)")
        }
    }

    func endAll() async {
        guard #available(iOS 16.1, *) else { return }
        for activity in Activity<ClassLiveActivityAttributes>.activities {
            let final = ActivityContent(state: activity.content.state, staleDate: Date())
            await activity.end(final, dismissalPolicy: .immediate)
        }
    }

    func nextRefreshDate(after now: Date = Date()) -> Date? {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        guard let data = defaults.data(forKey: cacheKey),
              let schedule = try? JSONDecoder().decode(ClassSchedule.self, from: data) else {
            return nil
        }

        let candidates = sessionsForDisplayDays(from: schedule, now: now)
            .sorted { $0.start < $1.start }

        for session in candidates {
            if now < session.start {
                return session.start
            }
            if session.start <= now && now < session.end {
                return session.end
            }
        }

        return nil
    }

    private typealias ClassSession = (courseName: String, classroom: String, teacher: String, periodLabel: String, start: Date, end: Date)

    private func classSnapshot(from schedule: ClassSchedule, now: Date) -> (mode: String, primary: ClassSession, next: ClassSession?)? {
        let candidates = sessionsForDisplayDays(from: schedule, now: now)
            .filter { $0.end > now }
            .sorted { $0.start < $1.start }

        guard !candidates.isEmpty else { return nil }

        if let current = candidates.first(where: { $0.start <= now && now < $0.end }) {
            let next = candidates.first(where: { $0.start >= current.end })
            return ("current", current, next)
        }

        let next = candidates[0]
        let following = candidates.count > 1 ? candidates[1] : nil
        return ("upcoming", next, following)
    }

    private func sessionsForDisplayDays(from schedule: ClassSchedule, now: Date) -> [ClassSession] {
        var candidates: [ClassSession] = []
        let calendar = Calendar.current
        let currentWeekday = calendar.component(.weekday, from: now)
        let startOfToday = calendar.startOfDay(for: now)
        let targetWeekdays: Set<Int> = {
            if currentWeekday == 7 || currentWeekday == 1 {
                // Weekend preview mode: read Monday + Tuesday classes.
                return [2, 3]
            }
            return [currentWeekday]
        }()

        for (offset, dayHeader) in schedule.dayHeaders.enumerated() {
            guard let weekday = weekdayIndex(from: dayHeader), targetWeekdays.contains(weekday) else { continue }
            for period in schedule.periods {
                guard let course = period.course(for: offset),
                      let startMins = period.startMinutes,
                      let endMins = period.endMinutes else { continue }

                let duration = endMins - startMins
                guard duration > 0 else { continue }

                let startDate: Date?
                if weekday == currentWeekday {
                    startDate = calendar.date(byAdding: .minute, value: startMins, to: startOfToday)
                } else {
                    startDate = nextDateForWeekday(weekday, minutes: startMins, from: now)
                }

                guard let startDate,
                      let endDate = calendar.date(byAdding: .minute, value: duration, to: startDate) else {
                    continue
                }

                let room = course.classroom?.nilIfEmpty ?? "教室待確認"
                let teacher = course.teacher?.nilIfEmpty ?? "授課教師待確認"
                let periodLabel = normalizedPeriodLabel(from: period.id)
                candidates.append((course.name, room, teacher, periodLabel, startDate, endDate))
            }
        }

        return candidates
    }

    private func nextDateForWeekday(_ weekday: Int, minutes: Int, from now: Date) -> Date? {
        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = minutes / 60
        comps.minute = minutes % 60

        return Calendar.current.nextDate(
            after: now,
            matching: comps,
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }

    private func weekdayIndex(from dayHeader: String) -> Int? {
        if dayHeader.contains("一") { return 2 }
        if dayHeader.contains("二") { return 3 }
        if dayHeader.contains("三") { return 4 }
        if dayHeader.contains("四") { return 5 }
        if dayHeader.contains("五") { return 6 }
        if dayHeader.contains("六") { return 7 }
        if dayHeader.contains("日") || dayHeader.contains("天") { return 1 }
        return nil
    }

    private func stableToken(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return String(scalars)
    }

    private func calendarStaleDate(for snapshot: (mode: String, primary: ClassSession, next: ClassSession?)) -> Date {
        let base = snapshot.mode == "current" ? snapshot.primary.end : snapshot.primary.start
        return Calendar.current.date(byAdding: .minute, value: stalePaddingMinutes, to: base) ?? base
    }

    private func normalizedPeriodLabel(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("第") && trimmed.hasSuffix("節") {
            return trimmed
        }
        if trimmed.hasSuffix("節") {
            return trimmed
        }
        return "第\(trimmed)節"
    }

}

@MainActor
final class ClassLiveActivityBackgroundRefreshCoordinator {
    static let shared = ClassLiveActivityBackgroundRefreshCoordinator()
    static let identifier = "CHIEN.NIU-APP.classLiveActivityRefresh"

    private let minimumDelay: TimeInterval = 60
    private let shortLeadTime: TimeInterval = 90
    private let mediumLeadTime: TimeInterval = 5 * 60
    private let longLeadTime: TimeInterval = 15 * 60
    private var hasRegistered = false

    private init() {}

    func register() {
        guard !hasRegistered else { return }

        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            Task { @MainActor in
                self.handle(task: task)
            }
        }

        hasRegistered = registered
        if !registered {
            print("[BGRefresh] 註冊失敗: \(Self.identifier)")
        }
    }

    func scheduleIfNeeded() {
        guard hasRegistered else { return }
        cancel()

        guard NotificationSettings.load().classLiveActivityEnabled else { return }
        guard hasAuthenticatedUser else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let transitionDate = ClassLiveActivityCoordinator.shared.nextRefreshDate() else { return }

        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = preferredBeginDate(for: transitionDate, now: Date())

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BGRefresh] 排程失敗: \(error.localizedDescription)")
        }
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
    }

    private func handle(task: BGAppRefreshTask) {
        scheduleIfNeeded()

        let refreshTask = Task { @MainActor in
            guard NotificationSettings.load().classLiveActivityEnabled, hasAuthenticatedUser else {
                task.setTaskCompleted(success: true)
                return
            }

            await ClassLiveActivityCoordinator.shared.refreshFromScheduleCache()
            scheduleIfNeeded()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            refreshTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private var hasAuthenticatedUser: Bool {
        guard let username = UserDefaults.standard.string(forKey: StorageKeys.username) else {
            return false
        }
        return !username.isEmpty
    }

    private func preferredBeginDate(for transitionDate: Date, now: Date) -> Date {
        let timeUntilTransition = transitionDate.timeIntervalSince(now)
        let leadTime = preferredLeadTime(for: timeUntilTransition)
        let targetDate = transitionDate.addingTimeInterval(-leadTime)
        return max(now.addingTimeInterval(minimumDelay), targetDate)
    }

    private func preferredLeadTime(for timeUntilTransition: TimeInterval) -> TimeInterval {
        switch timeUntilTransition {
        case ...(10 * 60):
            return shortLeadTime
        case ...(60 * 60):
            return mediumLeadTime
        default:
            return longLeadTime
        }
    }
}
#else
@MainActor
final class ClassLiveActivityCoordinator {
    static let shared = ClassLiveActivityCoordinator()
    private init() {}
    func refreshFromScheduleCache() async {}
    func endAll() async {}
    func nextRefreshDate(after now: Date = Date()) -> Date? { nil }
}

@MainActor
final class ClassLiveActivityBackgroundRefreshCoordinator {
    static let shared = ClassLiveActivityBackgroundRefreshCoordinator()
    static let identifier = "CHIEN.NIU-APP.classLiveActivityRefresh"

    private init() {}

    func register() {}
    func scheduleIfNeeded() {}
    func cancel() {}
}
#endif
