import SwiftUI
import Combine

@MainActor
final class EventRegistrationViewModel: ObservableObject {
    @Published var selectedTab: Int = 0
}

enum EventLoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

struct EventActionAlert: Identifiable {
    enum Kind { case success, failure, uncertain }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String

    init(_ outcome: EventActionOutcome, action: String) {
        switch outcome {
        case .confirmed(let message): (kind, title, self.message) = (.success, "\(action)完成", message)
        case .rejected(let message): (kind, title, self.message) = (.failure, "未完成\(action)", message)
        case .uncertain(let message): (kind, title, self.message) = (.uncertain, "無法確認\(action)結果", message)
        }
    }

    /// An error thrown before the request was sent, so nothing changed at the school.
    init(error: Error, action: String) {
        kind = .failure
        title = "未完成\(action)"
        message = EventRegistrationError.message(for: error)
    }
}

extension EventRegistrationError {
    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? EventRegistrationError.unavailable.localizedDescription
    }
}

extension Notification.Name {
    /// Posted after a registration, cancellation or edit was sent, so both lists reload.
    static let didChangeEventRegistration = Notification.Name("didChangeEventRegistration")
}

// MARK: - 修改報名資料

@MainActor
final class EventRegistrationFormViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published var form = EventRegistrationForm()
    private var original: EventRegistrationForm?
    private let eventID: String
    private let service: any EventRegistrationServing
    private var task: Task<Void, Never>?

    init(eventID: String, service: (any EventRegistrationServing)? = nil) {
        self.eventID = eventID
        self.service = service ?? EventRegistrationClient.shared
    }

    var isValid: Bool {
        let mail = form.mail.trimmingCharacters(in: .whitespacesAndNewlines)
        return phase == .loaded && !form.tel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && mail.contains("@") && !mail.hasPrefix("@") && !mail.hasSuffix("@")
    }

    var hasChanges: Bool {
        original.map { !form.matchesEditableFields(of: $0) } ?? false
    }

    func load() {
        task?.cancel()
        phase = .loading
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await service.registrationForm(eventID: eventID)
                try Task.checkCancellation()
                form = loaded
                original = loaded
                phase = .loaded
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(EventRegistrationError.message(for: error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
