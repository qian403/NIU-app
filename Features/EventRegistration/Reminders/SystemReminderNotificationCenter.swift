import Foundation
import UserNotifications

@MainActor
final class SystemReminderNotificationCenter: ReminderNotificationCenter {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
    }

    func pending() async -> [PendingManagedNotification] {
        await center.pendingNotificationRequests().map { request in
            let data = request.content.userInfo["managedNotification"] as? Data
            var value = data.flatMap { try? JSONDecoder().decode(ManagedNotification.self, from: $0) }
            if let stored = value, stored.weekday != nil, let next = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() {
                value = ManagedNotification(id: stored.id, category: stored.category, title: stored.title,
                                            body: stored.body, fireDate: next, weekday: stored.weekday)
            }
            return PendingManagedNotification(id: request.identifier,
                session: request.content.userInfo["authSession"] as? String, value: value)
        }
    }

    func add(_ value: ManagedNotification, session: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = value.title; content.body = value.body; content.sound = .default
        content.userInfo = ["authSession": session, "managedNotification": try JSONEncoder().encode(value)]
        var parts = EventReminderDate.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value.fireDate)
        if let weekday = value.weekday {
            parts = EventReminderDate.calendar.dateComponents([.hour, .minute], from: value.fireDate)
            parts.weekday = weekday
        }
        parts.calendar = EventReminderDate.calendar
        parts.timeZone = EventReminderDate.calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: value.weekday != nil)
        try await center.add(UNNotificationRequest(identifier: value.id, content: content, trigger: trigger))
    }

    func remove(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(_ ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
}
