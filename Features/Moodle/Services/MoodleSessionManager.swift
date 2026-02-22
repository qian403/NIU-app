import Combine
import SwiftUI
import WebKit

/// Stores the SSO redirect URL for EUNI (Moodle).
final class SSOEUNISettings {
    static let shared = SSOEUNISettings()
    private let defaults = UserDefaults(suiteName: "SSOID") ?? .standard

    var euniRedirectPath: String {
        get { defaults.string(forKey: "EUNI") ?? "" }
        set { defaults.set(newValue, forKey: "EUNI") }
    }

    var euniFullURL: String? {
        let path = euniRedirectPath
        guard !path.isEmpty, Self.isLikelyValidEUNIPath(path) else { return nil }
        if path.hasPrefix("http") { return path }
        return "https://ccsys.niu.edu.tw/SSO/" + path
    }

    static func isLikelyValidEUNIPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.isEmpty { return false }
        if lower.contains("logout.aspx") { return false }
        if lower.hasPrefix("javascript:") { return false }
        if lower == "#" { return false }
        return true
    }

    func clear() {
        defaults.removeObject(forKey: "EUNI")
    }
}

/// Extracts the EUNI redirect link from Std002.aspx after SSO login.
@MainActor
final class MoodleSessionManager: ObservableObject {
    static let shared = MoodleSessionManager()

    @Published private(set) var isReady = false
    @Published private(set) var isWorking = false

    private var hiddenWebView: WKWebView?
    private var coordinator: SSOIDCoordinator?
    private var didFail = false

    private init() {
        if SSOEUNISettings.shared.euniFullURL != nil {
            isReady = true
        }
    }

    func fetchEUNILink() {
        guard !isReady && !isWorking else { return }
        isWorking = true

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 500),
                           configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        let coord = SSOIDCoordinator { [weak self] euniPath in
            guard let self else { return }
            self.isWorking = false
            if let path = euniPath, SSOEUNISettings.isLikelyValidEUNIPath(path) {
                SSOEUNISettings.shared.euniRedirectPath = path
                self.isReady = true
                self.didFail = false
                print("[MoodleSession] ✓ Got EUNI path: \(path)")
            } else {
                self.didFail = true
                print("[MoodleSession] ✗ Failed to get EUNI path")
            }
            self.hiddenWebView = nil
            self.coordinator = nil
        }

        wv.navigationDelegate = coord
        self.hiddenWebView = wv
        self.coordinator = coord

        if let url = URL(string: "https://ccsys.niu.edu.tw/SSO/Std002.aspx") {
            print("[MoodleSession] Loading Std002.aspx to extract EUNI link")
            wv.load(URLRequest(url: url))
        }
    }

    func reset() {
        isReady = false
        isWorking = false
        didFail = false
        SSOEUNISettings.shared.clear()
        hiddenWebView = nil
        coordinator = nil
    }
}

// MARK: - Coordinator

private class SSOIDCoordinator: NSObject, WKNavigationDelegate {
    private let completion: (String?) -> Void
    private var isDone = false
    private var timeoutWork: DispatchWorkItem?

    init(completion: @escaping (String?) -> Void) {
        self.completion = completion
        super.init()
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        print("[MoodleSession] didFinish: \(url.prefix(80))")

        if url.contains("Std002.aspx") {
            extractEUNILink(from: webView, attempt: 0)
        } else if url.contains("Default.aspx") {
            print("[MoodleSession] SSO expired (redirected to Default.aspx)")
            finish(nil)
        }
    }

    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func extractEUNILink(from webView: WKWebView, attempt: Int) {
        let js = """
        (function() {
            var found = [];
            var idOrder = [12,11,10,9,8,7,6,5,4,3,2,1,0];
            for (var p = 0; p < idOrder.length; p++) {
                var k = idOrder[p];
                var id = 'ctl00_ContentPlaceHolder1_RadListView1_ctrl' + k + '_HyperLink1';
                var el = document.getElementById(id);
                if (el) {
                    var href = el.getAttribute('href') || '';
                    var text = (el.textContent || '').trim();
                    found.push({i: k, href: href.substring(0, 120), text: text.substring(0, 40)});
                    if (href.toLowerCase().indexOf('euni') !== -1 ||
                        href.toLowerCase().indexOf('jumpto') !== -1 ||
                        text.indexOf('euni') !== -1 ||
                        text.indexOf('M園區') !== -1 ||
                        text.indexOf('Moodle') !== -1 ||
                        text.indexOf('數位學習') !== -1) {
                        return JSON.stringify({match: href, all: found});
                    }
                }
            }
            var allLinks = [];
            var links = document.querySelectorAll('a[href]');
            for (var i = 0; i < links.length; i++) {
                var h = (links[i].getAttribute('href') || '');
                var t = (links[i].textContent || '').trim();
                allLinks.push({href: h.substring(0, 120), text: t.substring(0, 40)});
                if (h.toLowerCase().indexOf('euni') !== -1 ||
                    h.toLowerCase().indexOf('jumpto') !== -1 ||
                    t.indexOf('M園區') !== -1 ||
                    t.indexOf('Moodle') !== -1 ||
                    t.indexOf('數位學習') !== -1) {
                    return JSON.stringify({match: h, all: found, allLinks: allLinks});
                }
            }
            return JSON.stringify({
                match: null,
                radListItems: found,
                linkCount: allLinks.length,
                bodyLen: (document.body && document.body.innerText ? document.body.innerText.length : 0)
            });
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, !self.isDone else { return }

            if let jsonStr = result as? String,
               let data = jsonStr.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                if let match = obj["match"] as? String, !match.isEmpty {
                    print("[MoodleSession] Found EUNI: \(match)")
                    self.finish(match)
                } else {
                    if attempt < 8 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            self.extractEUNILink(from: webView, attempt: attempt + 1)
                        }
                    } else {
                        print("[MoodleSession] No EUNI found. Debug: \(jsonStr.prefix(500))")
                        self.finish(nil)
                    }
                }
            } else {
                print("[MoodleSession] JS returned: \(String(describing: result))")
                self.finish(nil)
            }
        }
    }

    private func finish(_ result: String?) {
        guard !isDone else { return }
        isDone = true
        timeoutWork?.cancel()
        timeoutWork = nil
        DispatchQueue.main.async { self.completion(result) }
    }
}
