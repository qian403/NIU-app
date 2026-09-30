import Foundation

nonisolated protocol CampusMailServing: Sendable {
    func challenge() async throws -> CampusMailLoginChallenge
    func login(account: String, password: String, captcha: String) async throws
    func webCookies() async throws -> [HTTPCookie]
    func completeTwoFactor(account: String, token: String) async throws
    func invalidate()
}

nonisolated final class CampusMailRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // API redirects are not authentication success; never forward credentials to another URL.
        completionHandler(nil)
    }
}

nonisolated final class CampusMailService: CampusMailServing {
    private let session: URLSession
    private let csrf: String
    private let cookies: HTTPCookieStorage?

    init(configuration: URLSessionConfiguration = .ephemeral) {
        csrf = UUID().uuidString
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 40
        configuration.httpCookieAcceptPolicy = .always
        cookies = configuration.httpCookieStorage
        if let cookie = HTTPCookie(properties: [
            .domain: "mail.niu.edu.tw", .path: "/", .name: "XSRF-TOKEN",
            .value: csrf, .secure: "TRUE"
        ]) {
            cookies?.setCookie(cookie)
        }
        session = URLSession(configuration: configuration, delegate: CampusMailRedirectPolicy(), delegateQueue: nil)
    }

    func invalidate() {
        session.invalidateAndCancel()
        cookies?.removeCookies(since: .distantPast)
    }

    deinit { session.invalidateAndCancel() }

    func webCookies() async throws -> [HTTPCookie] {
        try Task.checkCancellation()
        // Narrow school cookies to the Mail host when importing into WebKit.
        return (cookies?.cookies ?? []).compactMap { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard domain == "mail.niu.edu.tw" || domain == "niu.edu.tw",
                  cookie.expiresDate.map({ $0 > Date() }) ?? true,
                  var properties = cookie.properties else { return nil }
            properties[.domain] = "mail.niu.edu.tw"
            properties[.secure] = "TRUE"
            return HTTPCookie(properties: properties)
        }
    }

    func challenge() async throws -> CampusMailLoginChallenge {
        struct Config: Decodable { let LOGIN_NEED_VERIFICATION_CODE: Bool }
        let data = try await request(path: "/api/config/NUMail")
        let config: Config = try decode(data)
        guard config.LOGIN_NEED_VERIFICATION_CODE else {
            return CampusMailLoginChallenge(requiresCaptcha: false, svg: nil)
        }
        let image = try await request(path: "/api/auth/captcha", acceptsSVG: true)
        guard image.count <= 256_000, let svg = String(data: image, encoding: .utf8),
              svg.contains("<svg"), svg.contains("</svg>") else { throw CampusMailError.invalidResponse }
        return CampusMailLoginChallenge(requiresCaptcha: true, svg: svg)
    }

    func login(account: String, password: String, captcha: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "username": account.lowercased(), "password": Data(password.utf8).base64EncodedString(),
            "captcha": captcha
        ])
        _ = try await request(path: "/api/auth/login", body: data, isLogin: true)
        try await verifyIdentity(account: account)
    }

    func completeTwoFactor(account: String, token: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["token": token])
        do {
            _ = try await request(path: "/api/auth/2FA/validate", body: data, isLogin: true)
        } catch CampusMailError.invalidCredentials {
            throw CampusMailError.invalidTwoFactor
        } catch CampusMailError.invalidCaptcha {
            throw CampusMailError.invalidTwoFactor
        }
        try await verifyIdentity(account: account)
    }

    private func verifyIdentity(account: String) async throws {
        // A successful POST alone does not prove a complete login (e.g. 2FA/password change).
        struct Identity: Decodable { let username: String }
        let identity: Identity = try decode(await request(path: "/api/auth/user"))
        guard identity.username.caseInsensitiveCompare(account) == .orderedSame else {
            throw CampusMailError.accountMismatch
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CampusMailError.invalidResponse }
    }

    private func request(path: String, body: Data? = nil,
                         acceptsSVG: Bool = false, isLogin: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "mail.niu.edu.tw"
        components.path = path
        guard let url = components.url else { throw CampusMailError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("https://mail.niu.edu.tw", forHTTPHeaderField: "Origin")
        request.setValue("https://mail.niu.edu.tw/NUMail/Login", forHTTPHeaderField: "Referer")
        let currentCSRF = cookies?.cookies(for: url)?.first(where: { $0.name == "XSRF-TOKEN" })?.value ?? csrf
        request.setValue(currentCSRF, forHTTPHeaderField: "X-XSRF-TOKEN")
        request.setValue(acceptsSVG ? "image/svg+xml" : "application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw CampusMailError.invalidResponse }
        if !(200..<300).contains(response.statusCode) {
            struct Failure: Decodable {
                struct Detail: Decodable { let message: String? }
                let error: Detail?
                let message: String?
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            let reason = (failure?.error?.message ?? failure?.message ?? "").lowercased()
            if isLogin, reason.contains("validation") || reason.contains("captcha") {
                throw CampusMailError.invalidCaptcha
            }
            if isLogin, reason == "two factor authentication require" {
                throw CampusMailError.twoFactorRequired
            }
            if isLogin, reason == "please change password first" || reason == "ad password expired" {
                throw CampusMailError.additionalVerification
            }
            if isLogin, reason == "unauthorized" { throw CampusMailError.invalidCredentials }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw isLogin ? CampusMailError.invalidCredentials : CampusMailError.sessionExpired
            }
            if (300..<400).contains(response.statusCode) { throw CampusMailError.sessionExpired }
            throw CampusMailError.server(response.statusCode)
        }
        let mime = response.mimeType?.lowercased() ?? ""
        guard acceptsSVG || mime.contains("json") else { throw CampusMailError.invalidResponse }
        guard data.count <= 15_000_000 else { throw CampusMailError.invalidResponse }
        return data
    }
}
