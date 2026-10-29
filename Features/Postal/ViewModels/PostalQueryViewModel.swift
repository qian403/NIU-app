import Foundation
import Combine

/// One search fetches every status at once, each on its own school session so paging stays
/// independent; switching status afterwards only changes what is shown. If the school rate-limits,
/// searches fall back to fetching only the shown status, and other statuses load when selected.
@MainActor
final class PostalQueryViewModel: ObservableObject {
    @Published var query = PostalQuery() {
        didSet {
            if Self.criteria(oldValue) != Self.criteria(query) { criteriaChanged() }
        }
    }
    @Published private(set) var updatedAt: Date?
    @Published private(set) var ownName: String?
    /// The criteria of the latest search, status left at its default; nil before any search.
    @Published private(set) var submitted: PostalQuery?

    private struct StatusResult {
        var page: PostalPage
        var records: [PostalRecord]
    }

    @Published private var results: [PostalStatus: StatusResult] = [:]
    @Published private var failures: [PostalStatus: String] = [:]
    @Published private var loading: Set<PostalStatus> = []
    @Published private var validationMessage: String?

    /// Shared by every postal screen: after a 429/503, stop sending parallel requests for a while.
    private static var throttledUntil: Date?
    static let throttleCooldown: TimeInterval = 10 * 60
    static var isThrottled: Bool { (throttledUntil ?? .distantPast) > Date() }
    static func clearThrottle() { throttledUntil = nil }

    private var account: String?
    private let makeService: @Sendable () async -> any PostalServing
    /// Floor for the wait before retrying a rate-limited status; tests pass 0.
    private let minimumRetryDelay: TimeInterval
    private var works: [PostalStatus: Task<Void, Never>] = [:]
    /// The session behind each status's results; its next page must use the same session.
    private var services: [PostalStatus: any PostalServing] = [:]
    private var generation = UUID()

    init(makeService: @escaping @Sendable () async -> any PostalServing = { await PostalService.make() },
         minimumRetryDelay: TimeInterval = 2) {
        self.makeService = makeService
        self.minimumRetryDelay = minimumRetryDelay
    }

    deinit {
        for work in works.values { work.cancel() }
        for service in services.values { service.invalidate() }
    }

    // MARK: - Shown status

    var records: [PostalRecord] { results[query.status]?.records ?? [] }
    var page: PostalPage? { results[query.status]?.page }
    /// The shown status is still loading, from a search or a further page.
    var isLoading: Bool { loading.contains(query.status) }
    /// Any status of the current search is still loading.
    var isSearching: Bool { !loading.isEmpty }
    var errorMessage: String? { validationMessage ?? failures[query.status] }

    /// The query the shown results answer; nil until this status has a result.
    var resultQuery: PostalQuery? {
        guard results[query.status] != nil, var value = submitted else { return nil }
        value.status = query.status
        return value
    }

    var filtersChanged: Bool { submitted.map { $0 != Self.criteria(query.normalized) } ?? false }

    /// Badge for a status button: record count, "+" when the school has more pages.
    func countText(for status: PostalStatus) -> String? {
        guard let result = results[status] else { return nil }
        let more = result.page.pageIndex + 1 < result.page.pageCount
        return "\(result.records.count)\(more ? "+" : "")"
    }

    func isLoading(_ status: PostalStatus) -> Bool { loading.contains(status) }

    // MARK: - Own mail

    func prepare(account: String?, name: String?) {
        let account = account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !account.isEmpty else { reset(); return }
        if self.account != account {
            reset()
            self.account = account
        }
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previousName = ownName
        ownName = !name.isEmpty && name.lowercased() != account ? name : nil
        if previousName != nil, ownName == nil {
            reset()
            self.account = account
            return
        }
        // A late profile update may fill an untouched form, but must not replace manual filters.
        guard ownName != previousName else { return }
        if let previousName, query.normalized == PostalQuery(name: previousName, status: query.status) {
            searchOwnMail(status: query.status)
        } else if query == PostalQuery(), submitted == nil, !isSearching {
            searchOwnMail()
        }
    }

    func searchOwnMail(status: PostalStatus = .waiting) {
        guard let ownName else { return }
        query = PostalQuery(name: ownName, status: status)
        search()
    }

    /// Shows another status from the results already fetched; searches only if nothing was fetched yet.
    func selectOwnStatus(_ status: PostalStatus) {
        guard ownName != nil, query.status != status else { return }
        if submitted == nil, !isSearching {
            searchOwnMail(status: status)
        } else {
            selectStatus(status)
        }
    }

    /// Switches the shown status. A status skipped because of rate limiting is fetched now.
    func selectStatus(_ status: PostalStatus) {
        query.status = status
        guard let base = submitted, !filtersChanged, results[status] == nil, failures[status] == nil,
              !loading.contains(status) else { return }
        fetch(status, base: base)
    }

    // MARK: - Loading

    func search() {
        cancelWork()
        guard query.canSearch else {
            validationMessage = "請填寫收件人、手機號碼或郵件號碼其中一項。"
            return
        }
        discardResults()
        validationMessage = nil
        let base = Self.criteria(query.normalized)
        submitted = base
        updatedAt = nil
        for status in Self.isThrottled ? [query.status] : PostalStatus.allCases {
            fetch(status, base: base)
        }
    }

    private func fetch(_ status: PostalStatus, base: PostalQuery) {
        var request = base
        request.status = status
        loading.insert(status)
        failures[status] = nil
        let makeService = makeService
        let current = generation
        let minimumDelay = minimumRetryDelay
        works[status] = Task { [weak self] in
            var attempt = 0
            while true {
                attempt += 1
                // Session setup must not compete with keyboard dismissal on the main actor.
                let client = await makeService()
                guard !Task.isCancelled, self?.generation == current else {
                    client.invalidate()
                    return
                }
                do {
                    let result = try await client.search(request)
                    guard !Task.isCancelled, let self, self.generation == current else {
                        client.invalidate()
                        return
                    }
                    self.services[status] = client
                    self.results[status] = StatusResult(page: result, records: result.records)
                    self.updatedAt = Date()
                    self.finish(status)
                    return
                } catch {
                    client.invalidate()
                    guard !Task.isCancelled, let self, self.generation == current else { return }
                    guard case .rateLimited(let retryAfter)? = error as? PostalError else {
                        self.failures[status] = Self.message(for: error)
                        self.finish(status)
                        return
                    }
                    Self.throttledUntil = Date().addingTimeInterval(Self.throttleCooldown)
                    // Only the status on screen is retried, once; others wait until the user selects them.
                    guard self.query.status == status else {
                        self.finish(status)
                        return
                    }
                    guard attempt < 2 else {
                        self.failures[status] = Self.message(for: error)
                        self.finish(status)
                        return
                    }
                    let delay = min(max(retryAfter ?? 3, minimumDelay), 15)
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
            }
        }
    }

    func loadMore() {
        let status = query.status
        guard !loading.contains(status), !filtersChanged, let result = results[status],
              result.page.nextForm != nil, let service = services[status] else { return }
        loading.insert(status)
        failures[status] = nil
        let current = generation, page = result.page
        works[status] = Task { [weak self] in
            do {
                let next = try await service.nextPage(after: page)
                guard !Task.isCancelled, let self, self.generation == current, var entry = self.results[status] else { return }
                let known = Set(entry.records.map(\.id))
                entry.records += next.records.filter { !known.contains($0.id) }
                entry.page = next
                self.results[status] = entry
                self.finish(status)
            } catch {
                guard !Task.isCancelled, let self, self.generation == current else { return }
                if case .rateLimited? = error as? PostalError {
                    Self.throttledUntil = Date().addingTimeInterval(Self.throttleCooldown)
                }
                self.failures[status] = Self.message(for: error)
                self.finish(status)
            }
        }
    }

    private func finish(_ status: PostalStatus) {
        loading.remove(status)
        works[status] = nil
    }

    private func criteriaChanged() {
        if isSearching {
            cancelWork()
            failures = [:]
        }
        validationMessage = nil
    }

    private func discardResults() {
        for service in services.values { service.invalidate() }
        services = [:]
        results = [:]
        failures = [:]
    }

    func reset() {
        cancelWork()
        account = nil
        ownName = nil
        discardResults()
        query = PostalQuery()
        submitted = nil
        updatedAt = nil
        validationMessage = nil
    }

    func cancelWork() {
        generation = UUID()
        for work in works.values { work.cancel() }
        works = [:]
        loading = []
    }

    private static func criteria(_ query: PostalQuery) -> PostalQuery {
        var value = query
        value.status = .waiting
        return value
    }

    static func message(for error: Error) -> String {
        switch error {
        case PostalError.invalidResponse: return "校方回傳的資料格式無法辨識，請稍後再試。"
        case PostalError.sessionExpired: return "校方查詢連線已失效，請重新查詢以取得新的連線。"
        case PostalError.unavailable: return "校方郵務系統暫時無法使用，請稍後再試。"
        case PostalError.rateLimited: return "校方系統忙碌或暫時限制查詢次數，請稍後再試。"
        default:
            switch (error as? URLError)?.code {
            case .notConnectedToInternet, .networkConnectionLost: return "目前無法連上網路，請確認連線後再試。"
            case .timedOut: return "校方回應逾時，請稍後再試。"
            default: return "無法取得郵件資料，請稍後重新查詢。"
            }
        }
    }
}
