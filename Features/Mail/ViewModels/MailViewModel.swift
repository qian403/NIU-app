import Foundation
import Combine

@MainActor
final class MailViewModel: ObservableObject {
    static let shared = MailViewModel()

    @Published private(set) var account = ""
    @Published private(set) var connectionStatus = "正在連接校園信箱…"
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsSchoolWebsite = false
    @Published private(set) var needsTwoFactor = false
    @Published private(set) var webSession: CampusMailWebSession?

    private let makeService: @MainActor () -> any CampusMailServing
    private let currentSession: @MainActor () -> String?
    private let savedCredentials: @MainActor () -> (username: String, password: String)?
    private let recognizeCaptcha: @Sendable (String) async throws -> String?
    private var service: (any CampusMailServing)?
    private var sessionID: String?
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(makeService: @escaping @MainActor () -> any CampusMailServing = { CampusMailService() },
         currentSession: @escaping @MainActor () -> String? = { UserDefaults.standard.string(forKey: StorageKeys.authSessionID) },
         savedCredentials: @escaping @MainActor () -> (username: String, password: String)? = { LoginRepository.shared.getSavedCredentials() },
         recognizeCaptcha: @escaping @Sendable (String) async throws -> String? = { try await MailCaptchaRecognizer.recognize(svg: $0) }) {
        self.makeService = makeService
        self.currentSession = currentSession
        self.savedCredentials = savedCredentials
        self.recognizeCaptcha = recognizeCaptcha
    }

    deinit {
        work?.cancel()
        service?.invalidate()
    }

    func prepare(account: String) {
        guard let session = currentSession(), !account.isEmpty else { reset(); return }
        let normalized = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if self.account != normalized || sessionID != session {
            reset()
            self.account = normalized
            sessionID = session
        }
        if !isAuthenticated, !isBusy { connect() }
    }

    func reset() {
        webSession?.invalidate()
        webSession = nil
        suspend()
        service?.invalidate()
        service = nil
        account = ""
        sessionID = nil
        isAuthenticated = false
        errorMessage = nil
        needsSchoolWebsite = false
        needsTwoFactor = false
    }

    func suspend() {
        generation = UUID()
        work?.cancel()
        work = nil
        isBusy = false
        if !isAuthenticated {
            service?.invalidate()
            service = nil
            needsTwoFactor = false
        }
    }

    func connect() {
        guard !account.isEmpty, !isAuthenticated, !isBusy,
              sessionID != nil, currentSession() == sessionID else { return }
        guard let credentials = savedCredentials(), !credentials.password.isEmpty,
              credentials.username.caseInsensitiveCompare(account) == .orderedSame else {
            errorMessage = CampusMailError.missingCredentials.errorDescription
            return
        }
        let token = beginWork()
        let account = self.account
        let recognize = recognizeCaptcha
        errorMessage = nil
        needsSchoolWebsite = false
        needsTwoFactor = false
        connectionStatus = "正在連接校園信箱…"
        work = Task { [weak self] in
            defer { self?.finishWork(token) }
            // Retry only recognition/rejected CAPTCHA failures, with a fresh isolated challenge.
            // Wrong credentials, additional verification and network errors stop immediately.
            for attempt in 1...3 {
                guard let self, self.isCurrent(token) else { return }
                self.service?.invalidate()
                let client = self.makeService()
                self.service = client
                do {
                    self.connectionStatus = attempt == 1 ? "正在連接校園信箱…" : "正在重新驗證（\(attempt)/3）…"
                    let challenge = try await client.challenge()
                    guard self.isCurrent(token) else { return }
                    var code = ""
                    if challenge.requiresCaptcha {
                        self.connectionStatus = "正在自動完成校方驗證…"
                        guard let svg = challenge.svg, let recognized = try await recognize(svg),
                              let candidate = MailCaptchaRecognizer.candidate(from: recognized) else {
                            throw CampusMailError.captchaRecognitionFailed
                        }
                        code = candidate
                    }
                    guard self.isCurrent(token) else { return }
                    self.connectionStatus = "正在登入校園信箱…"
                    try await client.login(account: account, password: credentials.password, captcha: code)
                    guard self.isCurrent(token) else { return }
                    try await self.finishAuthentication(client: client, token: token)
                    return
                } catch {
                    guard self.isCurrent(token) else { return }
                    if case CampusMailError.twoFactorRequired = error {
                        self.needsTwoFactor = true
                        self.errorMessage = CampusMailError.twoFactorRequired.errorDescription
                        return
                    }
                    client.invalidate()
                    self.service = nil
                    if let failure = error as? CampusMailError {
                        switch failure {
                        case .invalidCaptcha, .captchaRecognitionFailed:
                            if attempt < 3 { continue }
                            self.errorMessage = CampusMailError.captchaRecognitionFailed.errorDescription
                        case .additionalVerification:
                            self.needsSchoolWebsite = true
                            self.errorMessage = failure.errorDescription
                        default:
                            self.errorMessage = failure.errorDescription
                        }
                    } else {
                        self.errorMessage = Self.message(for: error)
                    }
                    return
                }
            }
        }
    }

    func submitTwoFactor(_ code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needsTwoFactor, !isBusy, !code.isEmpty, code.count <= 128,
              let client = service, currentSession() == sessionID else { return }
        let token = beginWork()
        let account = self.account
        errorMessage = nil
        connectionStatus = "正在確認二次驗證…"
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.finishWork(token) }
            do {
                try await client.completeTwoFactor(account: account, token: code)
                guard self.isCurrent(token) else { return }
                try await self.finishAuthentication(client: client, token: token)
            } catch {
                guard self.isCurrent(token) else { return }
                if case CampusMailError.additionalVerification = error {
                    self.needsSchoolWebsite = true
                    self.needsTwoFactor = false
                    client.invalidate()
                    self.service = nil
                } else if case CampusMailError.accountMismatch = error {
                    self.needsTwoFactor = false
                    client.invalidate()
                    self.service = nil
                } else if case CampusMailError.sessionExpired = error {
                    self.needsTwoFactor = false
                    client.invalidate()
                    self.service = nil
                }
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    private func finishAuthentication(client: any CampusMailServing, token: UUID) async throws {
        let cookies = try await client.webCookies()
        guard isCurrent(token) else { return }
        webSession = CampusMailWebSession(account: account, cookies: cookies)
        needsTwoFactor = false
        isAuthenticated = true
        finishWork(token)
    }

    func webSessionExpired(id: UUID, accountMismatch: Bool = false) {
        guard webSession?.id == id else { return }
        webSession?.invalidate()
        webSession = nil
        isAuthenticated = false
        suspend()
        errorMessage = accountMismatch
            ? CampusMailError.accountMismatch.errorDescription
            : "郵件登入已結束，請重新連線。若剛才正在寄信，請先查看寄件備份確認結果，避免重複寄出。"
    }

    private func beginWork() -> UUID {
        work?.cancel()
        generation = UUID()
        isBusy = true
        return generation
    }

    private func finishWork(_ token: UUID) {
        guard generation == token else { return }
        isBusy = false
        work = nil
    }

    private func isCurrent(_ token: UUID) -> Bool {
        generation == token && sessionID != nil && currentSession() == sessionID && !Task.isCancelled
    }

    private static func message(for error: Error) -> String? {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
        if let error = error as? CampusMailError { return error.errorDescription }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "郵件服務連線逾時，請重試。"
            case .notConnectedToInternet, .networkConnectionLost: return "目前無法連線，請檢查網路後重試。"
            default: return "無法連接校方郵件服務，請稍後重試。"
            }
        }
        return "無法讀取郵件資料，請稍後重試。"
    }
}
