import Foundation
import WebKit

/// Drives the school's leave form inside a WebView kept under the native screen.
/// Login follows the enrollment flow: reuse acade cookies first, exchange one GUID
/// only when the school reports an expired session, and return to MainFrame from
/// the legacy portal landing page.
@MainActor
final class LeaveApplicationService: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var onDialog: ((String) -> Void)?
    var onConfirm: ((String, @escaping (Bool) -> Void) -> Void)?
    var onProgress: ((LeaveLoadStage) -> Void)?
    private var pendingConfirm: ((Bool) -> Void)?
    private var closed = false
    private var account = ""
    private var scripts: [UUID: CheckedContinuation<String, Error>] = [:]
    private var mainFrameReady = false
    private var sessionExpired = false
    private var navigationFailure: Error?
    private var navigationGeneration = UUID()
    /// When MainFrame.aspx committed; a fallback when a stuck subframe delays didFinish.
    private var mainFrameCommittedAt: ContinuousClock.Instant?
    /// From the start of a GUID bridge until a blank page replaces the expired document:
    /// that document's timers, alerts and redirects report the same lapse again.
    private var replacingDocument = false
    private var blankNavigation: WKNavigation?
    /// This service already refreshed the app's SSO login once; the caller must not repeat it.
    private(set) var refreshedLogin = false
    private let createdAt = ContinuousClock.now

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    private enum Read<T> { case waiting, expired, ready(T) }
    private var started = false
    /// One-shot approval for a school confirm the user already accepted natively (撤回).
    private var expectedConfirm: ((String) -> Bool)?

    /// 申請、修改或補檔: opens the matching school form and verifies it is the expected one.
    func load(account: String, entry: LeaveEntry = .apply) async throws -> LeavePage {
        self.account = account
        switch entry {
        case .apply:
            let page: LeavePage = try await open(LeaveSchoolPage.apply) {
                guard let page = try? await self.snapshot() else { return .waiting }
                if page.kind == "expired" { return .expired }
                guard ["notice", "form"].contains(page.kind) else { return .waiting }
                return .ready(page)
            }
            if page.kind == "form", ["MOD", "DETAIL"].contains(page.mode ?? "") { throw LeaveApplicationError.changed }
            return page
        case .modify(let formNo), .supplement(let formNo):
            let mode = { if case .modify = entry { return "MOD" } else { return "DETAIL" } }()
            let page = try await openRecord(formNo: formNo, listPath: LeaveSchoolPage.manage,
                                             listPage: LeaveSchoolPage.manageList, mode: mode)
            guard page.editable == (mode == "MOD") else { throw LeaveApplicationError.changed }
            return page
        }
    }

    /// 請假紀錄 (all forms) plus what 學生請假修改 allows for each.
    func loadRecords(account: String) async throws -> (records: [LeaveRecord], actions: [LeaveRecordActions]) {
        self.account = account
        let records = try await list(LeaveSchoolPage.records, listPage: LeaveSchoolPage.recordsList).records ?? []
        let actions = try await list(LeaveSchoolPage.manage, listPage: LeaveSchoolPage.manageList).actions ?? []
        return (records, actions)
    }

    /// Read-only detail of one form (Mode=DETAIL from 請假紀錄) with its 簽核流程.
    func loadDetail(account: String, formNo: String) async throws -> LeavePage {
        self.account = account
        var page = try await openRecord(formNo: formNo, listPath: LeaveSchoolPage.records,
                                        listPage: LeaveSchoolPage.recordsList, mode: "DETAIL")
        // The flow is extra: a failure here leaves the detail usable and shows its own notice.
        do {
            let text = try await run(LeaveApplicationScript.flow, arguments: ["formNo": formNo])
            let flow = try JSONDecoder().decode(LeaveApprovalFlow.self, from: Data(text.utf8))
            if flow.kind == "expired" { throw LeaveApplicationError.expired }
            if flow.kind == "flow" { page.flow = flow }
        } catch is CancellationError {
            throw CancellationError()
        } catch LeaveApplicationError.expired {
            throw LeaveApplicationError.expired
        } catch {
            // Optional flow failures keep the already verified form available.
            page.flow = nil
        }
        try check()
        return page
    }

    /// 撤回 one form. Returns true only when a fresh query no longer lists it as withdrawable.
    func withdraw(account: String, formNo: String) async throws -> Bool {
        self.account = account
        let before = try await list(LeaveSchoolPage.manage, listPage: LeaveSchoolPage.manageList)
        guard before.actions?.contains(where: { $0.formNo == formNo && $0.withdraw }) == true else {
            throw LeaveApplicationError.recordMissing
        }
        // The user confirmed in the app; accept only the school's own delete prompt once.
        expectedConfirm = { $0.contains("刪除") || $0.contains("撤回") }
        defer { expectedConfirm = nil }
        // The postback is scheduled after the script returns, so an error here means nothing was sent.
        let result = try await run(LeaveApplicationScript.withdraw, arguments: ["formNo": formNo])
        // The school's confirm text did not match: nothing was sent, and nothing is retried.
        guard result == "posted" else { throw LeaveApplicationError.changed }
        // Let the school finish before querying again; leaving early could abort the postback.
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(500))
            try check()
            let state: String?
            do { state = try await run(LeaveApplicationScript.withdrawSettled, arguments: ["formNo": formNo]) }
            catch LeaveApplicationError.expired { throw LeaveApplicationError.expired }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Postback can replace the JS context mid-read; keep the bounded poll.
                state = nil
            }
            if state == "expired" { throw LeaveApplicationError.expired }
            if state == "reloaded" || state == "removed" { break }
        }
        let after = try await list(LeaveSchoolPage.manage, listPage: LeaveSchoolPage.manageList)
        return after.actions?.contains(where: { $0.formNo == formNo }) != true
            && after.records?.contains(where: { $0.formNo == formNo }) != true
    }

    private func list(_ path: String, listPage: String) async throws -> LeaveListPage {
        try await open(path) {
            guard let text = try? await self.run(LeaveApplicationScript.list, arguments: ["listPage": listPage]),
                  let page = try? JSONDecoder().decode(LeaveListPage.self, from: Data(text.utf8)) else { return .waiting }
            switch page.kind {
            case "list": return .ready(page)
            case "expired": return .expired
            default: return .waiting
            }
        }
    }

    private func openRecord(formNo: String, listPath: String, listPage: String, mode: String) async throws -> LeavePage {
        let rows = try await list(listPath, listPage: listPage)
        guard rows.records?.contains(where: { $0.formNo == formNo }) == true else { throw LeaveApplicationError.recordMissing }
        let cellMode = mode == "MOD" ? "Mod" : "Detail"
        _ = try await run(LeaveApplicationScript.openRecord,
                          arguments: ["listPage": listPage, "formNo": formNo, "mode": cellMode])
        let page = try await waitForPage(kind: "form") { $0.formNo == formNo && $0.mode == mode }
        guard page.studentID?.lowercased() == account.lowercased() else { throw LeaveApplicationError.changed }
        return page
    }

    /// Reuses cookies with one GUID bridge at most per open, loads `path`
    /// into mainFrame like the school's menu, then polls `read` within a fixed budget.
    private func open<T>(_ path: String, read: @escaping @MainActor () async -> Read<T>) async throws -> T {
        if !started {
            guard let mainFrame = EnrollmentEndpoint.mainFrame else { throw LeaveApplicationError.unavailable }
            started = true
            report(.connecting)
            webView.load(URLRequest(url: mainFrame, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
        var opened = false
        var openedAt = ContinuousClock.now
        var reopens = 0
        var bridged = false
        // Login and page lookup share one fixed 45 s budget, checked every 0.2 s.
        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            try check()
            if let failure = navigationFailure { navigationFailure = nil; throw failure }
            if sessionExpired {
                guard !bridged else { throw LeaveApplicationError.expired }
                bridged = true; opened = false; reopens = 0
                try await bridgeSession()
                continue
            }
            guard mainFrameReady || mainFrameCommittedAt.map({ ContinuousClock.now - $0 > .seconds(4) }) == true else { continue }
            if !opened {
                let result = try? await run(LeaveApplicationScript.openPage, arguments: ["path": path])
                if result == "opened" { opened = true; openedAt = .now; report(.reading) }
                continue
            }
            switch await read() {
            case .ready(let value): return value
            case .expired: sessionExpired = true
            case .waiting:
                // MainFrame's own scripts can replace or drop the menu navigation; send it again, bounded.
                guard reopens < 2 else { continue }
                let elapsed = ContinuousClock.now - openedAt
                let target = try? await run(LeaveApplicationScript.openedPage, arguments: ["path": path])
                if (target == "elsewhere" && elapsed > .seconds(4)) || (target == "pending" && elapsed > .seconds(10)) {
                    log("重新開啟請假頁 state=\(target ?? "")")
                    opened = false; reopens += 1
                }
            }
        }
        throw URLError(.timedOut)
    }

    private func bridgeSession() async throws {
        sessionExpired = false
        mainFrameReady = false
        mainFrameCommittedAt = nil
        navigationGeneration = UUID()
        report(.signingIn)
        // Replace the expired document while the GUID is requested, so none of its
        // late signals is taken for the result of the new login.
        replacingDocument = true
        defer { replacingDocument = false; blankNavigation = nil }
        webView.stopLoading()
        blankNavigation = webView.loadHTMLString("", baseURL: nil)
        let guid: String
        do {
            guid = try await requestGUID()
            try check()
            for _ in 0..<40 where replacingDocument {
                try await Task.sleep(for: .milliseconds(50))
                try check()
            }
        } catch {
            // The WebView is left blank: a retry on this service starts again from MainFrame.
            started = false
            throw error
        }
        replacingDocument = false; blankNavigation = nil
        sessionExpired = false; navigationFailure = nil
        guard let login = SSOGUIDBridge.acadeLoginURL(guid: guid) else { throw LeaveApplicationError.unavailable }
        webView.load(URLRequest(url: login, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    /// A lapsed app SSO token is refreshed once here, so the same WebView continues
    /// instead of the caller rebuilding it and reloading MainFrame.
    private func requestGUID() async throws -> String {
        do { return try await SSOGUIDBridge.requestGUID(account: account) }
        catch let error as URLError where error.code == .userAuthenticationRequired && !refreshedLogin {
            refreshedLogin = true
            try check()
            log("SSO 登入失效，更新登入")
            guard await SSOSessionService.shared.requestRefresh(force: true) else { throw LeaveApplicationError.expired }
            try check()
            return try await SSOGUIDBridge.requestGUID(account: account)
        }
    }

    func run(_ source: String, arguments: [String: Any] = [:]) async throws -> String {
        try check()
        if sessionExpired { throw LeaveApplicationError.expired }
        guard webView.url?.host?.lowercased() == "acade.niu.edu.tw" else { throw LeaveApplicationError.expired }
        var args = arguments; args["account"] = account
        let id = UUID()
        let result: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !closed, !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                scripts[id] = continuation
                webView.callAsyncJavaScript(source, arguments: args, in: nil, in: .page) { [weak self] result in
                    guard let waiter = self?.scripts.removeValue(forKey: id) else { return }
                    switch result {
                    case .success(let value):
                        guard let text = value as? String else { waiter.resume(throwing: LeaveApplicationError.changed); return }
                        waiter.resume(returning: text)
                    case .failure(let error):
                        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
                        waiter.resume(throwing: message.contains("SESSION_EXPIRED") ? LeaveApplicationError.expired
                                      : message.contains("RECORD_MISSING")
                                      ? LeaveApplicationError.recordMissing : LeaveApplicationError.changed)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.scripts.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
        try check()
        return result
    }

    func snapshot() async throws -> LeavePage { try await read(LeaveApplicationScript.snapshot) }
    func read(_ script: String) async throws -> LeavePage {
        let result = try await run(script)
        return try JSONDecoder().decode(LeavePage.self, from: Data(result.utf8))
    }

    func waitForPage(kind: String, script: String = LeaveApplicationScript.snapshot,
                     matches: (LeavePage) -> Bool = { _ in true }) async throws -> LeavePage {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            try check()
            if sessionExpired { throw LeaveApplicationError.expired }
            if let failure = navigationFailure { navigationFailure = nil; throw failure }
            if let result = try? await read(script) {
                if result.kind == "expired" { throw LeaveApplicationError.expired }
                if result.kind == kind, matches(result) { return result }
            }
        }
        throw URLError(.timedOut)
    }

    private func check() throws {
        try Task.checkCancellation()
        if closed { throw CancellationError() }
    }

    private func report(_ stage: LeaveLoadStage) {
        log(stage.title)
        onProgress?(stage)
    }

    private func log(_ event: String) {
        let elapsed = ContinuousClock.now - createdAt
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        print("[Leave] \(event) elapsed_ms=\(ms)")
    }

    func close() {
        closed = true
        onDialog = nil; onConfirm = nil; onProgress = nil
        pendingConfirm?(false); pendingConfirm = nil
        let pending = Array(scripts.values); scripts.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if navigation === blankNavigation { replacingDocument = false; blankNavigation = nil; return }
        guard !closed, !replacingDocument, let url = webView.url else { return }
        // A new top document replaces MainFrame until its own didFinish.
        if Self.isMainFrame(url) { mainFrameCommittedAt = .now } else { mainFrameCommittedAt = nil; mainFrameReady = false }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, !replacingDocument, let url = webView.url else { return }
        // Only log the path: Login.aspx carries a one-use GUID in its query.
        log("已載入 path=\(url.path)")
        if SSOGUIDBridge.isSessionExpiredURL(url) {
            sessionExpired = true
        } else if EnrollmentEndpoint.isLegacyPortalLanding(url), let mainFrame = EnrollmentEndpoint.mainFrame {
            webView.load(URLRequest(url: mainFrame, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        } else if Self.isMainFrame(url) {
            if !mainFrameReady { report(.opening) }
            mainFrameReady = true
        }
    }

    private static func isMainFrame(_ url: URL) -> Bool {
        url.host?.lowercased() == "acade.niu.edu.tw" && url.path.lowercased() == "/niu/mainframe.aspx"
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, let url = action.request.url else { decisionHandler(.cancel); return }
        let isMainFrame = action.targetFrame?.isMainFrame != false
        if replacingDocument {
            // Only the blank page may load; the expired document's own navigations are dropped.
            decisionHandler(isMainFrame && url.scheme == "about" ? .allow : .cancel)
            return
        }
        if SSOGUIDBridge.isSessionExpiredURL(url) {
            if isMainFrame {
                decisionHandler(.cancel)
                mainFrameReady = false
                sessionExpired = true
            } else if url.host?.lowercased() == "acade.niu.edu.tw" {
                // MainFrame preloads a hidden timeout page; the snapshot decides
                // whether the leave frame itself expired.
                decisionHandler(.allow)
            } else if let frame = action.targetFrame {
                // A subframe heading to the cross-origin SSO login: only the leave
                // frame's subtree counts as an expired leave session.
                let generation = navigationGeneration
                webView.evaluateJavaScript(LeaveApplicationScript.isLeaveFrame, in: frame, in: .page) { [weak self] result in
                    decisionHandler(.cancel)
                    guard let self, !self.closed, self.navigationGeneration == generation,
                          case .success(let value) = result, value as? Bool == true else { return }
                    self.sessionExpired = true
                }
            } else {
                decisionHandler(.cancel)
            }
            return
        }
        let allowed = EnrollmentEndpoint.allowsRegistrationNavigation(url)
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed, isMainFrame { navigationFailure = LeaveApplicationError.unavailable }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }
    private func fail(_ error: Error) {
        let nsError = error as NSError
        // Cancelled loads and WebKit's "frame load interrupted" come from our own redirects.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        guard !closed, !replacingDocument else { return }
        log("載入失敗 domain=\(nsError.domain) code=\(nsError.code)")
        navigationFailure = error
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let pending = Array(scripts.values); scripts.removeAll()
        pending.forEach { $0.resume(throwing: LeaveApplicationError.unavailable) }
        navigationFailure = LeaveApplicationError.unavailable
        onDialog?("校方頁面已中斷，請前往校務系統確認申請狀態。")
    }

    // MARK: - School dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        // 「使用時間逾時,系統已將您自動登出」is a lapsed session: sign in again on the
        // next page open instead of showing it as a message about the leave form.
        if Self.isLogoutNotice(message) {
            if !closed, !replacingDocument { sessionExpired = true }
            return
        }
        onDialog?(String(message.prefix(1000)))
    }

    nonisolated static func isLogoutNotice(_ message: String) -> Bool {
        message.contains("自動登出") || (message.contains("逾時") && message.contains("登入"))
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        if let expectedConfirm, expectedConfirm(message) {
            self.expectedConfirm = nil
            completionHandler(true); return
        }
        guard let onConfirm, pendingConfirm == nil else { completionHandler(false); return }
        pendingConfirm = completionHandler
        onConfirm(String(message.prefix(1000))) { [weak self] accepted in
            let completion = self?.pendingConfirm
            self?.pendingConfirm = nil
            completion?(accepted)
        }
    }
}
