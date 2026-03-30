import SwiftUI
import Combine
import WebKit

@MainActor
final class EventRegistration_Tab2_ViewModel: ObservableObject {
    
    // 狀態
    @Published var isOverlayVisible = true
    @Published var overlayText: String = "載入中"
    @Published var events: [EventData_Apply] = []
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""
    
    // 搜尋
    @Published var searchText: String = ""
    
    var filteredEvents: [EventData_Apply] {
        if searchText.isEmpty {
            return events
        } else {
            return events.filter { event in
                event.name.localizedCaseInsensitiveContains(searchText) ||
                event.department.localizedCaseInsensitiveContains(searchText) ||
                event.eventDetail.localizedCaseInsensitiveContains(searchText) ||
                event.state.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    // 選中的活動資訊
    @Published var selectedEventForDetail: EventData_Apply?
    @Published var selectedEventForModify: EventData_Apply?
    
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

    // JavaScript 抓取已報名活動列表
    private let jsGetData: String = """
        (function() { 
            var data = []; 
            var container = document.querySelector('.col-md-11.col-md-offset-1.col-sm-10.col-xs-12.col-xs-offset-0') || document;
            var rows = container.querySelectorAll('.row.enr-list-sec');
            var rowStates = document.querySelectorAll('.row.bg-warning');
            var count = rows.length;
            for(let i=0; i<count; i++) {
                let row = rows[i];
                let row_state = rowStates[i];
                let dialog = row.querySelector('.table');
                if (!row || !dialog) { continue; }
                let name = row.querySelector('h3') ? row.querySelector('h3').innerText.trim() : '';
                let departmentNode = row.querySelector('.col-sm-3.text-center.enr-list-dep-nam.hidden-xs');
                let department = departmentNode && departmentNode.title
                    ? (departmentNode.title.includes('：')
                        ? ((departmentNode.title.split('：')[1] || '').trim())
                        : (departmentNode.title.includes(':')
                            ? departmentNode.title.split(':')[1].trim()
                            : departmentNode.title.trim()))
                    : '';
                let stateNode = row_state ? row_state.querySelector('.text-danger.text-shadow') : null;
                let state = stateNode
                    ? (stateNode.innerText.includes('：')
                        ? ((stateNode.innerText.split('：')[1] || '').trim())
                        : (stateNode.innerText.includes(':')
                            ? stateNode.innerText.split(':')[1].trim()
                            : stateNode.innerText.trim()))
                    : '';
                let eventStateNode = row.querySelector('.btn.btn-danger');
                let event_state = eventStateNode ? eventStateNode.innerText.trim() : '';
                let eventSerialID = row.querySelector('p')
                    ? ((row.querySelector('p').innerText.includes('：')
                        ? (row.querySelector('p').innerText.split('：')[1] || '')
                        : (row.querySelector('p').innerText.includes(':')
                            ? row.querySelector('p').innerText.split(':')[1]
                            : row.querySelector('p').innerText))
                        .split(' ')[0].trim())
                    : '';
                let eventTime = row.querySelector('.fa-calendar') ? row.querySelector('.fa-calendar').parentElement.innerText.replace(/\\s+/g,'').replace('~','起\\n')+'止'.trim() : '';
                let eventLocation = row.querySelector('.fa-map-marker') ? row.querySelector('.fa-map-marker').parentElement.innerText.trim() : '';
                let eventDetail = dialog.querySelectorAll('tr')[3] && dialog.querySelectorAll('tr')[3].querySelectorAll('td')[1]
                    ? dialog.querySelectorAll('tr')[3].querySelectorAll('td')[1]
                        .innerHTML
                        .replace(/<br\\s*\\/?>/gi, '\\n')
                        .replace(/&nbsp;/gi, ' ')
                        .replace(/<[^>]*>/g, '')
                        .replace('"','')
                        .trim()
                    : '';
                let contactInfoText = dialog.querySelectorAll('tr')[5] && dialog.querySelectorAll('tr')[5].querySelectorAll('td')[1]
                    ? dialog.querySelectorAll('tr')[5].querySelectorAll('td')[1].innerHTML
                    : '';
                let contactInfos = contactInfoText ? contactInfoText.split('<br>').map(function(info) {
                    return info.replace(/<[^>]*>/g,'').trim();
                }) : ['', '', ''];
                let Related_links = dialog.querySelectorAll('tr')[6] && dialog.querySelectorAll('tr')[6].querySelectorAll('td')[1]
                    ? dialog.querySelectorAll('tr')[6].querySelectorAll('td')[1].textContent.replace(/\\s+/g,'').trim()
                    : '';
                let Remark = dialog.querySelectorAll('tr')[7] && dialog.querySelectorAll('tr')[7].querySelectorAll('td')[1]
                    ? dialog.querySelectorAll('tr')[7].querySelectorAll('td')[1].textContent.replace(/\\s+/g,'').replace('<br>','\\n').replace('"','').trim()
                    : '';
                let Multi_factor_authentication = dialog.querySelectorAll('tr')[8] && dialog.querySelectorAll('tr')[8].querySelectorAll('td')[1]
                    ? dialog.querySelectorAll('tr')[8].querySelectorAll('td')[1].textContent.replace(/\\s+/g,'').replace('<br>','\\n').replace('"','').trim()
                    : '';
                let eventRegisterTime = dialog.querySelectorAll('tr')[9] && dialog.querySelectorAll('tr')[9].querySelectorAll('td')[1]
                    ? dialog.querySelectorAll('tr')[9].querySelectorAll('td')[1].textContent.replace(/\\s+/g,'').replace('~','~\\n').trim()
                    : '';
                data[i] = {name, department, state, event_state, eventSerialID, eventTime, eventLocation, eventDetail, contactInfoName: contactInfos[0] || '', contactInfoTel: contactInfos[1] || '', contactInfoMail: contactInfos[2] || '', Related_links, Remark, Multi_factor_authentication, eventRegisterTime};
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
    
    /// 當 Tab2 View 出現時調用此方法
    func onViewAppear() {
        if !hasInitialized {
            prewarmLoginIfNeeded()
            return
        }

        // 若背景預熱期間失敗，切到本分頁時要主動重試，避免卡在舊狀態
        if events.isEmpty || isOverlayVisible {
            loadEventList()
        }
    }

    /// 供外部在頁面剛開啟時先行觸發登入，避免切換到本分頁時才發現登入過期
    func prewarmLoginIfNeeded() {
        if !hasInitialized {
            hasInitialized = true
            startLogin()
        }
    }
    
    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
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
    
    private func escapeForSingleQuotedJavaScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    func startLogin() {
        isOverlayVisible = true
        overlayText = "載入中"
        loginAttemptCount = 0
        resetLoginProgress()
        navigateToApplyMe()
    }

    func loadEventList() {
        isOverlayVisible = true
        overlayText = "載入中"
        loginAttemptCount = 0
        resetLoginProgress()
        navigateToApplyMe()
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

            print("[EventRegistration Tab2] 登入提交後仍停留登入頁，觸發恢復流程")
            self.isSubmittingLogin = false
            self.checkLoginError()
        }

        loginRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + waitTime, execute: workItem)
    }

    private func navigateToApplyMe() {
        if let url = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Act/ApplyMe") {
            webView?.load(URLRequest(url: url))
        }
    }

    private func loadCanonicalLoginPage() {
        if let loginURL = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Account/Login?ReturnUrl=%2FMvcTeam%2FAct%2FApplyMe") {
            webView?.load(URLRequest(url: loginURL))
        }
    }

    private func recreateWebViewForLoginRecovery() {
        print("[EventRegistration Tab2] 偵測到空白登入 DOM，重建 WebView 後重試")
        setupWebView()
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
                print("[EventRegistration Tab2] JavaScript 執行錯誤: \(error)")
                
                // 重試最多 3 次
                if retryCount < 3 {
                    print("[EventRegistration Tab2] 重試 (\(retryCount + 1)/3)")
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
                print("[EventRegistration Tab2] JSON 資料長度: \(jsonString.count)")
                
                do {
                    guard let jsonData = jsonString.data(using: .utf8) else {
                        throw NSError(domain: "EventRegistrationTab2", code: -1, userInfo: [NSLocalizedDescriptionKey: "JSON 編碼失敗"])
                    }
                    if let jsonArray = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                        
                        // 如果沒有活動資料且重試次數未達上限，重試
                        if jsonArray.isEmpty && retryCount < 3 {
                            print("[EventRegistration Tab2] 沒有活動資料，重試 (\(retryCount + 1)/3)")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.executeRefresh(retryCount: retryCount + 1)
                            }
                            return
                        }
                        
                        let decodedEvents = jsonArray.compactMap { dict -> EventData_Apply? in
                            guard
                                let name = dict["name"] as? String,
                                let department = dict["department"] as? String,
                                let state = dict["state"] as? String,
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
                                let Multi_factor_authentication = dict["Multi_factor_authentication"] as? String
                            else { return nil }
                            
                            return EventData_Apply(
                                name: name,
                                department: department,
                                state: state,
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
        weak var viewModel: EventRegistration_Tab2_ViewModel?
        
        init(viewModel: EventRegistration_Tab2_ViewModel) {
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
        print("[EventRegistration Tab2] 頁面載入完成: \(url)")

        if url.contains("/MvcTeam/Account/Login") {
            overlayText = "正在登入"
            if isSubmittingLogin,
               let submitTime = loginSubmitTimestamp,
               Date().timeIntervalSince(submitTime) < loginSubmitCooldown {
                print("[EventRegistration Tab2] 登入提交等待跳轉中，略過重入")
                scheduleLoginRecoveryIfNeeded()
                return
            }
            if isSubmittingLogin {
                print("[EventRegistration Tab2] 登入提交逾時仍在登入頁，重置提交狀態")
                isSubmittingLogin = false
            }
            checkLoginError()
        } else if url.contains("/MvcTeam/Act/ApplyMe") {
            EventRegistrationWebViewManager.shared.completeLoginIfNeeded(requesterID: loginRequesterID)
            loginAttemptCount = 0
            resetLoginProgress()
            refresh()
        } else if url.contains("/MvcTeam/Act") {
            // redirect 到 /MvcTeam/Act，導向已報名列表
            navigateToApplyMe()
        }
    }

    private func checkLoginError() {
        webView?.evaluateJavaScript("document.body.innerText") { [weak self] result, error in
            guard let self = self else { return }

            if let bodyText = result as? String {
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

            if self.loginAttemptCount >= self.maxLoginAttempts {
                Task { @MainActor in
                    self.isSubmittingLogin = false
                    self.isOverlayVisible = false
                    self.toastMessage = "登入失敗，請檢查帳號密碼"
                    self.showToast = true
                }
                return
            }

            EventRegistrationWebViewManager.shared.requestLogin(requesterID: self.loginRequesterID) { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.loginAttemptCount += 1
                    self.performEventSystemLogin()
                }
            } waitCompletion: { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    print("[EventRegistration Tab2] 其他 tab 已完成登入，重新加載頁面")
                    self.loginAttemptCount = 0
                    self.resetLoginProgress()
                    self.navigateToApplyMe()
                }
            }
        }
    }

    private func performEventSystemLogin() {
        guard !isSubmittingLogin else {
            print("[EventRegistration Tab2] 登入提交進行中，略過重複提交")
            return
        }

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

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
                        print("[EventRegistration Tab2] 登入提交結果: \(resultString)")

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
                                    print("[EventRegistration Tab2] 登入欄位未就緒詳情: \(value)")
                                }
                                print("[EventRegistration Tab2] 登入欄位未就緒，等待重試 (\(self.loginFieldRetryCount)/\(self.maxLoginFieldRetries))")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    self.performEventSystemLogin()
                                }
                            } else if self.loginPageReloadCount < self.maxLoginPageReloads {
                                self.loginPageReloadCount += 1
                                self.loginFieldRetryCount = 0
                                print("[EventRegistration Tab2] 登入頁疑似未完整載入，重新載入固定登入頁 (\(self.loginPageReloadCount)/\(self.maxLoginPageReloads))")
                                self.loadCanonicalLoginPage()
                            } else {
                                self.isOverlayVisible = false
                                self.toastMessage = "登入頁面載入失敗"
                                self.showToast = true
                            }

                        case "not_login_page":
                            self.isSubmittingLogin = false
                            self.navigateToApplyMe()

                        default:
                            self.isSubmittingLogin = false
                            self.loadCanonicalLoginPage()
                        }
                    } else if let error = error {
                        print("[EventRegistration Tab2] 登入錯誤: \(error)")
                        self.isSubmittingLogin = false
                        self.isOverlayVisible = false
                        self.toastMessage = "登入失敗"
                        self.showToast = true
                    }
                }
            }
        }
    }

    // MARK: - 取消報名
    func cancelRegistration(eventID: String) {
        isOverlayVisible = true
        overlayText = "正在取消報名"
        
        // 訪問 RegData 頁面（不是 Cancel 頁面）以獲得表單
        let regDataURL = "https://ccsys.niu.edu.tw/MvcTeam/Act/RegData/\(eventID)"
        guard let url = URL(string: regDataURL) else { return }
        let request = URLRequest(url: url)
        webView?.load(request)
        
        // 等待頁面載入後執行取消
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.executeCancelRegistration(eventID: eventID)
        }
    }
    
    private func executeCancelRegistration(eventID: String) {
        // 先檢查頁面結構
        webView?.evaluateJavaScript("""
            (function() {
                var info = {
                    url: window.location.href,
                    hasForm: !!document.querySelector('form'),
                    inputs: [],
                    bodyText: document.body.innerText.substring(0, 300)
                };
                
                // 獲取所有 input 名稱
                document.querySelectorAll('input').forEach(function(inp) {
                    info.inputs.push(inp.name + '=' + inp.value.substring(0, 20));
                });
                
                // 查找 token
                var tokenInput = document.querySelector('[name="__RequestVerificationToken"]');
                info.hasToken = !!tokenInput;
                
                // 如果沒有 token，試試其他選擇器
                if (!tokenInput) {
                    var allInputs = document.querySelectorAll('input[type="hidden"]');
                    info.hiddenInputs = allInputs.length;
                }
                
                // 找提交按鈕
                var submitBtn = document.querySelector('input[type="submit"]');
                info.hasSubmitBtn = !!submitBtn;
                if (submitBtn) {
                    info.submitValue = submitBtn.value;
                }
                
                return JSON.stringify(info);
            })();
        """) { [weak self] result, error in
            // 現在執行取消
            self?.performCancelSubmit(eventID: eventID)
        }
    }
    
    private func performCancelSubmit(eventID: String) {
        // 提取所有表單數據並提交
        webView?.evaluateJavaScript("""
            (function() {
                // 獲取 token 和其他必要字段
                var token = document.querySelector('[name="__RequestVerificationToken"]')?.value;
                var signId = document.querySelector('[name="SignId"]')?.value;
                var applyId = document.querySelector('[name="ApplyId"]')?.value;
                
                if (!token || !signId || !applyId) {
                    return JSON.stringify({
                        status: 'missing_fields',
                        token: !!token,
                        signId: !!signId,
                        applyId: !!applyId
                    });
                }
                
                // 找到取消按鈕並執行點擊提交
                var submitBtns = document.querySelectorAll('input[type="submit"]');
                for (var i = 0; i < submitBtns.length; i++) {
                    if (submitBtns[i].value.includes('取消')) {
                        // 找到取消按鈕，點擊它
                        submitBtns[i].click();
                        return JSON.stringify({status: 'submitted'});
                    }
                }
                
                return JSON.stringify({status: 'no_cancel_button'});
            })();
        """) { [weak self] result, error in
            if let jsonStr = result as? String,
               let data = jsonStr.data(using: .utf8),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = info["status"] as? String {
                print("[EventRegistration Tab2] 取消提交狀態: \(status)")
                
                if status == "submitted" {
                    // 等待結果
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self?.checkCancelStatus()
                    }
                } else {
                    Task { @MainActor in
                        self?.isOverlayVisible = false
                        self?.toastMessage = "取消報名失敗: \(status)"
                        self?.showToast = true
                        self?.loadEventList()
                    }
                }
            }
        }
    }
    
    private func checkCancelStatus() {
        // 檢查 URL 是否已改變（表示已提交且導向）
        webView?.evaluateJavaScript("""
            (function() {
                return {
                    url: window.location.href,
                    bodyText: document.body.innerText.substring(0, 500)
                };
            })();
        """) { [weak self] result, error in
            guard let self = self else { return }
            
            if let dict = result as? [String: Any],
               let url = dict["url"] as? String,
               let bodyText = dict["bodyText"] as? String {
                print("[EventRegistration Tab2] 取消後頁面: \(url)")
                
                // 檢查 URL 是否回到列表或其他頁面（說明提交成功）
                if url.contains("ApplyMe") || url.contains("Act") && !url.contains("RegData") {
                    // URL 已改變，說明表單已提交
                    Task { @MainActor in
                        self.isOverlayVisible = false
                        self.toastMessage = "取消報名成功"
                        self.showToast = true
                        
                        // 通知兩個分頁更新
                        NotificationCenter.default.post(name: .didChangeEventRegistration, object: nil)
                        
                        // 延遲重新載入
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.loadEventList()
                        }
                    }
                } else if bodyText.contains("取消成功") || bodyText.contains("已取消") || bodyText.contains("報名已取消") {
                    Task { @MainActor in
                        self.isOverlayVisible = false
                        self.toastMessage = "取消報名成功"
                        self.showToast = true
                        
                        NotificationCenter.default.post(name: .didChangeEventRegistration, object: nil)
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.loadEventList()
                        }
                    }
                } else if bodyText.contains("失敗") || bodyText.contains("錯誤") {
                    Task { @MainActor in
                        self.isOverlayVisible = false
                        self.toastMessage = "取消報名失敗"
                        self.showToast = true
                        self.loadEventList()
                    }
                } else {
                    // 繼續檢查
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.checkCancelStatus()
                    }
                }
            }
        }
    }
    
    // MARK: - 修改報名資訊
    func modifyRegistration(eventInfo: EventInfo) {
        isOverlayVisible = true
        overlayText = "正在修改報名資訊"
        
        // 構建修改請求到 RegData 頁面
        let modifyURL = "https://ccsys.niu.edu.tw/MvcTeam/Act/RegData/\(eventInfo.SignId)"
        guard let url = URL(string: modifyURL) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        
        // 正確構建 POST body
        var bodyParts: [String] = []
        bodyParts.append("__RequestVerificationToken=\(eventInfo.RequestVerificationToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        bodyParts.append("ApplyId=\(eventInfo.SignId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        bodyParts.append("SignId=\(eventInfo.SignId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        bodyParts.append("SignTEL=\(eventInfo.Tel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        bodyParts.append("SignEmail=\(eventInfo.Mail.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        bodyParts.append("SignMemo=\(eventInfo.Remark.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        bodyParts.append("Food=\(eventInfo.selectedFood)")
        bodyParts.append("Proof=\(eventInfo.selectedProof)")
        bodyParts.append("action=\(String(describing: "儲存修改").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        
        let bodyString = bodyParts.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)
        
        webView?.load(request)
        
        // 檢查修改結果
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.checkModifyStatus()
        }
    }
    
    private func checkModifyStatus() {
        webView?.evaluateJavaScript("""
            (function() {
                var bodyText = document.body.innerText;
                var bodyHTML = document.body.innerHTML;
                
                // 檢查是否顯示成功信息
                if (bodyText.includes('修改成功') || 
                    bodyText.includes('更新成功') || 
                    bodyText.includes('已更新') ||
                    bodyHTML.includes('alert-success') ||
                    bodyHTML.includes('成功')) {
                    return 'success';
                }
                
                // 檢查是否顯示失敗信息
                if (bodyText.includes('失敗') || 
                    bodyText.includes('錯誤') || 
                    bodyText.includes('error') ||
                    bodyHTML.includes('alert-danger')) {
                    return 'failed';
                }
                
                // 檢查是否返回到已報名列表（表示成功）
                if (bodyText.includes('已報名') && bodyText.includes('取消報名')) {
                    return 'success';
                }
                
                return 'pending';
            })();
        """) { [weak self] result, error in
            guard let self = self else { return }
            
            Task { @MainActor in
                if let status = result as? String {
                    print("[EventRegistration] 修改狀態: \(status)")
                    
                    if status == "success" {
                        self.isOverlayVisible = false
                        self.toastMessage = "修改成功"
                        self.showToast = true
                        
                        // 通知兩個分頁更新
                        NotificationCenter.default.post(name: .didChangeEventRegistration, object: nil)
                        
                        // 延遲重新載入
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.loadEventList()
                        }
                    } else if status == "failed" {
                        self.isOverlayVisible = false
                        self.toastMessage = "修改失敗，請重試"
                        self.showToast = true
                        self.loadEventList()
                    } else if status == "pending" {
                        // 繼續檢查
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.checkModifyStatus()
                        }
                    }
                } else if let error = error {
                    print("[EventRegistration] 檢查修改狀態錯誤: \(error)")
                    self.isOverlayVisible = false
                    self.toastMessage = "無法確認修改狀態"
                    self.showToast = true
                    self.loadEventList()
                }
            }
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let didSubmitEventRegistration = Notification.Name("didSubmitEventRegistration")
    static let didChangeEventRegistration = Notification.Name("didChangeEventRegistration")
}
