import WidgetKit
import SwiftUI

struct NIUWidgetEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let scheduleState: String
    let scheduleCourse: String
    let scheduleMeta: String
    let calendarEvent: String
    let calendarDate: String
}

struct NIUWidgetProvider: AppIntentTimelineProvider {
    private let appGroupIdentifier = "group.CHIEN.NIU-APP"

    func placeholder(in context: Context) -> NIUWidgetEntry {
        NIUWidgetEntry(
            date: Date(),
            configuration: ConfigurationAppIntent(),
            scheduleState: "下一堂",
            scheduleCourse: "資料庫系統",
            scheduleMeta: "資工館 A201 ・ 第3節 10:20",
            calendarEvent: "期中考週",
            calendarDate: "2026/04/13 - 2026/04/17"
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> NIUWidgetEntry {
        makeEntry(configuration: configuration)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<NIUWidgetEntry> {
        let entry = makeEntry(configuration: configuration)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func makeEntry(configuration: ConfigurationAppIntent) -> NIUWidgetEntry {
        let schedule = loadScheduleSummary()
        let calendar = loadCalendarSummary()
        return NIUWidgetEntry(
            date: Date(),
            configuration: configuration,
            scheduleState: schedule.state,
            scheduleCourse: schedule.course,
            scheduleMeta: schedule.meta,
            calendarEvent: calendar.event,
            calendarDate: calendar.dateRange
        )
    }

    private func loadScheduleSummary() -> (state: String, course: String, meta: String) {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        guard let data = defaults.data(forKey: "classSchedule.v2.cachedData"),
              let schedule = try? JSONDecoder().decode(WidgetClassSchedule.self, from: data) else {
            return ("未同步", "課表資料", "請先在 App 內開啟我的課表")
        }

        let calendar = Calendar.current
        let now = Date()
        let currentWeekday = calendar.component(.weekday, from: now)
        if currentWeekday == 7 || currentWeekday == 1 {
            return ("今天沒課", "好好休息吧", "")
        }
        let startOfToday = calendar.startOfDay(for: now)
        let targetWeekdays: Set<Int> = [currentWeekday]

        typealias Candidate = (state: String, course: String, meta: String, start: Date, end: Date)
        var candidates: [Candidate] = []

        for (dayIndex, header) in schedule.dayHeaders.enumerated() {
            guard let weekday = weekdayIndex(from: header), targetWeekdays.contains(weekday) else { continue }
            for period in schedule.periods {
                guard let course = period.courses[String(dayIndex)],
                      let start = period.startMinutes,
                      let end = period.endMinutes,
                      end > start else { continue }

                let startDate: Date?
                if weekday == currentWeekday {
                    startDate = calendar.date(byAdding: .minute, value: start, to: startOfToday)
                } else {
                    startDate = nextDateForWeekday(weekday, minutes: start, from: now)
                }
                guard let startDate,
                      let endDate = calendar.date(byAdding: .minute, value: end - start, to: startDate),
                      endDate > now else { continue }

                let room = course.classroom?.trimmingCharacters(in: .whitespacesAndNewlines)
                let roomLabel = (room?.isEmpty == false) ? room! : "教室待確認"
                let state = (startDate <= now && now < endDate) ? "本節課" : "下一堂"
                let meta = "\(roomLabel) ・ 第\(period.id)節 \(period.startLabel)"
                candidates.append((state, course.name, meta, startDate, endDate))
            }
        }

        if let next = candidates.sorted(by: { $0.start < $1.start }).first {
            return (next.state, next.course, next.meta)
        }

        return ("今天辛苦啦", "好好休息吧", "")
    }

    private func loadCalendarSummary() -> (event: String, dateRange: String) {
        guard let data = Bundle.main.url(forResource: "academic_calendar", withExtension: "json").flatMap({ try? Data(contentsOf: $0) }),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let semesters = root["semesters"] as? [[String: Any]] else {
            return ("行事曆資料讀取失敗", "請稍後再試")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()

        var best: (title: String, subtitle: String, start: Date)? = nil
        for semester in semesters {
            guard let events = semester["events"] as? [[String: Any]] else { continue }
            for event in events {
                guard let title = event["title"] as? String,
                      let startString = event["startDate"] as? String,
                      let startDate = formatter.date(from: startString) else { continue }
                let endString = (event["endDate"] as? String) ?? startString
                let subtitle = "\(startString) - \(endString)"

                if startDate >= now {
                    if let currentBest = best {
                        if startDate < currentBest.start {
                            best = (title, subtitle, startDate)
                        }
                    } else {
                        best = (title, subtitle, startDate)
                    }
                }
            }
        }

        if let best {
            return (best.title, best.subtitle)
        }
        return ("近期無行事曆事件", "請稍後再查看")
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

    private func nextDateForWeekday(_ weekday: Int, minutes: Int, from now: Date) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = minutes / 60
        components.minute = minutes % 60
        return Calendar.current.nextDate(after: now, matching: components, matchingPolicy: .nextTime, direction: .forward)
    }
}

struct NIUWidgetView: View {
    let entry: NIUWidgetProvider.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemSmall {
                smallLayout
            } else {
                mediumLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.configuration.contentType == .classSchedule ? entry.scheduleState : "下一個事件")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(entry.configuration.contentType == .classSchedule ? entry.scheduleCourse : entry.calendarEvent)
                .font(.headline)
                .lineLimit(2)

            Text(compactMeta)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(compactMeta.isEmpty ? 0 : 1)

            Spacer()

            Text(compactTime)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: entry.configuration.contentType == .classSchedule ? "tablecells" : "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.configuration.contentType == .classSchedule ? "課表" : "行事曆")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if entry.configuration.contentType == .classSchedule {
                    Text(entry.scheduleState)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Text(entry.configuration.contentType == .classSchedule ? entry.scheduleCourse : entry.calendarEvent)
                .font(.headline)
                .lineLimit(2)

            if !(entry.configuration.contentType == .classSchedule ? entry.scheduleMeta : entry.calendarDate).isEmpty {
                Text(entry.configuration.contentType == .classSchedule ? entry.scheduleMeta : entry.calendarDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Text(entry.date, style: .time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var compactMeta: String {
        if entry.configuration.contentType == .classSchedule {
            if let room = entry.scheduleMeta.components(separatedBy: "・").first {
                return room.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return entry.scheduleMeta
        }
        return entry.calendarDate
    }

    private var compactTime: String {
        if entry.configuration.contentType == .classSchedule,
           let lastToken = entry.scheduleMeta.split(separator: " ").last,
           lastToken.contains(":") {
            return String(lastToken)
        }
        return entry.date.formatted(date: .omitted, time: .shortened)
    }
}

struct NIU_LiveActivities: Widget {
    let kind: String = "NIU_LiveActivities"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: NIUWidgetProvider()) { entry in
            NIUWidgetView(entry: entry)
        }
        .configurationDisplayName("NIU 小工具")
        .description("可切換顯示課表或學年行事曆")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct WidgetClassSchedule: Decodable {
    let periods: [WidgetClassPeriod]
    let dayHeaders: [String]
}

private struct WidgetClassPeriod: Decodable {
    let id: String
    let timeRange: String
    let courses: [String: WidgetCourseInfo]

    var startMinutes: Int? {
        parseRange().map { $0.0 }
    }

    var endMinutes: Int? {
        parseRange().map { $0.1 }
    }

    var startLabel: String {
        timeRange.components(separatedBy: CharacterSet(charactersIn: "~-"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func parseRange() -> (Int, Int)? {
        let parts = timeRange.components(separatedBy: CharacterSet(charactersIn: "~-"))
        guard parts.count >= 2 else { return nil }
        let start = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let end = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = toMinutes(start), let e = toMinutes(end) else { return nil }
        return (s, e)
    }

    private func toMinutes(_ text: String) -> Int? {
        let split = text.split(separator: ":")
        guard split.count == 2,
              let h = Int(split[0]),
              let m = Int(split[1]) else { return nil }
        return h * 60 + m
    }
}

private struct WidgetCourseInfo: Decodable {
    let name: String
    let classroom: String?
}

#Preview(as: .systemSmall) {
    NIU_LiveActivities()
} timeline: {
    NIUWidgetEntry(
        date: .now,
        configuration: {
            var intent = ConfigurationAppIntent()
            intent.contentType = .classSchedule
            return intent
        }(),
        scheduleState: "下一堂",
        scheduleCourse: "資料庫系統",
        scheduleMeta: "資工館 A201 ・ 第3節 10:20",
        calendarEvent: "期中考週",
        calendarDate: "2026/04/13 - 2026/04/17"
    )
}
