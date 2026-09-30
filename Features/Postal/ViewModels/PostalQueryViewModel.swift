import Foundation
import Combine

@MainActor
final class PostalQueryViewModel: ObservableObject {
    @Published var query = PostalQuery() {
        didSet {
            if oldValue != query { criteriaChanged() }
        }
    }
    @Published private(set) var records: [PostalRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var resultQuery: PostalQuery?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var page: PostalPage?

    private let makeService: () -> any PostalServing
    private var service: (any PostalServing)?
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(makeService: @escaping () -> any PostalServing = { PostalService() }) {
        self.makeService = makeService
    }

    deinit {
        work?.cancel()
        service?.invalidate()
    }

    var filtersChanged: Bool { resultQuery.map { $0 != query.normalized } ?? false }

    func search() {
        cancelWork()
        guard query.canSearch else {
            errorMessage = "請填寫收件人、手機號碼或郵件號碼其中一項。"
            return
        }
        service?.invalidate()
        let client = makeService()
        service = client
        let submitted = query.normalized
        records = []
        page = nil
        resultQuery = nil
        updatedAt = nil
        isLoading = true
        errorMessage = nil
        let current = generation
        work = Task { [weak self] in
            do {
                let result = try await client.search(submitted)
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.records = result.records
                self.page = result
                self.resultQuery = submitted
                self.updatedAt = Date()
                self.isLoading = false
                self.work = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.errorMessage = Self.message(for: error)
                self.isLoading = false
                self.work = nil
            }
        }
    }

    func loadMore() {
        guard !isLoading, !filtersChanged, let page, page.nextForm != nil, let service else { return }
        isLoading = true
        errorMessage = nil
        let current = generation
        work = Task { [weak self] in
            do {
                let result = try await service.nextPage(after: page)
                guard !Task.isCancelled, let self, self.generation == current else { return }
                let known = Set(self.records.map(\.id))
                self.records += result.records.filter { !known.contains($0.id) }
                self.page = result
                self.isLoading = false
                self.work = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.errorMessage = Self.message(for: error)
                self.isLoading = false
                self.work = nil
            }
        }
    }

    private func criteriaChanged() {
        if isLoading {
            cancelWork()
            errorMessage = nil
        }
    }

    func reset() {
        cancelWork()
        service?.invalidate()
        service = nil
        query = PostalQuery()
        records = []
        page = nil
        resultQuery = nil
        updatedAt = nil
        errorMessage = nil
    }

    func cancelWork() {
        generation = UUID()
        work?.cancel()
        work = nil
        isLoading = false
    }

    static func message(for error: Error) -> String {
        switch error {
        case PostalError.invalidResponse: return "校方回傳的資料格式無法辨識，請稍後再試。"
        case PostalError.sessionExpired: return "校方查詢連線已失效，請重新查詢以取得新的連線。"
        case PostalError.unavailable: return "校方郵務系統暫時無法使用，請稍後再試。"
        default:
            switch (error as? URLError)?.code {
            case .notConnectedToInternet, .networkConnectionLost: return "目前無法連上網路，請確認連線後再試。"
            case .timedOut: return "校方回應逾時，請稍後再試。"
            default: return "無法取得郵件資料，請稍後重新查詢。"
            }
        }
    }
}
