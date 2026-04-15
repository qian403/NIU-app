import WidgetKit
import SwiftUI

private let bundledAcademicCalendarURL = Bundle.main.url(forResource: "academic_calendar", withExtension: "json")

struct NIUWidgetEntry: TimelineEntry {
    let date: Date
    fileprivate let payload: WidgetPayload
}

struct NIUWidgetProvider: AppIntentTimelineProvider {
    private let appGroupIdentifier = "group.CHIEN.NIU-APP"
    private let appGroupCalendarCacheKey = "academicCalendar.shared.cachedData"

    private var academicCalendarURL: URL {
        let calendar = Calendar.current
        let now = Date()
        let gregorianYear = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let academicYear = month >= 8 ? gregorianYear - 1911 : gregorianYear - 1912
        return URL(string: "https://tools.chien.dev/data/niu/academic-calendar/\(academicYear).json")!
    }

    func placeholder(in context: Context) -> NIUWidgetEntry {
        NIUWidgetEntry(
            date: Date(),
            payload: .placeholder(for: .classSchedule)
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> NIUWidgetEntry {
        await makeEntry(configuration: configuration)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<NIUWidgetEntry> {
        let entry = await makeEntry(configuration: configuration)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func makeEntry(configuration: ConfigurationAppIntent) async -> NIUWidgetEntry {
        await entry(for: configuration.contentType)
    }

    func entry(for contentType: WidgetContentType) async -> NIUWidgetEntry {
        NIUWidgetEntry(date: Date(), payload: await makePayload(for: contentType))
    }

    private func makePayload(for contentType: WidgetContentType) async -> WidgetPayload {
        switch contentType {
        case .classSchedule:
            return .todaySchedule(loadTodayScheduleSummary())
        case .academicCalendar:
            return .calendar(await loadCalendarSummary())
        case .weeklyTimetable:
            return .weeklyTimetable(loadWeekSummary())
        }
    }

    private func loadTodayScheduleSummary() -> TodayScheduleSummary {
        guard let schedule = loadSchedule() else {
            return TodayScheduleSummary(
                state: "未同步課表",
                title: "課表資料",
                subtitle: "請先在 App 內開啟我的課表",
                location: nil,
                entries: []
            )
        }

        let calendar = Calendar.current
        let now = Date()
        let currentWeekday = calendar.component(.weekday, from: now)
        if currentWeekday == 7 || currentWeekday == 1 {
            return TodayScheduleSummary(
                state: "今日無課",
                title: "好好休息吧",
                subtitle: "週末沒有排課",
                location: nil,
                entries: []
            )
        }

        guard let dayIndex = schedule.dayHeaders.firstIndex(where: { weekdayIndex(from: $0) == currentWeekday }) else {
            return TodayScheduleSummary(
                state: "今日無課",
                title: "今日無排課",
                subtitle: "適合安排自習或處理作業",
                location: nil,
                entries: []
            )
        }

        let entries = schedule.periods.compactMap { period -> TodayScheduleItem? in
            guard let course = period.courses[String(dayIndex)] else { return nil }
            return TodayScheduleItem(
                periodLabel: period.id,
                timeLabel: period.startLabel,
                timeRange: period.timeRange,
                courseName: course.name,
                classroom: course.classroom?.trimmedOrNil,
                teacher: course.teacher?.trimmedOrNil,
                isCurrent: period.contains(now: now)
            )
        }

        guard let first = entries.first else {
            return TodayScheduleSummary(
                state: "今日無課",
                title: "今日無排課",
                subtitle: "適合安排自習或處理作業",
                location: nil,
                entries: []
            )
        }

        let primary = entries.first(where: { $0.isCurrent }) ?? first
        let firstStartMinutes = minutes(from: first.timeLabel)
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let currentMinutes = components.hour.flatMap { hour in
            components.minute.map { minute in
                hour * 60 + minute
            }
        }
        let state: String
        if primary.isCurrent {
            state = "上課中"
        } else if let firstStartMinutes, let currentMinutes, currentMinutes < firstStartMinutes {
            state = "今日第一堂"
        } else {
            state = "下一堂課"
        }
        let subtitle = primary.classroom.map { "\($0) ・ 第\(primary.periodLabel)節 \(primary.timeLabel)" } ?? "第\(primary.periodLabel)節 \(primary.timeLabel)"
        let focusedEntries = focusedScheduleItems(from: entries, now: now)

        return TodayScheduleSummary(
            state: state,
            title: primary.courseName,
            subtitle: subtitle,
            location: primary.classroom,
            entries: focusedEntries
        )
    }

    private func loadWeekSummary() -> WeekTimetableSummary {
        guard let schedule = loadSchedule() else {
            return WeekTimetableSummary(
                title: "完整課表",
                subtitle: "請先在 App 內同步課表",
                days: [],
                blocks: []
            )
        }

        let todayWeekday = Calendar.current.component(.weekday, from: Date())
        let validPeriods = schedule.periods.filter { period in
            guard let start = period.startMinutes, let end = period.endMinutes else { return false }
            return end > start
        }

        let days = schedule.dayHeaders.enumerated().map { index, header in
            let items = validPeriods.compactMap { period -> WidgetCourseInfo? in
                period.courses[String(index)]
            }
            return WeekDaySummary(
                label: shortDayLabel(from: header),
                countText: "\(items.count)",
                topCourse: items.first?.name ?? "無課",
                sessions: items.map(\.name),
                allDaySummary: items.isEmpty ? "無課" : "\(items.count) 堂課",
                isToday: weekdayIndex(from: header) == todayWeekday
            )
        }

        let rawBlocksByDay: [[WeekCourseBlock]] = schedule.dayHeaders.enumerated().map { dayIndex, header in
            validPeriods.compactMap { period -> WeekCourseBlock? in
                guard let course = period.courses[String(dayIndex)],
                      let start = period.startMinutes,
                      let end = period.endMinutes else {
                    return nil
                }

                return WeekCourseBlock(
                    id: "\(dayIndex)-\(period.id)-\(course.name)",
                    dayIndex: dayIndex,
                    dayLabel: shortDayLabel(from: header),
                    courseName: course.name,
                    classroom: course.classroom?.trimmedOrNil,
                    startMinutes: start,
                    endMinutes: end,
                    startLabel: period.startLabel,
                    endLabel: period.endLabel,
                    colorStyle: WeekCourseColorStyle.style(for: course.name)
                )
            }
        }

        let blocks = rawBlocksByDay
            .enumerated()
            .flatMap { dayIndex, blocks in
                mergedWeekCourseBlocks(blocks)
                    .map { merged -> WeekCourseBlock in
                        WeekCourseBlock(
                            id: "\(dayIndex)-\(merged.courseName)-\(merged.startMinutes)",
                            dayIndex: merged.dayIndex,
                            dayLabel: merged.dayLabel,
                            courseName: merged.courseName,
                            classroom: merged.classroom,
                            startMinutes: merged.startMinutes,
                            endMinutes: merged.endMinutes,
                            startLabel: merged.startLabel,
                            endLabel: merged.endLabel,
                            colorStyle: merged.colorStyle
                        )
                    }
            }

        let visibleBlocks = blocks.filter { $0.dayIndex < 5 }

        return WeekTimetableSummary(
            title: "完整課表",
            subtitle: "\(weekTimeRangeText(for: visibleBlocks)) 週課表",
            days: Array(days.prefix(5)),
            blocks: visibleBlocks
        )
    }

    private func loadCalendarSummary() async -> CalendarSummary {
        let events = await loadAcademicCalendarEvents()
        guard !events.isEmpty else {
            return CalendarSummary(
                state: "資料異常",
                title: "資料讀取失敗",
                subtitle: "請稍後再試",
                entries: []
            )
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let todayEvents = events.filter { event in
            guard let start = event.start else { return false }
            return start >= startOfToday && start < endOfToday
        }

        if let current = events.first(where: { event in
            guard let start = event.start, let end = event.end else { return false }
            return start <= now && now <= end
        }) {
            let entries = Array(events.filter { event in
                guard let start = event.start, let end = event.end else { return false }
                return start <= now && now <= end
            }.prefix(3)).map(makeCalendarItem)
            return CalendarSummary(
                state: current.isMultiDay ? "進行中" : "今日事件",
                title: current.title,
                subtitle: displayDateRange(for: current),
                entries: entries
            )
        }

        if let today = todayEvents.first {
            return CalendarSummary(
                state: "今日事件",
                title: today.title,
                subtitle: displayDateRange(for: today),
                entries: Array(todayEvents.prefix(3)).map(makeCalendarItem)
            )
        }

        if let next = events.first(where: { ($0.start ?? .distantFuture) >= startOfToday }) {
            let upcoming = Array(events.filter { ($0.start ?? .distantFuture) >= startOfToday }.prefix(3)).map(makeCalendarItem)
            let state = calendar.isDate(next.start ?? now, inSameDayAs: now) ? "今日事件" : "下一個事件"
            return CalendarSummary(
                state: state,
                title: next.title,
                subtitle: displayDateRange(for: next),
                entries: upcoming
            )
        }

        return CalendarSummary(
            state: "今日無事",
            title: "今天沒有事件",
            subtitle: "打開完整行事曆查看更多日程",
            entries: []
        )
    }

    private func makeCalendarItem(from event: WidgetCalendarEvent) -> CalendarItem {
        CalendarItem(
            dayText: dayLabel(for: event.start),
            monthText: monthLabel(for: event.start),
            title: event.title,
            subtitle: displayDateRange(for: event)
        )
    }

    private func loadSchedule() -> WidgetClassSchedule? {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        guard let data = defaults.data(forKey: "classSchedule.v2.cachedData"),
              let schedule = try? JSONDecoder().decode(WidgetClassSchedule.self, from: data) else {
            return nil
        }
        return schedule
    }

    private func loadAcademicCalendarEvents() async -> [WidgetCalendarEvent] {
        if let cached = loadSharedAcademicCalendarEvents(), !cached.isEmpty {
            return cached.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        }
        if let remote = await loadRemoteAcademicCalendarEvents(), !remote.isEmpty {
            return remote.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        }
        if let local = loadBundledAcademicCalendarEvents(), !local.isEmpty {
            return local.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        }
        return []
    }

    private func loadSharedAcademicCalendarEvents() -> [WidgetCalendarEvent]? {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        guard let data = defaults.data(forKey: appGroupCalendarCacheKey) else {
            return nil
        }

        if let decoded = try? JSONDecoder().decode(WidgetRemoteAcademicCalendar.self, from: data) {
            return decoded.pages.flatMap { $0.events }
        }

        if let decoded = try? JSONDecoder().decode(WidgetBundledAcademicCalendar.self, from: data) {
            return decoded.calendars.flatMap(\.events)
        }

        return nil
    }

    private func loadRemoteAcademicCalendarEvents() async -> [WidgetCalendarEvent]? {
        do {
            let (data, _) = try await URLSession.shared.data(from: academicCalendarURL)
            let decoded = try JSONDecoder().decode(WidgetRemoteAcademicCalendar.self, from: data)
            return decoded.pages.flatMap { $0.events }
        } catch {
            return nil
        }
    }

    private func loadBundledAcademicCalendarEvents() -> [WidgetCalendarEvent]? {
        guard let url = bundledAcademicCalendarURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(WidgetBundledAcademicCalendar.self, from: data) else {
            return nil
        }

        return decoded.calendars.flatMap(\.events)
    }

    private func displayDateRange(for event: WidgetCalendarEvent) -> String {
        guard let start = event.start else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "M/d"

        let startLabel = formatter.string(from: start)
        guard let end = event.end, !Calendar.current.isDate(start, inSameDayAs: end) else {
            return startLabel
        }
        return "\(startLabel) - \(formatter.string(from: end))"
    }

    private func dayLabel(for date: Date?) -> String {
        guard let date else { return "--" }
        return String(Calendar.current.component(.day, from: date))
    }

    private func monthLabel(for date: Date?) -> String {
        guard let date else { return "" }
        return "\(Calendar.current.component(.month, from: date))月"
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

    private func shortDayLabel(from header: String) -> String {
        String(header.suffix(1))
    }

    private func focusedScheduleItems(from entries: [TodayScheduleItem], now: Date) -> [TodayScheduleItem] {
        guard !entries.isEmpty else { return [] }
        if let currentIndex = entries.firstIndex(where: { $0.isCurrent }) {
            let upperBound = min(entries.count, currentIndex + 2)
            return Array(entries[currentIndex..<upperBound])
        }

        if let upcomingIndex = entries.firstIndex(where: { item in
            guard let startMinutes = minutes(from: item.timeLabel) else { return false }
            let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
            guard let hour = comps.hour, let minute = comps.minute else { return false }
            let currentMinutes = hour * 60 + minute
            return startMinutes >= currentMinutes
        }) {
            let upperBound = min(entries.count, upcomingIndex + 2)
            return Array(entries[upcomingIndex..<upperBound])
        }

        return Array(entries.suffix(2))
    }

    private func minutes(from label: String) -> Int? {
        let parts = label.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        return hour * 60 + minute
    }
}

struct NIUCompactWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NIUWidgetEntry {
        NIUWidgetEntry(date: Date(), payload: .placeholder(for: .classSchedule))
    }

    func snapshot(for configuration: CompactConfigurationAppIntent, in context: Context) async -> NIUWidgetEntry {
        await NIUWidgetProvider().entry(for: configuration.contentType.widgetContentType)
    }

    func timeline(for configuration: CompactConfigurationAppIntent, in context: Context) async -> Timeline<NIUWidgetEntry> {
        let entry = await snapshot(for: configuration, in: context)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }
}

struct NIUWidgetView: View {
    let entry: NIUWidgetProvider.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch entry.payload {
            case .todaySchedule(let summary):
                scheduleLayout(summary: summary)
            case .calendar(let summary):
                calendarLayout(summary: summary)
            case .weeklyTimetable(let summary):
                weekLayout(summary: summary)
            }
        }
        .widgetURL(destinationURL)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var destinationURL: URL? {
        switch entry.payload {
        case .todaySchedule, .weeklyTimetable:
            return URL(string: "niuapp://class-schedule")
        case .calendar:
            return URL(string: "niuapp://academic-calendar")
        }
    }

    @ViewBuilder
    private func scheduleLayout(summary: TodayScheduleSummary) -> some View {
        if family == .systemSmall {
            let primary = summary.entries.first
            let next = summary.entries.dropFirst().first

            VStack(alignment: .leading, spacing: 8) {
                widgetHeader(icon: "tablecells", title: summary.state, state: smallScheduleBadge(summary))

                if let primary {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(primary.courseName)
                            .font(.headline)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                            .allowsTightening(true)
                            .truncationMode(.tail)

                        HStack(spacing: 6) {
                            if let room = primary.classroom {
                                Label(room, systemImage: "mappin.and.ellipse")
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        compactInfoPill(
                            label: primary.isCurrent ? "進行中" : summary.state,
                            value: primary.isCurrent ? primary.timeRange : "\(primary.timeLabel) 開始"
                        )

                        if let next {
                            HStack(spacing: 4) {
                                Text("下堂")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(next.courseName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(next.timeLabel)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } else {
                    Text(summary.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(summary.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(12)
        } else {
            mediumScheduleLayout(summary: summary)
        }
    }

    private func mediumScheduleLayout(summary: TodayScheduleSummary) -> some View {
        let primary = summary.entries.first
        let next = summary.entries.dropFirst().first

        return VStack(alignment: .leading, spacing: 10) {
            if let primary {
                HStack(alignment: .firstTextBaseline) {
                    Text(primary.courseName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(primary.isCurrent ? primary.timeRange : primary.timeLabel)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    if let classroom = primary.classroom {
                        Label(classroom, systemImage: "mappin.and.ellipse")
                            .lineLimit(1)
                    }
                    Label(normalizedPeriodLabel(primary.periodLabel), systemImage: "clock")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(primary.isCurrent ? "進行中 · \(primary.timeRange)" : "\(summary.state) · \(primary.timeLabel) 開始")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let teacher = primary.teacher {
                        Text(teacher)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if let next {
                    HStack(spacing: 6) {
                        Text("下堂")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(next.courseName)
                            .font(.caption2)
                            .lineLimit(1)
                        if let room = next.classroom {
                            Text("· \(room)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(next.timeLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                widgetHeader(icon: "tablecells", title: "當日課表", state: summary.state)
                Text(summary.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func calendarLayout(summary: CalendarSummary) -> some View {
        if family == .systemSmall {
            let first = summary.entries.first

            VStack(alignment: .leading, spacing: 8) {
                widgetHeader(icon: "calendar", title: summary.state, state: smallCalendarCount(summary))

                if let first {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 1) {
                            Text(first.dayText)
                                .font(.title3.weight(.bold))
                                .lineLimit(1)
                            Text(first.monthText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 34)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.title)
                                .font(.headline)
                                .lineLimit(2)
                                .minimumScaleFactor(0.72)
                                .allowsTightening(true)
                                .truncationMode(.tail)

                            Text(summary.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .allowsTightening(true)
                                .truncationMode(.tail)
                        }
                    }

                    compactInfoPill(label: "日期", value: first.subtitle)

                    if summary.entries.count > 1 {
                        let remaining = summary.entries.count - 1
                        Text(remaining == 1 ? "還有 1 個相關事件" : "還有 \(remaining) 個相關事件")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(summary.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(summary.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(12)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                widgetHeader(icon: "calendar", title: "校園行事曆", state: summary.state)
                Text(summary.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !summary.entries.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(summary.entries) { item in
                            HStack(spacing: 10) {
                                VStack(spacing: 1) {
                                    Text(item.dayText)
                                        .font(.subheadline.weight(.bold))
                                    Text(item.monthText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(item.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func weekLayout(summary: WeekTimetableSummary) -> some View {
        Group {
            if family == .systemLarge {
                largeWeekLayout(summary: summary)
            } else {
                VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
                    widgetHeader(icon: "rectangle.split.5x1", title: summary.title, state: "本週")
                    Text(summary.subtitle)
                        .font(family == .systemSmall ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if summary.days.isEmpty {
                        Spacer()
                        Text("尚未同步課表")
                            .font(.headline)
                            .lineLimit(2)
                        Text("請先在 App 內開啟我的課表")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        let shownDays = Array(summary.days.prefix(4))
                        HStack(spacing: 6) {
                            ForEach(shownDays) { day in
                                compactWeekDayCard(day)
                            }
                        }
                    }
                }
                .padding(family == .systemSmall ? 12 : 14)
            }
        }
    }

    private func largeWeekLayout(summary: WeekTimetableSummary) -> some View {
        GeometryReader { geometry in
            let paddedSize = CGSize(
                width: geometry.size.width - 24,
                height: geometry.size.height - 12
            )
            let layout = WeekGridLayout(
                containerSize: paddedSize,
                dayCount: max(summary.days.count, 5),
                blocks: summary.blocks
            )
            
            Group {
                if summary.days.isEmpty {
                    largeWeekEmptyState()
                } else {
                    largeWeekContent(summary: summary, layout: layout)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    
    private func largeWeekEmptyState() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.subheadline.weight(.semibold))
                Text("課表")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text(currentWeekRangeLabel())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("尚未同步課表")
                .font(.title3.weight(.semibold))
            Text("請先在 App 內開啟我的課表")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
    }
    
    private func largeWeekContent(summary: WeekTimetableSummary, layout: WeekGridLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            largeWeekHeader(summary: summary, layout: layout)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            
            ZStack(alignment: .topLeading) {
                largeWeekGrid(layout: layout, days: summary.days)
                ForEach(summary.blocks) { block in
                    largeWeekCourseBlock(block, layout: layout)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
    
    private func largeWeekHeader(summary: WeekTimetableSummary, layout: WeekGridLayout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.caption.weight(.semibold))
                    Text("課表")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 8)
                Text(currentWeekRangeLabel())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            
            largeWeekDayHeaders(summary: summary, layout: layout)
        }
    }
    
    private func largeWeekDayHeaders(summary: WeekTimetableSummary, layout: WeekGridLayout) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: layout.timeAxisWidth, height: 28)
            
            ForEach(Array(summary.days.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 2) {
                    Text("週\(day.label)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                    Text(weekDateLabel(for: index))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                }
                .frame(width: layout.dayColumnWidth, height: 28)
            }
        }
    }
    
    private func largeWeekGrid(layout: WeekGridLayout, days: [WeekDaySummary]) -> some View {
        VStack(spacing: 0) {
            ForEach(layout.hourMarks.indices, id: \.self) { index in
                gridRow(layout: layout, days: days, index: index)
                if index < layout.hourMarks.count - 1 {
                    gridDivider(layout: layout)
                }
            }
        }
    }
    
    private func gridRow(layout: WeekGridLayout, days: [WeekDaySummary], index: Int) -> some View {
        HStack(spacing: 0) {
            Text(layout.hourMarks[index])
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: layout.timeAxisWidth - 6, alignment: .trailing)
                .padding(.trailing, 6)
            
            HStack(spacing: 0) {
                ForEach(days.indices, id: \.self) { dayIndex in
                    gridCell(layout: layout, days: days, dayIndex: dayIndex)
                }
            }
        }
    }
    
    private func gridCell(layout: WeekGridLayout, days: [WeekDaySummary], dayIndex: Int) -> some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 1)
            }
            .frame(width: layout.dayColumnWidth, height: layout.hourRowHeight)
    }
    
    private func gridDivider(layout: WeekGridLayout) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(height: 1)
            .padding(.leading, layout.timeAxisWidth)
    }
    
    private func largeWeekCourseBlock(_ block: WeekCourseBlock, layout: WeekGridLayout) -> some View {
        let frame = layout.frame(for: block)
        let isCompact = frame.height < 58
        let isVeryCompact = frame.height < 44
        
        return courseBlockContent(block: block, isCompact: isCompact, isVeryCompact: isVeryCompact)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .background(block.colorStyle.background)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(block.colorStyle.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .offset(x: frame.minX, y: frame.minY)
    }
    
    private func courseBlockContent(block: WeekCourseBlock, isCompact: Bool, isVeryCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 1 : 2) {
            Text(block.courseName)
                .font(isCompact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(block.colorStyle.foreground)
                .lineLimit(isVeryCompact ? 2 : 3)
                .minimumScaleFactor(0.75)
            
            if !isVeryCompact {
                Text("\(block.startLabel)-\(block.endLabel)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(block.colorStyle.foreground.opacity(0.8))
                    .lineLimit(1)
            }
            
            if !isCompact, let classroom = block.classroom {
                Text(classroom)
                    .font(.caption2)
                    .foregroundStyle(block.colorStyle.foreground.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .padding(isCompact ? 5 : 6)
    }

    private func compactWeekDayCard(_ day: WeekDaySummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(day.label)
                    .font(.caption.weight(.semibold))
                if day.isToday {
                    Circle()
                        .fill(.primary)
                        .frame(width: 5, height: 5)
                }
            }
            Text(day.countText)
                .font(.title3.weight(.bold))
            Text(day.topCourse)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(family == .systemSmall ? 2 : 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(day.isToday ? Color.primary.opacity(0.16) : Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func largeWeekDayCard(_ day: WeekDaySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("週\(day.label)")
                    .font(.caption.weight(.semibold))
                if day.isToday {
                    Circle()
                        .fill(.primary)
                        .frame(width: 6, height: 6)
                }
                Spacer(minLength: 0)
                Text(day.allDaySummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if day.sessions.isEmpty || (day.sessions.count == 1 && day.sessions[0] == "無課") {
                Text("無課")
                    .font(.callout.weight(.semibold))
                    .padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(day.sessions.enumerated()), id: \.offset) { index, session in
                        HStack(alignment: .top, spacing: 5) {
                            Text("\(index + 1).")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 12, alignment: .leading)
                            Text(session)
                                .font(index == 0 ? .callout.weight(.semibold) : .caption)
                                .foregroundStyle(index == 0 ? .primary : .secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(day.isToday ? Color.primary.opacity(0.16) : Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func widgetHeader(icon: String, title: String, state: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if !state.isEmpty {
                Text(state)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func compactInfoPill(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func smallScheduleBadge(_ summary: TodayScheduleSummary) -> String {
        guard let first = summary.entries.first else { return "" }
        let trimmed = first.periodLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("第") && trimmed.hasSuffix("節") {
            return trimmed
        }
        return "第\(trimmed)節"
    }

    private func smallCalendarBadge(_ summary: CalendarSummary) -> String {
        if let first = summary.entries.first {
            return "\(first.monthText)\(first.dayText)日"
        }
        return currentMonthDayLabel()
    }

    private func smallCalendarHeader(_ summary: CalendarSummary) -> String {
        if summary.entries.isEmpty {
            return currentMonthDayLabel()
        }
        return "今天"
    }

    private func smallCalendarCount(_ summary: CalendarSummary) -> String {
        if summary.entries.isEmpty {
            return "0 件"
        }
        return "\(summary.entries.count) 件"
    }

    private func currentMonthDayLabel() -> String {
        let now = Date()
        let calendar = Calendar.current
        return "\(calendar.component(.month, from: now))/\(calendar.component(.day, from: now))"
    }

    private func currentWeekRangeLabel() -> String {
        let calendar = Calendar.current
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)
        let offsetToMonday = weekday == 1 ? -6 : 2 - weekday
        let start = calendar.date(byAdding: .day, value: offsetToMonday, to: now) ?? now
        let end = calendar.date(byAdding: .day, value: 4, to: start) ?? now

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "M/d"
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }

    private func weekDateLabel(for dayIndex: Int) -> String {
        let calendar = Calendar.current
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)
        let offsetToMonday = weekday == 1 ? -6 : 2 - weekday
        let start = calendar.date(byAdding: .day, value: offsetToMonday, to: now) ?? now
        let date = calendar.date(byAdding: .day, value: dayIndex, to: start) ?? start

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private func normalizedPeriodLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("第") && trimmed.hasSuffix("節") {
            return trimmed
        }
        return "第\(trimmed)節"
    }
}

struct NIU_LiveActivities: Widget {
    let kind: String = "NIU_LiveActivities"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: NIUWidgetProvider()) { entry in
            NIUWidgetView(entry: entry)
        }
        .configurationDisplayName("NIU 完整課表")
        .description("大型小工具，可切換顯示完整課表、當日課表或學年行事曆")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

struct NIU_CompactWidget: Widget {
    let kind: String = "NIU_CompactWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: CompactConfigurationAppIntent.self, provider: NIUCompactWidgetProvider()) { entry in
            NIUWidgetView(entry: entry)
        }
        .configurationDisplayName("NIU 小工具")
        .description("小型與中型小工具，可切換顯示當日課表或學年行事曆")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

private enum WidgetPayload {
    case todaySchedule(TodayScheduleSummary)
    case calendar(CalendarSummary)
    case weeklyTimetable(WeekTimetableSummary)

    static func placeholder(for type: WidgetContentType) -> WidgetPayload {
        switch type {
        case .classSchedule:
            return .todaySchedule(
                TodayScheduleSummary(
                    state: "下一堂",
                    title: "資料庫系統",
                    subtitle: "資工館 A201 ・ 第3節 10:20",
                    location: "資工館 A201",
                    entries: [
                        TodayScheduleItem(periodLabel: "3", timeLabel: "10:20", timeRange: "10:20~11:10", courseName: "資料庫系統", classroom: "資工館 A201", teacher: "林老師", isCurrent: true),
                        TodayScheduleItem(periodLabel: "5", timeLabel: "13:10", timeRange: "13:10~14:00", courseName: "作業系統", classroom: "資工館 B101", teacher: "陳老師", isCurrent: false)
                    ]
                )
            )
        case .academicCalendar:
            return .calendar(
                CalendarSummary(
                    state: "今天",
                    title: "期中考週",
                    subtitle: "4/13（週一） - 4/17",
                    entries: [
                        CalendarItem(dayText: "13", monthText: "4月", title: "期中考週", subtitle: "4/13（週一） - 4/17"),
                        CalendarItem(dayText: "22", monthText: "4月", title: "選課截止", subtitle: "4/22（週三）")
                    ]
                )
            )
        case .weeklyTimetable:
            return .weeklyTimetable(
                WeekTimetableSummary(
                    title: "完整課表",
                    subtitle: "一眼查看這週每天課程數量",
                    days: [
                        WeekDaySummary(label: "一", countText: "3", topCourse: "資料庫系統", sessions: ["資料庫系統", "作業系統", "體育"], allDaySummary: "3 堂課", isToday: true),
                        WeekDaySummary(label: "二", countText: "2", topCourse: "作業系統", sessions: ["作業系統", "英文"], allDaySummary: "2 堂課", isToday: false),
                        WeekDaySummary(label: "三", countText: "4", topCourse: "演算法", sessions: ["演算法", "網路", "專題研究", "班會"], allDaySummary: "4 堂課", isToday: false),
                        WeekDaySummary(label: "四", countText: "1", topCourse: "專題研究", sessions: ["專題研究"], allDaySummary: "1 堂課", isToday: false),
                        WeekDaySummary(label: "五", countText: "2", topCourse: "統計學", sessions: ["統計學", "資料探勘"], allDaySummary: "2 堂課", isToday: false)
                    ],
                    blocks: [
                        WeekCourseBlock(id: "mon-1", dayIndex: 0, dayLabel: "一", courseName: "資料庫系統", classroom: "資工館 A201", startMinutes: 540, endMinutes: 590, startLabel: "09:00", endLabel: "09:50", colorStyle: WeekCourseColorStyle.style(for: "資料庫系統")),
                        WeekCourseBlock(id: "mon-2", dayIndex: 0, dayLabel: "一", courseName: "作業系統", classroom: "資工館 B101", startMinutes: 610, endMinutes: 660, startLabel: "10:10", endLabel: "11:00", colorStyle: WeekCourseColorStyle.style(for: "作業系統")),
                        WeekCourseBlock(id: "tue-1", dayIndex: 1, dayLabel: "二", courseName: "英文", classroom: "教學大樓 201", startMinutes: 780, endMinutes: 830, startLabel: "13:00", endLabel: "13:50", colorStyle: WeekCourseColorStyle.style(for: "英文")),
                        WeekCourseBlock(id: "wed-1", dayIndex: 2, dayLabel: "三", courseName: "演算法", classroom: "資工館 C301", startMinutes: 540, endMinutes: 660, startLabel: "09:00", endLabel: "11:00", colorStyle: WeekCourseColorStyle.style(for: "演算法")),
                        WeekCourseBlock(id: "thu-1", dayIndex: 3, dayLabel: "四", courseName: "專題研究", classroom: "研討室 2", startMinutes: 840, endMinutes: 950, startLabel: "14:00", endLabel: "15:50", colorStyle: WeekCourseColorStyle.style(for: "專題研究")),
                        WeekCourseBlock(id: "fri-1", dayIndex: 4, dayLabel: "五", courseName: "統計學", classroom: "綜合教學館 105", startMinutes: 600, endMinutes: 710, startLabel: "10:00", endLabel: "11:50", colorStyle: WeekCourseColorStyle.style(for: "統計學"))
                    ]
                )
            )
        }
    }
}

private struct TodayScheduleSummary {
    let state: String
    let title: String
    let subtitle: String
    let location: String?
    let entries: [TodayScheduleItem]
}

private struct TodayScheduleItem: Identifiable {
    let id = UUID()
    let periodLabel: String
    let timeLabel: String
    let timeRange: String
    let courseName: String
    let classroom: String?
    let teacher: String?
    let isCurrent: Bool
}

private struct CalendarSummary {
    let state: String
    let title: String
    let subtitle: String
    let entries: [CalendarItem]
}

private struct CalendarItem: Identifiable {
    let id = UUID()
    let dayText: String
    let monthText: String
    let title: String
    let subtitle: String
}

private struct WeekTimetableSummary {
    let title: String
    let subtitle: String
    let days: [WeekDaySummary]
    let blocks: [WeekCourseBlock]
}

private struct WeekDaySummary: Identifiable {
    let id = UUID()
    let label: String
    let countText: String
    let topCourse: String
    let sessions: [String]
    let allDaySummary: String
    let isToday: Bool
}

private struct WeekCourseBlock: Identifiable {
    let id: String
    let dayIndex: Int
    let dayLabel: String
    let courseName: String
    let classroom: String?
    let startMinutes: Int
    let endMinutes: Int
    let startLabel: String
    let endLabel: String
    let colorStyle: WeekCourseColorStyle
}

private struct WeekCourseColorStyle {
    let background: Color
    let border: Color
    let foreground: Color

    static func style(for courseName: String) -> WeekCourseColorStyle {
        let palettes: [(Color, Color, Color)] = [
            (Color(red: 0.98, green: 0.91, blue: 0.63), Color(red: 0.90, green: 0.77, blue: 0.30), Color(red: 0.39, green: 0.30, blue: 0.07)),
            (Color(red: 0.98, green: 0.80, blue: 0.63), Color(red: 0.90, green: 0.55, blue: 0.29), Color(red: 0.42, green: 0.20, blue: 0.08)),
            (Color(red: 0.77, green: 0.92, blue: 0.79), Color(red: 0.39, green: 0.70, blue: 0.47), Color(red: 0.13, green: 0.33, blue: 0.18)),
            (Color(red: 0.76, green: 0.87, blue: 0.98), Color(red: 0.36, green: 0.61, blue: 0.92), Color(red: 0.10, green: 0.23, blue: 0.41)),
            (Color(red: 0.96, green: 0.80, blue: 0.88), Color(red: 0.86, green: 0.50, blue: 0.67), Color(red: 0.42, green: 0.16, blue: 0.29))
        ]

        let hash = abs(courseName.hashValue)
        let base = palettes[hash % palettes.count]

        return WeekCourseColorStyle(
            background: base.0.opacity(0.96),
            border: base.1.opacity(0.9),
            foreground: base.2
        )
    }
}

private func mergedWeekCourseBlocks(_ blocks: [WeekCourseBlock]) -> [WeekCourseBlock] {
    let sorted = blocks.sorted {
        if $0.dayIndex != $1.dayIndex { return $0.dayIndex < $1.dayIndex }
        return $0.startMinutes < $1.startMinutes
    }

    var merged: [WeekCourseBlock] = []

    for block in sorted {
        if let last = merged.last,
           last.dayIndex == block.dayIndex,
           last.courseName == block.courseName,
           last.classroom == block.classroom,
           block.startMinutes - last.endMinutes <= 20 {
            merged[merged.count - 1] = WeekCourseBlock(
                id: last.id,
                dayIndex: last.dayIndex,
                dayLabel: last.dayLabel,
                courseName: last.courseName,
                classroom: last.classroom,
                startMinutes: last.startMinutes,
                endMinutes: block.endMinutes,
                startLabel: last.startLabel,
                endLabel: block.endLabel,
                colorStyle: last.colorStyle
            )
        } else {
            merged.append(block)
        }
    }

    return merged
}

private func weekTimeRangeText(for blocks: [WeekCourseBlock]) -> String {
    let bounds = weekTimeBounds(for: blocks)
    return "\(timeText(for: bounds.start))–\(timeText(for: bounds.end))"
}

private func timeText(for minutes: Int) -> String {
    let clamped = max(0, min(24 * 60, minutes))
    let hour = clamped / 60
    let minute = clamped % 60
    return String(format: "%02d:%02d", hour, minute)
}

private func weekTimeBounds(for blocks: [WeekCourseBlock]) -> (start: Int, end: Int) {
    guard let earliest = blocks.map(\.startMinutes).min(),
          let latest = blocks.map(\.endMinutes).max() else {
        return (8 * 60, 18 * 60)
    }

    let minimumSpan = 6 * 60
    var start = max(0, (earliest / 60) * 60)
    var end = min(24 * 60, ((latest + 59) / 60) * 60)

    if end - start < minimumSpan {
        end = min(24 * 60, start + minimumSpan)
    }

    if end - start < minimumSpan {
        start = max(0, end - minimumSpan)
    }

    return (start, end)
}

private struct WeekGridLayout {
    let containerSize: CGSize
    let dayCount: Int
    let visibleStartMinutes: Int
    let visibleEndMinutes: Int

    let timeAxisWidth: CGFloat = 38
    let headerHeight: CGFloat = 42
    let gridTopPadding: CGFloat = 0
    let horizontalPadding: CGFloat = 0
    let bottomPadding: CGFloat = 0

    init(containerSize: CGSize, dayCount: Int, blocks: [WeekCourseBlock]) {
        self.containerSize = containerSize
        self.dayCount = dayCount

        let bounds = weekTimeBounds(for: blocks)
        visibleStartMinutes = bounds.start
        visibleEndMinutes = bounds.end
    }

    var gridHeight: CGFloat {
        max(180, containerSize.height - headerHeight - bottomPadding)
    }

    var hourRowHeight: CGFloat {
        gridHeight / CGFloat(max(visibleHourCount, 1))
    }

    var dayColumnWidth: CGFloat {
        let available = max(120, containerSize.width - horizontalPadding * 2 - timeAxisWidth)
        return available / CGFloat(max(dayCount, 1))
    }

    var visibleHourCount: Int {
        max(1, (visibleEndMinutes - visibleStartMinutes) / 60)
    }

    var hourMarks: [String] {
        stride(from: visibleStartMinutes, to: visibleEndMinutes, by: 60).map(Self.timeLabel)
    }

    func frame(for block: WeekCourseBlock) -> CGRect {
        let x = timeAxisWidth + CGFloat(block.dayIndex) * dayColumnWidth + 0.5
        let startOffset = CGFloat(block.startMinutes - visibleStartMinutes) / 60.0 * hourRowHeight
        let duration = CGFloat(block.endMinutes - block.startMinutes) / 60.0 * hourRowHeight
        let availableHeight = max(0, gridHeight - startOffset - 1)
        let minimumHeight = min(22, max(16, hourRowHeight - 2))
        let preferredHeight = max(minimumHeight, duration - 1)
        return CGRect(
            x: x,
            y: startOffset + 0.5,
            width: dayColumnWidth - 1,
            height: min(availableHeight, preferredHeight)
        )
    }

    func todayColumnIndex(days: [WeekDaySummary]) -> Int? {
        days.firstIndex(where: { $0.isToday })
    }
    private static func timeLabel(for minutes: Int) -> String {
        let hour = minutes / 60
        return String(format: "%02d:00", hour)
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

    var endLabel: String {
        let parts = timeRange.components(separatedBy: CharacterSet(charactersIn: "~-"))
        guard parts.count >= 2 else { return "" }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func contains(now: Date) -> Bool {
        guard let startMinutes, let endMinutes else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        guard let hour = comps.hour, let minute = comps.minute else { return false }
        let current = hour * 60 + minute
        return startMinutes <= current && current < endMinutes
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
    let teacher: String?
}

private struct WidgetRemoteAcademicCalendar: Decodable {
    let pages: [WidgetRemoteAcademicCalendarPage]
}

private struct WidgetBundledAcademicCalendar: Decodable {
    let calendars: [WidgetBundledSemester]
}

private struct WidgetBundledSemester: Decodable {
    let events: [WidgetCalendarEvent]
}

private struct WidgetRemoteAcademicCalendarPage: Decodable {
    let events: [WidgetCalendarEvent]
}

private struct WidgetCalendarEvent: Decodable {
    let title: String
    let startDate: String
    let endDate: String?

    enum CodingKeys: String, CodingKey {
        case title
        case startDate
        case endDate
        case description
        case start_date
        case end_date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title))
            ?? (try? container.decode(String.self, forKey: .description))
            ?? "未命名事件"
        startDate = (try? container.decode(String.self, forKey: .startDate))
            ?? (try? container.decode(String.self, forKey: .start_date))
            ?? "1970-01-01"
        endDate = (try? container.decodeIfPresent(String.self, forKey: .endDate))
            ?? (try? container.decodeIfPresent(String.self, forKey: .end_date))
    }

    var start: Date? {
        Self.formatter.date(from: startDate)
    }

    var end: Date? {
        Self.formatter.date(from: endDate ?? startDate)
    }

    var isMultiDay: Bool {
        endDate != nil && endDate != startDate
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private extension String {
    var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

#Preview(as: .systemSmall) {
    NIU_CompactWidget()
} timeline: {
    NIUWidgetEntry(
        date: .now,
        payload: .placeholder(for: .classSchedule)
    )
}

#Preview("Calendar", as: .systemMedium) {
    NIU_CompactWidget()
} timeline: {
    NIUWidgetEntry(
        date: .now,
        payload: .placeholder(for: .academicCalendar)
    )
}

#Preview("Week", as: .systemLarge) {
    NIU_LiveActivities()
} timeline: {
    NIUWidgetEntry(
        date: .now,
        payload: .placeholder(for: .weeklyTimetable)
    )
}
