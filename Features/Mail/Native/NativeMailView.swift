import SwiftUI

/// HomeView owns the NavigationStack. Mail owns its destinations, compose sheet and outbox.
struct NativeMailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var model: NativeMailViewModel
    let account: String
    let isAuthenticated: Bool

    init(account: String, isAuthenticated: Bool) {
        self.init(account: account, isAuthenticated: isAuthenticated, model: .shared)
    }

    init(account: String, isAuthenticated: Bool, model: NativeMailViewModel) {
        self.account = account; self.isAuthenticated = isAuthenticated; self.model = model
    }

    var body: some View {
        MailboxListView(model: model)
            .mailChrome(model)
            .navigationDestination(for: MailFolder.self) { folder in
                MessageListView(model: model, mailbox: folder).mailChrome(model)
            }
            .navigationDestination(for: MailSummary.self) { summary in
                MessageDetailView(model: model, summary: summary).mailChrome(model)
            }
            .sheet(isPresented: $model.composing) { ComposeView(model: model) }
            .confirmationDialog("將郵件標記為已刪除？", isPresented: Binding(
                get: { model.deleteConfirmation != nil },
                set: { if !$0 { model.deleteConfirmation = nil } }
            ), titleVisibility: .visible, presenting: model.deleteConfirmation) { summary in
                Button("標記為已刪除", role: .destructive) {
                    model.moveToTrash(summary, confirmed: true); model.deleteConfirmation = nil
                }
            } message: { _ in
                Text("這封信沒有可移入的垃圾桶。標記後校方可能清除郵件，此操作不會清空其他信件。")
            }
            .task(id: account) { model.prepare(account: isAuthenticated ? account : "") }
            .onChange(of: isAuthenticated) { _, authenticated in
                if authenticated { model.prepare(account: account) } else { model.reset() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.suspendReads() }
                if phase == .active {
                    model.prepare(account: isAuthenticated ? account : "")
                    if let selected = model.selected, model.content == nil { model.read(selected) }
                    else { model.loadInlineImages() }
                }
            }
            .onChange(of: model.banner) { _, banner in
                if let banner { AccessibilityNotification.Announcement(banner.text).post() }
            }
            .sensoryFeedback(.success, trigger: model.successFeedback)
    }
}

#if DEBUG
/// Owns isolated dependencies for the lifetime of the screenshot-review root.
struct NativeMailUIFixtureRoot: View {
    @StateObject private var model: NativeMailViewModel
    @State private var path = NavigationPath()
    @State private var ready = false
    private let screen = NativeMailUIFixtureScreen.launchScreen()

    init() {
        let service = NativeMailUIFixtureService(
            sendFailure: ProcessInfo.processInfo.arguments.contains("-NIUMailUIFixtureSendFailure"))
        let files = MailLocalFiles(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("NIUMailUIFixture", isDirectory: true))
        _model = StateObject(wrappedValue: NativeMailViewModel(
            service: service, fileStore: files, session: { "synthetic-ui-session" },
            credentials: { ("test@niu.edu.tw", "synthetic-ui-password") }))
    }

    var body: some View {
        Group {
            if ready {
                NavigationStack(path: $path) {
                    NativeMailView(account: "test@niu.edu.tw", isAuthenticated: true, model: model)
                }
            } else {
                ProgressView("正在準備郵件畫面…")
            }
        }
        // Keep fixture interactions offline, including taps on synthetic body links.
        .environment(\.openURL, OpenURLAction { _ in .handled })
        .task {
            guard !ready else { return }
            model.prepare(account: "test@niu.edu.tw")
            await model.refresh()
            guard !Task.isCancelled else { return }
            // Prepare before mounting destinations so their account observers never
            // mistake fixture initialization for an account switch and dismiss them.
            var initialPath = NavigationPath()
            if let screen, let inbox = model.folders.first(where: { $0.role == .inbox }) {
                initialPath.append(inbox)
                switch screen {
                case .detail, .detailExpanded:
                    if let message = model.messages.first(where: \.hasAttachment) { initialPath.append(message) }
                case .inline:
                    if let message = model.messages.first(where: { $0.id.uid == 19 }) { initialPath.append(message) }
                case .notification:
                    if let message = model.messages.first(where: { $0.id.uid == 17 }) { initialPath.append(message) }
                case .html:
                    if let message = model.messages.first(where: { $0.id.uid == 18 }) { initialPath.append(message) }
                case .compose:
                    model.draft = NativeMailUIFixtureService.screenshotDraft(invalidRecipient: true)
                    model.newDraft()
                case .reply:
                    if let message = model.messages.first(where: \.hasAttachment) {
                        model.compose(.replyAll, summary: message)
                    }
                case .sending, .sent, .failure:
                    model.showUIFixtureBanner(screen)
                case .list:
                    break
                }
            }
            path = initialPath
            ready = true
        }
    }
}
#endif
