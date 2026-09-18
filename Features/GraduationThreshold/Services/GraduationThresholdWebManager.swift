import SwiftUI
import WebKit
import Combine

// MARK: - Web Result

enum GraduationThresholdWebResult {
    case success(GraduationData)
    case sessionExpired
    case failure(String)
}

// MARK: - Web View Manager

@MainActor
final class GraduationThresholdWebManager: NSObject, ObservableObject {
    @Published var currentURL: String = ""
    @Published var isLoading = false

    var onResult: ((GraduationThresholdWebResult) -> Void)?

    private weak var webView: WKWebView?
    private var navigationStep = 0
    private var active = true
    private var cancelled = false
    private var bridgeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    private let getInfoJS = """
        (function() {
            // 隱藏按鈕
            document.querySelectorAll('input.btn').forEach(btn => btn.style.display = 'none');

            // 多元時數 (8 numbers)
            var diverseElement = document.getElementById('div_B');
            if (!diverseElement) return null;
            var diverseText = diverseElement.innerText;
            var diverseMatches = diverseText.match(/\\d+/g) || [];
            if (diverseMatches.length === 4) {
                diverseMatches = [
                    diverseMatches[0], "不計入",
                    diverseMatches[1], "不計入",
                    diverseMatches[2], "不計入",
                    diverseMatches[3], "不計入"
                ];
            }

            // 英文門檻
            var engSpan = document.querySelector('span[ml="PL_外語能力"]');
            var englishAbility = engSpan ? engSpan.closest('tr').querySelector('div').innerText : '';

            // 體適能
            var phySpan = document.querySelector('span[ml="PL_體適能"]');
            var physicalFitness = phySpan ? phySpan.closest('tr').querySelector('div').innerText : '';

            // 畢業最低學分數
            var rows = document.querySelectorAll('tr.tdWhite');
            var creditRequired = [];
            rows.forEach(r => {
                if (r.cells[0] && r.cells[0].innerText.trim() === '畢業最低學分數') {
                    creditRequired.push(r.cells[1].innerText.trim());
                    creditRequired.push(r.cells[2].innerText.trim());
                }
            });

            // 學分學程
            var creditCourse = document.getElementById('CRS_PROG');
            var creditCourseStr = creditCourse ? creditCourse.innerText : '';

            return JSON.stringify({
                diverseHours: diverseMatches,
                englishAbility: englishAbility,
                physicalFitness: physicalFitness,
                creditRequired: creditRequired,
                creditCourse: creditCourseStr
            });
        })();
    """

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .default()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        self.webView = wv

        loadInitialPage()
        return wv
    }

    private func loadInitialPage() {
        isLoading = true
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(40)) } catch { return }
            self?.finish(.failure("畢業門檻載入逾時，請檢查網路後重試"))
        }
        // A modern SSO login alone does not establish the legacy acade cookie.
        // Exchange a fresh GUID on every attempt, including after re-login.
        bridgeTask = Task { [weak self] in
            let account = SSOTokenStore.shared.account
                ?? LoginRepository.shared.getSavedCredentials()?.username
                ?? ""
            let guid = account.isEmpty ? nil : await SSOGUIDBridge.fetchGUID(account: account)
            guard !Task.isCancelled, let self, self.active else { return }
            guard let guid, let url = SSOGUIDBridge.acadeLoginURL(guid: guid) else {
                self.finish(.sessionExpired)
                return
            }
            self.webView?.load(URLRequest(url: url))
        }
    }

    func cancel() {
        cancelled = true
        active = false
        bridgeTask?.cancel()
        timeoutTask?.cancel()
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        onResult = nil
    }

    private func finish(_ result: GraduationThresholdWebResult) {
        guard active else { return }
        active = false
        isLoading = false
        bridgeTask?.cancel()
        timeoutTask?.cancel()
        webView?.stopLoading()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.onResult?(result)
        }
    }

    private func extractData() {
        webView?.evaluateJavaScript(getInfoJS) { [weak self] result, error in
            guard let self, self.active else { return }

            if let error = error {
                print("[GraduationThreshold] JS error code=\((error as NSError).code)")
                self.finish(.failure("資料擷取失敗，請稍後重試"))
                return
            }

            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8) else {
                self.finish(.failure("找不到畢業門檻資料，請稍後重試"))
                return
            }

            let decoder = JSONDecoder()
            if let obj = try? decoder.decode(GraduationData.self, from: data) {
                self.finish(.success(obj))
            } else {
                self.finish(.failure("資料解析失敗，請稍後重試"))
            }
        }
    }
}

extension GraduationThresholdWebManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard active, let url = webView.url else { return }
        isLoading = false
        // Never log the one-shot GUID from the login URL.
        currentURL = "\(url.host ?? "")\(url.path)"
        print("[GraduationThreshold] Loaded: \(currentURL)")

        // Detect session expired - redirect to login page
        if SSOGUIDBridge.isSessionExpiredURL(url) {
            print("[GraduationThreshold] Session expired, redirecting to login")
            finish(.sessionExpired)
            return
        }

        // Handle Std002.aspx - redirect to MainFrame
        if url.path.lowercased().hasSuffix("/std002.aspx") {
            print("[GraduationThreshold] Std002.aspx reached, navigating to MainFrame...")
            if let url = URL(string: "https://acade.niu.edu.tw/NIU/MainFrame.aspx") {
                webView.load(URLRequest(url: url))
                isLoading = true
            }
            return
        }

        guard url.host?.lowercased() == "acade.niu.edu.tw" else { return }
        switch url.path.lowercased() {
        case "/niu/mainframe.aspx" where navigationStep == 0:
            navigationStep = 1
            var request = URLRequest(url: URL(string: "https://acade.niu.edu.tw/NIU/Application/ENR/ENRG0/ENRG010_01.aspx")!)
            request.setValue("https://acade.niu.edu.tw/NIU/Application/ENR/ENRG0/ENRG010_03.aspx", forHTTPHeaderField: "Referer")
            webView.load(request)
            isLoading = true

        case "/niu/application/enr/enrg0/enrg010_01.aspx" where navigationStep < 2:
            navigationStep = 2
            extractData()

        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard active else { return }
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    private func handleNavigationError(_ error: Error) {
        let error = error as NSError
        guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
        finish(.failure("畢業門檻連線失敗，請檢查網路後重試"))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure("畢業門檻網頁已中斷，請重試"))
    }
}

// MARK: - WebView Representable

struct GraduationThresholdWebView: UIViewRepresentable {
    let onResult: (GraduationThresholdWebResult) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let manager = context.coordinator
        manager.onResult = onResult
        return manager.makeWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: GraduationThresholdWebManager) {
        coordinator.cancel()
    }

    func makeCoordinator() -> GraduationThresholdWebManager {
        GraduationThresholdWebManager()
    }
}
