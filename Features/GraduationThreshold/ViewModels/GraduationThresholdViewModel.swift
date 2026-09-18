import SwiftUI
import WebKit
import Combine

@MainActor
final class GraduationThresholdViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Published var loadState: LoadState = .idle
    @Published var graduationData: GraduationData?
    @Published var showWebView = false
    @Published var isWebVisible = false
    @Published var isFetchingInBackground = false  // background refresh while showing cache
    @Published private(set) var isRefreshing = false
    @Published private(set) var webViewID = UUID()
    @Published private(set) var lastRefreshError: String?
    @Published private(set) var lastUpdated: Date?

    private var sessionRefreshAttempted = false
    private var operationID = UUID()
    private var sessionRefreshTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    private let cacheKey: String?
    private let cacheDefaults: UserDefaults
    private let refreshTimeout: Duration

    init(cacheDefaults: UserDefaults = .standard, account: String? = nil,
         refreshTimeout: Duration = .seconds(90)) {
        self.cacheDefaults = cacheDefaults
        self.refreshTimeout = refreshTimeout
        let owner = (account ?? cacheDefaults.string(forKey: "app.user.username") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cacheKey = owner.isEmpty ? nil : "graduationThreshold.v2.cachedData.\(owner)"
        loadGraduationData()
    }

    func refresh() {
        guard !isRefreshing, !showWebView else { return }
        operationID = UUID()
        webViewID = UUID()
        lastRefreshError = nil
        isRefreshing = true
        sessionRefreshAttempted = false
        isFetchingInBackground = graduationData != nil
        if graduationData == nil { loadState = .loading }
        showWebView = true
        scheduleLoadTimeout()
    }

    /// Network loading has its own budget; interactive SSO has a separate timeout.
    private func scheduleLoadTimeout() {
        let operation = operationID
        let timeout = refreshTimeout
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.operationID == operation, self.isRefreshing else { return }
            self.fail("畢業門檻更新逾時，請稍後重試")
        }
    }

    func refreshAndWait() async {
        refresh()
        let operation = operationID
        while isRefreshing && operationID == operation && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    func toggleWebView() {
        if graduationData != nil {
            isWebVisible.toggle()
        }
    }

    private func loadGraduationData() {
        if let cached = loadFromCache() {
            graduationData = cached.data
            lastUpdated = cached.fetchedAt
            loadState = .loaded
        } else {
            refresh()
        }
    }

    func handleWebResult(_ result: GraduationThresholdWebResult, requestID: UUID) {
        guard isRefreshing, showWebView, requestID == webViewID else { return }
        showWebView = false

        switch result {
        case .success(let data):
            finishOperation()
            let date = Date()
            saveToCache(CachedGraduationData(data: data, fetchedAt: date))
            lastUpdated = date
            graduationData = data
            loadState = .loaded

        case .sessionExpired:
            // One real SSO re-login per operation, then rebuild acade cookies
            // using a fresh GUID in a new WebView.
            if !sessionRefreshAttempted {
                sessionRefreshAttempted = true
                let operation = operationID
                timeoutTask?.cancel()
                timeoutTask = nil
                sessionRefreshTask = Task { [weak self] in
                    let refreshed = await SSOSessionService.shared.requestRefresh(force: true)
                    guard !Task.isCancelled, let self,
                          self.operationID == operation, self.isRefreshing else { return }
                    if refreshed {
                        self.scheduleLoadTimeout()
                        self.webViewID = UUID()
                        self.showWebView = true
                    } else {
                        self.fail(SSOSessionService.shared.lastFailureMessage
                        ?? "無法更新校務登入，請稍後重試，或到設定重新登入")
                    }
                }
            } else {
                fail("教務系統登入仍已逾時，請稍後重試，或到設定重新登入")
            }

        case .failure(let message):
            fail(message)
        }
    }

    private func finishOperation() {
        operationID = UUID()
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        showWebView = false
        isRefreshing = false
        isFetchingInBackground = false
        sessionRefreshAttempted = false
    }

    private func fail(_ message: String) {
        finishOperation()
        lastRefreshError = message
        if graduationData == nil { loadState = .error(message) }
    }

    func textColor(for ability: String?) -> Color {
        if let ability = ability, ability.contains("未") {
            return .red
        } else {
            return .green
        }
    }

    // MARK: - Cache

    private func loadFromCache() -> CachedGraduationData? {
        guard let cacheKey, let data = cacheDefaults.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode(CachedGraduationData.self, from: data)
        else { return nil }
        return decoded
    }

    private func saveToCache(_ cached: CachedGraduationData) {
        if let cacheKey, let data = try? JSONEncoder().encode(cached) {
            cacheDefaults.set(data, forKey: cacheKey)
        }
    }

}
