import Foundation

/// Bridges the modern JWT SSO (`ccsys1.niu.edu.tw`) to the legacy domains
/// (`acade.niu.edu.tw`, `ccsys.niu.edu.tw/MvcTeam`) by exchanging the JWT for a
/// one-shot GUID via `GET /SSO/API/GUID/{account}`. The GUID is then appended
/// to the legacy entry URL (typically `Login.aspx?GUID=<guid>`) which causes
/// the legacy site to establish its own ASP.NET session cookies inside the
/// shared `WKWebsiteDataStore`.
enum SSOGUIDBridge {

    /// Fetches a fresh GUID for the given account. Returns `nil` on failure
    /// (no token, network error, non-200 response, malformed payload).
    static func fetchGUID(account: String) async -> String? {
        do { return try await requestGUID(account: account) }
        catch {
            // Error descriptions can contain a credential-bearing URL.
            print("[SSOGUIDBridge] GUID request failed code=\((error as NSError).code)")
            return nil
        }
    }

    /// Throwing variant for callers that distinguish offline/timeout from expired login.
    // Reads the renewer and token store together, so it runs on the main actor.
    @MainActor
    static func requestGUID(account: String) async throws -> String {
        let acnt = account.lowercased()
        // Silent sliding renewal first, so long sessions rarely reach the login page.
        let session = SSOTokenRenewer.shared.sessionGeneration
        _ = await SSOTokenRenewer.shared.renewIfNeeded()
        try Task.checkCancellation()
        // A login or logout during renewal (even of the same account) replaced the
        // session; this request belongs to the old one and must not use or clear it.
        guard SSOTokenRenewer.shared.sessionGeneration == session else { throw URLError(.cancelled) }
        // A rejected renewal cleared the session: log in again. Never pair another
        // account's token with this account's GUID request.
        guard let token = SSOTokenStore.shared.token, SSOTokenStore.shared.account == acnt else {
            throw URLError(.userAuthenticationRequired)
        }
        guard let url = URL(string: "https://ccsys1.niu.edu.tw/SSO/API/GUID/\(acnt)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request, delegate: SchoolServerTrust.delegate)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 {
            SSOTokenStore.shared.clear(ifMatching: token)
            throw URLError(.userAuthenticationRequired)
        }
        guard status == 200 else { throw URLError(.badServerResponse) }
        struct Payload: Decodable { let guid: String? }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let guid = payload.guid?.nilIfEmpty else { throw URLError(.cannotParseResponse) }
        return guid
    }

    /// Builds `https://acade.niu.edu.tw/NIU/Login.aspx?GUID=<guid>`, the
    /// canonical entry point that establishes the legacy acade session before
    /// the caller navigates to a deep page.
    static func acadeLoginURL(guid: String) -> URL? {
        URL(string: "https://acade.niu.edu.tw/NIU/Login.aspx?GUID=\(guid)")
    }
    /// A GUID-bearing Login.aspx can finish before its redirect; it is not yet a failed login.
    static func isSessionExpiredURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        guard ["acade.niu.edu.tw", "ccsys.niu.edu.tw", "ccsys1.niu.edu.tw"].contains(host) else { return false }
        let path = url.path.lowercased()
        if path == "/sso/login", ["ccsys.niu.edu.tw", "ccsys1.niu.edu.tw"].contains(host) { return true }
        if host == "ccsys1.niu.edu.tw", path == "/sso" || path.hasPrefix("/sso/") {
            return true
        }
        return (host == "acade.niu.edu.tw" && path == "/niu/logout.aspx")
            || path.hasSuffix("/timeoutpage.aspx")
            || path.hasSuffix("/default.aspx")
            || (path.hasSuffix("/login.aspx") && !(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name.caseInsensitiveCompare("guid") == .orderedSame && !($0.value ?? "").isEmpty } ?? false))
            || path.hasSuffix("/account/login")
    }


}
