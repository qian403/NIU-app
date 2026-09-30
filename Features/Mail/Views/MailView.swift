import SwiftUI
import WebKit
import SafariServices
import QuickLook

@MainActor
struct MailView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var model: MailViewModel
    @State private var showsSchoolLogin = false
    @State private var twoFactorCode = ""

    init(model: MailViewModel? = nil) { self.model = model ?? .shared }

    var body: some View {
        Group {
            if let session = model.webSession {
                CampusMailWorkspace(session: session) { [weak model] mismatch in
                    model?.webSessionExpired(id: session.id, accountMismatch: mismatch)
                }
                .id(session.id)
            } else {
                connectionView
            }
        }
        .navigationTitle("校園信箱")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.currentUser?.username) {
            model.prepare(account: appState.currentUser?.username ?? "")
        }
        .onChange(of: appState.isAuthenticated) { _, authenticated in
            if !authenticated { model.reset() }
        }
        .onDisappear { twoFactorCode = ""; model.suspend() }
        .sheet(isPresented: $showsSchoolLogin) {
            CampusMailExternalPage(url: CampusMailWebPolicy.origin.appendingPathComponent("NUMail/Login"))
        }
    }

    private var connectionView: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.large) {
                Image(systemName: "envelope.fill")
                    .font(.largeTitle).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text("校園信箱").font(.title2.bold())
                if model.isBusy {
                    ProgressView()
                    Text(model.connectionStatus).foregroundStyle(.secondary)
                    Text("正在沿用 App 登入資訊，請稍候。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    if model.needsTwoFactor {
                        TextField("二次驗證碼", text: $twoFactorCode)
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { submitTwoFactor() }
                        Button("完成驗證") { submitTwoFactor() }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                            .disabled(twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("重新連線") { twoFactorCode = ""; model.connect() }.frame(minHeight: 44)
                    } else {
                        Button("重新連線") { model.connect() }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    }
                    if model.needsSchoolWebsite {
                        Button("完成校方額外驗證") { showsSchoolLogin = true }.frame(minHeight: 44)
                        Text("若已變更校方密碼，請同步更新 App 登入資訊。").font(.footnote)
                    }
                }
                Text("收發信、回覆、附件、草稿與信件管理，皆可在 App 內使用。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(Theme.Spacing.large)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.xlarge)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func submitTwoFactor() {
        model.submitTwoFactor(twoFactorCode)
        twoFactorCode = ""
    }
}

@MainActor
struct CampusMailWorkspace: View {
    @StateObject private var browser: CampusMailBrowser
    @State private var pendingNavigation: URL?
    @State private var confirmsNavigation = false
    @State private var confirmsClosingPopup = false
    @State private var promptText = ""

    init(session: CampusMailWebSession, onExpired: @escaping (Bool) -> Void) {
        _browser = StateObject(wrappedValue: CampusMailBrowser.workspace(session: session, onExpired: onExpired))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = browser.errorMessage {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote)
                    Spacer(minLength: 8)
                    Button("重新載入") { askToNavigate(nil) }.frame(minHeight: 44)
                }.padding(.horizontal)
            }
            ZStack {
                CampusMailWebContainer(browser: browser)
                    .opacity(browser.isReady ? 1 : 0)
                    .allowsHitTesting(browser.isReady)
                    .accessibilityHidden(!browser.isReady)
                if !browser.isReady, browser.errorMessage == nil {
                    ProgressView("正在開啟郵件功能…")
                }
            }
            if browser.downloadCount > 0 {
                ProgressView("正在下載附件（\(browser.downloadCount)）…")
                    .font(.footnote).padding(8)
            }
        }
        .overlay(alignment: .top) {
            if browser.isReady, browser.isLoading { ProgressView().padding(8).background(.regularMaterial, in: Capsule()) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if browser.hasPopup {
                    Button("關閉子視窗", systemImage: "xmark") { confirmsClosingPopup = true }
                        .labelStyle(.iconOnly)
                } else if browser.canGoBack {
                    Button("上一頁", systemImage: "chevron.backward") { browser.back() }
                        .labelStyle(.iconOnly)
                }
                Menu {
                    Button("手機版信箱", systemImage: "iphone") { askToNavigate(CampusMailWebPolicy.inbox) }
                    Button("完整版信箱", systemImage: "desktopcomputer") { askToNavigate(CampusMailWebPolicy.desktop) }
                    Button("郵件設定", systemImage: "gearshape") { askToNavigate(CampusMailWebPolicy.settings) }
                    Divider()
                    Button("下載附件（\(browser.files.count)）", systemImage: "arrow.down.circle") { browser.showsDownloads = true }
                    Button("重新載入", systemImage: "arrow.clockwise") { askToNavigate(nil) }
                } label: { Label("郵件選單", systemImage: "ellipsis.circle") }
                .disabled(!browser.isReady && browser.errorMessage == nil)
            }
        }
        .task { browser.start(); browser.resume() }
        .onDisappear { browser.pause() }
        .confirmationDialog("關閉目前子視窗？", isPresented: $confirmsClosingPopup, titleVisibility: .visible) {
            Button("關閉", role: .destructive) { browser.closePopup() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("未儲存的草稿或輸入內容可能會遺失。")
        }
        .confirmationDialog("重新載入或切換頁面？", isPresented: $confirmsNavigation, titleVisibility: .visible) {
            Button("繼續") {
                if let url = pendingNavigation { browser.navigate(url) }
                else { browser.reload() }
            }
            Button("取消", role: .cancel) { pendingNavigation = nil }
        } message: {
            Text("請先儲存正在編輯的草稿。若剛才已按寄出，請先確認寄件備份，以免重複寄信。")
        }
        .alert("校園信箱", isPresented: Binding(get: { browser.dialog != nil }, set: { if !$0 { browser.resolveDialog(accept: false) } })) {
            if browser.dialog?.kind == .prompt { TextField("輸入內容", text: $promptText) }
            Button("確定") { browser.resolveDialog(accept: true, text: promptText) }
            if browser.dialog?.kind != .alert { Button("取消", role: .cancel) { browser.resolveDialog(accept: false) } }
        } message: { Text(browser.dialog?.message ?? "") }
        .onChange(of: browser.dialog?.message) { _, _ in promptText = browser.dialog?.defaultText ?? "" }
        .sheet(isPresented: $browser.showsDownloads) { downloads }
        .sheet(isPresented: Binding(get: { browser.externalURL != nil }, set: { if !$0 { browser.externalURL = nil } })) {
            if let url = browser.externalURL { CampusMailExternalPage(url: url) }
        }
    }

    private func askToNavigate(_ url: URL?) {
        pendingNavigation = url
        if !browser.isReady { browser.reload() }
        else { confirmsNavigation = true }
    }

    private var downloads: some View {
        NavigationStack {
            List {
                if browser.files.isEmpty {
                    ContentUnavailableView("尚未下載附件", systemImage: "arrow.down.circle",
                                           description: Text("在信件內點選附件下載，即可預覽或儲存到「檔案」。"))
                }
                ForEach(browser.files) { file in
                    NavigationLink {
                        CampusMailFilePreview(url: file.url)
                            .navigationTitle(file.url.lastPathComponent)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ShareLink(item: file.url) { Label("分享或儲存附件", systemImage: "square.and.arrow.up") } }
                    } label: { Label(file.url.lastPathComponent, systemImage: "doc") }
                }
                if !browser.files.isEmpty {
                    Text("附件暫存會在郵件連線結束或登出時清除。要保留附件，請使用分享功能儲存到「檔案」。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("下載附件")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { browser.showsDownloads = false } } }
        }
    }
}

@MainActor
private struct CampusMailWebContainer: UIViewRepresentable {
    @ObservedObject var browser: CampusMailBrowser
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ container: UIView, context: Context) {
        let target = browser.displayedWebView
        guard target.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        target.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(target)
        NSLayoutConstraint.activate([
            target.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            target.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            target.topAnchor.constraint(equalTo: container.topAnchor),
            target.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

@MainActor
private struct CampusMailExternalPage: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

@MainActor
private struct CampusMailFilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
