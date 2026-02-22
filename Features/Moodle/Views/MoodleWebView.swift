import Combine
import SwiftUI
import WebKit

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
            webManager.loadWithSSO(targetURL: targetURL)
        }
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

    let webView: WKWebView
    private var targetURL: String?
    private var originalTargetURL: String?
    private var phase: Phase = .idle
    private var hasStarted = false
    private var retriedAfterLoginRedirect = false
    private var isAutologinSupported = true
    private var hasTriedSilentRefresh = false
    private var assignmentResolveAttempts = 0
    private let maxAssignmentResolveAttempts = 2

    private enum Phase {
        case idle
        case resolvingEuni // Loading Std002.aspx to find EUNI redirect path
        case ssoRedirect   // Loading SSO EUNI redirect URL
        case loadingTarget // Session established, loading target
        case done
    }

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func loadWithSSO(targetURL: String) {
        guard !hasStarted else { return }
        hasStarted = true
        self.originalTargetURL = targetURL
        self.errorMessage = nil
        self.assignmentResolveAttempts = 0

        Task {
            let resolved = await resolveTargetURL(from: targetURL)
            targetURLReady(resolved)
        }
    }

    private var isAssignmentUploadTarget: Bool {
        let target = (originalTargetURL ?? targetURL ?? "").lowercased()
        return target.contains("/mod/assign/view.php") && target.contains("action=editsubmission")
    }
    
    private func targetURLReady(_ resolvedTarget: URL) {
        self.targetURL = resolvedTarget.absoluteString
        self.externalOpenURL = resolvedTarget
        
        // Sync cookies from HTTPCookieStorage to WKWebView (like reference project)
        syncCookies {
            if !self.isAssignmentUploadTarget,
               let euniURL = SSOEUNISettings.shared.euniFullURL,
               let url = URL(string: euniURL) {
                // Step 1: Load SSO EUNI redirect to establish Moodle session
                print("[MoodleWeb] SSO redirect: \(euniURL.prefix(80))")
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

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            let rawJSON = (result as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var resolved = ""

            if let data = rawJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                resolved = (obj["match"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let candidatesCount = obj["candidatesCount"] as? Int ?? 0
                let bodyLen = obj["bodyLen"] as? Int ?? 0

                if resolved.isEmpty && attempt < 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
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
            print("[MoodleWeb] Resolved EUNI link: \(full.prefix(80))")
            self.phase = .ssoRedirect
            self.webView.load(URLRequest(url: url))
        }
    }
    
    private func retryUsingAutologin() {
        guard !retriedAfterLoginRedirect, let originalTargetURL else { return }
        retriedAfterLoginRedirect = true
        Task {
            let resolved = await resolveTargetURL(from: originalTargetURL)
            self.targetURL = resolved.absoluteString
            self.externalOpenURL = resolved
            self.phase = .loadingTarget
            self.webView.load(URLRequest(url: resolved))
        }
    }

    private func isLoginPage(_ urlString: String) -> Bool {
        urlString.contains("euni.niu.edu.tw") && urlString.contains("/login")
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

    private func failAsNeedsRelogin() {
        phase = .done
        isPageReady = false
        errorMessage = "M 園區登入已失效，請回設定頁重新登入後再試。"
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

        Task {
            let refreshed = await SSOSessionService.shared.requestRefresh()
            if refreshed, let target = originalTargetURL {
                print("[MoodleWeb] Silent refresh success, retry target")
                SSOEUNISettings.shared.clear()
                phase = .idle
                hasStarted = false
                retriedAfterLoginRedirect = false
                targetURL = nil
                externalOpenURL = nil
                loadWithSSO(targetURL: target)
            } else {
                print("[MoodleWeb] Silent refresh failed")
                failAsNeedsRelogin()
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

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        let url = wv.url?.absoluteString ?? ""
        print("[MoodleWeb] didFinish (\(phase)): \(url.prefix(100))")

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
            }

        case .idle:
            break
        }
    }

    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[MoodleWeb] didFail: \(error.localizedDescription)")
        if phase == .ssoRedirect || phase == .resolvingEuni {
            if isAssignmentUploadTarget {
                failAsNeedsRelogin()
            } else {
                fallbackToTargetAfterSSOFailure()
            }
        }
    }

    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[MoodleWeb] provisional fail: \(error.localizedDescription)")
        if phase == .ssoRedirect || phase == .resolvingEuni {
            if isAssignmentUploadTarget {
                failAsNeedsRelogin()
            } else {
                fallbackToTargetAfterSSOFailure()
            }
        }
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
