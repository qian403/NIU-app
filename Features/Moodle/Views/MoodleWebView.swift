import Combine
import SwiftUI
import WebKit

struct MoodleAttendanceWebOutcome: Equatable {
    enum Kind: Equatable {
        case recorded
        case alreadyRecorded
        case requiresAction
        case expired
        case failed
        case unknown
    }

    let kind: Kind
    let message: String
    let courseModuleID: Int?

    var opensWebResponseAutomatically: Bool { kind == .requiresAction }

    var isTerminal: Bool {
        switch kind {
        case .recorded, .alreadyRecorded, .expired, .failed: return true
        case .requiresAction, .unknown: return false
        }
    }

    var allowsAttendanceLinkSharing: Bool {
        kind == .recorded || kind == .alreadyRecorded
    }
}

/// Moodle page viewer.
///
/// Uses a persistent WKWebView that first navigates through the SSO EUNI
/// redirect to establish a Moodle session, then loads the target URL.
/// The WebView instance is kept alive (not recreated by SwiftUI) so the
/// session cookie persists.
struct MoodleWebPageView: View {
    let title: String
    let targetURL: String
    var showsNavigationChrome: Bool = true

    @StateObject private var webManager = MoodleWebManager()

    var body: some View {
        ZStack {
            if targetURL.contains("pluginfile.php") {
                TokenFileWebView(targetURL: targetURL)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                // Persistent WebView — not recreated on SwiftUI redraws
                MoodlePersistentWebView(manager: webManager)
                    .ignoresSafeArea(edges: .bottom)
                    .opacity(webManager.isPageReady ? 1 : 0)

                if !webManager.isPageReady {
                    VStack {
                        Spacer()
                        ProgressView()
                        Text("正在載入...")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                        Spacer()
                    }
                }

                if let message = webManager.errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2.weight(.light))
                            .foregroundColor(.secondary)
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        Button("重新載入") {
                            webManager.retry()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                }
            }
        }
        .background(Color(.systemBackground))
        .modifier(MoodleWebNavigationChrome(
            enabled: showsNavigationChrome,
            title: title,
            targetURL: targetURL,
            externalOpenURL: webManager.externalOpenURL
        ))
        .onAppear {
            if !targetURL.contains("pluginfile.php") {
                webManager.loadWithSSO(targetURL: targetURL)
            }
        }
        .onDisappear { webManager.cancel() }
    }
}

private struct MoodleWebNavigationChrome: ViewModifier {
    let enabled: Bool
    let title: String
    let targetURL: String
    let externalOpenURL: URL?

    func body(content: Content) -> some View {
        if enabled {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            if let url = externalOpenURL ?? URL(string: targetURL) {
                                UIApplication.shared.open(url)
                            }
                        }) {
                            Image(systemName: "safari")
                                .font(.body)
                                .foregroundColor(.primary)
                        }
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - Persistent WebView Manager

/// Owns a single WKWebView instance that survives SwiftUI view updates.
/// Handles the SSO → Moodle → target URL flow.
@MainActor
final class MoodleWebManager: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isPageReady = false
    @Published var externalOpenURL: URL?
    @Published var errorMessage: String?
    @Published private(set) var attendanceOutcome: MoodleAttendanceWebOutcome?
    @Published private(set) var questionNeedsWebInteraction = false

    private var storedWebView: WKWebView?
    var webView: WKWebView {
        if let storedWebView { return storedWebView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let contentController = WKUserContentController()
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        if isQuestionActivityTarget { webView.uiDelegate = questionUIDelegate }
        webView.allowsBackForwardNavigationGestures = true
        storedWebView = webView
        return webView
    }
    private var targetURL: String?
    private var originalTargetURL: String?
    private let questionUIDelegate = MoodleQuestionWebUIDelegate()
    private var phase: Phase = .idle
    private var hasStarted = false
    private var loadingTask: Task<Void, Never>?
    private var questionTimeoutTask: Task<Void, Never>?
    private var attemptedQuestionLogin = false
    private var loadGeneration = 0
    private var retriedAfterLoginRedirect = false
    private var isAutologinSupported = true
    private var hasTriedSilentRefresh = false
    private var webContentRecoveryAttempts = 0
    private var assignmentResolveAttempts = 0
    private var attendanceNavigationGeneration = 0
    private var attendanceLoginAttempts = 0
    private var attendanceCaptchaTask: Task<Void, Never>?
    private var attendanceLoginPageGeneration: Int?
    private var attendanceUsesManualLogin = false
    private let maxAttendanceLoginAttempts = 3
    private let maxAssignmentResolveAttempts = 2

    private enum Phase {
        case idle
        case resolvingEuni // Loading Std002.aspx to find EUNI redirect path
        case ssoRedirect   // Loading SSO EUNI redirect URL
        case loadingTarget // Session established, loading target
        case done
    }

    override init() {
        super.init()
    }

    func loadWithSSO(targetURL: String) {
        guard !hasStarted else { return }
        hasStarted = true
        storedWebView?.navigationDelegate = self
        isPageReady = false
        self.originalTargetURL = targetURL
        questionNeedsWebInteraction = false
        attemptedQuestionLogin = false
        storedWebView?.uiDelegate = isQuestionActivityTarget ? questionUIDelegate : nil
        self.errorMessage = nil
        self.attendanceOutcome = nil
        self.assignmentResolveAttempts = 0
        self.attendanceLoginAttempts = 0

        if isQuestionActivityTarget, let url = URL(string: targetURL) {
            // A persistent Moodle cookie is reusable; mobile autologin keys are not.
            self.targetURL = targetURL
            externalOpenURL = url
            phase = .loadingTarget
            startQuestionTimeout()
            webView.load(URLRequest(url: url, timeoutInterval: 20))
            return
        }

        let generation = loadGeneration
        loadingTask = Task { [weak self] in
            guard let self else { return }
            let resolved = await resolveTargetURL(from: targetURL)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            targetURLReady(resolved)
        }
    }

    func cancel() {
        loadGeneration &+= 1
        attendanceNavigationGeneration &+= 1
        attendanceCaptchaTask?.cancel()
        attendanceCaptchaTask = nil
        attendanceLoginPageGeneration = nil
        attendanceUsesManualLogin = false
        questionUIDelegate.cancel()
        questionTimeoutTask?.cancel()
        questionTimeoutTask = nil
        loadingTask?.cancel()
        loadingTask = nil
        storedWebView?.stopLoading()
        storedWebView?.isUserInteractionEnabled = true
        storedWebView?.navigationDelegate = nil
        storedWebView?.uiDelegate = nil
        hasStarted = false
        phase = .idle
        retriedAfterLoginRedirect = false
        hasTriedSilentRefresh = false
        webContentRecoveryAttempts = 0
        attendanceLoginAttempts = 0
        questionNeedsWebInteraction = false
    }

    func retry() {
        guard let originalTargetURL else { return }
        cancel()
        phase = .idle
        hasStarted = false
        retriedAfterLoginRedirect = false
        hasTriedSilentRefresh = false
        assignmentResolveAttempts = 0
        webContentRecoveryAttempts = 0
        attendanceLoginAttempts = 0
        targetURL = nil
        externalOpenURL = nil
        errorMessage = nil
        isPageReady = false
        loadWithSSO(targetURL: originalTargetURL)
    }

    func verifyAttendanceSubmission() {
        guard isAttendanceQRTarget,
              let originalTargetURL,
              let url = URL(string: originalTargetURL)
        else { return }

        attendanceOutcome = nil
        errorMessage = nil
        isPageReady = false
        attendanceLoginAttempts = 0
        phase = .loadingTarget
        targetURL = originalTargetURL
        externalOpenURL = url
        webView.load(URLRequest(url: url))
    }

    private var isAssignmentUploadTarget: Bool {
        let target = (originalTargetURL ?? targetURL ?? "").lowercased()
        return target.contains("/mod/assign/view.php") && target.contains("action=editsubmission")
    }

    private var isAttendanceQRTarget: Bool {
        guard let originalTargetURL else { return false }
        return MoodleAttendanceQRCode.validatedURL(from: originalTargetURL) != nil
    }

    private var isQuestionActivityTarget: Bool {
        guard let originalTargetURL,
              let url = URL(string: originalTargetURL) else { return false }
        return MoodleQuestionActivityKind.matches(url)
    }

    private func startQuestionTimeout() {
        questionTimeoutTask?.cancel()
        let generation = loadGeneration
        questionTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) }
            catch { return }
            guard let self, hasStarted, generation == loadGeneration else { return }
            loadingTask?.cancel()
            storedWebView?.stopLoading()
            failTargetLoad("問答載入逾時，請檢查網路後重試。")
        }
    }

    private func recoverQuestionLogin() {
        guard let originalTargetURL else { return }
        attemptedQuestionLogin = true
        isPageReady = false
        let generation = loadGeneration
        startQuestionTimeout()
        loadingTask?.cancel()
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await MoodleService.shared.autologinURL(for: originalTargetURL)
                guard !Task.isCancelled, generation == loadGeneration else { return }
                // No private token means there is no automatic browser-login route.
                guard url.absoluteString != originalTargetURL else {
                    showQuestionLogin()
                    return
                }
                phase = .loadingTarget
                webView.load(URLRequest(url: url, timeoutInterval: 20))
            } catch {
                guard !Task.isCancelled, generation == loadGeneration else { return }
                showQuestionLogin()
            }
        }
    }

    private func showQuestionLogin() {
        questionTimeoutTask?.cancel()
        questionTimeoutTask = nil
        questionNeedsWebInteraction = true
        isPageReady = true
        errorMessage = nil
    }
    
    private func targetURLReady(_ resolvedTarget: URL) {
        self.targetURL = resolvedTarget.absoluteString
        self.externalOpenURL = resolvedTarget

        // Attendance is a browser login flow: opening the QR target first lets
        // Moodle preserve its return URL, then a successful Moodle form login
        // redirects this same WebView back to the attendance endpoint.
        if isAttendanceQRTarget {
            phase = .loadingTarget
            webView.load(URLRequest(url: resolvedTarget))
            return
        }
        
        // Sync cookies from HTTPCookieStorage to WKWebView (like reference project)
        let generation = loadGeneration
        syncCookies { [weak self] in
            guard let self, self.hasStarted, generation == self.loadGeneration else { return }
            // If activity mobile autologin is available,
            // use it immediately instead of taking an unnecessary SSO round trip.
            if self.isQuestionActivityTarget,
               resolvedTarget.path.lowercased().contains("/admin/tool/mobile/autologin.php") {
                self.phase = .loadingTarget
                self.webView.load(URLRequest(url: resolvedTarget))
                return
            }

            if !self.isAssignmentUploadTarget,
               let euniURL = SSOEUNISettings.shared.euniFullURL,
               let url = URL(string: euniURL) {
                // Step 1: Load SSO EUNI redirect to establish Moodle session
                print("[MoodleWeb] SSO redirect: \(URL(string: euniURL)?.path ?? "")")
                self.phase = .ssoRedirect
                self.webView.load(URLRequest(url: url))
            } else {
                // No cached EUNI link: resolve from SSO portal page first.
                print("[MoodleWeb] No cached EUNI link, resolving from Std002.aspx")
                self.phase = .resolvingEuni
                if self.isAssignmentUploadTarget {
                    self.assignmentResolveAttempts += 1
                }
                if let std002 = URL(string: "https://ccsys.niu.edu.tw/SSO/Std002.aspx") {
                    self.webView.load(URLRequest(url: std002))
                } else {
                    self.phase = .done
                    self.webView.load(URLRequest(url: resolvedTarget))
                }
            }
        }
    }
    
    private func resolveTargetURL(from rawTarget: String) async -> URL {
        // A Moodle Web Service token is not a browser login. Attendance must
        // open the QR URL itself so Moodle can retain the post-login return URL.
        if isAttendanceQRTarget {
            return URL(string: rawTarget) ?? URL(string: "about:blank")!
        }
        if rawTarget.contains("/mod/assign/view.php"),
           rawTarget.contains("action=editsubmission") {
            // Assignment upload page is more stable with pure SSO cookie flow.
            return URL(string: rawTarget) ?? URL(string: "about:blank")!
        }
        guard rawTarget.contains("euni.niu.edu.tw"), isAutologinSupported else {
            return URL(string: rawTarget) ?? URL(string: "about:blank")!
        }
        
        do {
            let autologinURL = try await MoodleService.shared.autologinURL(for: rawTarget)
            print("[MoodleWeb] Autologin prepared")
            return autologinURL
        } catch {
            let message = error.localizedDescription
            if message.contains("only available when accessed via the Moodle mobile or desktop app") {
                isAutologinSupported = false
                print("[MoodleWeb] Autologin disabled by server, fallback to SSO cookie flow")
            } else {
                print("[MoodleWeb] Autologin failed: \(message)")
            }
            if let url = URL(string: rawTarget) {
                return url
            }
            return URL(string: "about:blank")!
        }
    }

    private func extractEUNIRedirectPath(from webView: WKWebView, attempt: Int = 0) {
        guard hasStarted, webView === storedWebView else { return }
        let generation = loadGeneration
        let js = """
        (function() {
            var ids = [
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl12_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl11_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl10_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl9_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl8_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl7_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl6_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl5_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl4_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl3_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl2_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl1_HyperLink1',
              'ctl00_ContentPlaceHolder1_RadListView1_ctrl0_HyperLink1'
            ];
            var candidates = [];
            for (var i = 0; i < ids.length; i++) {
                var el = document.getElementById(ids[i]);
                if (el) {
                    var href = el.getAttribute('href') || '';
                    var text = (el.textContent || '').trim();
                    if (href) {
                        candidates.push({href: href, text: text, id: ids[i]});
                    }
                    if (href.toLowerCase().indexOf('euni') !== -1 ||
                        href.toLowerCase().indexOf('jumpto') !== -1 ||
                        text.indexOf('M園區') !== -1 ||
                        text.indexOf('Moodle') !== -1 ||
                        text.indexOf('數位學習') !== -1) {
                        return JSON.stringify({match: href, candidates: candidates, bodyLen: (document.body && document.body.innerText ? document.body.innerText.length : 0)});
                    }
                }
            }
            var links = document.querySelectorAll('a[href]');
            for (var k = 0; k < links.length; k++) {
                var h = (links[k].getAttribute('href') || '');
                var t = (links[k].textContent || '').trim();
                if (h) {
                    candidates.push({href: h, text: t, id: 'a[' + k + ']'});
                }
                if (h.toLowerCase().indexOf('euni') !== -1 ||
                    h.toLowerCase().indexOf('jumpto') !== -1 ||
                    t.indexOf('M園區') !== -1 ||
                    t.indexOf('Moodle') !== -1 ||
                    t.indexOf('數位學習') !== -1) {
                    return JSON.stringify({match: h, candidates: candidates, bodyLen: (document.body && document.body.innerText ? document.body.innerText.length : 0)});
                }
            }
            return JSON.stringify({
                match: '',
                candidatesCount: candidates.length,
                bodyLen: (document.body && document.body.innerText ? document.body.innerText.length : 0)
            });
        })();
        """

        webView.evaluateJavaScript(js) { [weak self, weak webView] result, _ in
            guard let self, let webView, self.hasStarted,
                  generation == self.loadGeneration else { return }
            let rawJSON = (result as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var resolved = ""

            if let data = rawJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                resolved = (obj["match"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let candidatesCount = obj["candidatesCount"] as? Int ?? 0
                let bodyLen = obj["bodyLen"] as? Int ?? 0

                if resolved.isEmpty && attempt < 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak webView] in
                        guard let self, let webView, generation == self.loadGeneration else { return }
                        self.extractEUNIRedirectPath(from: webView, attempt: attempt + 1)
                    }
                    return
                }
                if resolved.isEmpty {
                    print("[MoodleWeb] No EUNI link from Std002 (\(candidatesCount), body=\(bodyLen))")
                }
            } else if !rawJSON.isEmpty {
                resolved = rawJSON
            }

            guard !resolved.isEmpty, SSOEUNISettings.isLikelyValidEUNIPath(resolved) else {
                if self.isAssignmentUploadTarget {
                    print("[MoodleWeb] Std002 has no EUNI link after retries, try silent refresh once")
                    self.attemptSilentRefreshAndRetry("resolvingEuni/no-euni")
                } else {
                    print("[MoodleWeb] Std002 has no EUNI link after retries, loading target directly")
                    self.fallbackToTargetAfterSSOFailure()
                }
                return
            }

            SSOEUNISettings.shared.euniRedirectPath = resolved
            guard let full = SSOEUNISettings.shared.euniFullURL, let url = URL(string: full) else {
                self.fallbackToTargetAfterSSOFailure()
                return
            }
            print("[MoodleWeb] Resolved EUNI link: \(URL(string: full)?.path ?? "")")
            self.phase = .ssoRedirect
            self.webView.load(URLRequest(url: url))
        }
    }
    
    private func retryUsingAutologin() {
        guard !retriedAfterLoginRedirect, let originalTargetURL else { return }
        retriedAfterLoginRedirect = true
        loadingTask?.cancel()
        let generation = loadGeneration
        loadingTask = Task { [weak self] in
            guard let self else { return }
            let resolved = await resolveTargetURL(from: originalTargetURL)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            self.targetURL = resolved.absoluteString
            self.externalOpenURL = resolved
            self.phase = .loadingTarget
            self.webView.load(URLRequest(url: resolved))
        }
    }

    private func isLoginPage(_ urlString: String) -> Bool {
        urlString.contains("euni.niu.edu.tw") && urlString.contains("/login")
    }

    /// Strict origin check before saved credentials are written into a page.
    /// `isLoginPage` stays loose for navigation decisions only.
    private func isTrustedAttendanceLoginPage(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "euni.niu.edu.tw"
            && (components.port == nil || components.port == 443)
            && components.user == nil && components.password == nil
            && components.path.lowercased().hasPrefix("/login/")
    }

    private struct AttendanceCaptchaPayload: Decodable {
        let hasInput: Bool
        let hasImage: Bool
        let dataURL: String?
        let complete: Bool
        let width: Int
    }

    private struct AttendanceLoginSubmission: Decodable {
        let status: String
        let action: String?
        let body: String?
    }

    private func attendanceLoginRequest(from submission: AttendanceLoginSubmission) -> URLRequest? {
        guard submission.status == "ready",
              let action = submission.action, let body = submission.body,
              let components = URLComponents(string: action),
              components.scheme == "https", components.host == "euni.niu.edu.tw",
              components.port == nil, components.user == nil, components.password == nil,
              components.path == "/login/index.php", let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://euni.niu.edu.tw", forHTTPHeaderField: "Origin")
        return request
    }

    private func handleAttendanceLoginPage(_ webView: WKWebView, excludingCaptcha: String? = nil) {
        guard attendanceLoginPageGeneration != attendanceNavigationGeneration else { return }
        attendanceLoginPageGeneration = attendanceNavigationGeneration
        guard !attendanceUsesManualLogin,
              attendanceLoginAttempts < maxAttendanceLoginAttempts,
              isTrustedAttendanceLoginPage(webView.url),
              let credentials = LoginRepository.shared.getSavedCredentials(),
              let username = javascriptLiteral(credentials.username),
              let password = javascriptLiteral(credentials.password) else {
            showAttendanceLoginPage()
            return
        }

        attendanceLoginAttempts += 1
        let attempt = attendanceLoginAttempts
        let generation = loadGeneration
        let navigationGeneration = attendanceNavigationGeneration
        let captureStarted = ProcessInfo.processInfo.systemUptime
        captureAttendanceCaptcha(
            webView,
            attempt: 1,
            generation: generation,
            navigationGeneration: navigationGeneration,
            excludingDataURL: excludingCaptcha
        ) { [weak self, weak webView] payload, image in
            guard let self, let webView, self.hasStarted,
                  generation == self.loadGeneration,
                  navigationGeneration == self.attendanceNavigationGeneration,
                  webView === self.storedWebView else { return }

            let captureMS = Int((ProcessInfo.processInfo.systemUptime - captureStarted) * 1000)
            print("[MoodleAttendance] captcha captureMs=\(captureMS) attempt=\(attempt) ready=\(image != nil)")
            guard let payload else {
                self.showAttendanceLoginPage()
                return
            }
            let hasCaptcha = payload.hasInput || payload.hasImage
            if hasCaptcha {
                guard let image else {
                    self.retryAttendanceLoginPage(
                        webView,
                        generation: generation,
                        navigationGeneration: navigationGeneration
                    )
                    return
                }
                self.attendanceCaptchaTask?.cancel()
                self.attendanceCaptchaTask = Task { [weak self, weak webView] in
                    let recognitionStarted = ProcessInfo.processInfo.systemUptime
                    let code = await SSOCaptchaProcessor.shared.recognizeAttendance(from: image)
                    guard let self, let webView, self.hasStarted,
                          !Task.isCancelled,
                          generation == self.loadGeneration,
                          navigationGeneration == self.attendanceNavigationGeneration,
                          webView === self.storedWebView else { return }
                    let recognitionMS = Int((ProcessInfo.processInfo.systemUptime - recognitionStarted) * 1000)
                    print("[MoodleAttendance] captcha ocrMs=\(recognitionMS) recognized=\(code != nil)")
                    guard let code, code.count == 5 else {
                        self.refreshAttendanceCaptcha(
                            webView,
                            previousDataURL: payload.dataURL,
                            generation: generation,
                            navigationGeneration: navigationGeneration
                        )
                        return
                    }
                    self.submitAttendanceLogin(
                        webView,
                        username: username,
                        password: password,
                        captcha: code,
                        captchaDataURL: payload.dataURL,
                        generation: generation,
                        navigationGeneration: navigationGeneration
                    )
                }
                return
            }

            // Some deployments do not inject the captcha. Preserve the old
            // username/password-only fallback, but never resubmit it forever.
            if attempt == 1 {
                self.submitAttendanceLogin(
                    webView,
                    username: username,
                    password: password,
                    captcha: nil,
                    captchaDataURL: nil,
                    generation: generation,
                    navigationGeneration: navigationGeneration
                )
            } else {
                self.showAttendanceLoginPage()
            }
        }
    }

    private func refreshAttendanceCaptcha(
        _ webView: WKWebView,
        previousDataURL: String?,
        generation: Int,
        navigationGeneration: Int
    ) {
        guard hasStarted, !attendanceUsesManualLogin,
              generation == loadGeneration, navigationGeneration == attendanceNavigationGeneration,
              webView === storedWebView else { return }
        guard attendanceLoginAttempts < maxAttendanceLoginAttempts,
              isTrustedAttendanceLoginPage(webView.url) else {
            showAttendanceLoginPage()
            return
        }
        guard let previousDataURL, let previousImage = javascriptLiteral(previousDataURL) else {
            retryAttendanceLoginPage(webView, generation: generation, navigationGeneration: navigationGeneration)
            return
        }
        let script = """
        (function(previousImage) {
            if (location.protocol !== 'https:' || location.hostname !== 'euni.niu.edu.tw' ||
                (location.port && location.port !== '443') || !location.pathname.startsWith('/login/')) {
                return 'manual';
            }
            var input = document.querySelector('#captcha, input[name="captcha"]');
            if (input && input.value.trim()) return 'manual';
            var image = document.querySelector('#imgcode, img[src*="/auth/posbosscaptcha/captcha.php"]');
            if (!input || !image) return 'unavailable';
            // A user may have already clicked while OCR was running. Wait for
            // that image instead of replacing it with yet another request.
            if (!image.complete) return 'changed';
            if (!image.naturalWidth) return 'unavailable';
            try {
                var canvas = document.createElement('canvas');
                canvas.width = image.naturalWidth;
                canvas.height = image.naturalHeight;
                var context = canvas.getContext('2d');
                if (!context) return 'unavailable';
                context.drawImage(image, 0, 0);
                if (canvas.toDataURL('image/png') !== previousImage) return 'changed';
                var previousSource = image.src;
                image.click();
                return image.src !== previousSource ? 'refreshed' : 'unavailable';
            } catch (error) { return 'unavailable'; }
        })(\(previousImage));
        """
        webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
            guard let self, let webView, self.hasStarted, !self.attendanceUsesManualLogin,
                  generation == self.loadGeneration,
                  navigationGeneration == self.attendanceNavigationGeneration,
                  webView === self.storedWebView else { return }
            if error == nil, let status = result as? String, ["refreshed", "changed"].contains(status) {
                self.attendanceLoginPageGeneration = nil
                self.handleAttendanceLoginPage(webView, excludingCaptcha: previousDataURL)
            } else if result as? String == "manual" {
                self.showAttendanceLoginPage()
            } else {
                // Missing/changed school click handler: retain the bounded fresh-GET fallback.
                self.retryAttendanceLoginPage(webView, generation: generation, navigationGeneration: navigationGeneration)
            }
        }
    }

    private func retryAttendanceLoginPage(
        _ webView: WKWebView,
        generation: Int,
        navigationGeneration: Int
    ) {
        guard hasStarted, generation == loadGeneration,
              navigationGeneration == attendanceNavigationGeneration,
              webView === storedWebView else { return }
        guard attendanceLoginAttempts < maxAttendanceLoginAttempts else {
            showAttendanceLoginPage()
            return
        }
        print("[MoodleAttendance] retrying M campus login captcha")
        let script = """
        (function() {
            var input = document.querySelector('#captcha, input[name="captcha"]');
            return !!(input && input.value.trim());
        })();
        """
        webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
            guard let self, let webView, self.hasStarted,
                  generation == self.loadGeneration,
                  navigationGeneration == self.attendanceNavigationGeneration,
                  webView === self.storedWebView else { return }
            guard error == nil, result as? Bool == false, !self.attendanceUsesManualLogin,
                  let url = URL(string: "https://euni.niu.edu.tw/login/index.php") else {
                self.showAttendanceLoginPage()
                return
            }
            // A failed login page may be a POST response. Fetch a fresh GET
            // instead of reload(), which could replay the rejected credentials.
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    private func captureAttendanceCaptcha(
        _ webView: WKWebView,
        attempt: Int,
        generation: Int,
        navigationGeneration: Int,
        excludingDataURL: String? = nil,
        completion: @escaping (AttendanceCaptchaPayload?, CaptchaImage?) -> Void
    ) {
        guard hasStarted, !attendanceUsesManualLogin, generation == loadGeneration,
              navigationGeneration == attendanceNavigationGeneration,
              webView === storedWebView else { return }
        let script = """
        (function() {
            var input = document.querySelector('#captcha, input[name="captcha"]');
            var image = document.querySelector('#imgcode, img[src*="/auth/posbosscaptcha/captcha.php"]');
            var payload = {
                hasInput: !!input,
                hasImage: !!image,
                dataURL: null,
                complete: !!(image && image.complete),
                width: image ? (image.naturalWidth || 0) : 0
            };
            if (!image || !image.complete || !image.naturalWidth) {
                return JSON.stringify(payload);
            }
            try {
                var canvas = document.createElement('canvas');
                canvas.width = image.naturalWidth;
                canvas.height = image.naturalHeight;
                var context = canvas.getContext('2d');
                if (context) {
                    context.drawImage(image, 0, 0);
                    payload.dataURL = canvas.toDataURL('image/png');
                }
            } catch (error) {}
            return JSON.stringify(payload);
        })();
        """

        webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
            guard let self, let webView, self.hasStarted, !self.attendanceUsesManualLogin,
                  generation == self.loadGeneration,
                  navigationGeneration == self.attendanceNavigationGeneration,
                  webView === self.storedWebView else { return }
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(AttendanceCaptchaPayload.self, from: data)
            else {
                completion(nil, nil)
                return
            }

            if let dataURL = payload.dataURL, dataURL != excludingDataURL,
               let image = self.decodeCaptchaDataURL(dataURL) {
                completion(payload, image)
                return
            }

            // The school's page can add the captcha after didFinish. Wait for
            // that script before deciding this login form has no captcha.
            let maxAttempts = excludingDataURL == nil ? 20 : 50
            let delay = excludingDataURL == nil ? 0.25 : 0.1
            if attempt < maxAttempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self, let webView,
                          generation == self.loadGeneration,
                          navigationGeneration == self.attendanceNavigationGeneration else { return }
                    self.captureAttendanceCaptcha(
                        webView,
                        attempt: attempt + 1,
                        generation: generation,
                        navigationGeneration: navigationGeneration,
                        excludingDataURL: excludingDataURL,
                        completion: completion
                    )
                }
            } else {
                completion(payload, nil)
            }
        }
    }

    private func decodeCaptchaDataURL(_ dataURL: String) -> CaptchaImage? {
        guard dataURL.hasPrefix("data:image"),
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let encoded = String(dataURL[dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return CaptchaImage(data: data)
    }

    private func submitAttendanceLogin(
        _ webView: WKWebView,
        username: String,
        password: String,
        captcha: String?,
        captchaDataURL: String?,
        generation: Int,
        navigationGeneration: Int
    ) {
        let captchaLiteral = captcha.flatMap(javascriptLiteral) ?? "null"
        let imageLiteral = captchaDataURL.flatMap(javascriptLiteral) ?? "null"
        guard isTrustedAttendanceLoginPage(webView.url) else {
            showAttendanceLoginPage()
            return
        }
        let script = """
        (function(username, password, captcha, capturedImage) {
            // The page may have changed since the native check; never fill credentials off-origin.
            if (location.protocol !== 'https:' || location.hostname !== 'euni.niu.edu.tw'
                || (location.port && location.port !== '443')
                || location.pathname.toLowerCase().indexOf('/login/') !== 0) return 'untrusted-origin';
            var form = document.querySelector('form[action*="login/index.php"]')
                || document.querySelector('form#login');
            var usernameInput = document.querySelector('input[name="username"], input#username');
            var passwordInput = document.querySelector('input[name="password"], input#password');
            var captchaInput = document.querySelector('#captcha, input[name="captcha"]');
            if (!form || !usernameInput || !passwordInput || (captchaInput && !captcha)) return 'missing-form';
            if (captchaInput && captchaInput.value.trim()) return 'manual-input';

            function imageIsCurrent() {
                if (!captcha) return !captchaInput;
                var image = document.querySelector('#imgcode, img[src*="/auth/posbosscaptcha/captcha.php"]');
                if (!capturedImage || !image || !image.complete || !image.naturalWidth) return false;
                try {
                    var canvas = document.createElement('canvas');
                    canvas.width = image.naturalWidth;
                    canvas.height = image.naturalHeight;
                    var context = canvas.getContext('2d');
                    if (!context) return false;
                    context.drawImage(image, 0, 0);
                    return canvas.toDataURL('image/png') === capturedImage;
                } catch (error) {
                    return false;
                }
            }
            if (!imageIsCurrent()) return 'stale-captcha';

            function setValue(input, value) {
                input.focus();
                input.value = value;
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
            }
            setValue(usernameInput, username);
            setValue(passwordInput, password);
            if (captchaInput && captcha) setValue(captchaInput, captcha);
            if (!imageIsCurrent()) {
                if (captchaInput) captchaInput.value = '';
                return 'stale-captcha';
            }

            if (form.method.toLowerCase() !== 'post'
                || (form.enctype && form.enctype !== 'application/x-www-form-urlencoded')
                || (form.checkValidity && !form.checkValidity())) return 'unsupported-form';
            var fields = new FormData(form);
            var submit = form.querySelector('button[type="submit"], input[type="submit"]');
            if (submit && submit.name && !submit.disabled) fields.append(submit.name, submit.value);
            return JSON.stringify({
                status: 'ready', action: form.action, body: new URLSearchParams(fields).toString()
            });
        })(\(username), \(password), \(captchaLiteral), \(imageLiteral));
        """

        // The school's image refresh is a tap handler. Prevent taps during
        // the short form-preparation/native-load handoff.
        webView.isUserInteractionEnabled = false
        webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
            guard let self, let webView, self.hasStarted,
                  generation == self.loadGeneration,
                  navigationGeneration == self.attendanceNavigationGeneration,
                  webView === self.storedWebView else { return }
            defer { webView.isUserInteractionEnabled = true }
            if let json = result as? String, let data = json.data(using: .utf8),
               let submission = try? JSONDecoder().decode(AttendanceLoginSubmission.self, from: data),
               let request = self.attendanceLoginRequest(from: submission) {
                // JavaScript only prepares the form. This generation check
                // precedes the actual native load, so queued JS cannot submit
                // after cancellation or a move to another document.
                webView.load(request)
                print("[MoodleAttendance] submitted M campus web login")
                self.checkAttendanceLoginSubmission(
                    webView,
                    generation: generation,
                    navigationGeneration: navigationGeneration
                )
            } else if result as? String == "manual-input" || result as? String == "untrusted-origin" {
                self.showAttendanceLoginPage()
            } else {
                self.retryAttendanceLoginPage(
                    webView,
                    generation: generation,
                    navigationGeneration: navigationGeneration
                )
            }
        }
    }

    private func checkAttendanceLoginSubmission(
        _ webView: WKWebView,
        generation: Int,
        navigationGeneration: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
            guard let self, let webView, self.hasStarted,
                  generation == self.loadGeneration,
                  navigationGeneration == self.attendanceNavigationGeneration,
                  webView === self.storedWebView else { return }
            guard !webView.isLoading else { return }

            let script = """
            !!document.querySelector('form[action*="login/index.php"], form#login')
            """
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
                guard let self, let webView, self.hasStarted,
                      generation == self.loadGeneration,
                      navigationGeneration == self.attendanceNavigationGeneration,
                      webView === self.storedWebView else { return }
                if result as? Bool == true {
                    self.retryAttendanceLoginPage(
                        webView,
                        generation: generation,
                        navigationGeneration: navigationGeneration
                    )
                }
            }
        }
    }

    private func javascriptLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func showAttendanceLoginPage() {
        attendanceUsesManualLogin = true
        attendanceCaptchaTask?.cancel()
        attendanceCaptchaTask = nil
        phase = .loadingTarget
        isPageReady = true
        attendanceOutcome = MoodleAttendanceWebOutcome(
            kind: .requiresAction,
            message: "請在 M 園區登入頁完成登入或輸入驗證碼；成功後會自動回到這次點名網址。",
            courseModuleID: nil
        )
    }

    private func isSSOSessionExpiredPage(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return SSOGUIDBridge.isSessionExpiredURL(url)
    }

    private func currentTargetRequest() -> URLRequest? {
        guard let target = targetURL, let url = URL(string: target) else { return nil }
        return URLRequest(url: url)
    }

    private func loadCurrentTarget() {
        if let request = currentTargetRequest() {
            webView.load(request)
        }
    }

    private func finishLoading() {
        questionTimeoutTask?.cancel()
        questionTimeoutTask = nil
        phase = .done
        isPageReady = true
    }

    private struct AttendancePageNotification: Decodable {
        let text: String
        let className: String
        let type: String
    }

    private struct AttendancePageSnapshot: Decodable {
        let url: String
        let body: String
        let hasAttendanceForm: Bool
        let notifications: [AttendancePageNotification]
        let errorCodes: [String]
    }

    private func inspectAttendancePage(_ webView: WKWebView) {
        let generation = attendanceNavigationGeneration
        let script = """
        (function() {
            var nodes = document.querySelectorAll(
                '[data-region="notification"], .alert, .notification, [role="alert"], .errorbox, .errormessage, [data-rel="fatalerror"]'
            );
            // Moodle keeps hidden message-drawer dialogues with role="alert" and
            // screen-reader-only dismiss labels inside alerts; neither is the response.
            var visibleNodes = Array.prototype.filter.call(nodes, function(node) {
                return node.getClientRects().length > 0
                    && !node.closest('[hidden], [aria-hidden="true"], [data-region="message-drawer"], .drawer');
            });
            var skipped = 'button, .close, .btn-close, [data-dismiss], [data-bs-dismiss], .sr-only, '
                + '.visually-hidden, .accesshide, [hidden], [aria-hidden="true"]';
            // Read only rendered text so CSS-hidden children cannot change the outcome.
            function visibleText(node) {
                var parts = [];
                var lastBlock = null;
                // Separate <br> and block boundaries without splitting inline elements.
                function blockOf(element) {
                    while (element && element !== node
                        && getComputedStyle(element).display.indexOf('inline') === 0) {
                        element = element.parentElement;
                    }
                    return element || node;
                }
                function isRendered(element) {
                    var hiddenAncestor = element && element.closest(skipped);
                    return !!element && !(hiddenAncestor && node.contains(hiddenAncestor))
                        && element.getClientRects().length > 0
                        && getComputedStyle(element).visibility === 'visible';
                }
                var walker = document.createTreeWalker(node, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
                while (walker.nextNode()) {
                    // Elements are checked themselves; text nodes through their parent.
                    if (walker.currentNode.nodeType === Node.ELEMENT_NODE) {
                        if (walker.currentNode.tagName === 'BR' && isRendered(walker.currentNode)) { parts.push(' '); }
                        continue;
                    }
                    var parent = walker.currentNode.parentElement;
                    if (!isRendered(parent)) { continue; }
                    var block = blockOf(parent);
                    if (lastBlock && block !== lastBlock) { parts.push(' '); }
                    lastBlock = block;
                    parts.push(walker.currentNode.nodeValue);
                }
                return parts.join('').replace(/\\s+/g, ' ').trim();
            }
            var notifications = visibleNodes.map(function(node) {
                return {
                    text: visibleText(node),
                    className: typeof node.className === 'string' ? node.className : '',
                    type: node.getAttribute('data-type') || node.getAttribute('role') || ''
                };
            }).filter(function(item, index, items) {
                return item.text.length > 0 && items.findIndex(function(other) {
                    return other.text === item.text;
                }) === index;
            });

            var main = document.querySelector('#region-main') || document.body;
            var errorCodes = Array.prototype.map.call(document.querySelectorAll('a[href]'), function(link) {
                // Moodle error-help links carry stable identifiers across languages.
                var parts = new URL(link.href, window.location.href).pathname.split('/').filter(Boolean);
                var index = parts.indexOf('error');
                return index >= 0 && ['attendance', 'mod_attendance'].indexOf(parts[index + 1]) >= 0
                    ? parts[index + 2] || '' : '';
            }).filter(Boolean);
            var hasAttendanceForm = Array.prototype.some.call(document.querySelectorAll('form'), function(form) {
                var action = new URL(form.action || window.location.href, window.location.href);
                return action.pathname === '/mod/attendance/attendance.php'
                    && !!form.querySelector('input[name="sessid"]')
                    && !!form.querySelector('input[name="status"], select[name="status"], input[name="studentpassword"]')
                    && !!form.querySelector('button[type="submit"], input[type="submit"]');
            });
            return JSON.stringify({
                url: window.location.href,
                body: ((main && main.innerText) || '').slice(0, 12000),
                hasAttendanceForm: hasAttendanceForm,
                notifications: notifications,
                errorCodes: errorCodes
            });
        })();
        """

        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            let raw = try? await webView.evaluateJavaScript(script) as? String
            guard generation == self.attendanceNavigationGeneration,
                  self.attendanceOutcome?.isTerminal != true else { return }
            guard let raw,
                  let data = raw.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(AttendancePageSnapshot.self, from: data)
            else {
                self.attendanceOutcome = MoodleAttendanceWebOutcome(
                    kind: .unknown,
                    message: "無法判讀 M 園區回應，請開啟原始頁面確認。",
                    courseModuleID: nil
                )
                return
            }

            let outcome = self.makeAttendanceOutcome(from: snapshot)
            print("[MoodleAttendance] result=\(outcome.kind) path=\(URL(string: snapshot.url)?.path ?? "")")
            self.attendanceOutcome = outcome
        }
    }

    private func makeAttendanceOutcome(from snapshot: AttendancePageSnapshot) -> MoodleAttendanceWebOutcome {
        let notificationText = snapshot.notifications.map(\.text).joined(separator: "\n")
        let combinedText = "\(notificationText)\n\(snapshot.body)"
        let normalized = combinedText.lowercased()
        let normalizedNotificationText = notificationText.lowercased()
        let courseModuleID = attendanceCourseModuleID(from: snapshot.url)
        let isOriginalAttendanceEndpoint = matchesOriginalAttendanceEndpoint(snapshot.url)

        guard let responseURL = URL(string: snapshot.url),
              responseURL.scheme == "https", responseURL.host == "euni.niu.edu.tw" else {
            return MoodleAttendanceWebOutcome(kind: .unknown,
                message: "未取得 M 園區的點名回應，請重新掃描或查看原始回應。", courseModuleID: nil)
        }

        let expiredPatterns = [
            "qr code has expired", "qr session has expired", "qr code expired",
            "qr 碼已過期", "qr碼已過期", "qr code 已過期", "qrcode已過期",
            "qr代碼已過期", "qr 代碼已過期", "二維碼已過期", "二维码已过期"
        ]
        let compactText = normalized.filter { !$0.isWhitespace }
        if snapshot.errorCodes.contains(where: { ["qr_pass_wrong", "qr_cookie_error"].contains($0) })
            || expiredPatterns.contains(where: { compactText.contains($0.filter { !$0.isWhitespace }) }) {
            return MoodleAttendanceWebOutcome(
                kind: .expired,
                message: "這個 QR Code 已過期，這次未完成點名。請對準老師目前顯示的最新 QR Code 重新掃描。",
                courseModuleID: courseModuleID
            )
        }

        let alreadyRecordedPatterns = [
            "attendance has already been set",
            "您的出缺席已經設置好了",
            "your attendance has already been marked as",
            "出席已被標記為",
            "出席已標記為"
        ]
        if isOriginalAttendanceEndpoint,
           let match = matchedPattern(in: normalized, patterns: alreadyRecordedPatterns) {
            return MoodleAttendanceWebOutcome(
                kind: .alreadyRecorded,
                message: bestAttendanceMessage(notificationText, fallback: match),
                courseModuleID: courseModuleID
            )
        }

        // A correctable form (for example, a mistyped attendance password) is
        // not a terminal failure. Expired QR codes above still require a new scan.
        if snapshot.hasAttendanceForm {
            return MoodleAttendanceWebOutcome(
                kind: .requiresAction,
                message: bestAttendanceMessage(notificationText,
                    fallback: "這堂課仍需要在 M 園區選擇狀態或送出表單。"),
                courseModuleID: courseModuleID
            )
        }

        let failurePatterns = [
            "incorrect password",
            "attendance has not been recorded",
            "no valid status was available",
            "not currently available for self-marking",
            "not a member of the course group",
            "outside the allowed subnet",
            "not in the allowed range",
            "device appears to have been used to record attendance for another student",
            "沒有可用的有效狀態",
            "學生只可以從某些特定的位置上紀錄出缺席",
            "自我標記已被禁用",
            "密碼不正確",
            "密碼錯誤",
            "尚未開放",
            "未開放點名",
            "沒有可用的出席狀態",
            "不在允許的網路範圍",
            "不在允許的子網路",
            "其他學生使用此裝置",
            "未記錄出席",
            "未紀錄出席"
        ]
        if let match = matchedPattern(in: normalized, patterns: failurePatterns) {
            return MoodleAttendanceWebOutcome(
                kind: .failed,
                message: bestAttendanceMessage(notificationText, fallback: match),
                courseModuleID: courseModuleID
            )
        }

        let recordedPatterns = [
            "your attendance in this session has been recorded",
            "attendance in this session has been recorded",
            "您在此上課時段的出席已被記錄",
            "您在此上課時段的出席已被紀錄"
        ]
        if courseModuleID != nil,
           matchedPattern(in: normalizedNotificationText, patterns: recordedPatterns) != nil {
            return MoodleAttendanceWebOutcome(
                kind: .recorded,
                message: bestAttendanceMessage(notificationText, fallback: "M 園區已接受這次點名。"),
                courseModuleID: courseModuleID
            )
        }

        return MoodleAttendanceWebOutcome(
            kind: .unknown,
            message: "M 園區沒有回傳可確認的點名結果，可能是 QR Code 已失效或頁面已跳轉。請重新掃描最新的 QR Code，或查看原始回應。",
            courseModuleID: courseModuleID
        )
    }

    private func matchedPattern(in text: String, patterns: [String]) -> String? {
        patterns.first { text.contains($0) }
    }

    private func bestAttendanceMessage(_ message: String, fallback: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(280))
    }

    private func attendanceCourseModuleID(from urlString: String) -> Int? {
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "euni.niu.edu.tw",
              components.port == nil || components.port == 443,
              components.path.lowercased() == "/mod/attendance/view.php",
              let value = components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value
        else { return nil }
        return Int(value)
    }

    private func matchesOriginalAttendanceEndpoint(_ urlString: String) -> Bool {
        guard let originalTargetURL,
              let expected = MoodleAttendanceQRCode.validatedURL(from: originalTargetURL),
              let actual = MoodleAttendanceQRCode.validatedURL(from: urlString),
              let expectedComponents = URLComponents(url: expected, resolvingAgainstBaseURL: false),
              let actualComponents = URLComponents(url: actual, resolvingAgainstBaseURL: false)
        else { return false }

        func value(named name: String, in components: URLComponents) -> String? {
            components.queryItems?.first(where: { $0.name.lowercased() == name })?.value
        }

        return value(named: "sessid", in: expectedComponents) == value(named: "sessid", in: actualComponents)
            && value(named: "qrpass", in: expectedComponents) == value(named: "qrpass", in: actualComponents)
    }

    private func failAsNeedsRelogin() {
        phase = .done
        isPageReady = false
        errorMessage = "M 園區登入已失效，請回設定頁重新登入後再試。"
    }

    private func failTargetLoad(_ message: String) {
        questionTimeoutTask?.cancel()
        questionTimeoutTask = nil
        phase = .done
        isPageReady = false
        errorMessage = message
    }

    private func resolveEuniInSameWebViewForUpload(reason: String) {
        guard isAssignmentUploadTarget else {
            fallbackToTargetAfterSSOFailure()
            return
        }
        assignmentResolveAttempts += 1
        guard assignmentResolveAttempts <= maxAssignmentResolveAttempts else {
            print("[MoodleWeb] \(reason), exceeded resolve attempts")
            failAsNeedsRelogin()
            return
        }
        print("[MoodleWeb] \(reason), resolve EUNI in same webview (\(assignmentResolveAttempts)/\(maxAssignmentResolveAttempts))")
        SSOEUNISettings.shared.clear()
        phase = .resolvingEuni
        if let std002 = URL(string: "https://ccsys.niu.edu.tw/SSO/Std002.aspx") {
            webView.load(URLRequest(url: std002))
        } else {
            failAsNeedsRelogin()
        }
    }

    private func attemptSilentRefreshAndRetry(_ reason: String) {
        guard !hasTriedSilentRefresh else {
            failAsNeedsRelogin()
            return
        }
        hasTriedSilentRefresh = true
        errorMessage = nil
        isPageReady = false
        print("[MoodleWeb] Silent refresh requested: \(reason)")

        loadingTask?.cancel()
        let generation = loadGeneration
        loadingTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let refreshed = await SSOSessionService.shared.requestRefresh()
            guard !Task.isCancelled, let self, generation == self.loadGeneration else { return }
            if refreshed, let target = self.originalTargetURL {
                print("[MoodleWeb] Silent refresh success, retry target")
                SSOEUNISettings.shared.clear()
                self.phase = .idle
                self.hasStarted = false
                self.retriedAfterLoginRedirect = false
                self.targetURL = nil
                self.externalOpenURL = nil
                self.loadWithSSO(targetURL: target)
            } else {
                print("[MoodleWeb] Silent refresh failed")
                self.failAsNeedsRelogin()
            }
        }
    }

    private func fallbackToTargetAfterSSOFailure() {
        if isAssignmentUploadTarget {
            failAsNeedsRelogin()
            return
        }
        phase = .done
        isPageReady = false
        loadCurrentTarget()
    }

    /// Sync HTTPCookieStorage cookies into WKWebView's cookie store
    private func syncCookies(completion: @escaping () -> Void) {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        guard !cookies.isEmpty else {
            completion()
            return
        }
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            cookieStore.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { completion() }
    }


    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        attendanceNavigationGeneration &+= 1
        webView.isUserInteractionEnabled = true
        attendanceCaptchaTask?.cancel()
        attendanceCaptchaTask = nil
        attendanceLoginPageGeneration = nil
    }

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        guard hasStarted, wv === storedWebView else { return }
        // A later school redirect must not replace a result or resubmit its QR.
        guard !isAttendanceQRTarget || attendanceOutcome?.isTerminal != true else { return }
        let url = wv.url?.absoluteString ?? ""
        if isAttendanceQRTarget {
            // QR pass and login fields must not appear in diagnostics.
            print("[MoodleWeb] didFinish (\(phase)): \(wv.url?.path ?? "")")
        } else {
            print("[MoodleWeb] didFinish (\(phase)): \(URL(string: url)?.path ?? "")")
        }

        if isAttendanceQRTarget, isLoginPage(url) {
            handleAttendanceLoginPage(wv)
            return
        }
        if isQuestionActivityTarget, isLoginPage(url) {
            // Keep an initial SSO handoff pending so a login that returns to
            // Moodle's home page still opens the selected activity once.
            if phase == .resolvingEuni { phase = .ssoRedirect }
            if !attemptedQuestionLogin {
                recoverQuestionLogin()
            } else {
                showQuestionLogin()
            }
            return
        }
        if isQuestionActivityTarget {
            questionTimeoutTask?.cancel()
            questionTimeoutTask = nil
            questionNeedsWebInteraction = false
        }

        switch phase {
        case .resolvingEuni:
            if isSSOSessionExpiredPage(url) {
                if isAssignmentUploadTarget {
                    attemptSilentRefreshAndRetry("resolvingEuni/session-expired")
                } else {
                    // SSO not valid now; target may still be publicly reachable.
                    fallbackToTargetAfterSSOFailure()
                }
            } else if url.contains("Std002.aspx") {
                extractEUNIRedirectPath(from: wv)
            }

        case .ssoRedirect:
            if url.lowercased().contains("logout.aspx") {
                print("[MoodleWeb] Invalid SSO redirect (logout), clear cached EUNI path")
                SSOEUNISettings.shared.clear()
                fallbackToTargetAfterSSOFailure()
                return
            }
            if isSSOSessionExpiredPage(url) {
                if isAssignmentUploadTarget {
                    resolveEuniInSameWebViewForUpload(reason: "SSO redirect session expired")
                } else {
                    // JumpTo token/session expired; silently refresh SSO then retry.
                    print("[MoodleWeb] SSO redirect session expired, trigger silent refresh")
                    attemptSilentRefreshAndRetry("ssoRedirect/session-expired")
                }
                return
            }
            if url.contains("euni.niu.edu.tw") && !isLoginPage(url) {
                // Session established — now load the actual target
                print("[MoodleWeb] ✓ Session OK, loading target")
                phase = .loadingTarget
                loadCurrentTarget()
            } else if isLoginPage(url) {
                // SSO didn't work — load target anyway (user sees login page)
                print("[MoodleWeb] SSO failed, loading target directly")
                fallbackToTargetAfterSSOFailure()
            }
            // Otherwise intermediate SSO redirect — wait

        case .loadingTarget:
            if isLoginPage(url) {
                if isAssignmentUploadTarget {
                    resolveEuniInSameWebViewForUpload(reason: "Upload target hit login page")
                } else {
                    attemptSilentRefreshAndRetry("loadingTarget/login")
                }
            } else {
                finishLoading()
                if isAttendanceQRTarget {
                    inspectAttendancePage(wv)
                }
            }

        case .done:
            if isLoginPage(url) {
                if isAssignmentUploadTarget {
                    failAsNeedsRelogin()
                    return
                }
                if isAutologinSupported {
                    print("[MoodleWeb] Landed on login page, retry with autologin")
                    retryUsingAutologin()
                } else {
                    attemptSilentRefreshAndRetry("done/login/autologin-disabled")
                }
            } else {
                isPageReady = true
                if isAttendanceQRTarget {
                    inspectAttendancePage(wv)
                }
            }

        case .idle:
            break
        }
    }

    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isAttendanceQRTarget || attendanceOutcome?.isTerminal != true else { return }
        print("[MoodleWeb] didFail code=\((error as NSError).code)")
        if (error as NSError).code == NSURLErrorCancelled { return }
        if isAttendanceQRTarget {
            phase = .done
            isPageReady = false
            attendanceOutcome = MoodleAttendanceWebOutcome(
                kind: .failed,
                message: "無法取得 M 園區點名結果，請檢查網路後再試。",
                courseModuleID: nil
            )
            return
        }
        if phase == .ssoRedirect || phase == .resolvingEuni {
            if isAssignmentUploadTarget {
                failAsNeedsRelogin()
            } else {
                fallbackToTargetAfterSSOFailure()
            }
        } else if phase == .loadingTarget || phase == .done {
            failTargetLoad("M 園區內容載入失敗，請檢查網路後重新載入。")
        }
    }

    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isAttendanceQRTarget || attendanceOutcome?.isTerminal != true else { return }
        print("[MoodleWeb] provisional fail code=\((error as NSError).code)")
        if (error as NSError).code == NSURLErrorCancelled { return }
        if isAttendanceQRTarget {
            phase = .done
            isPageReady = false
            attendanceOutcome = MoodleAttendanceWebOutcome(
                kind: .failed,
                message: "無法連線至 M 園區，請檢查網路後再試。",
                courseModuleID: nil
            )
            return
        }
        if phase == .ssoRedirect || phase == .resolvingEuni {
            if isAssignmentUploadTarget {
                failAsNeedsRelogin()
            } else {
                fallbackToTargetAfterSSOFailure()
            }
        } else if phase == .loadingTarget || phase == .done {
            failTargetLoad("無法連線至 M 園區，請檢查網路後重新載入。")
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if isQuestionActivityTarget {
            questionUIDelegate.cancel()
            failTargetLoad("問答頁面已中斷，尚無法確認答案是否送出。請重新開啟活動並查看 M 園區的作答紀錄。")
            return
        }
        if isAttendanceQRTarget {
            // Reloading a submission may reuse an expired code or submit it again.
            guard attendanceOutcome?.isTerminal != true else { return }
            failTargetLoad("點名頁面已中斷，無法確認結果。請返回掃描最新的 QR Code。")
            return
        }
        guard webContentRecoveryAttempts < 1 else {
            failTargetLoad("M 園區頁面程序已中斷，請重新載入。")
            return
        }
        webContentRecoveryAttempts += 1
        errorMessage = nil
        isPageReady = false
        webView.reload()
    }
}

// MARK: - Persistent WebView wrapper (doesn't recreate the WKWebView)

private struct MoodlePersistentWebView: UIViewRepresentable {
    let manager: MoodleWebManager

    func makeUIView(context: Context) -> WKWebView {
        manager.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Token-authenticated file viewer

private struct TokenFileWebView: UIViewRepresentable {
    let targetURL: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        if let url = rewrittenURL() {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.stopLoading()
    }

    private func rewrittenURL() -> URL? {
        guard let token = MoodleService.shared.currentToken else {
            return URL(string: targetURL)
        }
        var rewritten = targetURL
        if rewritten.contains("/pluginfile.php") &&
           !rewritten.contains("/webservice/pluginfile.php") {
            rewritten = rewritten.replacingOccurrences(
                of: "/pluginfile.php",
                with: "/webservice/pluginfile.php"
            )
        }
        let sep = rewritten.contains("?") ? "&" : "?"
        rewritten += "\(sep)token=\(token)"
        return URL(string: rewritten)
    }
}
