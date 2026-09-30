import Foundation

nonisolated protocol PostalServing: Sendable {
    func search(_ query: PostalQuery) async throws -> PostalPage
    func nextPage(after page: PostalPage) async throws -> PostalPage
    func invalidate()
}

nonisolated final class PostalRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated final class PostalService: PostalServing {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration, delegate: PostalRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }
    func invalidate() { session.invalidateAndCancel() }

    @concurrent
    func search(_ query: PostalQuery) async throws -> PostalPage {
        guard query.canSearch else { throw PostalError.invalidResponse }
        let html = try await request()
        let form = try PostalHTML.form(in: html)
        try Task.checkCancellation()
        let result = try await request(fields: PostalHTML.searchForm(form, query: query.normalized))
        return try PostalHTML.page(result, query: query.normalized)
    }

    @concurrent
    func nextPage(after page: PostalPage) async throws -> PostalPage {
        guard let form = page.nextForm else { throw PostalError.invalidResponse }
        let html = try await request(fields: form)
        let next = try PostalHTML.page(html, query: page.query)
        guard next.pageIndex == page.pageIndex + 1 else { throw PostalError.invalidResponse }
        return next
    }

    private func request(fields: [String: String]? = nil) async throws -> String {
        guard let url = URL(string: "https://ccsys2.niu.edu.tw/GA/Postal/") else { throw PostalError.invalidResponse }
        var request = URLRequest(url: url)
        if let fields {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = PostalHTML.encodeForm(fields)
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw PostalError.invalidResponse }
        if (300..<400).contains(response.statusCode) || [401, 403].contains(response.statusCode) {
            throw PostalError.sessionExpired
        }
        guard response.statusCode == 200 else { throw PostalError.unavailable }
        guard data.count <= 4_000_000, let html = String(data: data, encoding: .utf8) else {
            throw PostalError.invalidResponse
        }
        return html
    }
}
