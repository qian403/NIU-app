import Foundation
import Combine

/// 多元時數紀錄。The portal only answers on the campus network, so the last
/// successful snapshot is kept on this device and a refresh never replaces it
/// until new data has been fetched and parsed.
@MainActor
final class LearningHoursViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var snapshot: LearningHoursSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshError: String?
    @Published var selectedAbility: String?

    private let client: LearningHoursFetching
    private let defaults: UserDefaults
    private let credentials: () -> (username: String, password: String)?
    private var fetchTask: Task<Void, Never>?
    private var operationID = UUID()

    init(client: LearningHoursFetching = LearningHoursClient(),
         defaults: UserDefaults = .standard,
         credentials: (() -> (username: String, password: String)?)? = nil) {
        self.client = client
        self.defaults = defaults
        self.credentials = credentials ?? { LoginRepository.shared.getSavedCredentials() }
    }

    var filteredRecords: [LearningHoursRecord] {
        guard let records = snapshot?.records else { return [] }
        guard let selectedAbility else { return records }
        return records.filter { $0.ability == selectedAbility }
    }

    func start() {
        guard fetchTask == nil else { return }
        if let cached = loadCache() {
            snapshot = cached
            loadState = .loaded
        } else {
            snapshot = nil
            refresh()
        }
    }

    func stop() {
        operationID = UUID()
        fetchTask?.cancel()
        fetchTask = nil
        isRefreshing = false
        if snapshot == nil, loadState == .loading { loadState = .idle }
    }

    func refresh() {
        guard !isRefreshing else { return }
        let account = currentAccount
        guard let account, let saved = credentials(), saved.username.lowercased() == account else {
            fail(LearningHoursError.credentialsMissing)
            return
        }
        let operation = UUID()
        operationID = operation
        lastRefreshError = nil
        isRefreshing = true
        if snapshot == nil { loadState = .loading }

        let client = client
        fetchTask = Task { [weak self] in
            let result: Result<LearningHoursSnapshot, Error>
            do {
                result = .success(try await client.fetch(username: saved.username, password: saved.password))
            } catch {
                result = .failure(error)
            }
            guard let self, self.operationID == operation, !Task.isCancelled else { return }
            // Drop a response that finishes after logout or an account switch.
            guard self.currentAccount == account else {
                self.stop()
                return
            }
            self.fetchTask = nil
            self.isRefreshing = false
            switch result {
            case .success(let fresh):
                self.snapshot = fresh
                self.loadState = .loaded
                self.saveCache(fresh, account: account)
                if let selected = self.selectedAbility, !fresh.records.contains(where: { $0.ability == selected }) {
                    self.selectedAbility = nil
                }
            case .failure(let error) where error is CancellationError:
                if self.snapshot == nil { self.loadState = .idle }
            case .failure(let error):
                self.fail(error)
            }
        }
    }

    func refreshAndWait() async {
        refresh()
        await fetchTask?.value
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? LearningHoursError.invalidResponse.errorDescription!
        lastRefreshError = message
        if snapshot == nil { loadState = .error(message) }
    }

    // MARK: - Cache

    private var currentAccount: String? {
        let account = (defaults.string(forKey: "app.user.username") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return account.isEmpty ? nil : account
    }

    /// The `graduationThreshold.` prefix is cleared with other personal caches on logout.
    private func cacheKey(for account: String) -> String {
        "graduationThreshold.learningHours.v1.\(account)"
    }

    private func loadCache() -> LearningHoursSnapshot? {
        guard let account = currentAccount,
              let data = defaults.data(forKey: cacheKey(for: account)) else { return nil }
        return try? JSONDecoder().decode(LearningHoursSnapshot.self, from: data)
    }

    private func saveCache(_ snapshot: LearningHoursSnapshot, account: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: cacheKey(for: account))
    }
}
