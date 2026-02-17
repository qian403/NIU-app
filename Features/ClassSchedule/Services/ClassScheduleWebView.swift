import SwiftUI
import WebKit

// MARK: - Result type

enum ClassScheduleWebResult {
    case success([[String]])   // 2-D array of table cell texts
    case notAvailable(String)  // Portal message (e.g. "不開放查詢時間")
    case sessionExpired        // SSO session has expired
    case failure(String)       // Other errors
}

// MARK: - UIViewRepresentable wrapper

/// An invisible WKWebView that navigates SSO → academic system → schedule page,
/// extracts the schedule table and returns rows via `onResult`.
struct ClassScheduleWebView: UIViewRepresentable {

    let onResult: (ClassScheduleWebResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // share cookies with SSO login
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        // Desktop user-agent so the academic portal renders correctly
        wv.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/17.0 Safari/605.1.15"

        context.coordinator.webView = wv

        // Kick off the flow
        if let url = URL(string: "https://ccsys.niu.edu.tw/SSO/Std002.aspx") {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {

        let onResult: (ClassScheduleWebResult) -> Void
        weak var webView: WKWebView?

        private var step: Step = .getAcadeMain
        private var active = true   // set false after we call onResult once

        private enum Step {
            case getAcadeMain
            case waitForMainFrame
            case waitForSchedulePage
            case waitForTable
        }

        init(onResult: @escaping (ClassScheduleWebResult) -> Void) {
            self.onResult = onResult
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard active else { return }
            let url = webView.url?.absoluteString ?? ""

            // Detect expired session → redirected back to login
            if url.contains("Default.aspx") && step != .getAcadeMain {
                finish(.sessionExpired)
                return
            }

            switch step {
            case .getAcadeMain:
                // We're on Std002 or were redirected to Default (not logged in)
                if url.contains("Default.aspx") {
                    finish(.sessionExpired)
                } else {
                    extractAcadeMainAndNavigate(webView: webView)
                }

            case .waitForMainFrame:
                if url.contains("MainFrame.aspx") {
                    step = .waitForSchedulePage
                    navigateToSchedulePage(webView: webView)
                }
                // Some SSO chains land directly on schedule page
                if url.contains("TKE2240_01.aspx") {
                    step = .waitForTable
                    clickQueryAndPoll(webView: webView)
                }

            case .waitForSchedulePage:
                if url.contains("TKE2240_01.aspx") {
                    step = .waitForTable
                    clickQueryAndPoll(webView: webView)
                }

            case .waitForTable:
                break   // handled by polling
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard active else { return }
            finish(.failure("網路連線失敗：\(error.localizedDescription)"))
        }

        // MARK: WKUIDelegate – JS alerts

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            completionHandler()
            guard active else { return }
            if message.contains("不開放") {
                finish(.notAvailable(message))
            }
        }

        // MARK: - Navigation helpers

        private func extractAcadeMainAndNavigate(webView: WKWebView) {
            let js = """
            (function() {
                var el = document.getElementById(
                    'ctl00_ContentPlaceHolder1_RadListView1_ctrl0_HyperLink1');
                return el ? el.getAttribute('href') : null;
            })()
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self, self.active else { return }

                guard let href = result as? String, !href.isEmpty else {
                    // The expected link element is absent. This most commonly
                    // means the SSO session is in a borderline-expired state:
                    // the portal served Std002 without redirecting to Default.aspx,
                    // but the page content isn't showing the logged-in view.
                    // Treat it as session expiry so the ViewModel can silently
                    // re-authenticate and retry.
                    self.finish(.sessionExpired)
                    return
                }

                let base = "https://ccsys.niu.edu.tw/SSO/"
                let fullURL: String
                if href.hasPrefix("http") {
                    fullURL = href
                } else {
                    let clean = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
                    fullURL = base + clean
                }

                guard let url = URL(string: fullURL) else {
                    self.finish(.failure("無效的 SSO 連結"))
                    return
                }

                self.step = .waitForMainFrame
                DispatchQueue.main.async {
                    webView.load(URLRequest(url: url))
                }
            }
        }

        private func navigateToSchedulePage(webView: WKWebView) {
            guard let url = URL(string:
                "https://acade.niu.edu.tw/NIU/Application/TKE/TKE22/TKE2240_01.aspx")
            else { return }

            var req = URLRequest(url: url)
            req.setValue(
                "https://acade.niu.edu.tw/NIU/Application/TKE/TKE22/TKE2240_01.aspx",
                forHTTPHeaderField: "Referer")
            webView.load(req)
        }

        private func clickQueryAndPoll(webView: WKWebView) {
            webView.evaluateJavaScript(
                "document.querySelector('input#QUERY_BTN3')?.click();"
            ) { [weak self] _, _ in
                self?.pollForTable(webView: webView, attempt: 0)
            }
        }

        // Poll every 300 ms, up to 100 times (~30 s)
        private func pollForTable(webView: WKWebView, attempt: Int) {
            guard active else { return }
            guard attempt < 100 else {
                finish(.failure("課表載入逾時，請稍後再試"))
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak webView] in
                guard let self = self, let webView = webView, self.active else { return }

                let js = """
                (function() {
                    var t = document.getElementById('table2');
                    if (!t) return null;
                    var txt = t.innerText || '';
                    if (!txt.includes('星期')) return null;
                    var rows = [];
                    t.querySelectorAll('tr').forEach(function(row) {
                        var cells = [];
                        row.querySelectorAll('td, th').forEach(function(cell) {
                            cells.push(cell.innerText.trim());
                        });
                        rows.push(cells);
                    });
                    return JSON.stringify(rows);
                })()
                """

                webView.evaluateJavaScript(js) { [weak self] result, _ in
                    guard let self = self, self.active else { return }

                    if let jsonStr = result as? String, !jsonStr.isEmpty,
                       let data = jsonStr.data(using: .utf8),
                       let rows = try? JSONSerialization.jsonObject(with: data) as? [[String]] {
                        self.finish(.success(rows))
                    } else {
                        self.pollForTable(webView: webView, attempt: attempt + 1)
                    }
                }
            }
        }

        // MARK: - Finish

        private func finish(_ result: ClassScheduleWebResult) {
            guard active else { return }
            active = false
            DispatchQueue.main.async {
                self.onResult(result)
            }
        }
    }
}
