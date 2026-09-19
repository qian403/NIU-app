import SwiftUI

private enum CalendarDisplayMode: String, CaseIterable, Identifiable {
    case month
    case events

    var id: String { rawValue }
    var title: String { self == .month ? "月曆" : "事件" }
}

struct AcademicCalendarView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("academicCalendar.displayMode") private var displayMode = CalendarDisplayMode.month
    @StateObject private var viewModel = AcademicCalendarViewModel()
    @State private var presentedEvent: CalendarEvent?
    @State private var searchText = ""
    @State private var selectedFilter: CalendarEventType?
    @State private var selectedDay: Int?
    @State private var scrollPosition = ScrollPosition(edge: .top)

    private var month: AcademicCalendarMonth {
        AcademicCalendarMonth(academicYear: Int(viewModel.currentSemester)!, month: viewModel.selectedMonth ?? 8)
    }
    private var selection: Date { month.selectedDate(day: selectedDay) }
    private var monthID: String { "\(viewModel.currentSemester)-\(viewModel.selectedMonth ?? 8)" }
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var categoryEvents: [CalendarEvent] {
        viewModel.allEvents.filter { selectedFilter == nil || $0.type == selectedFilter }
    }
    private var searchResults: [CalendarEvent] {
        categoryEvents.filter {
            $0.title.localizedStandardContains(query) || $0.displayTitle.localizedStandardContains(query) ||
            ($0.description?.localizedStandardContains(query) ?? false) ||
            ($0.sourceText?.localizedStandardContains(query) ?? false)
        }
    }
    private var dailyEvents: [CalendarEvent] { categoryEvents.filter { $0.contains(selection) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("顯示方式", selection: $displayMode) {
                    ForEach(CalendarDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                scopeControls
                if query.isEmpty {
                    if displayMode == .month { monthCalendar }
                    else { monthNavigation }
                }
                if viewModel.currentCalendar != nil {
                    if let notice = viewModel.statusMessage {
                        Label(notice, systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if query.isEmpty && displayMode == .events { monthlyAgenda }
                    else { agenda }
                    syncFooter
                } else {
                    unavailableContent
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition)
        .background(Theme.Colors.background)
        .navigationTitle("行事曆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(displayMode == .month ? "今天" : "本月", action: returnToToday)
                    .accessibilityHint(displayMode == .month ? "清除搜尋與分類篩選，回到今天的事件" : "清除搜尋與分類篩選，回到本月事件")
            }
        }
        .searchable(text: $searchText, prompt: "搜尋此學年度的事件")
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await viewModel.reload(force: true) }
        .task(id: viewModel.currentSemester) { await viewModel.reload() }
        .task {
            viewModel.handleDateChange()
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
        .onChange(of: monthID) { _, _ in selectedDay = nil }
        .onChange(of: displayMode) { _, _ in scrollPosition.scrollTo(edge: .top) }
        .sheet(item: $presentedEvent) { event in
            CalendarEventDetailSheet(event: event)
        }
    }

    private var scopeControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack { yearPicker; Spacer(minLength: 12); categoryPicker }
            VStack(alignment: .leading, spacing: 4) { yearPicker; categoryPicker }
        }
    }

    private var yearPicker: some View {
        Menu {
            ForEach(Array(Set(viewModel.availableYears + [Int(viewModel.currentSemester)!])).sorted(by: >), id: \.self) { year in
                Button {
                    viewModel.switchSemester(to: String(year))
                } label: {
                    if String(year) == viewModel.currentSemester {
                        Label("\(String(year)) 學年度", systemImage: "checkmark")
                    } else {
                        Text("\(String(year)) 學年度")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("\(viewModel.currentSemester) 學年度").font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityLabel("切換學年度，目前 \(viewModel.currentSemester) 學年度")
    }

    private var categoryPicker: some View {
        Menu {
            Picker("事件分類", selection: $selectedFilter) {
                Text("全部類別").tag(Optional<CalendarEventType>.none)
                ForEach(CalendarEventType.allCases, id: \.self) { type in
                    Label(type.rawValue, systemImage: type.icon).tag(Optional(type))
                }
            }
        } label: {
            Label(selectedFilter?.rawValue ?? "全部類別", systemImage: "line.3.horizontal.decrease")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(selectedFilter == nil ? Color(.secondarySystemBackground) : Color.primary.opacity(0.1),
                            in: Capsule())
        }
        .tint(.primary)
        .accessibilityLabel("篩選事件，目前\(selectedFilter?.rawValue ?? "全部類別")")
    }

    private var monthNavigation: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CampusCalendarDate.format(month.start, "yyyy 年"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(CampusCalendarDate.format(month.start, "M 月"))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            monthArrow("chevron.left", label: "上個月", offset: -1)
            monthArrow("chevron.right", label: "下個月", offset: 1)
        }
    }

    private var monthCalendar: some View {
        VStack(spacing: 16) {
            monthNavigation

            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(Array(["日", "一", "二", "三", "四", "五", "六"].enumerated()), id: \.offset) { index, day in
                        Text(day)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                    ForEach(Array(month.cells.enumerated()), id: \.offset) { _, date in
                        if let date { dayButton(date) }
                        else { Color.clear.frame(minHeight: 46).accessibilityHidden(true) }
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { dayLegend; periodLegend }
                VStack(alignment: .leading, spacing: 8) { dayLegend; periodLegend }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dayLegend: some View {
        HStack(spacing: 6) {
            Circle().fill(.secondary).frame(width: 4, height: 4)
            Text("當日事項")
        }
    }

    private var periodLegend: some View {
        HStack(spacing: 6) {
            Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 5, height: 5)
            Text("期間進行中")
        }
    }

    private func monthArrow(_ symbol: String, label: String, offset: Int) -> some View {
        Button {
            guard let date = CampusCalendarDate.calendar.date(byAdding: .month, value: offset, to: month.start) else { return }
            viewModel.switchSemester(to: String(CampusCalendarDate.academicYear(at: date)))
            viewModel.selectMonth(CampusCalendarDate.calendar.component(.month, from: date))
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func dayButton(_ date: Date) -> some View {
        let calendar = CampusCalendarDate.calendar
        let isSelected = calendar.isDate(date, inSameDayAs: selection)
        let isToday = calendar.isDate(date, inSameDayAs: Date())
        let events = categoryEvents.filter { $0.contains(date) }
        let boundaries = events.filter { $0.isBoundary(on: date) }.count
        let ongoing = events.count - boundaries
        let foreground = isSelected ? Color(.systemBackground) : Color.primary
        return Button {
            selectedDay = calendar.component(.day, from: date)
        } label: {
            VStack(spacing: 4) {
                Text(CampusCalendarDate.format(date, "d"))
                    .font(.body.weight(isSelected || isToday ? .bold : .regular))
                    .monospacedDigit()
                HStack(spacing: 3) {
                    ForEach(0..<min(boundaries, 3), id: \.self) { _ in
                        Circle().frame(width: 3, height: 3)
                    }
                    if ongoing > 0 { Circle().strokeBorder(foreground, lineWidth: 1).frame(width: 4, height: 4) }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(isSelected ? Color.primary : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if isToday && !isSelected {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.4), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(CampusCalendarDate.format(date, "M月d日 EEEE"))\(isToday ? "，今天" : "")")
        .accessibilityValue(viewModel.currentCalendar == nil ? "事件資料尚未取得" : "\(boundaries) 個當日事項，\(ongoing) 個期間進行中")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var agenda: some View {
        let events = query.isEmpty ? dailyEvents : searchResults
        let boundaries = dailyEvents.filter { $0.isBoundary(on: selection) }
        let ongoing = dailyEvents.filter { !$0.isBoundary(on: selection) }
        return VStack(alignment: .leading, spacing: 16) {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(query.isEmpty ? CampusCalendarDate.format(selection, "M月d日 EEEE") : "搜尋結果")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(query.isEmpty ? "\(boundaries.count) 個當日事項 · \(ongoing.count) 個期間進行中"
                     : "\(viewModel.currentSemester) 學年度 · \(events.count) 個符合的事件")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if events.isEmpty {
                emptyAgenda
            } else if !query.isEmpty {
                eventList(events)
            } else {
                if !boundaries.isEmpty { eventList(boundaries) }
                if !ongoing.isEmpty {
                    Label("期間進行中", systemImage: "calendar.badge.clock")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, boundaries.isEmpty ? 0 : 8)
                        .accessibilityAddTraits(.isHeader)
                    eventList(ongoing)
                }
            }
        }
    }

    private var monthlyAgenda: some View {
        let sections = month.eventSections(categoryEvents)
        let count = sections.reduce(0) { $0 + $1.events.count }
        return VStack(alignment: .leading, spacing: 20) {
            Text("本月共 \(count) 個事件 · 跨日事件僅列一次")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if sections.isEmpty {
                emptyAgenda
            } else {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            if let date = section.date {
                                Text(CampusCalendarDate.format(date, "M月d日 EEEE"))
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("跨月期間", systemImage: "calendar.badge.clock")
                                        .font(.headline)
                                        .accessibilityAddTraits(.isHeader)
                                    Text("先前開始，持續至本月的事件")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            eventList(section.events)
                        }
                    }
                }
            }
        }
    }

    private func eventList(_ events: [CalendarEvent]) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(events) { event in
                CalendarEventCard(event: event, context: eventContext(event)) { presentedEvent = event }
            }
        }
    }

    private func eventContext(_ event: CalendarEvent) -> String? {
        guard query.isEmpty, displayMode == .month, event.isMultiDay else { return nil }
        let key = CampusCalendarDate.dayKey(selection)
        if key == event.startDate { return "本日開始" }
        if key == event.endDate { return "本日結束" }
        return nil
    }

    private var emptyAgenda: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(query.isEmpty ? "\(displayMode == .month ? "這天" : "這個月")沒有\(selectedFilter?.rawValue ?? "校曆")事件" : "找不到符合的事件",
                  systemImage: query.isEmpty ? "calendar" : "magnifyingglass")
                .font(.headline)
            Text(query.isEmpty ? (displayMode == .month ? "可點選其他日期，或切換月份查看。" : "可切換月份，或調整分類查看其他事件。") : "試試「選課」「期中」等關鍵字，或調整分類。")
                .font(.subheadline).foregroundStyle(.secondary)
            if selectedFilter != nil {
                Button("顯示全部類別") { selectedFilter = nil }.frame(minHeight: 44)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isLoading {
                ProgressView("載入行事曆中…").frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                Label(viewModel.isNotPublished ? "此學年度尚未公布" : "暫時無法取得行事曆", systemImage: "calendar.badge.exclamationmark")
                    .font(.headline)
                Text(viewModel.statusMessage ?? "請稍後再試，或切換學年度查看已公布的資料。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("重新整理") { Task { await viewModel.reload(force: true) } }
                    .frame(minHeight: 44)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var syncFooter: some View {
        VStack(spacing: 6) {
            if viewModel.isLoading { ProgressView().accessibilityLabel("正在更新行事曆") }
            Text(viewModel.sourceLabel)
            Label("下拉更新行事曆", systemImage: "arrow.down")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func returnToToday() {
        let now = Date()
        searchText = ""
        selectedFilter = nil
        viewModel.handleDateChange(now: now)
        viewModel.switchSemester(to: String(CampusCalendarDate.academicYear(at: now)))
        viewModel.selectMonth(CampusCalendarDate.calendar.component(.month, from: now))
        selectedDay = CampusCalendarDate.calendar.component(.day, from: now)
        scrollPosition.scrollTo(edge: .top)
    }
}

#Preview {
    NavigationStack { AcademicCalendarView() }
}
