import Foundation
import Combine
import WebKit

@MainActor
final class LibraryEquipmentViewModel: ObservableObject {
    @Published private(set) var groups: [LibraryEquipmentGroup] = []
    @Published private(set) var groupID: Int?
    @Published private(set) var equipmentID: Int?
    @Published private(set) var date = LibraryEquipmentDate.day(Date())
    @Published private(set) var schedule: LibraryEquipmentSchedule?
    @Published private(set) var policy: LibraryEquipmentPolicy?
    @Published private(set) var reservations: [LibraryEquipmentReservation] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var reservationsUpdatedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var needsLogin = false
    @Published private(set) var needsVerification = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var completion: LibraryEquipmentCompletion?
    @Published var reservationQuery = ""
    @Published var reservationPeriod: LibraryReservationPeriod = .all
    @Published var reservationEquipmentID: Int?
    @Published var confirmation: LibraryEquipmentDraft?
    @Published private(set) var selectedStartMinute: Int?
    @Published private(set) var durationMinutes = 60
    @Published private(set) var selectionMessage: String?
    @Published private(set) var webView: WKWebView?

    private let service: any LibraryEquipmentServing
    private let currentAccount: @MainActor () -> String?
    private let currentSession: @MainActor () -> String?
    private let password: @MainActor (String) -> String?
    private var account = ""
    private var session: String?
    private var generation = UUID()
    private var connected = false
    private var task: Task<Void, Never>?

    init(service: (any LibraryEquipmentServing)? = nil,
         currentAccount: @escaping @MainActor () -> String? = { UserDefaults.standard.string(forKey: StorageKeys.username) },
         currentSession: @escaping @MainActor () -> String? = { UserDefaults.standard.string(forKey: StorageKeys.authSessionID) },
         password: @escaping @MainActor (String) -> String? = { account in
             guard let credentials = LoginRepository.shared.getSavedCredentials(),
                   credentials.username.caseInsensitiveCompare(account) == .orderedSame else { return nil }
             return credentials.password
         }) {
        self.service = service ?? LibraryEquipmentService()
        self.currentAccount = currentAccount
        self.currentSession = currentSession
        self.password = password
        self.service.onWebViewCreated = { [weak self] view in
            self?.webView = view
        }
    }

    var selectedGroup: LibraryEquipmentGroup? { groups.first { $0.id == groupID } }
    var reservationEquipment: [LibraryEquipmentItem] {
        var names: [Int: String] = [:]
        for record in reservations { names[record.equipmentID] = record.equipmentName }
        return names.map { LibraryEquipmentItem(id: $0.key, name: $0.value) }
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var filteredReservations: [LibraryEquipmentReservation] {
        LibraryReservationSearch.filter(reservations, query: reservationQuery,
            period: reservationPeriod, equipmentID: reservationEquipmentID)
    }
    var hasReservationFilters: Bool {
        !reservationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || reservationPeriod != .all || reservationEquipmentID != nil
    }
    func resetReservationFilters() {
        reservationQuery = ""; reservationPeriod = .all; reservationEquipmentID = nil
    }
    func dismissCompletion() { completion = nil }
    var selectedEquipment: LibraryEquipmentItem? { schedule?.equipment.first { $0.id == equipmentID } }
    var minutes: [Int] {
        guard let policy else { return [] }
        return Array(stride(from: ((policy.openMinute + 29) / 30) * 30,
                            through: policy.closeMinute, by: 30))
    }
    var selectionError: String? {
        guard selectedStartMinute != nil else { return "請點選開始時間。" }
        guard let draft = draft(), let schedule else { return "請先選擇設備並取得校方規則。" }
        do { try draft.policy.validate(draft, schedule: schedule); return nil }
        catch { return Self.message(error) }
    }
    var minimumDuration: Int { Int(ceil((policy?.minimumHours ?? 1) * 2)) * 30 }
    var maximumDuration: Int? {
        guard let start = selectedStartMinute, let policy, let group = selectedGroup,
              let equipment = selectedEquipment, let schedule else { return nil }
        let limits = [policy.maximumHours * 60, policy.remainingHours * 60,
                      Double(policy.closeMinute - start)]
        let upper = Int(floor(max(0, limits.min() ?? 0) / 30)) * 30
        guard upper >= minimumDuration else { return nil }
        var maximum: Int?
        for duration in stride(from: minimumDuration, through: upper, by: 30) {
            let selection = LibraryEquipmentDraft(group: group, equipment: equipment, date: date,
                startMinute: start, endMinute: start + duration, policy: policy)
            do { try policy.validate(selection, schedule: schedule); maximum = duration }
            catch { break }
        }
        return maximum
    }
    var selectedTimeLabel: String? { draft()?.timeLabel }
    var slots: [LibraryEquipmentSlot] {
        guard let policy, let schedule, let equipmentID else { return [] }
        let now = Date()
        let validSelection = selectionError == nil
        return minutes.filter { $0 < policy.closeMinute }.map { minute in
            let start = LibraryEquipmentDate.at(minute, on: date)
            let occupied = schedule.occupied.filter { $0.equipmentID == equipmentID }
            let overlaps = occupied.contains {
                $0.overlaps(start: start, end: LibraryEquipmentDate.at(minute + 30, on: date))
            }
            let next = occupied.filter { $0.start >= start }.map(\.start).min()
            let nextMinute = next.map { Int($0.timeIntervalSince(LibraryEquipmentDate.day(date)) / 60) }
            let continuous = max(0, min(policy.closeMinute, nextMinute ?? policy.closeMinute) - minute)
            let state: LibraryEquipmentSlot.State
            if start < now { state = .past }
            else if overlaps { state = .occupied }
            else if policy.remainingHours < policy.minimumHours { state = .quotaUnavailable }
            else if continuous < minimumDuration { state = .tooShort }
            else { state = .available }
            return LibraryEquipmentSlot(minute: minute, state: state, continuousMinutes: continuous,
                isSelected: validSelection && selectedStartMinute.map { minute >= $0 && minute < $0 + durationMinutes } == true,
                isStart: validSelection && selectedStartMinute == minute)
        }
    }

    func selectStart(_ minute: Int) {
        guard !isLoading, !isMutating, let policy, let group = selectedGroup,
              let equipment = selectedEquipment, let schedule else { return }
        guard selectedStartMinute != minute else { return }
        let duration = minimumDuration
        let selection = LibraryEquipmentDraft(group: group, equipment: equipment, date: date,
            startMinute: minute, endMinute: minute + duration, policy: policy)
        do {
            try policy.validate(selection, schedule: schedule)
            selectedStartMinute = minute
            durationMinutes = duration
            confirmation = nil
            selectionMessage = nil
        } catch { selectionMessage = Self.message(error) }
    }

    func changeDuration(by delta: Int) {
        setDuration(durationMinutes + delta)
    }

    func setDuration(_ duration: Int) {
        guard !isLoading, !isMutating, let start = selectedStartMinute,
              let policy, let group = selectedGroup, let equipment = selectedEquipment, let schedule else { return }
        guard duration % 30 == 0 else { return }
        let hours = Double(duration) / 60
        guard hours >= policy.minimumHours else { selectionMessage = "最短需預約 \(policy.minimumHours.formatted()) 小時。"; return }
        guard hours <= policy.maximumHours else { selectionMessage = "已達單次預約上限。"; return }
        guard hours <= policy.remainingHours else { selectionMessage = "校方剩餘額度不足。"; return }
        guard start + duration <= policy.closeMinute else { selectionMessage = "延長後會超過設備開放時間。"; return }
        let selection = LibraryEquipmentDraft(group: group, equipment: equipment, date: date,
            startMinute: start, endMinute: start + duration, policy: policy)
        do {
            try policy.validate(selection, schedule: schedule)
            durationMinutes = duration
            selectionMessage = nil
            confirmation = nil
        } catch { selectionMessage = "後方時段已占用，無法延長。請選擇其他開始時間。" }
    }

    func recheckSelection() {
        guard selectedStartMinute != nil, selectionError != nil else { return }
        selectedStartMinute = nil
        confirmation = nil
        selectionMessage = "原選取時段已無法預約，請重新選擇開始時間。"
    }

    func start() {
        stop()
        guard let owner = currentAccount(), !owner.isEmpty, let session = currentSession() else {
            errorMessage = "請先登入 App 後使用設備預約。"
            return
        }
        account = owner
        self.session = session
        run { model, operation in
            try await model.service.connect(account: owner, password: model.password(owner))
            try model.check(operation)
            model.connected = true
            try await model.loadAll(operation)
        }
    }

    func resumeLogin() {
        run { model, operation in
            try await model.service.resumeLogin()
            try model.check(operation)
            model.connected = true
            model.needsLogin = false
            try await model.loadAll(operation)
        }
    }

    func select(groupID: Int) {
        guard !isMutating, self.groupID != groupID else { return }
        self.groupID = groupID
        equipmentID = nil
        clearSelection()
        refresh()
    }

    func select(equipmentID: Int) {
        guard !isMutating, self.equipmentID != equipmentID else { return }
        self.equipmentID = equipmentID
        policy = nil
        confirmation = nil
        selectedStartMinute = nil
        selectionMessage = nil
        refresh()
    }

    func select(date: Date) {
        let day = LibraryEquipmentDate.day(date)
        guard !isMutating, self.date != day else { return }
        self.date = day
        clearSelection()
        refresh()
    }

    func refresh() {
        guard connected else { if !needsLogin { start() }; return }
        run { model, operation in try await model.loadAll(operation) }
    }

    func refreshAndWait() async {
        guard !isMutating, !Task.isCancelled else { return }
        refresh()
        let operation = generation
        await withTaskCancellationHandler {
            await task?.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == operation, self?.isMutating == false else { return }
                self?.cancelRead()
            }
        }
    }

    func prepareConfirmation() {
        guard !isLoading, !isMutating, !needsVerification, let selection = draft() else { return }
        run { model, operation in
            let fresh = try await model.freshDraft(selection, operation: operation)
            try model.check(operation)
            model.confirmation = fresh
        }
    }

    func submit() {
        guard let draft = confirmation, !needsVerification else { return }
        mutate(success: LibraryEquipmentCompletion(kind: .reserved, equipmentName: draft.equipment.name,
            start: draft.start, end: draft.end)) { model, operation in
            let fresh = try await model.freshDraft(draft, operation: operation)
            try model.check(operation)
            try await model.service.reserve(fresh)
        }
    }

    func cancel(_ reservation: LibraryEquipmentReservation) {
        guard reservations.contains(where: { $0.id == reservation.id }), !needsVerification else { return }
        mutate(success: LibraryEquipmentCompletion(kind: .cancelled, equipmentName: reservation.equipmentName,
            start: reservation.start, end: reservation.end)) { model, operation in
            try model.check(operation)
            try await model.service.cancelReservation(reservation)
        }
    }

    func acknowledgeVerification() {
        guard !isLoading, reservationsUpdatedAt != nil else { return }
        needsVerification = false
        notice = nil
    }

    private func mutate(success: LibraryEquipmentCompletion,
                        action: @escaping (LibraryEquipmentViewModel, UUID) async throws -> Void) {
        guard connected, !isLoading, !isMutating, isCurrent(generation) else { return }
        isMutating = true
        errorMessage = nil
        notice = nil
        completion = nil
        let operation = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await action(self, operation)
                try check(operation)
                confirmation = nil
                notice = success.kind == .reserved ? "預約已完成。" : "預約已取消。"
                var result = success
                do { try await loadAll(operation) }
                catch {
                    try check(operation)
                    handle(error)
                    result.refreshFailed = true
                    notice = (notice ?? success.title) + " 資料更新失敗，請重新整理。"
                }
                completion = result
            } catch {
                guard isCurrent(operation) else { return }
                confirmation = nil
                if error as? LibraryEquipmentError == .uncertainMutation {
                    needsVerification = true
                    reservationsUpdatedAt = nil
                    notice = LibraryEquipmentError.uncertainMutation.localizedDescription
                }
                handle(error)
            }
            if isCurrent(operation) { isMutating = false; task = nil }
        }
    }

    private func freshDraft(_ selection: LibraryEquipmentDraft, operation: UUID) async throws -> LibraryEquipmentDraft {
        let schedule = try await service.schedule(groupID: selection.group.id, date: selection.date)
        try check(operation)
        let policy = try await fetchPolicy(groupID: selection.group.id, equipmentID: selection.equipment.id,
                                          date: selection.date, operation: operation)
        let draft = LibraryEquipmentDraft(group: selection.group, equipment: selection.equipment,
            date: selection.date, startMinute: selection.startMinute, endMinute: selection.endMinute, policy: policy)
        self.schedule = schedule
        self.policy = policy
        updatedAt = Date()
        do { try policy.validate(draft, schedule: schedule) }
        catch { recheckSelection(); throw error }
        return draft
    }

    private func loadAll(_ operation: UUID) async throws {
        let groups = try await service.groups()
        try check(operation)
        self.groups = groups
        if !groups.contains(where: { $0.id == groupID }) {
            let hadSelection = selectedStartMinute != nil
            groupID = groups.first?.id
            equipmentID = nil
            clearSelection()
            if hadSelection { selectionMessage = "原設備群組已無法選擇，請重新選取時段。" }
        }
        // Personal records refresh first so a closed date never prevents reconciliation.
        let records = try await service.reservations()
        try check(operation)
        reservations = records
        if let selected = reservationEquipmentID, !records.contains(where: { $0.equipmentID == selected }) {
            reservationEquipmentID = nil
        }
        reservationsUpdatedAt = Date()
        guard let groupID else { clearSelection(); return }
        let schedule = try await service.schedule(groupID: groupID, date: date)
        try check(operation)
        self.schedule = schedule
        if !schedule.equipment.contains(where: { $0.id == equipmentID }) {
            let hadSelection = selectedStartMinute != nil
            equipmentID = schedule.equipment.first?.id
            selectedStartMinute = nil
            confirmation = nil
            policy = nil
            if hadSelection { selectionMessage = "原設備已無法選擇，請重新選取時段。" }
        }
        guard let equipmentID else { policy = nil; return }
        let policy = try await fetchPolicy(groupID: groupID, equipmentID: equipmentID,
                                          date: date, operation: operation)
        self.policy = policy
        updatedAt = Date()
        recheckSelection()
    }

    private func fetchPolicy(groupID: Int, equipmentID: Int, date: Date,
                             operation: UUID) async throws -> LibraryEquipmentPolicy {
        do {
            let result = try await service.policy(groupID: groupID, equipmentID: equipmentID, date: date)
            try check(operation)
            return result
        } catch {
            try check(operation)
            if let known = error as? LibraryEquipmentError, case .rejected = known {
                selectedStartMinute = nil
                confirmation = nil
                policy = nil
                updatedAt = nil
                selectionMessage = "此設備或日期目前無法預約，請重新選擇。"
            }
            throw error
        }
    }

    private func run(_ action: @escaping (LibraryEquipmentViewModel, UUID) async throws -> Void) {
        guard !isMutating else { return }
        cancelRead()
        let operation = generation
        isLoading = true
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try check(operation)
                try await action(self, operation)
            }
            catch { if isCurrent(operation), !(error is CancellationError) { handle(error) } }
            if isCurrent(operation) { isLoading = false; task = nil }
        }
    }

    private func handle(_ error: Error) {
        errorMessage = Self.message(error)
        if error as? LibraryEquipmentError == .loginRequired {
            needsLogin = service.webView != nil
            webView = service.webView
            connected = false
        }
    }

    private func draft() -> LibraryEquipmentDraft? {
        guard let group = selectedGroup, let equipment = selectedEquipment, let policy,
              let startMinute = selectedStartMinute else { return nil }
        return LibraryEquipmentDraft(group: group, equipment: equipment, date: date,
                                     startMinute: startMinute, endMinute: startMinute + durationMinutes, policy: policy)
    }
    private func clearSelection() {
        schedule = nil; policy = nil; updatedAt = nil; confirmation = nil
        selectedStartMinute = nil; selectionMessage = nil
    }
    private func cancelRead() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }
    func stop() {
        cancelRead()
        service.close()
        webView = nil
        account = ""
        session = nil
        connected = false
        needsLogin = false
        needsVerification = false
        isMutating = false
        groups = []
        groupID = nil
        equipmentID = nil
        reservations = []
        reservationsUpdatedAt = nil
        notice = nil
        completion = nil
        resetReservationFilters()
        errorMessage = nil
        clearSelection()
    }
    private func isCurrent(_ operation: UUID) -> Bool {
        !Task.isCancelled && operation == generation && session != nil && session == currentSession()
            && currentAccount()?.lowercased() == account.lowercased()
    }
    private func check(_ operation: UUID) throws {
        guard isCurrent(operation) else { throw CancellationError() }
    }
    private static func message(_ error: Error) -> String {
        if let error = error as? LibraryEquipmentError { return error.localizedDescription }
        return "無法取得圖書館資料，請檢查網路後重新整理。"
    }
}
