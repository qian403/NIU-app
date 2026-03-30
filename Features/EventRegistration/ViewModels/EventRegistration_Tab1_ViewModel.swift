import SwiftUI
import Combine
import WebKit

@MainActor
final class EventRegistration_Tab1_ViewModel: ObservableObject {
    
    // 狀態
    @Published var isOverlayVisible = true
    @Published var overlayText: String = "載入中"
    @Published var events: [EventData] = []
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""
    @Published var isPostHandled: Bool = false
    
    // 搜尋
    @Published var searchText: String = ""
    
    var filteredEvents: [EventData] {
        if searchText.isEmpty {
            return events
        } else {
            return events.filter { event in
                event.name.localizedCaseInsensitiveContains(searchText) ||
                event.department.localizedCaseInsensitiveContains(searchText) ||
                event.eventDetail.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    // 選中的活動資訊
    @Published var selectedEventForDetail: EventData?
    private var selectedEventID: String?
    
    // WebView
    private var webView: WKWebView?
    private var navigationDelegate: NavigationDelegate?
    private var notificationObservers: [NSObjectProtocol] = []
    
    // 登入狀態追蹤
    private var loginAttemptCount = 0
    private let maxLoginAttempts = 2
    private let loginRequesterID = UUID().uuidString
    private var hasInitialized = false
    private var isSubmittingLogin = false
    private var loginSubmitTimestamp: Date?
    private var loginFieldRetryCount = 0
    private var loginPageReloadCount = 0
    private var emptyLoginDOMCount = 0
    private var loginRecoveryWorkItem: DispatchWorkItem?
    private let maxLoginFieldRetries = 3
    private let maxLoginPageReloads = 2
    private let maxEmptyLoginDOMBeforeRecreate = 2
    private let loginSubmitCooldown: TimeInterval = 1.5
    
    // SSO ID
    private var ssoID: String = ""

    private func escapeForSingleQuotedJavaScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
    
    // JavaScript 抓取活動列表
    private let jsGetData: String = """
        (function() { 
            var data = []; 
            var skip = 0; 
            var count = document.querySelector('.col-md-11.col-md-offset-1.col-sm-10.col-xs-12.col-xs-offset-0').querySelectorAll('.row.enr-list-sec').length;
            for(let i=0; i<count; i++) {
                let row = document.querySelectorAll('.row.enr-list-sec')[i];
                let dialog = row.querySelector('.table');
                let name = row.querySelector('h3').innerText.trim();
                let department = row.querySelector('.col-sm-3.text-center.enr-list-dep-nam.hidden-xs').title.split('：')[1].trim();
                let state = row.querySelector('.badge.alert-danger').innerText.trim();
                if (state === '活動已結束') {count--;skip++;continue;}
                let targets = row.querySelector('.fa-id-badge').parentElement.innerText.trim();
                if (!targets.includes('本校在校生')) {count--;skip++;continue;}
                let eventSerialID = row.querySelector('p').innerText.split('：')[1].split(' ')[0].trim();
                let eventTime = row.querySelector('.fa-calendar').parentElement.innerText.replace(/\\s+/g,'').replace('~','起\\n')+'止'.trim();
                let eventLocation = row.querySelector('.fa-map-marker').parentElement.innerText.trim();
                let eventRegisterTime = row.querySelector('.table').querySelectorAll('tr')[9].querySelectorAll('td')[1].textContent.replace(/\\s+/g,'').replace('~','起\\n')+'止'.trim();
                let eventDetail = dialog.querySelectorAll('tr')[3].querySelectorAll('td')[1]
                    .innerHTML
                    .replace(/<br\\s*\\/?>/gi, '\\n')
                    .replace(/&nbsp;/gi, ' ')
                    .replace(/<[^>]*>/g, '')
                    .replace('\"','')
                    .trim();
                let contactInfoText = dialog.querySelectorAll('tr')[5].querySelectorAll('td')[1].innerHTML;
                let contactInfos = contactInfoText.split('<br>').map(function(info) {
                    return info.replace(/<[^>]*>/g,'').trim();
                });
                let Related_links = dialog.querySelectorAll('tr')[6].querySelectorAll('td')[1].textContent.replace(/\\s+/g,'').trim();
                let Remark = dialog.querySelectorAll('tr')[7].querySelectorAll('td')[1].textContent.replace(/\\s+/g,'').replace('<br>','\\n').replace('\"','').trim();
                let Multi_factor_authentication = dialog.querySelectorAll('tr')[8].querySelectorAll('td')[1].textContent.replace(/\\s+/g,'').replace('<br>','\\n').replace('已認證，','').replace('\"','').trim();
                let eventPeople = row.querySelector('.fa-user-plus').parentElement.innerText.replace(/\\s+/g,'').replace('，','人\\n')+'人'.trim();
                data[i-skip] = {name, department, event_state: state, eventSerialID, eventTime, eventLocation, eventRegisterTime, eventDetail, contactInfoName: contactInfos[0], contactInfoTel: contactInfos[1], contactInfoMail: contactInfos[2], Related_links, Remark, Multi_factor_authentication, eventPeople};
            }
            return JSON.stringify(data);
        })();
        """
    
    init() {
        setupWebView()
        
        // 不要立即登入，等到 View 出現時再檢查
        
        // 監聽報名相關通知
        let submitObserver = NotificationCenter.default.addObserver(
            forName: .didSubmitEventRegistration,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.loadEventList()
            }
        }
        notificationObservers.append(submitObserver)
        
        let changeObserver = NotificationCenter.default.addObserver(
            forName: .didChangeEventRegistration,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.loadEventList()
            }
        }
        notificationObservers.append(changeObserver)
    }
    
    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
    }
    
    /// 當 Tab1 View 出現時調用此方法
    func onViewAppear() {
        prewarmLoginIfNeeded()
    }

    /// 供外部在頁面剛開啟時先行觸發登入，避免切換到本分頁時才發現登入過期
    func prewarmLoginIfNeeded() {
        if !hasInitialized {
            hasInitialized = true
            startLogin()
        }
    }
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        // 使用共享的 DataStore，讓所有 Tab 共享 Cookie
        config.websiteDataStore = EventRegistrationWebViewManager.shared.dataStore
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView?.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        
        navigationDelegate = NavigationDelegate(viewModel: self)
        webView?.navigationDelegate = navigationDelegate
    }
    
    func startLogin() {
        isOverlayVisible = true
        overlayText = "載入中"
        loginAttemptCount = 0
        resetLoginProgress()
        
        // 直接訪問活動列表頁面，如果未登入會自動重定向到登入頁
        if let url = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Act") {
            let request = URLRequest(url: url)
            webView?.load(request)
        }
    }
    
    func loadEventList() {
        isOverlayVisible = true
        overlayText = "載入中"
        loginAttemptCount = 0  // 重置登入狀態，允許重新登入
        resetLoginProgress()
        
        if let url = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Act") {
            let request = URLRequest(url: url)
            webView?.load(request)
        }
    }

    private func resetLoginProgress() {
        loginRecoveryWorkItem?.cancel()
        loginRecoveryWorkItem = nil
        isSubmittingLogin = false
        loginSubmitTimestamp = nil
        loginFieldRetryCount = 0
        loginPageReloadCount = 0
        emptyLoginDOMCount = 0
    }

    private func loadCanonicalLoginPage() {
        if let loginURL = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Account/Login?ReturnUrl=%2FMvcTeam%2FAct") {
            webView?.load(URLRequest(url: loginURL))
        }
    }

    private func recreateWebViewForLoginRecovery() {
        print("[EventRegistration] 偵測到空白登入 DOM，重建 WebView 後重試")
        setupWebView()
    }

    private func scheduleLoginRecoveryIfNeeded() {
        guard isSubmittingLogin else { return }
        loginRecoveryWorkItem?.cancel()

        let elapsed: TimeInterval
        if let submitTime = loginSubmitTimestamp {
            elapsed = Date().timeIntervalSince(submitTime)
        } else {
            elapsed = 0
        }

        let waitTime = max(0.2, loginSubmitCooldown - elapsed + 0.1)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.loginRecoveryWorkItem = nil
            guard self.isSubmittingLogin else { return }
            guard let currentURL = self.webView?.url?.absoluteString,
                  currentURL.contains("/MvcTeam/Account/Login") else {
                return
            }

            print("[EventRegistration] 登入提交後仍停留登入頁，觸發恢復流程")
            self.isSubmittingLogin = false
            self.checkLoginError()
        }

        loginRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + waitTime, execute: workItem)
    }
    
    // 手動刷新
    @MainActor
    func manualRefresh() async {
        EventRegistrationWebViewManager.shared.resetLoginState()
        loadEventList()
        
        // 等待刷新完成
        while isOverlayVisible {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 秒
        }
    }
    
    private func refresh() {
        // 延遲確保頁面完全載入
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.executeRefresh(retryCount: 0)
        }
    }
    
    private func executeRefresh(retryCount: Int) {
        webView?.evaluateJavaScript(jsGetData) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                print("[EventRegistration] JavaScript 執行錯誤: \(error)")
                
                // 重試最多 3 次
                if retryCount < 3 {
                    print("[EventRegistration] 重試 (\(retryCount + 1)/3)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.executeRefresh(retryCount: retryCount + 1)
                    }
                } else {
                    Task { @MainActor in
                        self.isOverlayVisible = false
                        self.toastMessage = "載入活動失敗，請重新整理"
                        self.showToast = true
                    }
                }
                return
            }
            
            if let jsonString = result as? String {
                print("[EventRegistration] JSON 資料長度: \(jsonString.count)")
                
                do {
                    guard let jsonData = jsonString.data(using: .utf8) else {
                        throw NSError(domain: "EventRegistration", code: -1, userInfo: [NSLocalizedDescriptionKey: "JSON 編碼失敗"])
                    }
                    if let jsonArray = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                        
                        // 如果沒有活動資料且重試次數未達上限，重試
                        if jsonArray.isEmpty && retryCount < 3 {
                            print("[EventRegistration] 沒有活動資料，重試 (\(retryCount + 1)/3)")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.executeRefresh(retryCount: retryCount + 1)
                            }
                            return
                        }
                        
                        let decodedEvents = jsonArray.compactMap { dict -> EventData? in
                            guard
                                let name = dict["name"] as? String,
                                let department = dict["department"] as? String,
                                let event_state = dict["event_state"] as? String,
                                let eventSerialID = dict["eventSerialID"] as? String,
                                let eventTime = dict["eventTime"] as? String,
                                let eventLocation = dict["eventLocation"] as? String,
                                let eventRegisterTime = dict["eventRegisterTime"] as? String,
                                let eventDetail = dict["eventDetail"] as? String,
                                let contactInfoName = dict["contactInfoName"] as? String,
                                let contactInfoTel = dict["contactInfoTel"] as? String,
                                let contactInfoMail = dict["contactInfoMail"] as? String,
                                let Related_links = dict["Related_links"] as? String,
                                let Remark = dict["Remark"] as? String,
                                let Multi_factor_authentication = dict["Multi_factor_authentication"] as? String,
                                let eventPeople = dict["eventPeople"] as? String
                            else { return nil }
                            
                            return EventData(
                                name: name,
                                department: department,
                                event_state: event_state,
                                eventSerialID: eventSerialID,
                                eventTime: eventTime,
                                eventLocation: eventLocation,
                                eventRegisterTime: eventRegisterTime,
                                eventDetail: eventDetail,
                                contactInfoName: contactInfoName,
                                contactInfoTel: contactInfoTel,
                                contactInfoMail: contactInfoMail,
                                Related_links: Related_links,
                                Multi_factor_authentication: Multi_factor_authentication,
                                eventPeople: eventPeople,
                                Remark: Remark
                            )
                        }
                        
                        Task { @MainActor in
                            self.events = decodedEvents
                            self.showPage()
                        }
                    }
                } catch {
                    print("JSON 解析錯誤: \(error)")
                }
            }
        }
    }
    
    private func showPage() {
        isOverlayVisible = false
    }
    
    // MARK: - Navigation Delegate
    class NavigationDelegate: NSObject, WKNavigationDelegate {
        weak var viewModel: EventRegistration_Tab1_ViewModel?
        
        init(viewModel: EventRegistration_Tab1_ViewModel) {
            self.viewModel = viewModel
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let viewModel = viewModel else { return }
            guard let url = webView.url?.absoluteString else { return }
            
            Task { @MainActor in
                viewModel.handlePageFinished(url: url)
            }
        }
    }
    
    private func handlePageFinished(url: String) {
        print("[EventRegistration] 頁面載入完成: \(url)")
        
        if url.contains("/MvcTeam/Account/Login") {
            // 被重定向到登入頁面，表示未登入，執行登入
            overlayText = "正在登入"
            if isSubmittingLogin,
               let submitTime = loginSubmitTimestamp,
               Date().timeIntervalSince(submitTime) < loginSubmitCooldown {
                print("[EventRegistration] 登入提交等待跳轉中，略過重入")
                scheduleLoginRecoveryIfNeeded()
                return
            }
            if isSubmittingLogin {
                print("[EventRegistration] 登入提交逾時仍在登入頁，重置提交狀態")
                isSubmittingLogin = false
            }
            checkLoginError()
        } else if url.contains("/MvcTeam/Act") && !url.contains("/Apply/") {
            // 活動列表頁面載入完成（可能是已登入直接顯示，或登入後跳轉）
            EventRegistrationWebViewManager.shared.completeLoginIfNeeded(requesterID: loginRequesterID)
            loginAttemptCount = 0  // 重置登入狀態
            resetLoginProgress()
            refresh()
        } else if url.contains("/Apply/") && isPostHandled {
            // 報名頁面載入完成，執行報名
            handleRegisterEvent(url: url)
        }
    }
    
    private func checkLoginError() {
        webView?.evaluateJavaScript("document.body.innerText") { [weak self] result, error in
            guard let self = self else { return }
            
            if let bodyText = result as? String {
                // 檢查是否有錯誤訊息
                if bodyText.contains("帳號或密碼錯誤") || bodyText.contains("登入失敗") {
                    Task { @MainActor in
                        self.isSubmittingLogin = false
                        self.isOverlayVisible = false
                        self.toastMessage = "帳號或密碼錯誤"
                        self.showToast = true
                    }
                    return
                }
            }
            
            // 檢查是否已達登入重試上限，避免無限循環
            if self.loginAttemptCount >= self.maxLoginAttempts {
                print("[EventRegistration] 已達登入重試上限，停止重試")
                Task { @MainActor in
                    self.isSubmittingLogin = false
                    self.isOverlayVisible = false
                    self.toastMessage = "登入失敗，請檢查帳號密碼"
                    self.showToast = true
                }
                return
            }
            
            // 沒有錯誤，請求登入
            EventRegistrationWebViewManager.shared.requestLogin(requesterID: self.loginRequesterID) { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.loginAttemptCount += 1
                    self.performEventSystemLogin()
                }
            } waitCompletion: { [weak self] in
                // 其他 tab 登入完成，直接重新加載頁面
                Task { @MainActor in
                    guard let self = self else { return }
                    print("[EventRegistration] 其他 tab 已完成登入，重新加載頁面")
                    self.loginAttemptCount = 0
                    self.resetLoginProgress()
                    if let url = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Act") {
                        let request = URLRequest(url: url)
                        self.webView?.load(request)
                    }
                }
            }
        }
    }
    
    private func performEventSystemLogin() {
        guard !isSubmittingLogin else {
            print("[EventRegistration] 登入提交進行中，略過重複提交")
            return
        }

        // 從 LoginRepository 取得帳號密碼
        guard let credentials = LoginRepository.shared.getSavedCredentials() else {
            isOverlayVisible = false
            toastMessage = "無法取得登入資訊"
            showToast = true
            return
        }
        
        overlayText = "正在登入活動系統"
        let escapedUsername = escapeForSingleQuotedJavaScript(credentials.username)
        let escapedPassword = escapeForSingleQuotedJavaScript(credentials.password)
        isSubmittingLogin = true
        loginSubmitTimestamp = Date()
        
        // 延遲確保頁面載入完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            // 填入帳號密碼並提交
            let loginScript = """
            (function() {
                if (window.location.href.indexOf('/MvcTeam/Account/Login') === -1) {
                    return 'not_login_page';
                }

                function pick(selectors) {
                    for (var i = 0; i < selectors.length; i++) {
                        var el = document.querySelector(selectors[i]);
                        if (el) { return el; }
                    }
                    return null;
                }

                var usernameField = pick([
                    'input[name="Account"]',
                    '#Account',
                    'input[id*="Account"]',
                    'input[name*="account" i]',
                    'input[type="text"]',
                    'input[type="email"]'
                ]);
                var passwordField = pick([
                    'input[name="Password"]',
                    '#Password',
                    'input[id*="Password"]',
                    'input[name*="password" i]',
                    'input[type="password"]'
                ]);

                if (!usernameField || !passwordField) {
                    var pwdCount = document.querySelectorAll('input[type="password"]').length;
                    var inputCount = document.querySelectorAll('input').length;
                    var formCount = document.querySelectorAll('form').length;
                    return 'missing_fields|ready=' + document.readyState + '|forms=' + formCount + '|inputs=' + inputCount + '|pwd=' + pwdCount + '|url=' + window.location.href;
                }

                usernameField.focus();
                usernameField.value = '\(escapedUsername)';
                usernameField.dispatchEvent(new Event('input', { bubbles: true }));
                usernameField.dispatchEvent(new Event('change', { bubbles: true }));

                passwordField.focus();
                passwordField.value = '\(escapedPassword)';
                passwordField.dispatchEvent(new Event('input', { bubbles: true }));
                passwordField.dispatchEvent(new Event('change', { bubbles: true }));

                var form = usernameField.closest('form') || passwordField.closest('form') || document.querySelector('form');
                if (form) {
                    if (typeof form.requestSubmit === 'function') {
                        form.requestSubmit();
                    } else {
                        form.submit();
                    }
                    return 'submitted';
                }

                var submitBtn = pick([
                    'button[type="submit"]',
                    'input[type="submit"]',
                    'button.btn-primary',
                    'button'
                ]);
                if (submitBtn) {
                    submitBtn.click();
                    return 'submitted';
                }

                return 'missing_submit';
            })();
            """
            
            self.webView?.evaluateJavaScript(loginScript) { result, error in
                Task { @MainActor in
                    if let resultString = result as? String {
                        print("[EventRegistration] 登入提交結果: \(resultString)")

                        let isMissingFields = resultString.hasPrefix("missing_fields")
                        let isMissingSubmit = resultString.hasPrefix("missing_submit")

                        switch resultString {
                        case "submitted":
                            self.loginFieldRetryCount = 0
                            self.loginPageReloadCount = 0
                            self.emptyLoginDOMCount = 0
                            self.scheduleLoginRecoveryIfNeeded()

                        case let value where isMissingFields || isMissingSubmit:
                            self.isSubmittingLogin = false
                            if isMissingFields,
                               value.contains("|forms=0|"),
                               value.contains("|inputs=0|") {
                                self.emptyLoginDOMCount += 1
                                if self.emptyLoginDOMCount >= self.maxEmptyLoginDOMBeforeRecreate {
                                    self.emptyLoginDOMCount = 0
                                    self.loginFieldRetryCount = 0
                                    self.recreateWebViewForLoginRecovery()
                                    self.loadCanonicalLoginPage()
                                    return
                                }
                            } else {
                                self.emptyLoginDOMCount = 0
                            }

                            if self.loginFieldRetryCount < self.maxLoginFieldRetries {
                                self.loginFieldRetryCount += 1
                                if isMissingFields {
                                    print("[EventRegistration] 登入欄位未就緒詳情: \(value)")
                                }
                                print("[EventRegistration] 登入欄位未就緒，等待重試 (\(self.loginFieldRetryCount)/\(self.maxLoginFieldRetries))")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    self.performEventSystemLogin()
                                }
                            } else if self.loginPageReloadCount < self.maxLoginPageReloads {
                                self.loginPageReloadCount += 1
                                self.loginFieldRetryCount = 0
                                print("[EventRegistration] 登入頁疑似未完整載入，重新載入固定登入頁 (\(self.loginPageReloadCount)/\(self.maxLoginPageReloads))")
                                self.loadCanonicalLoginPage()
                            } else {
                                self.isOverlayVisible = false
                                self.toastMessage = "登入頁面載入失敗"
                                self.showToast = true
                            }

                        case "not_login_page":
                            self.isSubmittingLogin = false
                            if let url = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Act") {
                                self.webView?.load(URLRequest(url: url))
                            }

                        default:
                            self.isSubmittingLogin = false
                            self.loadCanonicalLoginPage()
                        }
                    } else if let error = error {
                        print("[EventRegistration] 登入錯誤: \(error)")
                        self.isSubmittingLogin = false
                        self.isOverlayVisible = false
                        self.toastMessage = "登入失敗"
                        self.showToast = true
                    }
                }
            }
        }
    }
    
    // MARK: - 報名功能
    func registerEvent(eventID: String) {
        isOverlayVisible = true
        overlayText = "正在報名"
        selectedEventID = eventID
        isPostHandled = true
        
        if let url = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Act/Apply/\(eventID)") {
            let request = URLRequest(url: url)
            webView?.load(request)
        }
    }
    
    private func handleRegisterEvent(url: String) {
        // 延遲一下確保頁面 DOM 完全載入
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            // 先檢查是否需要登入
            self.webView?.evaluateJavaScript("document.body.innerText") { result, error in
                if let bodyText = result as? String {
                    // 如果頁面包含登入相關文字，說明 Session 過期
                    if bodyText.contains("登入") || bodyText.contains("帳號") {
                        Task { @MainActor in
                            self.isOverlayVisible = false
                            self.toastMessage = "登入已過期，請重新啟動 App"
                            self.showToast = true
                        }
                        return
                    }
                }
                
                // 嘗試取得驗證碼
                self.webView?.evaluateJavaScript("document.querySelector('[name=\"__RequestVerificationToken\"]')?.value") { [weak self] result, error in
                    guard let self = self else { return }
                    
                    if let error = error {
                        print("[EventRegistration] JavaScript 錯誤: \(error)")
                    }
                    
                    if let token = result as? String, !token.isEmpty {
                        Task { @MainActor in
                            self.submitRegistration(token: token, eventID: self.selectedEventID ?? "", postURL: url)
                        }
                    } else {
                        print("[EventRegistration] 無法取得驗證碼，result: \(String(describing: result))")
                        Task { @MainActor in
                            self.isOverlayVisible = false
                            self.toastMessage = "頁面載入失敗，請稍後再試"
                            self.showToast = true
                            self.loadEventList()
                        }
                    }
                }
            }
        }
    }
    
    private func submitRegistration(token: String, eventID: String, postURL: String) {
        guard let url = URL(string: postURL) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "__RequestVerificationToken", value: token),
            URLQueryItem(name: "id", value: eventID),
            URLQueryItem(name: "action", value: "我要報名")
        ]
        
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        
        webView?.load(request)
        
        checkRegistrationStatus()
    }
    
    private func checkRegistrationStatus() {
        isPostHandled = false
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            
            // 檢查頁面內容確認報名狀態
            self.webView?.evaluateJavaScript("""
                (function() {
                    // 檢查是否有「已報名」或「報名成功」的文字
                    var bodyText = document.body.innerText;
                    if (bodyText.includes('已報名') || bodyText.includes('報名成功')) {
                        return 'success';
                    }
                    // 檢查是否有錯誤訊息
                    if (bodyText.includes('報名失敗') || bodyText.includes('錯誤') || bodyText.includes('已額滿')) {
                        return 'failed';
                    }
                    return 'unknown';
                })();
            """) { result, error in
                Task { @MainActor in
                    if let status = result as? String {
                        print("[EventRegistration] 報名狀態: \(status)")
                        
                        if status == "success" {
                            // 報名成功
                            self.isOverlayVisible = false
                            self.toastMessage = "報名成功"
                            self.showToast = true
                            
                            // 通知兩個分頁更新
                            NotificationCenter.default.post(name: .didSubmitEventRegistration, object: nil)
                            
                            // 延遲重新載入，讓用戶看到成功訊息
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                self.loadEventList()
                            }
                        } else if status == "failed" {
                            // 報名失敗
                            self.isOverlayVisible = false
                            self.toastMessage = "報名失敗，請稍後再試"
                            self.showToast = true
                            self.loadEventList()
                        } else {
                            // 狀態不明，繼續等待
                            self.checkRegistrationStatus()
                        }
                    } else {
                        // 無法取得狀態，假設成功並重新載入
                        print("[EventRegistration] 無法確認報名狀態，重新載入")
                        self.isOverlayVisible = false
                        NotificationCenter.default.post(name: .didSubmitEventRegistration, object: nil)
                        self.loadEventList()
                    }
                }
            }
        }
    }
}
