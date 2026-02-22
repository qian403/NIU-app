import SwiftUI
import Combine
import UserNotifications

@MainActor
final class AppState: ObservableObject {

    @Published var isAuthenticated: Bool = false
    @Published var currentUser: User?
    @Published var notificationSettings = NotificationSettings.load()

    /// `true` after the user explicitly presses the logout button.
    /// Used by LoginView to suppress automatic re-login.
    @Published private(set) var didExplicitlyLogout: Bool = false
    private var isRefreshingProfile = false

    init() {
        checkAuthenticationStatus()
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

    func refreshNotificationSchedules() async {
        guard isAuthenticated else { return }
        guard let credentials = LoginRepository.shared.getSavedCredentials() else { return }
        await NotificationScheduler.shared.scheduleAll(
            settings: notificationSettings,
            username: credentials.username,
            password: credentials.password
        )
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

    static func load() -> NotificationSettings {
        let defaults = UserDefaults.standard
        return NotificationSettings(
            assignmentDeadlineEnabled: defaults.object(forKey: NotificationKeys.assignmentDeadlineEnabled) as? Bool ?? false,
            academicCalendarEnabled: defaults.object(forKey: NotificationKeys.academicCalendarEnabled) as? Bool ?? false
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(assignmentDeadlineEnabled, forKey: NotificationKeys.assignmentDeadlineEnabled)
        defaults.set(academicCalendarEnabled, forKey: NotificationKeys.academicCalendarEnabled)
    }
}

private enum NotificationKeys {
    static let assignmentDeadlineEnabled = "app.notification.assignmentDeadlineEnabled"
    static let academicCalendarEnabled = "app.notification.academicCalendarEnabled"
}

@MainActor
private final class NotificationScheduler {
    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()
    private let assignmentPrefix = "notify.assignment."
    private let calendarPrefix = "notify.calendar."

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
                .filter { $0.hasPrefix(assignmentPrefix) || $0.hasPrefix(calendarPrefix) }
            guard !ids.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func scheduleAll(settings: NotificationSettings, username: String, password: String) async {
        await clear(byPrefix: assignmentPrefix)
        await clear(byPrefix: calendarPrefix)

        guard settings.assignmentDeadlineEnabled || settings.academicCalendarEnabled else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        if settings.assignmentDeadlineEnabled {
            await scheduleAssignmentDeadlines(username: username, password: password)
        }
        if settings.academicCalendarEnabled {
            await scheduleAcademicCalendarEvents()
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

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
