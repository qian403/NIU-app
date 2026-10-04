import Foundation
import Combine

/// Local personal data. Every read/write is fenced by account, login session and a clear generation.
/// AppState must call `shared.clear()` before replacing login identity and before clearing logout identity.
@MainActor
final class EventFavoritesStore: ObservableObject {
    struct Session: Codable, Equatable {
        let account: String
        let authSessionID: String
        fileprivate let generation: UUID
    }

    private struct Record: Codable, Equatable {
        let session: Session
        var ids: Set<String>
    }

    static let shared = EventFavoritesStore()
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private let account: @MainActor () -> String?
    private let sessionID: @MainActor () -> String?
    private let key = "eventFavorites.v1.record"
    private let generationKey = "eventFavorites.v1.generation"
    private var cached: Record?

    init(defaults: UserDefaults = .standard,
         account: @escaping @MainActor () -> String? = { UserDefaults.standard.string(forKey: StorageKeys.username) },
         session: @escaping @MainActor () -> String? = { UserDefaults.standard.string(forKey: StorageKeys.authSessionID) }) {
        self.defaults = defaults
        self.account = account
        self.sessionID = session
        _ = synchronize()
    }

    var currentSession: Session? { synchronize()?.session }

    func isCurrent(_ session: Session?) -> Bool {
        guard let session else { return false }
        return synchronize()?.session == session
    }

    func favorites(for session: Session?) -> Set<String> {
        guard let record = synchronize(), record.session == session else { return [] }
        return record.ids
    }

    func setFavorite(_ favorite: Bool, ids: Set<String>, session: Session?) {
        guard var record = synchronize(), record.session == session else { return }
        let ids = ids.filter { !$0.isEmpty }
        if favorite { record.ids.formUnion(ids) } else { record.ids.subtract(ids) }
        save(record)
    }

    /// Invalidates existing clients even if the caller has not removed the username/session yet.
    func clear() {
        defaults.removeObject(forKey: key)
        defaults.set(UUID().uuidString, forKey: generationKey)
        cached = nil
        revision += 1
    }

    private func identity() -> (account: String, session: String)? {
        guard let account = account()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !account.isEmpty, let session = sessionID(), !session.isEmpty else { return nil }
        return (account, session)
    }

    @discardableResult
    private func synchronize() -> Record? {
        guard let identity = identity() else {
            let hadRecord = cached != nil || defaults.object(forKey: key) != nil
            defaults.removeObject(forKey: key)
            cached = nil
            if hadRecord { revision += 1 }
            return nil
        }
        if let data = defaults.data(forKey: key),
           let record = try? JSONDecoder().decode(Record.self, from: data),
           record.session.generation.uuidString == defaults.string(forKey: generationKey),
           record.session.account == identity.account, record.session.authSessionID == identity.session {
            if cached != record { cached = record; revision += 1 }
            return record
        }
        // A new account/session never inherits or retains the old account's personal cache.
        let record = Record(session: Session(account: identity.account, authSessionID: identity.session,
                                            generation: UUID()), ids: [])
        defaults.set(record.session.generation.uuidString, forKey: generationKey)
        save(record)
        return record
    }

    private func save(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
        if cached != record { cached = record; revision += 1 }
    }
}
