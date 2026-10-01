import Foundation
import WebKit

@MainActor
protocol LibraryEquipmentServing: AnyObject {
    var webView: WKWebView? { get }
    var onWebViewCreated: ((WKWebView) -> Void)? { get set }
    func connect(account: String, password: String?) async throws
    func resumeLogin() async throws
    func groups() async throws -> [LibraryEquipmentGroup]
    func schedule(groupID: Int, date: Date) async throws -> LibraryEquipmentSchedule
    func policy(groupID: Int, equipmentID: Int, date: Date) async throws -> LibraryEquipmentPolicy
    func reservations() async throws -> [LibraryEquipmentReservation]
    func reserve(_ draft: LibraryEquipmentDraft) async throws
    func cancelReservation(_ reservation: LibraryEquipmentReservation) async throws
    func close()
}

@MainActor
final class LibraryEquipmentService: NSObject, LibraryEquipmentServing, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    var onWebViewCreated: ((WKWebView) -> Void)?
    private var navigation: WKNavigation?
    private var navigationWaiter: CheckedContinuation<Void, Error>?
    private var navigationTimeout: Task<Void, Never>?
    private var scripts: [UUID: CheckedContinuation<String, Error>] = [:]
    private var csrfToken: String?
    private var owner = ""
    private var generation = UUID()
    private let origin = "https://webpacx.niu.edu.tw"

    private enum LoginAttempt { case authenticated, interactive, retry }
    private static let loginAttempts = 3
    private static let loginSubmissions = 2

    func connect(account: String, password: String?) async throws {
        close()
        owner = account.lowercased()
        let operation = generation
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        onWebViewCreated?(view)
        guard let url = URL(string: origin + "/equipment") else { throw LibraryEquipmentError.invalidResponse }
        // Slow page hydration or a delayed session cookie are retried quietly; the school's page is
        // shown only for CAPTCHA, a missing password, or after every bounded attempt has failed.
        var submissions = 0
        var lastError: Error = LibraryEquipmentError.loginRequired
        for attempt in 0..<Self.loginAttempts {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(attempt))
                try check(operation)
            }
            do {
                let canSubmit = submissions < Self.loginSubmissions
                switch try await attemptLogin(url, account: account, password: canSubmit ? password : nil,
                                              operation: operation, submitted: { submissions += 1 }) {
                case .authenticated: return
                case .interactive: throw LibraryEquipmentError.loginRequired
                case .retry: lastError = LibraryEquipmentError.loginRequired
                }
            } catch let error where Self.isTransient(error) {
                try check(operation)
                lastError = error
            }
        }
        throw lastError
    }

    private func attemptLogin(_ url: URL, account: String, password: String?, operation: UUID,
                              submitted: () -> Void) async throws -> LoginAttempt {
        try await load(url)
        try check(operation)
        if try await authenticate() { return .authenticated }
        // The school's form handles its own AES encryption. CAPTCHA is never solved automatically.
        let loginState = try await script(LibraryEquipmentJavaScript.login, arguments: [
            "account": account, "password": password ?? ""
        ])
        try check(operation)
        switch loginState {
        case "submitted": submitted()
        case "interactive": return .interactive
        default: return .retry
        }
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            try check(operation)
            do {
                if try await authenticate() { return .authenticated }
            } catch let error where Self.isTransient(error) || error is CancellationError {
                // The page may still be navigating after the form submission.
                try check(operation)
            }
        }
        return .retry
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let error = error as? LibraryEquipmentError {
            return [.timedOut, .unavailable, .invalidResponse].contains(error)
        }
        if let error = error as? URLError {
            // Offline is reported immediately; a load interrupted by the school's redirect is retried.
            return ![.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
        }
        let error = error as NSError
        // WebKit reports an interrupted page load (e.g. a redirect during login) as 102.
        return error.domain == "WebKitErrorDomain" && error.code == 102
    }

    func resumeLogin() async throws {
        guard try await authenticate() else { throw LibraryEquipmentError.loginRequired }
    }

    func groups() async throws -> [LibraryEquipmentGroup] {
        let result: LibraryEquipmentDecoding.GroupResult = try await query(
            "getEquipmentGroupInfo", document: LibraryEquipmentQueries.groups, variables: ["groupId": 0])
        return result.groups
    }

    func schedule(groupID: Int, date: Date) async throws -> LibraryEquipmentSchedule {
        let result: LibraryEquipmentDecoding.ScheduleResult = try await query(
            "getEquipmentInfo", document: LibraryEquipmentQueries.schedule,
            variables: ["groupId": groupID, "startdate": LibraryEquipmentDate.format(date)])
        return try result.schedule()
    }

    func policy(groupID: Int, equipmentID: Int, date: Date) async throws -> LibraryEquipmentPolicy {
        let result: LibraryEquipmentDecoding.PolicyResult = try await query(
            "getDayReservedByReader", document: LibraryEquipmentQueries.policy,
            variables: ["groupId": groupID, "equipId": equipmentID, "reserveDate": LibraryEquipmentDate.format(date)])
        return try result.policy()
    }

    func reservations() async throws -> [LibraryEquipmentReservation] {
        let result: LibraryEquipmentDecoding.ReservationsResult = try await query(
            "getEquipmentByReader", document: LibraryEquipmentQueries.reservations, variables: [:])
        return try result.reservations()
    }

    func reserve(_ draft: LibraryEquipmentDraft) async throws {
        try await mutate("reserveEquipmentCir", document: LibraryEquipmentQueries.reserve, variables: [
            "starttime": LibraryEquipmentDate.format(draft.start, pattern: "yyyy/MM/dd HH:mm"),
            "endtime": LibraryEquipmentDate.format(draft.end, pattern: "yyyy/MM/dd HH:mm"),
            "equipId": draft.equipment.id, "groupId": draft.group.id,
            // This is the school's public client parameter; account identity comes from its session.
            "muserid": 100
        ])
    }

    func cancelReservation(_ reservation: LibraryEquipmentReservation) async throws {
        try await mutate("cancelEquipmentCir", document: LibraryEquipmentQueries.cancel,
                         variables: ["eccId": reservation.id, "eccIds": ""])
    }

    private func mutate(_ operation: String, document: String, variables: [String: Any]) async throws {
        // Authenticate before starting the mutation, so login failures cannot trigger a replay.
        guard try await authenticate() else { throw LibraryEquipmentError.loginRequired }
        let result: LibraryEquipmentDecoding.MutationResult
        do {
            result = try await query(operation, document: document, variables: variables, authenticated: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch LibraryEquipmentError.loginRequired {
            throw LibraryEquipmentError.loginRequired
        } catch {
            throw LibraryEquipmentError.uncertainMutation
        }
        guard let response = result.reserveEquipmentCir ?? result.cancelEquipmentCir else {
            throw LibraryEquipmentError.uncertainMutation
        }
        guard response.success else {
            let message = response.message ?? ""
            let containsChinese = message.range(of: "\\p{Han}", options: .regularExpression) != nil
            throw LibraryEquipmentError.rejected(
                containsChinese && !message.contains("<") && !message.contains("http")
                ? String(message.prefix(240))
                : "校方未接受這次操作，請重新整理資料，或開啟校方設備頁確認。")
        }
    }

    private func query<T: Decodable & Sendable>(_ operation: String, document: String,
                                               variables: [String: Any], authenticated: Bool = false) async throws -> T {
        let operationID = generation
        if !authenticated {
            guard try await authenticate() else { throw LibraryEquipmentError.loginRequired }
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "operationName": operation, "query": document, "variables": variables
        ])
        guard let payload = String(data: body, encoding: .utf8), let csrfToken else {
            throw LibraryEquipmentError.loginRequired
        }
        let result = try await script(LibraryEquipmentJavaScript.request, arguments: [
            "path": "/api/HyLibWS/graphql", "body": payload, "csrf": csrfToken
        ])
        try check(operationID)
        return try await LibraryEquipmentTransport.decode(result)
    }

    private func authenticate() async throws -> Bool {
        let operation = generation
        let result = try await script(LibraryEquipmentJavaScript.authentication, arguments: ["account": owner])
        try check(operation)
        struct Authentication: Decodable { let authenticated: Bool; let csrf: String? }
        guard let data = result.data(using: .utf8) else { throw LibraryEquipmentError.invalidResponse }
        let state = try JSONDecoder().decode(Authentication.self, from: data)
        csrfToken = state.authenticated ? state.csrf : nil
        return state.authenticated && csrfToken != nil
    }

    private func load(_ url: URL) async throws {
        let operation = generation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, let webView else {
                    continuation.resume(throwing: CancellationError()); return
                }
                navigationWaiter = continuation
                navigation = webView.load(URLRequest(url: url))
                navigationTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    self?.finishNavigation(.failure(LibraryEquipmentError.timedOut))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == operation else { return }
                self?.finishNavigation(.failure(CancellationError()))
                self?.webView?.stopLoading()
            }
        }
    }

    private func script(_ source: String, arguments: [String: Any]) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, let webView,
                      webView.url?.host == "webpacx.niu.edu.tw" else {
                    continuation.resume(throwing: CancellationError()); return
                }
                scripts[id] = continuation
                var args = arguments
                args["requestID"] = id.uuidString
                webView.callAsyncJavaScript(source, arguments: args, in: nil, in: .page) { [weak self] result in
                    guard let continuation = self?.scripts.removeValue(forKey: id) else { return }
                    switch result {
                    case .success(let value):
                        guard let text = value as? String else {
                            continuation.resume(throwing: LibraryEquipmentError.invalidResponse); return
                        }
                        continuation.resume(returning: text)
                    case .failure:
                        continuation.resume(throwing: LibraryEquipmentError.timedOut)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let continuation = self.scripts.removeValue(forKey: id) else { return }
                continuation.resume(throwing: CancellationError())
                self.webView?.callAsyncJavaScript(
                    "window.__niuEquipmentRequests?.get(requestID)?.abort(); return '';",
                    arguments: ["requestID": id.uuidString], in: nil, in: .page, completionHandler: nil)
            }
        }
    }

    private func check(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard operation == generation else { throw CancellationError() }
    }

    func close() {
        generation = UUID()
        finishNavigation(.failure(CancellationError()))
        let pending = Array(scripts.values)
        scripts.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
        csrfToken = nil
        owner = ""
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        if let blank = URL(string: "about:blank") { webView?.load(URLRequest(url: blank)) }
        webView = nil
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        navigationTimeout?.cancel()
        navigationTimeout = nil
        navigation = nil
        let waiter = navigationWaiter
        navigationWaiter = nil
        waiter?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        finishNavigation(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        finishNavigation(.failure(error))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        finishNavigation(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(.failure(LibraryEquipmentError.unavailable))
        let pending = Array(scripts.values)
        scripts.removeAll()
        pending.forEach { $0.resume(throwing: LibraryEquipmentError.unavailable) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler((url.scheme == "https" && url.host == "webpacx.niu.edu.tw") || url.scheme == "about" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        presentPanel(webView, message: message, confirm: false) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        presentPanel(webView, message: message, confirm: true, completion: completionHandler)
    }

    private func presentPanel(_ view: WKWebView, message: String, confirm: Bool,
                              completion: @escaping (Bool) -> Void) {
        guard var controller = view.window?.rootViewController else {
            completion(false)
            return
        }
        while let presented = controller.presentedViewController { controller = presented }
        let panel = UIAlertController(title: "圖書館", message: message, preferredStyle: .alert)
        if confirm {
            panel.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        }
        panel.addAction(UIAlertAction(title: "確定", style: .default) { _ in completion(true) })
        controller.present(panel, animated: true)
    }
}

nonisolated enum LibraryEquipmentTransport {
    struct HTTPResult: Decodable { let status: Int; let text: String }
    struct GraphQL<T: Decodable>: Decodable {
        let data: T?
        let errors: [GraphError]?
        struct GraphError: Decodable { let message: String }
    }
    @concurrent
    static func decode<T: Decodable & Sendable>(_ text: String) async throws -> T {
        guard let data = text.data(using: .utf8), data.count <= 4_000_000 else {
            throw LibraryEquipmentError.invalidResponse
        }
        let http = try JSONDecoder().decode(HTTPResult.self, from: data)
        if [401, 403].contains(http.status) { throw LibraryEquipmentError.loginRequired }
        guard http.status == 200 else { throw LibraryEquipmentError.unavailable }
        let payload = try JSONDecoder().decode(GraphQL<T>.self, from: Data(http.text.utf8))
        guard payload.errors?.isEmpty != false, let result = payload.data else {
            throw LibraryEquipmentError.invalidResponse
        }
        return result
    }
}

nonisolated enum LibraryEquipmentJavaScript {
    static let login = """
    for (let i = 0; i < 20; i++) {
      const user = document.querySelector('#logxinid'), pass = document.querySelector('#pincode');
      if (user && pass) {
        const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        set.call(user, account);
        user.dispatchEvent(new Event('input', {bubbles:true}));
        user.dispatchEvent(new Event('change', {bubbles:true}));
        if (!password || document.querySelector('#captcha')) return 'interactive';
        set.call(pass, password);
        pass.dispatchEvent(new Event('input', {bubbles:true}));
        pass.dispatchEvent(new Event('change', {bubbles:true}));
        const submit = [...document.querySelectorAll('input[type=submit]')].find(e => e.offsetParent);
        if (submit) { submit.click(); return 'submitted'; }
      }
      await new Promise(r => setTimeout(r, 250));
    }
    return 'missing';
    """

    static let authentication = """
    const controller = new AbortController();
    window.__niuEquipmentRequests ||= new Map();
    window.__niuEquipmentRequests.set(requestID, controller);
    const timeout = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch('/equipment', {credentials:'include', cache:'no-store', signal:controller.signal});
      if (!response.ok) throw new Error('LIBRARY_HTTP');
      const doc = new DOMParser().parseFromString(await response.text(), 'text/html');
      const node = doc.querySelector('#__NEXT_DATA__');
      if (!node) throw new Error('LIBRARY_DATA');
      const props = JSON.parse(node.textContent).props?.pageProps;
      const code = props?.session?.readerCode;
      const sameAccount = typeof code === 'string' && code.length > 0
        && code.toLowerCase() === account.toLowerCase();
      return JSON.stringify({authenticated: !!props?.auth && sameAccount, csrf: props?.session?.csrfToken || null});
    } finally {
      clearTimeout(timeout);
      window.__niuEquipmentRequests.delete(requestID);
    }
    """

    static let request = """
    const controller = new AbortController();
    window.__niuEquipmentRequests ||= new Map();
    window.__niuEquipmentRequests.set(requestID, controller);
    const timeout = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await fetch(path, {
        method:'POST', credentials:'include', signal:controller.signal,
        headers:{'Content-Type':'application/json', 'X-CSRF-Token':csrf}, body
      });
      return JSON.stringify({status:response.status, text:await response.text()});
    } finally {
      clearTimeout(timeout);
      window.__niuEquipmentRequests.delete(requestID);
    }
    """
}

nonisolated enum LibraryEquipmentQueries {
    static let groups = """
    query getEquipmentGroupInfo($groupId: Int) {
      getEquipmentGroupInfo(groupId: $groupId) {
        eqgroupitemlist {
          equipmentGroup { id name }
          ebPolicy { timeType }
          useNum equipmentNum
        }
      }
    }
    """
    static let schedule = """
    query getEquipmentInfo($groupId: Int, $startdate: String) {
      getEquipmentInfoList(groupId: $groupId) { eqgroupitemlist { equipment { id name } } }
      getReserveEquipmentList(groupId: $groupId, startdate: $startdate) {
        eqgroupitemlist { equipmentCir { equipmentId startDate endDate } }
      }
    }
    """
    static let policy = """
    query getDayReservedByReader($groupId: Int, $equipId: Int, $reserveDate: String) {
      getDayReservedByReader(groupId: $groupId, equipId: $equipId, reserveDate: $reserveDate) {
        success data message
      }
    }
    """
    static let reservations = """
    query getEquipmentByReader {
      reservelist: getEquipmentByReader(status: "Reserve") {
        success
        eqgroupitemlist {
          equipment { id name }
          equipmentCir { startDate endDate reserveKeepDate }
          equipmentCirContent { id }
        }
      }
    }
    """
    static let reserve = """
    mutation reserveEquipmentCir($starttime: String, $endtime: String, $equipId: Int, $groupId: Int, $muserid: Int) {
      reserveEquipmentCir(starttime: $starttime, endtime: $endtime, equipId: $equipId, groupId: $groupId, muserid: $muserid) {
        success message
      }
    }
    """
    static let cancel = """
    mutation cancelEquipmentCir($eccId: Int, $eccIds: String) {
      cancelEquipmentCir(eccId: $eccId, eccIds: $eccIds) { success message }
    }
    """
}
