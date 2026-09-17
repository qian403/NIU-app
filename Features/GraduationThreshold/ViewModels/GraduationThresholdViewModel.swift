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

    private var sessionRefreshAttempted = false

    private let cacheKey = "graduationThreshold.v1.cachedData"

    init() {
        loadGraduationData()
    }

    func refresh() {
        guard !isRefreshing, !showWebView else { return }
        isRefreshing = true
        sessionRefreshAttempted = false
        isFetchingInBackground = graduationData != nil
        if graduationData == nil { loadState = .loading }
        showWebView = true
    }

    func refreshAndWait() async {
        refresh()
        let deadline = Date().addingTimeInterval(90)
        while isRefreshing && !Task.isCancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        if isRefreshing {
            isRefreshing = false
            isFetchingInBackground = false
            showWebView = false
            if graduationData == nil { loadState = .error("畢業門檻更新逾時，請稍後再試") }
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
            loadState = .loaded
        } else {
            loadState = .loading
            showWebView = true
        }
    }

    func handleWebResult(_ result: GraduationThresholdWebResult) {
        showWebView = false

        switch result {
        case .success(let data):
            isRefreshing = false
            sessionRefreshAttempted = false
            isFetchingInBackground = false
            saveToCache(CachedGraduationData(data: data, fetchedAt: Date()))
            graduationData = data
            loadState = .loaded

        case .sessionExpired:
            // Try a transparent SSO re-login first (only once per operation).
            // If cached data exists, keep showing it silently on failure.
            if !sessionRefreshAttempted {
                sessionRefreshAttempted = true
                Task {
                    let refreshed = await SSOSessionService.shared.requestRefresh()
                    if refreshed {
                        self.showWebView = true
                    } else {
                        self.isRefreshing = false
                        self.isFetchingInBackground = false
                        if self.graduationData == nil {
                            self.loadState = .error("SSO 登入失敗\n\n請在「設定」頁面重新登入後再試")
                        }
                    }
                }
            } else {
                sessionRefreshAttempted = false
                isRefreshing = false
                isFetchingInBackground = false
                if graduationData == nil {
                    loadState = .error("SSO 登入失敗\n\n請在「設定」頁面重新登入後再試")
                }
            }

        case .failure(let message):
            isRefreshing = false
            sessionRefreshAttempted = false
            isFetchingInBackground = false
            if graduationData == nil {
                loadState = .error(message)
            }
        }
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
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode(CachedGraduationData.self, from: data)
        else { return nil }
        return decoded
    }

    private func saveToCache(_ cached: CachedGraduationData) {
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

}
