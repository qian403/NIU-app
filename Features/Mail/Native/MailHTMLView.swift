import SwiftUI
import WebKit
#if DEBUG
import os
#endif

/// Read-only mail document. It never shares a browser session with SSO or Webmail.
struct MailHTMLView: UIViewRepresentable {
    let document: MailHTMLDocument
    let message: MailMessageKey
    let model: NativeMailViewModel
    let externalImages: Bool
    let imageRevision: Int
    @Binding var height: CGFloat
    @Binding var loading: Bool
    @Binding var failed: Bool
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MailHTMLContainer {
        let configuration = WKWebViewConfiguration()
        // WebKit documents that this disables content scripts, not App-injected JS:
        // https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebpagePreferences.h
        // Measurement below runs in .defaultClient; mail scripts stay disabled.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        // Image completion may not change UIScrollView.contentSize when the mail
        // clips overflow. Notify the App independently; never enable page scripts.
        configuration.userContentController.add(MailImageLoadHandler(context.coordinator),
            contentWorld: .defaultClient, name: "mailImageLayout")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            for (const event of ['load', 'error']) {
                document.addEventListener(event, function(event) {
                    if (event.target instanceof HTMLImageElement) {
                        window.webkit.messageHandlers.mailImageLayout.postMessage(null);
                    }
                }, true);
            }
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.dataDetectorTypes = []
        configuration.setURLSchemeHandler(context.coordinator.cid, forURLScheme: MailHTMLPolicy.scheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.bounces = false
        view.scrollView.showsVerticalScrollIndicator = false
        view.isOpaque = false
        view.backgroundColor = document.hasOwnColors ? .white : .systemBackground
        view.scrollView.backgroundColor = view.backgroundColor
        view.navigationDelegate = context.coordinator
        view.allowsLinkPreview = false
        let container = MailHTMLContainer(webView: view)
        container.widthDidChange = { [weak coordinator = context.coordinator] in coordinator?.scheduleLayout() }
        context.coordinator.observe(container)
        return container
    }

    func updateUIView(_ container: MailHTMLContainer, context: Context) {
        context.coordinator.update(self, view: container.webView)
    }

    static func dismantleUIView(_ container: MailHTMLContainer, coordinator: Coordinator) {
        coordinator.stop(container.webView)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        weak var model: NativeMailViewModel?
        private weak var webView: WKWebView?
        private weak var container: MailHTMLContainer?
        #if DEBUG
        private static let logger = Logger(subsystem: "dev.chienniuapp", category: "MailHTML")
        #endif
        let cid: MailCIDSchemeHandler
        private var observation: NSKeyValueObservation?
        private var generation = UUID()
        private var signature: String?
        private var initialLoad = false
        private var activeNavigation: WKNavigation?
        private var documentReady = false
        private var layoutTask: Task<Void, Never>?
        private var viewportWidth: CGFloat = 0
        private var geometryRevision = 0
        private var widthReflows = 0
        private var measuring = false
        private var needsMeasurement = false
        private var height: Binding<CGFloat>
        private var loading: Binding<Bool>
        private var failed: Binding<Bool>
        private var openURL: OpenURLAction

        init(_ parent: MailHTMLView) {
            model = parent.model
            cid = MailCIDSchemeHandler(model: parent.model, message: parent.message)
            height = parent.$height; loading = parent.$loading; failed = parent.$failed; openURL = parent.openURL
        }

        func observe(_ container: MailHTMLContainer) {
            self.container = container
            let view = container.webView
            webView = view
            observation = view.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    // Read current geometry on the main actor, never a captured
                    // size that might belong to the preceding document.
                    self?.scheduleLayout()
                }
            }
        }

        func scheduleLayout() {
            guard documentReady, webView != nil else { return }
            needsMeasurement = true
            guard !measuring, layoutTask == nil else { return }
            let token = generation
            layoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, self.generation == token, self.documentReady else { return }
                self.layoutTask = nil
                self.fitAndMeasure()
            }
        }

        private func fitAndMeasure() {
            guard let view = webView, let container, container.bounds.width > 0 else { return }
            if abs(viewportWidth - container.bounds.width) > 0.5 {
                viewportWidth = container.bounds.width
                widthReflows = 0
                container.contentWidth = viewportWidth
                container.contentHeight = 1
                container.setNeedsLayout()
                container.layoutIfNeeded()
                height.wrappedValue = 1
                scheduleLayout()
                return
            }
            let token = generation, revision = geometryRevision
            let width = container.bounds.width, layoutWidth = view.bounds.width
            measuring = true
            needsMeasurement = false
            view.evaluateJavaScript(MailHTMLPolicy.measurementScript, in: nil, in: .defaultClient) { [weak self, weak view, weak container] result in
                guard let self, let view, let container, self.webView === view,
                      self.generation == token, self.documentReady else { return }
                self.measuring = false
                guard self.geometryRevision == revision, abs(container.bounds.width - width) <= 0.5,
                      view.bounds.width == layoutWidth else {
                    self.scheduleLayout(); return
                }
                guard case .success(let value) = result, let dimensions = value as? [String: NSNumber],
                      let cssWidth = dimensions["width"]?.doubleValue,
                      let cssHeight = dimensions["height"]?.doubleValue,
                      let clientWidth = dimensions["clientWidth"]?.doubleValue,
                      let right = dimensions["right"]?.doubleValue,
                      let bottom = dimensions["bottom"]?.doubleValue,
                      [cssWidth, cssHeight, clientWidth, right, bottom].allSatisfy({ $0.isFinite && $0 >= 0 }),
                      cssWidth > 0, cssHeight > 0 else {
                    self.fail(); return
                }
                let naturalWidth = max(Double(width), Double(container.contentWidth), ceil(max(cssWidth, right)))
                let zoom = MailHTMLPolicy.fittingScale(contentWidth: naturalWidth, viewportWidth: Double(width))
                #if DEBUG
                // Numeric-only columns: container bounds.width, WebView bounds.width,
                // scrollWidth, scrollHeight, clientWidth, max rect.right, pageZoom,
                // calculated native scale. No mail content or URL is logged.
                Self.logger.debug("\(Double(width), privacy: .public) \(Double(layoutWidth), privacy: .public) \(cssWidth, privacy: .public) \(cssHeight, privacy: .public) \(clientWidth, privacy: .public) \(right, privacy: .public) \(Double(view.pageZoom), privacy: .public) \(zoom, privacy: .public)")
                #endif
                if naturalWidth > Double(container.contentWidth) {
                    // Percentage widths plus fixed padding can grow at every reflow.
                    // Bound this work and use the existing plain-text fallback.
                    guard self.widthReflows < 4 else { self.fail(); return }
                    self.widthReflows += 1
                    container.contentWidth = CGFloat(naturalWidth)
                    container.contentHeight = 1
                    container.setNeedsLayout()
                    container.layoutIfNeeded()
                    // Lay out at the natural width before publishing the height.
                    self.scheduleLayout()
                    return
                }
                self.widthReflows = 0
                let naturalHeight = ceil(max(cssHeight, bottom))
                let measured = max(1, ceil(naturalHeight * zoom))
                // Keep the WebView's layout height independent of SwiftUI's rounded
                // display height, so scrollHeight's viewport floor cannot grow it.
                container.contentHeight = CGFloat(naturalHeight)
                container.setNeedsLayout()
                if abs(Double(self.height.wrappedValue) - (measured + 1)) > 0.5 {
                    self.height.wrappedValue = CGFloat(measured + 1)
                }
                if self.needsMeasurement { self.scheduleLayout() }
            }
        }

        func imageDidLoad() {
            guard documentReady else { return }
            geometryRevision += 1
            // Images can shrink as well as grow. Remove the previous viewport-height
            // floor before measuring, without changing the outer SwiftUI height.
            container?.contentHeight = 1
            container?.setNeedsLayout()
            container?.layoutIfNeeded()
            scheduleLayout()
        }

        func update(_ parent: MailHTMLView, view: WKWebView) {
            height = parent.$height; loading = parent.$loading; failed = parent.$failed; openURL = parent.openURL
            let next = "\(parent.document.insertionToken)-\(parent.externalImages)-\(parent.imageRevision)"
            guard signature != next else { return }
            signature = next; generation = UUID()
            let token = generation
            documentReady = false; activeNavigation = nil
            layoutTask?.cancel(); layoutTask = nil
            viewportWidth = 0; widthReflows = 0; geometryRevision += 1
            measuring = false; needsMeasurement = false
            view.stopLoading(); cid.stopAll()
            view.pageZoom = 1
            container?.contentWidth = 0
            container?.contentHeight = 1
            container?.setNeedsLayout()
            view.scrollView.isScrollEnabled = false
            view.scrollView.setContentOffset(.zero, animated: false)
            let html = parent.document.rendered(externalImages: parent.externalImages)
            let rules = MailHTMLPolicy.rules(externalImages: parent.externalImages)
            let identifier = parent.externalImages ? "niu-mail-images-v2" : "niu-mail-private-v2"
            // No HTML is loaded until the blocker compiles successfully (fail closed).
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { [weak self, weak view] rule, _ in
                guard let self, let view, self.webView === view, self.generation == token else { return }
                guard let rule else { self.fail(); return }
                view.configuration.userContentController.removeAllContentRuleLists()
                view.configuration.userContentController.add(rule)
                self.loading.wrappedValue = true
                self.initialLoad = true
                self.activeNavigation = view.loadHTMLString(html, baseURL: nil)
            }
        }

        func stop(_ view: WKWebView) {
            generation = UUID(); initialLoad = false
            documentReady = false; activeNavigation = nil
            layoutTask?.cancel(); layoutTask = nil
            container?.widthDidChange = nil
            view.stopLoading(); view.navigationDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "mailImageLayout", contentWorld: .defaultClient)
            view.configuration.userContentController.removeAllUserScripts()
            observation?.invalidate(); observation = nil
            cid.stopAll(); webView = nil
        }

        private func fail() {
            documentReady = false; activeNavigation = nil
            layoutTask?.cancel(); layoutTask = nil
            webView?.stopLoading(); cid.stopAll()
            loading.wrappedValue = false; failed.wrappedValue = true
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let decision = MailHTMLPolicy.navigation(action.request.url, userActivated: action.navigationType == .linkActivated,
                initialLoad: initialLoad, mainFrame: action.targetFrame?.isMainFrame == true)
            if decision == .initial { initialLoad = false; decisionHandler(.allow); return }
            decisionHandler(.cancel)
            switch decision {
            case .external(let url): openURL(url)
            case .compose(let to, let subject): model?.composeMailto(to: to, subject: subject)
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard self.webView === webView, navigation === activeNavigation else { return }
            // didFinish includes initial CID / permitted remote-image loads. Later
            // image load/error events and contentSize KVO remeasure; manual CID
            // retry reloads HTML. Signals arriving before didFinish are covered here.
            documentReady = true
            loading.wrappedValue = false
            scheduleLayout()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard navigation === activeNavigation else { return }
            if (error as NSError).code != NSURLErrorCancelled { fail() }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard navigation === activeNavigation else { return }
            if (error as NSError).code != NSURLErrorCancelled { fail() }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }

        deinit { layoutTask?.cancel() }
    }
}

/// The content controller retains its handler; keep the coordinator reference weak.
@MainActor private final class MailImageLoadHandler: NSObject, WKScriptMessageHandler {
    private weak var coordinator: MailHTMLView.Coordinator?

    init(_ coordinator: MailHTMLView.Coordinator) { self.coordinator = coordinator }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        // No message payload is used; always measure the current document afresh.
        coordinator?.imageDidLoad()
    }
}

/// Use native geometry to scale the whole rendered page (including fonts), not
/// pageZoom: WebKit can reflow a device-width viewport as pageZoom changes. The
/// WebView instead lays out at the measured natural width with pageZoom == 1;
/// UIKit transforms its output without changing CSS pixels or running page scripts.
/// initial-scale=1 (without device-width) derives the viewport from these bounds.
final class MailHTMLContainer: UIView {
    let webView: WKWebView
    var widthDidChange: (() -> Void)?
    var contentWidth: CGFloat = 0
    var contentHeight: CGFloat = 1
    private var previousWidth: CGFloat = 0

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let naturalWidth = max(bounds.width, contentWidth)
        let scale = CGFloat(MailHTMLPolicy.fittingScale(contentWidth: Double(naturalWidth), viewportWidth: Double(bounds.width)))
        // With a nonidentity transform, use bounds/center, never frame.
        webView.bounds = CGRect(x: 0, y: 0, width: naturalWidth, height: contentHeight)
        webView.transform = CGAffineTransform(scaleX: scale, y: scale)
        webView.center = CGPoint(x: naturalWidth * scale / 2, y: contentHeight * scale / 2)
        guard abs(previousWidth - bounds.width) > 0.5 else { return }
        previousWidth = bounds.width
        widthDidChange?()
    }
}

@MainActor final class MailCIDSchemeHandler: NSObject, WKURLSchemeHandler {
    private weak var model: NativeMailViewModel?
    private let message: MailMessageKey
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(model: NativeMailViewModel, message: MailMessageKey) { self.model = model; self.message = message }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url, url.scheme == MailHTMLPolicy.scheme, url.host == "part",
              let model, model.selected?.id == message,
              let part = model.content?.inlineImages.first(where: { $0.id == String(url.path.dropFirst()) }) else {
            urlSchemeTask.didFailWithError(NativeMailError.missingMessage); return
        }
        let message = message
        tasks[id] = Task { [weak self, weak model] in
            do {
                guard let model else { throw CancellationError() }
                let data = try await model.cidData(part: part.id, message: message)
                try Task.checkCancellation()
                guard let self, self.tasks[id] != nil else { return }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: part.mime.components(separatedBy: ";")[0],
                                                    expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                self.tasks[id] = nil
            } catch {
                guard !Task.isCancelled, let self, self.tasks[id] != nil else { return }
                urlSchemeTask.didFailWithError(error); self.tasks[id] = nil
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
    func stopAll() { for task in tasks.values { task.cancel() }; tasks.removeAll() }
    deinit { for task in tasks.values { task.cancel() } }
}
