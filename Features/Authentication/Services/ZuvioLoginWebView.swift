import SwiftUI
import WebKit

#if os(macOS)
public typealias ZuvioViewRepresentable = NSViewRepresentable
#else
public typealias ZuvioViewRepresentable = UIViewRepresentable
#endif

private func formURLEncodedData(_ params: [String: String]) -> Data? {
    var comps = URLComponents()
    comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
    return comps.percentEncodedQuery?.data(using: .utf8)
}

struct ZuvioLoginWebView: ZuvioViewRepresentable {
    let account: String
    let password: String
    let onResult: (Bool) -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(account: account, password: password, onResult: onResult)
    }
    
    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        return createWebView(context: context)
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    #else
    func makeUIView(context: Context) -> WKWebView {
        return createWebView(context: context)
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    #endif
    
    private func createWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .default()
                
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        
        // 先訪問登入頁面，等頁面載入後再提交
        let loginPageURL = URL(string: "https://irs.zuvio.com.tw/irs/login/zh-TW")!
        webView.load(URLRequest(url: loginPageURL))
        
        return webView
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let account: String
        let password: String
        let onResult: (Bool) -> Void
        private var hasReported = false
        private var hasSentLogin = false
        private var startTime: Date?
        private var timeoutTimer: Timer?
        
        init(account: String, password: String, onResult: @escaping (Bool) -> Void) {
            self.account = account
            self.password = password
            self.onResult = onResult
        }
        
        deinit {
            timeoutTimer?.invalidate()
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasReported else { return }
            
            if startTime == nil {
                startTime = Date()
                // 啟動 10 秒超時計時器
                timeoutTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
                    guard let self = self, !self.hasReported else { return }
                    print("[Zuvio] 10 秒內未成功，視為失敗")
                    self.hasReported = true
                    self.onResult(false)
                }
            }
            
            let currentURL = webView.url?.absoluteString ?? ""
            let elapsed = Date().timeIntervalSince(startTime ?? Date())
            print("[Zuvio] 已載入 (\(String(format: "%.1f", elapsed))秒): \(currentURL)")
            
            // 檢查多種可能的成功 URL
            if currentURL.contains("student5/irs/index") || 
               currentURL.contains("student/index") ||
               currentURL.contains("app_v2") {
                print("[Zuvio] 登入成功")
                hasReported = true
                timeoutTimer?.invalidate()
                onResult(true)
                return
            }
            
            // 如果在登入頁面且還沒提交過，則提交登入
            if currentURL.contains("/irs/login") && !hasSentLogin {
                print("[Zuvio] 登入頁面載入完成，準備提交登入...")
                hasSentLogin = true
                submitLogin(in: webView)
            } else if currentURL.contains("/irs/login") && hasSentLogin {
                // 提交後又回到登入頁面，可能是帳密錯誤
                print("[Zuvio] 登入後返回登入頁面，可能帳密錯誤")
                hasReported = true
                timeoutTimer?.invalidate()
                onResult(false)
            }
        }
        
        private func submitLogin(in webView: WKWebView) {
            let encodedPwdB64 = Data(password.utf8).base64EncodedString()
            let params: [String: String] = [
                "email": account,
                "password": password,
                "encoded_password": encodedPwdB64,
                "current_language": "zh-TW"
            ]
            
            guard let body = formURLEncodedData(params),
                  let url = URL(string: "https://irs.zuvio.com.tw/irs/submitLogin") else {
                print("[Zuvio] 組合登入請求失敗")
                hasReported = true
                timeoutTimer?.invalidate()
                onResult(false)
                return
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 30.0
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("zh-TW,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            
            print("[Zuvio] 送出登入請求")
            webView.load(request)
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            let urlStr = webView.url?.absoluteString ?? ""
            print("[Zuvio] 開始載入: \(urlStr)")
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !hasReported else { return }
            let urlStr = webView.url?.absoluteString ?? ""
            print("[Zuvio] 載入失敗(預備): \(urlStr) error=\(error.localizedDescription)")
            
            // 失敗視為登入失敗
            hasReported = true
            timeoutTimer?.invalidate()
            onResult(false)
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !hasReported else { return }
            let urlStr = webView.url?.absoluteString ?? ""
            print("[Zuvio] 載入失敗: \(urlStr) error=\(error.localizedDescription)")
            
            // 失敗視為登入失敗
            hasReported = true
            timeoutTimer?.invalidate()
            onResult(false)
        }
    }
}
