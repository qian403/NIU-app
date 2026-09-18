import Foundation
import UIKit

enum LibraryCodeKind: String, CaseIterable, Identifiable {
    case entrance
    case borrowing

    var id: Self { self }
    var title: String { self == .entrance ? "門禁 QR Code" : "借書條碼" }
}

/// Mirrors the student portal's LibraryService. Codes stay in memory and are
/// requested only for the signed-in AppState user; no GUID or password is needed.
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
            let response = try await post("Number/", body: ["role": "student", "acnt": account])
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
            data = try await post("Create/Barcode", body: ["ou": "student", "acnt": account])
        }

        try Task.checkCancellation()
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw LibraryCodeError.invalidResponse
        }
        return image
    }

    private func post(_ path: String, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw LibraryCodeError.unavailable
        }
        return data
    }
}

enum LibraryCodeError: LocalizedError {
    case missingAccount
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .missingAccount: return "請先登入，再開啟圖書館通行碼。"
        case .invalidResponse: return "學校暫時未提供有效圖碼，請稍後重新整理。"
        case .unavailable: return "目前無法取得圖書館通行碼，請稍後再試。"
        }
    }
}
