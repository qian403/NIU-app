import SwiftUI

struct AcademicCalendarView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = AcademicCalendarViewModel()
    @State private var presentedEvent: PresentedEvent?
    @State private var searchText = ""
    @State private var selectedFilter: CalendarEventType?
    @State private var scrollMinY: CGFloat = 0
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()
                mainContent
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: viewModel.currentSemester) {
                await viewModel.reload()
            }
            .task {
                // Keep a visible calendar current across midnight, including January and August.
                viewModel.handleDateChange() // task(id:) loads a changed year.
                while !Task.isCancelled {
                    let delay = max(1, CampusCalendarDate.tomorrow(after: Date()).timeIntervalSinceNow)
                    do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                    guard !Task.isCancelled else { break }
                    if !viewModel.handleDateChange() { await viewModel.reload() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { if !viewModel.handleDateChange() { await viewModel.reload() } }
                }
            }
            .sheet(item: $presentedEvent) { item in
                CalendarEventDetailSheet(event: item.event)
            }
        }
    }
    
    // MARK: - Main Content
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            topHeader
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.top, 6)
                .padding(.bottom, 2)
            
            // 事件列表
            if viewModel.currentCalendar != nil {
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.medium, pinnedViews: [.sectionHeaders]) {
                        Section {
                            // Track scroll offset for compact search style.
                            Color.clear
                                .frame(height: 0)
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear
                                            .preference(
                                                key: CalendarScrollOffsetPreferenceKey.self,
                                                value: proxy.frame(in: .named("calendarScroll")).minY
                                            )
                                    }
                                )

                            // 即將到來的事件（如果有）
                            if shouldShowUpcomingSection {
                                upcomingEventsSection
                            }
                            
                            // 按月份顯示事件
                            if let month = viewModel.selectedMonth {
                                monthEventsSection(month: month, events: eventsByDisplayedMonth[month] ?? [])
                            } else {
                                // 顯示所有月份
                                ForEach(displayedMonths, id: \.self) { month in
                                    monthEventsSection(month: month, events: eventsByDisplayedMonth[month] ?? [])
                                }
                            }

                            if displayedMonths.isEmpty { emptyResultView }
                            VStack(spacing: 6) {
                                if viewModel.isLoading { ProgressView() }
                                Text(viewModel.sourceLabel)
                                Text("下拉可更新行事曆")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        } header: {
                            stickyControlsHeader
                        }
                    }
                }
                .coordinateSpace(name: "calendarScroll")
                .onPreferenceChange(CalendarScrollOffsetPreferenceKey.self) { value in
                    scrollMinY = value
                }
                .refreshable {
                    await viewModel.reload(force: true)
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        if viewModel.isLoading {
                            ProgressView("載入行事曆中…")
                        } else {
                            Image(systemName: "calendar.badge.exclamationmark").font(.largeTitle)
                            Text(viewModel.statusMessage ?? "尚未取得此學年度資料")
                                .multilineTextAlignment(.center)
                            if viewModel.isNotPublished {
                                Text("可切換學年度查看已公布資料")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button("重新整理") { Task { await viewModel.reload(force: true) } }
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await viewModel.reload(force: true) }
            }
        }
    }

    private var stickyControlsHeader: some View {
        VStack(spacing: 0) {
            searchAndFilterSection
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.bottom, 4)

            monthSelector
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.bottom, 4)
        }
        .background(Theme.Colors.background)
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var topHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(headerMonthTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Theme.Colors.primary)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Colors.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if shouldShowYearPicker {
                semesterPicker
            }
        }
    }

    private var headerMonthTitle: String {
        if let month = viewModel.selectedMonth {
            return monthName(month)
        }
        return viewModel.displayTitle
    }

    private var headerSubtitle: String {
        let parts: [String] = [viewModel.displayPeriodLabel, viewModel.sourceLabel]
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ・ ")
    }

    private var shouldShowYearPicker: Bool {
        viewModel.availableYears.count > 1
    }
    
    // MARK: - Components
    
    private var monthSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                MonthButton(
                    title: "全部",
                    isSelected: viewModel.selectedMonth == nil,
                    compact: true
                ) {
                    viewModel.selectedMonth = nil
                }
                
                if let calendar = viewModel.currentCalendar {
                    ForEach(calendar.monthsWithEvents, id: \.self) { month in
                        MonthButton(
                            title: monthName(month),
                            isSelected: viewModel.selectedMonth == month,
                            compact: true
                        ) {
                            viewModel.selectMonth(month)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
        .defaultScrollAnchor(.leading)
    }
    
    private var semesterPicker: some View {
        Menu {
            ForEach(viewModel.availableYears, id: \.self) { year in
                Button {
                    viewModel.switchSemester(to: String(year))
                } label: {
                    HStack {
                        Text("\(year) 學年度")
                        if String(year) == viewModel.currentSemester { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(viewModel.currentSemester)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(Theme.Colors.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.gray.opacity(0.12))
            )
        }
    }

    private var searchAndFilterSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Colors.tertiaryText)
                TextField("搜尋活動、關鍵字", text: $searchText)
                    .font(.system(size: isSearchCompact ? 12 : 13))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.Colors.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, isSearchCompact ? 6 : 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.12))
            )

            if let first = viewModel.todayEvents.first,
               searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               selectedFilter == nil {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.orange)
                    Text(first.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.Colors.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    EventTypeChip(
                        title: "全部",
                        isSelected: selectedFilter == nil
                    ) { selectedFilter = nil }

                    ForEach(CalendarEventType.allCases, id: \.self) { type in
                        EventTypeChip(
                            title: type.rawValue,
                            isSelected: selectedFilter == type
                        ) {
                            selectedFilter = (selectedFilter == type ? nil : type)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            }
            .defaultScrollAnchor(.leading)
        }
    }

    private var isSearchCompact: Bool {
        scrollMinY < -10
    }
    
    private var upcomingEventsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.orange)
                Text("即將到來")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.Colors.primary)
            }
            .padding(.horizontal, Theme.Spacing.small)
            
            ForEach(Array(filteredUpcomingEvents.prefix(3).enumerated()), id: \.offset) { _, event in
                CalendarEventCard(event: event) {
                    presentedEvent = PresentedEvent(event: event)
                }
            }
        }
    }

    
    private func monthEventsSection(month: Int, events: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(monthName(month))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Theme.Colors.primary)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.top, Theme.Spacing.small)
            
            if events.isEmpty {
                EmptyView()
            } else {
                ForEach(events) { event in
                    CalendarEventCard(event: event) {
                        presentedEvent = PresentedEvent(event: event)
                    }
                }
            }
        }
    }
    
    private var emptyResultView: some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.gray)
            Text("沒有符合目前篩選條件的事件")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.large)
    }
    
    // MARK: - Helper Methods
    
    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        return formatter.monthSymbols[month - 1]
    }

    private var filteredEvents: [CalendarEvent] {
        var events = viewModel.allEvents

        if let selectedFilter {
            events = events.filter { $0.inferredType == selectedFilter }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            events = events.filter {
                $0.title.lowercased().contains(query) ||
                ($0.description?.lowercased().contains(query) ?? false)
            }
        }

        if let selectedMonth = viewModel.selectedMonth {
            events = events.filter {
                $0.months.contains(selectedMonth)
            }
        }

        return events.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    private var eventsByDisplayedMonth: [Int: [CalendarEvent]] {
        var grouped: [Int: [CalendarEvent]] = [:]
        for event in filteredEvents {
            for month in event.months { grouped[month, default: []].append(event) }
        }
        return grouped
    }

    private var displayedMonths: [Int] {
        CampusCalendarDate.monthOrder.filter { eventsByDisplayedMonth[$0] != nil }
    }

    private var filteredUpcomingEvents: [CalendarEvent] {
        let now = CampusCalendarDate.calendar.startOfDay(for: Date())
        let thirtyDaysLater = CampusCalendarDate.calendar.date(byAdding: .day, value: 30, to: now) ?? now
        return filteredEvents.filter {
            guard let start = $0.start else { return false }
            return start >= now && start <= thirtyDaysLater
        }
    }

    private var shouldShowUpcomingSection: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        selectedFilter == nil &&
        viewModel.selectedMonth == nil &&
        !filteredUpcomingEvents.isEmpty
    }
}

private struct CalendarScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PresentedEvent: Identifiable {
    let id = UUID()
    let event: CalendarEvent
}

// MARK: - Month Button Component

struct MonthButton: View {
    let title: String
    let isSelected: Bool
    let compact: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 12 : 14, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? Color(.systemBackground) : Theme.Colors.primary)
                .frame(minWidth: compact ? (title == "全部" ? 50 : 40) : nil)
                .padding(.horizontal, compact ? 0 : 16)
                .padding(.vertical, compact ? 8 : 8)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isSelected ? Theme.Colors.primary : Color(.secondarySystemFill))
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct EventTypeChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? Color(.systemBackground) : Theme.Colors.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? Theme.Colors.primary : Color(.secondarySystemFill))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    AcademicCalendarView()
}
