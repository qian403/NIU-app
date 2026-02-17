import SwiftUI

struct AcademicCalendarView: View {
    @StateObject private var viewModel = AcademicCalendarViewModel()
    @State private var presentedEvent: PresentedEvent?
    @State private var searchText = ""
    @State private var selectedFilter: CalendarEventType?
    
    var body: some View {
        NavigationView {
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
            .navigationTitle("學年度行事曆")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    semesterPicker
                }
            }
            .onAppear {
                // 優先從公開 URL 載入，失敗再 fallback（Firebase/本地）
                viewModel.loadFromConfiguredSources()
            }
            .sheet(item: $presentedEvent) { item in
                CalendarEventDetailSheet(event: item.event)
            }
        }
        .preferredColorScheme(.light)
    }
    
    // MARK: - Main Content
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            // 月份選擇器
            monthSelector
                .padding(.horizontal)
                .padding(.vertical, Theme.Spacing.small)
            
            Divider()
            
            // 事件列表
            if let calendar = viewModel.currentCalendar {
                ScrollView {
                    VStack(spacing: Theme.Spacing.medium) {
                        // 即將到來的事件（如果有）
                        if !viewModel.upcomingEvents.isEmpty {
                            upcomingEventsSection
                        }
                        
                        // 按月份顯示事件
                        if let month = viewModel.selectedMonth {
                            monthEventsSection(month: month)
                        } else {
                            // 顯示所有月份
                            ForEach(calendar.monthsWithEvents, id: \.self) { month in
                                monthEventsSection(month: month)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                emptyStateView
            }
        }
    }
    
    // MARK: - Components
    
    private var monthSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.small) {
                // "全部" 按鈕
                MonthButton(
                    title: "全部",
                    isSelected: viewModel.selectedMonth == nil
                ) {
                    viewModel.selectMonth(0)
                    viewModel.selectedMonth = nil
                }
                
                // 月份按鈕
                if let calendar = viewModel.currentCalendar {
                    ForEach(calendar.monthsWithEvents, id: \.self) { month in
                        MonthButton(
                            title: monthName(month),
                            isSelected: viewModel.selectedMonth == month
                        ) {
                            viewModel.selectMonth(month)
                        }
                    }
                }
            }
        }
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
        }
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
            
            ForEach(Array(viewModel.upcomingEvents.prefix(3).enumerated()), id: \.offset) { _, event in
                CalendarEventCard(event: event) {
                    presentedEvent = PresentedEvent(event: event)
                }
            }
        }
    }
    
    private func monthEventsSection(month: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(monthName(month))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Theme.Colors.primary)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.top, Theme.Spacing.small)
            
            if let events = viewModel.currentCalendar?.eventsByMonth[month] {
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
                    .foregroundColor(.white)
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
    
    // MARK: - Helper Methods
    
    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        return formatter.monthSymbols[month - 1]
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
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : Theme.Colors.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isSelected ? Theme.Colors.primary : Color.gray.opacity(0.2))
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Preview

#Preview {
    AcademicCalendarView()
}
