import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var scheduleViewModel = ClassScheduleViewModel()
    @State private var navigateToClassSchedule = false
    @State private var animateIn = true

    // Today's courses state
    @State private var relevantPeriods: [(period: ClassPeriod, course: CourseInfo)] = []
    @State private var todayHasAnyClasses = false
    @State private var isLoadingCourses = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.systemBackground),
                        Color(.systemGroupedBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: Theme.Spacing.large) {
                        headerSection
                            .padding(.horizontal, Theme.Spacing.large)
                            .padding(.top, Theme.Spacing.medium)

                        welcomeSection
                            .padding(.horizontal, Theme.Spacing.large)

                        schedulePreview
                            .padding(.horizontal, Theme.Spacing.large)

                        quickAttendanceEntry
                            .padding(.horizontal, Theme.Spacing.large)

                        featureCards
                            .padding(.horizontal, Theme.Spacing.large)

                        Spacer()
                    }
                    .padding(.bottom, Theme.Spacing.large)
                }
                .refreshable {
                    await scheduleViewModel.refreshAndWait()
                    loadTodayCourses()
                }

                if scheduleViewModel.showWebView {
                    ClassScheduleWebView { result in
                        scheduleViewModel.handleWebResult(result)
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $navigateToClassSchedule) {
                ClassScheduleView()
            }
        }
        .onAppear {
            loadTodayCourses()
            if scheduleViewModel.loadState == .idle {
                scheduleViewModel.loadSchedule()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .classScheduleDidUpdate)) { _ in
            loadTodayCourses()
        }
        .onOpenURL { url in
            guard shouldOpenClassSchedule(from: url) else { return }
            navigateToClassSchedule = true
        }
        .task {
            await appState.refreshProfileIfNeeded()
        }
    }

    private func shouldOpenClassSchedule(from url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        let path = url.path.lowercased()
        guard scheme == "niuapp" else { return false }
        return host == "class-schedule" || path == "/class-schedule"
    }

    // MARK: - Load Today's Courses

    private static let weekdayNames = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
    private static let cacheKey = "classSchedule.v2.cachedData"

    private func loadTodayCourses() {
        isLoadingCourses = true
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let schedule = try? JSONDecoder().decode(ClassSchedule.self, from: data) {
            let extracted = extractRelevantPeriods(from: schedule)
            relevantPeriods = extracted.relevant
            todayHasAnyClasses = extracted.todayHasAnyClasses
        } else {
            relevantPeriods = []
            todayHasAnyClasses = false
        }
        isLoadingCourses = false
    }

    private func extractRelevantPeriods(from schedule: ClassSchedule) -> (relevant: [(period: ClassPeriod, course: CourseInfo)], todayHasAnyClasses: Bool) {
        let weekday = Calendar.current.component(.weekday, from: Date())
        let mondayBased = (weekday + 5) % 7
        guard mondayBased < Self.weekdayNames.count else { return ([], false) }
        let todayName = Self.weekdayNames[mondayBased]
        guard let colIndex = schedule.dayHeaders.firstIndex(of: todayName) else { return ([], false) }

        let todaysAll = schedule.periods.compactMap { period -> (period: ClassPeriod, course: CourseInfo)? in
            guard let course = period.course(for: colIndex) else { return nil }
            return (period, course)
        }

        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let nowMinutes = (now.hour ?? 0) * 60 + (now.minute ?? 0)

        let notEnded = todaysAll.filter { item in
            guard let end = item.period.endMinutes else { return false }
            return end > nowMinutes
        }

        var result: [(period: ClassPeriod, course: CourseInfo)] = []
        if let current = notEnded.first(where: { $0.period.isCurrentPeriod }) {
            result.append(current)
        }
        if let next = notEnded.first(where: {
            guard let start = $0.period.startMinutes else { return false }
            return start > nowMinutes
        }) {
            result.append(next)
        }

        return (result, !todaysAll.isEmpty)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack {
            NavigationLink(destination: SettingsView()) {
                HStack(spacing: Theme.Spacing.small) {
                    NIUAvatar(appState.currentUser?.name ?? "U", size: .small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.currentUser?.name ?? "User")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(.label))
                        Text("國立宜蘭大學")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            NavigationLink(
                destination: MoodleWebPageView(
                    title: "M 園區通知",
                    targetURL: "https://euni.niu.edu.tw/message/output/popup/notifications.php"
                )
            ) {
                iconButtonAppearance("bell.badge")
            }
            .buttonStyle(.plain)
        }
    }

    private func iconButtonAppearance(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.accentColor.opacity(0.12)))
    }

    // MARK: - Welcome Section

    private var welcomeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Welcome back,")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
                .opacity(animateIn ? 1 : 0)
                .animation(Theme.Animation.fast.delay(0.3), value: animateIn)

            Text(appState.currentUser?.name ?? "User")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Color(.label))
                .opacity(animateIn ? 1 : 0)
                .animation(Theme.Animation.fast.delay(0.4), value: animateIn)

            if let user = appState.currentUser {
                HStack(spacing: Theme.Spacing.medium) {
                    if let department = user.department {
                        InfoChip(
                            icon: "building.2",
                            title: normalizedDepartment(from: department)
                        )
                    }

                    if let grade = user.grade {
                        InfoChip(
                            icon: "calendar",
                            title: grade
                        )
                    }
                }
                .opacity(animateIn ? 1 : 0)
                .animation(Theme.Animation.fast.delay(0.5), value: animateIn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Schedule Preview

    private var schedulePreview: some View {
        VStack(spacing: Theme.Spacing.medium) {
            HStack {
                Text("今日課程")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(.label))

                Spacer()

                Button("查看全部") {
                    navigateToClassSchedule = true
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }

            if relevantPeriods.isEmpty && !isLoadingCourses {
                emptyScheduleCard
            } else if !relevantPeriods.isEmpty {
                relevantPeriodsList
            } else {
                loadingCard
            }
        }
        .opacity(animateIn ? 1 : 0)
        .animation(Theme.Animation.fast.delay(0.6), value: animateIn)
    }

    private var emptyScheduleCard: some View {
        NIUGlassCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(todayHasAnyClasses ? "今天的課程都結束了" : "今天沒有安排課程")
                        .font(.system(size: 17, weight: .semibold))
                    Text(todayHasAnyClasses ? "好好休息一下吧 🎉" : "可以安排自己的時間 🌤️")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(.secondaryLabel))
                }
                Spacer()
                Image(systemName: todayHasAnyClasses ? "sun.max.fill" : "calendar.badge.minus")
                    .font(.system(size: 32, weight: .ultraLight))
                    .foregroundStyle(todayHasAnyClasses ? .orange.opacity(0.5) : .blue.opacity(0.45))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var loadingCard: some View {
        NIUGlassCard {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("載入課表...")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(.secondaryLabel))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var relevantPeriodsList: some View {
        VStack(spacing: Theme.Spacing.xsmall) {
            ForEach(Array(relevantPeriods.enumerated()), id: \.offset) { _, item in
                todayCourseRow(period: item.period, course: item.course)
            }
        }
    }

    private func todayCourseRow(period: ClassPeriod, course: CourseInfo) -> some View {
        let isCurrent = period.isCurrentPeriod

        return Button {
            navigateToClassSchedule = true
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isCurrent ? Color.accentColor : Color(.separator))
                    .frame(width: 3, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if isCurrent {
                            Text("上課中")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor))
                        } else {
                            Text("下一堂")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(.secondaryLabel))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(.tertiarySystemFill)))
                        }
                        Text(period.timeRange)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }

                    Text(course.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)

                    if let classroom = course.classroom, !classroom.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin")
                                .font(.system(size: 10))
                            Text(classroom)
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Color(.tertiaryLabel))
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(0.06) : Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feature Cards

    private var quickAttendanceEntry: some View {
        NavigationLink(destination: MoodleAttendanceScannerView()) {
            HStack(spacing: Theme.Spacing.medium) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 56, height: 56)

                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Moodle 快速點名")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(.label))
                    Text("掃描課堂 QR Code 完成簽到")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(.secondaryLabel))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(Theme.Spacing.medium)
            .glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? 1 : 0)
        .animation(Theme.Animation.fast.delay(0.65), value: animateIn)
    }

    private var featureCards: some View {
        VStack(spacing: Theme.Spacing.medium) {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: Theme.Spacing.medium),
                GridItem(.flexible(), spacing: Theme.Spacing.medium)
            ], spacing: Theme.Spacing.medium) {
                FeatureCard(
                    icon: "graduationcap.fill",
                    title: "M 園區",
                    subtitle: "課程、公告與作業",
                    color: .blue,
                    destination: MoodleView()
                )

                FeatureCard(
                    icon: "tablecells",
                    title: "我的課表",
                    subtitle: "查看每週課程安排",
                    color: .purple,
                    destination: ClassScheduleView()
                )

                FeatureCard(
                    icon: "calendar",
                    title: "學年度行事曆",
                    subtitle: "查看學期重要日程",
                    color: .orange,
                    destination: AcademicCalendarView()
                )

                FeatureCard(
                    icon: "calendar.badge.plus",
                    title: "活動報名",
                    subtitle: "參加校園活動",
                    color: .green,
                    destination: EventRegistrationView()
                )

                FeatureCard(
                    icon: "chart.bar.doc.horizontal",
                    title: "成績查詢",
                    subtitle: "歷年成績與 GPA",
                    color: .orange,
                    destination: GradeHistoryView()
                )

                FeatureCard(
                    icon: "checkmark.seal",
                    title: "畢業門檻",
                    subtitle: "多元時數、英文、體適能",
                    color: .teal,
                    destination: GraduationThresholdView()
                )
            }
            .opacity(animateIn ? 1 : 0)
            .animation(Theme.Animation.fast.delay(0.7), value: animateIn)
        }
    }
}

// MARK: - Feature Card

struct FeatureCard<Destination: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let destination: Destination

    var body: some View {
        NavigationLink(destination: destination) {
            VStack(spacing: Theme.Spacing.small) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(color)
                }

                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(.label))

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Info Chip

struct InfoChip: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color(.secondaryLabel))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }
}

// MARK: - Helper Functions

private func normalizedDepartment(from raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }
    let prefixes = ["系所年級：", "系所年級:", "系所：", "系所:"]
    for prefix in prefixes where trimmed.hasPrefix(prefix) {
        let value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "" : value
    }
    return trimmed
}

#Preview {
    NavigationStack {
        HomeView()
            .environmentObject(AppState())
    }
}
