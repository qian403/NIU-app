import SwiftUI
import WebKit
#if os(macOS)
import AppKit
public typealias SSOViewRepresentable = NSViewRepresentable
public typealias SSOImage = NSImage
#else
import UIKit
public typealias SSOViewRepresentable = UIViewRepresentable
public typealias SSOImage = UIImage
#endif

public struct StudentInfo {
    let name: String
    let department: String
    let grade: String
}

public enum SSOLoginResult {
    case success(info: StudentInfo)
    case credentialsFailed(message: String)
    case passwordExpiring(message: String)
    case passwordExpired(message: String)
    case accountLocked(lockTime: String?)
    case systemError
    case generic(title: String, message: String)
}

private func sso_percentEncodeForm(_ string: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._* ")
    let encoded = string.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    return encoded.replacingOccurrences(of: " ", with: "+")
}

private func sso_formURLEncodedDataOrdered(_ items: [(String, String)]) -> Data? {
    let pairs = items.map { key, value in
        "\(sso_percentEncodeForm(key))=\(sso_percentEncodeForm(value))"
    }
    let bodyString = pairs.joined(separator: "&")
    return bodyString.data(using: .utf8)
}

public struct SSOLoginWebView: SSOViewRepresentable {
    public let account: String
    public let password: String
    public let onResult: (SSOLoginResult) -> Void
    
    @EnvironmentObject var appState: AppState

    public init(account: String, password: String, onResult: @escaping (SSOLoginResult) -> Void) {
        self.account = account
        self.password = password
        self.onResult = onResult
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState, parent: self)
    }

    #if os(macOS)
    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        if let url = URL(string: "https://ccsys.niu.edu.tw/SSO/Default.aspx") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
    #else
    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        if let url = URL(string: "https://ccsys.niu.edu.tw/SSO/Default.aspx") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
    #endif

    public class Coordinator: NSObject, WKNavigationDelegate {
        private let appState: AppState
        private let parent: SSOLoginWebView
        private var isProcessingCaptcha = false
        private var getSSOViewState = false
        private var lastPostFailed = false
        private var retryCount = 0
        private let maxRetries = 3

        init(appState: AppState, parent: SSOLoginWebView) {
            self.appState = appState
            self.parent = parent
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let urlStr = webView.url?.absoluteString ?? ""
            print("[SSO] 已載入: \(urlStr)")

            if urlStr.contains("StdMain.aspx") {
                getSSOViewState = false  // 重置狀態
                print("[SSO] 登入成功 → 抓取學生資訊...")
                let GetStudentInfoJS = """
                (function() {
                    var span = document.getElementById('Label1');
                    if (!span) return JSON.stringify({name: '', department: '', grade: ''});
                    var text = span.innerText || span.textContent;
                    
                    // 抓取姓名：XXX
                    var nameMatch = text.match(/姓名[：:]\\s*([^\\s<]+)/);
                    var name = nameMatch ? nameMatch[1].trim() : '';
                    
                    // 抓取系所：XXX 或 科系：XXX
                    var deptMatch = text.match(/[系科][所]?[：:]\\s*([^\\s<]+)/);
                    var department = deptMatch ? deptMatch[1].trim() : '';
                    
                    // 抓取年級：X年級 或 X級
                    var gradeMatch = text.match(/(\\d+\\s*年級|\\d+\\s*級)/);
                    var grade = gradeMatch ? gradeMatch[1].replace(/\\s+/g, '') : '';

                    // 若沒有明確 "系/科："，嘗試從 "資訊工程學系2年級" 這種連在一起的文字拆解
                    if (!department && grade) {
                        var gradePos = text.indexOf(gradeMatch ? gradeMatch[1] : '');
                        if (gradePos > 0) {
                            var beforeGrade = text.substring(0, gradePos).trim();
                            var pieces = beforeGrade.split(/\\s+/);
                            var candidate = pieces.length > 0 ? pieces[pieces.length - 1] : beforeGrade;
                            if (candidate && (candidate.indexOf('系') !== -1 || candidate.indexOf('學程') !== -1 || candidate.indexOf('所') !== -1)) {
                                department = candidate.trim();
                            }
                        }
                    }
                    
                    return JSON.stringify({
                        name: name,
                        department: department,
                        grade: grade
                    });
                })();
                """
                webView.evaluateJavaScript(GetStudentInfoJS) { result, error in
                    if let jsonStr = result as? String,
                       let data = jsonStr.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       let name = obj["name"], !name.isEmpty {
                        let department = obj["department"] ?? ""
                        let grade = obj["grade"] ?? ""
                        let info = StudentInfo(name: name, department: department, grade: grade)
                        print("[SSO] 取得學生資訊: \(name) / \(department) / \(grade)")
                        self.parent.onResult(.success(info: info))
                    } else {
                        print("[SSO] 未取得完整資訊，使用學號作為姓名")
                        let fallbackInfo = StudentInfo(name: self.parent.account, department: "", grade: "")
                        self.parent.onResult(.success(info: fallbackInfo))
                    }
                    return
                }
                return
            }

            if urlStr.contains("AccountLock.aspx") {
                getSSOViewState = false  // 重置狀態
                print("[SSO] 帳號鎖定")
                eval(webView, "document.querySelector('#ContentPlaceHolder1_lbl_lockTime').textContent", "getLockTime") { val in
                    let lockTime = val as? String
                    self.parent.onResult(.accountLocked(lockTime: lockTime))
                }
                return
            }

            if urlStr.contains("error.html") {
                getSSOViewState = false  // 重置狀態
                print("[SSO] 系統錯誤頁面")
                parent.onResult(.systemError)
                return
            }

            if urlStr.contains("Default.aspx") {
                lastPostFailed = false  // 重置失敗標誌
                checkLoginError_SSO(in: webView) { [weak self] errorResult in
                    if let errorResult = errorResult {
                        self?.parent.onResult(errorResult)
                        return
                    }
                    self?.checkLoginDialog_SSO(in: webView) { [weak self] dialogResult in
                        if let dialogResult = dialogResult {
                            self?.parent.onResult(dialogResult)
                            return
                        }
                        self?.Login_SSO(in: webView)
                    }
                }
                return
            }
        }

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            let urlStr = webView.url?.absoluteString ?? ""
            print("[SSO] 開始載入: \(urlStr)")
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let urlStr = webView.url?.absoluteString ?? ""
            let nsError = error as NSError
            print("[SSO] 載入失敗(預備): \(urlStr) error=\(error.localizedDescription)")
            
            // 超時錯誤處理
            if nsError.code == NSURLErrorTimedOut && !lastPostFailed {
                print("[SSO] 請求超時，重置狀態並重試...")
                lastPostFailed = true
                getSSOViewState = false
                isProcessingCaptcha = false
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let url = URL(string: "https://ccsys.niu.edu.tw/SSO/Default.aspx") {
                        webView.load(URLRequest(url: url))
                    }
                }
            } else if nsError.code == NSURLErrorTimedOut && lastPostFailed {
                print("[SSO] 重試後仍超時，停止嘗試")
                parent.onResult(.systemError)
            }
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let urlStr = webView.url?.absoluteString ?? ""
            print("[SSO] 載入失敗: \(urlStr) error=\(error.localizedDescription)")
        }

        private func eval(_ webView: WKWebView, _ js: String, _ note: String, completion: @escaping (Any?) -> Void) {
            webView.evaluateJavaScript(js) { result, error in
                completion(error == nil ? result : nil)
            }
        }

        private func checkLoginError_SSO(in webView: WKWebView, done: @escaping (SSOLoginResult?) -> Void) {
            let js = """
            (function(){
                var el=document.querySelector('#show_failed');
                if(!el) return JSON.stringify({found:false});
                var s=window.getComputedStyle(el);
                var visible=(s.display!=='none' && s.visibility!=='hidden' && el.offsetWidth>0 && el.offsetHeight>0);
                var msg=el.innerText.trim().slice(0, -1);
                return JSON.stringify({found:true,visible:visible,message:msg});
            })()
            """
            eval(webView, js, "checkLoginError_SSO") { val in
                guard let jsonStr = val as? String,
                      let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    done(nil)
                    return
                }
                
                if let found = obj["found"] as? Bool, found,
                   let visible = obj["visible"] as? Bool, visible,
                   let message = obj["message"] as? String, !message.isEmpty {
                    done(.credentialsFailed(message: message))
                } else {
                    done(nil)
                }
            }
        }

        private func checkLoginDialog_SSO(in webView: WKWebView, done: @escaping (SSOLoginResult?) -> Void) {
            let js = """
            (function(){
                var modalBg = document.querySelector('.sweet-alert.showSweetAlert.visible');
                if (!modalBg) return JSON.stringify({found: false});
                var title = modalBg.querySelector('h2')?.innerText.trim() || '';
                var content = modalBg.querySelector('p')?.innerText.trim() || '';
                return JSON.stringify({found: true, title: title, content: content});
            })()
            """
            eval(webView, js, "checkLoginDialog_SSO") { val in
                guard let jsonStr = val as? String,
                      let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let found = obj["found"] as? Bool, found,
                      let title = obj["title"] as? String,
                      let content = obj["content"] as? String else {
                    done(nil)
                    return
                }
                
                if content.contains("密碼即將到期") {
                    if let url = URL(string: "https://ccsys.niu.edu.tw/SSO/StdMain.aspx") {
                        webView.load(URLRequest(url: url))
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        done(.passwordExpiring(message: content))
                    }
                } else if content.contains("密碼已到期") {
                    done(.passwordExpired(message: content))
                } else if content.contains("驗證碼輸入錯誤") {
                    self.retryCount += 1
                    if self.retryCount <= self.maxRetries {
                        print("[SSO] 驗證碼錯誤，重試 (第 \(self.retryCount)/\(self.maxRetries) 次)")
                        self.handleCaptchaErrorAndRetry(in: webView)
                        done(nil)
                    } else {
                        print("[SSO] 已達重試上限，停止重試")
                        done(.credentialsFailed(message: "驗證碼錯誤次數過多，請稍後再試"))
                    }
                } else {
                    done(.generic(title: title, message: content))
                }
            }
        }

        private func Login_SSO(in webView: WKWebView) {
            guard !isProcessingCaptcha else { return }
            isProcessingCaptcha = true
            print("[SSO] 開始登入流程")

            getSSOViewState(in: webView) { [weak self] viewState in
                guard let self = self, let viewState = viewState else {
                    print("[SSO] 取得 VIEWSTATE 失敗")
                    self?.isProcessingCaptcha = false
                    return
                }
                if viewState.isEmpty {
                    print("[SSO] VIEWSTATE 為空")
                }
                
                self.getCaptchaImage(in: webView) { [weak self] image in
                    guard let self = self, let image = image else {
                        print("[SSO] 取得驗證碼圖片失敗")
                        self?.isProcessingCaptcha = false
                        return
                    }
                    
                    SSOCaptchaProcessor.shared.recognize(from: image) { [weak self] code in
                        guard let self = self else { return }
                        
                        if let code = code, code.count == 6 {
                            print("[SSO] OCR 成功 → \(code)")
                            self.fetchHiddenFieldsAndPost(in: webView, viewState: viewState, captcha: code)
                        } else {
                            print("[SSO] OCR 無效結果")
                            self.retryCount += 1
                            if self.retryCount <= self.maxRetries {
                                print("[SSO] OCR 失敗，1 秒後重試 (第 \(self.retryCount)/\(self.maxRetries) 次)")
                                self.isProcessingCaptcha = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    if let url = URL(string: "https://ccsys.niu.edu.tw/SSO/Default.aspx") {
                                        webView.load(URLRequest(url: url))
                                    }
                                }
                            } else {
                                print("[SSO] 已達重試上限，停止重試")
                                self.isProcessingCaptcha = false
                                self.parent.onResult(.credentialsFailed(message: "驗證碼識別失敗，請稍後再試"))
                            }
                        }
                    }
                }
            }
        }

        private func getSSOViewState(in webView: WKWebView, completion: @escaping (String?) -> Void) {
            let js = "document.getElementById('__VIEWSTATE')?.value || ''"
            eval(webView, js, "getViewState") { val in
                if val == nil {
                    print("[SSO] VIEWSTATE JS 取值為 nil")
                }
                completion(val as? String)
            }
        }

        private func getCaptchaImage(in webView: WKWebView, completion: @escaping (SSOImage?) -> Void) {
            let js = """
            (function(){
                var img = document.getElementById('VaildteCode') || document.getElementById('ContentPlaceHolder1_ImageSecurityCode');
                if (!img) return null;
                if (img.src && img.src.indexOf('data:image') === 0) return img.src;
                if (!img.complete || img.naturalWidth === 0) return null;
                var canvas = document.createElement('canvas');
                canvas.width = img.naturalWidth;
                canvas.height = img.naturalHeight;
                var ctx = canvas.getContext('2d');
                if (!ctx) return null;
                ctx.drawImage(img, 0, 0);
                try {
                    return canvas.toDataURL('image/png');
                } catch (e) {
                    return null;
                }
            })()
            """
            eval(webView, js, "getCaptchaImage") { val in
                guard let dataURL = val as? String,
                      dataURL.starts(with: "data:image"),
                      let commaIndex = dataURL.firstIndex(of: ",") else {
                    print("[SSO] 驗證碼 dataURL 取得失敗")
                    completion(nil)
                    return
                }
                
                let base64 = String(dataURL[dataURL.index(after: commaIndex)...])
                guard let data = Data(base64Encoded: base64),
                      let image = SSOImage(data: data) else {
                    print("[SSO] 驗證碼圖片解碼失敗")
                    completion(nil)
                    return
                }
                completion(image)
            }
        }

        private func fetchHiddenFieldsAndPost(in webView: WKWebView, viewState: String, captcha: String) {
            let js = """
            (function(){
              function gv(id){var e=document.getElementById(id);return e?e.value:'';}
              function qv(sel){var e=document.querySelector(sel);return e?e.value:'';}
              return JSON.stringify({
                viewstate: gv('__VIEWSTATE'),
                vsg: gv('__VIEWSTATEGENERATOR'),
                ev: gv('__EVENTVALIDATION'),
                token: qv('input[name="__RequestVerificationToken"]')
              });
            })()
            """

            eval(webView, js, "getHiddenFields") { [weak self] val in
                guard let self = self else { return }
                guard let jsonStr = val as? String,
                      let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    print("[SSO] Hidden fields parse failed")
                    self.isProcessingCaptcha = false
                    return
                }

                let hiddenViewState = obj["viewstate"] ?? viewState
                let vsg = obj["vsg"] ?? ""
                let ev = obj["ev"] ?? ""
                let token = obj["token"] ?? ""
                self.submitLogin(in: webView, viewState: hiddenViewState, viewStateGenerator: vsg, eventValidation: ev, requestToken: token, captcha: captcha)
            }
        }

        private func submitLogin(in webView: WKWebView, viewState: String, viewStateGenerator: String, eventValidation: String, requestToken: String, captcha: String) {
            let formData: [(String, String)] = [
                ("__EVENTTARGET", ""),
                ("__EVENTARGUMENT", ""),
                ("__VIEWSTATE", viewState),
                ("__VIEWSTATEGENERATOR", viewStateGenerator),
                ("__EVENTVALIDATION", eventValidation),
                ("txt_Account", parent.account),
                ("txt_PWD", parent.password),
                ("txt_validateCode", captcha),
                ("__RequestVerificationToken", requestToken),
                ("ButLogin", "登入系統"),
                ("recaptchaResponse", "")
            ]

            guard let body = sso_formURLEncodedDataOrdered(formData),
                  let url = URL(string: "https://ccsys.niu.edu.tw/SSO/Default.aspx") else {
                print("[SSO] 組合登入請求失敗")
                isProcessingCaptcha = false
                return
            }

            if self.getSSOViewState {
                print("[SSO] 已送出登入請求，略過重送")
                isProcessingCaptcha = false
                return
            }
            self.getSSOViewState = true

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 30.0
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            print("[SSO] 送出登入請求")

            lastPostFailed = false
            webView.load(request)
            isProcessingCaptcha = false
        }

        private func handleCaptchaErrorAndRetry(in webView: WKWebView) {
            let closeJS = """
            (function(){
                var btn = document.querySelector('.swal-button--confirm');
                if (btn) { btn.click(); }
            })();
            """
            self.eval(webView, closeJS, "closeCaptchaErrorDialog") { _ in
                self.isProcessingCaptcha = false
                self.getSSOViewState = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.Login_SSO(in: webView)
                }
            }
        }
    }
}
