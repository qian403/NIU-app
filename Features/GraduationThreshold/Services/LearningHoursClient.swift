import Foundation

nonisolated protocol LearningHoursFetching: Sendable {
    func fetch(username: String, password: String) async throws -> LearningHoursSnapshot
}

/// Signs in to the student portal (ep.niu.edu.tw) and reads 多元學習認證 hours.
/// The portal is reachable from the campus network only. Each fetch uses its own
/// ephemeral session so the portal cookie never reaches shared storage.
nonisolated struct LearningHoursClient: LearningHoursFetching {
    static let pageURL = URL(string: "https://ep.niu.edu.tw/search/learning_certification")!
    private static let base = URL(string: "https://ep.niu.edu.tw")!
    private static let maxPages = 30

    @concurrent
    func fetch(username: String, password: String) async throws -> LearningHoursSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        try await login(session: session, username: username, password: password)
        let summaries = try LearningHoursParser.parseSummary(
            try await get(session: session, path: "/Api/MultLearn"))

        var records: [LearningHoursRecord] = []
        var page = 1
        var lastPage = 1
        while page <= lastPage {
            let data = try await get(session: session, path: "/Api/MultLearnDetail", page: page)
            guard let html = String(data: data, encoding: .utf8) else {
                throw LearningHoursError.invalidResponse
            }
            let parsed = try LearningHoursParser.parseDetail(html)
            guard parsed.lastPage <= Self.maxPages else { throw LearningHoursError.tooManyPages }
            if parsed.records.isEmpty { break }
            records += parsed.records
            lastPage = parsed.lastPage
            page += 1
        }
        try Task.checkCancellation()

        return LearningHoursSnapshot(summaries: summaries, records: records, fetchedAt: Date())
    }

    private func login(session: URLSession, username: String, password: String) async throws {
        var request = URLRequest(url: Self.base.appendingPathComponent("login/student"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(Self.base.appendingPathComponent("login").absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = Self.formBody(["student_id": username, "password": password])
        let data = try await send(session: session, request: request)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LearningHoursError.invalidResponse
        }
        let status = (object["status"] as? NSNumber)?.intValue ?? Int(object["status"] as? String ?? "")
        guard status == 1 else { throw LearningHoursError.invalidCredentials }
    }

    private func get(session: URLSession, path: String, page: Int? = nil) async throws -> Data {
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let page { components.queryItems = [URLQueryItem(name: "page", value: String(page))] }
        var request = URLRequest(url: components.url!)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(Self.pageURL.absoluteString, forHTTPHeaderField: "Referer")
        return try await send(session: session, request: request)
    }

    private func send(session: URLSession, request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw LearningHoursError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        // Off-campus requests may be refused by the school's firewall.
        case 401, 403: throw LearningHoursError.campusNetworkRequired
        default: throw LearningHoursError.invalidResponse
        }
    }

    static func map(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled: return CancellationError()
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return LearningHoursError.offline
        default:
            // Timeouts, refused connections and DNS failures are what an
            // off-campus device sees; the portal has no public endpoint.
            return LearningHoursError.campusNetworkRequired
        }
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._*")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(encoded)"
        }.joined(separator: "&").data(using: .utf8)!
    }
}
