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
    
    // 登入狀態追蹤
    private var hasAttemptedLogin = false
    private var hasInitialized = false
    
    // JavaScript 抓取已報名活動列表
    private let jsGetData: String = """
        (function() { 
            var data = []; 
            var count = document.querySelector('.col-md-11.col-md-offset-1.col-sm-10.col-xs-12.col-xs-offset-0').querySelectorAll('.row.enr-list-sec').length;
            for(let i=0; i<count; i++) {
                let row = document.querySelectorAll('.row.enr-list-sec')[i];
                let row_state = document.querySelectorAll('.row.bg-warning')[i];
                let dialog = row.querySelector('.table');
                let name = row.querySelector('h3').innerText.trim();
                let department = row.querySelector('.col-sm-3.text-center.enr-list-dep-nam.hidden-xs').title.split('：')[1].trim();
                let state = row_state.querySelector('.text-danger.text-shadow').innerText.split('：')[1].trim();
                let event_state = row.querySelector('.btn.btn-danger').innerText.trim();
                let eventSerialID = row.querySelector('p').innerText.split('：')[1].split(' ')[0].trim();
                let eventTime = row.querySelector('.fa-calendar').parentElement.innerText.replace(/\\s+/g,'').replace('~','起\\n')+'止'.trim();
                let eventLocation = row.querySelector('.fa-map-marker').parentElement.innerText.trim();
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
                let Multi_factor_authentication = dialog.querySelectorAll('tr')[8].querySelectorAll('td')[1].textContent.replace(/\\s+/g,'').replace('<br>','\\n').replace('\"','').trim();
                let eventRegisterTime = dialog.querySelectorAll('tr')[9].querySelectorAll('td')[1].textContent.replace(/\\s+/g,'').replace('~','~\\n').trim();
                data[i] = {name, department, state, event_state, eventSerialID, eventTime, eventLocation, eventDetail, contactInfoName: contactInfos[0], contactInfoTel: contactInfos[1], contactInfoMail: contactInfos[2], Related_links, Remark, Multi_factor_authentication, eventRegisterTime};
            }
            return JSON.stringify(data);
        })();
        """
    
    init() {
        setupWebView()
        
        // 不要立即登入，等到 View 出現時再檢查
        
        // 監聽報名相關通知
        NotificationCenter.default.addObserver(
            forName: .didSubmitEventRegistration,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.loadEventList()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .didChangeEventRegistration,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.loadEventList()
            }
        }
    }
    
    /// 當 Tab2 View 出現時調用此方法
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
    
    deinit {
        NotificationCenter.default.removeObserver(self)
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
        hasAttemptedLogin = false
        
        // 直接訪問已報名列表頁面，如果未登入會自動重定向到登入頁
        if let url = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Act/ApplyMe") {
            let request = URLRequest(url: url)
            webView?.load(request)
        }
    }
    
    func loadEventList() {
        isOverlayVisible = true
        overlayText = "載入中"
        hasAttemptedLogin = false  // 重置登入狀態，允許重新登入
        
        if let url = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Act/ApplyMe") {
            let request = URLRequest(url: url)
            webView?.load(request)
        }
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
                    let jsonData = jsonString.data(using: .utf8)!
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
            // 被重定向到登入頁面，表示未登入，執行登入
            overlayText = "正在登入"
            checkLoginError()
        } else if url.contains("/MvcTeam/Act/ApplyMe") {
            // 已報名列表頁面載入完成（可能是已登入直接顯示，或登入後跳轉）
            hasAttemptedLogin = false  // 重置登入狀態
            refresh()
        }
    }
    
    private func checkLoginError() {
        webView?.evaluateJavaScript("document.body.innerText") { [weak self] result, error in
            guard let self = self else { return }
            
            if let bodyText = result as? String {
                // 檢查是否有錯誤訊息
                if bodyText.contains("帳號或密碼錯誤") || bodyText.contains("登入失敗") {
                    Task { @MainActor in
                        self.isOverlayVisible = false
                        self.toastMessage = "帳號或密碼錯誤"
                        self.showToast = true
                    }
                    return
                }
            }
            
            // 檢查是否已經嘗試過登入，避免無限循環
            if self.hasAttemptedLogin {
                print("[EventRegistration Tab2] 已嘗試登入但失敗，停止重試")
                Task { @MainActor in
                    self.isOverlayVisible = false
                    self.toastMessage = "登入失敗，請檢查帳號密碼"
                    self.showToast = true
                }
                return
            }
            
            // 沒有錯誤，請求登入
            EventRegistrationWebViewManager.shared.requestLogin { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.hasAttemptedLogin = true
                    self.performEventSystemLogin()
                }
            } waitCompletion: { [weak self] in
                // 其他 tab 登入完成，直接重新加載頁面
                Task { @MainActor in
                    guard let self = self else { return }
                    print("[EventRegistration Tab2] 其他 tab 已完成登入，重新加載頁面")
                    self.hasAttemptedLogin = false
                    if let url = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Act/ApplyMe") {
                        let request = URLRequest(url: url)
                        self.webView?.load(request)
                    }
                }
            }
        }
    }
    
    private func performEventSystemLogin() {
        // 從 LoginRepository 取得帳號密碼
        guard let credentials = LoginRepository.shared.getSavedCredentials() else {
            isOverlayVisible = false
            toastMessage = "無法取得登入資訊"
            showToast = true
            return
        }
        
        overlayText = "正在登入活動系統"
        
        // 延遲確保頁面載入完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            // 填入帳號密碼並提交
            let loginScript = """
            (function() {
                var usernameField = document.querySelector('input[name="Account"]') || document.getElementById('Account');
                var passwordField = document.querySelector('input[name="Password"]') || document.getElementById('Password');
                
                if (usernameField && passwordField) {
                    usernameField.value = '\(credentials.username)';
                    passwordField.value = '\(credentials.password)';
                    
                    // 找到表單並提交
                    var form = usernameField.closest('form');
                    if (form) {
                        form.submit();
                        return 'submitted';
                    }
                }
                return 'failed';
            })();
            """
            
            self.webView?.evaluateJavaScript(loginScript) { result, error in
                Task { @MainActor in
                    if let resultString = result as? String {
                        print("[EventRegistration Tab2] 登入提交結果: \(resultString)")
                        if resultString == "submitted" {
                            // 通知其他 tab 登入已完成
                            EventRegistrationWebViewManager.shared.notifyLoginCompleted()
                        } else if resultString == "failed" {
                            self.isOverlayVisible = false
                            self.toastMessage = "登入頁面載入失敗"
                            self.showToast = true
                        }
                    } else if let error = error {
                        print("[EventRegistration Tab2] 登入錯誤: \(error)")
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
            if let jsonStr = result as? String,
               let data = jsonStr.data(using: .utf8),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("[EventRegistration Tab2] Cancel 頁面資訊: \(info)")
            }
            
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
        
        print("[EventRegistration] 修改請求正文: \(bodyString)")
        
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
