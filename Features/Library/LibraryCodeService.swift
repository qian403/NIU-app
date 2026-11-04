import Foundation
import UIKit

enum LibraryCodeKind: String, CaseIterable, Identifiable {
    case entrance
    case borrowing

    var id: Self { self }
    var title: String { self == .entrance ? "門禁 QR Code" : "借書條碼" }
}

/// Mirrors the student portal's LibraryService. Codes stay in memory and are
/// requested only for the signed-in AppState user. The school's QRCode API
/// requires the same ccsys1 SSO bearer token the portal sends; the token is
/// used only when it belongs to that user and is never logged.
@MainActor
final class LibraryCodeService {
    private let session: URLSession
    private let baseURL = URL(string: "https://sso.niu.edu.tw/QRCode/")!

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration)
    }

    func image(for kind: LibraryCodeKind, account: String) async throws -> UIImage {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !account.isEmpty else { throw LibraryCodeError.missingAccount }

        let data: Data
        switch kind {
        case .entrance:
            let response = try await post("Number/", body: ["role": "student", "acnt": account], account: account)
            struct NumberResponse: Decodable { let no: String }
            guard let number = try? JSONDecoder().decode(NumberResponse.self, from: response),
                  !number.no.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LibraryCodeError.invalidResponse
            }
            let validationURL = baseURL.appendingPathComponent("Validate").appendingPathComponent(number.no)
            var components = URLComponents(url: baseURL.appendingPathComponent("Create"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "u", value: validationURL.absoluteString)]
            guard let imageURL = components.url else { throw LibraryCodeError.invalidResponse }
            data = try await send(URLRequest(url: imageURL))
        case .borrowing:
            data = try await post("Create/Barcode", body: ["ou": "student", "acnt": account], account: account)
        }

        try Task.checkCancellation()
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw LibraryCodeError.invalidResponse
        }
        return image
    }

    /// Like the app's other SSO features, a missing or rejected token triggers
    /// one background re-login with the saved credentials before giving up.
    private func post(_ path: String, body: [String: String], account: String) async throws -> Data {
        do {
            return try await authorizedPost(path, body: body, account: account)
        } catch LibraryCodeError.loginRequired {
            try Task.checkCancellation()
            print("[LibraryCode] SSO 登入失效，背景更新登入")
            guard await SSOSessionService.shared.requestRefresh(force: true) else {
                throw LibraryCodeError.loginRequired
            }
            try Task.checkCancellation()
            return try await authorizedPost(path, body: body, account: account)
        }
    }

    private func authorizedPost(_ path: String, body: [String: String], account: String) async throws -> Data {
        let renewer = SSOTokenRenewer.shared
        for attempt in 0..<2 {
            let generation = renewer.sessionGeneration
            if attempt == 0 {
                _ = await renewer.renewIfNeeded()
            } else if !(await renewer.renew()) {
                try Task.checkCancellation()
                // A rejected renewal clears the stored token; anything else is transient.
                throw SSOTokenStore.shared.token == nil ? LibraryCodeError.loginRequired : LibraryCodeError.unavailable
            }
            try Task.checkCancellation()
            // Login or logout replaced the session while renewing.
            guard renewer.sessionGeneration == generation else { throw CancellationError() }
            // Never pair another account's token with this account's code request.
            guard let token = SSOTokenStore.shared.token,
                  SSOTokenStore.shared.account?.lowercased() == account else {
                print("[LibraryCode] 無可用的 SSO token（未儲存或帳號不符）")
                throw LibraryCodeError.loginRequired
            }

            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Header parity with the portal page that calls this API.
            request.setValue("https://ccsys1.niu.edu.tw", forHTTPHeaderField: "Origin")
            request.setValue("https://ccsys1.niu.edu.tw/", forHTTPHeaderField: "Referer")
            request.httpBody = try JSONEncoder().encode(body)

            let (data, status) = try await perform(request)
            // Path and status only; never the token, account or response body.
            print("[LibraryCode] POST \(path) attempt=\(attempt) status=\(status)")
            // A rejected token is renewed once; a second rejection needs a new login.
            if status == 401 || status == 403 {
                if attempt == 0 { continue }
                throw LibraryCodeError.loginRequired
            }
            guard (200..<300).contains(status) else { throw LibraryCodeError.unavailable }
            return data
        }
        throw LibraryCodeError.loginRequired
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, status) = try await perform(request)
        guard (200..<300).contains(status) else { throw LibraryCodeError.unavailable }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Error descriptions can contain the request URL; log the code only.
            print("[LibraryCode] \(request.url?.path ?? "") 連線失敗 code=\((error as NSError).code)")
            throw error
        }
        try Task.checkCancellation()
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }
}

enum LibraryCodeError: LocalizedError {
    case missingAccount
    case invalidResponse
    case unavailable
    case loginRequired

    var errorDescription: String? {
        switch self {
        case .missingAccount: return "請先登入，再開啟圖書館通行碼。"
        case .invalidResponse: return "學校暫時未提供有效圖碼，請稍後重新整理。"
        case .unavailable: return "目前無法取得圖書館通行碼，請稍後再試。"
        case .loginRequired: return "登入狀態已過期，請重新登入後再開啟圖書館通行碼。"
        }
    }
}
