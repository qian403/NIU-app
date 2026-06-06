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

final class GraduationThresholdWebManager: NSObject, ObservableObject {
    @Published var currentURL: String = ""
    @Published var isLoading = false

    var onResult: ((GraduationThresholdWebResult) -> Void)?

    private var webView: WKWebView?
    private var navigationStep = 0

    private let getInfoJS = """
        (function() {
            // 隱藏按鈕
            document.querySelectorAll('input.btn').forEach(btn => btn.style.display = 'none');

            // 多元時數 (8 numbers)
            var diverseText = document.getElementById('div_B').innerText;
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
        // Direct URL to academic system main frame
        guard let url = URL(string: "https://acade.niu.edu.tw/NIU/MainFrame.aspx") else { return }
        webView?.load(URLRequest(url: url))
        isLoading = true
    }

    private func extractData() {
        webView?.evaluateJavaScript(getInfoJS) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                print("[GraduationThreshold] JS error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onResult?(.failure("資料擷取失敗，請稍後重試"))
                }
                return
            }

            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8) else {
                DispatchQueue.main.async {
                    self.onResult?(.failure("資料格式異常，請稍後重試"))
                }
                return
            }

            let decoder = JSONDecoder()
            if let obj = try? decoder.decode(GraduationData.self, from: data) {
                DispatchQueue.main.async {
                    self.onResult?(.success(obj))
                }
            } else {
                DispatchQueue.main.async {
                    self.onResult?(.failure("資料解析失敗，請稍後重試"))
                }
            }
        }
    }
}

extension GraduationThresholdWebManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url?.absoluteString ?? ""
        print("[GraduationThreshold] Loaded: \(currentURL)")

        // Detect session expired - redirect to login page
        if currentURL.contains("/Account/Login") ||
           currentURL.contains("Default.aspx") {
            print("[GraduationThreshold] Session expired, redirecting to login")
            DispatchQueue.main.async {
                self.onResult?(.sessionExpired)
            }
            return
        }

        // Handle Std002.aspx - redirect to MainFrame
        if currentURL.contains("Std002.aspx") {
            print("[GraduationThreshold] Std002.aspx reached, navigating to MainFrame...")
            if let url = URL(string: "https://acade.niu.edu.tw/NIU/MainFrame.aspx") {
                webView.load(URLRequest(url: url))
                isLoading = true
            }
            return
        }

        switch currentURL {
        case "https://acade.niu.edu.tw/NIU/MainFrame.aspx":
            navigationStep = 1
            var request = URLRequest(url: URL(string: "https://acade.niu.edu.tw/NIU/Application/ENR/ENRG0/ENRG010_01.aspx")!)
            request.setValue("https://acade.niu.edu.tw/NIU/Application/ENR/ENRG0/ENRG010_03.aspx", forHTTPHeaderField: "Referer")
            webView.load(request)
            isLoading = true

        case "https://acade.niu.edu.tw/NIU/Application/ENR/ENRG0/ENRG010_01.aspx":
            navigationStep = 2
            extractData()

        default:
            // After Std002.aspx, SSO should redirect to MainFrame
            // If we got Std002.aspx but no further redirect, check if session expired
            if navigationStep == 0 && currentURL.contains("Std002.aspx") {
                print("[GraduationThreshold] Std002.aspx reached, waiting for redirect...")
            }
            break
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        print("[GraduationThreshold] Load error: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        print("[GraduationThreshold] Provisional load error: \(error.localizedDescription)")
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

    func makeCoordinator() -> GraduationThresholdWebManager {
        GraduationThresholdWebManager()
    }
}
