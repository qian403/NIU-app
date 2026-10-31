import Foundation

/// Silent sliding renewal for the SSO bearer token.
///
/// The school's own web client keeps its session alive by calling
/// `POST /SSO/API/Login/refreshToken` with the current bearer token. That call
/// needs no credentials and no Turnstile token, so renewing through it never
/// opens the login page. Renewal never falls back to the login page itself:
/// features re-login on their own when the school actually rejects the token.
@MainActor
final class SSOTokenRenewer {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    static let shared = SSOTokenRenewer()

    private let transport: Transport
    private var inFlight: Task<Bool, Never>?
    private var generation = 0

    init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0, delegate: SchoolServerTrust.delegate) }) {
        self.transport = transport
    }

    /// Renews only when the stored token is close to expiry.
    func renewIfNeeded() async -> Bool {
        guard SSOTokenStore.shared.needsRenewal else { return false }
        return await renew()
    }

    /// Renews the stored token. Returns `true` when a fresh token was saved.
    /// Concurrent callers share one request, so one token is never renewed twice.
    func renew() async -> Bool {
        if let inFlight { return await inFlight.value }
        guard let token = SSOTokenStore.shared.token,
              let account = SSOTokenStore.shared.account else { return false }
        let current = generation
        let task = Task { await perform(token: token, account: account, generation: current) }
        inFlight = task
        let result = await task.value
        if generation == current { inFlight = nil }
        return result
    }

    /// Changes on every login and logout (via `cancel()`), so callers that await
    /// renewal can tell a replaced session from a renewal of the same one.
    var sessionGeneration: Int { generation }

    /// Login and logout replace the session; a late response must not save into it.
    func cancel() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
    }

    private func perform(token: String, account: String, generation: Int) async -> Bool {
        guard let url = URL(string: "https://ccsys1.niu.edu.tw/SSO/API/Login/refreshToken") else {
            return false
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Header parity with the school's browser client.
        request.setValue("https://ccsys1.niu.edu.tw/SSO/login", forHTTPHeaderField: "Referer")
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            print("[SSOTokenRenewer] 續期請求失敗 code=\((error as NSError).code)")
            return false
        }
        // Logout, a new login or a newer renewal replaced the token while this one waited.
        guard !Task.isCancelled, generation == self.generation,
              SSOTokenStore.shared.token == token,
              SSOTokenStore.shared.account == account else { return false }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 {
            print("[SSOTokenRenewer] 校方拒絕續期 status=401")
            SSOTokenStore.shared.clear(ifMatching: token)
            return false
        }
        guard status == 200 else {
            print("[SSOTokenRenewer] 續期失敗 status=\(status)")
            return false
        }
        struct Payload: Decodable {
            let token: String?
            let exp: String?

            private enum CodingKeys: String, CodingKey { case token, exp }

            // `exp` may arrive as epoch seconds or a date string; an unexpected
            // type must not discard a valid token whose JWT already carries `exp`.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                token = try? container.decode(String.self, forKey: .token)
                if let text = try? container.decode(String.self, forKey: .exp) {
                    exp = text
                } else if let seconds = try? container.decode(Double.self, forKey: .exp) {
                    exp = String(seconds)
                } else {
                    exp = nil
                }
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let renewed = payload.token?.nilIfEmpty else {
            print("[SSOTokenRenewer] 續期回應格式不符")
            return false
        }
        let expiration = SSOTokenStore.jwtExpiration(renewed) ?? Self.normalizedExpiration(payload.exp)
        if expiration == nil {
            // Without an expiry, foreground renewal cannot run; a later 401 still triggers login.
            print("[SSOTokenRenewer] 無法解析新 token 的到期時間")
        }
        SSOTokenStore.shared.save(token: renewed, exp: expiration, account: account)
        return SSOTokenStore.shared.token == renewed
    }

    /// The school's web app parses `exp` with `new Date(String(exp))`. Accept
    /// epoch seconds and ISO dates (trimming .NET's long fractional seconds,
    /// which ISO8601DateFormatter rejects). Unreadable values return `nil`.
    static func normalizedExpiration(_ raw: String?) -> String? {
        guard let raw = raw?.nilIfEmpty else { return nil }
        if let seconds = Double(raw), seconds > 1_000_000_000 {
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        }
        let trimmed = raw.replacingOccurrences(of: "(\\.\\d{3})\\d+", with: "$1",
                                               options: .regularExpression)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed) else {
            return nil
        }
        return ISO8601DateFormatter().string(from: date)
    }
}
