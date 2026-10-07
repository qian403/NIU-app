import SwiftUI
import Combine
import BackgroundTasks
import UserNotifications
import WebKit
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
final class AppState: ObservableObject {

    @Published var isAuthenticated: Bool = false
    @Published private(set) var isLoggingOut = false
    @Published var currentUser: User?
    @Published var notificationSettings = NotificationSettings.load()
    @Published private(set) var eventReminderStatus = "活動提醒尚未同步"

    /// `true` after the user explicitly presses the logout button.
    /// Used by LoginView to suppress automatic re-login.
    @Published private(set) var didExplicitlyLogout: Bool = false
    private var isRefreshingProfile = false
    private var lastNotificationForegroundRefresh: Date?
    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
            return
        }
        NotificationScheduler.shared.statusChanged = { [weak self] in self?.eventReminderStatus = $0 }
        observeClassScheduleUpdates()
        if UserDefaults.standard.bool(forKey: "app.logoutCleanupPending") {
            logout()
        } else {
            checkAuthenticationStatus()
        }
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func login(user: User) {
        guard !isLoggingOut else { return }
        EventFavoritesStore.shared.clear()
        NotificationScheduler.shared.invalidateSession()
        EventRegistrationClient.shared.reset()
        // A new login replaces the session, including any pending refresh/EUNI work.
        SSOSessionService.shared.disableAutoRefresh()
        MoodleSessionManager.shared.reset()
        MailViewModel.shared.reset()
        NativeMailViewModel.shared.reset()
        LiveActivityRemoteClient.shared.stop()
        UserDefaults.standard.set(UUID().uuidString, forKey: StorageKeys.authSessionID)
        let mergedUser = mergedWithPersistedProfile(user)
        currentUser = mergedUser
        isAuthenticated = true
        didExplicitlyLogout = false
        saveAuthState()
        SSOSessionService.shared.enableAutoRefresh()
        // Extract EUNI redirect link while SSO session is still alive
        MoodleSessionManager.shared.fetchEUNILink()
        print("[App] 使用者已登入")
        Task { await UsageHeartbeatClient.shared.report() }
        Task { await refreshNotificationSchedules() }
        
        if mergedUser.department?.nilIfEmpty == nil || mergedUser.grade?.nilIfEmpty == nil {
            Task { await refreshProfileIfNeeded(force: true) }
        }
    }

    func logout() {
        guard !isLoggingOut else { return }
        EventFavoritesStore.shared.clear()
        MailViewModel.shared.reset()
        NativeMailViewModel.shared.reset()
        LiveActivityRemoteClient.shared.disable()
        NotificationScheduler.shared.invalidateSession()
        isLoggingOut = true
        UserDefaults.standard.set(true, forKey: "app.logoutCleanupPending")
        currentUser = nil
        isAuthenticated = false
        didExplicitlyLogout = true
        clearAuthState()
        LoginRepository.shared.clearCredentials()
        SSOTokenStore.shared.clear()
        clearPersonalCaches()
        SSOSessionService.shared.disableAutoRefresh()
        MoodleSessionManager.shared.reset()
        MoodleService.shared.logout()
        EventRegistrationClient.shared.reset()
        ClassLiveActivityBackgroundRefreshCoordinator.shared.cancel()
        Task {
            await NotificationScheduler.shared.clearAllManagedNotifications()
            await ClassLiveActivityCoordinator.shared.endAll()
            // Keep the login screen unavailable until old web sessions are removed.
            await WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            URLCache.shared.removeAllCachedResponses()
            let files = FileManager.default.temporaryDirectory.appendingPathComponent("MoodleFiles")
            try? FileManager.default.removeItem(at: files)
            SSOTokenStore.shared.clear()
            clearPersonalCaches()
            UserDefaults.standard.removeObject(forKey: "app.logoutCleanupPending")
            isLoggingOut = false
        }
        print("[App] 使用者已登出")
    }

    private func clearPersonalCaches() {
        let prefixes = ["grade_history.", "graduationThreshold.", "classSchedule."]
        for defaults in [UserDefaults.standard, UserDefaults(suiteName: "group.dev.chien.niuapp")] {
            guard let defaults else { continue }
            for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: key.hasPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: "app.installationID")
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func checkAuthenticationStatus() {
        if let savedUsername = UserDefaults.standard.string(forKey: StorageKeys.username),
           let savedName = UserDefaults.standard.string(forKey: StorageKeys.name),
           !savedUsername.isEmpty {
            if UserDefaults.standard.string(forKey: StorageKeys.authSessionID) == nil {
                UserDefaults.standard.set(UUID().uuidString, forKey: StorageKeys.authSessionID)
            }
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
            Task { await UsageHeartbeatClient.shared.report() }
            // Try to fetch EUNI link if we don't have one yet
            if SSOEUNISettings.shared.euniFullURL == nil {
                MoodleSessionManager.shared.fetchEUNILink()
            }
            Task { await refreshNotificationSchedules() }
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
        UserDefaults.standard.removeObject(forKey: StorageKeys.authSessionID)
        UserDefaults.standard.removeObject(forKey: StorageKeys.username)
        UserDefaults.standard.removeObject(forKey: StorageKeys.name)
        UserDefaults.standard.removeObject(forKey: StorageKeys.department)
        UserDefaults.standard.removeObject(forKey: StorageKeys.grade)
        UserDefaults.standard.removeObject(forKey: StorageKeys.loginTime)
    }

    private func mergedWithPersistedProfile(_ user: User) -> User {
        let sameAccount = UserDefaults.standard.string(forKey: StorageKeys.username)?.lowercased() == user.username.lowercased()
        let savedDepartment = sameAccount ? UserDefaults.standard.string(forKey: StorageKeys.department)?.nilIfEmpty : nil
        let savedGrade = sameAccount ? UserDefaults.standard.string(forKey: StorageKeys.grade)?.nilIfEmpty : nil
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

    func setEventRemindersEnabled(_ enabled: Bool) async {
        notificationSettings.eventReminderEnabled = enabled
        notificationSettings.save()
        if enabled { _ = await NotificationScheduler.shared.requestAuthorizationIfNeeded() }
        await refreshNotificationSchedules()
    }

    func setEventReminderLeadTime(_ lead: EventReminderLeadTime) async {
        notificationSettings.eventReminderLeadTime = lead
        notificationSettings.save()
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
        guard isAuthenticated, let session = UserDefaults.standard.string(forKey: StorageKeys.authSessionID) else { return }
        await refreshClassLiveActivitiesIfNeeded()
        guard isAuthenticated, UserDefaults.standard.string(forKey: StorageKeys.authSessionID) == session else { return }
        ClassLiveActivityBackgroundRefreshCoordinator.shared.scheduleIfNeeded()
        let credentials = LoginRepository.shared.getSavedCredentials()
        await NotificationScheduler.shared.scheduleAll(
            settings: notificationSettings,
            username: credentials?.username ?? "",
            password: credentials?.password ?? ""
        )
    }

    func setRemoteLiveActivityEnabled(_ enabled: Bool) async {
        if enabled {
            UserDefaults.standard.set(true, forKey: LiveActivityRemoteClient.consentKey)
        } else {
            LiveActivityRemoteClient.shared.disable()
        }
        await refreshClassLiveActivitiesIfNeeded(forceRebuild: true)
    }

    func applicationDidBecomeActive() async {
        notificationSettings = NotificationSettings.load()
        LiveActivityRemoteClient.shared.retryCleanup()
        if isAuthenticated {
            Task { await UsageHeartbeatClient.shared.report() }
        }
        ClassLiveActivityCoordinator.shared.setForeground(true)
        await refreshClassLiveActivitiesIfNeeded()
        ClassLiveActivityBackgroundRefreshCoordinator.shared.scheduleIfNeeded()
        if lastNotificationForegroundRefresh.map({ Date().timeIntervalSince($0) >= 300 }) ?? true {
            lastNotificationForegroundRefresh = Date()
            await refreshNotificationSchedules()
        }
    }

    func applicationDidEnterBackground() {
        ClassLiveActivityCoordinator.shared.setForeground(false)
        ClassLiveActivityBackgroundRefreshCoordinator.shared.scheduleIfNeeded()
    }


    private func observeClassScheduleUpdates() {
        let settingsObserver = NotificationCenter.default.addObserver(
            forName: .classLiveActivitySettingDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.notificationSettings = NotificationSettings.load()
            }
        }
        notificationObservers.append(settingsObserver)
        let observer = NotificationCenter.default.addObserver(
            forName: .classScheduleDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.refreshNotificationSchedules()
            }
        }
        notificationObservers.append(observer)
        for name in [Notification.Name.didChangeEventRegistration,
                     Notification.Name.didConfirmEventCancellation,
                     Notification.Name("didChangeEventRegistrationSession")] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                // Both notifications are published by the MainActor activity client/view models.
                MainActor.assumeIsolated {
                    if notification.name.rawValue == "didChangeEventRegistrationSession" {
                        NotificationScheduler.shared.invalidateSession()
                    }
                    if notification.name == .didConfirmEventCancellation,
                       notification.userInfo?["session"] as? UUID == EventRegistrationClient.shared.sessionRevision,
                       let id = notification.userInfo?["eventID"] as? String {
                        NotificationScheduler.shared.removeConfirmedEvent(id)
                        return // The following didChangeEventRegistration starts the refresh.
                    }
                    guard let self, self.isAuthenticated, !self.isLoggingOut else { return }
                    Task { await self.refreshNotificationSchedules() }
                }
            }
            notificationObservers.append(observer)
        }
    }

    private func refreshClassLiveActivitiesIfNeeded(forceRebuild: Bool = false) async {
        guard isAuthenticated else { return }
        guard notificationSettings.classLiveActivityEnabled else { return }
        await ClassLiveActivityCoordinator.shared.refreshFromScheduleCache(forceRebuild: forceRebuild)
    }


}

enum StorageKeys {
    static let authSessionID = "app.auth.sessionID"
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
    var eventReminderEnabled: Bool = false
    var eventReminderLeadTime: EventReminderLeadTime = .oneDay

    static func load(defaults: UserDefaults = .standard) -> NotificationSettings {
        return NotificationSettings(
            assignmentDeadlineEnabled: defaults.object(forKey: NotificationKeys.assignmentDeadlineEnabled) as? Bool ?? false,
            academicCalendarEnabled: defaults.object(forKey: NotificationKeys.academicCalendarEnabled) as? Bool ?? false,
            classReminderEnabled: defaults.object(forKey: NotificationKeys.classReminderEnabled) as? Bool ?? false,
            classLiveActivityEnabled: defaults.object(forKey: NotificationKeys.classLiveActivityEnabled) as? Bool ?? false,
            eventReminderEnabled: defaults.object(forKey: NotificationKeys.eventReminderEnabled) as? Bool ?? false,
            eventReminderLeadTime: EventReminderLeadTime(rawValue: defaults.integer(forKey: NotificationKeys.eventReminderLeadTime)) ?? .oneDay
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(assignmentDeadlineEnabled, forKey: NotificationKeys.assignmentDeadlineEnabled)
        defaults.set(academicCalendarEnabled, forKey: NotificationKeys.academicCalendarEnabled)
        defaults.set(classReminderEnabled, forKey: NotificationKeys.classReminderEnabled)
        defaults.set(classLiveActivityEnabled, forKey: NotificationKeys.classLiveActivityEnabled)
        defaults.set(eventReminderEnabled, forKey: NotificationKeys.eventReminderEnabled)
        defaults.set(eventReminderLeadTime.rawValue, forKey: NotificationKeys.eventReminderLeadTime)
    }

    static func setClassLiveActivityEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: NotificationKeys.classLiveActivityEnabled)
        NotificationCenter.default.post(name: .classLiveActivitySettingDidChange, object: nil)
    }
}

private enum NotificationKeys {
    static let eventReminderEnabled = "app.notification.eventReminderEnabled"
    static let eventReminderLeadTime = "app.notification.eventReminderLeadTime"
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
    var statusChanged: (String) -> Void = { _ in }
    private lazy var reconciler: EventReminderScheduler = {
        let scheduler = EventReminderScheduler(center: SystemReminderNotificationCenter(), session: {
            UserDefaults.standard.string(forKey: StorageKeys.authSessionID)
        }, loadCache: {
            UserDefaults.standard.data(forKey: "app.notification.eventCache")
        }, saveCache: { data in
            UserDefaults.standard.set(data, forKey: "app.notification.eventCache")
        }, events: {
            try await EventRegistrationClient.shared.appliedEvents().map {
                EventReminderRecord(id: $0.eventSerialID, title: $0.name, eventTime: $0.eventTime,
                                    registrationState: $0.state, eventState: $0.event_state)
            }
        })
        scheduler.statusChanged = { [weak self] in self?.statusChanged($0) }
        return scheduler
    }()

    private init() {}

    // Authorization prompts are only reached by an explicit user toggle, never automatic synchronization.
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default: return false
        }
    }

    func invalidateSession() { reconciler.invalidateSession() }

    func removeConfirmedEvent(_ id: String) { reconciler.removeConfirmedEvent(id) }

    func clearAllManagedNotifications() async {
        reconciler.invalidateSession()
        await reconciler.waitForIdle()
        center.removeAllDeliveredNotifications()
    }

    func scheduleAll(settings: NotificationSettings, username: String, password: String) async {
        var enabled = Set<ManagedNotificationCategory>()
        if settings.eventReminderEnabled { enabled.insert(.event) }
        if settings.assignmentDeadlineEnabled { enabled.insert(.assignment) }
        if settings.academicCalendarEnabled { enabled.insert(.calendar) }
        if settings.classReminderEnabled { enabled.insert(.class) }
        await reconciler.refresh(enabled: enabled, lead: settings.eventReminderLeadTime, sources: [
            .assignment: { try await self.scheduleAssignmentDeadlines(username: username, password: password) },
            .calendar: { try await self.scheduleAcademicCalendarEvents() },
            .class: { try self.scheduleClassReminders() }
        ])
    }

    private func scheduleAssignmentDeadlines(username: String, password: String) async throws -> [ManagedNotification] {
        var result: [ManagedNotification] = []
        guard !username.isEmpty, !password.isEmpty else { throw URLError(.userAuthenticationRequired) }
        if !MoodleService.shared.isAuthenticated {
            try await MoodleService.shared.authenticate(username: username, password: password)
        }
        try Task.checkCancellation()
        let courses = try await MoodleService.shared.fetchCourses()
        var allAssignments: [(courseName: String, assignment: MoodleAssignment)] = []
        for course in courses {
            try Task.checkCancellation()
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
            result.append(ManagedNotification(
                id: "\(assignmentPrefix)\(item.assignment.id)", category: .assignment,
                title: "作業即將截止",
                body: "\(item.assignment.name)（\(item.courseName)）將於 \(due.formatted(date: .abbreviated, time: .shortened)) 截止",
                fireDate: fireDate
            ))
        }
        return result
    }

    private func scheduleAcademicCalendarEvents() async throws -> [ManagedNotification] {
        let pending = await SystemReminderNotificationCenter(center: center).pending()
        try Task.checkCancellation()
        return try await CalendarNotificationSource.load(now: Date(), existing: pending,
            owner: UserDefaults.standard.string(forKey: StorageKeys.authSessionID)) { year, now in
                await AcademicCalendarStore.shared.refresh(year: year, now: now).document
            }
    }

    private func scheduleClassReminders() throws -> [ManagedNotification] {
        var result: [ManagedNotification] = []
        guard let data = UserDefaults.standard.data(forKey: classScheduleCacheKey),
              let schedule = try? JSONDecoder().decode(ClassSchedule.self, from: data),
              schedule.ownerSessionID == UserDefaults.standard.string(forKey: StorageKeys.authSessionID) else {
            throw URLError(.cannotDecodeContentData)
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
                let parts = DateComponents(hour: hour, minute: minute, weekday: weekday)
                guard let fireDate = EventReminderDate.calendar.nextDate(after: Date(), matching: parts, matchingPolicy: .strict) else { continue }
                result.append(ManagedNotification(
                    id: "\(classReminderPrefix)\(weekday).\(period.id).\(courseToken)", category: .class,
                    title: "即將上課",
                    body: body,
                    fireDate: fireDate, weekday: weekday
                ))
            }
        }
        return result
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


}

/// Successful academic years replace only their own reminders; unavailable years retain valid same-session requests.
@MainActor
enum CalendarNotificationSource {
    static func load(now: Date, existing: [PendingManagedNotification], owner: String?,
                     document: (Int, Date) async -> CampusCalendarDocument?) async throws -> [ManagedNotification] {
        let year = CampusCalendarDate.academicYear(at: now)
        let upperBound = CampusCalendarDate.calendar.date(byAdding: .day, value: 30, to: now) ?? now
        let upperYear = CampusCalendarDate.academicYear(at: upperBound)
        var events: [CalendarEvent] = []
        var resultRequests: [ManagedNotification] = []
        var loadedAny = false
        for requestedYear in Set([year, upperYear]).sorted() {
            let value = await document(requestedYear, now)
            try Task.checkCancellation()
            if let value {
                loadedAny = true
                events += value.events.map { CalendarEvent($0, document: value) }
            } else if let owner {
                resultRequests += existing.compactMap { request in
                    guard request.session == owner, let value = request.value,
                          value.category == .calendar, value.fireDate > now,
                          let eventDay = CampusCalendarDate.calendar.date(byAdding: .day, value: 1, to: value.fireDate),
                          CampusCalendarDate.academicYear(at: eventDay) == requestedYear else { return nil }
                    return value
                }
            }
        }
        guard loadedAny else { throw URLError(.cannotParseResponse) }
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
            try Task.checkCancellation()
            guard let start = event.start else { continue }
            let previousDay = CampusCalendarDate.calendar.date(byAdding: .day, value: -1, to: start) ?? start
            let fireDate = CampusCalendarDate.calendar.date(bySettingHour: 8, minute: 0, second: 0, of: previousDay) ?? previousDay
            guard fireDate > now else { continue }
            resultRequests.append(ManagedNotification(
                id: "notify.calendar.\(event.id)", category: .calendar,
                title: "重要日期提醒",
                body: "\(event.title)（\(event.dateString)）即將到來",
                fireDate: fireDate
            ))
        }
        return resultRequests
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
@MainActor
final class ClassLiveActivityCoordinator {
    static let shared = ClassLiveActivityCoordinator()
    enum RefreshResult {
        case updated, outsideDisplayWindow, noSchedule, notAuthorized, disabled
        case notAuthenticated, superseded, failed
    }
    private var boundaryTask: Task<Void, Never>?
    private var foreground = false
    private var refreshGeneration = 0
    private var shortcutRefreshGeneration: Int?
    private var refreshAfterShortcut = false

    private init() {}

    @discardableResult
    func refreshFromScheduleCache(
        forceRebuild: Bool = false,
        enableIfNeeded: Bool = false,
        shortcutRequest: Bool = false
    ) async -> RefreshResult {
        guard !Task.isCancelled else { return .superseded }
        if !shortcutRequest && !forceRebuild && shortcutRefreshGeneration != nil {
            refreshAfterShortcut = true
            return .superseded
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if shortcutRequest { shortcutRefreshGeneration = generation }
        if forceRebuild && !shortcutRequest {
            shortcutRefreshGeneration = nil
            refreshAfterShortcut = false
        }
        defer {
            if shortcutRefreshGeneration == generation {
                shortcutRefreshGeneration = nil
                if refreshAfterShortcut {
                    refreshAfterShortcut = false
                    Task { await self.refreshFromScheduleCache() }
                }
            }
            if generation == refreshGeneration, !Task.isCancelled { scheduleBoundary() }
        }
        guard enableIfNeeded || NotificationSettings.load().classLiveActivityEnabled else {
            await endAll()
            return .disabled
        }
        guard let username = UserDefaults.standard.string(forKey: StorageKeys.username), !username.isEmpty,
              !UserDefaults.standard.bool(forKey: "app.logoutCleanupPending"),
              let sessionID = UserDefaults.standard.string(forKey: StorageKeys.authSessionID) else {
            await endAll()
            return .notAuthenticated
        }
        let now = Date()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAll()
            return .notAuthorized
        }
        let cached = await Task.detached(priority: .userInitiated) {
            ClassScheduleCache.load(sessionID: sessionID, now: now)
        }.value
        guard isCurrentRefresh(generation, sessionID: sessionID, requireEnabled: !enableIfNeeded) else { return .superseded }
        guard let cached else {
            await endAll()
            return .noSchedule
        }
        if enableIfNeeded {
            NotificationSettings.setClassLiveActivityEnabled(true)
        }
        guard let snapshot = classSnapshot(from: cached, now: now) else {
            // Keep this refresh current so the foreground timer can reach the first class window.
            LiveActivityRemoteClient.shared.stop()
            await endActivities(generation: generation)
            guard isCurrentRefresh(generation, sessionID: sessionID) else { return .superseded }
            return .outsideDisplayWindow
        }

        let primary = snapshot.primary.session
        let state = ClassLiveActivityAttributes.ContentState(
            mode: snapshot.mode,
            courseName: primary.courseName,
            classroom: primary.classroom,
            teacher: primary.teacher,
            periodLabel: primary.periodLabel,
            startDate: primary.start,
            endDate: primary.end,
            periodStartDates: snapshot.primary.periods.count > 1 ? snapshot.primary.periods.map(\.lowerBound) : nil,
            periodEndDates: snapshot.primary.periods.count > 1 ? snapshot.primary.periods.map(\.upperBound) : nil
        )

        let attributes = ClassLiveActivityAttributes(startedAt: now, token: sessionID)
        let staleDate = calendarStaleDate(for: snapshot)
        let content = ActivityContent(state: state, staleDate: staleDate)

        if forceRebuild || Activity<ClassLiveActivityAttributes>.activities.contains(where: { $0.attributes.token != sessionID }) {
            LiveActivityRemoteClient.shared.stop()
            await endActivities(generation: generation)
            guard isCurrentRefresh(generation, sessionID: sessionID) else { return .superseded }
        }

        let activities = Activity<ClassLiveActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }

        if activities.count > 1 {
            for activity in activities {
                let final = ActivityContent(state: activity.content.state, staleDate: Date())
                await activity.end(final, dismissalPolicy: .immediate)
                guard isCurrentRefresh(generation, sessionID: sessionID) else { return .superseded }
            }
            do {
                let activity = try Activity<ClassLiveActivityAttributes>.request(
                    attributes: attributes,
                    content: content,
                    pushType: LiveActivityRemoteClient.enabled ? .token : nil
                )
                LiveActivityRemoteClient.shared.observe(activity)
                return .updated
            } catch {
                print("[LiveActivity] 重建失敗: \(error.localizedDescription)")
                return .failed
            }
        }

        if let activity = activities.first {
            await activity.update(content)
            guard isCurrentRefresh(generation, sessionID: sessionID) else { return .superseded }
            guard activity.activityState == .active || activity.activityState == .stale else { return .failed }
            LiveActivityRemoteClient.shared.observe(activity)
            return .updated
        }

        do {
            let activity = try Activity<ClassLiveActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: LiveActivityRemoteClient.enabled ? .token : nil
            )
            LiveActivityRemoteClient.shared.observe(activity)
            return .updated
        } catch {
            print("[LiveActivity] 啟動失敗: \(error.localizedDescription)")
            return .failed
        }
    }

    func endAll() async {
        boundaryTask?.cancel()
        boundaryTask = nil
        LiveActivityRemoteClient.shared.stop()
        refreshGeneration &+= 1
        shortcutRefreshGeneration = nil
        refreshAfterShortcut = false
        await endActivities(generation: refreshGeneration)
    }

    private func isCurrentRefresh(_ generation: Int, sessionID: String, requireEnabled: Bool = true) -> Bool {
        !Task.isCancelled && generation == refreshGeneration &&
            UserDefaults.standard.string(forKey: StorageKeys.authSessionID) == sessionID &&
            !UserDefaults.standard.bool(forKey: "app.logoutCleanupPending") &&
            (!requireEnabled || NotificationSettings.load().classLiveActivityEnabled)
    }

    private func endActivities(generation: Int) async {
        for activity in Activity<ClassLiveActivityAttributes>.activities {
            guard generation == refreshGeneration else { return }
            let final = ActivityContent(state: activity.content.state, staleDate: Date())
            await activity.end(final, dismissalPolicy: .immediate)
        }
    }

    func nextRefreshDate(after now: Date = Date()) -> Date? {
        guard let sessionID = UserDefaults.standard.string(forKey: StorageKeys.authSessionID),
              let base = ClassScheduleCache.loadBase(sessionID: sessionID) else { return nil }
        let schedule = base.schedule.merging(base.customCourses, weekContaining: now)
        let candidates = sessionsForDisplayDays(from: schedule, now: now)

        if let windowStart = displayWindowStart(for: candidates), now < windowStart {
            return windowStart
        }

        for session in candidates {
            if now < session.start {
                return session.start
            }
            if session.start <= now && now < session.end {
                return session.end
            }
        }

        // The stored timetable repeats weekly; find the next day's first display window.
        let calendar = ScheduleClock.calendar
        for offset in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let firstClass = sessionsForDisplayDays(
                    from: base.schedule.merging(base.customCourses, weekContaining: day), now: day
                  ).min(by: { $0.start < $1.start })
            else { continue }
            let displayStart = firstClass.start.addingTimeInterval(-Self.displayLeadTime)
            return max(calendar.startOfDay(for: day), displayStart)
        }

        return nil
    }

    private typealias ClassSession = ScheduleSession

    /// The activity appears 30 minutes before the day's first class rather than
    /// right after midnight, which also keeps the ~8h activity lifetime for the
    /// classes themselves instead of spending it on the early morning.
    private static let displayLeadTime: TimeInterval = 30 * 60

    private func displayWindowStart(for daySessions: [ClassSession]) -> Date? {
        daySessions.map(\.start).min()?.addingTimeInterval(-Self.displayLeadTime)
    }

    private func classSnapshot(from schedule: ClassSchedule, now: Date) -> (mode: String, primary: ScheduleBlock, next: ScheduleBlock?)? {
        let daySessions = schedule.sessions(on: now).mergedConsecutiveCourses()
        if let windowStart = displayWindowStart(for: daySessions.map(\.session)), now < windowStart { return nil }

        let candidates = daySessions
            .filter { $0.session.end > now }

        guard !candidates.isEmpty else { return nil }

        if let current = candidates.first(where: { $0.session.start <= now && now < $0.session.end }) {
            let next = candidates.first(where: { $0.session.start >= current.session.end })
            return ("current", current, next)
        }

        let next = candidates[0]
        let following = candidates.count > 1 ? candidates[1] : nil
        return ("upcoming", next, following)
    }

    /// Consecutive periods of one course share a single activity, so they also
    /// share one refresh boundary instead of waking at every period break.
    private func sessionsForDisplayDays(from schedule: ClassSchedule, now: Date) -> [ClassSession] {
        schedule.sessions(on: now).mergedConsecutiveCourses().map(\.session)
    }

    func setForeground(_ active: Bool) {
        foreground = active
        boundaryTask?.cancel()
        boundaryTask = nil
        if active { scheduleBoundary() }
    }

    private func scheduleBoundary() {
        boundaryTask?.cancel()
        guard foreground, let next = nextRefreshDate() else { return }
        let delay = max(0.1, next.timeIntervalSinceNow)
        boundaryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self,
                  NotificationSettings.load().classLiveActivityEnabled,
                  UserDefaults.standard.string(forKey: StorageKeys.username) != nil else { return }
            await self.refreshFromScheduleCache()
        }
    }

    private func stableToken(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return String(scalars)
    }

    private func calendarStaleDate(for snapshot: (mode: String, primary: ScheduleBlock, next: ScheduleBlock?)) -> Date {
        let base = snapshot.mode == "current" ? snapshot.primary.session.end : snapshot.primary.session.start
        return base
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

        let completion = ClassActivityRefreshCompletion(task)
        let refreshTask = Task { @MainActor in
            defer { completion.finish(success: !Task.isCancelled) }
            guard !Task.isCancelled, NotificationSettings.load().classLiveActivityEnabled, hasAuthenticatedUser else { return }
            await ClassLiveActivityCoordinator.shared.refreshFromScheduleCache()
            guard !Task.isCancelled else { return }
            scheduleIfNeeded()
        }
        task.expirationHandler = {
            refreshTask.cancel()
            Task { @MainActor in completion.finish(success: false) }
        }
    }

    private var hasAuthenticatedUser: Bool {
        guard let username = UserDefaults.standard.string(forKey: StorageKeys.username) else {
            return false
        }
        return !username.isEmpty
    }

    private func preferredBeginDate(for transitionDate: Date, now: Date) -> Date {
        return max(now.addingTimeInterval(minimumDelay), transitionDate)
    }

}

@MainActor
private final class ClassActivityRefreshCompletion {
    private let task: BGAppRefreshTask
    private var completed = false
    init(_ task: BGAppRefreshTask) { self.task = task }
    func finish(success: Bool) {
        guard !completed else { return }
        completed = true
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
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
