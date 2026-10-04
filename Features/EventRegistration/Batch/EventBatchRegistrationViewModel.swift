import Foundation
import Combine

@MainActor
final class EventBatchRegistrationViewModel: ObservableObject {
    enum Phase: Equatable { case idle, checking, ready, failed(String), submitting, finished, sessionChanged }
    enum Result: Equatable {
        case pending, sending, confirmed(String), rejected(String), uncertain(String), notSent(String)
        var title: String {
            switch self {
            case .pending: return "待確認"
            case .sending: return "正在確認校方結果"
            case .confirmed: return "成功"
            case .rejected: return "失敗"
            case .uncertain: return "結果不明"
            case .notSent: return "未送出"
            }
        }
        var reason: String? {
            switch self {
            case .pending, .sending: return nil
            case .confirmed(let text), .rejected(let text), .uncertain(let text), .notSent(let text): return text
            }
        }
    }
    struct Item: Identifiable {
        let event: EventData
        let eligibility: EventBatchEligibility
        var result: Result = .pending
        var id: String { event.id }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [Item] = []
    @Published private(set) var stopRequested = false
    private let events: [EventData]
    private let service: any EventRegistrationServing
    private let revision: @MainActor () -> UUID
    private let initialRevision: UUID
    private let now: () -> Date
    private var readTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var readID = UUID()
    private var sessionObserver: AnyCancellable?

    init(events: [EventData], service: (any EventRegistrationServing)? = nil,
         sessionRevision: (@MainActor () -> UUID)? = nil, now: @escaping () -> Date = Date.init) {
        var seen = Set<String>()
        self.events = events.filter { seen.insert($0.id).inserted }
        let service = service ?? EventRegistrationClient.shared
        self.service = service
        let revision = sessionRevision ?? { (service as? EventRegistrationClient)?.sessionRevision ?? EventRegistrationClient.shared.sessionRevision }
        self.revision = revision
        initialRevision = revision()
        self.now = now
        sessionObserver = NotificationCenter.default.publisher(for: .didChangeEventRegistrationSession)
            .sink { [weak self] _ in self?.sessionDidChange() }
    }

    var eligibleCount: Int { items.filter { $0.eligibility.canSubmit }.count }
    var processedCount: Int {
        items.filter { $0.eligibility.canSubmit && $0.result != .pending && $0.result != .sending }.count
    }
    var canConfirm: Bool { phase == .ready && eligibleCount > 0 }
    var isSubmitting: Bool { phase == .submitting }

    func check() {
        guard phase == .idle || isReadFailure, validateSession() else { return }
        readTask?.cancel()
        let token = UUID()
        readID = token
        phase = .checking
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                let available = try await service.availableEvents()
                try Task.checkCancellation()
                guard readID == token, validateSession() else { return }
                let applied = try await service.appliedEvents()
                try Task.checkCancellation()
                guard readID == token, validateSession() else { return }
                EventRegistrationSubmission.shared.reconcileApplied(applied, session: initialRevision)
                let appliedIDs = Set(applied.map(\.eventSerialID))
                // Duplicate server IDs are ambiguous: never choose an arbitrary version.
                let grouped = Dictionary(grouping: available, by: \.eventSerialID)
                let uncertain = EventRegistrationSubmission.shared.blockedIDs(session: initialRevision)
                items = events.map { selected in
                    let fresh = grouped[selected.id]
                    let eligibility: EventBatchEligibility
                    if appliedIDs.contains(selected.id) {
                        eligibility = .excluded("已報名：校方已報名清單已有此活動。")
                    } else if let fresh, fresh.count == 1, let event = fresh.first {
                        eligibility = EventBatchEligibility.evaluate(event, appliedIDs: appliedIDs, uncertainIDs: uncertain, now: self.now())
                    } else {
                        eligibility = .excluded("無法判定：校方可報名清單沒有唯一且完整的此活動資料。")
                    }
                    return Item(event: fresh?.first ?? selected, eligibility: eligibility,
                                result: eligibility.canSubmit ? .pending : .notSent(eligibility.reason))
                }
                phase = .ready
            } catch {
                guard readID == token, validateSession() else { return }
                phase = error is CancellationError ? .idle : .failed(EventRegistrationError.message(for: error))
            }
            if readID == token { readTask = nil }
        }
    }

    /// Called only by the explicit confirmation button. There is no mutation in check().
    func confirm() {
        guard canConfirm, sendTask == nil, validateSession() else { return }
        phase = .submitting
        stopRequested = false
        sendTask = Task { [weak self] in
            guard let self else { return }
            for index in items.indices where items[index].eligibility.canSubmit {
                guard validateSession() else { break }
                if stopRequested {
                    items[index].result = .notSent("已停止，沒有送出此活動。")
                    continue
                }
                let id = items[index].id
                guard !EventRegistrationSubmission.shared.blockedIDs(session: initialRevision).contains(id) else {
                    items[index].result = .notSent("此活動已送出或結果不明，請查看「已報名活動」。")
                    continue
                }
                items[index].result = .sending
                let outcome: EventActionOutcome
                do {
                    outcome = try await EventRegistrationSubmission.shared.submit(eventID: id, service: service, session: initialRevision)
                } catch let error as EventRegistrationNotSubmittedError {
                    guard validateSession() else { break }
                    items[index].result = .notSent(error.localizedDescription)
                    continue
                } catch {
                    // An arbitrary service error cannot prove that a mutation never reached school.
                    outcome = .uncertain("無法確認是否完成：\(EventRegistrationError.message(for: error)) 請查看「已報名活動」，勿立即重送。")
                }
                guard validateSession() else { break }
                switch outcome {
                case .confirmed(let reason):
                    items[index].result = .confirmed(reason)
                case .rejected(let reason):
                    items[index].result = .rejected(reason)
                case .uncertain(let reason): items[index].result = .uncertain(reason)
                }
                NotificationCenter.default.post(name: .didChangeEventRegistration, object: nil)
            }
            if validateSession() { phase = .finished }
            sendTask = nil
        }
    }

    func stop() { stopRequested = true }

    /// Stop the next item, but keep the already-started request alive to obtain its outcome.
    func leave() {
        stop()
        readID = UUID()
        readTask?.cancel()
        readTask = nil
        if phase == .checking { phase = .idle }
    }

    func sessionDidChange() { _ = validateSession() }

    @discardableResult private func validateSession() -> Bool {
        guard revision() == initialRevision else {
            stopRequested = true
            readTask?.cancel()
            items = []
            phase = .sessionChanged
            return false
        }
        return true
    }

    private var isReadFailure: Bool { if case .failed = phase { return true }; return false }
}
