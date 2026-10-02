import Foundation
import Combine
import WebKit

@MainActor
final class EnrollmentCertificateViewModel: ObservableObject {
    @Published private(set) var snapshot: EnrollmentSnapshot?
    @Published private(set) var pdfData: Data?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingPDF = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var certificateLoginURL: URL?
    @Published private(set) var registrationWebView: WKWebView?
    @Published private(set) var loadStage = EnrollmentLoadStage.connecting

    private var task: Task<Void, Never>?
    private var registrationService: EnrollmentRegistrationService?
    private var generation = UUID()
    private var sessionID: String?
    private var account = ""

    // Injected closures allow offline cancellation/account-switch regression tests.
    private let currentSession: @MainActor () -> String?
    private let currentAccount: @MainActor () -> String?
    private let refreshSession: @MainActor () async -> Bool
    private let loadRegistration: (@MainActor (String) async throws -> EnrollmentSnapshot)?
    private let makeRegistrationService: @MainActor () -> EnrollmentRegistrationService
    private let loadPDF: @MainActor (String) async throws -> Data

    init(currentSession: @escaping @MainActor () -> String? = { UserDefaults.standard.string(forKey: StorageKeys.authSessionID) },
         currentAccount: @escaping @MainActor () -> String? = { UserDefaults.standard.string(forKey: "app.user.username") },
         refreshSession: @escaping @MainActor () async -> Bool = { await SSOSessionService.shared.requestRefresh(force: true) },
         loadRegistration: (@MainActor (String) async throws -> EnrollmentSnapshot)? = nil,
         makeRegistrationService: @escaping @MainActor () -> EnrollmentRegistrationService = { EnrollmentRegistrationService() },
         loadPDF: @escaping @MainActor (String) async throws -> Data = { studentID in
             let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
             return try await EnrollmentPDFService(studentID: studentID).load(cookies: cookies)
         }) {
        self.currentSession = currentSession
        self.currentAccount = currentAccount
        self.refreshSession = refreshSession
        self.loadRegistration = loadRegistration
        self.makeRegistrationService = makeRegistrationService
        self.loadPDF = loadPDF
    }

    func refresh() {
        cancel()
        guard let session = currentSession(), let owner = currentAccount(), !owner.isEmpty else {
            errorMessage = "請先登入後再查詢在學證明"; return
        }
        sessionID = session
        account = owner
        isLoading = true
        errorMessage = nil
        let operation = generation
        task = Task { [weak self] in
            guard let self else { return }
            #if DEBUG
            let startedAt = ProcessInfo.processInfo.systemUptime
            defer { print("[Enrollment] 整體查詢結束 elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))") }
            #endif
            do {
                let result = try await self.fetchRegistrationWithRetry(operation: operation)
                guard self.isCurrent(operation) else { return }
                guard result.records.allSatisfy({ $0.studentID.caseInsensitiveCompare(owner) == .orderedSame }) else {
                    throw EnrollmentError.invalidResponse
                }
                self.snapshot = result
                self.updatedAt = Date()
            } catch {
                if self.isCurrent(operation), !(error is CancellationError) { self.errorMessage = Self.message(for: error) }
            }
            if self.isCurrent(operation) { self.isLoading = false; self.task = nil }
        }
    }

    private func fetchRegistrationWithRetry(operation: UUID) async throws -> EnrollmentSnapshot {
        do { return try await fetchRegistration() }
        catch EnrollmentError.sessionExpired {
            guard isCurrent(operation), await refreshSession(), isCurrent(operation) else { throw EnrollmentError.sessionExpired }
            return try await fetchRegistration()
        }
    }

    private func fetchRegistration() async throws -> EnrollmentSnapshot {
        if let loadRegistration { return try await loadRegistration(account) }
        let service = makeRegistrationService()
        registrationService = service
        registrationWebView = service.webView
        service.onProgress = { [weak self, weak service] stage in
            guard let self, let service, self.registrationService === service else { return }
            self.loadStage = stage
        }
        defer {
            if registrationService === service {
                registrationService = nil
                registrationWebView = nil
            }
        }
        return try await service.load(account: account)
    }

    func showCertificate() {
        guard !isLoading, !isLoadingPDF, snapshot?.canPrint == true,
              let studentID = snapshot?.records.first?.studentID, isCurrent(generation) else { return }
        isLoadingPDF = true
        errorMessage = nil
        pdfData = nil
        let operation = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.loadPDF(studentID)
                guard self.isCurrent(operation) else { return }
                self.pdfData = data
                self.certificateLoginURL = nil
            } catch EnrollmentError.sessionExpired {
                if self.isCurrent(operation) {
                    self.certificateLoginURL = EnrollmentEndpoint.certificate(studentID: studentID)
                    self.errorMessage = "證明服務需要另外登入，請開啟校方登入頁完成後再取得 PDF"
                }
            } catch {
                if self.isCurrent(operation), !(error is CancellationError) { self.errorMessage = Self.message(for: error) }
            }
            if self.isCurrent(operation) { self.isLoadingPDF = false; self.task = nil }
        }
    }

    func refreshAndWait() async {
        refresh()
        let operation = generation
        await withTaskCancellationHandler {
            await task?.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == operation else { return }
                self.cancel()
            }
        }
    }

    func dismissCertificate() { pdfData = nil }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        registrationService?.cancel()
        registrationService = nil
        registrationWebView = nil
        loadStage = .connecting
        snapshot = nil
        pdfData = nil
        updatedAt = nil
        certificateLoginURL = nil
        isLoading = false
        isLoadingPDF = false
        sessionID = nil
    }

    private func isCurrent(_ operation: UUID) -> Bool {
        !Task.isCancelled && generation == operation && sessionID != nil
            && sessionID == currentSession() && account.lowercased() == currentAccount()?.lowercased()
    }

    static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "目前無法連線，請連上網路後重試"
            case .timedOut: return "校方回應逾時，請稍後重試"
            case .cancelled: return "載入已取消，請重試"
            default: return "校方連線失敗，請稍後重試"
            }
        }
        switch error as? EnrollmentError {
        case .sessionExpired: return "校務登入已失效，請重試，或到設定重新登入"
        case .unavailable: return "校方目前無法提供在學證明，請確認註冊狀態後重試"
        case .tooLarge: return "校方回傳的檔案過大，請改由校務系統查看"
        default: return "校方回傳的資料或 PDF 無法辨識，請稍後重試"
        }
    }
}
