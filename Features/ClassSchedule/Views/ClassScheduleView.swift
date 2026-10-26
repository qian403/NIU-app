import SwiftUI

struct ClassScheduleView: View {
    @StateObject private var vm = ClassScheduleViewModel()
    @State private var showSettings = false
    @State private var editorRequest: CustomCourseEditorRequest?
    @State private var pagerSelection: Int = 1
    @State private var campusPlans: CampusFloorPlans?
    @State private var campusMapRequest: CampusPlanRequest?
    @AppStorage("classSchedule.displayMode") private var displayMode = "day"

    // Classmates' timetables, shown in place of the user's own.
    @ObservedObject private var exchangeStore: ScheduleExchangeStore
    @StateObject private var exchange: ScheduleExchangeViewModel
    @State private var viewingID: UUID?
    @State private var marksFreeTime = true
    @State private var showsClassmates = false
    @State private var showsMyCode = false
    @State private var showsScanner = false
    @State private var afterClassmates: ClassmateAction?
    @State private var exchangeToast: String?
    /// Classmates compared together on the user's own timetable; empty when not comparing.
    @State private var comparingIDs: Set<UUID> = []
    @State private var compareSetup: CompareSetupRequest?

    private enum ClassmateAction { case scan, myCode, compare }

    private struct CompareSetupRequest: Identifiable {
        let id = UUID()
        let selected: Set<UUID>
    }

    /// `opensClassmates` shows the classmate picker on arrival, for the home-screen shortcut.
    init(opensClassmates: Bool = false) {
        let store = ScheduleExchangeStore.shared
        exchangeStore = store
        _exchange = StateObject(wrappedValue: ScheduleExchangeViewModel(schedule: nil, store: store))
        _showsClassmates = State(initialValue: opensClassmates)
    }

    #if DEBUG
    init(fixtureSchedule: ClassSchedule, defaults: UserDefaults) {
        let model = ClassScheduleViewModel(customCourses: CustomCourseStore(fixtureDefaults: defaults))
        model.schedule = fixtureSchedule
        model.loadState = .fresh
        model.selectedDayIndex = model.todayDayIndex
        _vm = StateObject(wrappedValue: model)
        _pagerSelection = State(initialValue: model.selectedDayIndex + 1)
        _displayMode = AppStorage(wrappedValue: "day", "classSchedule.displayMode", store: defaults)
        let store = ClassScheduleUIFixture.exchangeStore
        exchangeStore = store
        _exchange = StateObject(wrappedValue: ScheduleExchangeViewModel(schedule: fixtureSchedule, store: store))
        _showsClassmates = State(initialValue: ClassScheduleUIFixture.scenario == "exchange")
        _showsMyCode = State(initialValue: ClassScheduleUIFixture.scenario == "exchange-share")
    }
    #endif

    private var showsWeek: Bool { displayMode == "week" }

    /// The classmate being viewed; nil shows the user's own timetable.
    private var viewing: ExchangedSchedule? {
        viewingID.flatMap { id in exchangeStore.schedules.first { $0.id == id } }
    }

    /// Classmates in the group comparison that still exist and belong to the current term.
    private var comparing: [ExchangedSchedule] {
        let term = exchange.currentTerm
        return exchangeStore.schedules
            .filter { comparingIDs.contains($0.id) && $0.payload.term == term }
            .sorted { $0.displayName < $1.displayName }
    }

    /// The user's timetable as shown, custom courses included, so their own commitments count as busy.
    /// Only for local comparison; nothing built here is shared.
    private func myComparisonPayload(for term: ScheduleShareTerm) -> ScheduleSharePayload? {
        guard term == exchange.currentTerm, let schedule = vm.displaySchedule else { return nil }
        return ScheduleSharePayload(schedule: schedule, shareID: UUID(), term: term, nickname: "我",
                                    includeRooms: false, includeTeachers: false, createdAt: Date())
    }

    private func refreshSchedule() async {
        #if DEBUG
        if ClassScheduleUIFixture.requested { return }
        #endif
        await vm.refreshAndWait()
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                if let viewing {
                    classmateContent(viewing)
                } else if !comparing.isEmpty, let schedule = vm.displaySchedule {
                    groupContent(schedule: schedule, classmates: comparing)
                } else {
                switch vm.loadState {
                case .idle:
                    EmptyView()

                case .loading:
                    fullScreenLoading

                case .cached, .fresh:
                    if let schedule = vm.displaySchedule {
                        scheduleContent(schedule: schedule)
                    }

                case .error(let msg):
                    errorView(message: msg)
                }
                }
            }

            // Invisible WebView for background data fetching
            if vm.showWebView {
                let generation = vm.loadGeneration
                ClassScheduleWebView { result in
                    vm.handleWebResult(result, generation: generation)
                }
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                titleSwitcher
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if vm.schedule != nil, viewingID == nil {
                    Button {
                        #if DEBUG
                        if ClassScheduleUIFixture.requested { return }
                        #endif
                        vm.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(vm.isRefreshing)
                    .accessibilityLabel("更新課表")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if vm.schedule != nil, viewingID == nil {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .accessibilityLabel("課表設定")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if viewingID == nil, !showsWeek, vm.schedule != nil, let today = vm.actualTodayDayIndex,
                   vm.selectedDayIndex != today {
                    Button {
                        vm.selectedDayIndex = today
                    } label: {
                        Image(systemName: "calendar.circle")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel("返回今天")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            if let schedule = vm.schedule {
                ClassScheduleSettingsView(schedule: schedule, store: vm.customCourses, today: vm.referenceDate)
            }
        }
        .sheet(item: $editorRequest) { request in
            if let schedule = vm.schedule {
                CustomCourseEditorView(schedule: schedule, store: vm.customCourses, request: request,
                                       today: vm.referenceDate)
            }
        }
        .onAppear {
            if vm.loadState == .idle || (vm.schedule == nil && !vm.showWebView) {
                vm.loadSchedule()
            }
        }
        .onDisappear {
            vm.cancelLoading()
            exchange.cancelAll()
        }
        .task(id: vm.schedule?.fetchedAt) { exchange.schedule = vm.schedule }
        .onAppear {
            exchangeStore.reload()
            #if DEBUG
            if ClassScheduleUIFixture.scenario == "exchange-friend", viewingID == nil {
                viewingID = exchangeStore.schedules.sorted { $0.displayName < $1.displayName }.first?.id
            }
            if ClassScheduleUIFixture.scenario == "exchange-group", comparingIDs.isEmpty {
                comparingIDs = Set(exchangeStore.schedules.filter { $0.payload.term == exchange.currentTerm }
                    .sorted { $0.displayName < $1.displayName }.prefix(3).map(\.id))
            }
            #endif
        }
        .sheet(isPresented: $showsClassmates, onDismiss: runClassmateAction) {
            ClassmatePickerSheet(store: exchangeStore, current: viewingID, canShare: vm.schedule != nil,
                                 select: { viewingID = $0; comparingIDs = []; showsClassmates = false },
                                 compare: { afterClassmates = .compare; showsClassmates = false },
                                 scan: { afterClassmates = .scan; showsClassmates = false },
                                 showMyCode: { afterClassmates = .myCode; showsClassmates = false },
                                 periods: exchange.myPayload(for: exchange.currentTerm)?.periods ?? [])
        }
        .sheet(item: $compareSetup) { request in
            CompareSetupSheet(store: exchangeStore, term: exchange.currentTerm, initial: request.selected) { ids in
                comparingIDs = ids
                viewingID = nil
                compareSetup = nil
            }
        }
        .sheet(isPresented: $showsMyCode) {
            MyScheduleCodeSheet(vm: exchange, store: exchangeStore)
        }
        .fullScreenCover(isPresented: $showsScanner, onDismiss: exchange.cancelAll) {
            ScheduleScanView(vm: exchange) { id, name in
                viewingID = id
                marksFreeTime = true
                exchangeToast = "已加入「\(name)」"
                showsScanner = false
            }
        }
        .overlay(alignment: .bottom) {
            if let exchangeToast {
                Label(exchangeToast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.small)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, Theme.Spacing.large)
                    .onAppear { UIAccessibility.post(notification: .announcement, argument: exchangeToast) }
            }
        }
        .task(id: exchangeToast) {
            guard exchangeToast != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            exchangeToast = nil
        }
        .task { campusPlans = try? await CampusMapLoader.shared.load().plans }
        .navigationDestination(item: $campusMapRequest) { request in
            BuildingMapView(buildingID: request.building, room: request.room)
        }
    }

    // MARK: - Classmates

    private var titleText: String {
        if let viewing { return "\(viewing.displayName) 的課表" }
        return comparing.isEmpty ? "我的課表" : "共同空堂"
    }

    private func runClassmateAction() {
        switch afterClassmates {
        case .scan: showsScanner = true
        case .myCode: showsMyCode = true
        case .compare: compareSetup = CompareSetupRequest(selected: comparingIDs)
        case nil: break
        }
        afterClassmates = nil
    }

    /// The user's own week view with every selected classmate; green where nobody has class.
    private func groupContent(schedule: ClassSchedule, classmates: [ExchangedSchedule]) -> some View {
        let mine = myComparisonPayload(for: exchange.currentTerm)
        let slots: Set<Int> = mine.map { mine in
            // `mine` skips periods whose times did not parse, so map its rows back by period ID.
            let rows = mine.periods.map { period in schedule.periods.firstIndex { $0.id == period.id } }
            return Set(mine.freeSlots(with: classmates.map(\.payload)).compactMap { key in
                rows[key % 100].map { key / 100 * 100 + $0 }
            })
        } ?? []
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                HStack(spacing: Theme.Spacing.small) {
                    HStack(spacing: -10) {
                        ForEach(Array((["我"] + classmates.map(\.displayName)).prefix(4).enumerated()), id: \.offset) { index, name in
                            Text(String(name.prefix(1)))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(index == 0 ? Theme.Colors.accent : Color(.systemPurple), in: Circle())
                                .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                        }
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(classmates.count + 1) 人一起比對")
                            .font(.subheadline.weight(.semibold))
                        Text((["我"] + classmates.map(\.displayName)).joined(separator: "、"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Theme.Spacing.xsmall)
                    Button("結束") { comparingIDs = [] }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
                HStack {
                    Text("綠色是大家都沒課的時間。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        compareSetup = CompareSetupRequest(selected: comparingIDs)
                    } label: {
                        Label("調整人選", systemImage: "person.2.badge.gearshape")
                            .font(.subheadline)
                            .frame(minHeight: 36)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(Color(.secondarySystemGroupedBackground))

            ClassScheduleWeekView(
                schedule: schedule,
                displayDayHeaders: vm.displayDayHeaders,
                isRefreshing: vm.isFetchingInBackground,
                cacheAgeText: vm.cacheAgeText,
                refresh: refreshSchedule,
                editCustomCourse: editCustomCourse,
                campusRoom: campusRoom,
                openCampusMap: { campusMapRequest = $0 },
                freeSlots: slots
            )
        }
    }

    /// The title doubles as the switch between the user's and classmates' timetables.
    private var titleSwitcher: some View {
        Button {
            showsClassmates = true
        } label: {
            HStack(spacing: 5) {
                Text(titleText)
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(1)
                Image(systemName: "chevron.down.circle.fill")
                    .font(.subheadline)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.Colors.accent)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewing.map { "正在看\($0.displayName)的課表" }
                            ?? (comparing.isEmpty ? "我的課表" : "正在和 \(comparing.count) 位同學比對"))
        .accessibilityHint("切換成同學的課表，或新增同學")
    }

    private func classmateContent(_ entry: ExchangedSchedule) -> some View {
        let payload = entry.payload
        let mine = myComparisonPayload(for: payload.term)
        let headers = CustomCourse.weekdayHeaders.enumerated()
            .filter { $0.offset < 5 || payload.days.contains($0.offset) }.map(\.element)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(String(entry.displayName.prefix(1)))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color(.systemPurple), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(entry.isExpired(at: Date()) ? "\(payload.term.title)・已過期" : payload.term.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Spacing.xsmall)
                    Button {
                        viewingID = nil
                    } label: {
                        Label("回到我的", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
                if mine != nil {
                    Toggle(isOn: $marksFreeTime) {
                        Label("標出我們都沒課的時間", systemImage: "checkmark.circle")
                            .font(.subheadline)
                    }
                    .tint(Color(.systemGreen))
                    HStack {
                        if marksFreeTime {
                            Text("綠色是你們都沒課；空白的時段是你有課。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            compareSetup = CompareSetupRequest(selected: [entry.id])
                        } label: {
                            Label("加人比對", systemImage: "person.badge.plus")
                                .font(.subheadline)
                                .frame(minHeight: 36)
                        }
                    }
                } else {
                    Text(vm.schedule == nil ? "你的課表載入後，就能標出你們都沒課的時間。"
                                            : "這份課表不是本學期的，無法和你的課表比對。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(Color(.secondarySystemGroupedBackground))

            ClassScheduleWeekView(
                schedule: payload.classSchedule,
                displayDayHeaders: headers,
                isRefreshing: false,
                cacheAgeText: nil,
                refresh: {},
                editCustomCourse: { _ in },
                campusRoom: campusRoom,
                openCampusMap: { campusMapRequest = $0 },
                isReadOnly: true,
                freeSlots: marksFreeTime ? mine.map { payload.freeSlots(with: [$0]) } : nil
            )
        }
    }

    /// 校園地圖上找得到的上課教室。
    private func campusRoom(_ classroom: String?) -> CampusPlanRequest? {
        guard let classroom, let found = campusPlans?.locate(classroom) else { return nil }
        return CampusPlanRequest(building: found.building.id, room: found.space.label)
    }

    // MARK: - Full-screen loading

    private var fullScreenLoading: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 80, height: 80)

                ProgressView()
                    .scaleEffect(1.2)
                    .tint(Color.accentColor)
            }

            VStack(spacing: Theme.Spacing.xsmall) {
                Text("正在載入課表…")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(.label))

                Text("首次載入需要幾秒鐘")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(.tertiaryLabel))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Error view

    private func errorView(message: String) -> some View {
        VStack(spacing: Theme.Spacing.medium) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.08))
                    .frame(width: 100, height: 100)

                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48, weight: .ultraLight))
                    .foregroundStyle(Color.red)
            }

            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.large)

            NIUButton("重新載入") {
                vm.refresh()
            }

            Spacer()
        }
    }

    // MARK: - Schedule content

    private func scheduleContent(schedule: ClassSchedule) -> some View {
        VStack(spacing: 0) {
            Picker("課表顯示方式", selection: $displayMode) {
                Text("單日").tag("day")
                Text("整週").tag("week")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ZStack {
                // Keep the pager mounted so toggling modes preserves its position.
                VStack(spacing: 0) {
                    dayOverview(schedule: schedule)
                    dayTabBar
                    dayPager(schedule: schedule)
                }
                .opacity(showsWeek ? 0 : 1)
                .allowsHitTesting(!showsWeek)
                .accessibilityHidden(showsWeek)

                if showsWeek {
                    ClassScheduleWeekView(
                        schedule: schedule,
                        displayDayHeaders: vm.displayDayHeaders,
                        isRefreshing: vm.isFetchingInBackground,
                        cacheAgeText: vm.cacheAgeText,
                        refresh: refreshSchedule,
                        editCustomCourse: editCustomCourse,
                        campusRoom: campusRoom,
                        openCampusMap: { campusMapRequest = $0 }
                    )
                }
            }
        }
        .onAppear {
            syncPagerSelection(with: vm.selectedDayIndex, animated: false)
        }
        .onChange(of: vm.selectedDayIndex) { _, newValue in
            syncPagerSelection(with: newValue, animated: true)
        }
        .onChange(of: vm.displayDayHeaders.count) { _, _ in
            syncPagerSelection(with: vm.selectedDayIndex, animated: false)
        }
    }

    private func editCustomCourse(_ id: UUID) {
        guard let course = vm.customCourses.courses.first(where: { $0.id == id }) else { return }
        editorRequest = CustomCourseEditorRequest(course: course)
    }

    /// Monday-based index for a display tab, used to preselect the weekday of a new course.
    private func weekday(forDisplayIndex index: Int) -> Int? {
        guard vm.displayDayHeaders.indices.contains(index) else { return nil }
        return CustomCourse.weekdayHeaders.firstIndex(of: vm.displayDayHeaders[index])
    }

    // MARK: - No course view

    private func noCourseView(displayIndex: Int) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                Text("這天沒有課")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(.label))

                Button {
                    editorRequest = CustomCourseEditorRequest(weekday: weekday(forDisplayIndex: displayIndex))
                } label: {
                    Label("新增自訂課程", systemImage: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .frame(minHeight: 44)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 96)
        }
        .refreshable { await refreshSchedule() }
    }

    // MARK: - Day overview

    private func dayOverview(schedule: ClassSchedule) -> some View {
        let selectedIndex = min(max(vm.selectedDayIndex, 0), vm.displayDayHeaders.count - 1)
        let courses: [(period: ClassPeriod, course: CourseInfo)] =
            vm.scheduleColumnIndex(for: selectedIndex).map { schedule.courses(for: $0) } ?? []

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(vm.displayDayHeaders[selectedIndex])
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(.label))
                if selectedIndex == vm.actualTodayDayIndex {
                    Text("今天")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text("\(courses.count) 節課")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(.secondaryLabel))
            }

            HStack(spacing: 6) {
                if let first = courses.first, let last = courses.last {
                    Image(systemName: "clock")
                    Text("\(first.period.startTimeLabel) - \(last.period.endTimeLabel)")
                } else {
                    Image(systemName: "checkmark.circle")
                    Text("沒有排定課程")
                }
                Spacer(minLength: 8)
                if vm.isFetchingInBackground {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("更新中")
                } else if let age = vm.cacheAgeText {
                    Text("更新於 \(age)")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(.secondaryLabel))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(Color(.systemBackground))
    }

    // MARK: - Day tab bar

    /// Always shows Mon–Fri plus any weekend days present in the fetched schedule.
    private var dayTabBar: some View {
        let labels = vm.displayShortLabels
        let count = vm.displayDayHeaders.count

        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let label = labels[index]
                let isSelected = vm.selectedDayIndex == index
                let isToday = vm.actualTodayDayIndex == index
                let hasClasses = vm.scheduleColumnIndex(for: index).map { column in
                    vm.displaySchedule?.periods.contains { $0.course(for: column) != nil } == true
                } ?? false

                Button {
                    withAnimation(Theme.Animation.fast) {
                        vm.selectedDayIndex = index
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(label)
                            .font(.system(size: 16, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(
                                isSelected
                                    ? Color(.systemBackground)
                                    : (hasClasses ? Color(.label) : Color(.tertiaryLabel))
                            )
                            .frame(width: 36, height: 36)
                            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))

                        Circle()
                            .fill(isToday ? Color.accentColor : (hasClasses ? Color(.tertiaryLabel) : Color.clear))
                            .frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(vm.displayDayHeaders[index] + (isToday ? "，今天" : ""))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func dayPager(schedule: ClassSchedule) -> some View {
        let count = vm.displayDayHeaders.count

        return TabView(selection: $pagerSelection) {
            // Leading ghost page: last day (for wrap-around to previous day)
            dayPage(schedule: schedule, displayIndex: max(count - 1, 0))
                .tag(0)

            ForEach(0..<count, id: \.self) { index in
                dayPage(schedule: schedule, displayIndex: index)
                    .tag(index + 1)
            }

            // Trailing ghost page: first day (for Sunday -> Monday wrap-around)
            dayPage(schedule: schedule, displayIndex: 0)
                .tag(count + 1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: pagerSelection) { _, newValue in
            guard count > 0 else { return }

            if newValue == 0 {
                vm.selectedDayIndex = count - 1
                withTransaction(Transaction(animation: nil)) {
                    pagerSelection = count
                }
            } else if newValue == count + 1 {
                vm.selectedDayIndex = 0
                withTransaction(Transaction(animation: nil)) {
                    pagerSelection = 1
                }
            } else {
                vm.selectedDayIndex = newValue - 1
            }
        }
    }

    @ViewBuilder
    private func dayPage(schedule: ClassSchedule, displayIndex: Int) -> some View {
        if let colIndex = vm.scheduleColumnIndex(for: displayIndex),
           !schedule.courses(for: colIndex).isEmpty {
            periodListView(schedule: schedule, scheduleColumnIndex: colIndex,
                           isToday: displayIndex == vm.actualTodayDayIndex)
        } else {
            noCourseView(displayIndex: displayIndex)
        }
    }

    private func periodListView(
        schedule: ClassSchedule,
        scheduleColumnIndex: Int,
        isToday: Bool
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(schedule.periods.filter { $0.course(for: scheduleColumnIndex) != nil }) { period in
                        PeriodRowView(
                            period: period,
                            scheduleColumnIndex: scheduleColumnIndex,
                            isCurrent: isToday && period.isCurrentPeriod,
                            editCustomCourse: editCustomCourse,
                            campusRoom: campusRoom,
                            openCampusMap: { campusMapRequest = $0 }
                        )
                        .id(period.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .refreshable { await refreshSchedule() }
            .onAppear {
                if isToday, let current = schedule.periods.first(where: {
                    $0.isCurrentPeriod && $0.course(for: scheduleColumnIndex) != nil
                }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation { proxy.scrollTo(current.id, anchor: .center) }
                    }
                }
            }
        }
    }

    private func syncPagerSelection(with dayIndex: Int, animated: Bool) {
        let target = dayIndex + 1
        guard pagerSelection != target else { return }

        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                pagerSelection = target
            }
        } else {
            withTransaction(Transaction(animation: nil)) {
                pagerSelection = target
            }
        }
    }
}

// MARK: - PeriodRowView

private struct PeriodRowView: View {
    let period: ClassPeriod
    let scheduleColumnIndex: Int
    let isCurrent: Bool
    let editCustomCourse: (UUID) -> Void
    let campusRoom: (String?) -> CampusPlanRequest?
    let openCampusMap: (CampusPlanRequest) -> Void

    private var course: CourseInfo? { period.course(for: scheduleColumnIndex) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(period.startTimeLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color(.label))
                Text(period.endTimeLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .frame(width: 48, alignment: .trailing)
            .padding(.top, 16)

            if let course = course, let customID = course.customCourseID {
                Button {
                    editCustomCourse(customID)
                } label: {
                    CourseCard(
                        course: course,
                        periodLabel: period.displayPeriodLabel,
                        isCurrent: isCurrent
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(period.displayPeriodLabel)，\(period.startTimeLabel)到\(period.endTimeLabel)，自訂課程，\(course.name)，\(course.details ?? "")")
                .accessibilityHint("編輯自訂課程")
                .campusRoomMenu(campusRoom(course.classroom), open: openCampusMap)
            } else if let course = course {
                NavigationLink {
                    ClassScheduleCourseDestination(courseName: course.name)
                } label: {
                    CourseCard(
                        course: course,
                        periodLabel: period.displayPeriodLabel,
                        isCurrent: isCurrent
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(period.displayPeriodLabel)，\(period.startTimeLabel)到\(period.endTimeLabel)，\(course.name)，\(course.details ?? "")")
                .accessibilityHint("開啟 M 園區課程")
                .campusRoomMenu(campusRoom(course.classroom), open: openCampusMap)
            }
        }
    }
}

// MARK: - CourseCard

private struct CourseCard: View {
    let course: CourseInfo
    let periodLabel: String
    let isCurrent: Bool

    private var customColour: Color? { course.customColor?.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(course.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(.label))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if course.customCourseID != nil {
                    Text("自訂")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(customColour ?? Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((customColour ?? Color.accentColor).opacity(0.12), in: Capsule())
                        .fixedSize()
                }
                Text(periodLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color(.secondaryLabel))
                    .fixedSize()
            }

            if isCurrent {
                Label("正在上課", systemImage: "circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            if let teacher = course.teacher, !teacher.isEmpty {
                Label(teacher, systemImage: "person")
                    .lineLimit(2)
            }
            if let classroom = course.classroom, !classroom.isEmpty {
                Label(classroom, systemImage: "mappin")
                    .lineLimit(2)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(.secondaryLabel))
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .adaptiveGlass(
            tint: isCurrent ? Color.accentColor.opacity(0.12) : customColour?.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Preview

#Preview {
    ClassScheduleView()
}
