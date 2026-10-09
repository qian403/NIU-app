import Foundation
import Security

/// Holds the anonymous installation UUID. Production uses a device-only Keychain item so the value
/// survives reinstalling but never moves to another phone through a backup or device transfer.
protocol UsageInstallationIDStore: Sendable {
    func read() -> String?
    /// Returns false when the value could not be stored.
    func write(_ value: String) -> Bool
}

struct KeychainUsageInstallationIDStore: UsageInstallationIDStore {
    let service: String
    private let account = "installation-id"

    init(service: String = (Bundle.main.bundleIdentifier ?? "dev.chienniuapp") + ".usage") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}

/// First-party aggregate usage reporting. School accounts and personal data never enter this client.
actor UsageHeartbeatClient {
    static let shared = UsageHeartbeatClient()
    /// UserDefaults key used before the UUID moved to the Keychain; read once to migrate.
    static let installationKey = "app.usage.installationID.v1"
    static let lastReportedDayKey = "app.usage.lastReportedDay.v1"
    static let platform = "ios"

    private var isReporting = false
    private let session: URLSession
    private let defaults: UserDefaults
    private let idStore: UsageInstallationIDStore
    private let configuredBaseURL: URL?
    private let appVersion: String?
    private let now: @Sendable () -> Date

    private struct Heartbeat: Encodable {
        let installation_id: String
        let platform: String
        let app_version: String?
    }

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        defaults = .standard
        idStore = KeychainUsageInstallationIDStore()
        configuredBaseURL = Self.baseURL
        appVersion = Self.reportableVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        now = { Date() }
    }

    init(
        session: URLSession,
        defaults: UserDefaults,
        idStore: UsageInstallationIDStore,
        baseURL: URL?,
        appVersion: String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.defaults = defaults
        self.idStore = idStore
        configuredBaseURL = baseURL
        self.appVersion = Self.reportableVersion(appVersion)
        self.now = now
    }

    func report() async {
        guard !Task.isCancelled, !isReporting, let baseURL = configuredBaseURL else { return }
        let today = Self.taipeiDay(date: now())
        guard defaults.string(forKey: Self.lastReportedDayKey) != today else { return }

        isReporting = true
        defer { isReporting = false }

        let installationID = Self.installationID(store: idStore, defaults: defaults)
        guard let body = try? Self.heartbeatBody(installationID: installationID, appVersion: appVersion) else { return }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/usage/heartbeat"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await session.data(for: request, delegate: NoUsageHeartbeatRedirects())
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 204 else { return }
            defaults.set(today, forKey: Self.lastReportedDayKey)
        } catch {
            // Statistics are best effort. Login, startup and all local features continue normally.
        }
    }

    /// Returns the stable installation UUID. A value from an older build is moved from UserDefaults
    /// into the Keychain so existing devices are not counted as new. If the Keychain is unavailable
    /// the UserDefaults value is kept, because a fresh UUID on every launch would inflate new devices.
    static func installationID(store: UsageInstallationIDStore, defaults: UserDefaults) -> String {
        if let stored = store.read().flatMap(randomUUIDv4) {
            defaults.removeObject(forKey: installationKey)
            return stored
        }
        let legacy = defaults.string(forKey: installationKey).flatMap(randomUUIDv4)
        let value = legacy ?? UUID().uuidString.lowercased()
        if store.write(value) {
            defaults.removeObject(forKey: installationKey)
        } else {
            defaults.set(value, forKey: installationKey)
        }
        return value
    }

    /// The API accepts one to three numeric components; anything else is omitted rather than rejected.
    static func reportableVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ (1...4).contains($0.count) && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        return value
    }

    private static func randomUUIDv4(_ value: String) -> String? {
        guard let parsed = UUID(uuidString: value) else { return nil }
        let normalized = parsed.uuidString.lowercased()
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[2].first == "4",
              let variant = parts[3].first, "89ab".contains(variant) else { return nil }
        return normalized
    }

    static func heartbeatBody(installationID: String, appVersion: String?) throws -> Data {
        try JSONEncoder().encode(Heartbeat(installation_id: installationID, platform: platform, app_version: appVersion))
    }

    private static func taipeiDay(date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static var baseURL: URL? {
        var raw = Bundle.main.object(forInfoDictionaryKey: "NIUUsageAPIBaseURL") as? String ?? ""
        #if DEBUG
        raw = ProcessInfo.processInfo.environment["NIU_USAGE_API_URL"] ?? raw
        #endif
        guard let url = URL(string: raw), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return nil }
        if url.scheme == "https", url.host != nil { return url }
        #if DEBUG
        if url.scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") { return url }
        #endif
        return nil
    }
}

private final class NoUsageHeartbeatRedirects: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
