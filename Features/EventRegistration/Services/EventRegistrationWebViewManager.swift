import Foundation
import WebKit

/// 管理活動報名 WebView 的共享配置，確保所有 Tab 共享登入狀態
final class EventRegistrationWebViewManager {
    static let shared = EventRegistrationWebViewManager()
    
    let dataStore: WKWebsiteDataStore
    
    // 登入狀態管理
    private var isLoggingIn = false
    private var loginCompletionHandlers: [() -> Void] = []
    
    private init() {
        // 使用 default data store 確保與系統共享 Cookie
        dataStore = .default()
    }
    
    /// 請求登入，如果已經有其他 Tab 在登入，則等待其完成
    /// - Parameters:
    ///   - loginAction: 執行登入的閉包（只有第一個請求會執行）
    ///   - waitCompletion: 等待其他 tab 登入完成後執行的閉包（第二個及之後的請求會執行）
    func requestLogin(loginAction: @escaping () -> Void, waitCompletion: @escaping () -> Void) {
        if isLoggingIn {
            // 已經有其他 Tab 在登入，等待完成後執行 waitCompletion
            print("[EventRegistration] 已有其他 tab 在登入，等待完成")
            loginCompletionHandlers.append(waitCompletion)
        } else {
            // 開始登入
            print("[EventRegistration] 開始執行登入")
            isLoggingIn = true
            loginAction()
        }
    }
    
    /// 通知登入完成
    func notifyLoginCompleted() {
        print("[EventRegistration] 登入完成，通知其他等待的 tab")
        isLoggingIn = false
        let handlers = loginCompletionHandlers
        loginCompletionHandlers.removeAll()
        
        // 延遲 1 秒後通知其他等待的 Tab，確保 Cookie 已同步
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            print("[EventRegistration] 執行 \(handlers.count) 個等待的 completion handler")
            handlers.forEach { $0() }
        }
    }
    
    /// 重置登入狀態（用於用戶手動刷新）
    func resetLoginState() {
        isLoggingIn = false
        loginCompletionHandlers.removeAll()
    }
    
    /// 清除所有 Cookie 和快取
    func clearData() async {
        await dataStore.httpCookieStore.allCookies()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast)
    }
}
