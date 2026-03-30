import Foundation
import WebKit

/// 管理活動報名 WebView 的共享配置，確保所有 Tab 共享登入狀態
final class EventRegistrationWebViewManager {
    static let shared = EventRegistrationWebViewManager()
    
    let dataStore: WKWebsiteDataStore
    
    // 登入狀態管理
    private var isLoggingIn = false
    private var activeLoginRequesterID: String?
    private var loginCompletionHandlers: [() -> Void] = []
    
    private init() {
        // 使用 default data store 確保與系統共享 Cookie
        dataStore = .default()
    }
    
    /// 請求登入，如果已經有其他 Tab 在登入，則等待其完成
    /// - Parameters:
    ///   - requesterID: 請求來源（通常是各 tab 的唯一 ID）
    ///   - loginAction: 執行登入的閉包（只有第一個請求會執行）
    ///   - waitCompletion: 等待其他 tab 登入完成後執行的閉包（第二個及之後的請求會執行）
    func requestLogin(
        requesterID: String,
        loginAction: @escaping () -> Void,
        waitCompletion: @escaping () -> Void
    ) {
        if isLoggingIn {
            // 同一個 tab 在登入流程中再次回到登入頁，允許直接重試，避免把自己鎖死在等待佇列
            if activeLoginRequesterID == requesterID {
                print("[EventRegistration] 同一個 tab 重新嘗試登入 requester=\(requesterID)")
                loginAction()
                return
            }

            // 已經有其他 Tab 在登入，等待完成後執行 waitCompletion
            print("[EventRegistration] 已有其他 tab 在登入，等待完成 requester=\(requesterID), active=\(activeLoginRequesterID ?? "nil")")
            loginCompletionHandlers.append(waitCompletion)
        } else {
            // 開始登入
            print("[EventRegistration] 開始執行登入 requester=\(requesterID)")
            isLoggingIn = true
            activeLoginRequesterID = requesterID
            loginAction()
        }
    }
    
    /// 只要任一 tab 已到達可視為登入成功的頁面，就可結束登入鎖，避免跨 tab 卡死
    func completeLoginIfNeeded(requesterID: String) {
        guard isLoggingIn else { return }
        print("[EventRegistration] 收到登入完成訊號 requester=\(requesterID), active=\(activeLoginRequesterID ?? "nil")")
        notifyLoginCompleted()
    }

    /// 通知登入完成
    func notifyLoginCompleted() {
        print("[EventRegistration] 登入完成，通知其他等待的 tab")
        isLoggingIn = false
        activeLoginRequesterID = nil
        let handlers = loginCompletionHandlers
        loginCompletionHandlers.removeAll()
        
        // 稍微延遲讓 Cookie 寫入完成，避免不必要的等待
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            print("[EventRegistration] 執行 \(handlers.count) 個等待的 completion handler")
            handlers.forEach { $0() }
        }
    }
    
    /// 重置登入狀態（用於用戶手動刷新）
    func resetLoginState() {
        isLoggingIn = false
        activeLoginRequesterID = nil
        loginCompletionHandlers.removeAll()
    }
    
    /// 清除所有 Cookie 和快取
    func clearData() async {
        await dataStore.httpCookieStore.allCookies()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast)
    }
}
