import Foundation
import Combine
import WebKit
import UniformTypeIdentifiers

@MainActor
final class LeaveApplicationViewModel: ObservableObject {
    /// The steps the school's form actually requires, in order.
    enum Step: Int, CaseIterable {
        case notice, details, periods, review
        var title: String {
            switch self {
            case .notice: return "注意事項"
            case .details: return "假別日期"
            case .periods: return "選擇節次"
            case .review: return "確認送出"
            }
        }
    }

    let entry: LeaveEntry
    @Published private(set) var service: LeaveApplicationService?
    @Published private(set) var page: LeavePage?
    @Published private(set) var periods: [LeavePeriod] = []
    @Published private(set) var isBusy = false
    /// Information from the school (alerts) or the result of an action.
    @Published private(set) var message: String?
    /// A load failure that prevents showing the form; offers retry.
    @Published private(set) var loadError: String?
    @Published private(set) var didAttemptSubmit = false
    @Published private(set) var canReview = false
    @Published private(set) var loadingMessage = "正在讀取請假表單…"
    @Published private(set) var loadStage = LeaveLoadStage.connecting
    @Published var leaveType = "" { didSet { if leaveType != oldValue { invalidateReview() } } }
    @Published var startDate = Date() {
        didSet {
            guard startDate != oldValue else { return }
            if endDate < startDate { endDate = startDate }
            datesChanged()
        }
    }
    @Published var endDate = Date() { didSet { if endDate != oldValue { datesChanged() } } }
    @Published var reason = "" { didSet { if reason != oldValue { invalidateReview() } } }
    @Published var supplementLater = false { didSet { if supplementLater != oldValue { invalidateReview() } } }
    @Published private(set) var selected = Set<String>()
    @Published var acknowledged = false
    @Published private(set) var schoolConfirmation: String?
    /// Periods already saved on the form being modified or supplemented.
    @Published private(set) var existingPeriods: [LeaveExistingPeriod] = []
    private var confirmReply: ((Bool) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var owner = ""
    private var session: String?
    private var periodDates: String?
    private var uploadUncertain = false

    init(entry: LeaveEntry = .apply) {
        self.entry = entry
    }

    /// 修改 starts from the saved form, so the notice step does not apply.
    var steps: [Step] { entry == .apply ? Step.allCases : [.details, .periods, .review] }
    var isSupplement: Bool { if case .supplement = entry { return true } else { return false } }
    var attachmentNames: [String] { page?.attachmentNames ?? [] }

    /// 補檔 needs at least one attachment on the school form before「送出」.
    var canSubmitSupplement: Bool {
        isSupplement && page?.mode == "DETAIL" && !attachmentNames.isEmpty && !uploadUncertain && !didAttemptSubmit && !isBusy
    }

    var dateKey: String { LeaveApplicationDate.string(startDate) + "|" + LeaveApplicationDate.string(endDate) }
    var selectedPeriods: [LeavePeriod] { periods.filter { selected.contains($0.id) } }
    var leaveTypeTitle: String? { page?.options?.first { $0.id == leaveType }?.title }
    var dayCount: Int { LeaveApplicationDate.dayCount(from: startDate, to: endDate) }
    var hasLoadedPeriods: Bool { periodDates == dateKey }
    var trimmedReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }
    var periodDays: [String] { Array(Set(periods.map(\.date))).sorted() }

    /// What the user still needs to do before reviewing; nil when the draft is complete.
    var missingRequirement: String? {
        if leaveType.isEmpty { return "請選擇假別" }
        if trimmedReason.isEmpty { return "請填寫請假事由" }
        if !hasLoadedPeriods { return "請查詢請假節次" }
        if selected.isEmpty { return "請至少選擇一節課" }
        if uploadUncertain { return "請先到校務系統確認附件" }
        return nil
    }

    var hasValidDraft: Bool {
        page?.kind == "form" && missingRequirement == nil && startDate <= endDate && !didAttemptSubmit && !isBusy
    }

    var currentStep: Step {
        if page?.kind == "notice", entry == .apply { return .notice }
        if didAttemptSubmit || canReview { return .review }
        if !leaveType.isEmpty && !trimmedReason.isEmpty { return .periods }
        return .details
    }

    func load() {
        guard !didAttemptSubmit else { return }
        close()
        owner = UserDefaults.standard.string(forKey: "app.user.username") ?? ""
        session = UserDefaults.standard.string(forKey: StorageKeys.authSessionID)
        guard !owner.isEmpty, session != nil else { loadError = "請先登入 App 後再使用請假功能。"; return }
        let service = makeService()
        let id = generation
        let entry = self.entry
        perform("正在連接教務系統…", failsLoad: true) { [self] operationID in
            do { try self.apply(try await service.load(account: self.owner, entry: entry), operation: operationID) }
            catch {
                let expired = (error as? LeaveApplicationError) == .expired
                    || (error as? URLError)?.code == .userAuthenticationRequired
                guard expired else { throw error }
                // One SSO refresh, then rebuild the WebView; never loop on a stale GUID.
                self.loadStage = .signingIn
                guard self.current(id), await SSOSessionService.shared.requestRefresh(force: true), self.current(id) else {
                    throw LeaveApplicationError.expired
                }
                service.close()
                let retry = self.makeService()
                try self.apply(try await retry.load(account: self.owner, entry: entry), operation: operationID)
            }
            try self.validateOwner()
            self.prefillSavedValues()
        }
    }

    /// 修改: start from what the school saved. Periods are re-queried so CLASS_INFO is
    /// rebuilt explicitly; the saved ones are preselected once the list arrives.
    private func prefillSavedValues() {
        guard entry != .apply, let saved = page?.current else { return }
        existingPeriods = page?.existingPeriods ?? []
        guard case .modify = entry else { return }
        if let start = LeaveApplicationDate.date(fromROC: saved.startDate) { startDate = start }
        if let end = LeaveApplicationDate.date(fromROC: saved.endDate) { endDate = max(end, startDate) }
        leaveType = saved.leaveType
        reason = saved.reason
        supplementLater = saved.supplementLater
        invalidateReview()
    }

    func acceptNotice() {
        guard let service, page?.kind == "notice", !isBusy else { return }
        perform("正在開啟申請表單…") { operationID in
            _ = try await service.run(LeaveApplicationScript.acceptNotice)
            try self.apply(try await service.waitForPage(kind: "form"), operation: operationID)
            try self.validateOwner()
        }
    }

    func togglePeriod(_ id: String) {
        guard !isBusy, !didAttemptSubmit else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        invalidateReview()
    }

    /// Selects every period of a day, or clears them when all are already selected.
    func toggleDay(_ date: String) {
        guard !isBusy, !didAttemptSubmit else { return }
        let ids = Set(periods.filter { $0.date == date }.map(\.id))
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
        invalidateReview()
    }

    func loadPeriods() {
        guard let service, !isBusy, !didAttemptSubmit, startDate <= endDate else { return }
        selected = []; invalidateReview(); periodDates = nil
        let key = dateKey
        let arguments: [String: Any] = ["startDate": LeaveApplicationDate.string(startDate), "endDate": LeaveApplicationDate.string(endDate)]
        perform("正在查詢這段期間的課程…") { operationID in
            _ = try await service.run(LeaveApplicationScript.openPeriods, arguments: arguments)
            let result = try await service.waitForPage(kind: "periods", script: LeaveApplicationScript.periods)
            try self.requireCurrent(operationID)
            guard self.dateKey == key else { throw CancellationError() }
            self.periods = result.periods ?? []; self.periodDates = key
            if case .modify = self.entry, self.selected.isEmpty {
                self.selected = Set(self.periods.filter { period in
                    self.existingPeriods.contains { $0.matches(period.id) }
                }.map(\.id))
            }
            if self.periods.isEmpty {
                _ = try await service.run(LeaveApplicationScript.closePeriods)
            }
        }
    }

    func prepareReview() {
        guard hasValidDraft, let service else { return }
        let ids = selected.sorted()
        invalidateReview()
        perform("正在把節次填入校方表單…") { operationID in
            let before = try await service.snapshot()
            if Set((before.selected ?? "").split(separator: ",").map(String.init)) != Set(ids) {
                _ = try await service.run(LeaveApplicationScript.openPeriods, arguments: [
                    "startDate": LeaveApplicationDate.string(self.startDate),
                    "endDate": LeaveApplicationDate.string(self.endDate)
                ])
                _ = try await service.waitForPage(kind: "periods", script: LeaveApplicationScript.periods)
                _ = try await service.run(LeaveApplicationScript.bindPeriods, arguments: ["selected": ids])
            }
            let page = try await service.waitForPage(kind: "form", matches: {
                Set(($0.selected ?? "").split(separator: ",").map(String.init)) == Set(ids)
            })
            try self.apply(page, operation: operationID)
            try self.validateOwner()
            self.canReview = true
        }
    }

    func upload(_ url: URL) {
        guard let service, !isBusy, !didAttemptSubmit, !uploadUncertain else { return }
        let ext = url.pathExtension.lowercased()
        guard ["pdf", "jpg", "jpeg", "png"].contains(ext) else {
            message = LeaveApplicationError.invalidFile.localizedDescription; return
        }
        let old = page?.attachmentNames ?? []
        invalidateReview()
        perform("正在附加證明文件…") { operationID in
            // Read the picked file off the main thread; it may be up to 10 MB.
            let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 10 * 1024 * 1024 else { throw LeaveApplicationError.invalidFile }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 10 * 1024 * 1024 else { throw LeaveApplicationError.invalidFile }
                return data
            }.value
            try self.requireCurrent(operationID)
            // Do not retry an upload whose response may have been lost.
            self.uploadUncertain = true
            _ = try await service.run(LeaveApplicationScript.upload, arguments: [
                "base64": data.base64EncodedString(), "filename": url.lastPathComponent,
                "mime": UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            ])
            let page = try await service.waitForPage(kind: "form", matches: { ($0.attachmentNames ?? []).count > old.count })
            try self.apply(page, operation: operationID)
            self.uploadUncertain = false
        }
    }

    func submit() {
        guard hasValidDraft, canReview, acknowledged, let service else { return }
        // Lock before dispatch: a timeout or navigation failure must never replay a submission.
        didAttemptSubmit = true; canReview = false
        // 修改 saves through the same form, whose button the school labels「修改」.
        let isModify: Bool = { if case .modify = entry { return true } else { return false } }()
        let arguments: [String: Any] = ["acknowledged": acknowledged, "reason": reason,
            "selected": selected.sorted(), "leaveType": leaveType, "supplementLater": supplementLater,
            "startDate": LeaveApplicationDate.string(startDate), "endDate": LeaveApplicationDate.string(endDate),
            "expectedButton": isModify ? "修改" : "送出", "expectedFormNo": entry.formNo ?? ""]
        perform("正在送出請假申請…") { operationID in
            _ = try await service.run(LeaveApplicationScript.submit, arguments: arguments)
            try await self.waitForSchoolReply(operationID)
        }
    }

    /// 補檔: attachments are already on the school form; this presses its「送出」once.
    func submitSupplement() {
        guard canSubmitSupplement, acknowledged, let service, let formNo = entry.formNo else { return }
        didAttemptSubmit = true
        perform("正在送出補交的證明文件…") { operationID in
            _ = try await service.run(LeaveApplicationScript.submitSupplement,
                                      arguments: ["acknowledged": true, "expectedFormNo": formNo])
            try await self.waitForSchoolReply(operationID)
        }
    }

    private func waitForSchoolReply(_ operationID: UUID) async throws {
        // Give the school's own alert a moment; its text is the only result we can show.
        for _ in 0..<16 where message == nil && schoolConfirmation == nil {
            try await Task.sleep(for: .milliseconds(500))
            try requireCurrent(operationID)
        }
        if message == nil {
            message = "已按下校方的送出按鈕，但未收到校方回應。請到「我的假單」或校務系統確認。"
        }
    }

    private func makeService() -> LeaveApplicationService {
        let service = LeaveApplicationService()
        service.onDialog = { [weak self] in self?.message = $0 }
        service.onProgress = { [weak self, weak service] stage in
            guard let self, let service, self.service === service else { return }
            self.loadStage = stage
        }
        service.onConfirm = { [weak self] message, reply in
            guard let self else { reply(false); return }
            self.confirmReply = reply
            self.schoolConfirmation = message
        }
        self.service = service
        return service
    }

    func answerSchoolConfirmation(_ accepted: Bool) {
        let reply = confirmReply
        let wasAsking = schoolConfirmation != nil
        confirmReply = nil; schoolConfirmation = nil
        if wasAsking, !accepted { message = "已取消校方確認。請前往校務系統查看申請狀態。" }
        reply?(accepted)
    }

    private func datesChanged() {
        invalidateReview()
        selected = []; periods = []; periodDates = nil
    }

    private func invalidateReview() { acknowledged = false; canReview = false }

    private func requireCurrent(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard current(operation) else { throw CancellationError() }
    }
    private func apply(_ page: LeavePage, operation: UUID) throws {
        try requireCurrent(operation)
        self.page = page
    }

    private func validateOwner() throws {
        guard page?.kind != "form" || page?.studentID?.lowercased() == owner.lowercased() else {
            page = nil; throw LeaveApplicationError.changed
        }
    }
    private func current(_ id: UUID) -> Bool {
        id == generation && session != nil && session == UserDefaults.standard.string(forKey: StorageKeys.authSessionID)
            && owner.lowercased() == UserDefaults.standard.string(forKey: "app.user.username")?.lowercased()
    }
    private func perform(_ progress: String, failsLoad: Bool = false,
                         operation: @escaping @MainActor (UUID) async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; message = nil; loadError = nil; loadingMessage = progress
        let id = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard self.current(id), !Task.isCancelled else { throw CancellationError() }
                try await operation(id)
            } catch {
                if self.current(id), !(error is CancellationError) {
                    let text = self.didAttemptSubmit
                        ? "送出結果尚未確認。請先到校務系統查看紀錄與附件，再決定是否重新申請。"
                        : self.uploadUncertain ? "附件上傳結果尚未確認，請前往校務系統檢查，避免重複附加。"
                        : LeaveApplicationError.message(for: error)
                    if failsLoad || self.page == nil { self.loadError = text } else { self.message = text }
                }
            }
            guard self.current(id) else { return }
            self.isBusy = false; self.task = nil
        }
    }

    func close() {
        generation = UUID(); task?.cancel(); task = nil
        answerSchoolConfirmation(false); service?.close(); service = nil
        page = nil; periods = []; selected = []; acknowledged = false; canReview = false
        isBusy = false; message = nil; loadError = nil; periodDates = nil; uploadUncertain = false; session = nil
        loadingMessage = "正在讀取請假表單…"; loadStage = .connecting
        leaveType = ""; reason = ""; supplementLater = false; existingPeriods = []
    }
}
