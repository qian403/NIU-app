import Foundation
import Combine

/// 我的假單: 請假紀錄 with what 學生請假修改 allows (撤回／修改／補檔) for each form.
@MainActor
final class LeaveRecordsViewModel: ObservableObject {
    enum WithdrawOutcome: Identifiable, Equatable {
        case withdrawn(formNo: String, summary: String)
        case uncertain(String)
        var id: String {
            switch self {
            case .withdrawn(let formNo, _): return "withdrawn-\(formNo)"
            case .uncertain(let text): return "uncertain-\(text)"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let record: LeaveRecord
        let actions: LeaveRecordActions
        var id: String { record.formNo }
    }

    @Published private(set) var service: LeaveApplicationService?
    @Published private(set) var items: [Item] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage = "正在讀取請假紀錄…"
    @Published private(set) var loadStage = LeaveLoadStage.connecting
    @Published private(set) var loadError: String?
    /// Result of 撤回 or a school alert; shown once.
    @Published var message: String?
    /// Result of 撤回, shown as an explicit alert on the detail sheet.
    @Published var withdrawOutcome: WithdrawOutcome?
    @Published private(set) var isWithdrawing = false
    @Published private(set) var details: [String: LeavePage] = [:]
    @Published private(set) var detailErrors: [String: String] = [:]
    @Published private(set) var updatedAt: Date?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var owner = ""
    private var session: String?

    var actionable: [Item] { items.filter { $0.actions.any } }
    var others: [Item] { items.filter { !$0.actions.any } }
    func item(_ formNo: String) -> Item? { items.first { $0.record.formNo == formNo } }

    func load() {
        perform("正在讀取請假紀錄…") { service in
            let result = try await service.loadRecords(account: self.owner)
            let actions = Dictionary(result.actions.map { ($0.formNo, $0) }, uniquingKeysWith: { first, _ in first })
            return result.records.map { Item(record: $0, actions: actions[$0.formNo] ?? .none) }
                .sorted { $0.record.formNo > $1.record.formNo }
        } apply: { items in
            self.items = items
            self.hasLoaded = true
            self.updatedAt = Date()
            self.details = [:]; self.detailErrors = [:]
        }
    }

    func reloadAndWait() async {
        load()
        await task?.value
    }

    func loadDetail(_ formNo: String) {
        guard details[formNo] == nil else { return }
        detailErrors[formNo] = nil
        perform("正在讀取假單內容…", reportsLoadError: false) { service in
            try await service.loadDetail(account: self.owner, formNo: formNo)
        } apply: { page in
            self.details[formNo] = page
        } failed: { text in
            self.detailErrors[formNo] = text
        }
    }

    /// The user already confirmed in the app; success is reported only after a fresh query.
    func withdraw(_ formNo: String) {
        guard !isBusy, let item = item(formNo), item.actions.withdraw else { return }
        let summary = "\(item.record.type.isEmpty ? "假單" : item.record.type)，\(LeaveRecordFormat.range(item.record))"
        isWithdrawing = true
        withdrawOutcome = nil
        perform("正在撤回假單…", reportsLoadError: false, retriesLogin: false) { service in
            try await service.withdraw(account: self.owner, formNo: formNo)
        } apply: { removed in
            self.isWithdrawing = false
            if removed {
                self.items.removeAll { $0.record.formNo == formNo }
                self.details[formNo] = nil
                self.withdrawOutcome = .withdrawn(formNo: formNo, summary: summary)
            } else {
                self.withdrawOutcome = .uncertain("已送出撤回，但校方列表仍顯示這張假單。請重新整理，或到校務系統查看，不要重複撤回。")
            }
        } failed: { text in
            self.isWithdrawing = false
            self.withdrawOutcome = .uncertain("無法確認是否已撤回：\(text) 請重新整理，或到校務系統查看，不要重複撤回。")
        }
    }

    func dismissMessage() { message = nil }

    private func perform<T>(_ progress: String, reportsLoadError: Bool = true, retriesLogin: Bool = true,
                            operation: @escaping @MainActor (LeaveApplicationService) async throws -> T,
                            apply: @escaping @MainActor (T) -> Void,
                            failed: (@MainActor (String) -> Void)? = nil) {
        guard !isBusy else { return }
        let account = UserDefaults.standard.string(forKey: "app.user.username") ?? ""
        let currentSession = UserDefaults.standard.string(forKey: StorageKeys.authSessionID)
        guard !account.isEmpty, currentSession != nil else { loadError = "請先登入 App 後再查詢假單。"; return }
        if account.lowercased() != owner.lowercased() || currentSession != session {
            // Another account or login: drop the old school page and everything read from it.
            close()
            owner = account; session = currentSession
        }
        let id = generation
        isBusy = true; busyMessage = progress
        if reportsLoadError { loadError = nil }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let service = self.service ?? self.makeService()
                let value: T
                do { value = try await operation(service) }
                catch let error where retriesLogin && Self.isExpired(error) && !service.refreshedLogin {
                    // One SSO refresh and a new page; never loop on a stale GUID.
                    guard self.current(id), await SSOSessionService.shared.requestRefresh(force: true), self.current(id) else {
                        throw LeaveApplicationError.expired
                    }
                    service.close()
                    value = try await operation(self.makeService())
                }
                guard self.current(id) else { return }
                apply(value)
            } catch {
                guard self.current(id), !(error is CancellationError) else { return }
                let text = LeaveApplicationError.message(for: error)
                if let failed { failed(text) } else { self.loadError = text }
            }
            guard self.current(id) else { return }
            self.isBusy = false; self.task = nil
        }
    }

    private static func isExpired(_ error: Error) -> Bool {
        (error as? LeaveApplicationError) == .expired || (error as? URLError)?.code == .userAuthenticationRequired
    }

    private func makeService() -> LeaveApplicationService {
        service?.close()
        let service = LeaveApplicationService()
        service.onDialog = { [weak self] in self?.message = $0 }
        service.onProgress = { [weak self, weak service] stage in
            guard let self, let service, self.service === service else { return }
            self.loadStage = stage
        }
        self.service = service
        return service
    }

    private func current(_ id: UUID) -> Bool {
        id == generation && session != nil && session == UserDefaults.standard.string(forKey: StorageKeys.authSessionID)
            && owner.lowercased() == UserDefaults.standard.string(forKey: "app.user.username")?.lowercased()
    }

    func close() {
        generation = UUID(); task?.cancel(); task = nil
        service?.close(); service = nil
        items = []; details = [:]; detailErrors = [:]; hasLoaded = false; updatedAt = nil
        isBusy = false; loadError = nil; message = nil; withdrawOutcome = nil; isWithdrawing = false; loadStage = .connecting
        session = nil; owner = ""
    }
}
