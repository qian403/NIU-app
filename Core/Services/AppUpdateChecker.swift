import Foundation
import Combine

/// Checks the public Taiwan App Store release on the first foreground activation each local day.
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()
    static let lastCheckKey = "app.update.lastCheckDate"
    static let failureDateKey = "app.update.lastFailureDate"
    static let failureCountKey = "app.update.failureCount"
    /// Failed lookups are retried on later activations the same day, up to this many attempts.
    static let maxDailyAttempts = 3

    struct Update {
        let version: String
        let url: URL
    }

    @Published private(set) var availableUpdate: Update?
    private var isChecking = false
    private let session: URLSession
    private let defaults: UserDefaults
    private let bundleID: String
    private let currentVersion: String
    private let now: () -> Date
    private let calendar: () -> Calendar

    private convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.init(
            session: URLSession(configuration: configuration),
            defaults: .standard,
            bundleID: Bundle.main.bundleIdentifier ?? "",
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        )
    }

    init(
        session: URLSession,
        defaults: UserDefaults,
        bundleID: String,
        currentVersion: String,
        now: @escaping () -> Date = { Date() },
        calendar: @escaping () -> Calendar = { Calendar.current }
    ) {
        self.session = session
        self.defaults = defaults
        self.bundleID = bundleID
        self.currentVersion = currentVersion
        self.now = now
        self.calendar = calendar
    }

    func checkIfNeeded() async {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              !Task.isCancelled, !isChecking, availableUpdate == nil,
              !bundleID.isEmpty, Self.versionComponents(currentVersion) != nil else { return }
        let date = now()
        let calendar = calendar()
        if let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date,
           calendar.isDate(lastCheck, inSameDayAs: date) {
            return
        }
        var failures = 0
        if let lastFailure = defaults.object(forKey: Self.failureDateKey) as? Date,
           calendar.isDate(lastFailure, inSameDayAs: date) {
            failures = defaults.integer(forKey: Self.failureCountKey)
        }
        guard failures < Self.maxDailyAttempts else { return }

        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "country", value: "tw"),
            // Apple's CDN caches this URL for hours, so today's single check could otherwise
            // see a listing from before the latest release. A unique key forces a fresh answer.
            URLQueryItem(name: "_", value: UUID().uuidString)
        ]
        guard let url = components.url else { return }

        isChecking = true
        // Count the attempt as failed before suspending so a relaunch mid-request still counts
        // toward today's limit. Only a valid App Store answer completes today's check.
        defaults.set(date, forKey: Self.failureDateKey)
        defaults.set(failures + 1, forKey: Self.failureCountKey)
        defer { isChecking = false }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else { return }
            let lookup = try JSONDecoder().decode(LookupResponse.self, from: data)
            // A valid listing answers today's check, including when no newer version exists.
            defaults.set(date, forKey: Self.lastCheckKey)
            defaults.removeObject(forKey: Self.failureDateKey)
            defaults.removeObject(forKey: Self.failureCountKey)
            guard let app = lookup.results.first(where: { $0.bundleId == bundleID }),
                  Self.isNewer(app.version, than: currentVersion),
                  let storeURL = URL(string: app.trackViewUrl),
                  storeURL.scheme == "https", storeURL.host == "apps.apple.com",
                  storeURL.user == nil, storeURL.password == nil else { return }
            availableUpdate = Update(version: app.version, url: storeURL)
        } catch {
            // Best effort only: a lookup failure must not interrupt launch or login;
            // a later activation today may retry within maxDailyAttempts.
        }
    }

    func dismissUpdate() {
        availableUpdate = nil
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let lhs = versionComponents(candidate), let rhs = versionComponents(installed) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func versionComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }

    private struct LookupResponse: Decodable {
        let results: [StoreApp]
    }

    private struct StoreApp: Decodable {
        let bundleId: String
        let version: String
        let trackViewUrl: String
    }
}
