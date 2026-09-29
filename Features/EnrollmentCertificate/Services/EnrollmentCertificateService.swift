import Foundation
import WebKit
import PDFKit

@MainActor
final class EnrollmentRegistrationService: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var onProgress: ((String) -> Void)?
    private var continuation: CheckedContinuation<EnrollmentSnapshot, Error>?
    private var pollTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var didOpenRegistration = false
    private var mainFrameReady = false
    private var didAttemptBridge = false
    private var bridgeTask: Task<Void, Never>?
    private var account = ""
    private var navigationGeneration = UUID()
    private let mainFrameURL: URL?
    private let allowsNavigation: (URL) -> Bool

    init(webView: WKWebView? = nil, mainFrameURL: URL? = EnrollmentEndpoint.mainFrame,
         allowsNavigation: @escaping (URL) -> Bool = EnrollmentEndpoint.allowsRegistrationNavigation) {
        self.mainFrameURL = mainFrameURL
        self.allowsNavigation = allowsNavigation
        if let webView {
            self.webView = webView
        } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 640), configuration: config)
        }
        super.init()
        self.webView.navigationDelegate = self
    }

    func load(account: String) async throws -> EnrollmentSnapshot {
        try Task.checkCancellation()
        guard let mainFrame = mainFrameURL else { throw EnrollmentError.invalidResponse }
        self.account = account
        report("正在讀取校務資料…")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(45)) } catch { return }
                    self?.finish(.failure(URLError(.timedOut)))
                }
                // Reuse the shared acade cookies first. Exchange a GUID only if
                // the school actually reports an expired session.
                webView.load(URLRequest(url: mainFrame, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
                pollTask = Task { [weak self] in
                    // Frame loads do not consistently invoke the main-frame didFinish delegate.
                    for _ in 0..<80 {
                        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
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
                                    self.report("正在讀取註冊結果…")
                                }
                            }
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
                    self?.finish(.failure(URLError(.timedOut)))
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
        pollTask?.cancel()
        pollTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        onProgress = nil
        if waiting != nil {
            switch result {
            case .success: print("[Enrollment] 註冊查詢完成")
            case .failure(let error): print("[Enrollment] 註冊查詢結束 code=\((error as NSError).code)")
            }
        }
        waiting?.resume(with: result)
    }

    private func report(_ message: String) {
        print("[Enrollment] \(message)")
        onProgress?(message)
    }

    private func connectUsingExistingSSO() {
        guard continuation != nil, bridgeTask == nil else { return }
        guard !didAttemptBridge else {
            finish(.failure(EnrollmentError.sessionExpired)); return
        }
        didAttemptBridge = true
        navigationGeneration = UUID()
        mainFrameReady = false
        didOpenRegistration = false
        webView.stopLoading()
        report("正在沿用既有登入連接教務系統…")
        bridgeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let guid = try await SSOGUIDBridge.requestGUID(account: self.account)
                guard !Task.isCancelled, self.continuation != nil else { return }
                guard let url = SSOGUIDBridge.acadeLoginURL(guid: guid) else { throw EnrollmentError.invalidResponse }
                self.bridgeTask = nil
                self.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            } catch {
                guard !Task.isCancelled, self.continuation != nil else { return }
                let expired = (error as? URLError)?.code == .userAuthenticationRequired
                self.finish(.failure(expired ? EnrollmentError.sessionExpired : error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil, bridgeTask == nil, let url = webView.url else { return }
        // Only log a path: Login.aspx query strings contain the one-use GUID.
        print("[Enrollment] 已載入 path=\(url.path)")
        if SSOGUIDBridge.isSessionExpiredURL(url) {
            connectUsingExistingSSO()
        } else if EnrollmentEndpoint.isLegacyPortalLanding(url) {
            if let mainFrame = mainFrameURL { webView.load(URLRequest(url: mainFrame)) }
        } else if url.host?.lowercased() == "acade.niu.edu.tw",
                  url.path.lowercased() == "/niu/mainframe.aspx", !mainFrameReady {
            mainFrameReady = true
            report("正在開啟註冊查詢…")
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame != false, SSOGUIDBridge.isSessionExpiredURL(url) {
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
