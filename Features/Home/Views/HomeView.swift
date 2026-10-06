import SwiftUI

private enum HomeDestination: Hashable {
    case settings, moodle, classSchedule, library, academicCalendar, attendance
    case eventRegistration, gradeHistory, graduationThreshold, mail, enrollmentCertificate, postalQuery, libraryEquipment
    case tools, leaveApplication

    init(_ destination: CampusDestination) {
        switch destination {
        case .classSchedule: self = .classSchedule
        case .academicCalendar: self = .academicCalendar
        case .attendance: self = .attendance
        case .library: self = .library
        case .mail: self = .mail
        case .moodle: self = .moodle
        }
    }
}

private struct HomeRoute: Hashable {
    let destination: HomeDestination
    var requestID: UUID?
}

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var router: CampusRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var scheduleViewModel = ClassScheduleViewModel()
    @State private var navigationPath = NavigationPath()
    @State private var animateIn = true
    @AppStorage("home.isNameMasked") private var isNameMasked = false
    @State private var nameScrambleRequest: UUID?
    @State private var scrambledName: String?
    @State private var nameGlitchOffset: CGFloat = 0

    private static let scrambleCharacters = Array("０１２３４５６７８９ＡＢＣＤＥＦ＃＊＋／＝")

    private static let compoundSurnames = [
        "歐陽", "司馬", "上官", "諸葛", "司徒", "司空", "夏侯", "皇甫",
        "尉遲", "公孫", "慕容", "令狐", "宇文", "長孫", "獨孤", "東方", "南宮"
    ]

    private var homeDisplayName: String {
        guard isNameMasked else { return appState.currentUser?.name ?? "User" }
        let name = appState.currentUser?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return "同學" }
        let surname = Self.compoundSurnames.first {
            name.hasPrefix($0) && name.count > $0.count
        } ?? String(name.prefix(1))
        return "\(surname)同學"
    }

    // Today's courses state
    @State private var relevantPeriods: [(period: ClassPeriod, course: CourseInfo)] = []
    @State private var todayHasAnyClasses = false
    @State private var isLoadingCourses = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
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
                    let generation = scheduleViewModel.loadGeneration
                    ClassScheduleWebView { result in
                        scheduleViewModel.handleWebResult(result, generation: generation)
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: HomeRoute.self) { route in
                destinationView(for: route.destination)
                    .id(route)
            }
            .task(id: nameScrambleRequest) { [request = nameScrambleRequest] in
                await animateNameScramble(request: request)
            }
            .onDisappear {
                stopNameScramble()
            }
            .onChange(of: appState.currentUser) { _, _ in
                stopNameScramble()
            }
            .onChange(of: reduceMotion) { _, enabled in
                if enabled { stopNameScramble() }
            }
        }
        .task(id: router.pendingRequest?.id) {
            guard let request = router.pendingRequest else { return }
            // Replace the route without rebuilding the stack that owns its path.
            navigationPath = NavigationPath([
                HomeRoute(destination: HomeDestination(request.destination), requestID: request.id)
            ])
            router.pendingRequest = nil
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
        .task {
            await appState.refreshProfileIfNeeded()
        }
    }

    @ViewBuilder
    private func destinationView(for destination: HomeDestination) -> some View {
        switch destination {
        case .settings: SettingsView()
        case .moodle: MoodleView()
        case .classSchedule: ClassScheduleView()
        case .library: LibraryCodeView()
        case .libraryEquipment: LibraryEquipmentView()
        case .academicCalendar: AcademicCalendarView()
        case .attendance:
            MoodleAttendanceScannerView(onReturnHome: {
                navigationPath = NavigationPath()
            })
        case .eventRegistration: EventRegistrationView()
        case .gradeHistory: GradeHistoryView()
        case .graduationThreshold: GraduationThresholdView()
        case .mail: NativeMailView(account: appState.currentUser?.username ?? "", isAuthenticated: appState.isAuthenticated)
        case .enrollmentCertificate: EnrollmentCertificateView()
        case .postalQuery: PostalQueryView()
        case .tools: HomeToolsView()
        case .leaveApplication: LeaveRecordsView()
        }
    }

    // MARK: - Load Today's Courses

    private static let weekdayNames = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
    private static let cacheKey = "classSchedule.v2.cachedData"

    private func loadTodayCourses() {
        isLoadingCourses = true
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(ClassSchedule.self, from: data) {
            let schedule = cached.withCustomCourses(from: UserDefaults(suiteName: "group.dev.chien.niuapp"), weekContaining: Date())
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
        let weekday = ScheduleClock.calendar.component(.weekday, from: Date())
        let mondayBased = (weekday + 5) % 7
        guard mondayBased < Self.weekdayNames.count else { return ([], false) }
        let todayName = Self.weekdayNames[mondayBased]
        guard let colIndex = schedule.dayHeaders.firstIndex(of: todayName) else { return ([], false) }

        let todaysAll = schedule.periods.compactMap { period -> (period: ClassPeriod, course: CourseInfo)? in
            guard let course = period.course(for: colIndex) else { return nil }
            return (period, course)
        }

        let now = ScheduleClock.calendar.dateComponents([.hour, .minute], from: Date())
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

    private func toggleNameMask() {
        isNameMasked.toggle()
        guard !reduceMotion else {
            stopNameScramble()
            return
        }
        scrambledName = scramble(homeDisplayName, revealedCount: 0)
        nameGlitchOffset = 0
        nameScrambleRequest = UUID()
    }

    @MainActor
    private func animateNameScramble(request: UUID?) async {
        guard let request, nameScrambleRequest == request else { return }
        let targetName = homeDisplayName
        do {
            for frame in 0..<12 {
                try Task.checkCancellation()
                guard nameScrambleRequest == request else { return }
                guard !reduceMotion, homeDisplayName == targetName else {
                    stopNameScramble()
                    return
                }
                let revealedCount = max(0, (frame - 3) * targetName.count / 8)
                scrambledName = scramble(targetName, revealedCount: revealedCount)
                nameGlitchOffset = frame < 8 ? CGFloat(frame % 3 - 1) : 0
                try await Task.sleep(for: .milliseconds(45))
            }
            if nameScrambleRequest == request { stopNameScramble() }
        } catch {
            // A cancelled transition must not clear a newer button press.
            if nameScrambleRequest == request { stopNameScramble() }
        }
    }

    private func stopNameScramble() {
        nameScrambleRequest = nil
        scrambledName = nil
        nameGlitchOffset = 0
    }

    private func scramble(_ name: String, revealedCount: Int) -> String {
        String(name.enumerated().map { index, character in
            index < revealedCount ? character : (Self.scrambleCharacters.randomElement() ?? "＃")
        })
    }

    private func animatedHomeName(font: Font) -> some View {
        // The resolved name reserves space and is the only name exposed to VoiceOver.
        Text(homeDisplayName)
            .font(font)
            .foregroundStyle(scrambledName == nil ? Theme.Colors.label : Color.clear)
            .overlay(alignment: .leading) {
                if let scrambledName {
                    Text(scrambledName)
                        .font(font.monospaced())
                        .foregroundStyle(LinearGradient(
                            colors: colorScheme == .dark ? [.cyan, .mint] : [.blue, .teal],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .shadow(color: .cyan.opacity(0.3), radius: 2)
                        .offset(x: nameGlitchOffset)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(homeDisplayName)
    }

    private var headerSection: some View {
        HStack {
            NavigationLink(value: HomeRoute(destination: .settings)) {
                HStack(spacing: Theme.Spacing.small) {
                    NIUAvatar(homeDisplayName, size: .small)
                    VStack(alignment: .leading, spacing: 2) {
                        animatedHomeName(font: .system(size: 14, weight: .semibold))
                        Text("國立宜蘭大學")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            NavigationLink(value: HomeRoute(destination: .settings)) {
                iconButtonAppearance("gearshape")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("設定")
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

            HStack(spacing: Theme.Spacing.xxsmall) {
                animatedHomeName(font: .system(size: 32, weight: .bold))
                    .layoutPriority(1)

                Button {
                    toggleNameMask()
                } label: {
                    Image(systemName: isNameMasked ? "eye.slash" : "eye")
                        .font(.callout.weight(.regular))
                        .foregroundStyle(Theme.Colors.secondaryLabel.opacity(0.65))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isNameMasked ? "顯示完整姓名" : "隱藏完整姓名")
                .accessibilityValue(isNameMasked ? "姓名已打碼" : "姓名完整顯示")
            }
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
                    navigationPath.append(HomeRoute(destination: .classSchedule))
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
            navigationPath.append(HomeRoute(destination: .classSchedule))
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
        NavigationLink(value: HomeRoute(destination: .attendance)) {
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
            .adaptiveGlass(
                interactive: true,
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
                    destination: .moodle
                )

                FeatureCard(
                    icon: "tablecells",
                    title: "我的課表",
                    subtitle: "查看每週課程安排",
                    color: .purple,
                    destination: .classSchedule
                )

                FeatureCard(
                    icon: "qrcode",
                    title: "圖書館通行碼",
                    subtitle: "門禁 QR Code 與借書條碼",
                    color: .indigo,
                    destination: .library
                )

                FeatureCard(
                    icon: "calendar",
                    title: "學年度行事曆",
                    subtitle: "查看學期重要日程",
                    color: .orange,
                    destination: .academicCalendar
                )

                FeatureCard(
                    icon: "calendar.badge.plus",
                    title: "活動報名",
                    subtitle: "參加校園活動",
                    color: .green,
                    destination: .eventRegistration
                )

                FeatureCard(
                    icon: "chart.bar.doc.horizontal",
                    title: "成績查詢",
                    subtitle: "歷年成績與 GPA",
                    color: .orange,
                    destination: .gradeHistory
                )

                FeatureCard(
                    icon: "checkmark.seal",
                    title: "畢業門檻",
                    subtitle: "多元時數、英文、體適能",
                    color: .teal,
                    destination: .graduationThreshold
                )

                FeatureCard(
                    icon: "envelope.fill",
                    title: "校園信箱",
                    subtitle: "收發郵件、回覆與附件",
                    color: .blue,
                    destination: .mail
                )

                FeatureCard(
                    icon: "doc.text",
                    title: "在學證明",
                    subtitle: "註冊查詢、顯示與列印",
                    color: .cyan,
                    destination: .enrollmentCertificate
                )

                FeatureCard(
                    icon: "calendar.badge.clock",
                    title: "請假",
                    subtitle: "我的假單、申請、修改與撤回",
                    color: .mint,
                    destination: .leaveApplication
                )

                FeatureCard(
                    icon: "square.grid.2x2.fill",
                    title: "小工具",
                    subtitle: "設備租借、郵件包裹",
                    color: .brown,
                    destination: .tools
                )
            }
            .opacity(animateIn ? 1 : 0)
            .animation(Theme.Animation.fast.delay(0.7), value: animateIn)
        }
    }
}

private struct HomeToolsView: View {
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: Theme.Spacing.medium),
                GridItem(.flexible(), spacing: Theme.Spacing.medium)
            ], spacing: Theme.Spacing.medium) {
                FeatureCard(
                    icon: "calendar.badge.clock",
                    title: "設備租借",
                    subtitle: "圖書館空間與設備預約",
                    color: .teal,
                    destination: .libraryEquipment
                )
                FeatureCard(
                    icon: "shippingbox.fill",
                    title: "郵件包裹查詢",
                    subtitle: "查詢收件與領取狀態",
                    color: .brown,
                    destination: .postalQuery
                )
            }
            .padding(Theme.Spacing.large)
        }
        .background(Theme.Colors.groupedBackground)
        .navigationTitle("小工具")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

// MARK: - Feature Card

private struct FeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let destination: HomeDestination

    var body: some View {
        NavigationLink(value: HomeRoute(destination: destination)) {
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
    HomeView()
        .environmentObject(AppState())
        .environmentObject(CampusRouter.shared)
}
