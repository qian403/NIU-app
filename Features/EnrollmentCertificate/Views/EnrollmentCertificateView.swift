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
            registrationList
                .opacity(isShowingRegistrationPage ? 0 : 1)
                .allowsHitTesting(!isShowingRegistrationPage)
                .accessibilityHidden(isShowingRegistrationPage)
        }
        .safeAreaInset(edge: .bottom) {
            if showRegistrationPage, model.registrationWebView != nil {
                Text("若校方要求登入或驗證，請在此完成。取得註冊資料後會自動返回。")
                    .font(.footnote).padding().frame(maxWidth: .infinity).background(.regularMaterial)
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
            guard model.registrationWebView != nil else { return }
            // Keep the same mounted WebView when revealing a slow or interactive school page.
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
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

    private var registrationList: some View {
        List {
            Section {
                Label("在學證明", systemImage: "doc.text")
                    .font(.title2.bold())
                Text("查詢當學期註冊狀態，取得校方核發的在學證明 PDF。")
                    .foregroundStyle(.secondary)
            }
            if model.isLoading {
                Section {
                    HStack(spacing: Theme.Spacing.medium) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.regular)
                            .accessibilityHidden(true)
                        Text(model.loadingMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            if let snapshot = model.snapshot {
                if snapshot.records.isEmpty {
                    Section { ContentUnavailableView("查無註冊資料", systemImage: "doc.text.magnifyingglass", description: Text("校方尚未回傳你的註冊紀錄。")) }
                }
                ForEach(snapshot.records) { record in
                    Section(record.semesterTitle) {
                        field("姓名", record.name)
                        field("學號", record.studentID)
                        field("系所", record.department)
                        field("年級", record.grade)
                        field("在學狀態", record.studentStatus)
                        field("註冊狀態", record.registrationStatus)
                        field("註冊日期", record.registrationDate)
                    }
                }
                Section {
                    Button {
                        model.showCertificate()
                    } label: {
                        HStack {
                            Label("顯示在學證明", systemImage: "doc.richtext")
                            Spacer()
                            if model.isLoadingPDF { ProgressView() }
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(!snapshot.canPrint || model.isLoadingPDF)
                } footer: {
                    Text(snapshot.canPrint
                         ? "開啟校方原始 PDF 後，可列印、分享或儲存至「檔案」。證明效期與內容以校方文件為準。"
                         : "校方目前未提供可列印的在學證明。請確認註冊狀態或稍後重試。")
                }
            }
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                    if model.certificateLoginURL != nil {
                        Button("開啟校方登入頁") { schoolLoginError = nil; showSchoolLogin = true }.frame(minHeight: 44)
                    }
                    Button("重新查詢") { model.refresh() }.frame(minHeight: 44)
                }
            }
            Section {
                Text("繳費狀態並非即時更新，請以校務系統的註冊結果為準。")
                if let updated = model.updatedAt {
                    Text("查詢時間：\(updated.formatted(date: .abbreviated, time: .shortened))")
                }
                Text("資料來源：國立宜蘭大學教務行政資訊系統")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await model.refreshAndWait() }
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

    private func field(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing) }
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
