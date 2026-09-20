import Foundation

/// First-party aggregate usage reporting. School accounts and personal data never enter this client.
actor UsageHeartbeatClient {
    static let shared = UsageHeartbeatClient()
    static let installationKey = "app.usage.installationID.v1"
    static let lastReportedDayKey = "app.usage.lastReportedDay.v1"

    private var isReporting = false
    private let session: URLSession
    private let defaults: UserDefaults
    private let configuredBaseURL: URL?
    private let now: @Sendable () -> Date

    private struct Heartbeat: Encodable {
        let installation_id: String
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
        configuredBaseURL = Self.baseURL
        now = { Date() }
    }

    init(session: URLSession, defaults: UserDefaults, baseURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.defaults = defaults
        configuredBaseURL = baseURL
        self.now = now
    }

    func report() async {
        guard !Task.isCancelled, !isReporting, let baseURL = configuredBaseURL else { return }
        let today = Self.taipeiDay(date: now())
        guard defaults.string(forKey: Self.lastReportedDayKey) != today else { return }

        isReporting = true
        defer { isReporting = false }

        let installationID = Self.installationID(in: defaults)
        guard let body = try? Self.heartbeatBody(installationID: installationID) else { return }

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

    static func installationID(in defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: installationKey), let normalized = randomUUIDv4(existing) {
            return normalized
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: installationKey)
        return created
    }

    private static func randomUUIDv4(_ value: String) -> String? {
        guard let parsed = UUID(uuidString: value) else { return nil }
        let normalized = parsed.uuidString.lowercased()
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[2].first == "4",
              let variant = parts[3].first, "89ab".contains(variant) else { return nil }
        return normalized
    }

    static func heartbeatBody(installationID: String) throws -> Data {
        try JSONEncoder().encode(Heartbeat(installation_id: installationID))
    }

    private static func taipeiDay(date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static var baseURL: URL? {
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
