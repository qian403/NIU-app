import ActivityKit
import CryptoKit
import DeviceCheck
import Foundation
import Security

/// Optional remote enhancement. Local schedule rendering never awaits this client.
@MainActor
final class LiveActivityRemoteClient {
    static let shared = LiveActivityRemoteClient()
    static let consentKey = "app.liveActivity.remoteConsent.v1"
    private let keychainService = "dev.chien.niuapp.liveactivity.credentials.v1"
    private let appAttestAccount = "app-attest-key"
    private var task: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var generation = 0
    private var observedID: String?
    private var pushToken: String?
    private var records: [Credential] = []
    private let session: URLSession

    private struct Credential: Codable {
        var token: String
        var activityID: String
        var endpoint: String
        var expiresAt: Date
        var revision: Int64
        var revoked: Bool
    }
    private struct AppAttestKey: Codable {
        let keyID: String
        var attested: Bool
    }
    private struct Registration: Decodable { let token: String; let expires_at: TimeInterval }
    private struct ChallengeRequest: Encodable { let key_id: String }
    private struct Challenge: Decodable {
        let challenge_id: String
        let challenge: String
        let attestation_required: Bool
        let expires_at: TimeInterval
    }
    private struct AttestedRegistration: Encodable {
        let challenge_id: String
        let key_id: String
        let attestation_object: String?
        let assertion: String?
    }
    private struct Upload: Encodable {
        let activity_id: String
        let update_token: String
        let revision: Int64
        let expires_at: Date
        let sessions: [ScheduleSession]
    }
    private enum RemoteError: Error { case invalidConfiguration, response, keychain }

    static var baseURL: URL? {
        var raw = Bundle.main.object(forInfoDictionaryKey: "NIUActivityAPIBaseURL") as? String ?? ""
        #if DEBUG
        raw = ProcessInfo.processInfo.environment["NIU_ACTIVITY_API_URL"] ?? raw
        #endif
        guard let url = URL(string: raw), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return nil }
        if url.scheme == "https", url.host != nil { return url }
        #if DEBUG
        if url.scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") { return url }
        #endif
        return nil
    }
    static var enabled: Bool { baseURL != nil && UserDefaults.standard.bool(forKey: consentKey) }

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        records = (try? JSONDecoder().decode([Credential].self, from: readKeychain())) ?? []
        // Credentials are bound to one activity, never a school username.
        records.removeAll { $0.expiresAt <= Date() }
    }

    func observe(_ activity: Activity<ClassLiveActivityAttributes>) {
        retryCleanup()
        guard Self.enabled else { return }
        if observedID == activity.id {
            if let pushToken { upload(activity, token: pushToken) }
            return
        }
        generation &+= 1
        task?.cancel(); uploadTask?.cancel()
        for index in records.indices where records[index].activityID != activity.id || records[index].endpoint != Self.baseURL?.absoluteString {
            records[index].revoked = true
        }
        do { try persist() } catch { return }
        retryCleanup()
        observedID = activity.id
        pushToken = activity.pushToken.map { $0.map { String(format: "%02x", $0) }.joined() }
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            if let token = self.pushToken { self.upload(activity, token: token) }
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled, current == self.generation else { return }
                let value = token.map { String(format: "%02x", $0) }.joined()
                self.pushToken = value
                self.upload(activity, token: value)
            }
        }
    }
    // A separate finite task allows schedule revisions without cancelling token observation.
    private var uploadTask: Task<Void, Never>?
    private func upload(_ activity: Activity<ClassLiveActivityAttributes>, token: String) {
        uploadTask?.cancel()
        let current = generation
        uploadTask = Task { [weak self] in await self?.synchronize(activity, token: token, generation: current) }
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: Self.consentKey)
        stop()
    }
    func stop() {
        generation &+= 1
        task?.cancel(); task = nil
        uploadTask?.cancel(); uploadTask = nil
        observedID = nil; pushToken = nil
        for index in records.indices { records[index].revoked = true }
        do { try persist() } catch { /* Existing Keychain entries remain for expiry/next cleanup. */ }
        retryCleanup()
    }
    func retryCleanup() {
        guard cleanupTask == nil else { return }
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            defer { self.cleanupTask = nil }
            var attempted: Set<String> = []
            while let record = self.records.first(where: { $0.revoked && !attempted.contains($0.token) }) {
                attempted.insert(record.token)
                guard !Task.isCancelled else { return }
                if record.expiresAt > Date() {
                    do { _ = try await self.request(endpoint: record.endpoint, path: "v1/me/device-session", method: "DELETE", token: record.token) }
                    catch { continue }
                }
                self.records.removeAll { $0.token == record.token }
                do { try self.persist() } catch { return }
            }
        }
    }

    private func synchronize(_ activity: Activity<ClassLiveActivityAttributes>, token: String, generation current: Int) async {
        guard Self.enabled, current == generation, !Task.isCancelled,
              let base = Self.baseURL, (activity.activityState == .active || activity.activityState == .stale),
              let data = UserDefaults(suiteName: "group.dev.chien.niuapp")?.data(forKey: "classSchedule.v2.cachedData"),
              let schedule = try? JSONDecoder().decode(ClassSchedule.self, from: data) else { return }
        let now = Date()
        let limit = activity.attributes.startedAt.addingTimeInterval(7 * 3600 + 55 * 60)
        let sessions = schedule.sessions(on: now).filter { $0.end > now && $0.end <= limit }
        guard let last = sessions.last else { return }
        let endpoint = base.absoluteString
        do {
            if !records.contains(where: { !$0.revoked && $0.activityID == activity.id && $0.endpoint == endpoint && $0.expiresAt > now }) {
                let data = try await createDeviceSession(endpoint: endpoint)
                let response = try JSONDecoder().decode(Registration.self, from: data)
                let revoked = current != generation || Task.isCancelled || !Self.enabled
                records.append(Credential(token: response.token, activityID: activity.id, endpoint: endpoint,
                                          expiresAt: Date(timeIntervalSince1970: response.expires_at), revision: 0, revoked: revoked))
                try persist()
                if revoked { retryCleanup(); return }
            }
            guard current == generation, !Task.isCancelled, Self.enabled,
                  let index = records.firstIndex(where: { !$0.revoked && $0.activityID == activity.id && $0.endpoint == endpoint && $0.expiresAt > now }) else { return }
            records[index].revision += 1
            let credential = records[index]
            try persist()
            let body = Upload(activity_id: activity.id, update_token: token, revision: credential.revision,
                              expires_at: last.end, sessions: sessions)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            _ = try await request(endpoint: endpoint, path: "v1/me/live-activity", method: "PUT", token: credential.token, body: encoder.encode(body))
        } catch {
            // No payload/URL/token is logged. The next foreground refresh retries;
            // the system's stale state is the user-visible fallback.
        }
    }

    private func createDeviceSession(endpoint: String) async throws -> Data {
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw RemoteError.invalidConfiguration }
        do {
            return try await createDeviceSession(endpoint: endpoint, service: service, key: try await appAttestKey(service: service), mayReplaceKey: true)
        } catch {
            let deviceCheckError = error as NSError
            guard deviceCheckError.domain == DCErrorDomain,
                  deviceCheckError.code == DCError.invalidKey.rawValue else { throw error }
            try deleteAppAttestKeyID()
            return try await createDeviceSession(endpoint: endpoint, service: service, key: try await appAttestKey(service: service), mayReplaceKey: false)
        }
    }

    private func createDeviceSession(endpoint: String, service: DCAppAttestService, key: AppAttestKey, mayReplaceKey: Bool) async throws -> Data {
        let encoder = JSONEncoder()
        let challengeData = try await request(
            endpoint: endpoint,
            path: "v1/device-attestation/challenges",
            method: "POST",
            body: encoder.encode(ChallengeRequest(key_id: key.keyID))
        )
        let challenge = try JSONDecoder().decode(Challenge.self, from: challengeData)
        guard challenge.expires_at > Date().timeIntervalSince1970,
              let rawChallenge = Data(base64Encoded: challenge.challenge), rawChallenge.count == 32 else {
            throw RemoteError.response
        }
        let clientDataHash = Data(SHA256.hash(data: rawChallenge))
        let registration: AttestedRegistration
        if challenge.attestation_required {
            // Apple keys should only be attested once. If the server no longer knows a
            // previously attested key, replace it instead of trying to re-attest it.
            if key.attested, mayReplaceKey {
                try deleteAppAttestKeyID()
                return try await createDeviceSession(endpoint: endpoint, service: service, key: try await appAttestKey(service: service), mayReplaceKey: false)
            }
            let attestation = try await service.attestKey(key.keyID, clientDataHash: clientDataHash)
            try writeKeychain(JSONEncoder().encode(AppAttestKey(keyID: key.keyID, attested: true)), account: appAttestAccount)
            registration = AttestedRegistration(
                challenge_id: challenge.challenge_id,
                key_id: key.keyID,
                attestation_object: attestation.base64EncodedString(),
                assertion: nil
            )
        } else {
            let assertion = try await service.generateAssertion(key.keyID, clientDataHash: clientDataHash)
            if !key.attested {
                try writeKeychain(JSONEncoder().encode(AppAttestKey(keyID: key.keyID, attested: true)), account: appAttestAccount)
            }
            registration = AttestedRegistration(
                challenge_id: challenge.challenge_id,
                key_id: key.keyID,
                attestation_object: nil,
                assertion: assertion.base64EncodedString()
            )
        }
        return try await request(
            endpoint: endpoint,
            path: "v1/device-sessions",
            method: "POST",
            body: encoder.encode(registration)
        )
    }

    private func appAttestKey(service: DCAppAttestService) async throws -> AppAttestKey {
        if let data = try? readKeychain(account: appAttestAccount) {
            if let key = try? JSONDecoder().decode(AppAttestKey.self, from: data), !key.keyID.isEmpty { return key }
            // Upgrade the first local implementation, which stored only the key ID.
            if let keyID = String(data: data, encoding: .utf8), !keyID.isEmpty {
                let key = AppAttestKey(keyID: keyID, attested: false)
                try writeKeychain(JSONEncoder().encode(key), account: appAttestAccount)
                return key
            }
        }
        let keyID = try await service.generateKey()
        let key = AppAttestKey(keyID: keyID, attested: false)
        try writeKeychain(JSONEncoder().encode(key), account: appAttestAccount)
        return key
    }

    private func request(endpoint: String, path: String, method: String, token: String? = nil, body: Data? = nil) async throws -> Data {
        guard let base = URL(string: endpoint), base.scheme == "https" || (Self.baseURL?.absoluteString == endpoint && base.scheme == "http") else { throw RemoteError.invalidConfiguration }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request, delegate: NoActivityRedirects())
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) || (method == "DELETE" && response.statusCode == 401) else { throw RemoteError.response }
        return data
    }
    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "activity-sessions"]
    }
    private func keychainQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
         kSecAttrAccount as String: account]
    }
    private func readKeychain() throws -> Data {
        try readKeychain(account: "activity-sessions")
    }
    private func readKeychain(account: String) throws -> Data {
        var query = keychainQuery(account: account); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { throw RemoteError.keychain }
        return data
    }
    private func persist() throws {
        records.removeAll { $0.expiresAt <= Date() }
        try writeKeychain(JSONEncoder().encode(records), account: "activity-sessions")
    }
    private func writeKeychain(_ data: Data, account: String) throws {
        let query = keychainQuery(account: account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query; addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw RemoteError.keychain }
        } else if status != errSecSuccess { throw RemoteError.keychain }
    }
    private func deleteAppAttestKeyID() throws {
        let status = SecItemDelete(keychainQuery(account: appAttestAccount) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw RemoteError.keychain }
    }
}

private final class NoActivityRedirects: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
