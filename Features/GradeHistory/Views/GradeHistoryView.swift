import SwiftUI
import WebKit

struct GradeHistoryView: View {
    @StateObject private var vm = GradeHistoryViewModel()

    var body: some View {
        NavigationView {
            ZStack {
                Color.white.ignoresSafeArea()

                switch vm.loadState {
                case .idle, .loading:
                    ProgressView(loadingText)
                        .progressViewStyle(.circular)
                        .tint(.black)
                        .foregroundColor(.black.opacity(0.6))

                case .error(let message):
                    errorView(message: message)

                case .loaded:
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                            modeSection
                            contentHeader
                            contentSection
                        }
                        .padding(.horizontal, Theme.Spacing.large)
                        .padding(.vertical, Theme.Spacing.medium)
                    }
                }
            }
            .navigationTitle("成績查詢")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: vm.refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .light))
                            .foregroundColor(.black)
                    }
                }
            }
        }
        .preferredColorScheme(.light)
        .overlay {
            if vm.showWebView {
                GradeHistoryWebView(mode: vm.selectedMode, onResult: vm.handleWebResult)
                    .frame(width: 360, height: 640)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Sections

    private var loadingText: String {
        switch vm.selectedMode {
        case .midterm: return "載入期中成績…"
        case .final: return "載入期末成績…"
        case .history: return "載入歷年成績…"
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("查詢模式")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.black.opacity(0.55))
            Picker("查詢模式", selection: $vm.selectedMode) {
                ForEach(GradeQueryMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onModeChange(vm.selectedMode) { mode in
                vm.selectMode(mode)
            }
        }
    }

    @ViewBuilder
    private var contentHeader: some View {
        if vm.selectedMode == .history {
            summarySection
            filterSection
        } else {
            termSummarySection
        }
    }

    private var summarySection: some View {
        let summary = vm.summary
        return VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(alignment: .center, spacing: Theme.Spacing.medium) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("累計 GPA")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.black.opacity(0.55))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%.2f", summary.cumulativeGPA))
                            .font(.system(size: 32, weight: .bold))
                        Text("/ 4.30")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.black.opacity(0.5))
                    }
                    Capsule()
                        .fill(Color.black.opacity(0.08))
                        .frame(height: 6)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Color.black)
                                    .frame(width: max(0, min(1, summary.cumulativeGPA / 4.3)) * proxy.size.width)
                            }
                        }
                }

                Spacer()

                VStack(alignment: .leading, spacing: 10) {
                    statRow(title: "平均分數", value: String(format: "%.2f", summary.averageScore))
                    statRow(title: "通過率", value: summary.passRate.isNaN ? "0%" : String(format: "%.0f%%", summary.passRate * 100))
                    statRow(title: "已修/通過學分", value: String(format: "%.0f / %.0f", summary.passedCredits, summary.totalCredits))
                }
            }

            if !summary.trend.isEmpty {
                GradeTrendView(points: summary.trend)
            }
        }
        .padding(Theme.Spacing.large)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .fill(Color.black.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .stroke(Color.black.opacity(0.07), lineWidth: 1)
        )
    }

    private func statRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.black.opacity(0.55))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.black)
        }
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("課程類別")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.black.opacity(0.55))
            Picker("課程類別", selection: $vm.selectedCategory) {
                ForEach(CourseCategory.allCases) { category in
                    Text(category.shortLabel).tag(category)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var termSummarySection: some View {
        let averageValue = vm.termSnapshot?.averageText.nilIfPlaceholder ?? "-"
        let rankValue = vm.termSnapshot?.rankText.nilIfPlaceholder ?? "-"
        let courseCount = String(vm.termSnapshot?.courses.count ?? 0)
        let averageTitle = vm.selectedMode == .midterm ? "期中平均" : "期末平均"

        return VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let title = vm.termSnapshot?.semesterTitle, !title.isEmpty {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
            }

            HStack(spacing: 12) {
                StatPill(title: averageTitle, value: averageValue)
                StatPill(title: "班排名", value: rankValue)
                StatPill(title: "課程數", value: courseCount)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.large)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .fill(Color.black.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .stroke(Color.black.opacity(0.07), lineWidth: 1)
        )
    }

    private var contentSection: some View {
        Group {
            if vm.selectedMode == .history {
                historyContent
            } else {
                termContent
            }
        }
    }

    private var historyContent: some View {
        Group {
            if vm.yearSections.isEmpty {
                emptyState
            } else {
                VStack(spacing: Theme.Spacing.medium) {
                    ForEach(vm.yearSections, id: \.year) { section in
                        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                            Text("\(section.year) 學年度")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                                .padding(.bottom, 2)

                            ForEach(section.semesters) { sem in
                                GradeSemesterCard(
                                    semester: sem,
                                    isExpanded: vm.expandedSemesters.contains(sem.id),
                                    toggle: { vm.toggle(sem) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var termContent: some View {
        Group {
            if let snapshot = vm.termSnapshot, !snapshot.courses.isEmpty {
                VStack(spacing: 12) {
                    ForEach(snapshot.courses) { course in
                        TermScoreRow(course: course)
                    }
                }
            } else {
                termEmptyState
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.black.opacity(0.35))
            Text("目前沒有符合篩選條件的課程")
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.black.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.large)
    }

    private var termEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.black.opacity(0.35))
            Text("目前沒有可顯示的\(vm.selectedMode.rawValue)成績")
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.black.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.large)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.black.opacity(0.35))
            Text(message)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.black.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("重新載入") {
                vm.refresh()
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                    .stroke(Color.black.opacity(0.2), lineWidth: 1)
            )
            .foregroundColor(.black)
        }
        .padding(.horizontal, Theme.Spacing.large)
    }
}

// MARK: - Trend mini-chart

private struct GradeTrendView: View {
    let points: [GradeHistorySummary.SemesterTrendPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GPA 走勢")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.black.opacity(0.55))

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(points) { point in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.8))
                            .frame(width: 18, height: CGFloat(max(0.1, point.gpa / 4.3)) * 70)
                        Text(point.label)
                            .font(.system(size: 11, weight: .light))
                            .foregroundColor(.black.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Semester card

private struct GradeSemesterCard: View {
    let semester: SemesterGrade
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(semester.termTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                    if let rank = semester.classRank, !rank.isEmpty {
                        Text("班級排名：\(rank)")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.black.opacity(0.55))
                    }
                }
                Spacer()
                Button(action: toggle) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black.opacity(0.7))
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                StatPill(title: "學期 GPA", value: String(format: "%.2f", semester.displayGPA))
                StatPill(title: "平均分數", value: String(format: "%.2f", semester.averageScore))
                StatPill(title: "通過率", value: String(format: "%.0f%%", semester.passRate * 100))
            }

            ProgressView(value: semester.passRate)
                .progressViewStyle(.linear)
                .tint(.black)
                .padding(.top, 4)

            if isExpanded {
                VStack(spacing: 12) {
                    ForEach(semester.courses) { course in
                        GradeCourseRow(course: course)
                    }
                }
                .padding(.top, 6)
            } else {
                if let first = semester.courses.first {
                    GradeCourseRow(course: first)
                        .padding(.top, 6)
                    if semester.courses.count > 1 {
                        Text("其餘 \(semester.courses.count - 1) 門課程…")
                            .font(.system(size: 12, weight: .light))
                            .foregroundColor(.black.opacity(0.5))
                    }
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.black.opacity(0.55))
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.black)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                .fill(Color.black.opacity(0.03))
        )
    }
}

private struct GradeCourseRow: View {
    let course: GradeCourse

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(course.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(course.code)
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(.black.opacity(0.6))
                    Badge(text: course.category.shortLabel)
                    if let remark = course.remarks, !remark.isEmpty {
                        Text(remark)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.black.opacity(0.55))
                    }
                }
            }

            Spacer()

            VStack(spacing: 4) {
                Text(String(format: "%.0f", course.score))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(course.passed ? .black : .red)
                Text("學分 \(String(format: "%.0f", course.credits))")
                    .font(.system(size: 11, weight: .light))
                    .foregroundColor(.black.opacity(0.5))
            }
            .frame(width: 70)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                .stroke(course.passed ? Color.black.opacity(0.12) : Color.red.opacity(0.35), lineWidth: course.passed ? 1 : 1.2)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                        .fill(course.passed ? Color.clear : Color.red.opacity(0.05))
                )
        )
    }
}

private struct TermScoreRow: View {
    let course: TermScoreCourse

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(course.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .lineLimit(2)
                Badge(text: course.type.isEmpty ? "未分類" : course.type)
            }

            Spacer()

            Text(course.scoreText)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(scoreColor(text: course.scoreText))
                .frame(width: 70)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        )
    }

    private func scoreColor(text: String) -> Color {
        guard let value = Double(text) else { return .black.opacity(0.65) }
        return value >= 60 ? .black : .red
    }
}

private struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.black.opacity(0.2), lineWidth: 1)
            )
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
        guard let raw = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if raw == "-" || raw == "--" || raw == "尚未計算" || raw == "尚未公佈" {
            return nil
        }
        return raw
    }
}

private extension View {
    @ViewBuilder
    func onModeChange(_ value: GradeQueryMode, perform action: @escaping (GradeQueryMode) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value) { newValue in
                action(newValue)
            }
        }
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

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, onResult: onResult)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/17.0 Safari/605.1.15"
        context.coordinator.webView = webView

        if let url = URL(string: context.coordinator.startURL) {
            webView.load(URLRequest(url: url))
        } else {
            context.coordinator.finish(.failure("無法建立成績查詢連結"))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let mode: GradeQueryMode
        let onResult: (GradeHistoryWebResult) -> Void
        weak var webView: WKWebView?

        private var step: Step = .resolveEntryLink
        private var active = true

        private enum Step {
            case resolveEntryLink
            case waitForMainEntry
            case waitForTargetPage
            case waitForParse
        }

        var startURL: String {
            switch mode {
            case .history:
                return "https://ccsys.niu.edu.tw/SSO/Std003.aspx"
            case .midterm, .final:
                return "https://ccsys.niu.edu.tw/SSO/Std002.aspx"
            }
        }

        init(mode: GradeQueryMode, onResult: @escaping (GradeHistoryWebResult) -> Void) {
            self.mode = mode
            self.onResult = onResult
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard active else { return }
            let url = webView.url?.absoluteString ?? ""
            print("[GradeHistory] mode=\(mode.rawValue) step=\(step) didFinish=\(url)")

            if url.contains("/MvcTeam/Account/Login") || url.contains("/Account/Login") {
                finish(.sessionExpired)
                return
            }

            if url.contains("Default.aspx") {
                finish(.sessionExpired)
                return
            }

            switch step {
            case .resolveEntryLink:
                handleEntryPage(webView: webView, currentURL: url)

            case .waitForMainEntry:
                handleMainEntryPage(webView: webView, currentURL: url)

            case .waitForTargetPage:
                step = .waitForParse
                if mode == .history {
                    pollForHistoryCourses(webView: webView, attempt: 0)
                } else {
                    pollForTermScores(webView: webView, attempt: 0)
                }

            case .waitForParse:
                break
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard active else { return }
            finish(.failure("網路連線失敗：\(error.localizedDescription)"))
        }

        private func handleEntryPage(webView: WKWebView, currentURL: String) {
            switch mode {
            case .history:
                if currentURL.contains("Std003.aspx") || currentURL.contains("Std002.aspx") {
                    extractCCSYSLinkAndNavigate(webView: webView)
                } else if currentURL.contains("/MvcTeam/Act") {
                    step = .waitForMainEntry
                    navigateToHistoryPage(webView: webView)
                }

            case .midterm, .final:
                if currentURL.contains("Std002.aspx") || currentURL.contains("StdMain.aspx") {
                    extractAcadeLinkAndNavigate(webView: webView)
                } else if currentURL.contains("MainFrame.aspx") {
                    step = .waitForMainEntry
                    navigateToTermPage(webView: webView)
                }
            }
        }

        private func handleMainEntryPage(webView: WKWebView, currentURL: String) {
            switch mode {
            case .history:
                if currentURL.contains("/MvcTeam/Act") {
                    navigateToHistoryPageFromAct(webView: webView)
                } else if currentURL.contains("/MvcTeam/Tutor/StudentCourseScore") {
                    step = .waitForTargetPage
                }
            case .midterm:
                if currentURL.contains("MainFrame.aspx") {
                    navigateToTermPage(webView: webView)
                } else if currentURL.contains("GRD5131_02.aspx") {
                    step = .waitForTargetPage
                }
            case .final:
                if currentURL.contains("MainFrame.aspx") {
                    navigateToTermPage(webView: webView)
                } else if currentURL.contains("GRD5130_02.aspx") {
                    step = .waitForTargetPage
                }
            }
        }

        private func extractCCSYSLinkAndNavigate(webView: WKWebView) {
            let js = """
            (function() {
                var el = document.getElementById('ctl00_ContentPlaceHolder1_RadListView1_ctrl0_HyperLink1');
                return el ? (el.getAttribute('href') || '') : '';
            })()
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, self.active else { return }
                let href = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fallback = "https://ccsys.niu.edu.tw/MvcTeam/Act"
                let fullURL: String

                if href.isEmpty {
                    fullURL = fallback
                } else if href.hasPrefix("http") {
                    fullURL = href
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
                        fullURL = fallback
                    }
                } else if href.hasPrefix("/") {
                    fullURL = "https://ccsys.niu.edu.tw" + href
                } else {
                    let clean = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
                    fullURL = "https://ccsys.niu.edu.tw/SSO/" + clean
                }

                guard let url = URL(string: fullURL) else {
                    self.finish(.failure("無法進入成績系統"))
                    return
                }

                self.step = .waitForMainEntry
                webView.load(URLRequest(url: url))
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
                    self.finish(.sessionExpired)
                    return
                }

                let fullURL: String
                if href.hasPrefix("http") {
                    fullURL = href
                } else {
                    let clean = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
                    fullURL = "https://ccsys.niu.edu.tw/SSO/" + clean
                }

                guard let url = URL(string: fullURL) else {
                    self.finish(.failure("無法進入教務系統"))
                    return
                }

                self.step = .waitForMainEntry
                webView.load(URLRequest(url: url))
            }
        }

        private func navigateToHistoryPage(webView: WKWebView) {
            guard let url = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Tutor/StudentCourseScore") else {
                finish(.failure("歷年成績頁面連結無效"))
                return
            }
            print("[GradeHistory] navigate history -> \(url.absoluteString)")
            step = .waitForTargetPage
            var request = URLRequest(url: url)
            request.setValue("https://ccsys.niu.edu.tw/MvcTeam/Act", forHTTPHeaderField: "Referer")
            webView.load(request)
        }

        private func navigateToHistoryPageFromAct(webView: WKWebView) {
            let js = """
            (function() {
                var anchors = Array.from(document.querySelectorAll('a[href]'));
                var match = anchors.find(function(a) {
                    var h = a.getAttribute('href') || '';
                    return h.indexOf('StudentCourseScore') >= 0;
                });
                return match ? (match.getAttribute('href') || '') : '';
            })()
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, self.active else { return }
                let href = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !href.isEmpty else {
                    self.navigateToHistoryPage(webView: webView)
                    return
                }

                let fullURL: String
                if href.hasPrefix("http") {
                    fullURL = href
                } else if href.hasPrefix("/") {
                    fullURL = "https://ccsys.niu.edu.tw" + href
                } else {
                    fullURL = "https://ccsys.niu.edu.tw/MvcTeam/" + href
                }
                print("[GradeHistory] Act link -> \(fullURL)")

                guard let url = URL(string: fullURL) else {
                    self.navigateToHistoryPage(webView: webView)
                    return
                }
                self.step = .waitForTargetPage
                var request = URLRequest(url: url)
                request.setValue("https://ccsys.niu.edu.tw/MvcTeam/Act", forHTTPHeaderField: "Referer")
                webView.load(request)
            }
        }

        private func navigateToTermPage(webView: WKWebView) {
            let path: String
            let referer: String
            switch mode {
            case .midterm:
                path = "https://acade.niu.edu.tw/NIU/Application/GRD/GRD51/GRD5131_02.aspx"
                referer = "https://acade.niu.edu.tw/NIU/Application/GRD/GRD51/GRD5131_.aspx?progcd=GRD5131"
            case .final:
                path = "https://acade.niu.edu.tw/NIU/Application/GRD/GRD51/GRD5130_02.aspx"
                referer = "https://acade.niu.edu.tw/NIU/Application/GRD/GRD51/GRD5130_.aspx?progcd=GRD5130"
            case .history:
                return
            }

            guard let url = URL(string: path) else {
                finish(.failure("期成績頁面連結無效"))
                return
            }
            var request = URLRequest(url: url)
            request.setValue(referer, forHTTPHeaderField: "Referer")
            print("[GradeHistory] navigate term -> \(path)")
            step = .waitForTargetPage
            webView.load(request)
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
                        return (s || '').replace(/\\s+/g, ' ').trim();
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

                    var summaryBySem = {};
                    var summaryRows = document.querySelectorAll('div.row table.table tr');
                    for (var i = 1; i < summaryRows.length; i++) {
                        var tds = summaryRows[i].querySelectorAll('td');
                        if (!tds || tds.length < 4) continue;
                        var sem = parseSemRaw(tds[0].innerText);
                        if (!sem) continue;
                        summaryBySem[sem.key] = {
                            classRank: clean(tds[2].innerText),
                            averageText: clean(tds[3].innerText)
                        };
                    }

                    var records = [];
                    var tables = document.querySelectorAll('#accordion修課紀錄 table.table.table-striped');
                    for (var t = 0; t < tables.length; t++) {
                        var rows = tables[t].querySelectorAll('tr');
                        for (var r = 1; r < rows.length; r++) {
                            var cells = rows[r].querySelectorAll('td');
                            if (!cells || cells.length < 5) continue;

                            var semRaw = clean(cells[0].innerText);
                            var sem = parseSemRaw(semRaw);
                            if (!sem) continue;

                            var courseType = clean(cells[1].innerText);
                            var creditsRaw = clean(cells[2].innerText);
                            var credits = parseFloat(creditsRaw);
                            var name = clean(cells[3].innerText);
                            var scoreText = clean(cells[4].innerText);
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
                                averageText: summary.averageText || ""
                            });
                        }
                    }

                    return JSON.stringify(records);
                })()
                """

                webView.evaluateJavaScript(js) { [weak self] result, _ in
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
                                remarks: combinedRemark.isEmpty ? nil : combinedRemark
                            )
                        }

                        let creditsTaken = courses.reduce(0.0) { $0 + $1.credits }
                        let creditsPassed = courses.filter { $0.passed }.reduce(0.0) { $0 + $1.credits }
                        let weightedScore = courses.reduce(0.0) { $0 + ($1.score * $1.credits) }
                        let computedAverage = creditsTaken == 0 ? 0 : weightedScore / creditsTaken
                        let sourceAverage = rows.compactMap { item in
                            Self.parseNumber(item.row.averageText)
                        }.first
                        let classRank = rows.compactMap { item in
                            item.row.classRank?.nilIfPlaceholder
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
                            courses: courses
                        )
                    }
                    .sorted { lhs, rhs in
                        if lhs.year == rhs.year { return lhs.term.order > rhs.term.order }
                        return lhs.year > rhs.year
                    }

                    print("[GradeHistory] history parse raw=\(courseRows.count) normalized=\(normalizedRows.count) semesters=\(semesters.count)")
                    if semesters.isEmpty {
                        let sample = courseRows.prefix(5).map { "\($0.year.map(String.init) ?? "nil")-\($0.term ?? "nil")|\($0.name)|\($0.scoreText)|\($0.credits)" }
                        print("[GradeHistory] history sample=\(sample.joined(separator: " || "))")
                    }

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
                        return (value || '').replace(/\\s+/g, ' ').trim();
                    }
                    function text(selector) {
                        var el = document.querySelector(selector);
                        return clean(el ? el.innerText : '');
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
                        var body = clean(document.body.innerText);
                        var match = body.match(/(\\d{2,3})\\s*學年度\\s*第?\\s*([上下暑123])\\s*學期/);
                        if (!match) return '';
                        var term = match[2];
                        if (term === '1') term = '上';
                        if (term === '2') term = '下';
                        if (term === '3') term = '暑';
                        return match[1] + ' 學年度第 ' + term + ' 學期';
                    }

                    var rows = [];
                    for (var i = 2; ; i++) {
                        var row = document.querySelector('#DataGrid > tbody > tr:nth-child(' + i + ')');
                        if (!row) break;
                        var type = clean(row.querySelector('td:nth-child(4)')?.innerText || '');
                        var lesson = clean(row.querySelector('td:nth-child(5)')?.innerText || '');
                        var score = clean(row.querySelector('td:nth-child(6)')?.innerText || '');
                        if (!lesson) continue;
                        rows.push({
                            type: type || '未分類',
                            lesson: lesson,
                            score: score || '-'
                        });
                    }

                    var rankRaw = text('#QTable2 > tbody > tr:nth-child(2) > td:nth-child(2) > table > tbody > tr:nth-child(2) > td:nth-child(4)');

                    return JSON.stringify({
                        semesterTitle: semesterTitle(),
                        averageText: text('#Q_CRS_AVG_MARK'),
                        rankText: formatRank(rankRaw),
                        rows: rows
                    });
                })()
                """

                webView.evaluateJavaScript(js) { [weak self] result, _ in
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
            DispatchQueue.main.async {
                self.onResult(result)
            }
        }
    }
}

#Preview {
    GradeHistoryView()
}
