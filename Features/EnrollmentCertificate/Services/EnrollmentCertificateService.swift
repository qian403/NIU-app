import Foundation
import WebKit
import PDFKit

nonisolated enum EnrollmentLoadStage: Int, CaseIterable {
    case connecting, signingIn, opening, reading

    var title: String {
        switch self {
        case .connecting: return "連接教務系統"
        case .signingIn: return "確認登入狀態"
        case .opening: return "開啟註冊查詢"
        case .reading: return "讀取註冊結果"
        }
    }
}

@MainActor
final class EnrollmentRegistrationService: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var onProgress: ((EnrollmentLoadStage) -> Void)?
    private var continuation: CheckedContinuation<EnrollmentSnapshot, Error>?
    private var pollTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var didOpenRegistration = false
    private var mainFrameReady = false
    private var bridgeAttempts = 0
    private var didRefreshSSO = false
    private var reportedStage: EnrollmentLoadStage?
    private var bridgeTask: Task<Void, Never>?
    private var bridgeWatchdog: Task<Void, Never>?
    private var didRetryStalledBridge = false
    private var account = ""
    private var navigationGeneration = UUID()
    #if DEBUG
    private let timingStart = ProcessInfo.processInfo.systemUptime
    private var timingPrevious = ProcessInfo.processInfo.systemUptime
    #endif
    private let mainFrameURL: URL?
    private let allowsNavigation: (URL) -> Bool
    private let refreshSSO: @MainActor () async -> Bool
    private let bridgeStallTimeout: Duration

    init(webView: WKWebView? = nil, mainFrameURL: URL? = EnrollmentEndpoint.mainFrame,
         allowsNavigation: @escaping (URL) -> Bool = EnrollmentEndpoint.allowsRegistrationNavigation,
         refreshSSO: @escaping @MainActor () async -> Bool = { await SSOSessionService.shared.requestRefresh(force: true) },
         bridgeStallTimeout: Duration = .seconds(15)) {
        self.mainFrameURL = mainFrameURL
        self.allowsNavigation = allowsNavigation
        self.refreshSSO = refreshSSO
        self.bridgeStallTimeout = bridgeStallTimeout
        if let webView {
            self.webView = webView
        } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 640), configuration: config)
        }
        super.init()
        self.webView.navigationDelegate = self
        trace("WebView 已備妥")
    }

    func load(account: String) async throws -> EnrollmentSnapshot {
        try Task.checkCancellation()
        guard let mainFrame = mainFrameURL else { throw EnrollmentError.invalidResponse }
        self.account = account
        report(.connecting)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                armTimeout()
                // Reuse the shared acade cookies first. Exchange a GUID only if
                // the school actually reports an expired session.
                webView.load(URLRequest(url: mainFrame, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
                pollTask = Task { [weak self] in
                    // Frame loads do not consistently invoke the main-frame didFinish delegate.
                    // The loop ends with finish(): result, cancellation or armTimeout().
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                        guard let self, self.continuation != nil else { return }
                        guard self.mainFrameReady else { continue }
                        let navigationGeneration = self.navigationGeneration
                        do {
                            if self.mainFrameReady && !self.didOpenRegistration {
                                let menu = try await self.webView.evaluateJavaScript(EnrollmentPageScript.openRegistrationMenu)
                                guard !Task.isCancelled, self.continuation != nil else { return }
                                guard self.mainFrameReady, self.navigationGeneration == navigationGeneration else { continue }
                                if menu as? String == "opened-registration" {
                                    self.didOpenRegistration = true
                                    self.report(.reading)
                                }
                            }
                            // Before the menu records its target frame, the snapshot cannot tell
                            // a stale record left in MainFrame from the requested query.
                            guard self.didOpenRegistration else { continue }
                            let value = try await self.webView.evaluateJavaScript(EnrollmentPageScript.snapshot)
                            guard !Task.isCancelled, self.continuation != nil else { return }
                            guard self.mainFrameReady, self.navigationGeneration == navigationGeneration else { continue }
                            if let json = value as? String {
                                if json == "session-expired" {
                                    self.connectUsingExistingSSO()
                                    continue
                                }
                                guard let data = json.data(using: .utf8),
                                      let snapshot = try? JSONDecoder().decode(EnrollmentSnapshot.self, from: data),
                                      snapshot.records.allSatisfy({ $0.studentID.caseInsensitiveCompare(account) == .orderedSame }),
                                      Set(snapshot.records.map(\.id)).count == snapshot.records.count else {
                                    self.finish(.failure(EnrollmentError.invalidResponse)); return
                                }
                                self.finish(.success(snapshot)); return
                            }
                        } catch {
                            // A frame can be replaced during navigation; retry within the fixed budget.
                            if Task.isCancelled { return }
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<EnrollmentSnapshot, Error>) {
        let waiting = continuation
        continuation = nil
        bridgeTask?.cancel()
        bridgeTask = nil
        bridgeWatchdog?.cancel()
        bridgeWatchdog = nil
        pollTask?.cancel()
        pollTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        onProgress = nil
        if waiting != nil {
            switch result {
            case .success: trace("註冊查詢完成")
            case .failure(let error): trace("註冊查詢結束 code=\((error as NSError).code)")
            }
        }
        waiting?.resume(with: result)
    }

    private func trace(_ event: String) {
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        print("[Enrollment] \(event) elapsed_ms=\(Int((now - timingStart) * 1000)) stage_ms=\(Int((now - timingPrevious) * 1000))")
        timingPrevious = now
        #endif
    }

    /// Progress only moves forward, so a GUID exchange or SSO refresh never looks like a restart.
    private func report(_ stage: EnrollmentLoadStage) {
        if let reportedStage, stage.rawValue <= reportedStage.rawValue { return }
        reportedStage = stage
        trace("\(stage.title)")
        onProgress?(stage)
    }

    /// Bounds the school page work. SSO refresh suspends it because interactive
    /// recovery has its own deadline in SSOSessionService.
    private func armTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            self?.finish(.failure(URLError(.timedOut)))
        }
    }

    private func refreshSSOOnce() async throws {
        didRefreshSSO = true
        timeoutTask?.cancel()
        timeoutTask = nil
        trace("更新 SSO 登入")
        let refreshed = await refreshSSO()
        guard !Task.isCancelled, continuation != nil else { throw CancellationError() }
        guard refreshed else { throw EnrollmentError.sessionExpired }
        trace("SSO 已更新")
        armTimeout()
    }

    /// Recovers the acade session inside this query. At most one SSO refresh and
    /// two GUID bridges run, and the WebView is reused so progress never restarts.
    private func connectUsingExistingSSO() {
        guard continuation != nil, bridgeTask == nil else { return }
        // A bridge that still lands on logout means the SSO token itself is stale.
        let needsFreshSSO = bridgeAttempts > 0
        guard bridgeAttempts < 2, !(needsFreshSSO && didRefreshSSO) else {
            finish(.failure(EnrollmentError.sessionExpired)); return
        }
        startBridge(needsFreshSSO: needsFreshSSO)
    }

    private func startBridge(needsFreshSSO: Bool) {
        bridgeWatchdog?.cancel()
        bridgeWatchdog = nil
        navigationGeneration = UUID()
        mainFrameReady = false
        didOpenRegistration = false
        webView.stopLoading()
        report(.signingIn)
        bridgeTask = Task { [weak self] in
            guard let self else { return }
            do {
                if needsFreshSSO { try await self.refreshSSOOnce() }
                self.trace("請求 GUID")
                let guid: String
                do {
                    guid = try await SSOGUIDBridge.requestGUID(account: self.account)
                } catch let error as URLError where error.code == .userAuthenticationRequired && !self.didRefreshSSO {
                    guard !Task.isCancelled, self.continuation != nil else { return }
                    self.trace("GUID 需要重新登入")
                    try await self.refreshSSOOnce()
                    self.trace("重新請求 GUID")
                    guid = try await SSOGUIDBridge.requestGUID(account: self.account)
                }
                guard !Task.isCancelled, self.continuation != nil else { return }
                guard let url = SSOGUIDBridge.acadeLoginURL(guid: guid) else { throw EnrollmentError.invalidResponse }
                self.trace("GUID 已備妥，載入 bridge")
                self.bridgeAttempts += 1
                self.bridgeTask = nil
                self.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
                self.watchBridge(generation: self.navigationGeneration)
            } catch {
                guard !Task.isCancelled, self.continuation != nil else { return }
                let expired = (error as? URLError)?.code == .userAuthenticationRequired
                    || error as? EnrollmentError == .sessionExpired
                self.trace("GUID 請求結束 authRequired=\(expired) code=\((error as NSError).code)")
                self.finish(.failure(expired ? EnrollmentError.sessionExpired : error))
            }
        }
    }

    /// Login.aspx can occasionally get no response at all. A GUID is single-use, so
    /// a stalled bridge is retried once with a new GUID, then reported as a timeout.
    private func watchBridge(generation: UUID) {
        let timeout = bridgeStallTimeout
        bridgeWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.continuation != nil, self.bridgeTask == nil,
                  self.navigationGeneration == generation else { return }
            self.bridgeWatchdog = nil
            guard !self.didRetryStalledBridge else {
                self.trace("bridge 仍無回應")
                self.finish(.failure(URLError(.timedOut))); return
            }
            self.trace("bridge 無回應，改用新 GUID")
            self.didRetryStalledBridge = true
            // The stalled bridge never reached the school, so it is not evidence of a stale token.
            self.bridgeAttempts -= 1
            self.armTimeout()
            self.startBridge(needsFreshSSO: false)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard continuation != nil else { return }
        if bridgeWatchdog != nil {
            bridgeWatchdog?.cancel()
            bridgeWatchdog = nil
            // Only log a path: Login.aspx query strings contain the one-use GUID.
            trace("bridge 已回應 path=\(webView.url?.path ?? "")")
        }
        // A main document response has arrived; its login state is still being resolved.
        guard !mainFrameReady, !didOpenRegistration else { return }
        report(.signingIn)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil, bridgeTask == nil, let url = webView.url else { return }
        // Only log a path: Login.aspx query strings contain the one-use GUID.
        trace("已載入 path=\(url.path)")
        if SSOGUIDBridge.isSessionExpiredURL(url) {
            connectUsingExistingSSO()
        } else if EnrollmentEndpoint.isLegacyPortalLanding(url) {
            if let mainFrame = mainFrameURL { webView.load(URLRequest(url: mainFrame)) }
        } else if url.host?.lowercased() == "acade.niu.edu.tw",
                  url.path.lowercased() == "/niu/mainframe.aspx", !mainFrameReady {
            mainFrameReady = true
            report(.opening)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame != false, SSOGUIDBridge.isSessionExpiredURL(url) {
            trace("登入失效 path=\(url.path)")
            decisionHandler(.cancel)
            connectUsingExistingSSO()
        } else if let frame = action.targetFrame, SSOGUIDBridge.isSessionExpiredURL(url) {
            let generation = navigationGeneration
            webView.evaluateJavaScript(EnrollmentPageScript.isRegistrationFrame, in: frame, in: .page) { [weak self] result in
                guard let self, self.continuation != nil, self.navigationGeneration == generation else {
                    decisionHandler(.cancel); return
                }
                if case .success(let value) = result, value as? Bool == true {
                    decisionHandler(.cancel)
                    if self.mainFrameReady { self.connectUsingExistingSSO() }
                } else {
                    // Keep unrelated same-origin frames working; never broaden the
                    // navigation allowlist just to reach a cross-origin login page.
                    decisionHandler(self.allowsNavigation(url) ? .allow : .cancel)
                }
            }
        } else {
            let allowed = allowsNavigation(url)
            decisionHandler(allowed ? .allow : .cancel)
            if !allowed, action.targetFrame?.isMainFrame != false {
                finish(.failure(EnrollmentError.invalidResponse))
            }
            // MainFrame preloads a hidden TimeoutPage. Its subframe is not evidence
            // that the active user's registration session has expired.
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ error: Error) {
        let nsError = error as NSError
        guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
        finish(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(EnrollmentError.invalidResponse))
    }
}

/// A per-request ephemeral session keeps certificate bytes and cookies out of disk caches.
nonisolated final class EnrollmentPDFService: NSObject, URLSessionTaskDelegate, Sendable {
    private let studentID: String
    init(studentID: String) { self.studentID = studentID }

    @concurrent func load(cookies: [HTTPCookie]) async throws -> Data {
        guard let url = EnrollmentEndpoint.certificate(studentID: studentID) else { throw EnrollmentError.invalidResponse }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        for cookie in cookies where Self.isCertificateCookieDomain(cookie.domain) {
            config.httpCookieStorage?.setCookie(cookie)
        }
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validateResponse(response, studentID: studentID)
        var data = Data()
        for try await byte in bytes {
            if data.count >= Self.sizeLimit { throw EnrollmentError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        try Self.validateDocument(data)
        return data
    }

    static let sizeLimit = 15 * 1024 * 1024

    static func isCertificateCookieDomain(_ domain: String) -> Bool {
        ["ccsys.niu.edu.tw", ".ccsys.niu.edu.tw", ".niu.edu.tw"].contains(domain.lowercased())
    }

    static func validateResponse(_ response: URLResponse, studentID: String) throws {
        guard let url = EnrollmentEndpoint.certificate(studentID: studentID) else { throw EnrollmentError.invalidResponse }
        guard let http = response as? HTTPURLResponse else { throw EnrollmentError.invalidResponse }
        if http.statusCode == 401 { throw EnrollmentError.sessionExpired }
        if (300..<400).contains(http.statusCode) {
            if let location = http.value(forHTTPHeaderField: "Location"),
               let login = URL(string: location, relativeTo: url)?.absoluteURL,
               EnrollmentEndpoint.isCertificateLogin(login) { throw EnrollmentError.sessionExpired }
            throw EnrollmentError.invalidResponse
        }
        guard http.statusCode == 200 else { throw EnrollmentError.unavailable }
        guard let finalURL = http.url, EnrollmentEndpoint.isCertificate(finalURL, studentID: studentID),
              http.mimeType?.lowercased() == "application/pdf" else { throw EnrollmentError.invalidResponse }
        guard response.expectedContentLength <= sizeLimit else { throw EnrollmentError.tooLarge }
    }

    static func validateDocument(_ data: Data) throws {
        guard data.count <= sizeLimit else { throw EnrollmentError.tooLarge }
        guard data.starts(with: Data("%PDF-".utf8)), let document = PDFDocument(data: data),
              !document.isLocked, document.pageCount > 0 else { throw EnrollmentError.invalidResponse }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Return authentication redirects to the ViewModel for visible MvcTeam login.
        completionHandler(nil)
    }
}
