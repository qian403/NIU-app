import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import WebKit

@MainActor
struct EnrollmentCertificateView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = EnrollmentCertificateViewModel()
    @State private var showPDF = false
    @State private var showSchoolLogin = false
    @State private var schoolLoginError: String?
    @State private var showRegistrationPage = false
    @State private var isWaitingLong = false

    private static let queryTimeFormat = Date.FormatStyle(
        date: .long, time: .shortened,
        locale: Locale(identifier: "zh_Hant_TW"),
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(identifier: "Asia/Taipei") ?? .gmt
    )

    init(model: EnrollmentCertificateViewModel? = nil) {
        _model = StateObject(wrappedValue: model ?? EnrollmentCertificateViewModel())
    }

    private var isShowingRegistrationPage: Bool { showRegistrationPage && model.registrationWebView != nil }

    var body: some View {
        ZStack {
            if let webView = model.registrationWebView {
                EnrollmentRegistrationWebView(webView: webView)
                    .id(ObjectIdentifier(webView))
                    .allowsHitTesting(isShowingRegistrationPage)
                    .accessibilityHidden(!isShowingRegistrationPage)
            }
            registrationContent
                .opacity(isShowingRegistrationPage ? 0 : 1)
                .allowsHitTesting(!isShowingRegistrationPage)
                .accessibilityHidden(isShowingRegistrationPage)
        }
        .safeAreaInset(edge: .bottom) {
            if isShowingRegistrationPage {
                Text("若校方要求登入或驗證，請在此完成。取得註冊資料後會自動返回。")
                    .font(.footnote).padding().frame(maxWidth: .infinity).background(.bar)
            } else if let snapshot = model.snapshot {
                certificateActionBar(canPrint: snapshot.canPrint)
            }
        }
        .toolbar {
            if model.registrationWebView != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showRegistrationPage ? "返回查詢" : "校方頁面") { showRegistrationPage.toggle() }
                }
            }
        }
        .task(id: model.registrationWebView.map(ObjectIdentifier.init)) {
            showRegistrationPage = false
            isWaitingLong = false
            guard model.registrationWebView != nil else { return }
            // Keep the same mounted WebView for both manual and automatic reveals.
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard model.isLoading, model.registrationWebView != nil else { return }
            isWaitingLong = true
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            if model.isLoading, model.registrationWebView != nil { showRegistrationPage = true }
        }
        .navigationTitle("在學證明")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.snapshot == nil && !model.isLoading { model.refresh() } }
        .onChange(of: model.pdfData) { _, data in showPDF = data != nil }
        .onChange(of: appState.currentUser?.username) { _, _ in showPDF = false; showSchoolLogin = false; model.cancel() }
        .onChange(of: appState.isAuthenticated) { _, authenticated in
            if !authenticated { showPDF = false; showSchoolLogin = false; model.cancel() }
        }
        .onDisappear { if !showPDF && !showSchoolLogin { model.cancel() } }
        .sheet(isPresented: $showPDF, onDismiss: model.dismissCertificate) {
            if let data = model.pdfData { EnrollmentCertificatePDFSheet(data: data) }
        }
        .sheet(isPresented: $showSchoolLogin) { schoolLoginSheet }
    }

    private var registrationContent: some View {
        ZStack {
            // Keep the refresh host mounted: refresh() clears the snapshot before loading.
            registrationList
                .opacity(model.snapshot == nil ? 0 : 1)
                .allowsHitTesting(model.snapshot != nil)
                .accessibilityHidden(model.snapshot == nil)
            if model.snapshot == nil {
                if let message = model.errorMessage, !model.isLoading {
                    failureView(message: message)
                } else {
                    EnrollmentConnectingView(stage: model.loadStage, isWaitingLong: isWaitingLong) {
                        showRegistrationPage = true
                    }
                }
            }
        }
    }

    private var registrationList: some View {
        List {
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    recoveryActions
                }
            }
            if let snapshot = model.snapshot {
                let records = snapshot.records.sorted {
                    $0.semester.compare($1.semester, options: .numeric) == .orderedDescending
                }
                if let current = records.first {
                    Section {
                        EnrollmentCurrentSemesterView(record: current)
                            .padding(.vertical, Theme.Spacing.xsmall)
                    }
                    if records.count > 1 {
                        Section("其他學期") {
                            ForEach(Array(records.dropFirst())) { record in
                                EnrollmentSemesterRow(record: record)
                            }
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView("查無註冊資料", systemImage: "doc.text.magnifyingglass",
                                               description: Text("校方尚未回傳你的註冊紀錄，可下拉重新查詢。"))
                    }
                }
            }
            Section {} footer: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxsmall) {
                    Text("繳費狀態並非即時更新，請以校務系統的註冊結果為準。")
                    if let updated = model.updatedAt {
                        Text("查詢時間：\(Self.queryTimeFormat.format(updated))")
                    }
                    Text("資料來源：國立宜蘭大學教務行政資訊系統")
                }
                .font(.footnote)
                .foregroundStyle(Theme.Colors.secondaryLabel)
                .textCase(nil)
            }
        }
        .background(Theme.Colors.groupedBackground)
        .refreshable { await model.refreshAndWait() }
    }

    private func failureView(message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.Colors.warning)
                    .accessibilityHidden(true)
                Text("無法查詢註冊資料")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .foregroundStyle(Theme.Colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                recoveryActions
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.groupedBackground)
    }

    private var recoveryActions: some View {
        VStack(spacing: Theme.Spacing.xsmall) {
            Button(action: model.refresh) {
                Label("重新查詢", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            if model.certificateLoginURL != nil {
                Button {
                    schoolLoginError = nil
                    showSchoolLogin = true
                } label: {
                    Label("開啟校方登入頁", systemImage: "safari")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .tint(Theme.Colors.accent)
    }

    private func certificateActionBar(canPrint: Bool) -> some View {
        VStack(spacing: Theme.Spacing.xsmall) {
            Text(canPrint
                 ? "校方原始 PDF 可列印、分享或儲存；效期與內容以文件為準。"
                 : "校方目前未提供可列印的在學證明。請確認註冊狀態或稍後重試。")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: model.showCertificate) {
                HStack(spacing: Theme.Spacing.small) {
                    if model.isLoadingPDF {
                        ProgressView().tint(Theme.Colors.secondaryLabel)
                            .accessibilityHidden(true)
                    }
                    Label("顯示在學證明", systemImage: "doc.richtext")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Colors.accent)
            .disabled(!canPrint || model.isLoadingPDF || model.isLoading)
            .accessibilityValue(model.isLoadingPDF ? "正在取得 PDF" : "")
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(.bar)
    }

    @ViewBuilder private var schoolLoginSheet: some View {
        if let url = model.certificateLoginURL {
            NavigationStack {
                EnrollmentSchoolLoginView(url: url, onReady: {
                    showSchoolLogin = false
                    // The next tap obtains cookies after the login sheet has fully closed.
                }, onError: { schoolLoginError = $0 })
                .navigationTitle("校方證明服務")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { showSchoolLogin = false } } }
                .safeAreaInset(edge: .bottom) {
                    Text(schoolLoginError ?? "完成校方登入後，返回並點選「顯示在學證明」。")
                        .font(.footnote).padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
            }
        }
    }

}

private struct EnrollmentConnectingView: View {
    let stage: EnrollmentLoadStage
    let isWaitingLong: Bool
    let showSchoolPage: () -> Void
    @ScaledMetric(relativeTo: .body) private var stageIconSize: CGFloat = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.Colors.accent)
                        .accessibilityHidden(true)
                    Text("正在查詢註冊資料")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("使用你在 App 的登入，向教務系統查詢註冊狀態。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Colors.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    ForEach(EnrollmentLoadStage.allCases, id: \.self) { item in
                        stageRow(item)
                    }
                }
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .padding(Theme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
                if isWaitingLong {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("比平常久一些").font(.headline)
                        Text("校方可能要求登入或驗證，請查看校方頁面並完成操作。")
                            .font(.subheadline)
                            .foregroundStyle(Theme.Colors.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: showSchoolPage) {
                            Label("查看校方頁面", systemImage: "safari")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.groupedBackground)
        .tint(Theme.Colors.accent)
    }

    private func stageRow(_ item: EnrollmentLoadStage) -> some View {
        let done = item.rawValue < stage.rawValue
        let active = item == stage
        return HStack(alignment: .center, spacing: Theme.Spacing.small) {
            ZStack(alignment: .center) {
                if active {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .scaleEffect(stageIconSize / 24)
                        .frame(width: stageIconSize, height: stageIconSize)
                } else {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: stageIconSize * 0.75))
                        .foregroundStyle(done ? Theme.Colors.accent : Theme.Colors.secondaryLabel)
                        .frame(width: stageIconSize, height: stageIconSize)
                }
            }
            .frame(width: stageIconSize, height: stageIconSize)
            Text(item.title)
                .font(.body)
                .foregroundStyle(active ? Theme.Colors.label : Theme.Colors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title)，\(done ? "已完成" : active ? "進行中" : "等待中")")
    }
}

private struct EnrollmentCurrentSemesterView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let record: EnrollmentRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(record.semesterTitle)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) { statusBadges }
            } else {
                HStack(alignment: .top, spacing: Theme.Spacing.xsmall) { statusBadges }
            }
            Divider()
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                EnrollmentDetail(title: "姓名", value: record.name)
                EnrollmentDetail(title: "學號", value: record.studentID)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.medium) { departmentAndGrade }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) { departmentAndGrade }
                }
                EnrollmentDetail(title: "註冊日期", value: record.registrationDate)
            }
        }
    }

    @ViewBuilder private var statusBadges: some View {
        statusBadge("在學狀態", value: record.studentStatus, icon: "person.crop.rectangle")
        statusBadge("註冊狀態", value: record.registrationStatus, icon: "checklist")
    }

    private func statusBadge(_ title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xsmall) {
            Image(systemName: icon)
                .foregroundStyle(Theme.Colors.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxsmall) {
                Text(title).font(.caption).foregroundStyle(Theme.Colors.secondaryLabel)
                Text(value.isEmpty ? "—" : value).font(.headline)
            }
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.tertiaryFill,
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var departmentAndGrade: some View {
        EnrollmentDetail(title: "系所", value: record.department)
        EnrollmentDetail(title: "年級", value: record.grade)
    }
}

private struct EnrollmentSemesterRow: View {
    let record: EnrollmentRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            Text(record.semesterTitle).font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.medium) { statuses }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) { statuses }
            }
            EnrollmentDetail(title: "註冊日期", value: record.registrationDate)
                .font(.footnote)
        }
        .padding(.vertical, Theme.Spacing.xsmall)
    }

    @ViewBuilder private var statuses: some View {
        EnrollmentDetail(title: "註冊狀態", value: record.registrationStatus)
        EnrollmentDetail(title: "在學狀態", value: record.studentStatus)
    }
}

private struct EnrollmentDetail: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let value: String

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.xxsmall))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Spacing.xsmall))
        layout {
            Text(title).foregroundStyle(Theme.Colors.secondaryLabel)
            Text(value.isEmpty ? "—" : value)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private struct EnrollmentRegistrationWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    // The service owns navigation and cancellation; removing this wrapper must not
    // cancel a replacement request while SwiftUI reconciles the view hierarchy.
}

private struct EnrollmentSchoolLoginView: UIViewRepresentable {
    let url: URL
    let onReady: () -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady, onError: onError) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.navigationDelegate = nil
        uiView.stopLoading()
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onReady: () -> Void
        let onError: (String) -> Void
        init(onReady: @escaping () -> Void, onError: @escaping (String) -> Void) {
            self.onReady = onReady
            self.onError = onError
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            let allowed = url?.scheme == "https" && url?.host == "ccsys.niu.edu.tw"
            decisionHandler(allowed ? .allow : .cancel)
            if !allowed { onError("校方登入導向了其他網站，請返回後重新查詢。") }
        }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.response.mimeType == "application/pdf" {
                decisionHandler(.cancel)
                onReady()
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
        private func report(_ error: Error) {
            let code = error as NSError
            guard code.domain != NSURLErrorDomain || code.code != NSURLErrorCancelled else { return }
            onError(EnrollmentCertificateViewModel.message(for: error) + "，請返回後重試。")
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onError("校方登入網頁已中斷，請返回後重試。")
        }
    }
}

private struct EnrollmentCertificatePDF: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { $0.data }
            .suggestedFileName("在學證明.pdf")
    }
}

private struct EnrollmentCertificatePDFSheet: View {
    @Environment(\.dismiss) private var dismiss
    let data: Data
    @State private var printError = false

    var body: some View {
        NavigationStack {
            EnrollmentPDFPreview(data: data)
                .navigationTitle("在學證明 PDF")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        ShareLink(item: EnrollmentCertificatePDF(data: data), preview: SharePreview("在學證明", image: Image(systemName: "doc.richtext"))) {
                            Label("分享或儲存 PDF", systemImage: "square.and.arrow.up")
                        }
                        EnrollmentPrintButton(data: data) { printError = true }
                            .frame(width: 44, height: 44)
                    }
                }
                .alert("無法開啟列印", isPresented: $printError) {
                    Button("好", role: .cancel) {}
                } message: { Text("請稍後重試，或先將 PDF 儲存至「檔案」。") }
        }
    }
}

private struct EnrollmentPDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) {}
    static func dismantleUIView(_ uiView: PDFView, coordinator: ()) { uiView.document = nil }
}

private struct EnrollmentPrintButton: UIViewRepresentable {
    let data: Data
    let onError: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "printer"), for: .normal)
        button.accessibilityLabel = "列印在學證明"
        button.addAction(UIAction { [weak button] _ in
            guard let button, UIPrintInteractionController.canPrint(data) else { onError(); return }
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil)
            info.jobName = "在學證明"
            info.outputType = .general
            controller.printInfo = info
            controller.printingItem = data
            // A view anchor also supports the iPad popover presentation.
            let presented = controller.present(from: button.bounds, in: button, animated: true) { controller, _, error in
                controller.printingItem = nil
                if error != nil { onError() }
            }
            if !presented { controller.printingItem = nil; onError() }
        }, for: .touchUpInside)
        return button
    }
    func updateUIView(_ uiView: UIButton, context: Context) {}
    static func dismantleUIView(_ uiView: UIButton, coordinator: ()) {
        UIPrintInteractionController.shared.dismiss(animated: false)
        UIPrintInteractionController.shared.printingItem = nil
    }
}
