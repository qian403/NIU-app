import Foundation

enum EventReminderLeadTime: Int, CaseIterable, Codable, Identifiable {
    case oneDay = 1440, oneHour = 60, thirtyMinutes = 30
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .oneDay: return "1 天"
        case .oneHour: return "1 小時"
        case .thirtyMinutes: return "30 分鐘"
        }
    }
}

/// The school scraper may remove all whitespace between the date and time.
/// A complete Gregorian date AND explicit clock time are required; no midnight fallback.
enum EventReminderDate {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .gmt
        return value
    }

    static func start(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(\d{4})[/-](\d{1,2})[/-](\d{1,2})\s*(?:(上午|下午)\s*(\d{1,2})|(\d{2})):(\d{2})(?::(\d{2}))?(?=\s*(?:起|[~～]|$))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func number(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }
        guard let year = number(1), (1912...9999).contains(year), let month = number(2),
              let day = number(3), let sourceHour = number(5) ?? number(6), let minute = number(7) else { return nil }
        let second = number(8) ?? 0
        var hour = sourceHour
        if let markerRange = Range(match.range(at: 4), in: text) {
            guard (1...12).contains(sourceHour) else { return nil }
            hour = sourceHour % 12 + (text[markerRange] == "下午" ? 12 : 0)
        }
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...59).contains(second) else { return nil }
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: parts) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual == parts else { return nil }
        return date
    }
}

struct EventReminderRecord: Codable {
    let id: String
    let title: String
    let eventTime: String
    let registrationState: String
    let eventState: String

    var isRegistered: Bool {
        // The source is the applied list; explicitly cancelled, rejected or waitlisted rows are not registrations.
        ["已報名", "報名成功", "正取", "錄取"].contains(registrationState.trimmingCharacters(in: .whitespacesAndNewlines))
            && !["取消", "停辦"].contains(where: eventState.contains)
    }
}

enum ManagedNotificationCategory: String, Codable, CaseIterable {
    case event, assignment, calendar, `class`
    var prefix: String { "notify.\(rawValue)." }
    var priority: Int {
        switch self {
        case .event: return 0
        case .assignment: return 1
        case .calendar: return 2
        case .class: return 3
        }
    }
    static func category(of id: String) -> Self? { allCases.first { id.hasPrefix($0.prefix) } }
}

struct ManagedNotification: Codable, Equatable {
    let id: String
    let category: ManagedNotificationCategory
    let title: String
    let body: String
    let fireDate: Date
    var weekday: Int? = nil
}

struct PendingManagedNotification {
    let id: String
    let session: String?
    let value: ManagedNotification?
}

@MainActor
protocol ReminderNotificationCenter: AnyObject {
    func isAuthorized() async -> Bool
    func pending() async -> [PendingManagedNotification]
    func add(_ value: ManagedNotification, session: String) async throws
    func remove(_ ids: [String])
    func removeDelivered(_ ids: [String])
}

/// One global policy for all local notifications, leaving four of iOS's 64 slots free.
/// Existing unmanaged requests consume this budget too. Events have first priority;
/// within a category use the earliest trigger, then a stable ID for deterministic ties.
enum NotificationBudget {
    static let limit = 60
    static func select(_ values: [ManagedNotification], unmanagedCount: Int, now: Date) -> [ManagedNotification] {
        var seen = Set<String>()
        return Array(values.filter { ($0.weekday != nil || $0.fireDate > now) && seen.insert($0.id).inserted }
            .sorted {
                if $0.category.priority != $1.category.priority { return $0.category.priority < $1.category.priority }
                if $0.fireDate != $1.fireDate { return $0.fireDate < $1.fireDate }
                return $0.id < $1.id
            }.prefix(max(0, limit - unmanagedCount)))
    }
}

/// Injected center, source, session, clock and cache make every path testable without credentials or real notifications.
/// Mutations are serialized. Every suspension is fenced by generation + session, including center.add completion.
@MainActor
final class EventReminderScheduler {
    typealias Source = @MainActor () async throws -> [ManagedNotification]
    private struct Cache: Codable { let session: String; let records: [EventReminderRecord] }
    private let center: ReminderNotificationCenter
    private let session: () -> String?
    private let now: () -> Date
    private let loadCache: () -> Data?
    private let saveCache: (Data?) -> Void
    private let events: @MainActor () async throws -> [EventReminderRecord]
    private var generation = UUID()
    private var needsSessionCleanup = false
    private var task: Task<Void, Never>?
    var statusChanged: (String) -> Void = { _ in }

    init(center: ReminderNotificationCenter, session: @escaping () -> String?, now: @escaping () -> Date = Date.init,
         loadCache: @escaping () -> Data?, saveCache: @escaping (Data?) -> Void,
         events: @escaping @MainActor () async throws -> [EventReminderRecord]) {
        self.center = center; self.session = session; self.now = now
        self.loadCache = loadCache; self.saveCache = saveCache; self.events = events
    }

    /// Synchronous invalidation is essential: call BEFORE replacing login state or awaiting logout cleanup.
    func invalidateSession() {
        generation = UUID()
        needsSessionCleanup = true
        task?.cancel()
        saveCache(nil)
        statusChanged("尚未安排活動提醒")
        let previous = task
        let token = generation
        task = Task {
            // Remove already-pending notifications promptly, even if the old source ignores cancellation.
            let pending = await center.pending()
            if token == generation {
                let ids = pending.map(\.id).filter { ManagedNotificationCategory.category(of: $0) != nil }
                center.remove(ids)
                center.removeDelivered(ids)
                needsSessionCleanup = false
            }
            // Keep this mutation barrier even if a new refresh supersedes the cleanup.
            // A late add is removed by the old task before the new task can reuse its ID.
            await previous?.value
        }
    }

    func waitForIdle() async { await task?.value }

    func refresh(enabled: Set<ManagedNotificationCategory>, lead: EventReminderLeadTime,
                 sources: [ManagedNotificationCategory: Source] = [:]) async {
        generation = UUID()
        let token = generation
        task?.cancel()
        let previous = task
        let owner = session()
        let next = Task {
            await previous?.value
            guard valid(token, owner) else { return }
            await reconcile(enabled: enabled, lead: lead, sources: sources, token: token, owner: owner)
        }
        task = next
        await next.value
    }

    private func valid(_ token: UUID, _ owner: String?) -> Bool {
        !Task.isCancelled && generation == token && owner == session()
    }

    private func reconcile(enabled: Set<ManagedNotificationCategory>, lead: EventReminderLeadTime,
                           sources: [ManagedNotificationCategory: Source], token: UUID, owner: String?) async {
        var pending = await center.pending()
        guard valid(token, owner) else { return }
        // Remove disabled and previous-session requests before any potentially slow network read.
        let obsolete = pending.filter {
            guard let category = ManagedNotificationCategory.category(of: $0.id) else { return false }
            return needsSessionCleanup || owner == nil || $0.session != owner || !enabled.contains(category)
        }.map(\.id)
        center.remove(obsolete)
        center.removeDelivered(obsolete)
        pending.removeAll { obsolete.contains($0.id) }
        needsSessionCleanup = false
        guard let owner else { statusChanged("登入後可同步活動提醒"); return }
        let authorized = await center.isAuthorized()
        guard valid(token, owner) else { return }
        guard authorized else {
            center.remove(pending.map(\.id).filter { ManagedNotificationCategory.category(of: $0) != nil })
            statusChanged(enabled.contains(.event) ? "系統通知尚未允許，未安排活動提醒；請至 iOS 設定開啟通知。" : "活動提醒已關閉")
            return
        }
        var candidates: [ManagedNotification] = []
        var invalid = 0, elapsed = 0
        var eventFetchFailed = false
        if enabled.contains(.event) {
            statusChanged("正在核對已報名活動…")
            var records: [EventReminderRecord]?
            do {
                records = try await events()
                guard valid(token, owner) else { return }
                saveCache(try? JSONEncoder().encode(Cache(session: owner, records: records ?? [])))
            } catch {
                guard valid(token, owner) else { return }
                eventFetchFailed = true
                if let data = loadCache(), let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.session == owner {
                    records = cache.records
                }
            }
            if let records {
                for record in records where record.isRegistered {
                    guard let start = EventReminderDate.start(record.eventTime) else { invalid += 1; continue }
                    let fire = start.addingTimeInterval(-Double(lead.rawValue) * 60)
                    guard fire > now() else { elapsed += 1; continue }
                    candidates.append(ManagedNotification(id: "notify.event.\(record.id)", category: .event,
                        title: "已報名活動即將開始", body: "\(record.title)（\(record.eventTime)）", fireDate: fire))
                }
            } else {
                candidates += pending.compactMap(\.value).filter { $0.category == .event }
            }
        }
        // A failed category refresh preserves its existing valid requests instead of treating it as an empty list.
        for category in ManagedNotificationCategory.allCases where category != .event && enabled.contains(category) {
            do {
                if let source = sources[category] { candidates += try await source() }
                else { candidates += pending.compactMap(\.value).filter { $0.category == category } }
            } catch {
                candidates += pending.compactMap(\.value).filter { $0.category == category }
            }
            guard valid(token, owner) else { return }
        }
        let unmanagedCount = pending.filter { ManagedNotificationCategory.category(of: $0.id) == nil }.count
        let chosen = NotificationBudget.select(candidates, unmanagedCount: unmanagedCount, now: now())
        let selectedIDs = Set(chosen.map(\.id))
        let removals = pending.filter { ManagedNotificationCategory.category(of: $0.id) != nil && !selectedIDs.contains($0.id) }.map(\.id)
        center.remove(removals)
        center.removeDelivered(removals)
        var scheduled = 0, failures = 0
        for value in chosen {
            guard valid(token, owner) else { return }
            do {
                // Reusing the identifier replaces a changed time without duplicating reminders.
                try await center.add(value, session: owner)
                guard valid(token, owner) else {
                    center.remove([value.id])
                    return
                }
                if value.category == .event { scheduled += 1 }
            } catch {
                guard valid(token, owner) else { return }
                if value.category == .event { failures += 1 }
            }
        }
        guard enabled.contains(.event) else { statusChanged("活動提醒已關閉"); return }
        let deferred = max(0, candidates.filter { $0.category == .event }.count - chosen.filter { $0.category == .event }.count)
        var lines = ["已安排 \(scheduled) 個活動提醒"]
        if eventFetchFailed { lines.append("更新失敗，保留有效快取；請稍後重試") }
        if invalid > 0 { lines.append("\(invalid) 個活動缺少可辨識的開始日期與時間，未安排") }
        if elapsed > 0 { lines.append("\(elapsed) 個活動的提醒時間已過，未安排") }
        if deferred > 0 { lines.append("\(deferred) 個活動因通知容量限制未安排，開啟 App 時重新核對") }
        if failures > 0 { lines.append("\(failures) 個提醒無法更新，請重試") }
        statusChanged(lines.joined(separator: "\n"))
    }
}
