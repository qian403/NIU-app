import SwiftUI

struct AcademicCalendarView: View {
    @StateObject private var viewModel = AcademicCalendarViewModel()
    @State private var presentedEvent: PresentedEvent?
    @State private var searchText = ""
    @State private var selectedFilter: CalendarEventType?
    @State private var scrollMinY: CGFloat = 0
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()
                if viewModel.isLoading {
                    loadingView
                } else if let errorMessage = viewModel.errorMessage {
                    errorView(message: errorMessage)
                } else {
                    mainContent
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // 優先從公開 URL 載入，失敗再 fallback（Firebase/本地）
                viewModel.loadFromConfiguredSources()
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
                .padding(.horizontal)
                .padding(.top, Theme.Spacing.small)
                .padding(.bottom, 6)
            
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

                            if displayedMonths.isEmpty {
                                emptyResultView
                            }
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
                    viewModel.loadFromConfiguredSources()
                }
            } else {
                emptyStateView
            }
        }
    }

    private var stickyControlsHeader: some View {
        VStack(spacing: 0) {
            monthSelector
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, 8)

            searchAndFilterSection
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.small)
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerMonthTitle)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(Theme.Colors.primary)
                    .lineLimit(1)
                Text(viewModel.currentSemester)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.Colors.secondaryText)
            }

            Spacer(minLength: 8)
            semesterPicker
        }
    }

    private var headerMonthTitle: String {
        if let month = viewModel.selectedMonth {
            return monthName(month)
        }
        return "全部行程"
    }
    
    // MARK: - Components
    
    private var monthSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .defaultScrollAnchor(.leading)
    }
    
    private var semesterPicker: some View {
        Menu {
            if let calendars = viewModel.calendarData?.calendars {
                ForEach(calendars, id: \.semester) { calendar in
                    Button(action: {
                        viewModel.switchSemester(to: calendar.semester)
                    }) {
                        HStack {
                            Text(calendar.semester)
                            if calendar.semester == viewModel.currentSemester {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.currentSemester)
                    .font(.system(size: 14, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 12))
            }
            .foregroundColor(Theme.Colors.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.gray.opacity(0.12))
            )
        }
    }

    private var searchAndFilterSection: some View {
        VStack(spacing: Theme.Spacing.small) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.Colors.tertiaryText)
                TextField("搜尋活動、關鍵字", text: $searchText)
                    .font(.system(size: isSearchCompact ? 13 : 14))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.Colors.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isSearchCompact ? 7 : 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.12))
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
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
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
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
                // Use index as identity to avoid missing rows when upstream data has duplicate `event.id`.
                ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                    CalendarEventCard(event: event) {
                        presentedEvent = PresentedEvent(event: event)
                    }
                }
            }
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: Theme.Spacing.medium) {
            ProgressView()
            Text("載入行事曆中...")
                .font(.system(size: 14, weight: .light))
                .foregroundColor(.gray)
        }
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.orange)
            
            Text(message)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(Theme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: {
                viewModel.loadFromLocalFile()
            }) {
                Text("使用本地資料")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(.systemBackground))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Theme.Colors.primary)
                    .cornerRadius(8)
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.gray)
            
            Text("目前沒有行事曆資料")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                guard let start = $0.start else { return false }
                return Calendar.current.component(.month, from: start) == selectedMonth
            }
        }

        return events.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    private var eventsByDisplayedMonth: [Int: [CalendarEvent]] {
        Dictionary(grouping: filteredEvents) { event in
            guard let start = event.start else { return 0 }
            return Calendar.current.component(.month, from: start)
        }
    }

    private var displayedMonths: [Int] {
        eventsByDisplayedMonth.keys.filter { $0 > 0 }.sorted()
    }

    private var filteredUpcomingEvents: [CalendarEvent] {
        let now = Date()
        let thirtyDaysLater = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
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
                .font(.system(size: compact ? 13 : 14, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? Color(.systemBackground) : Theme.Colors.primary)
                .frame(minWidth: compact ? (title == "全部" ? 56 : 44) : nil)
                .padding(.horizontal, compact ? 0 : 16)
                .padding(.vertical, compact ? 10 : 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
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
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? Color(.systemBackground) : Theme.Colors.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
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
