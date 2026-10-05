import Foundation
import WebKit
import Combine

extension Notification.Name {
    static let didChangeEventRegistrationSession = Notification.Name("didChangeEventRegistrationSession")
    static let didConfirmEventCancellation = Notification.Name("didConfirmEventCancellation")
}

private nonisolated struct EventOperationSession: Sendable {
    let revision: UUID
    let username: String?
    let password: String?
}

private nonisolated enum EventOperationContext {
    @TaskLocal static var session: EventOperationSession?
}

nonisolated enum EventRegistrationError: LocalizedError, Equatable {
    case credentialsMissing
    case invalidCredentials
    case loginFailed
    case offline
    case timedOut
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .credentialsMissing: return "找不到已儲存的登入資訊，請重新登入 App 後再試。"
        case .invalidCredentials: return "活動系統回報帳號或密碼錯誤。若最近改過密碼，請重新登入 App。"
        case .loginFailed: return "活動系統登入沒有完成，請稍後重試，或改用網頁開啟。"
        case .offline: return "目前沒有網路連線，請連線後重試。"
        case .timedOut: return "活動系統回應逾時，請稍後重試。"
        case .unavailable: return "目前無法連線至活動系統，請稍後重試。"
        case .invalidResponse: return "無法辨識活動系統的頁面內容，請稍後重試。"
        }
    }
}

/// The result of a request that changes the school's records.
nonisolated enum EventActionOutcome: Equatable {
    /// Verified against the school's applied-event list or the saved form.
    case confirmed(String)
    /// The school reported a failure, or nothing was submitted.
    case rejected(String)
    /// The request was sent but its result could not be verified.
    case uncertain(String)
}

/// Only the production mutation boundary may assert that no POST was submitted.
nonisolated struct EventRegistrationNotSubmittedError: LocalizedError {
    let reason: String
    let wasCancelled: Bool

    init(_ error: Error) {
        wasCancelled = error is CancellationError
        reason = error is CancellationError ? "操作已取消。"
            : (error as? LocalizedError)?.errorDescription ?? EventRegistrationError.unavailable.localizedDescription
    }

    var errorDescription: String? { "尚未送出報名：\(reason)" }
}

/// Shared by direct client calls and both UI entry points, including injected services.
@MainActor
final class EventRegistrationSubmission {
    static let shared = EventRegistrationSubmission()
    private var reservations: [UUID: [String: UUID]] = [:]
    private var uncertain: [UUID: Set<String>] = [:]
    private var resetObserver: AnyCancellable?

    private init() {
        resetObserver = NotificationCenter.default.publisher(for: .didChangeEventRegistrationSession)
            .sink { [weak self] _ in
                self?.reservations.removeAll()
                self?.uncertain.removeAll()
            }
    }

    func blockedIDs(session: UUID) -> Set<String> { Set(reservations[session, default: [:]].keys) }

    /// Only a successful, fresh same-session read can resolve uncertainty; absence may be school lag.
    func reconcileApplied(_ records: [EventData_Apply], session: UUID) {
        for record in records where ["已報名", "報名成功", "正取", "錄取"].contains(record.state.trimmingCharacters(in: .whitespacesAndNewlines))
            && !["取消", "停辦"].contains(where: record.event_state.contains) {
            guard uncertain[session]?.remove(record.id) != nil else { continue }
            reservations[session]?[record.id] = nil
        }
    }

    func submit(eventID: String, service: any EventRegistrationServing, session: UUID) async throws -> EventActionOutcome {
        // Production register owns its fence so direct callers cannot bypass it. Do not reserve twice.
        if let client = service as? EventRegistrationClient {
            guard client.sessionRevision == session else { throw CancellationError() }
            return try await client.register(eventID: eventID)
        }
        return try await perform(eventID: eventID, session: session) {
            try await service.register(eventID: eventID)
        }
    }

    func perform(eventID: String, session: UUID,
                 operation: () async throws -> EventActionOutcome) async throws -> EventActionOutcome {
        guard reservations[session]?[eventID] == nil else {
            return .uncertain("此活動已送出或結果不明，未再次送出；請查看「已報名活動」。")
        }
        let token = UUID()
        reservations[session, default: [:]][eventID] = token
        func release() {
            // A reset or replacement must not be changed by a late completion.
            guard reservations[session]?[eventID] == token else { return }
            reservations[session]?[eventID] = nil
        }
        do {
            let outcome = try await operation()
            if case .uncertain = outcome {
                if reservations[session]?[eventID] == token { uncertain[session, default: []].insert(eventID) }
            } else { release() }
            return outcome
        } catch let error as EventRegistrationNotSubmittedError {
            release()
            throw error
        } catch {
            // Unknown injected-service errors (including cancellation) cannot prove no mutation.
            if reservations[session]?[eventID] == token { uncertain[session, default: []].insert(eventID) }
            throw error
        }
    }
}

struct EventRegistrationForm: Equatable {
    var role = ""
    var classes = ""
    var studentID = ""
    var name = ""
    var tel = ""
    var mail = ""
    var memo = ""
    /// "1" 葷食, "2" 素食, "3" 不用餐
    var food = "3"
    /// "1" 不需要, "2" 參加證明, "3" 公務人員學習時數
    var proof = "1"

    func matchesEditableFields(of other: EventRegistrationForm) -> Bool {
        func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized(tel) == normalized(other.tel) && normalized(mail) == normalized(other.mail)
            && normalized(memo) == normalized(other.memo) && food == other.food && proof == other.proof
    }
}

@MainActor
protocol EventRegistrationServing: AnyObject {
    func availableEvents() async throws -> [EventData]
    func appliedEvents() async throws -> [EventData_Apply]
    func register(eventID: String) async throws -> EventActionOutcome
    func cancelRegistration(eventID: String) async throws -> EventActionOutcome
    func registrationForm(eventID: String) async throws -> EventRegistrationForm
    func modifyRegistration(eventID: String, form: EventRegistrationForm) async throws -> EventActionOutcome
}

/// One hidden browser for the activity system. Operations run one at a time so both tabs share a
/// single sign-in, and a school session that expires mid-use is renewed with a bounded retry.
@MainActor
final class EventRegistrationClient: NSObject, EventRegistrationServing, WKNavigationDelegate, WKUIDelegate {
    static let shared = EventRegistrationClient()
    static let websiteURL = URL(string: "https://ccsys.niu.edu.tw/MvcTeam/Act")

    private let origin: URL
    private var dataStore: WKWebsiteDataStore
    private(set) var sessionRevision = UUID()
    private let credentials: @MainActor () -> (username: String, password: String)?
    private var webView: WKWebView?
    private var queueTail: Task<Void, Never>?
    private var operations: [UUID: () -> Void] = [:]
    private var navigationCount = 0
    private var navigationRevision = UUID()
    private var currentNavigation: WKNavigation?
    // Weak keys retain callback provenance across prepareNavigation without retaining old navigations.
    private let navigationRevisions = NSMapTable<WKNavigation, NSUUID>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var navigationCompleted = false
    private var acceptsDocumentReady = false
    private var documentReadyTask: Task<Void, Never>?
    private var navigationStartedAt = ContinuousClock.now
    private var lastNavigation: Result<URL, Error> = .failure(EventRegistrationError.unavailable)
    private var lastServerResponseAt: Date?
    private var waiters: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var dialogs: [String] = []
    private var acceptsConfirmation = false

    private static let loginAttempts = 4
    private static let loginSubmissions = 2
    private static let failurePhrases = ["失敗", "錯誤", "額滿", "截止", "不符", "無法", "不可", "未開放", "重複"]

    init(origin: URL = URL(string: "https://ccsys.niu.edu.tw") ?? URL(fileURLWithPath: "/"),
         dataStore: WKWebsiteDataStore? = nil,
         credentials: @escaping @MainActor () -> (username: String, password: String)? = {
             LoginRepository.shared.getSavedCredentials()
         }) {
        self.origin = origin
        // Activity login is isolated from the app's other school services and from future accounts.
        self.dataStore = dataStore ?? .nonPersistent()
        self.credentials = credentials
    }

    // MARK: Reads

    func availableEvents() async throws -> [EventData] {
        try await serializedRead { [self] in
            try await open(endpoint("/MvcTeam/Act"))
            return try await scrape(Scripts.available)
        }
    }

    func appliedEvents() async throws -> [EventData_Apply] {
        try await serializedRead { [self] in try await loadApplied() }
    }

    func registrationForm(eventID: String) async throws -> EventRegistrationForm {
        let url = try endpoint("/MvcTeam/Act/RegData/\(try Self.validated(eventID))")
        return try await serializedRead { [self] in
            try await open(url)
            return try await readForm().form
        }
    }

    // MARK: Mutations

    func register(eventID: String) async throws -> EventActionOutcome {
        let id: String
        do { id = try Self.validated(eventID) }
        catch { throw EventRegistrationNotSubmittedError(error) }
        let revision = sessionRevision
        var submissionStarted = false
        return try await EventRegistrationSubmission.shared.perform(eventID: id, session: revision) {
            do {
                return try await self.registerUnreserved(eventID: id, onSubmit: { submissionStarted = true })
            } catch {
                // Never label an old-session or post-boundary cancellation as "not submitted".
                guard revision == self.sessionRevision, !submissionStarted else { throw error }
                throw EventRegistrationNotSubmittedError(error)
            }
        }
    }

    private func registerUnreserved(eventID: String, onSubmit: @escaping () -> Void) async throws -> EventActionOutcome {
        let id = try Self.validated(eventID)
        let url = try endpoint("/MvcTeam/Act/Apply/\(id)")
        return try await serialized { [self] in
            if let existing = try await loadApplied().first(where: { $0.eventSerialID == id }) {
                return .confirmed(Self.registeredMessage("你已報名這個活動", state: existing.state))
            }
            let page: URL
            do { page = try await open(url) } catch EventRegistrationError.invalidResponse {
                return .rejected("無法開啟此活動的報名頁面，可能已截止或額滿。請重新整理後再試。")
            }
            let token = try await evaluate(
                "return document.querySelector('[name=\"__RequestVerificationToken\"]')?.value || '';")
            guard !token.isEmpty else {
                return .rejected("報名頁面沒有可送出的表單，可能已截止或額滿。請重新整理後再試。")
            }
            var request = URLRequest(url: page, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody([("__RequestVerificationToken", token), ("id", id), ("action", "我要報名")])
            return try await submitThenVerify(request, uncertain: "已送出報名，但尚無法確認校方是否完成。請到「已報名活動」確認，勿立即重複報名。", onSubmit: onSubmit) {
                if let record = try await self.loadApplied().first(where: { $0.eventSerialID == id }) {
                    return .confirmed(Self.registeredMessage("已完成報名", state: record.state))
                }
                return nil
            }
        }
    }

    func cancelRegistration(eventID: String) async throws -> EventActionOutcome {
        let id = try Self.validated(eventID)
        let url = try endpoint("/MvcTeam/Act/RegData/\(id)")
        return try await serialized { [self] in
            try await open(url)
            acceptsConfirmation = true
            defer {
                if EventOperationContext.session?.revision == sessionRevision { acceptsConfirmation = false }
            }
            let mark = navigationCount
            dialogs.removeAll()
            prepareNavigation(acceptDocumentReady: false)
            try Task.checkCancellation()
            try validateOperationSession()
            let cancellationState: String
            do { cancellationState = try await evaluate(Scripts.cancel) }
            catch {
                try validateOperationSession()
                return .uncertain("取消操作可能已送出，請重新整理「已報名活動」確認，勿立即重送。")
            }
            switch cancellationState {
            case "submitted": break
            case "no_cancel_button":
                return .rejected("找不到取消報名的選項，可能已超過可取消的期間。請到校方網頁確認。")
            default:
                return .rejected("取消報名頁面內容不完整，沒有送出取消。請重新整理後再試。")
            }
            do { _ = try await waitForNavigation(after: mark, timeout: .seconds(20)) }
            catch {
                try validateOperationSession()
                // The page may answer without navigating; verification below decides.
            }
            return try await verify(uncertain: "已送出取消，但尚無法確認校方是否完成。請重新整理「已報名活動」確認。") {
                let records = try await self.loadApplied()
                guard let record = records.first(where: { $0.eventSerialID == id }) else {
                    return .confirmed("已取消報名。")
                }
                return record.state.contains("取消") ? .confirmed("已取消報名。") : nil
            }
        }
    }

    func modifyRegistration(eventID: String, form: EventRegistrationForm) async throws -> EventActionOutcome {
        let id = try Self.validated(eventID)
        let url = try endpoint("/MvcTeam/Act/RegData/\(id)")
        return try await serialized { [self] in
            try await open(url)
            let current = try await readForm()
            guard !current.token.isEmpty, let signID = current.signID.nilIfBlank,
                  Self.isEventID(signID) else {
                return .rejected("報名資料頁面內容不完整，沒有送出修改。請重新整理後再試。")
            }
            var request = URLRequest(url: try endpoint("/MvcTeam/Act/RegData/\(signID)"),
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody([
                ("__RequestVerificationToken", current.token),
                ("ApplyId", current.applyID.nilIfBlank ?? signID), ("SignId", signID),
                ("SignTEL", form.tel), ("SignEmail", form.mail), ("SignMemo", form.memo),
                ("Food", form.food), ("Proof", form.proof), ("action", "儲存修改")
            ])
            return try await submitThenVerify(request, uncertain: "已送出修改，但尚無法確認校方是否儲存。請重新開啟報名資料確認。") {
                try await self.open(url)
                return try await self.readForm().form.matchesEditableFields(of: form) ? .confirmed("已更新報名資料。") : nil
            }
        }
    }

    /// Logout or replaced login: fence old work and replace only this service's cookie store.
    func reset() {
        navigationRevision = UUID()
        navigationCompleted = true
        documentReadyTask?.cancel()
        documentReadyTask = nil
        currentNavigation = nil
        sessionRevision = UUID()
        lastServerResponseAt = nil
        let pending = operations.values
        operations.removeAll()
        pending.forEach { $0() }
        queueTail = nil
        let waiting = waiters.values
        waiters.removeAll()
        waiting.forEach { $0.resume(throwing: CancellationError()) }
        dialogs.removeAll()
        acceptsConfirmation = false
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView = nil
        dataStore = .nonPersistent()
        NotificationCenter.default.post(name: .didChangeEventRegistrationSession, object: nil)
    }

    // MARK: Sign-in

    @discardableResult
    private func open(_ url: URL) async throws -> URL {
        var landed = try await load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData), acceptDocumentReady: true)
        if Self.isLoginPage(landed) {
            landed = try await signIn()
            if !Self.samePage(landed, url) { landed = try await load(URLRequest(url: url), acceptDocumentReady: true) }
            if Self.isLoginPage(landed) { throw EventRegistrationError.loginFailed }
        }
        guard Self.samePage(landed, url) else {
            print("[EventRegistration] 頁面導向非預期位置 path=\(landed.path)")
            throw EventRegistrationError.invalidResponse
        }
        return landed
    }

    /// Fills the school's own form. Retries a page that is still rendering, but submits the
    /// password at most twice and stops immediately when the school rejects it.
    private func signIn() async throws -> URL {
        guard let credentials = credentials(), !credentials.username.isEmpty, !credentials.password.isEmpty else {
            throw EventRegistrationError.credentialsMissing
        }
        var submissions = 0
        for attempt in 0..<Self.loginAttempts {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(600 * attempt))
                // A login page that keeps rendering empty is usually a stuck web content process.
                if attempt == Self.loginAttempts - 1 { discardWebView() }
                let landed = try await load(URLRequest(url: try endpoint("/MvcTeam/Account/Login"),
                                                       cachePolicy: .reloadIgnoringLocalCacheData), acceptDocumentReady: true)
                if !Self.isLoginPage(landed) { return landed }
            }
            let mark = navigationCount
            let timeout = navigationTimeout(warm: 20)
            prepareNavigation(acceptDocumentReady: true)
            let state = try await evaluate(Scripts.login, [
                "account": credentials.username, "password": credentials.password
            ])
            print("[EventRegistration] 登入表單狀態=\(state) attempt=\(attempt + 1)")
            switch state {
            case "not_login_page":
                if let url = webView?.url { return url }
                continue
            case "submitted":
                submissions += 1
            default:
                continue
            }
            do {
                let page = try await waitForNavigation(after: mark, timeout: .seconds(timeout))
                if !Self.isLoginPage(page) { return page }
            } catch EventRegistrationError.timedOut {
                if let url = webView?.url, !Self.isLoginPage(url) { return url }
            }
            let text = (try? await evaluate(Scripts.pageText)) ?? ""
            if ["帳號或密碼錯誤", "密碼錯誤", "帳號不存在", "登入失敗"].contains(where: text.contains) {
                throw EventRegistrationError.invalidCredentials
            }
            if submissions >= Self.loginSubmissions { break }
        }
        throw EventRegistrationError.loginFailed
    }

    // MARK: Pages

    private func loadApplied() async throws -> [EventData_Apply] {
        try await open(endpoint("/MvcTeam/Act/ApplyMe"))
        let records: [EventData_Apply] = try await scrape(Scripts.applied)
        try validateOperationSession()
        EventRegistrationSubmission.shared.reconcileApplied(records, session: sessionRevision)
        return records
    }

    private func scrape<T: Decodable>(_ script: String) async throws -> [T] {
        for attempt in 0..<2 {
            do {
                let json = try await evaluate("return " + script)
                return try JSONDecoder().decode([T].self, from: Data(json.utf8))
            } catch EventRegistrationError.invalidResponse where attempt == 0 {
                try await Task.sleep(for: .milliseconds(800))
            } catch is DecodingError {
                throw EventRegistrationError.invalidResponse
            }
        }
        throw EventRegistrationError.invalidResponse
    }

    private struct LoadedForm: Decodable {
        var tel = "", mail = "", memo = "", food = "3", proof = "1"
        var role = "", classes = "", studentID = "", name = ""
        var token = "", signID = "", applyID = ""
        var form: EventRegistrationForm {
            EventRegistrationForm(role: role, classes: classes, studentID: studentID, name: name,
                                  tel: tel, mail: mail, memo: memo, food: food, proof: proof)
        }
    }

    private func readForm() async throws -> LoadedForm {
        let json = try await evaluate(Scripts.form)
        do { return try JSONDecoder().decode(LoadedForm.self, from: Data(json.utf8)) }
        catch { throw EventRegistrationError.invalidResponse }
    }

    private func submitThenVerify(_ request: URLRequest, uncertain: String,
                                  onSubmit: () -> Void = {},
                                  confirmation: @escaping () async throws -> EventActionOutcome?) async throws -> EventActionOutcome {
        // Cancellation before this boundary proves no mutation was submitted.
        try Task.checkCancellation()
        try validateOperationSession()
        onSubmit()
        do { _ = try await load(request) }
        catch {
            try validateOperationSession()
            // The request may have reached the school before the response failed.
            return .uncertain(uncertain)
        }
        return try await verify(uncertain: uncertain, confirmation: confirmation)
    }

    private func verify(uncertain: String,
                        confirmation: () async throws -> EventActionOutcome?) async throws -> EventActionOutcome {
        let failure = await failureMessage()
        do {
            if let confirmed = try await confirmation() { return confirmed }
        } catch {
            try validateOperationSession()
            return .uncertain(uncertain)
        }
        if let failure { return .rejected("校方回應：\(failure)") }
        return .uncertain(uncertain)
    }

    private func failureMessage() async -> String? {
        var messages = dialogs
        if let json = try? await evaluate(Scripts.feedback),
           let notes = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
            messages += notes
        }
        return messages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { message in !message.isEmpty && Self.failurePhrases.contains(where: message.contains) }
            .map { String($0.prefix(200)) }
    }

    // MARK: Browser

    private func page() throws -> WKWebView {
        try Task.checkCancellation()
        try validateOperationSession()
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // This isolated-world marker is set after the main document is parsed, without waiting
        // for images/frames. Page scripts cannot spoof it. Reads still validate their DOM below.
        configuration.userContentController.addUserScript(WKUserScript(
            source: "globalThis.niuActivityDocumentReady = true;",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        return view
    }

    private func discardWebView() {
        documentReadyTask?.cancel()
        documentReadyTask = nil
        currentNavigation = nil
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView = nil
    }

    private func prepareNavigation(acceptDocumentReady: Bool) {
        navigationRevision = UUID()
        documentReadyTask?.cancel()
        documentReadyTask = nil
        currentNavigation = nil
        navigationCompleted = false
        acceptsDocumentReady = acceptDocumentReady
        navigationStartedAt = .now
    }

    /// IIS may need a cold start after an idle period. Successful navigation warms this session.
    private func navigationTimeout(warm: TimeInterval = 30, now: Date = Date()) -> TimeInterval {
        guard let lastServerResponseAt, now.timeIntervalSince(lastServerResponseAt) < 600 else { return 90 }
        return warm
    }

    private func load(_ request: URLRequest, acceptDocumentReady: Bool = false) async throws -> URL {
        try Task.checkCancellation()
        try validateOperationSession()
        var request = request
        // Snapshot once so the request and its waiter have the same deadline. POSTs stay at 30s.
        if request.httpMethod == nil || request.httpMethod == "GET" {
            request.timeoutInterval = navigationTimeout()
        }
        // A page's delayed JS navigation has no WKNavigation identity until its first
        // callback. Isolate explicit loads by view identity; keep the same data store
        // so school cookies survive. In-page login/cancel submits still use their page.
        discardWebView()
        let view = try page()
        let mark = navigationCount
        dialogs.removeAll()
        prepareNavigation(acceptDocumentReady: acceptDocumentReady)
        currentNavigation = view.load(request)
        if let currentNavigation { navigationRevisions.setObject(navigationRevision as NSUUID, forKey: currentNavigation) }
        return try await waitForNavigation(after: mark, timeout: .seconds(request.timeoutInterval))
    }

    private func evaluate(_ body: String, _ arguments: [String: Any] = [:]) async throws -> String {
        let view = try page()
        let value: Any?
        do { value = try await view.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page) }
        catch {
            try Task.checkCancellation()
            throw EventRegistrationError.invalidResponse
        }
        try Task.checkCancellation()
        try validateOperationSession()
        guard let text = value as? String else { throw EventRegistrationError.invalidResponse }
        return text
    }

    private func waitForNavigation(after mark: Int, timeout: Duration) async throws -> URL {
        if navigationCount > mark { return try lastNavigation.get() }
        let revision = navigationRevision
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.waiters.removeValue(forKey: id)?.resume(throwing: EventRegistrationError.timedOut)
        }
        defer {
            timer.cancel()
            if revision == navigationRevision {
                documentReadyTask?.cancel()
                documentReadyTask = nil
                if !navigationCompleted {
                    // Cancellation/timeout can precede didCommit. Fence that late callback too.
                    navigationCompleted = true
                    currentNavigation = nil
                    webView?.stopLoading()
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    private func record(_ result: Result<URL, Error>, documentReady: Bool = false) {
        guard !navigationCompleted else { return }
        if case .success = result { lastServerResponseAt = Date() }
        navigationCompleted = true
        documentReadyTask?.cancel()
        documentReadyTask = nil
        #if DEBUG
        let outcome: String
        switch result {
        case .success: outcome = documentReady ? "內容就緒" : "整頁完成"
        case .failure: outcome = "載入失敗"
        }
        print("[EventRegistration] \(outcome) elapsed=\(navigationStartedAt.duration(to: .now))")
        #endif
        navigationCount += 1
        lastNavigation = result
        let waiting = waiters.values
        waiters.removeAll()
        waiting.forEach { $0.resume(with: result) }
    }

    /// Retry only public reads, inside one queue slot and the original operation session.
    /// Mutation preflight/verification reads deliberately bypass this wrapper.
    private func serializedRead<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await serialized { [self] in
            do { return try await body() }
            catch {
                try Task.checkCancellation()
                try validateOperationSession()
                // Unknown errors must not become retryable merely because normalization has a fallback.
                guard error is EventRegistrationError || error is URLError else { throw error }
                let normalized = Self.normalized(error)
                guard let failure = normalized as? EventRegistrationError,
                      failure == .timedOut || failure == .unavailable else { throw normalized }
            }
            try Task.checkCancellation()
            try validateOperationSession()
            return try await body()
        }
    }

    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queueTail
        #if DEBUG
        let queuedAt = ContinuousClock.now
        #endif
        let id = UUID()
        let saved = credentials()
        let session = EventOperationSession(revision: sessionRevision, username: saved?.username, password: saved?.password)
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            try Task.checkCancellation()
            #if DEBUG
            print("[EventRegistration] 開始處理 queue_wait=\(queuedAt.duration(to: .now))")
            #endif
            return try await EventOperationContext.$session.withValue(session) {
                try self.validateOperationSession()
                let result = try await body()
                try self.validateOperationSession()
                return result
            }
        }
        operations[id] = { task.cancel() }
        queueTail = Task { _ = try? await task.value }
        defer { operations[id] = nil }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            throw Self.normalized(error)
        }
    }

    private func validateOperationSession() throws {
        guard let session = EventOperationContext.session else { return }
        let current = credentials()
        guard session.revision == sessionRevision, session.username == current?.username,
              session.password == current?.password else { throw CancellationError() }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView, let navigation else { return }
        if let revision = navigationRevisions.object(forKey: navigation) {
            guard revision == navigationRevision as NSUUID, navigation === currentNavigation else { return }
        } else {
            navigationRevisions.setObject(navigationRevision as NSUUID, forKey: navigation)
        }
        guard !navigationCompleted else { return }
        // A new provisional navigation may replace a JS redirect without a terminal callback first.
        documentReadyTask?.cancel()
        documentReadyTask = nil
        currentNavigation = navigation
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView, navigation === currentNavigation,
              acceptsDocumentReady, !navigationCompleted else { return }
        documentReadyTask?.cancel()
        let revision = navigationRevision
        documentReadyTask = Task { [weak self, weak webView, weak navigation] in
            // Bounded by the navigation timeout; didFinish remains the fallback if evaluation fails.
            for _ in 0..<600 {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, let webView, let navigation,
                      webView === self.webView, navigation === self.currentNavigation,
                      revision == self.navigationRevision, !self.navigationCompleted else { return }
                let ready = try? await webView.callAsyncJavaScript(
                    "return globalThis.niuActivityDocumentReady === true;", arguments: [:], in: nil, contentWorld: .defaultClient)
                guard !Task.isCancelled, navigation === self.currentNavigation,
                      webView === self.webView, revision == self.navigationRevision, !self.navigationCompleted else { return }
                if ready as? Bool == true, let url = webView.url,
                   Self.samePage(url, self.origin, pathOnly: false) {
                    self.record(.success(url), documentReady: true)
                    return
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === currentNavigation, let url = webView.url else { return }
        record(.success(url))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === currentNavigation else { return }
        failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === currentNavigation else { return }
        failed(webView, error)
    }

    private func failed(_ view: WKWebView, _ error: Error) {
        guard view === webView else { return }
        let error = error as NSError
        // A superseded or redirected load is followed by the navigation that replaced it.
        if (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102) {
            documentReadyTask?.cancel()
            documentReadyTask = nil
            currentNavigation = nil
            return
        }
        record(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        discardWebView()
        record(.failure(EventRegistrationError.unavailable))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let mainFrame = navigationAction.targetFrame?.isMainFrame != false
        if !mainFrame || url.scheme == "about" || Self.samePage(url, origin, pathOnly: false) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        guard webView === self.webView else { return }
        print("[EventRegistration] 阻擋非活動系統頁面 host=\(url.host ?? "-")")
        record(.failure(EventRegistrationError.unavailable))
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard webView === self.webView else { completionHandler(); return }
        dialogs.append(message)
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard webView === self.webView else { completionHandler(false); return }
        dialogs.append(message)
        // Only a cancellation the user already confirmed in the app may answer the school's prompt.
        completionHandler(acceptsConfirmation)
    }

    // MARK: Helpers

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL else {
            throw EventRegistrationError.invalidResponse
        }
        return url
    }

    private static func registeredMessage(_ prefix: String, state: String) -> String {
        let state = state.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.isEmpty ? "\(prefix)。" : "\(prefix)，目前狀態：\(state)。"
    }

    nonisolated static func isEventID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validated(_ eventID: String) throws -> String {
        let value = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEventID(value) else { throw EventRegistrationError.invalidResponse }
        return value
    }

    nonisolated static func isLoginPage(_ url: URL) -> Bool {
        url.path.lowercased().hasPrefix("/mvcteam/account/login")
    }

    nonisolated static func samePage(_ lhs: URL, _ rhs: URL, pathOnly: Bool = true) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased(), lhs.port == rhs.port else { return false }
        guard pathOnly else { return true }
        func trimmed(_ url: URL) -> String {
            let path = url.path.lowercased()
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return trimmed(lhs) == trimmed(rhs)
    }

    /// application/x-www-form-urlencoded; `+`, `&` and `=` in user input must be escaped.
    nonisolated static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-._* ")
        func encode(_ value: String) -> String {
            (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").replacingOccurrences(of: " ", with: "+")
        }
        return Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }

    nonisolated static func normalized(_ error: Error) -> Error {
        if error is CancellationError || error is EventRegistrationError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .networkConnectionLost:
                return EventRegistrationError.offline
            case .timedOut: return EventRegistrationError.timedOut
            case .cancelled: return CancellationError()
            default: return EventRegistrationError.unavailable
            }
        }
        return EventRegistrationError.unavailable
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private nonisolated enum Scripts {
    static let login = """
    if (location.pathname.toLowerCase().indexOf('/mvcteam/account/login') !== 0) { return 'not_login_page'; }
    function pick(selectors) {
      for (const selector of selectors) { const el = document.querySelector(selector); if (el) { return el; } }
      return null;
    }
    const user = pick(['input[name="Account"]', '#Account', 'input[id*="Account"]', 'input[name*="account" i]',
                       'input[type="text"]', 'input[type="email"]']);
    const pass = pick(['input[name="Password"]', '#Password', 'input[id*="Password"]', 'input[name*="password" i]',
                       'input[type="password"]']);
    if (!user || !pass) { return 'missing_fields'; }
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    for (const [field, value] of [[user, account], [pass, password]]) {
      field.focus();
      setter.call(field, value);
      field.dispatchEvent(new Event('input', {bubbles: true}));
      field.dispatchEvent(new Event('change', {bubbles: true}));
    }
    const form = user.closest('form') || pass.closest('form') || document.querySelector('form');
    const button = document.querySelector('button[type="submit"], input[type="submit"], button.btn-primary');
    if (!form && !button) { return 'missing_submit'; }
    // Submit after returning so the navigation cannot interrupt this script's result.
    setTimeout(() => {
      if (form && typeof form.requestSubmit === 'function') { form.requestSubmit(); }
      else if (form) { form.submit(); }
      else { button.click(); }
    }, 0);
    return 'submitted';
    """

    static let pageText = """
    return document.body ? document.body.innerText.slice(0, 4000) : '';
    """

    static let feedback = """
    const selectors = '.validation-summary-errors, .field-validation-error, .alert-danger, .alert-warning, .alert-info, .alert-success';
    return JSON.stringify(Array.from(document.querySelectorAll(selectors))
      .map(el => el.innerText.trim()).filter(Boolean).slice(0, 10));
    """

    static let cancel = """
    const token = document.querySelector('[name="__RequestVerificationToken"]')?.value;
    const signId = document.querySelector('[name="SignId"]')?.value;
    const applyId = document.querySelector('[name="ApplyId"]')?.value;
    if (!token || !signId || !applyId) { return 'missing_fields'; }
    const button = Array.from(document.querySelectorAll('input[type="submit"], button[type="submit"]'))
      .find(el => (el.value || el.innerText || '').includes('取消'));
    if (!button) { return 'no_cancel_button'; }
    setTimeout(() => button.click(), 0);
    return 'submitted';
    """

    static let form = """
    const value = selector => document.querySelector(selector)?.value || '';
    const checked = (name, fallback) => document.querySelector('input[name="' + name + '"]:checked')?.value || fallback;
    const result = {
      tel: value('input[name="SignTEL"]'), mail: value('input[name="SignEmail"]'),
      memo: value('textarea[name="SignMemo"]'), food: checked('Food', '3'), proof: checked('Proof', '1'),
      token: value('input[name="__RequestVerificationToken"]'), signID: value('input[name="SignId"]'),
      applyID: value('input[name="ApplyId"]'), role: '', classes: '', studentID: '', name: ''
    };
    document.querySelectorAll('label, div, span, p').forEach(el => {
      const text = el.textContent.trim();
      if (text.startsWith('本校在校生') || text.startsWith('校外人士')) { result.role = text; }
      if (/^(大學|專科)/.test(text)) { result.classes = text; }
      if (/^[A-Z][0-9]{7}$/.test(text)) { result.studentID = text; }
      if (text.length > 2 && text.length < 10 && !text.includes(' ') && /[\\u4e00-\\u9fa5]/.test(text)
          && el.previousElementSibling && el.previousElementSibling.textContent.includes('姓名')) {
        result.name = text;
      }
    });
    return JSON.stringify(result);
    """

    static let available = """
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

    static let applied = """
        (function() {
            var data = [];
            var container = document.querySelector('.col-md-11.col-md-offset-1.col-sm-10.col-xs-12.col-xs-offset-0');
            if (!container) { throw new Error('event_list_not_ready'); }
            var rows = container.querySelectorAll('.row.enr-list-sec');
            var rowStates = document.querySelectorAll('.row.bg-warning');
            var count = rows.length;
            for(let i=0; i<count; i++) {
                let row = rows[i];
                let row_state = rowStates[i];
                let dialog = row.querySelector('.table');
                if (!row || !dialog) { throw new Error('applied_event_incomplete'); }
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
                if (!/^[0-9]+$/.test(eventSerialID)) { throw new Error('applied_event_id_missing'); }
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
}
