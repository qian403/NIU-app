import Foundation

nonisolated struct CreditsDocument: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let description: String
        let projectName: String
        let url: URL
        let order: Int
    }

    let schemaVersion: Int
    let revision: Int
    let introduction: String
    let entries: [Entry]

    var sortedEntries: [Entry] {
        entries.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 131_072 else { throw CreditsError.invalidDocument }
        let document = try JSONDecoder().decode(Self.self, from: data)
        guard document.schemaVersion == 1, document.revision > 0,
              validText(document.introduction, limit: 2_000), document.entries.count <= 100,
              Set(document.entries.map(\.id)).count == document.entries.count else {
            throw CreditsError.invalidDocument
        }
        for entry in document.entries {
            guard validText(entry.id, limit: 100), validText(entry.name, limit: 200),
                  validText(entry.description, limit: 2_000), validText(entry.projectName, limit: 200),
                  entry.url.absoluteString.count <= 2_048,
                  let components = URLComponents(url: entry.url, resolvingAgainstBaseURL: false),
                  components.scheme == "https", let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil else {
                throw CreditsError.invalidDocument
            }
        }
        return document
    }

    private static func validText(_ text: String, limit: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= limit
    }
}

nonisolated enum CreditsError: Error {
    case invalidDocument
    case httpStatus(Int)
    case revisionConflict
}

nonisolated struct CreditsSnapshot: Sendable {
    enum Source: String, Sendable {
        case bundled = "App 內建名單"
        case cache = "本機快取"
        case remote = "GitHub 最新名單"
    }

    let document: CreditsDocument?
    let source: Source
    var message: String?
}

/// Public content only. Actor isolation keeps disk work off the main actor and
/// serializes revision validation and atomic cache replacement.
actor CreditsStore {
    static let shared = CreditsStore()
    typealias Fetch = @Sendable () async throws -> Data

    private let cacheURL: URL
    private let bundleURL: URL?
    private let fetch: Fetch
    private var snapshot: CreditsSnapshot?
    private var lastChecked: Date?
    private var requestGeneration = 0

    init(cacheURL: URL = URL.cachesDirectory.appendingPathComponent("NIUCredits-v1/credits.json"),
         bundleURL: URL? = Bundle.main.url(forResource: "credits", withExtension: "json"),
         fetch: @escaping Fetch = CreditsStore.download) {
        self.cacheURL = cacheURL
        self.bundleURL = bundleURL
        self.fetch = fetch
    }

    func local() -> CreditsSnapshot {
        if let snapshot { return snapshot }
        let bundled = bundleURL.flatMap { try? CreditsDocument.decode(Data(contentsOf: $0)) }
        let cached = try? CreditsDocument.decode(Data(contentsOf: cacheURL))
        let useCache = cached.map { $0.revision > (bundled?.revision ?? 0) } ?? false
        let result = CreditsSnapshot(document: useCache ? cached : bundled,
                                     source: useCache ? .cache : .bundled,
                                     message: nil)
        snapshot = result
        return result
    }

    func refresh(force: Bool = false, now: Date = Date()) async throws -> CreditsSnapshot {
        let current = local()
        if !force, let lastChecked, now.timeIntervalSince(lastChecked) >= 0,
           now.timeIntervalSince(lastChecked) < 21_600 {
            return current
        }
        requestGeneration += 1
        let generation = requestGeneration
        do {
            let data = try await fetch()
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            let incoming = try CreditsDocument.decode(data)
            if let existing = snapshot?.document {
                guard incoming.revision >= existing.revision,
                      incoming.revision != existing.revision || incoming == existing else {
                    throw CreditsError.revisionConflict
                }
            }
            var message: String?
            do {
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: cacheURL, options: .atomic)
            } catch {
                message = "名單已更新，但無法儲存離線快取。"
            }
            let result = CreditsSnapshot(document: incoming, source: .remote, message: message)
            snapshot = result
            // Retry persistence on the next visit if disk writing failed.
            lastChecked = message == nil ? now : nil
            return result
        } catch {
            guard !Task.isCancelled, generation == requestGeneration,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else {
                throw CancellationError()
            }
            var result = local()
            if let error = error as? URLError,
               [.notConnectedToInternet, .networkConnectionLost].contains(error.code) {
                result.message = "目前離線，尚未確認遠端更新。"
            } else if (error as? URLError)?.code == .timedOut {
                result.message = "更新逾時，請稍後重試。"
            } else if case CreditsError.httpStatus(404) = error {
                result.message = "遠端名單尚未發布，請稍後重試。"
            } else if error is CreditsError || error is DecodingError {
                result.message = "遠端資料無法使用，請稍後重試。"
            } else {
                result.message = "暫時無法更新，請稍後重試。"
            }
            snapshot = result
            return result
        }
    }

    private static func download() async throws -> Data {
        guard let url = URL(string: "https://raw.githubusercontent.com/qian403/NIU-app/main/app-content/credits.json") else {
            throw CreditsError.invalidDocument
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw CreditsError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}
