import SwiftUI

struct ClassScheduleView: View {
    @StateObject private var vm = ClassScheduleViewModel()
    @State private var showExportSheet = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.white.ignoresSafeArea()

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
        }
        .preferredColorScheme(.light)
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
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("正在載入課表…")
                .font(.system(size: 15, weight: .light))
                .foregroundColor(.black.opacity(0.5))
            Text("首次載入需要幾秒鐘")
                .font(.system(size: 12, weight: .light))
                .foregroundColor(.black.opacity(0.3))
            Spacer()
        }
    }

    // MARK: - Error view

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundColor(.black.opacity(0.35))

            Text(message)
                .font(.system(size: 15))
                .foregroundColor(.black.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            Button("重新載入") {
                vm.refresh()
            }
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                    .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
            )
            .foregroundColor(.black)

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

            // Schedule column index for the currently selected display day
            let colIndex = vm.scheduleColumnIndex(for: vm.selectedDayIndex)

            if colIndex == nil {
                // Selected weekday exists in the tab but not in the fetched schedule → no classes
                noCourseView
            } else {
                // Periods list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(schedule.periods) { period in
                                PeriodRowView(
                                    period: period,
                                    scheduleColumnIndex: colIndex!
                                )
                                .id(period.id)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.small)
                    }
                    .onAppear {
                        if let current = schedule.periods.first(where: { $0.isCurrentPeriod }),
                           colIndex != nil {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation { proxy.scrollTo(current.id, anchor: .center) }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - No course view

    private var noCourseView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "moon.zzz")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundColor(.black.opacity(0.25))
            Text("本日無課程")
                .font(.system(size: 15, weight: .light))
                .foregroundColor(.black.opacity(0.4))
            Spacer()
        }
    }

    // MARK: - Cache info bar

    private var cacheInfoBar: some View {
        HStack(spacing: 6) {
            if let age = vm.cacheAgeText {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundColor(.black.opacity(0.35))
                Text("更新於 \(age)")
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.black.opacity(0.35))
            }
            Spacer()
            if vm.isFetchingInBackground {
                Text("正在更新…")
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.black.opacity(0.35))
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.02))
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
                    withAnimation(.easeInOut(duration: 0.15)) {
                        vm.selectedDayIndex = index
                    }
                } label: {
                    VStack(spacing: 5) {
                        Text(label)
                            .font(.system(
                                size: 15,
                                weight: isSelected ? .semibold : .regular
                            ))
                            .foregroundColor(
                                isSelected
                                    ? .black
                                    : (hasClasses ? .black.opacity(0.5) : .black.opacity(0.25))
                            )

                        // Today indicator dot
                        Circle()
                            .fill(isToday ? Color.black : Color.clear)
                            .frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(
                        Rectangle()
                            .frame(height: 2)
                            .foregroundColor(isSelected ? .black : .clear),
                        alignment: .bottom
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - PeriodRowView

private struct PeriodRowView: View {
    let period: ClassPeriod
    let scheduleColumnIndex: Int   // column in schedule.dayHeaders (already resolved)

    private var course: CourseInfo? { period.course(for: scheduleColumnIndex) }
    private var isCurrent: Bool { period.isCurrentPeriod }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Period label + start time
            VStack(alignment: .trailing, spacing: 2) {
                Text(period.id)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundColor(isCurrent ? .black : .black.opacity(0.45))

                Text(period.startTimeLabel)
                    .font(.system(size: 10, weight: .light))
                    .foregroundColor(.black.opacity(0.3))
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 44, alignment: .trailing)

            // Timeline bar
            RoundedRectangle(cornerRadius: 1)
                .fill(isCurrent ? Color.black : Color.black.opacity(0.1))
                .frame(width: isCurrent ? 2.5 : 1.5)
                .padding(.top, 3)

            // Course card or empty slot
            if let course = course {
                CourseCard(course: course, isCurrent: isCurrent)
            } else {
                Color.clear
                    .frame(height: 50)
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, 5)
        .background(
            isCurrent
                ? Color.black.opacity(0.025)
                : Color.clear
        )
    }
}

// MARK: - CourseCard

private struct CourseCard: View {
    let course: CourseInfo
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(course.name)
                .font(.system(size: 14, weight: isCurrent ? .medium : .regular))
                .foregroundColor(.black)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let details = course.details, !details.isEmpty {
                Text(details)
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.black.opacity(0.5))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                .strokeBorder(
                    isCurrent
                        ? Color.black.opacity(0.45)
                        : Color.black.opacity(0.12),
                    lineWidth: isCurrent ? 1.5 : 1
                )
        )
    }
}

// MARK: - Preview

#Preview {
    ClassScheduleView()
}
