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

    private var sessionRefreshAttempted = false

    init() {
        loadGraduationData()
    }

    func refresh() {
        sessionRefreshAttempted = false
        graduationData = nil
        loadGraduationData()
    }

    func toggleWebView() {
        if graduationData != nil {
            isWebVisible.toggle()
        }
    }

    private func loadGraduationData() {
        loadState = .loading
        showWebView = true
    }

    func handleWebResult(_ result: GraduationThresholdWebResult) {
        showWebView = false

        switch result {
        case .success(let data):
            sessionRefreshAttempted = false
            graduationData = data
            loadState = .loaded

        case .sessionExpired:
            if !sessionRefreshAttempted {
                sessionRefreshAttempted = true
                Task {
                    let refreshed = await SSOSessionService.shared.requestRefresh()
                    if refreshed {
                        self.showWebView = true
                    } else {
                        self.loadState = .error("SSO 登入失敗\n\n請在「設定」頁面重新登入後再試")
                    }
                }
            } else {
                sessionRefreshAttempted = false
                loadState = .error("SSO 登入失敗\n\n請在「設定」頁面重新登入後再試")
            }

        case .failure(let message):
            sessionRefreshAttempted = false
            loadState = .error(message)
        }
    }

    func textColor(for ability: String?) -> Color {
        if let ability = ability, ability.contains("未") {
            return .red
        } else {
            return .green
        }
    }
}
