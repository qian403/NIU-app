import Combine
import Foundation
import UIKit
import WebKit

struct CampusMailDownloadedFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class CampusMailBrowser: NSObject, ObservableObject {
    // Keep the compose document when navigating elsewhere in the App. Logout and
    // account switches revoke the session and release this workspace synchronously.
    private static var workspaces: [UUID: CampusMailBrowser] = [:]

    static func workspace(session: CampusMailWebSession, onExpired: @escaping (Bool) -> Void) -> CampusMailBrowser {
        if let existing = workspaces[session.id] { return existing }
        let browser = CampusMailBrowser(session: session, onExpired: onExpired)
        workspaces[session.id] = browser
        return browser
    }
    @Published private(set) var isReady = false
    @Published private(set) var isLoading = true
    @Published private(set) var canGoBack = false
    @Published private(set) var hasPopup = false
    @Published private(set) var downloadCount = 0
    @Published private(set) var files: [CampusMailDownloadedFile] = []
    @Published var errorMessage: String?
    @Published var showsDownloads = false
    @Published var dialog: JavaScriptDialog?
    @Published var externalURL: URL?

    let webView: WKWebView
    @Published private(set) var popup: WKWebView?
    private var popups: [WKWebView] = []
    private let session: CampusMailWebSession
    private let onExpired: (Bool) -> Void
    private let downloadDirectory: URL
    private var observers: [NSKeyValueObservation] = []
    private var popupObservers: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var startup: Task<Void, Never>?
    private var verification: Task<Void, Never>?
    private var downloads: [ObjectIdentifier: WKDownload] = [:]
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var started = false
    private var closed = false
    private var isVisible = false
    private var isPrinting = false
    private var identityVerified = false
    private var printHandler: PrintHandler?

    struct JavaScriptDialog {
        enum Kind { case alert, confirm, prompt }
        let kind: Kind
        let message: String
        let defaultText: String
        let complete: (Bool, String?) -> Void
    }

    init(session: CampusMailWebSession, onExpired: @escaping (Bool) -> Void) {
        self.session = session
        self.onExpired = onExpired
        downloadDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NIUMail-\(UUID().uuidString)", isDirectory: true)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configure(webView)
        let handler = PrintHandler(owner: self)
        printHandler = handler
        configuration.userContentController.add(handler, name: "niuMailPrint")
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.print = () => window.webkit.messageHandlers.niuMailPrint.postMessage('print');",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        session.onInvalidate = { [weak self] in self?.close() }
    }

    deinit {
        startup?.cancel()
        verification?.cancel()
        let directory = downloadDirectory
        Task { await Self.remove(directory) }
    }

    var displayedWebView: WKWebView { popup ?? webView }
    private var isActive: Bool { !closed && session.isValid }

    func start() {
        guard !started, isActive else { return }
        started = true
        startup = Task { [weak self] in
            guard let self else { return }
            let store = self.webView.configuration.websiteDataStore.httpCookieStore
            for cookie in self.session.cookies {
                await store.setCookie(cookie)
                guard self.isActive, !Task.isCancelled else {
                    await self.clearWebsiteData()
                    return
                }
            }
            guard self.isActive, !Task.isCancelled else { return }
            self.webView.load(URLRequest(url: CampusMailWebPolicy.inbox))
            self.startup = nil
        }
    }

    func navigate(_ url: URL) {
        guard isActive, isReady, CampusMailWebPolicy.isSchool(url) else { return }
        while popup != nil { closePopup() }
        webView.load(URLRequest(url: url))
    }

    func reload() {
        guard isActive else { return }
        errorMessage = nil
        // Reloading a document can discard a compose form, so the UI asks first.
        if webView.url == nil {
            webView.load(URLRequest(url: CampusMailWebPolicy.inbox))
        } else {
            displayedWebView.reload()
        }
    }

    func back() {
        guard isActive else { return }
        if displayedWebView.canGoBack { displayedWebView.goBack() }
        else if popup != nil { closePopup() }
    }

    func closePopup(_ view: WKWebView? = nil) {
        guard let popup = view ?? popup else { return }
        popupObservers.removeValue(forKey: ObjectIdentifier(popup))
        if dialog != nil { resolveDialog(accept: false) }
        popup.stopLoading()
        popup.navigationDelegate = nil
        popup.uiDelegate = nil
        popup.loadHTMLString("", baseURL: nil)
        popups.removeAll { $0 === popup }
        self.popup = popups.last
        hasPopup = self.popup != nil
        canGoBack = displayedWebView.canGoBack || hasPopup
    }

    func pause() {
        // Preserve drafts and the live document. Cancel transfers that no longer
        // have a visible owner; never reload or replay a sending request here.
        guard isActive else { return }
        isVisible = false
        let pendingFiles = Array(destinations.values)
        for download in downloads.values {
            download.delegate = nil
            download.cancel { _ in }
        }
        if !downloads.isEmpty { errorMessage = "附件下載已暫停，請回到信件重新下載。" }
        downloads.removeAll()
        destinations.removeAll()
        downloadCount = 0
        Task { for url in pendingFiles { await Self.remove(url.deletingLastPathComponent()) } }
        webView.setAllMediaPlaybackSuspended(true)
        popups.forEach { $0.setAllMediaPlaybackSuspended(true) }
    }

    func resume() {
        guard isActive else { return }
        isVisible = true
        webView.setAllMediaPlaybackSuspended(false)
        popups.forEach { $0.setAllMediaPlaybackSuspended(false) }
    }

    func resolveDialog(accept: Bool, text: String? = nil) {
        let pending = dialog
        dialog = nil
        pending?.complete(accept, text)
    }

    func close() {
        guard !closed else { return }
        closed = true
        isVisible = false
        if isPrinting {
            UIPrintInteractionController.shared.dismiss(animated: false)
            isPrinting = false
        }
        if Self.workspaces[session.id] === self { Self.workspaces.removeValue(forKey: session.id) }
        isReady = false
        isLoading = false
        startup?.cancel()
        verification?.cancel()
        observers.removeAll()
        resolveDialog(accept: false)
        externalURL = nil
        showsDownloads = false
        while popup != nil { closePopup() }
        for download in downloads.values {
            download.delegate = nil
            download.cancel { _ in }
        }
        downloads.removeAll()
        destinations.removeAll()
        downloadCount = 0
        files = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.loadHTMLString("", baseURL: nil)
        let directory = downloadDirectory
        Task { [self] in
            await clearWebsiteData()
            await Self.remove(directory)
        }
    }

    private func clearWebsiteData() async {
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    private func configure(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = false
        let urlObserver = view.observe(\.url, options: [.new]) { [weak self, weak view] _, _ in
            Task { @MainActor [weak self, weak view] in
                guard let self, self.isActive, let view else { return }
                self.checkLocation(view)
            }
        }
        let backObserver = view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.canGoBack = self.displayedWebView.canGoBack || self.hasPopup
            }
        }
        if view === webView { observers = [urlObserver, backObserver] }
        else { popupObservers[ObjectIdentifier(view)] = [urlObserver, backObserver] }
    }

    private func checkLocation(_ view: WKWebView) {
        guard let url = view.url else { return }
        if CampusMailWebPolicy.isLogin(url) {
            close()
            onExpired(false)
        }
    }

    private func verifyIdentity() {
        guard verification == nil, isActive else { return }
        verification = Task { [weak self] in
            guard let self else { return }
            defer { self.verification = nil }
            do {
                let result = try await self.webView.callAsyncJavaScript("""
                    const controller = new AbortController();
                    const timer = setTimeout(() => controller.abort(), 15000);
                    try {
                        const response = await fetch('/api/auth/user', {
                            credentials: 'same-origin', cache: 'no-store', signal: controller.signal
                        });
                        if (response.status === 401 || response.status === 403) return { expired: true };
                        if (!response.ok) return { failed: true };
                        const user = await response.json();
                        return { username: user.username };
                    } finally { clearTimeout(timer); }
                    """, arguments: [:], in: nil, contentWorld: .defaultClient)
                guard self.isActive, !Task.isCancelled else { return }
                guard let value = result as? [String: Any] else { throw CampusMailError.invalidResponse }
                if value["expired"] as? Bool == true {
                    self.close()
                    self.onExpired(false)
                } else if let username = value["username"] as? String {
                    guard username.caseInsensitiveCompare(self.session.account) == .orderedSame else {
                        self.close()
                        self.onExpired(true)
                        return
                    }
                    self.identityVerified = true
                    self.isReady = true
                    self.isLoading = false
                } else { throw CampusMailError.invalidResponse }
            } catch {
                guard self.isActive, !Task.isCancelled else { return }
                self.isLoading = false
                self.errorMessage = "無法確認郵件連線，請檢查網路後重新載入。"
            }
        }
    }

    private func failed(_ error: Error) {
        guard isActive, (error as? URLError)?.code != .cancelled,
              (error as NSError).code != 102 else { return }
        isLoading = false
        errorMessage = (error as? URLError)?.code == .notConnectedToInternet
            ? "目前沒有網路連線。恢復連線後可重新載入郵件。"
            : "郵件頁面載入失敗，請稍後重試。"
    }

    private func showExternal(_ url: URL) {
        guard isActive, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        externalURL = url
    }

    private func trackDownload(_ download: WKDownload) {
        guard isActive else { download.cancel { _ in }; return }
        isLoading = false
        downloads[ObjectIdentifier(download)] = download
        downloadCount = downloads.count
        download.delegate = self
    }

    @concurrent
    private static func destination(directory: URL, name: String) async throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return folder.appendingPathComponent(CampusMailWebPolicy.filename(name))
    }

    @concurrent
    private static func remove(_ url: URL) async {
        do { try FileManager.default.removeItem(at: url) }
        catch {
            // A cancelled download may never have created its destination.
            if (error as NSError).code != NSFileNoSuchFileError {
                // The directory is in the OS temporary area and is never reused.
                return
            }
        }
    }

    private final class PrintHandler: NSObject, WKScriptMessageHandler {
        weak var owner: CampusMailBrowser?
        init(owner: CampusMailBrowser) { self.owner = owner }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let owner, owner.isActive, owner.isVisible, message.frameInfo.isMainFrame,
                  let view = message.webView,
                  view === owner.webView || view === owner.popup,
                  message.frameInfo.securityOrigin.host == CampusMailWebPolicy.origin.host else { return }
            let controller = UIPrintInteractionController.shared
            controller.printFormatter = view.viewPrintFormatter()
            owner.isPrinting = true
            controller.present(animated: true) { [weak owner] _, _, _ in owner?.isPrinting = false }
        }
    }
}

extension CampusMailBrowser: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard isActive, let url = action.request.url else { decisionHandler(.cancel); return }
        if CampusMailWebPolicy.isSchool(url) || CampusMailWebPolicy.isSchoolBlob(url) {
            if action.targetFrame?.isMainFrame == true, CampusMailWebPolicy.isLogin(url) {
                decisionHandler(.cancel)
                close()
                onExpired(false)
                return
            }
            decisionHandler(action.shouldPerformDownload ? .download : .allow)
        } else if url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" {
            decisionHandler(.allow)
        } else if action.targetFrame?.isMainFrame == false {
            // School messages may use an isolated body iframe.
            decisionHandler(url.scheme == "https" || url.scheme == "data" ? .allow : .cancel)
        } else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated || action.targetFrame == nil { showExternal(url) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard isActive else { decisionHandler(.cancel); return }
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(!response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") ? .download : .allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard isActive else { return }
        isLoading = true
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isActive else { return }
        checkLocation(webView)
        if webView === self.webView, !identityVerified { verifyIdentity() }
        else { isLoading = false }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard isActive else { return }
        isLoading = false
        errorMessage = "郵件頁面已停止，請重新載入。尚未儲存的內容可能需要重新輸入；寄信結果請先查看寄件備份。"
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { trackDownload(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { trackDownload(download) }
}

extension CampusMailBrowser: WKUIDelegate {
    // File inputs use WebKit's system picker, including taking a photo.
    // Live camera/microphone streams are separate and not needed for attachments.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard isActive, action.sourceFrame.securityOrigin.host == CampusMailWebPolicy.origin.host else { return nil }
        if let url = action.request.url, !CampusMailWebPolicy.isSchool(url),
           !CampusMailWebPolicy.isSchoolBlob(url), url.absoluteString != "about:blank" {
            showExternal(url)
            return nil
        }
        let child = WKWebView(frame: .zero, configuration: configuration)
        configure(child)
        popups.append(child)
        popup = child
        hasPopup = true
        canGoBack = true
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        if popups.contains(where: { $0 === webView }) { closePopup(webView) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard isActive, frame.securityOrigin.host == CampusMailWebPolicy.origin.host else { completionHandler(); return }
        resolveDialog(accept: false)
        dialog = JavaScriptDialog(kind: .alert, message: String(message.prefix(2000)), defaultText: "") { _, _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard isActive, frame.securityOrigin.host == CampusMailWebPolicy.origin.host else { completionHandler(false); return }
        resolveDialog(accept: false)
        dialog = JavaScriptDialog(kind: .confirm, message: String(message.prefix(2000)), defaultText: "") { accept, _ in completionHandler(accept) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard isActive, frame.securityOrigin.host == CampusMailWebPolicy.origin.host else { completionHandler(nil); return }
        resolveDialog(accept: false)
        dialog = JavaScriptDialog(kind: .prompt, message: String(prompt.prefix(2000)), defaultText: defaultText ?? "") { accept, text in
            completionHandler(accept ? text ?? "" : nil)
        }
    }
}

extension CampusMailBrowser: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        guard isActive, downloads[key] != nil, let url = response.url,
              CampusMailWebPolicy.isSchool(url) || CampusMailWebPolicy.isSchoolBlob(url) else {
            completionHandler(nil)
            return
        }
        let directory = downloadDirectory
        Task { [weak self] in
            do {
                let url = try await Self.destination(directory: directory, name: suggestedFilename)
                guard let self, self.isActive, self.downloads[key] != nil else {
                    completionHandler(nil)
                    await Self.remove(url.deletingLastPathComponent())
                    return
                }
                self.destinations[key] = url
                completionHandler(url)
            } catch {
                if let self, self.isActive { self.errorMessage = "無法儲存附件，請確認裝置儲存空間後重試。" }
                completionHandler(nil)
            }
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(isActive && request.url.map(CampusMailWebPolicy.isSchool) == true ? .allow : .cancel)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        downloads.removeValue(forKey: key)
        downloadCount = downloads.count
        guard let url = destinations.removeValue(forKey: key), isActive else { return }
        files.append(CampusMailDownloadedFile(url: url))
        showsDownloads = true
        if popup?.url == nil { closePopup() }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        downloads.removeValue(forKey: key)
        downloadCount = downloads.count
        if let url = destinations.removeValue(forKey: key) {
            Task { await Self.remove(url.deletingLastPathComponent()) }
        }
        guard isActive, (error as? URLError)?.code != .cancelled else { return }
        errorMessage = "附件下載失敗，請恢復連線後重新下載。"
    }
}
