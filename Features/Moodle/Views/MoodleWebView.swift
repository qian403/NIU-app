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
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                        Spacer()
                    }
                }

                if let message = webManager.errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(.secondary)
                        Text(message)
                            .font(.system(size: 13))
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
                                .font(.system(size: 16))
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
        webView.allowsBackForwardNavigationGestures = true
        storedWebView = webView
        return webView
    }
    private var targetURL: String?
    private var originalTargetURL: String?
    private var phase: Phase = .idle
    private var hasStarted = false
    private var loadingTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var retriedAfterLoginRedirect = false
    private var isAutologinSupported = true
    private var hasTriedSilentRefresh = false
    private var webContentRecoveryAttempts = 0
    private var assignmentResolveAttempts = 0
    private var attendanceNavigationGeneration = 0
    private var attendanceLoginAttempts = 0
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
        self.errorMessage = nil
        self.attendanceOutcome = nil
        self.assignmentResolveAttempts = 0
        self.attendanceLoginAttempts = 0

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
        loadingTask?.cancel()
        loadingTask = nil
        storedWebView?.stopLoading()
        storedWebView?.navigationDelegate = nil
        hasStarted = false
        phase = .idle
        retriedAfterLoginRedirect = false
        hasTriedSilentRefresh = false
        webContentRecoveryAttempts = 0
        attendanceLoginAttempts = 0
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

    private var isIRSActivityTarget: Bool {
        guard let originalTargetURL,
              let components = URLComponents(string: originalTargetURL) else { return false }
        return components.host?.lowercased() == "euni.niu.edu.tw"
            && components.path.lowercased() == "/mod/irs/view.php"
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
            // IRS is a browser-only activity. If mobile autologin is available,
            // use it immediately instead of taking an unnecessary SSO round trip.
            if self.isIRSActivityTarget,
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

    private struct AttendanceCaptchaPayload: Decodable {
        let hasInput: Bool
        let hasImage: Bool
        let dataURL: String?
        let complete: Bool
        let width: Int
    }

    private func handleAttendanceLoginPage(_ webView: WKWebView) {
        guard attendanceLoginAttempts < maxAttendanceLoginAttempts,
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
        captureAttendanceCaptcha(
            webView,
            attempt: 1,
            refreshImage: attempt > 1,
            generation: generation,
            navigationGeneration: navigationGeneration
        ) { [weak self, weak webView] payload, image in
            guard let self, let webView, self.hasStarted,
                  generation == self.loadGeneration,
                  navigationGeneration == self.attendanceNavigationGeneration,
                  webView === self.storedWebView else { return }

            let hasCaptcha = payload?.hasInput == true || payload?.hasImage == true
            if hasCaptcha {
                guard let image else {
                    self.retryAttendanceLoginPage(
                        webView,
                        generation: generation,
                        navigationGeneration: navigationGeneration
                    )
                    return
                }
                SSOCaptchaProcessor.shared.recognize(from: image, expectedLength: 5) { [weak self, weak webView] code in
                    guard let self, let webView, self.hasStarted,
                          generation == self.loadGeneration,
                          navigationGeneration == self.attendanceNavigationGeneration,
                          webView === self.storedWebView else { return }
                    guard let code, code.count == 5 else {
                        self.retryAttendanceLoginPage(
                            webView,
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
                    generation: generation,
                    navigationGeneration: navigationGeneration
                )
            } else {
                self.showAttendanceLoginPage()
            }
        }
    }

    private func retryAttendanceLoginPage(
        _ webView: WKWebView,
        generation: Int,
        navigationGeneration: Int
    ) {
        guard generation == loadGeneration,
              navigationGeneration == attendanceNavigationGeneration,
              webView === storedWebView,
              attendanceLoginAttempts < maxAttendanceLoginAttempts
        else {
            showAttendanceLoginPage()
            return
        }
        print("[MoodleAttendance] retrying M campus login captcha")
        webView.reload()
    }

    private func captureAttendanceCaptcha(
        _ webView: WKWebView,
        attempt: Int,
        refreshImage: Bool,
        generation: Int,
        navigationGeneration: Int,
        completion: @escaping (AttendanceCaptchaPayload?, CaptchaImage?) -> Void
    ) {
        let script = """
        (function() {
            var input = document.querySelector('#captcha, input[name="captcha"]');
            var image = document.querySelector('#imgcode, img[src*="/auth/posbosscaptcha/captcha.php"]');
            var didRefresh = false;
            if (\(refreshImage ? "true" : "false") && image) {
                var source = image.getAttribute('src') || '';
                if (source) {
                    image.setAttribute('src', source + (source.indexOf('?') >= 0 ? '&' : '?') + 't=' + Date.now());
                    didRefresh = true;
                }
            }
            var payload = {
                hasInput: !!input,
                hasImage: !!image,
                dataURL: null,
                complete: !didRefresh && !!(image && image.complete),
                width: image ? (image.naturalWidth || 0) : 0
            };
            if (didRefresh || !image || !image.complete || !image.naturalWidth) {
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
            guard let self, let webView, self.hasStarted,
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

            if let dataURL = payload.dataURL,
               let image = self.decodeCaptchaDataURL(dataURL) {
                completion(payload, image)
                return
            }

            let needsPolling = payload.hasInput || payload.hasImage
            if needsPolling && attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak webView] in
                    guard let self, let webView,
                          generation == self.loadGeneration,
                          navigationGeneration == self.attendanceNavigationGeneration else { return }
                    self.captureAttendanceCaptcha(
                        webView,
                        attempt: attempt + 1,
                        refreshImage: false,
                        generation: generation,
                        navigationGeneration: navigationGeneration,
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
        generation: Int,
        navigationGeneration: Int
    ) {
        let captchaLiteral = captcha.flatMap(javascriptLiteral) ?? "null"
        let script = """
        (function(username, password, captcha) {
            var form = document.querySelector('form[action*="login/index.php"]')
                || document.querySelector('form#login');
            var usernameInput = document.querySelector('input[name="username"], input#username');
            var passwordInput = document.querySelector('input[name="password"], input#password');
            var captchaInput = document.querySelector('#captcha, input[name="captcha"]');
            if (!form || !usernameInput || !passwordInput || (captchaInput && !captcha)) return 'missing-form';

            function setValue(input, value) {
                input.focus();
                input.value = value;
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
            }
            setValue(usernameInput, username);
            setValue(passwordInput, password);
            if (captchaInput && captcha) setValue(captchaInput, captcha);

            var submit = form.querySelector('button[type="submit"], input[type="submit"]');
            if (form.requestSubmit) {
                submit ? form.requestSubmit(submit) : form.requestSubmit();
            } else if (submit) {
                submit.click();
            } else {
                form.submit();
            }
            return 'submitted';
        })(\(username), \(password), \(captchaLiteral));
        """

        webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
            guard let self, let webView, self.hasStarted,
                  generation == self.loadGeneration,
                  navigationGeneration == self.attendanceNavigationGeneration,
                  webView === self.storedWebView else { return }
            if result as? String == "submitted" {
                print("[MoodleAttendance] submitted M campus web login")
                self.checkAttendanceLoginSubmission(
                    webView,
                    generation: generation,
                    navigationGeneration: navigationGeneration
                )
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
        phase = .loadingTarget
        isPageReady = true
        attendanceOutcome = MoodleAttendanceWebOutcome(
            kind: .requiresAction,
            message: "請在 M 園區登入頁完成登入或輸入驗證碼；成功後會自動回到這次點名網址。",
            courseModuleID: nil
        )
    }

    private func isSSODefaultPage(_ urlString: String) -> Bool {
        urlString.contains("ccsys.niu.edu.tw/SSO/Default.aspx")
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
            var notifications = Array.prototype.map.call(nodes, function(node) {
                return {
                    text: (node.innerText || node.textContent || '').trim(),
                    className: node.className || '',
                    type: node.getAttribute('data-type') || node.getAttribute('role') || ''
                };
            }).filter(function(item) { return item.text.length > 0; });

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

        switch phase {
        case .resolvingEuni:
            if url.contains("Default.aspx") {
                if isAssignmentUploadTarget {
                    attemptSilentRefreshAndRetry("resolvingEuni/default")
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
            if isSSODefaultPage(url) {
                if isAssignmentUploadTarget {
                    resolveEuniInSameWebViewForUpload(reason: "SSO redirect landed on Default.aspx")
                } else {
                    // JumpTo token/session expired; silently refresh SSO then retry.
                    print("[MoodleWeb] SSO redirect landed on Default.aspx, trigger silent refresh")
                    attemptSilentRefreshAndRetry("ssoRedirect/default")
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
