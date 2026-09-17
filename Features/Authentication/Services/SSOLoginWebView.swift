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

private let ssoModernLoginURLString = "https://ccsys1.niu.edu.tw/SSO/login"
private let ssoLegacyDefaultURLString = "https://ccsys.niu.edu.tw/SSO/Default.aspx"
private let ssoLegacyMainURLString = "https://ccsys.niu.edu.tw/SSO/StdMain.aspx"

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

        if let url = URL(string: ssoModernLoginURLString) {
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

        if let url = URL(string: ssoModernLoginURLString) {
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
        private var modernLoginFinished = false
        private var modernFormHasBeenFilled = false
        private var modernSubmitTriggered = false
        private var modernLoginDeadline: Date?
        private var modernStateCheckInFlight = false
        private var modernWebContentRecoveryCount = 0
        private var modernPageGeneration = 0
        private let maxLegacyCaptchaAttempts = 6
        private var legacyCaptchaRetryCount = 0
        private var didFallbackToLegacyFlow = false

        init(appState: AppState, parent: SSOLoginWebView) {
            self.appState = appState
            self.parent = parent
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let urlStr = webView.url?.absoluteString ?? ""
            print("[SSO] 已載入: \(urlStr)")

            if urlStr.contains("StdMain.aspx") {
                legacyCaptchaRetryCount = 0
                didFallbackToLegacyFlow = false
                getSSOViewState = false  // 重置狀態
                print("[SSO] 登入成功 → 抓取學生資訊...")
                let GetStudentInfoJS = """
                (function() {
                    function collectText(doc) {
                        var collected = [];
                        if (!doc) return collected;
                        var span = doc.getElementById('Label1');
                        var textSource = span ? (span.innerText || span.textContent) : '';
                        if (textSource) collected.push(textSource);
                        if (doc.body) {
                            var bodyText = doc.body.innerText || doc.body.textContent || '';
                            if (bodyText) collected.push(bodyText);
                        }
                        return collected;
                    }
                
                    var texts = collectText(document);
                    if (window.frames && window.frames.length) {
                        for (var i = 0; i < window.frames.length; i++) {
                            try {
                                texts = texts.concat(collectText(window.frames[i].document));
                            } catch (e) {}
                        }
                    }
                
                    if (!texts.length) return JSON.stringify({name: '', department: '', grade: ''});
                    var text = texts.join(' ');
                    var normalized = text.replace(/\\s+/g, ' ').trim();
                    if (!normalized) return JSON.stringify({name: '', department: '', grade: ''});
                    
                    var name = '';
                    var department = '';
                    var grade = '';
                    
                    var infoLineMatch = normalized.match(/系所年級[：:]?\\s*([^\\s<]+)\\s*學號[：:]?\\s*[^\\s<]+\\s*姓名[：:]?\\s*([^\\s<]+)/);
                    if (infoLineMatch) {
                        department = infoLineMatch[1].trim();
                        name = infoLineMatch[2].trim();
                    }
                    
                    // 抓取姓名：XXX
                    if (!name) {
                        var nameMatch = normalized.match(/姓名[：:]\\s*([^\\s<]+)/);
                        name = nameMatch ? nameMatch[1].trim() : '';
                    }
                    
                    // 抓取系所：XXX 或 科系：XXX / 系所年級
                    if (!department) {
                        var deptMatch = normalized.match(/(系所年級|系所|科系|學系|學程|研究所|系級|班級)[：:]?\\s*([^\\s<]+)/);
                        department = deptMatch ? deptMatch[2].trim() : '';
                    }
                    
                    // 抓取年級：X年級 或 X級 / 年級：X
                    var gradeLabelMatch = normalized.match(/年級[：:]?\\s*([0-9]+|[一二三四五六七八九十]+)/);
                    if (gradeLabelMatch) {
                        grade = gradeLabelMatch[1].trim();
                        if (grade && grade.indexOf('年級') === -1 && grade.indexOf('級') === -1) {
                            grade = grade + '年級';
                        }
                    }
                
                    if (!grade) {
                        var gradeMatch = normalized.match(/([0-9]+|[一二三四五六七八九十]+)\\s*(年級|級)/);
                        grade = gradeMatch ? gradeMatch[0].replace(/\\s+/g, '') : '';
                    }
                
                    if (department && !grade) {
                        var inlineGrade = department.match(/([0-9]+|[一二三四五六七八九十]+)\\s*(年級|級)/);
                        if (inlineGrade) {
                            grade = inlineGrade[0].replace(/\\s+/g, '');
                        }
                    }
                
                    if (department && grade) {
                        department = department.replace(grade, '').trim();
                    }
                
                    // 若沒有明確 "系/科："，嘗試從 "資訊工程學系2年級" 這種連在一起的文字拆解
                    if (!department && grade) {
                        var gradePos = normalized.indexOf(grade);
                        if (gradePos > 0) {
                            var beforeGrade = normalized.substring(0, gradePos).trim();
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
                fetchStudentInfo(in: webView, javascript: GetStudentInfoJS, attempt: 0)
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

            if isModernLoginPage(urlStr) {
                startModernLogin(in: webView)
                return
            }

            if urlStr.contains("ccsys1.niu.edu.tw/SSO/dashboard") {
                checkModernLoginState(in: webView)
                return
            }

            if urlStr.contains("Default.aspx") {
                lastPostFailed = false
                getSSOViewState = false
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
                modernStateCheckInFlight = false
                modernFormHasBeenFilled = false
                modernSubmitTriggered = false
                modernLoginDeadline = nil
                modernPageGeneration += 1
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let url = URL(string: ssoModernLoginURLString) {
                        webView.load(URLRequest(url: url))
                    }
                }
            } else if nsError.code == NSURLErrorTimedOut && lastPostFailed {
                print("[SSO] 重試後仍超時，停止嘗試")
                handleModernLoginOutcome(.systemError, in: webView)
            } else if nsError.code != NSURLErrorCancelled,
                      !modernLoginFinished,
                      urlStr.contains("ccsys1.niu.edu.tw/SSO") {
                handleModernLoginOutcome(
                    .generic("登入頁載入失敗", "無法載入校方登入頁，請確認網路後再試一次"),
                    in: webView
                )
            }
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let urlStr = webView.url?.absoluteString ?? ""
            print("[SSO] 載入失敗: \(urlStr) error=\(error.localizedDescription)")
            let nsError = error as NSError
            if nsError.code != NSURLErrorCancelled,
               !modernLoginFinished,
               urlStr.contains("ccsys1.niu.edu.tw/SSO") {
                handleModernLoginOutcome(
                    .generic("登入頁載入失敗", "校方登入頁中斷，請重新登入"),
                    in: webView
                )
            }
        }

        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !modernLoginFinished else { return }
            print("[SSO] WebContent 程序終止，嘗試恢復登入頁")

            guard modernWebContentRecoveryCount < 1 else {
                handleModernLoginOutcome(
                    .generic("登入頁載入失敗", "校方登入頁的 WebView 已停止運作，請重新登入或改用實機再試"),
                    in: webView
                )
                return
            }

            modernWebContentRecoveryCount += 1
            isProcessingCaptcha = false
            modernStateCheckInFlight = false
            modernFormHasBeenFilled = false
            modernSubmitTriggered = false
            modernLoginDeadline = nil
            modernPageGeneration += 1

            if let url = URL(string: ssoModernLoginURLString) {
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            } else {
                handleModernLoginOutcome(.systemError, in: webView)
            }
        }

        private func eval(_ webView: WKWebView, _ js: String, _ note: String, completion: @escaping (Any?) -> Void) {
            webView.evaluateJavaScript(js) { result, error in
                completion(error == nil ? result : nil)
            }
        }

        private func isModernLoginPage(_ urlString: String) -> Bool {
            guard let url = URL(string: urlString) else { return false }
            guard url.host == "ccsys1.niu.edu.tw" else { return false }
            return url.path.lowercased().contains("/sso/login")
        }

        private struct LegacyCaptchaImagePayload: Decodable {
            let dataURL: String?
            let src: String?
            let complete: Bool
            let width: Double
        }

        private struct AuthorizationInfoResponse: Decodable {
            struct Data: Decodable {
                let acnt: String?
                let ou: String?
                let role: String?
                let chName: String?
                let idno: String?
                let collegeName: String?
                let facultyName: String?
                let degreeName: String?
                let grade: String?
                let classNo: String?
                let exp: String?
            }
            let userType: String?
            let data: Data?
        }

        private enum ModernLoginOutcome {
            case success(token: String?)
            case credentialsFailed(String)
            case passwordExpired(String)
            case accountLocked(String?)
            case generic(String, String)
            case systemError
        }

        private func startModernLogin(in webView: WKWebView) {
            guard !isProcessingCaptcha, !modernLoginFinished else { return }
            isProcessingCaptcha = true
            modernLoginDeadline = Date().addingTimeInterval(60)
            print("[SSO] 開始新版登入流程")
            checkModernLoginState(in: webView)
            fillModernLoginForm(in: webView)
        }

        private func fillModernLoginForm(in webView: WKWebView) {
            guard !modernLoginFinished, !modernSubmitTriggered else { return }
            let generation = modernPageGeneration
            guard let credentials = try? JSONSerialization.data(withJSONObject: [parent.account, parent.password]),
                  let json = String(data: credentials, encoding: .utf8) else {
                handleModernLoginOutcome(.systemError, in: webView)
                return
            }
            let shouldFill = modernFormHasBeenFilled ? "false" : "true"

            let script = """
            (function() {
                const [account, password] = \(json);
                const usernameField = document.querySelector('#username');
                const passwordField = document.querySelector('#password');
                const form = document.querySelector('form.login-form');
                const submit = document.querySelector('form.login-form button[type="submit"]');
                if (!usernameField || !passwordField || !form || !submit) return 'waiting';
                if (!window.__niuAppSubmitHooked) {
                    window.__niuAppSubmitHooked = true;
                    form.addEventListener('submit', () => { window.__niuAppSubmitObserved = true; });
                }
                if (window.__niuAppSubmitObserved) return 'submitted';
                if (\(shouldFill)) {
                    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
                    for (const [field, value] of [[usernameField, account], [passwordField, password]]) {
                        setter.call(field, value);
                        field.dispatchEvent(new Event('input', { bubbles: true }));
                        field.dispatchEvent(new Event('change', { bubbles: true }));
                    }
                }
                if (!usernameField.checkValidity() || !passwordField.checkValidity()) return 'invalid_credentials';
                if (submit.disabled) return 'waiting_verification';
                submit.click();
                return 'submitted';
            })();
            """

            webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
                guard let self, let webView,
                      generation == self.modernPageGeneration,
                      !self.modernLoginFinished else { return }
                let state = result as? String
                if state == "waiting_verification" || state == "submitted" {
                    self.modernFormHasBeenFilled = true
                }
                if error != nil || state != "submitted" {
                    if state == "invalid_credentials" {
                        self.handleModernLoginOutcome(
                            .credentialsFailed("帳號或密碼格式不正確"),
                            in: webView
                        )
                        return
                    }
                    if let deadline = self.modernLoginDeadline, Date() >= deadline {
                        self.handleModernLoginOutcome(
                            .generic("登入逾時", "請完成校方登入頁的人機驗證，再重新登入"),
                            in: webView
                        )
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak webView] in
                        guard let self, let webView,
                              generation == self.modernPageGeneration else { return }
                        self.fillModernLoginForm(in: webView)
                    }
                    return
                }
                self.modernSubmitTriggered = true
            }
        }

        private func checkModernLoginState(in webView: WKWebView) {
            guard isProcessingCaptcha, !modernLoginFinished, !modernStateCheckInFlight else { return }
            let generation = modernPageGeneration
            modernStateCheckInFlight = true
            let script = """
            (function() {
                const token = sessionStorage.getItem('niu_sso_token') || '';
                const alert = document.querySelector('.swal2-popup.swal2-show, .alert-danger, [role="alert"]');
                return JSON.stringify({ token: token, error: alert ? alert.innerText.trim() : '' });
            })();
            """
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
                guard let self, let webView,
                      generation == self.modernPageGeneration,
                      !self.modernLoginFinished else { return }
                self.modernStateCheckInFlight = false
                if let json = result as? String,
                   let data = json.data(using: .utf8),
                   let state = try? JSONDecoder().decode(ModernPageState.self, from: data) {
                    if !state.token.isEmpty {
                        self.handleModernLoginOutcome(.success(token: state.token), in: webView)
                        return
                    }
                    if !state.error.isEmpty {
                        let lowercased = state.error.lowercased()
                        if !state.error.contains("驗證") && !lowercased.contains("turnstile") {
                            self.handleModernLoginOutcome(self.modernLoginError(state.error), in: webView)
                            return
                        }
                    }
                }
                if let deadline = self.modernLoginDeadline, Date() >= deadline {
                    self.handleModernLoginOutcome(.generic("登入逾時", "請確認人機驗證已完成，再重新登入"), in: webView)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak webView] in
                    guard let self, let webView,
                          generation == self.modernPageGeneration else { return }
                    self.checkModernLoginState(in: webView)
                }
            }
        }

        private struct ModernPageState: Decodable {
            let token: String
            let error: String
        }

        private func modernLoginError(_ message: String) -> ModernLoginOutcome {
            if message.contains("鎖定") { return .accountLocked(nil) }
            if message.contains("密碼") &&
                (message.contains("到期") || message.contains("過期") || message.contains("變更預設密碼")) {
                return .passwordExpired(message)
            }
            if message.contains("帳號") || message.contains("密碼") { return .credentialsFailed(message) }
            return .generic("登入失敗", message)
        }

        private func handleModernLoginOutcome(_ outcome: ModernLoginOutcome, in webView: WKWebView) {
            guard !modernLoginFinished else { return }
            modernLoginFinished = true
            isProcessingCaptcha = false
            switch outcome {
            case .success(let token):
                if let token, !token.isEmpty {
                    SSOTokenStore.shared.save(token: token, exp: tokenExpiration(token), account: parent.account)
                }
                finishModernLogin(token: token, in: webView)
            case .credentialsFailed(let message):
                parent.onResult(.credentialsFailed(message: message))
            case .passwordExpired(let message):
                parent.onResult(.passwordExpired(message: message))
            case .accountLocked(let lockTime):
                parent.onResult(.accountLocked(lockTime: lockTime))
            case .generic(let title, let message):
                parent.onResult(.generic(title: title, message: message))
            case .systemError:
                parent.onResult(.systemError)
            }
        }

        private func tokenExpiration(_ token: String) -> String? {
            let parts = token.split(separator: ".")
            guard parts.count > 1 else { return nil }
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                          .replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: payload),
                  let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let seconds = claims["exp"] as? TimeInterval else { return nil }
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        }

        private func finishModernLogin(token: String?, in webView: WKWebView) {
            guard let token, !token.isEmpty else {
                print("[SSO] 新版登入成功但缺少 token")
                parent.onResult(.systemError)
                return
            }

            persistTokenIntoWebView(token: token, in: webView)

            Task { [weak self] in
                guard let self else { return }
                let info = await self.fetchAuthorizationInfo(token: token)
                await MainActor.run {
                    let resolved = info ?? StudentInfo(name: self.parent.account, department: "", grade: "")
                    self.appState.updateProfileFromSSO(resolved)
                    self.parent.onResult(.success(info: resolved))
                }
            }
        }

        private func persistTokenIntoWebView(token: String, in webView: WKWebView) {
            let escaped = token.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "'", with: "\\'")
            let js = "try { sessionStorage.setItem('niu_sso_token', '\(escaped)'); } catch (e) {}"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    print("[SSO] sessionStorage 寫入失敗: \(error.localizedDescription)")
                }
            }
        }

        private func fetchAuthorizationInfo(token: String) async -> StudentInfo? {
            guard let url = URL(string: "https://ccsys1.niu.edu.tw/SSO/API/Authorization/info") else {
                return nil
            }

            for attempt in 1...3 {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 15
                request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(ssoModernLoginURLString, forHTTPHeaderField: "Referer")

                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    guard status == 200 else {
                        print("[SSO] Authorization/info attempt=\(attempt) status=\(status)")
                        if status == 401 || status == 403 { return nil }
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        continue
                    }
                    let payload = try JSONDecoder().decode(AuthorizationInfoResponse.self, from: data)
                    guard let d = payload.data else {
                        print("[SSO] Authorization/info attempt=\(attempt) 無 data 欄位")
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        continue
                    }
                    let name = d.chName?.nilIfEmpty ?? parent.account
                    let department = d.facultyName?.nilIfEmpty ?? ""
                    let grade: String
                    if let raw = d.grade?.nilIfEmpty {
                        grade = raw.contains("年級") ? raw : "\(raw)年級"
                    } else {
                        grade = ""
                    }
                    print("[SSO] 新版登入取得學生資訊: \(name) / \(department) / \(grade)")
                    return StudentInfo(name: name, department: department, grade: grade)
                } catch {
                    print("[SSO] Authorization/info attempt=\(attempt) 失敗: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    continue
                }
            }
            return nil
        }

        private func bootstrapLegacyPortalSession(in webView: WKWebView, reason: String) {
            print("[SSO] 進入舊版 portal session 建立流程 reason=\(reason)")
            legacyCaptchaRetryCount = 0
            getSSOViewState = false
            isProcessingCaptcha = false
            if let url = URL(string: ssoLegacyDefaultURLString) {
                webView.load(URLRequest(url: url))
            } else {
                parent.onResult(.systemError)
            }
        }

        private func scheduleLegacyCaptchaRetry(in webView: WKWebView, reason: String) {
            legacyCaptchaRetryCount += 1

            guard legacyCaptchaRetryCount <= maxLegacyCaptchaAttempts else {
                print("[SSO] 舊版驗證碼重試超過上限 reason=\(reason)")
                isProcessingCaptcha = false
                getSSOViewState = false
                parent.onResult(.generic(title: "登入失敗", message: "驗證碼辨識多次失敗，請再試一次"))
                return
            }

            print("[SSO] 舊版驗證碼重試 \(legacyCaptchaRetryCount)/\(maxLegacyCaptchaAttempts) reason=\(reason)")
            isProcessingCaptcha = false
            getSSOViewState = false

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let url = URL(string: ssoLegacyDefaultURLString) {
                    webView.load(URLRequest(url: url))
                } else {
                    self.parent.onResult(.systemError)
                }
            }
        }

        private func fetchStudentInfo(in webView: WKWebView, javascript: String, attempt: Int) {
            let maxAttempts = 2
            webView.evaluateJavaScript(javascript) { [weak self] result, error in
                guard let self else { return }
                if let jsonStr = result as? String,
                   let data = jsonStr.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let name = obj["name"], !name.isEmpty {
                    let department = obj["department"] ?? ""
                    let grade = obj["grade"] ?? ""
                    let info = StudentInfo(name: name, department: department, grade: grade)
                    print("[SSO] 取得學生資訊: \(name) / \(department) / \(grade)")
                    if !department.isEmpty || !grade.isEmpty {
                        Task { @MainActor in
                            self.appState.updateProfileFromSSO(info)
                        }
                        self.parent.onResult(.success(info: info))
                        return
                    }

                    if attempt < maxAttempts {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            self.fetchStudentInfo(in: webView, javascript: javascript, attempt: attempt + 1)
                        }
                        return
                    }

                    self.parent.onResult(.success(info: info))
                    return
                }

                if attempt < maxAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.fetchStudentInfo(in: webView, javascript: javascript, attempt: attempt + 1)
                    }
                    return
                }

                print("[SSO] 未取得完整資訊，使用學號作為姓名")
                let fallbackInfo = StudentInfo(name: self.parent.account, department: "", grade: "")
                self.parent.onResult(.success(info: fallbackInfo))
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
                    if let url = URL(string: ssoLegacyMainURLString) {
                        webView.load(URLRequest(url: url))
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        done(.passwordExpiring(message: content))
                    }
                } else if content.contains("密碼已到期") {
                    done(.passwordExpired(message: content))
                } else if content.contains("驗證碼輸入錯誤") {
                    self.handleCaptchaErrorAndRetry(in: webView)
                    done(nil)
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
                        self?.scheduleLegacyCaptchaRetry(in: webView, reason: "legacy-captcha-image-missing")
                        return
                    }
                    
                    SSOCaptchaProcessor.shared.recognize(from: image) { [weak self] code in
                        guard let self = self else { return }
                        
                        if let code = code, code.count == 6 {
                            print("[SSO] OCR 成功 → \(code)")
                            self.legacyCaptchaRetryCount = 0
                            self.fetchHiddenFieldsAndPost(in: webView, viewState: viewState, captcha: code)
                        } else {
                            print("[SSO] OCR 失敗，重新嘗試")
                            self.scheduleLegacyCaptchaRetry(in: webView, reason: "legacy-ocr-failed")
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
            getCaptchaImage(in: webView, attempt: 1, completion: completion)
        }

        private func getCaptchaImage(in webView: WKWebView, attempt: Int, completion: @escaping (SSOImage?) -> Void) {
            let maxAttempts = 4
            let js = """
            (function(){
                var img = document.getElementById('VaildteCode') || document.getElementById('ContentPlaceHolder1_ImageSecurityCode');
                if (!img) return JSON.stringify({dataURL:null,src:null,complete:false,width:0});
                if (img.src && img.src.indexOf('data:image') === 0) {
                    return JSON.stringify({dataURL:img.src,src:img.currentSrc || img.src,complete:!!img.complete,width:img.naturalWidth || 0});
                }
                if (!img.complete || img.naturalWidth === 0) {
                    return JSON.stringify({dataURL:null,src:img.currentSrc || img.src || null,complete:!!img.complete,width:img.naturalWidth || 0});
                }
                var dpr = window.devicePixelRatio || 1;
                var canvas = document.createElement('canvas');
                canvas.width = img.naturalWidth * dpr;
                canvas.height = img.naturalHeight * dpr;
                var ctx = canvas.getContext('2d');
                if (!ctx) return JSON.stringify({dataURL:null,src:img.currentSrc || img.src || null,complete:true,width:img.naturalWidth || 0});
                ctx.scale(dpr, dpr);
                ctx.drawImage(img, 0, 0);
                try {
                    return JSON.stringify({dataURL:canvas.toDataURL('image/png'),src:img.currentSrc || img.src || null,complete:true,width:img.naturalWidth || 0});
                } catch (e) {
                    return JSON.stringify({dataURL:null,src:img.currentSrc || img.src || null,complete:true,width:img.naturalWidth || 0});
                }
            })()
            """
            eval(webView, js, "getCaptchaImage") { val in
                guard let jsonStr = val as? String,
                      let data = jsonStr.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(LegacyCaptchaImagePayload.self, from: data) else {
                    print("[SSO] 驗證碼 payload 解析失敗")
                    completion(nil)
                    return
                }

                if let dataURL = payload.dataURL,
                   let image = self.decodeCaptchaDataURL(dataURL) {
                    completion(image)
                    return
                }

                if attempt < maxAttempts {
                    print("[SSO] 驗證碼尚未就緒 complete=\(payload.complete) width=\(payload.width) attempt=\(attempt)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.getCaptchaImage(in: webView, attempt: attempt + 1, completion: completion)
                    }
                    return
                }

                guard let src = payload.src, !src.isEmpty else {
                    print("[SSO] 驗證碼 dataURL 取得失敗，且無法取得 src")
                    completion(nil)
                    return
                }
                self.fetchCaptchaImageData(from: src, relativeTo: webView.url) { image in
                    if image == nil {
                        print("[SSO] 驗證碼 fallback 抓圖失敗")
                    }
                    completion(image)
                }
            }
        }

        private func decodeCaptchaDataURL(_ dataURL: String) -> SSOImage? {
            guard dataURL.starts(with: "data:image"),
                  let commaIndex = dataURL.firstIndex(of: ",") else {
                return nil
            }
            let base64 = String(dataURL[dataURL.index(after: commaIndex)...])
            guard let data = Data(base64Encoded: base64) else { return nil }
            return SSOImage(data: data)
        }

        private func fetchCaptchaImageData(from src: String, relativeTo baseURL: URL?, completion: @escaping (SSOImage?) -> Void) {
            let url = URL(string: src, relativeTo: baseURL)?.absoluteURL ?? URL(string: src)
            guard let url else {
                completion(nil)
                return
            }

            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                func finish(_ image: SSOImage?) {
                    DispatchQueue.main.async {
                        completion(image)
                    }
                }

                if let error {
                    print("[SSO] fallback 驗證碼下載失敗: \(error.localizedDescription)")
                    finish(nil)
                    return
                }
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(statusCode) || statusCode == 0,
                      let data,
                      let image = SSOImage(data: data) else {
                    print("[SSO] fallback 驗證碼內容無效 status=\(statusCode)")
                    finish(nil)
                    return
                }
                finish(image)
            }
            task.resume()
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
                    self.getSSOViewState = false
                    self.parent.onResult(.systemError)
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
                  let url = URL(string: ssoLegacyDefaultURLString) else {
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
                self.scheduleLegacyCaptchaRetry(in: webView, reason: "legacy-captcha-rejected")
            }
        }
    }
}
