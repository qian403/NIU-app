import SwiftUI
import WebKit

struct ModifyRegistrationView: View {
    let event: EventData_Apply
    @Environment(\.dismiss) private var dismiss
    let onSubmit: (EventInfo) -> Void
    let onCancel: (String) -> Void
    
    @State private var tel = ""
    @State private var mail = ""
    @State private var selectedFood = "3"  // "1"=葷食 "2"=素食 "3"=不用餐
    @State private var selectedProof = "1" // "1"=不需要 "2"=參加證明 "3"=公務人員學習時數
    @State private var remark = ""
    
    @State private var role = ""
    @State private var classes = ""
    @State private var schnum = ""
    @State private var name = ""
    @State private var tokenValue = ""
    @State private var signId = ""
    @State private var isLoading = true
    @State private var webView: WKWebView?
    @State private var webViewDelegate: WebViewLoadDelegate?
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("活動資訊")) {
                    HStack {
                        Text("活動名稱")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(event.name)
                            .fontWeight(.semibold)
                    }
                    
                    HStack {
                        Text("主辦單位")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(event.department)
                            .fontWeight(.semibold)
                    }
                }
                
                if !isLoading {
                    Section(header: Text("基本資訊（展示用）")) {
                        HStack {
                            Text("身份")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(role.isEmpty ? "-" : role)
                                .fontWeight(.semibold)
                        }
                        
                        HStack {
                            Text("班級")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(classes.isEmpty ? "-" : classes)
                                .fontWeight(.semibold)
                        }
                        
                        HStack {
                            Text("學號")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(schnum.isEmpty ? "-" : schnum)
                                .fontWeight(.semibold)
                        }
                        
                        HStack {
                            Text("姓名")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(name.isEmpty ? "-" : name)
                                .fontWeight(.semibold)
                        }
                    }
                    
                    Section(header: Text("聯絡資訊")) {
                        HStack {
                            Text("電話")
                            Spacer()
                            TextField("請輸入電話", text: $tel)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.phonePad)
                        }
                        
                        HStack {
                            Text("信箱")
                            Spacer()
                            TextField("請輸入信箱", text: $mail)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                        }
                    }
                    
                    Section(header: Text("飲食習慣")) {
                        Picker("飲食習慣", selection: $selectedFood) {
                            Text("不用餐").tag("3")
                            Text("葷食").tag("1")
                            Text("素食").tag("2")
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Section(header: Text("活動認證")) {
                        Picker("活動認證", selection: $selectedProof) {
                            Text("不需要").tag("1")
                            Text("參加證明").tag("2")
                            Text("公務人員學習時數").tag("3")
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Section(header: Text("備註（選填）")) {
                        TextEditor(text: $remark)
                            .frame(minHeight: 80)
                    }
                } else {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Text("載入報名資訊...")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
                
                if !isLoading {
                    Section {
                        Button(action: {
                            submitModification()
                        }) {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                Text("儲存修改")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .disabled(!isFormValid)
                        
                        Button(role: .destructive, action: {
                            onCancel(event.eventSerialID)
                            dismiss()
                        }) {
                            HStack {
                                Spacer()
                                Image(systemName: "xmark.circle.fill")
                                Text("取消報名")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("修改報名資訊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("放棄修改") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadRegistrationInfo()
            }
        }
    }
    
    private var isFormValid: Bool {
        !tel.isEmpty && !mail.isEmpty && !isLoading
    }
    
    private func loadRegistrationInfo() {
        isLoading = true
        
        let urlString = "https://ccsys.niu.edu.tw/MvcTeam/Act/RegData/\(event.eventSerialID)"
        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }
        
        // 使用 WKWebView 載入頁面
        let webViewConfig = WKWebViewConfiguration()
        webViewConfig.websiteDataStore = EventRegistrationWebViewManager.shared.dataStore
        
        let tmpWebView = WKWebView(frame: CGRect(x: -9999, y: -9999, width: 1, height: 1), configuration: webViewConfig)
        
        // 設置代理
        let delegate = WebViewLoadDelegate(callback: { [self] in
            DispatchQueue.main.async {
                self.extractFormDataFromWebView(tmpWebView)
            }
        })
        tmpWebView.navigationDelegate = delegate
        webViewDelegate = delegate  // 保留強引用
        
        // 載入頁面
        tmpWebView.load(URLRequest(url: url))
    }
    
    private func extractFormDataFromWebView(_ webView: WKWebView) {
        // 頁面已經在 didFinish 中加載完成，直接提取值
        
        // 提取 SignTEL 值
        let jsTel = """
        document.querySelector('input[name="SignTEL"]') ? document.querySelector('input[name="SignTEL"]').value : 'NOT_FOUND'
        """
        webView.evaluateJavaScript(jsTel) { res, err in
            if let tel = res as? String {
                DispatchQueue.main.async {
                    self.tel = tel == "NOT_FOUND" ? "" : tel
                }
            }
        }
        
        // 提取 SignEmail 值
        let jsEmail = """
        document.querySelector('input[name="SignEmail"]') ? document.querySelector('input[name="SignEmail"]').value : 'NOT_FOUND'
        """
        webView.evaluateJavaScript(jsEmail) { res, err in
            if let email = res as? String {
                DispatchQueue.main.async {
                    self.mail = email == "NOT_FOUND" ? "" : email
                }
            }
        }
        
        // 提取 SignMemo 值
        let jsMemo = """
        document.querySelector('textarea[name="SignMemo"]') ? document.querySelector('textarea[name="SignMemo"]').value : 'NOT_FOUND'
        """
        webView.evaluateJavaScript(jsMemo) { res, err in
            if let memo = res as? String {
                DispatchQueue.main.async {
                    self.remark = memo == "NOT_FOUND" ? "" : memo
                }
            }
        }
        
        // 提取選中的 Food 值
        let jsFood = """
        (function() {
            var radios = document.querySelectorAll('input[name="Food"]');
            for(var i = 0; i < radios.length; i++) {
                if(radios[i].checked) return radios[i].value;
            }
            return '3';
        })()
        """
        webView.evaluateJavaScript(jsFood) { res, err in
            if let food = res as? String {
                DispatchQueue.main.async {
                    self.selectedFood = food
                }
            }
        }
        
        // 提取選中的 Proof 值
        let jsProof = """
        (function() {
            var radios = document.querySelectorAll('input[name="Proof"]');
            for(var i = 0; i < radios.length; i++) {
                if(radios[i].checked) return radios[i].value;
            }
            return '1';
        })()
        """
        webView.evaluateJavaScript(jsProof) { res, err in
            if let proof = res as? String {
                DispatchQueue.main.async {
                    self.selectedProof = proof
                }
            }
        }
        
        // 提取隱藏字段
        let jsToken = """
        document.querySelector('input[name="__RequestVerificationToken"]') ? document.querySelector('input[name="__RequestVerificationToken"]').value : 'NOT_FOUND'
        """
        webView.evaluateJavaScript(jsToken) { res, err in
            if let token = res as? String {
                DispatchQueue.main.async {
                    self.tokenValue = token == "NOT_FOUND" ? "" : token
                }
            }
        }
        
        let jsSignId = """
        document.querySelector('input[name="SignId"]') ? document.querySelector('input[name="SignId"]').value : 'NOT_FOUND'
        """
        webView.evaluateJavaScript(jsSignId) { res, err in
            if let id = res as? String {
                DispatchQueue.main.async {
                    self.signId = id == "NOT_FOUND" ? "" : id
                }
            }
        }
        
        // 最後提取唯讀信息
        let jsInfo = """
        (function() {
            var result = {};
            // 尋找包含「身分」的文本
            document.querySelectorAll('label, div, span, p').forEach(function(el) {
                var text = el.textContent.trim();
                if(text.startsWith('本校在校生') || text.startsWith('校外人士')) {
                    result.role = text;
                }
                if(text.match(/^(大學|專科)/)) {
                    result.classes = text;
                }
                if(text.match(/^[A-Z][0-9]{7}$/)) {
                    result.schnum = text;
                }
                if(text.length > 2 && text.length < 10 && !text.includes(' ') && el.textContent.match(/[\\u4e00-\\u9fa5]/)) {
                    // 可能是姓名，但需要判斷上下文
                    if(el.previousElementSibling && el.previousElementSibling.textContent.includes('姓名')) {
                        result.name = text;
                    }
                }
            });
            return JSON.stringify(result);
        })()
        """
        webView.evaluateJavaScript(jsInfo) { res, err in
            if let jsonStr = res as? String,
               let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                DispatchQueue.main.async {
                    self.role = dict["role"] ?? ""
                    self.classes = dict["classes"] ?? ""
                    self.schnum = dict["schnum"] ?? ""
                    self.name = dict["name"] ?? ""
                    self.isLoading = false
                }
            } else {
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }
    }
    
    private func submitModification() {
        let eventInfo = EventInfo(
            RequestVerificationToken: tokenValue,
            SignId: signId,
            role: role,
            classes: classes,
            schnum: schnum,
            name: name,
            Tel: tel,
            Mail: mail,
            selectedFood: selectedFood,
            selectedProof: selectedProof,
            Remark: remark
        )
        
        onSubmit(eventInfo)
        dismiss()
    }
}

// MARK: - WebViewLoadDelegate
class WebViewLoadDelegate: NSObject, WKNavigationDelegate {
    let callback: () -> Void
    
    init(callback: @escaping () -> Void) {
        self.callback = callback
        super.init()
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[ModifyRegistration] WebView 頁面載入完成")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.callback()
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[ModifyRegistration] WebView 載入失敗: \(error)")
    }
}
