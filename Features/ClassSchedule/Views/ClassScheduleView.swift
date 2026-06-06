import SwiftUI
import Combine

struct ClassScheduleView: View {
    @StateObject private var vm = ClassScheduleViewModel()
    @StateObject private var attendanceStore = ClassAttendanceStore()
    @State private var showExportSheet = false
    @State private var selectedSession: ScheduleSession?
    @State private var pagerSelection: Int = 1

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                switch vm.loadState {
                case .idle:
                    EmptyView()

                case .loading:
                    fullScreenLoading

                case .cached, .fresh:
                    if let schedule = vm.schedule {
                        scheduleContent(schedule: schedule)
                    }

                case .error(let msg):
                    errorView(message: msg)
                }
            }

            // Invisible WebView for background data fetching
            if vm.showWebView {
                ClassScheduleWebView { result in
                    vm.handleWebResult(result)
                }
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle("我的課表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Export to calendar
                    if vm.schedule != nil {
                        Button {
                            showExportSheet = true
                        } label: {
                            Image(systemName: "calendar.badge.plus")
                                .font(.system(size: 16, weight: .light))
                        }
                    }
                    // Refresh
                    refreshButton
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            if let schedule = vm.schedule {
                ClassScheduleExportView(
                    schedule: schedule,
                    isPresented: $showExportSheet
                )
            }
        }
        .sheet(item: $selectedSession) { session in
            QuickAttendanceSheet(
                session: session,
                attendanceStore: attendanceStore
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color(.systemBackground))
        }
        .onAppear {
            if vm.loadState == .idle {
                vm.loadSchedule()
            }
        }
    }

    // MARK: - Refresh button

    private var refreshButton: some View {
        Button(action: { vm.refresh() }) {
            if vm.isFetchingInBackground {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .light))
            }
        }
        .disabled(vm.loadState == .loading || vm.isFetchingInBackground)
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
            // Cache age info bar
            cacheInfoBar

            // Day tabs (always Mon–Fri + any weekend in schedule)
            dayTabBar

            Divider()
            dayPager(schedule: schedule)
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

    // MARK: - No course view

    private var noCourseView: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 80, height: 80)

                Image(systemName: "moon.zzz")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(Color(.tertiaryLabel))
            }

            Text("本日無課程")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))

            Spacer()
        }
    }

    // MARK: - Cache info bar

    private var cacheInfoBar: some View {
        HStack(spacing: 6) {
            if let age = vm.cacheAgeText {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(.tertiaryLabel))
                Text("更新於 \(age)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            Spacer()
            if vm.isFetchingInBackground {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("正在更新…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
        .background(Color(.tertiarySystemBackground))
    }

    // MARK: - Day tab bar

    /// Always shows Mon–Fri plus any weekend days present in the fetched schedule.
    private var dayTabBar: some View {
        let labels = vm.displayShortLabels
        let count  = vm.displayDayHeaders.count

        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let label      = index < labels.count ? labels[index] : ""
                let isSelected = vm.selectedDayIndex == index
                let isToday    = vm.todayDayIndex == index
                // Dim if this weekday has no classes in the schedule
                let hasClasses = vm.scheduleColumnIndex(for: index) != nil

                Button {
                    withAnimation(Theme.Animation.fast) {
                        vm.selectedDayIndex = index
                    }
                } label: {
                    VStack(spacing: 6) {
                        Text(label)
                            .font(.system(
                                size: 15,
                                weight: isSelected ? .semibold : .medium
                            ))
                            .foregroundStyle(
                                isSelected
                                    ? Color.accentColor
                                    : (hasClasses ? Color(.secondaryLabel) : Color(.tertiaryLabel))
                            )

                        // Today indicator
                        if isToday {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: 24, height: 3)
                        } else {
                            Circle()
                                .fill(Color.clear)
                                .frame(width: 4, height: 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.small)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(.secondarySystemBackground))
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
        if let colIndex = vm.scheduleColumnIndex(for: displayIndex) {
            periodListView(schedule: schedule, scheduleColumnIndex: colIndex)
        } else {
            noCourseView
        }
    }

    private func periodListView(
        schedule: ClassSchedule,
        scheduleColumnIndex: Int
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(schedule.periods) { period in
                        PeriodRowView(
                            period: period,
                            scheduleColumnIndex: scheduleColumnIndex,
                            dayName: schedule.dayHeaders[scheduleColumnIndex]
                        ) { session in
                            selectedSession = session
                        }
                        .id(period.id)
                    }
                }
                .padding(.vertical, Theme.Spacing.small)
            }
            .onAppear {
                if let current = schedule.periods.first(where: { $0.isCurrentPeriod }) {
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
    let scheduleColumnIndex: Int   // column in schedule.dayHeaders (already resolved)
    let dayName: String
    let onSelect: (ScheduleSession) -> Void

    private var course: CourseInfo? { period.course(for: scheduleColumnIndex) }
    private var isCurrent: Bool { period.isCurrentPeriod }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            // Period label + start time
            VStack(alignment: .trailing, spacing: 2) {
                Text(period.id)
                    .font(.system(size: 14, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color(.secondaryLabel))

                Text(period.startTimeLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 44, alignment: .trailing)

            // Timeline bar
            RoundedRectangle(cornerRadius: 1)
                .fill(isCurrent ? Color.accentColor : Color(.separator))
                .frame(width: isCurrent ? 3 : 2)
                .padding(.top, 4)

            // Course card or empty slot
            if let course = course {
                CourseCard(course: course, isCurrent: isCurrent)
                    .onTapGesture {
                        onSelect(
                            ScheduleSession(
                                dayName: dayName,
                                periodId: period.id,
                                timeRange: period.timeRange,
                                course: course
                            )
                        )
                    }
            } else {
                Color.clear
                    .frame(height: 50)
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.xsmall)
        .background(
            isCurrent
                ? Color.accentColor.opacity(0.04)
                : Color.clear
        )
    }
}

// MARK: - CourseCard

private struct CourseCard: View {
    let course: CourseInfo
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            Text(course.name)
                .font(.system(size: 15, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(Color(.label))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let details = course.details, !details.isEmpty {
                Text(details)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.08) : Color(.tertiarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                .strokeBorder(
                    isCurrent
                        ? Color.accentColor
                        : Color.clear,
                    lineWidth: 1.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous))
    }
}

private struct ScheduleSession: Identifiable {
    let dayName: String
    let periodId: String
    let timeRange: String
    let course: CourseInfo

    var id: String {
        encodedAttendanceKey([dayName, periodId, course.name, course.teacher ?? "", course.classroom ?? ""])
    }
}

private enum AttendanceStatus: String, Codable, CaseIterable {
    case present
    case late
    case absent
    case excused

    var title: String {
        switch self {
        case .present: return "出席"
        case .late: return "遲到"
        case .absent: return "缺席"
        case .excused: return "請假"
        }
    }

    var score: Double? {
        switch self {
        case .present: return 1.0
        case .late: return 1.0
        case .absent: return 0.0
        case .excused: return nil
        }
    }
}

private struct AttendanceRecord: Codable, Identifiable {
    let dateKey: String
    let periodId: String
    let courseName: String
    let teacher: String?
    let classroom: String?
    let status: AttendanceStatus

    var id: String { sessionKey }

    var sessionKey: String {
        encodedAttendanceKey([dateKey, periodId, courseName, teacher ?? "", classroom ?? ""])
    }

    var slotKey: String {
        encodedAttendanceKey([periodId, courseName, teacher ?? "", classroom ?? ""])
    }
}

private struct SlotStats {
    let present: Int
    let absent: Int
    let late: Int
    let excused: Int
    let counted: Int
    let equivalentPresent: Double

    var rate: Double {
        counted > 0 ? equivalentPresent / Double(counted) : 0
    }
}

@MainActor
private final class ClassAttendanceStore: ObservableObject {
    @Published private(set) var recordsByKey: [String: AttendanceRecord] = [:]

    private let key = "attendance.records.v1"
    private let instanceID = UUID().uuidString
    private var saveWorkItem: DispatchWorkItem?
    private var historyCache: [String: [AttendanceRecord]] = [:]
    private var cancellables = Set<AnyCancellable>()
    private static let storageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init() {
        load()
        observeExternalUpdates()
    }

    func load() {
        recordsByKey = loadFromDisk()
        historyCache.removeAll()
    }

    func status(on date: Date, session: ScheduleSession) -> AttendanceStatus? {
        recordsByKey[recordKey(for: session, date: date)]?.status
    }

    func set(_ status: AttendanceStatus, on date: Date, session: ScheduleSession) {
        var latest = loadFromDisk()
        let record = AttendanceRecord(
            dateKey: dateKey(from: date),
            periodId: session.periodId,
            courseName: session.course.name,
            teacher: session.course.teacher,
            classroom: session.course.classroom,
            status: status
        )
        latest[record.sessionKey] = record
        recordsByKey = latest
        historyCache.removeAll()
        scheduleSave(snapshot: latest)
    }

    func clear(on date: Date, session: ScheduleSession) {
        var latest = loadFromDisk()
        latest.removeValue(forKey: recordKey(for: session, date: date))
        recordsByKey = latest
        historyCache.removeAll()
        scheduleSave(snapshot: latest)
    }

    func history(for session: ScheduleSession) -> [AttendanceRecord] {
        let key = slotKey(for: session)
        if let cached = historyCache[key] {
            return cached
        }
        let resolved = recordsByKey.values
            .filter { $0.slotKey == key }
            .sorted { $0.dateKey > $1.dateKey }
        historyCache[key] = resolved
        return resolved
    }

    func stats(for session: ScheduleSession) -> SlotStats {
        let history = history(for: session)
        let present = history.filter { $0.status == .present }.count
        let absent = history.filter { $0.status == .absent }.count
        let late = history.filter { $0.status == .late }.count
        let excused = history.filter { $0.status == .excused }.count
        let counted = history.filter { $0.status.score != nil }.count
        let equivalent = history.compactMap { $0.status.score }.reduce(0, +)
        return SlotStats(
            present: present,
            absent: absent,
            late: late,
            excused: excused,
            counted: counted,
            equivalentPresent: equivalent
        )
    }

    private func slotKey(for session: ScheduleSession) -> String {
        encodedAttendanceKey([session.periodId, session.course.name, session.course.teacher ?? "", session.course.classroom ?? ""])
    }

    private func recordKey(for session: ScheduleSession, date: Date) -> String {
        encodedAttendanceKey([
            dateKey(from: date),
            session.periodId,
            session.course.name,
            session.course.teacher ?? "",
            session.course.classroom ?? ""
        ])
    }

    private func dateKey(from date: Date) -> String {
        Self.storageDateFormatter.string(from: date)
    }

    private func loadFromDisk() -> [String: AttendanceRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([AttendanceRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.sessionKey, $0) })
    }

    private func scheduleSave(snapshot: [String: AttendanceRecord]) {
        saveWorkItem?.cancel()
        let records = snapshot
        let key = self.key
        let source = instanceID
        let work = DispatchWorkItem {
            let list = Array(records.values)
            guard let data = try? JSONEncoder().encode(list) else { return }
            UserDefaults.standard.set(data, forKey: key)
            NotificationCenter.default.post(name: attendanceRecordsUpdatedNotification, object: source)
        }
        saveWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func observeExternalUpdates() {
        NotificationCenter.default.publisher(for: attendanceRecordsUpdatedNotification)
            .sink { [weak self] note in
                guard let self else { return }
                if let source = note.object as? String, source == self.instanceID { return }
                Task { @MainActor in
                    self.load()
                }
            }
            .store(in: &cancellables)
    }
}

private struct QuickAttendanceSheet: View {
    let session: ScheduleSession
    @ObservedObject var attendanceStore: ClassAttendanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate = Date()

    private var stats: SlotStats {
        attendanceStore.stats(for: session)
    }

    private var history: [AttendanceRecord] {
        attendanceStore.history(for: session)
    }

    private var selectedStatus: AttendanceStatus? {
        attendanceStore.status(on: selectedDate, session: session)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: Theme.Spacing.medium) {
                        headerCard
                        quickRecordCard
                        miniStatsCard
                    }
                    .padding(Theme.Spacing.medium)
                }
            }
            .navigationTitle("快速記錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(session.course.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color(.label))
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Text("\(session.dayName)・\(session.periodId)・\(session.timeRange)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))

            if let teacher = session.course.teacher, !teacher.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(.tertiaryLabel))
                    Text(teacher)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }

            if let classroom = session.course.classroom, !classroom.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(.tertiaryLabel))
                    Text(classroom)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var quickRecordCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("當日記錄")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))

            HStack {
                DatePicker("", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "zh_TW"))
                Spacer()
                if selectedStatus != nil {
                    Button("清除") {
                        attendanceStore.clear(on: selectedDate, session: session)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
            }

            HStack(spacing: Theme.Spacing.xsmall) {
                ForEach(AttendanceStatus.allCases, id: \.rawValue) { status in
                    Button {
                        if selectedStatus == status {
                            attendanceStore.clear(on: selectedDate, session: session)
                        } else {
                            attendanceStore.set(status, on: selectedDate, session: session)
                        }
                    } label: {
                        Text(status.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selectedStatus == status ? Color(.systemBackground) : Color(.secondaryLabel))
                            .padding(.horizontal, Theme.Spacing.small)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selectedStatus == status ? Color.accentColor : Color(.tertiarySystemFill))
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var miniStatsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("本課統計")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))

            HStack(spacing: Theme.Spacing.xsmall) {
                miniStat(number: stats.present, label: "出席")
                miniStat(number: stats.late, label: "遲到")
                miniStat(number: stats.absent, label: "缺席")
                miniStat(number: stats.excused, label: "請假")
                miniStat(number: Int((stats.rate * 100).rounded()), label: "出席率%")
            }

            if let latest = history.first {
                Text("最近一次：\(formatted(dateKey: latest.dateKey)) \(latest.status.title)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func miniStat(number: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(number)")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color(.label))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }

    private func formatted(dateKey: String) -> String {
        guard let date = Self.storageDateParser.date(from: dateKey) else { return dateKey }
        return Self.displayDateFormatter.string(from: date)
    }

    private static let storageDateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}

private func encodedAttendanceKey(_ parts: [String]) -> String {
    parts
        .map { Data($0.utf8).base64EncodedString() }
        .joined(separator: ".")
}

private let attendanceRecordsUpdatedNotification = Notification.Name("attendance.records.updated")

// MARK: - Preview

#Preview {
    ClassScheduleView()
}
