import SwiftUI
import Charts
import WebKit

struct GradeHistoryView: View {
    @StateObject private var vm = GradeHistoryViewModel()
    @State private var showsGPAInfo = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            switch vm.loadState {
            case .idle, .loading:
                ProgressView(loadingText)

            case .error(let message):
                ContentUnavailableView {
                    Label("無法載入成績", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重新載入", action: vm.refresh)
                        .buttonStyle(.bordered)
                }

            case .loaded:
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        if vm.selectedMode == .history {
                            historyContent
                        } else {
                            termContent
                        }
                        AcademicRefreshFooter(
                            lastUpdated: vm.lastUpdated,
                            isRefreshing: vm.isRefreshing,
                            errorMessage: vm.lastRefreshError,
                            onRetry: vm.refresh
                        )
                    }
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.small)
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .refreshable { await vm.refreshAndWait() }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { modePicker }
        .navigationTitle("成績查詢")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if vm.isModeLoading {
                    ProgressView()
                } else {
                    Button(action: vm.refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重新整理成績")
                }
            }
        }
        .sheet(isPresented: $showsGPAInfo) { GPAInfoSheet() }
        .overlay {
            if vm.showWebView {
                GradeHistoryWebView(mode: vm.selectedMode) { [requestID = vm.webViewID] result in
                    vm.handleWebResult(result, requestID: requestID)
                }
                    .id(vm.webViewID)
                    .frame(width: 360, height: 640)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
        .task { vm.startIfNeeded() }
        .onDisappear { vm.cancelLoading() }
    }

    private var loadingText: String {
        switch vm.selectedMode {
        case .midterm: return "載入期中成績…"
        case .final: return "載入期末成績…"
        case .history: return "載入歷年成績…"
        }
    }

    private var modePicker: some View {
        Picker("查詢模式", selection: $vm.selectedMode) {
            ForEach(GradeQueryMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.xsmall)
        .background(.bar)
        .onChange(of: vm.selectedMode) { _, mode in
            vm.selectMode(mode)
        }
    }

    // MARK: - History

    private var selectedSemester: SemesterGrade? {
        vm.selectedSemesterID.flatMap { id in vm.semesters.first { $0.id == id } }
    }

    @ViewBuilder
    private var historyContent: some View {
        let summary = vm.summary
        GPAOverviewCard(
            title: selectedSemester.map { "\($0.shortTitle) 學期 GPA" } ?? "累計 GPA",
            summary: summary,
            onInfo: { showsGPAInfo = true }
        )

        if selectedSemester == nil, summary.trend.count >= 2 {
            GradeTrendCard(points: summary.trend)
        }

        HStack {
            Text("各學期成績")
                .font(.headline)
            Spacer()
            semesterMenu
        }
        .padding(.top, Theme.Spacing.xsmall)

        if vm.displayedSemesters.isEmpty {
            ContentUnavailableView("尚無歷年成績", systemImage: "doc.text.magnifyingglass",
                                   description: Text("教務系統目前沒有可顯示的修課紀錄"))
        } else {
            ForEach(vm.displayedSemesters) { semester in
                GradeSemesterCard(
                    semester: semester,
                    isExpanded: vm.selectedSemesterID != nil || vm.expandedSemesters.contains(semester.id),
                    canToggle: vm.selectedSemesterID == nil,
                    toggle: {
                        withAnimation(Theme.Animation.standard) { vm.toggle(semester) }
                    }
                )
            }
        }
    }

    private var semesterMenu: some View {
        Menu {
            Picker("學期", selection: $vm.selectedSemesterID) {
                Text("全部學期").tag(String?.none)
                ForEach(vm.semesters) { semester in
                    Text(semester.termTitle).tag(Optional(semester.id))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedSemester?.shortTitle ?? "全部學期")
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.subheadline)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("篩選學期")
        .accessibilityValue(selectedSemester?.termTitle ?? "全部學期")
    }

    // MARK: - Midterm / final

    @ViewBuilder
    private var termContent: some View {
        if let snapshot = vm.termSnapshot, !snapshot.courses.isEmpty {
            let publishedCount = snapshot.courses.filter { $0.scoreText.nilIfPlaceholder != nil }.count
            GradeCard {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    if let title = snapshot.semesterTitle.nilIfPlaceholder {
                        Text(title)
                            .font(.headline)
                    }
                    MetricRow(metrics: [
                        (vm.selectedMode == .midterm ? "期中平均" : "期末平均",
                         snapshot.averageText.nilIfPlaceholder ?? "未公布"),
                        ("班排名", snapshot.rankText.nilIfPlaceholder ?? "未公布"),
                        ("已公布", "\(publishedCount) / \(snapshot.courses.count) 科")
                    ])
                }
                .padding(Theme.Spacing.medium)
            }

            GradeCard {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.courses.enumerated()), id: \.offset) { index, course in
                        if index > 0 { Divider().padding(.leading, Theme.Spacing.medium) }
                        TermScoreRow(course: course)
                    }
                }
            }
        } else {
            ContentUnavailableView("尚無\(vm.selectedMode.rawValue)成績", systemImage: "doc.text.magnifyingglass",
                                   description: Text("教師登錄成績後就會顯示在這裡"))
        }
    }
}

// MARK: - Building blocks

private struct GradeCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

/// 三欄數據；放大文字時改為直排，避免窄螢幕截字。
private struct MetricRow: View {
    let metrics: [(title: String, value: String)]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.xsmall))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.small))
        layout {
            ForEach(metrics, id: \.title) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(metric.value)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private extension Double {
    var gpaText: String { String(format: "%.2f", self) }
    var creditText: String { formatted(.number.precision(.fractionLength(0...1))) }
}

// MARK: - GPA overview

private struct GPAOverviewCard: View {
    let title: String
    let summary: GradeHistorySummary
    let onInfo: () -> Void

    var body: some View {
        GradeCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(action: onInfo) {
                        Image(systemName: "info.circle")
                            .font(.body)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, -10)
                    .accessibilityLabel("GPA 計算說明")
                    .accessibilityHint("說明 GPA 為估算值及計算公式")
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(summary.cumulativeGPA?.gpaText ?? "—")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .monospacedDigit()
                        Text("/ \(GPAFormula.maxGPA, specifier: "%.1f")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(1, (summary.cumulativeGPA ?? 0) / GPAFormula.maxGPA))
                        .tint(.primary)
                    Text("依各科成績換算的估算值，僅供參考")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(summary.cumulativeGPA.map {
                    "\($0.gpaText)，滿分 \(GPAFormula.maxGPA)，估算值，僅供參考"
                } ?? "無法計算")

                Divider()

                MetricRow(metrics: [
                    ("加權平均", summary.averageScore.map { String(format: "%.1f", $0) } ?? "—"),
                    ("實得學分", "\(summary.earnedCredits.creditText) / \(summary.attemptedCredits.creditText)"),
                    ("課程數", "\(summary.courseCount)")
                ])
            }
            .padding(Theme.Spacing.medium)
        }
    }
}

// MARK: - Trend chart

private struct GradeTrendCard: View {
    let points: [GradeHistorySummary.SemesterTrendPoint]
    private let visibleCount = 6

    var body: some View {
        GradeCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("各學期 GPA 走勢")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                chart
                    .frame(height: 170)
            }
            .padding(Theme.Spacing.medium)
        }
    }

    @ViewBuilder
    private var chart: some View {
        let base = Chart(points) { point in
            LineMark(x: .value("學期", point.label), y: .value("GPA", point.gpa))
                .foregroundStyle(Color.primary.opacity(0.85))
            PointMark(x: .value("學期", point.label), y: .value("GPA", point.gpa))
                .foregroundStyle(Color.primary)
                .annotation(position: .top, spacing: 4) {
                    Text(point.gpa.gpaText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
        .chartYScale(domain: 0...GPAFormula.maxGPA)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 1, 2, 3, 4]) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel()
            }
        }

        if points.count > visibleCount, let last = points.last {
            base
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visibleCount)
                .chartScrollPosition(initialX: last.label)
        } else {
            base
        }
    }
}

// MARK: - Semester card

private struct GradeSemesterCard: View {
    let semester: SemesterGrade
    let isExpanded: Bool
    let canToggle: Bool
    let toggle: () -> Void

    var body: some View {
        GradeCard {
            VStack(spacing: 0) {
                if canToggle {
                    Button(action: toggle) {
                        header
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isExpanded ? "已展開" : "已收合")
                    .accessibilityHint(isExpanded ? "收合課程列表" : "顯示課程列表")
                } else {
                    header
                        .accessibilityElement(children: .combine)
                }

                if isExpanded {
                    Divider()
                    ForEach(Array(semester.courses.enumerated()), id: \.offset) { index, course in
                        if index > 0 { Divider().padding(.leading, Theme.Spacing.medium) }
                        GradeCourseRow(course: course)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 4) {
                Text(semester.termTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detailLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let rankText {
                    Text(rankText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if semester.failedCount > 0 {
                    Label("\(semester.failedCount) 科不及格", systemImage: "exclamationmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
            }

            Spacer(minLength: Theme.Spacing.xsmall)

            VStack(alignment: .trailing, spacing: 0) {
                Text(semester.displayGPA?.gpaText ?? "—")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("GPA")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if canToggle {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var detailLine: String {
        ["平均 \(String(format: "%.1f", semester.averageScore))",
         "\(semester.earnedCredits.creditText)/\(semester.attemptedCredits.creditText) 學分"]
            .joined(separator: " · ")
    }

    private var rankText: String? {
        let parts = [
            Self.formatRank("班排", semester.classRank),
            Self.formatRank("系排", semester.departmentRank)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 校方只給名次時顯示「第 3 名」，有總人數時顯示「第 3 名 / 45 人」。
    private static func formatRank(_ label: String, _ raw: String?) -> String? {
        guard let rank = raw?.nilIfPlaceholder else { return nil }
        let numbers = rank.split(whereSeparator: { !$0.isNumber })
        switch numbers.count {
        case 1 where rank.allSatisfy({ $0.isNumber || $0.isWhitespace }):
            return "\(label) 第 \(numbers[0]) 名"
        case 2 where rank.contains("/"):
            return "\(label) 第 \(numbers[0]) 名 / \(numbers[1]) 人"
        default:
            return "\(label) \(rank)"
        }
    }
}

private struct GradeCourseRow: View {
    let course: GradeCourse

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Theme.Spacing.xsmall)

            VStack(alignment: .trailing, spacing: 2) {
                Text(course.displayScore)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(isFailed ? .red : .primary)
                Text(gradeCaption)
                    .font(.caption2)
                    .foregroundStyle(isFailed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .accessibilityElement(children: .combine)
    }

    private var isFailed: Bool { course.hasNumericScore && !course.passed }

    private var detailLine: String {
        var parts = [course.category.shortLabel, "\(course.credits.creditText) 學分"]
        if let remark = course.remarks, !remark.isEmpty, remark != course.displayScore {
            parts.append(remark)
        }
        return parts.joined(separator: " · ")
    }

    private var gradeCaption: String {
        if isFailed { return "不及格" }
        guard let letter = course.letterGrade else { return "不計 GPA" }
        guard let point = course.gradePoint else { return "\(letter) · 不計 GPA" }
        return "\(letter) · \(String(format: "%.1f", point))"
    }
}

private struct TermScoreRow: View {
    let course: TermScoreCourse

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(course.type.isEmpty ? "未分類" : course.type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Theme.Spacing.xsmall)

            VStack(alignment: .trailing, spacing: 2) {
                Text(course.scoreText.nilIfPlaceholder ?? "未公布")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(score == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(isFailed ? Color.red : Color.primary))
                if isFailed {
                    Text("不及格")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .accessibilityElement(children: .combine)
    }

    private var score: Double? { Double(course.scoreText.trimmingCharacters(in: .whitespaces)) }
    private var isFailed: Bool { (score ?? 100) < 60 }
}

// MARK: - GPA info

private struct GPAInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text("校方沒有提供 GPA，本頁的 GPA 是 App 依各科成績自行換算，可能與學校的正式紀錄有誤差，僅供參考。申請升學、獎學金或交換等正式用途，請以學校核發的成績單為準。")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Text("GPA = Σ（各科績分 × 學分）÷ Σ 學分")
                        .font(.body.weight(.semibold))
                    Text("例如：3 學分 85 分（A，4.0）與 2 學分 72 分（B-，2.7）\n(4.0 × 3 + 2.7 × 2) ÷ 5 = 3.48")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("計算公式")
                }

                Section {
                    ForEach(GPAFormula.bands) { band in
                        HStack {
                            Text(band.range)
                                .monospacedDigit()
                            Spacer()
                            Text(band.letter)
                                .frame(minWidth: 32, alignment: .leading)
                            Text(String(format: "%.1f", band.points))
                                .monospacedDigit()
                                .frame(minWidth: 36, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(band.range) 分，等第 \(band.letter)，績分 \(String(format: "%.1f", band.points))")
                    }
                } header: {
                    HStack {
                        Text("分數")
                        Spacer()
                        Text("等第　績分")
                    }
                } footer: {
                    Text("採台灣多數大學使用的 4.3 制對照，並非校方公告的換算方式。")
                }

                Section {
                    Text("只計入學分大於 0 且有數字成績的課程；抵免、通過等文字成績不列入 GPA。")
                    Text("不及格科目以 0 績分計入。")
                    Text("重修的課程每次修課都會計入，可能與學校的採計方式不同。")
                    Text("累計 GPA 以所有學期的課程直接按學分加權，不是各學期 GPA 的平均。")
                } header: {
                    Text("計算方式")
                }
                .font(.subheadline)
            }
            .navigationTitle("GPA 計算說明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private extension String {
    var nilIfPlaceholder: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "-" || trimmed == "--" || trimmed == "尚未計算" || trimmed == "尚未公佈" {
            return nil
        }
        return trimmed
    }
}

private extension Optional where Wrapped == String {
    var nilIfPlaceholder: String? {
        self?.nilIfPlaceholder
    }
}

enum GradeHistoryWebResult {
    case historySuccess([SemesterGrade])
    case termSuccess(TermScoreSnapshot)
    case sessionExpired
    case failure(String)
}

private struct GradeHistoryCourseDTO: Decodable {
    let year: Int?
    let term: String?
    let code: String
    let name: String
    let courseType: String?
    let credits: Double
    let scoreText: String
    let remark: String
    let classRank: String?
    let departmentRank: String?
    let averageText: String?
}

private struct TermScoreCourseDTO: Decodable {
    let type: String
    let lesson: String
    let score: String
}

private struct TermScoreSnapshotDTO: Decodable {
    let semesterTitle: String?
    let averageText: String?
    let rankText: String?
    let rows: [TermScoreCourseDTO]
}

private struct GradeHistoryWebView: UIViewRepresentable {
    let mode: GradeQueryMode
    let onResult: (GradeHistoryWebResult) -> Void

    private static let modernLoginURLPrefix = "https://ccsys1.niu.edu.tw/SSO/login"
    private static let acadeMainFrameURL = "https://acade.niu.edu.tw/NIU/MainFrame.aspx"

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, onResult: onResult)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // MenuRedirect.aspx opens the history SSO page with window.open after
        // navigation. iOS blocks it without this setting (macOS permits it).
        // The UI delegate loads that request in this same WebView.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Notify Swift for every frame, including cross-origin MvcTeam pages.
        // JavaScript in MainFrame cannot inspect a cross-origin frame's DOM.
        config.userContentController.add(context.coordinator, name: "gradeFrame")
        config.userContentController.addUserScript(WKUserScript(source: """
            window.webkit.messageHandlers.gradeFrame.postMessage({
                history: !!document.querySelector('#accordion修課紀錄'),
                term: !!document.querySelector('#DataGrid')
            });
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: false))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/17.0 Safari/605.1.15"
        context.coordinator.webView = webView

        context.coordinator.start(webView: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let mode: GradeQueryMode
        let onResult: (GradeHistoryWebResult) -> Void
        weak var webView: WKWebView?

        fileprivate var step: Step = .resolveEntryLink
        private var active = true
        private var cancelled = false
        private var acadeMenuNavigationInFlight = false
        private var contentFrame: WKFrameInfo?
        private var bridgeTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?

        fileprivate enum Step {
            case resolveEntryLink
            case waitForMainEntry
            case waitForTargetPage
            case waitForParse
        }

        var startURL: String {
            "https://ccsys.niu.edu.tw/SSO/Std002.aspx"
        }

        init(mode: GradeQueryMode, onResult: @escaping (GradeHistoryWebResult) -> Void) {
            self.mode = mode
            self.onResult = onResult
        }

        func start(webView: WKWebView) {
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(65)) } catch { return }
                self?.finish(.failure("成績頁面載入逾時，請稍後重試"))
            }
            bridgeTask = Task { [weak self, weak webView] in
                let account = SSOTokenStore.shared.account
                    ?? LoginRepository.shared.getSavedCredentials()?.username ?? ""
                let guid = account.isEmpty ? nil : await SSOGUIDBridge.fetchGUID(account: account)
                guard !Task.isCancelled, let self, self.active, let webView else { return }
                guard let guid, let url = SSOGUIDBridge.acadeLoginURL(guid: guid) else {
                    self.finish(.sessionExpired)
                    return
                }
                self.step = .waitForMainEntry
                webView.load(URLRequest(url: url))
            }
        }

        func cancel() {
            active = false
            cancelled = true
            bridgeTask?.cancel()
            timeoutTask?.cancel()
            contentFrame = nil
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "gradeFrame")
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView?.stopLoading()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, message.name == "gradeFrame", let webView,
                  let url = message.frameInfo.request.url,
                  ["acade.niu.edu.tw", "ccsys.niu.edu.tw", "ccsys1.niu.edu.tw"].contains(url.host?.lowercased() ?? "") else { return }
            if SSOGUIDBridge.isSessionExpiredURL(url) {
                finish(.sessionExpired)
                return
            }
            let markers = message.body as? [String: Bool] ?? [:]
            let isTarget = mode == .history
                ? (isHistoryTargetURL(url.absoluteString) || markers["history"] == true)
                // The portal homepage also has a DataGrid; that alone is not a grade page.
                : isTermTargetURL(url.absoluteString)
            guard isTarget else { return }
            contentFrame = message.frameInfo
            print("[GradeHistory] target frame host=\(url.host ?? "") path=\(url.path)")
            beginParsing(webView: webView)
        }

        private func beginParsing(webView: WKWebView) {
            guard active, step != .waitForParse else { return }
            acadeMenuNavigationInFlight = false
            step = .waitForParse
            if mode == .history {
                pollForHistoryCourses(webView: webView, attempt: 0)
            } else {
                pollForTermScores(webView: webView, attempt: 0)
            }
        }

        private func evaluateContentJavaScript(_ script: String, webView: WKWebView,
                                                completion: @escaping (Any?, Error?) -> Void) {
            webView.evaluateJavaScript(script, in: contentFrame, in: .page) { result in
                switch result {
                case .success(let value): completion(value, nil)
                case .failure(let error): completion(nil, error)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard active else { return }
            let url = webView.url?.absoluteString ?? ""
            print("[GradeHistory] mode=\(mode.rawValue) step=\(step) path=\(webView.url?.path ?? "")")

            if let current = webView.url, SSOGUIDBridge.isSessionExpiredURL(current) {
                finish(.sessionExpired)
                return
            }

            switch step {
            case .resolveEntryLink:
                handleEntryPage(webView: webView, currentURL: url)

            case .waitForMainEntry:
                handleMainEntryPage(webView: webView, currentURL: url)

            case .waitForTargetPage:
                if (mode == .history && isHistoryTargetURL(url)) || isTermTargetURL(url) {
                    beginParsing(webView: webView)
                }

            case .waitForParse:
                break
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard active else { return }
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }
            finish(.failure("成績查詢連線失敗，請檢查網路後重試"))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            finish(.failure("成績查詢連線失敗，請檢查網路後重試"))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(.failure("成績網頁已中斷，請重試"))
        }

        private func handleEntryPage(webView: WKWebView, currentURL: String) {
            if currentURL.contains("MainFrame.aspx") {
                step = .waitForMainEntry
                openAcadeMenuTarget(webView: webView, attempt: 0)
            } else if isHistoryTargetURL(currentURL) || isTermTargetURL(currentURL) {
                beginParsing(webView: webView)
            } else if currentURL.contains("Std002.aspx") || currentURL.contains("StdMain.aspx") || currentURL.contains("/MvcTeam/Act") {
                extractAcadeLinkAndNavigate(webView: webView)
            }
        }

        private func handleMainEntryPage(webView: WKWebView, currentURL: String) {
            if currentURL.contains("MainFrame.aspx") {
                openAcadeMenuTarget(webView: webView, attempt: 0)
            } else if isHistoryTargetURL(currentURL) || isTermTargetURL(currentURL) {
                beginParsing(webView: webView)
            }
        }

        private func extractAcadeLinkAndNavigate(webView: WKWebView) {
            let js = """
            (function() {
                var el = document.getElementById('ctl00_ContentPlaceHolder1_RadListView1_ctrl0_HyperLink1');
                return el ? (el.getAttribute('href') || '') : '';
            })()
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, self.active else { return }
                let href = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !href.isEmpty else {
                    self.navigateToAcadeMainFrame(webView: webView)
                    return
                }

                let fullURL: String
                if href.hasPrefix("http") {
                    fullURL = href
                } else if href.hasPrefix("/") {
                    fullURL = "https://ccsys.niu.edu.tw" + href
                } else if href.contains("JumpTo(") {
                    let pattern = #"['"]([^'"]+)['"]"#
                    if let range = href.range(of: pattern, options: .regularExpression) {
                        let raw = String(href[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if raw.hasPrefix("http") {
                            fullURL = raw
                        } else if raw.hasPrefix("/") {
                            fullURL = "https://ccsys.niu.edu.tw" + raw
                        } else {
                            fullURL = "https://ccsys.niu.edu.tw/" + raw
                        }
                    } else {
                        self.navigateToAcadeMainFrame(webView: webView)
                        return
                    }
                } else {
                    let clean = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
                    fullURL = "https://ccsys.niu.edu.tw/SSO/" + clean
                }

                guard let url = URL(string: fullURL) else {
                    self.navigateToAcadeMainFrame(webView: webView)
                    return
                }

                self.step = .waitForMainEntry
                webView.load(URLRequest(url: url))
            }
        }

        private func navigateToAcadeMainFrame(webView: WKWebView) {
            guard let url = URL(string: GradeHistoryWebView.acadeMainFrameURL) else {
                finish(.failure("無法進入教務系統"))
                return
            }
            print("[GradeHistory] navigate acade mainframe -> \(url.absoluteString)")
            acadeMenuNavigationInFlight = false
            step = .waitForMainEntry
            webView.load(URLRequest(url: url))
        }

        private func openAcadeMenuTarget(webView: WKWebView, attempt: Int) {
            guard active else { return }
            guard attempt < 30 else {
                acadeMenuNavigationInFlight = false
                finish(.failure("無法開啟成績查詢頁面"))
                return
            }
            guard !acadeMenuNavigationInFlight || attempt > 0 else { return }

            acadeMenuNavigationInFlight = true

            let targetLabel: String
            switch mode {
            case .midterm:
                targetLabel = "學生查詢期中成績"
            case .final:
                targetLabel = "學生查詢當學期成績"
            case .history:
                targetLabel = "學生歷年學期成績及排名查詢"
            }

            let js = """
            (function() {
                function normalize(value) {
                    return String(value || '').replace(/\\s+/g, ' ').trim();
                }

                var menuWin = window.frames['menuFrame'];
                if (!menuWin || !menuWin.document) return 'missing-menu-frame';

                var links = Array.from(menuWin.document.querySelectorAll('a'));

                function findLink(keyword) {
                    return links.find(function(link) {
                        return normalize(link.innerText || link.textContent).indexOf(keyword) >= 0;
                    });
                }

                var leaf = findLink('\(targetLabel)');
                if (leaf) {
                    leaf.click();
                    return 'clicked-leaf';
                }

                var scoreQuery = findLink('成績查詢作業');
                if (scoreQuery) {
                    scoreQuery.click();
                    return 'clicked-score-query';
                }

                var scoreRoot = findLink('成績及計分冊');
                if (scoreRoot) {
                    scoreRoot.click();
                    return 'clicked-score-root';
                }

                return 'missing-target';
            })()
            """
            webView.evaluateJavaScript(js) { [weak self, weak webView] result, _ in
                guard let self, let webView, self.active else { return }
                let state = (result as? String) ?? "unknown"
                print("[GradeHistory] open menu target attempt=\(attempt) state=\(state)")

                if state == "clicked-leaf" {
                    self.acadeMenuNavigationInFlight = false
                    // Wait for the destination's frame message. The previous portal
                    // may still contain a DataGrid while the target is navigating.
                    if self.step != .waitForParse { self.step = .waitForTargetPage }
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.openAcadeMenuTarget(webView: webView, attempt: attempt + 1)
                }
            }
        }

        private func isTermTargetURL(_ url: String) -> Bool {
            switch mode {
            case .midterm:
                return url.contains("GRD5131")
            case .final:
                return url.contains("GRD5130")
            case .history:
                return false
            }
        }

        private func isHistoryTargetURL(_ url: String) -> Bool {
            url.contains("/MvcTeam/Tutor/StudentCourseScore")
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard active, navigationAction.targetFrame == nil else { return nil }
            print("[GradeHistory] intercept popup path=\(navigationAction.request.url?.path ?? "")")
            contentFrame = nil
            webView.load(navigationAction.request)
            return nil
        }

        private func pollForHistoryCourses(webView: WKWebView, attempt: Int) {
            guard active else { return }
            guard attempt < 180 else {
                finish(.failure("歷年成績載入逾時，請稍後再試"))
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak webView] in
                guard let self, let webView, self.active else { return }

                let js = """
                (function() {
                    function clean(s) {
                        return String(s || '').replace(/\\s+/g, ' ').trim();
                    }

                    function collectDocs(win, seen, docs) {
                        if (!win) return;
                        try {
                            if (seen.indexOf(win) >= 0) return;
                            seen.push(win);
                            if (win.document) docs.push(win.document);
                            for (var i = 0; i < win.frames.length; i++) {
                                collectDocs(win.frames[i], seen, docs);
                            }
                        } catch (error) {}
                    }

                    function termFromDigit(d) {
                        if (d === '1') return '上';
                        if (d === '2') return '下';
                        if (d === '3') return '暑';
                        return '';
                    }

                    function parseSemRaw(v) {
                        var m = clean(v).match(/^(\\d{2,3})([123])$/);
                        if (!m) return null;
                        return {
                            year: parseInt(m[1], 10),
                            term: termFromDigit(m[2]),
                            key: m[1] + m[2]
                        };
                    }

                    var docs = [];
                    collectDocs(window, [], docs);

                    var targetDoc = null;
                    for (var d = 0; d < docs.length; d++) {
                        try {
                            if (docs[d].querySelector('#accordion修課紀錄')) {
                                targetDoc = docs[d];
                                break;
                            }
                        } catch (error) {}
                    }

                    if (!targetDoc) {
                        for (var d2 = 0; d2 < docs.length; d2++) {
                            try {
                                var bodyText = clean(docs[d2].body && docs[d2].body.textContent);
                                if (bodyText.indexOf('歷年學業成績及排名') >= 0) {
                                    targetDoc = docs[d2];
                                    break;
                                }
                            } catch (error) {}
                        }
                    }

                    if (!targetDoc) return '';

                    // The school's accordion is mutually exclusive. All rows already
                    // exist in the DOM, so read hidden panels without clicking them.
                    // Course tables also sit in div.row and start with the same
                    // 學年期 column, so find the summary table by its rank header
                    // and map columns by header text instead of fixed indexes.
                    var summaryBySem = {};
                    var summaryTables = targetDoc.querySelectorAll('table.table');
                    for (var s = 0; s < summaryTables.length; s++) {
                        var summaryTable = summaryTables[s];
                        if (summaryTable.closest && summaryTable.closest('#accordion修課紀錄')) continue;
                        var summaryRows = summaryTable.querySelectorAll('tr');
                        if (!summaryRows.length) continue;
                        var headers = Array.prototype.map.call(
                            summaryRows[0].querySelectorAll('th,td'),
                            function(cell) { return clean(cell.textContent); }
                        );
                        function columnOf(keyword) {
                            for (var h = 0; h < headers.length; h++) {
                                if (headers[h].indexOf(keyword) >= 0) return h;
                            }
                            return -1;
                        }
                        var semCol = columnOf('學年期');
                        var deptCol = columnOf('系排名');
                        var classCol = columnOf('班排名');
                        var avgCol = columnOf('平均');
                        if (semCol < 0 || (deptCol < 0 && classCol < 0)) continue;

                        for (var i = 1; i < summaryRows.length; i++) {
                            var tds = summaryRows[i].querySelectorAll('td');
                            if (!tds || tds.length <= semCol) continue;
                            var sem = parseSemRaw(tds[semCol].textContent);
                            if (!sem) continue;
                            function cellText(col) {
                                return col >= 0 && col < tds.length ? clean(tds[col].textContent) : '';
                            }
                            summaryBySem[sem.key] = {
                                classRank: cellText(classCol),
                                departmentRank: cellText(deptCol),
                                averageText: cellText(avgCol)
                            };
                        }
                        break;
                    }

                    var records = [];
                    var tables = targetDoc.querySelectorAll('#accordion修課紀錄 table.table.table-striped');
                    if (!tables.length) {
                        tables = targetDoc.querySelectorAll('table.table.table-striped');
                    }

                    for (var t = 0; t < tables.length; t++) {
                        var rows = tables[t].querySelectorAll('tr');
                        for (var r = 1; r < rows.length; r++) {
                            var cells = rows[r].querySelectorAll('td');
                            if (!cells || cells.length < 5) continue;

                            var semRaw = clean(cells[0].textContent);
                            var sem = parseSemRaw(semRaw);
                            if (!sem) continue;

                            var courseType = clean(cells[1].textContent);
                            var creditsRaw = clean(cells[2].textContent);
                            var credits = parseFloat(creditsRaw);
                            var name = clean(cells[3].textContent);
                            var scoreText = clean(cells[4].textContent);
                            if (!name || !scoreText) continue;

                            var summary = summaryBySem[sem.key] || {};
                            records.push({
                                year: sem.year,
                                term: sem.term,
                                code: sem.key + "_" + t + "_" + r,
                                name: name,
                                courseType: courseType,
                                credits: Number.isFinite(credits) ? credits : 0,
                                scoreText: scoreText,
                                remark: "",
                                classRank: summary.classRank || "",
                                departmentRank: summary.departmentRank || "",
                                averageText: summary.averageText || ""
                            });
                        }
                    }

                    return records.length ? JSON.stringify(records) : '';
                })()
                """

                self.evaluateContentJavaScript(js, webView: webView) { [weak self] result, _ in
                    guard let self, self.active else { return }
                    guard let json = result as? String, let data = json.data(using: .utf8) else {
                        self.pollForHistoryCourses(webView: webView, attempt: attempt + 1)
                        return
                    }

                    guard let courseRows = try? JSONDecoder().decode([GradeHistoryCourseDTO].self, from: data),
                          !courseRows.isEmpty else {
                        self.pollForHistoryCourses(webView: webView, attempt: attempt + 1)
                        return
                    }

                    // Only keep rows that can be confidently mapped to a semester.
                    let normalizedRows: [(year: Int, term: SemesterTerm, row: GradeHistoryCourseDTO)] =
                        courseRows.compactMap { row in
                            guard let parsed = Self.parseYearTerm(year: row.year, termRaw: row.term) else {
                                return nil
                            }
                            return (year: parsed.year, term: parsed.term, row: row)
                        }

                    let grouped = Dictionary(grouping: normalizedRows) { item in
                        "\(item.year)-\(item.term.rawValue)"
                    }

                    let semesters = grouped.values.compactMap { rows -> SemesterGrade? in
                        guard let first = rows.first else { return nil }
                        let year = first.year
                        let term = first.term

                        let courses: [GradeCourse] = rows.map { item in
                            let raw = item.row
                            let score = Double(raw.scoreText) ?? 0
                            let remarkFromScore = Double(raw.scoreText) == nil ? raw.scoreText : ""
                            let combinedRemark = [raw.remark, remarkFromScore]
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty && $0 != raw.name }
                                .joined(separator: " ")
                            return GradeCourse(
                                code: raw.code,
                                name: raw.name,
                                category: Self.mapCategory(raw.name, courseType: raw.courseType),
                                credits: raw.credits,
                                score: score,
                                gpa: nil,
                                remarks: combinedRemark.isEmpty ? nil : combinedRemark,
                                scoreText: raw.scoreText
                            )
                        }

                        let creditsTaken = courses.reduce(0.0) { $0 + $1.credits }
                        let creditsPassed = courses.filter { $0.passed }.reduce(0.0) { $0 + $1.credits }
                        let computedAverage = GPAFormula.weightedScore(courses) ?? 0
                        let sourceAverage = rows.compactMap { item in
                            Self.parseNumber(item.row.averageText)
                        }.first
                        let classRank = rows.compactMap { item in
                            item.row.classRank?.nilIfPlaceholder
                        }.first
                        let departmentRank = rows.compactMap { item in
                            item.row.departmentRank?.nilIfPlaceholder
                        }.first
                        let averageScore = sourceAverage ?? computedAverage

                        return SemesterGrade(
                            year: year,
                            term: term,
                            averageScore: averageScore,
                            gpa: nil,
                            creditsTaken: creditsTaken,
                            creditsPassed: creditsPassed,
                            classRank: classRank,
                            departmentRank: departmentRank,
                            courses: courses
                        )
                    }
                    .sorted { lhs, rhs in
                        if lhs.year == rhs.year { return lhs.term.order > rhs.term.order }
                        return lhs.year > rhs.year
                    }

                    print("[GradeHistory] history parse raw=\(courseRows.count) normalized=\(normalizedRows.count) semesters=\(semesters.count)")

                    if semesters.isEmpty {
                        self.finish(.failure("目前查無可解析的歷年成績資料"))
                    } else {
                        self.finish(.historySuccess(semesters))
                    }
                }
            }
        }

        private func pollForTermScores(webView: WKWebView, attempt: Int) {
            guard active else { return }
            guard attempt < 120 else {
                finish(.failure("\(mode.rawValue)成績載入逾時，請稍後再試"))
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak webView] in
                guard let self, let webView, self.active else { return }

                let js = """
                (function() {
                    function clean(value) {
                        return String(value || '').replace(/\\s+/g, ' ').trim();
                    }

                    function collectDocs(win, seen, docs) {
                        if (!win) return;
                        try {
                            if (seen.indexOf(win) >= 0) return;
                            seen.push(win);
                            if (win.document) docs.push(win.document);
                            for (var i = 0; i < win.frames.length; i++) {
                                collectDocs(win.frames[i], seen, docs);
                            }
                        } catch (error) {}
                    }

                    function firstText(selector) {
                        for (var i = 0; i < docs.length; i++) {
                            try {
                                var el = docs[i].querySelector(selector);
                                var value = clean(el ? el.innerText : '');
                                if (value) return value;
                            } catch (error) {}
                        }
                        return '';
                    }

                    function formatRank(raw) {
                        function normalizeIntText(s) {
                            var n = parseInt(String(s || '').replace(/[^0-9]/g, ''), 10);
                            return Number.isFinite(n) ? String(n) : '';
                        }
                        var cleaned = String(raw || '');
                        var slash = cleaned.match(/(\\d+)\\s*\\/\\s*(\\d+)/);
                        if (slash) {
                            var left = normalizeIntText(slash[1]);
                            var right = normalizeIntText(slash[2]);
                            return (left && right) ? (left + '/' + right) : '';
                        }
                        var nums = cleaned.match(/\\d+/g) || [];
                        if (nums.length >= 2) {
                            var first = normalizeIntText(nums[0]);
                            var last = normalizeIntText(nums[nums.length - 1]);
                            return (first && last) ? (first + '/' + last) : '';
                        }
                        return normalizeIntText(cleaned);
                    }

                    function semesterTitle() {
                        for (var i = 0; i < docs.length; i++) {
                            try {
                                var body = clean(docs[i].body && docs[i].body.innerText);
                                var match = body.match(/(\\d{2,3})\\s*學年度\\s*第?\\s*([上下暑123])\\s*學期/);
                                if (!match) continue;
                                var term = match[2];
                                if (term === '1') term = '上';
                                if (term === '2') term = '下';
                                if (term === '3') term = '暑';
                                return match[1] + ' 學年度第 ' + term + ' 學期';
                            } catch (error) {}
                        }
                        return '';
                    }

                    var docs = [];
                    collectDocs(window, [], docs);

                    var targetDoc = null;
                    for (var d = 0; d < docs.length; d++) {
                        try {
                            if (docs[d].querySelector('#DataGrid')) {
                                targetDoc = docs[d];
                                break;
                            }
                        } catch (error) {}
                    }
                    if (!targetDoc) return '';

                    var rows = [];
                    var tableRows = targetDoc.querySelectorAll('#DataGrid tr');
                    for (var i = 0; i < tableRows.length; i++) {
                        var cells = tableRows[i].querySelectorAll('td');
                        if (!cells || cells.length < 6) continue;
                        var type = clean(cells[3].innerText);
                        var lesson = clean(cells[4].innerText);
                        var score = clean(cells[5].innerText);
                        if (!lesson) continue;
                        rows.push({
                            type: type || '未分類',
                            lesson: lesson,
                            score: score || '-'
                        });
                    }

                    if (!rows.length) return '';

                    return JSON.stringify({
                        semesterTitle: semesterTitle(),
                        averageText: firstText('#Q_CRS_AVG_MARK'),
                        rankText: formatRank(firstText('#QTable2 > tbody > tr:nth-child(2) > td:nth-child(2) > table > tbody > tr:nth-child(2) > td:nth-child(4)')),
                        rows: rows
                    });
                })()
                """

                self.evaluateContentJavaScript(js, webView: webView) { [weak self] result, _ in
                    guard let self, self.active else { return }
                    guard let json = result as? String, let data = json.data(using: .utf8),
                          let dto = try? JSONDecoder().decode(TermScoreSnapshotDTO.self, from: data) else {
                        self.pollForTermScores(webView: webView, attempt: attempt + 1)
                        return
                    }

                    let courses = dto.rows.map {
                        TermScoreCourse(type: $0.type, name: $0.lesson, scoreText: $0.score)
                    }

                    if courses.isEmpty {
                        self.pollForTermScores(webView: webView, attempt: attempt + 1)
                        return
                    }

                    let snapshot = TermScoreSnapshot(
                        mode: self.mode,
                        semesterTitle: dto.semesterTitle?.nilIfPlaceholder,
                        averageText: dto.averageText?.nilIfPlaceholder,
                        rankText: dto.rankText?.nilIfPlaceholder,
                        courses: courses
                    )
                    self.finish(.termSuccess(snapshot))
                }
            }
        }

        private static func parseTerm(from raw: String?) -> SemesterTerm? {
            guard let raw else { return nil }
            if raw.contains("上") || raw == "1" { return .fall }
            if raw.contains("下") || raw == "2" { return .spring }
            if raw.contains("暑") || raw == "3" { return .summer }
            return nil
        }

        private static func parseYearTerm(year: Int?, termRaw: String?) -> (year: Int, term: SemesterTerm)? {
            if let year, year > 0 {
                if year >= 1000 {
                    let y = year / 10
                    let t = year % 10
                    if let term = parseTerm(from: String(t)) {
                        return (y, term)
                    }
                }
                if let term = parseTerm(from: termRaw) {
                    return (year, term)
                }
            }

            if let termRaw {
                let compact = termRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let m = compact.range(of: #"^(\d{2,3})([123])$"#, options: .regularExpression) {
                    let str = String(compact[m])
                    let yPart = String(str.dropLast())
                    let tPart = String(str.suffix(1))
                    if let y = Int(yPart), let term = parseTerm(from: tPart) {
                        return (y, term)
                    }
                }
            }

            return nil
        }

        private static func parseNumber(_ raw: String?) -> Double? {
            guard let raw else { return nil }
            let cleaned = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(cleaned)
        }

        private static func isModernLoginPage(_ urlString: String) -> Bool {
            urlString.contains("ccsys1.niu.edu.tw/SSO")
        }

        private static func isAcadeTimeOut(_ urlString: String) -> Bool {
            urlString.contains("TimeOutPage.aspx")
        }

        private static func mapCategory(_ courseName: String, courseType: String?) -> CourseCategory {
            if let courseType {
                if courseType.contains("必修") { return .required }
                if courseType.contains("選修") { return .elective }
            }
            if courseName.contains("體育") { return .physical }
            if courseName.contains("通識") { return .general }
            return .other
        }

        func finish(_ result: GradeHistoryWebResult) {
            guard active else { return }
            active = false
            bridgeTask?.cancel()
            timeoutTask?.cancel()
            webView?.stopLoading()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled else { return }
                self.onResult(result)
            }
        }
    }
}

#Preview {
    NavigationStack { GradeHistoryView() }
}
