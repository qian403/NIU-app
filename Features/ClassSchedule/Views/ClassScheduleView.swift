import SwiftUI

struct ClassScheduleView: View {
    @StateObject private var vm = ClassScheduleViewModel()
    @State private var showExportSheet = false
    @State private var pagerSelection: Int = 1

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

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
                if vm.schedule != nil {
                    Button {
                        showExportSheet = true
                    } label: {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .accessibilityLabel("匯出課表至行事曆")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if vm.schedule != nil, let today = vm.actualTodayDayIndex,
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
        .sheet(isPresented: $showExportSheet) {
            if let schedule = vm.schedule {
                ClassScheduleExportView(
                    schedule: schedule,
                    isPresented: $showExportSheet
                )
            }
        }
        .onAppear {
            if vm.loadState == .idle {
                vm.loadSchedule()
            }
        }
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
            dayOverview(schedule: schedule)
            dayTabBar
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
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 96)
        }
        .refreshable { await vm.refreshAndWait() }
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
                    vm.schedule?.periods.contains { $0.course(for: column) != nil } == true
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
            noCourseView
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
                            isCurrent: isToday && period.isCurrentPeriod
                        )
                        .id(period.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .refreshable { await vm.refreshAndWait() }
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

            if let course = course {
                CourseCard(
                    course: course,
                    periodLabel: period.displayPeriodLabel,
                    isCurrent: isCurrent
                )
                .accessibilityLabel("\(period.displayPeriodLabel)，\(period.startTimeLabel)到\(period.endTimeLabel)，\(course.name)，\(course.details ?? "")")
            }
        }
    }
}

// MARK: - CourseCard

private struct CourseCard: View {
    let course: CourseInfo
    let periodLabel: String
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(course.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(.label))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
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
        .glassEffect(
            isCurrent
                ? .regular.tint(Color.accentColor.opacity(0.12))
                : .regular,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Preview

#Preview {
    ClassScheduleView()
}
