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
        guard let token = SSOTokenStore.shared.token else {
            print("[SSOGUIDBridge] 無 JWT，無法取得 GUID")
            return nil
        }
        let acnt = account.lowercased()
        guard let url = URL(string: "https://ccsys1.niu.edu.tw/SSO/API/GUID/\(acnt)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                print("[SSOGUIDBridge] /SSO/API/GUID status=\(status)")
                return nil
            }
            struct Payload: Decodable { let guid: String? }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return payload.guid?.nilIfEmpty
        } catch {
            print("[SSOGUIDBridge] /SSO/API/GUID 失敗: \(error.localizedDescription)")
            return nil
        }
    }

    /// Builds `https://acade.niu.edu.tw/NIU/Login.aspx?GUID=<guid>`, the
    /// canonical entry point that establishes the legacy acade session before
    /// the caller navigates to a deep page.
    static func acadeLoginURL(guid: String) -> URL? {
        URL(string: "https://acade.niu.edu.tw/NIU/Login.aspx?GUID=\(guid)")
    }
}
