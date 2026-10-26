import Foundation
import CryptoKit
import Combine
import Security

/// A classmate's timetable received by QR code.
nonisolated struct ExchangedSchedule: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var payload: ScheduleSharePayload
    var importedAt: Date

    var displayName: String { payload.nickname.isEmpty ? "未命名同學" : payload.nickname }

    func isExpired(at date: Date) -> Bool { payload.term.endDate <= date }
    /// Expired entries stay visible for this long so a summer course or a wrong term can be noticed first.
    static let deletionGrace: TimeInterval = 30 * 24 * 60 * 60
    func shouldDelete(at date: Date) -> Bool { payload.term.endDate.addingTimeInterval(Self.deletionGrace) <= date }
}

/// Per-account sharing preferences, kept with the account's storage ID.
nonisolated struct ScheduleSharePreferences: Codable, Equatable, Sendable {
    enum NicknameMode: String, Codable, Sendable { case custom, realName }

    var shareID = UUID()
    var nicknameMode = NicknameMode.custom
    var customNickname = ""
    var includeRooms = false
    var includeTeachers = false
}

/// Classmates' timetables are other people's personal data. Each account's list lives in its own
/// AES-GCM file (complete file protection, excluded from backup) whose key is a device-only Keychain
/// item; nothing is written to UserDefaults or the App Group. Logout keeps the files and only clears memory.
@MainActor
final class ScheduleExchangeStore: ObservableObject {
    static let shared = ScheduleExchangeStore()

    enum Status: Equatable {
        case ready
        /// Protected data is unavailable until the device is unlocked; nothing was changed.
        case locked
        /// The file exists but cannot be opened with this account's key. Never overwritten automatically.
        case unreadable
        case signedOut
    }

    @Published private(set) var schedules: [ExchangedSchedule] = []
    @Published private(set) var preferences = ScheduleSharePreferences()
    @Published private(set) var status: Status = .signedOut
    /// A failed write; memory still shows what is on disk.
    @Published var errorMessage: String?

    private var account: String?
    private var sessionID: String?
    private var storageID: UUID?
    private let backend: ScheduleExchangeBackend

    private init() {
        backend = KeychainFileScheduleExchangeBackend()
    }

    #if DEBUG
    /// Isolated store for UI fixtures and checks; never touches the real Keychain or files.
    init(backend: ScheduleExchangeBackend, account: String) {
        self.backend = backend
        fixtureAccount = account
    }
    private var fixtureAccount: String?
    #endif

    private var currentAccount: String? {
        #if DEBUG
        if let fixtureAccount { return fixtureAccount }
        #endif
        guard !UserDefaults.standard.bool(forKey: "app.logoutCleanupPending") else { return nil }
        return UserDefaults.standard.string(forKey: StorageKeys.username)?.nilIfBlank
    }

    private var currentSessionID: String? {
        #if DEBUG
        if fixtureAccount != nil { return "fixture" }
        #endif
        return UserDefaults.standard.string(forKey: StorageKeys.authSessionID)
    }

    /// Re-reads the signed-in account's list and removes entries past their grace period.
    func reload(now: Date = Date()) {
        clearMemory()
        guard let account = currentAccount, let sessionID = currentSessionID else { return }
        do {
            let entry = try backend.accountEntry(for: account)
            let list = try backend.load(storageID: entry.storageID)
            self.account = account
            self.sessionID = sessionID
            storageID = entry.storageID
            preferences = entry.preferences
            schedules = list
            status = .ready
            if list.contains(where: { $0.shouldDelete(at: now) }) {
                // On failure the expired entries stay listed and cleanup is retried on the next reload.
                persist(list.filter { !$0.shouldDelete(at: now) })
            }
        } catch ScheduleExchangeBackendError.locked {
            status = .locked
        } catch {
            status = .unreadable
        }
    }

    /// Called on logout: the encrypted files stay, nothing of the previous account stays in memory.
    func clearMemory() {
        errorMessage = nil
        schedules = []
        preferences = ScheduleSharePreferences()
        account = nil
        sessionID = nil
        storageID = nil
        status = .signedOut
    }

    /// Whether the store still belongs to the account and login session that started an operation.
    var isCurrent: Bool {
        status == .ready && account != nil && account == currentAccount && sessionID == currentSessionID
    }

    /// The saved entry an imported payload would update: same sharer ID and term. The ID is not proof
    /// of identity, so callers ask the user instead of overwriting automatically.
    func existing(matching payload: ScheduleSharePayload) -> ExchangedSchedule? {
        schedules.first { $0.payload.shareID == payload.shareID && $0.payload.term == payload.term }
    }

    /// Returns the saved entry's ID, or nil when nothing was written.
    @discardableResult
    func save(_ payload: ScheduleSharePayload, replacing id: UUID?, now: Date = Date()) -> UUID? {
        guard isCurrent else { return nil }
        var list = schedules
        let savedID: UUID
        if let id, let index = list.firstIndex(where: { $0.id == id }) {
            list[index].payload = payload
            list[index].importedAt = now
            savedID = id
        } else {
            savedID = UUID()
            list.append(ExchangedSchedule(id: savedID, payload: payload, importedAt: now))
        }
        return persist(list) ? savedID : nil
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard isCurrent else { return false }
        return persist(schedules.filter { $0.id != id })
    }

    func updatePreferences(_ change: (inout ScheduleSharePreferences) -> Void) {
        guard isCurrent, let account else { return }
        var value = preferences
        change(&value)
        guard value != preferences else { return }
        do {
            try backend.savePreferences(value, for: account)
            preferences = value
        } catch {
            report(error)
        }
    }

    /// Classmates who saved the old code can no longer match new codes to their entry.
    func resetShareID() {
        updatePreferences { $0.shareID = UUID() }
    }

    /// Removes the unreadable file and its key after the user confirms; other accounts are untouched.
    func resetUnreadableData() {
        guard status == .unreadable, let account = currentAccount else { return }
        do {
            try backend.removeAccount(account)
            reload()
        } catch {
            errorMessage = "無法清除資料，請稍後再試。"
        }
    }

    /// Memory changes only after the backend confirms the write, so a failed delete never looks done.
    @discardableResult
    private func persist(_ list: [ExchangedSchedule]) -> Bool {
        guard let storageID else { return false }
        do {
            try backend.save(list, storageID: storageID)
            schedules = list
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: Error) {
        if case ScheduleExchangeBackendError.locked = error {
            status = .locked
            errorMessage = "裝置已鎖定，請解鎖後再試。"
        } else {
            errorMessage = "無法儲存變更，請稍後再試。"
        }
    }
}

// MARK: - Backend

nonisolated enum ScheduleExchangeBackendError: Error {
    case locked
    case unreadable
    case keychain(OSStatus)
}

nonisolated struct ScheduleExchangeAccountEntry: Codable, Sendable {
    let storageID: UUID
    var preferences: ScheduleSharePreferences
}

nonisolated protocol ScheduleExchangeBackend: Sendable {
    /// Creates the account's entry on first use.
    func accountEntry(for account: String) throws -> ScheduleExchangeAccountEntry
    func savePreferences(_ preferences: ScheduleSharePreferences, for account: String) throws
    func load(storageID: UUID) throws -> [ExchangedSchedule]
    func save(_ list: [ExchangedSchedule], storageID: UUID) throws
    func removeAccount(_ account: String) throws
}

/// The account index (username → random storage ID and preferences) and each account's AES key are
/// device-only Keychain items, so neither file names nor UserDefaults reveal the username.
nonisolated struct KeychainFileScheduleExchangeBackend: ScheduleExchangeBackend {
    private let service = "dev.chien.niuapp.scheduleExchange"
    private let indexAccount = "account-index"

    func accountEntry(for account: String) throws -> ScheduleExchangeAccountEntry {
        var index = try readIndex()
        if let entry = index[account] { return entry }
        let entry = ScheduleExchangeAccountEntry(storageID: UUID(), preferences: ScheduleSharePreferences())
        index[account] = entry
        try write(JSONEncoder().encode(index), account: indexAccount)
        return entry
    }

    func savePreferences(_ preferences: ScheduleSharePreferences, for account: String) throws {
        var index = try readIndex()
        guard var entry = index[account] else { throw ScheduleExchangeBackendError.unreadable }
        entry.preferences = preferences
        index[account] = entry
        try write(JSONEncoder().encode(index), account: indexAccount)
    }

    func load(storageID: UUID) throws -> [ExchangedSchedule] {
        let url = try fileURL(storageID)
        let sealed: Data
        do {
            sealed = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw ScheduleExchangeBackendError.locked
        }
        guard let keyData = try read(account: keyAccount(storageID)) else {
            throw ScheduleExchangeBackendError.unreadable
        }
        return try Self.open(sealed, key: keyData, storageID: storageID)
    }

    /// AES-GCM with the storage ID as associated data, so a file copied onto another account's name fails to open.
    static func seal(_ list: [ExchangedSchedule], key: Data, storageID: UUID) throws -> Data {
        let plain = try JSONEncoder().encode(list)
        let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: key), authenticating: Data(storageID.uuidString.utf8))
        guard let combined = sealed.combined else { throw ScheduleExchangeBackendError.unreadable }
        return combined
    }

    static func open(_ sealed: Data, key: Data, storageID: UUID) throws -> [ExchangedSchedule] {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(storageID.uuidString.utf8))
            return try JSONDecoder().decode([ExchangedSchedule].self, from: plain)
        } catch {
            throw ScheduleExchangeBackendError.unreadable
        }
    }

    func save(_ list: [ExchangedSchedule], storageID: UUID) throws {
        let url = try fileURL(storageID)
        if list.isEmpty {
            try Self.removeFileIfPresent(url)
            return
        }
        let keyData: Data
        if let existing = try read(account: keyAccount(storageID)) {
            keyData = existing
        } else {
            // A file without its key is unreadable; never replace it silently.
            guard !FileManager.default.fileExists(atPath: url.path) else { throw ScheduleExchangeBackendError.unreadable }
            keyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try write(keyData, account: keyAccount(storageID))
        }
        try Self.seal(list, key: keyData, storageID: storageID).write(to: url, options: [.atomic, .completeFileProtection])
        // Best effort: a backed-up copy cannot be opened on another device because the key is device-only.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    func removeAccount(_ account: String) throws {
        var index = try readIndex()
        guard let entry = index.removeValue(forKey: account) else { return }
        try Self.removeFileIfPresent(fileURL(entry.storageID))
        try delete(account: keyAccount(entry.storageID))
        try write(JSONEncoder().encode(index), account: indexAccount)
    }

    private static func removeFileIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    // MARK: Files

    private func fileURL(_ storageID: UUID) throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("ScheduleExchange", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableFolder = folder
            try? mutableFolder.setResourceValues(values)   // best effort, see `save`
        }
        return folder.appendingPathComponent("\(storageID.uuidString).bin")
    }

    // MARK: Keychain

    private func keyAccount(_ storageID: UUID) -> String { "key-\(storageID.uuidString)" }

    private func readIndex() throws -> [String: ScheduleExchangeAccountEntry] {
        guard let data = try read(account: indexAccount) else { return [:] }
        guard let index = try? JSONDecoder().decode([String: ScheduleExchangeAccountEntry].self, from: data) else {
            throw ScheduleExchangeBackendError.unreadable
        }
        return index
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(account: String) throws -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case errSecInteractionNotAllowed: throw ScheduleExchangeBackendError.locked
        default: throw ScheduleExchangeBackendError.keychain(status)
        }
    }

    private func write(_ data: Data, account: String) throws {
        let query = query(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw added == errSecInteractionNotAllowed ? ScheduleExchangeBackendError.locked
                                                           : ScheduleExchangeBackendError.keychain(added)
            }
        } else if status == errSecInteractionNotAllowed {
            throw ScheduleExchangeBackendError.locked
        } else if status != errSecSuccess {
            throw ScheduleExchangeBackendError.keychain(status)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound: return
        case errSecInteractionNotAllowed: throw ScheduleExchangeBackendError.locked
        default: throw ScheduleExchangeBackendError.keychain(status)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
