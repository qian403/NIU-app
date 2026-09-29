import Foundation

enum ConnectionService: String, CaseIterable, Sendable {
    case academic
    case moodle
    case backend

    var title: String {
        switch self {
        case .academic: "校務系統"
        case .moodle: "M 園區"
        case .backend: "App 後端"
        }
    }
}

enum ConnectionStatus: Equatable, Sendable {
    case unchecked, checking, connected, offline, timedOut, unavailable, notConfigured

    var title: String {
        switch self {
        case .unchecked: "尚未檢查"
        case .checking: "檢查中"
        case .connected: "可連線"
        case .offline: "裝置離線"
        case .timedOut: "連線逾時"
        case .unavailable: "暫無法連線"
        case .notConfigured: "尚未設定"
        }
    }
}

actor ConnectionStatusService {
    private let session: URLSession
    private let backendURL: URL?
    private let checkTimeout: Duration

    init(backendURL: URL?, session: URLSession? = nil, checkTimeout: Duration = .seconds(12)) {
        self.backendURL = backendURL
        self.checkTimeout = checkTimeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            configuration.waitsForConnectivity = false
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func check(_ service: ConnectionService) async throws -> ConnectionStatus {
        try Task.checkCancellation()
        let url: URL?
        switch service {
        case .academic: url = URL(string: "https://ccsys1.niu.edu.tw/SSO/login")
        case .moodle: url = URL(string: "https://euni.niu.edu.tw/login/index.php")
        case .backend: url = backendURL?.appendingPathComponent("v1/usage/heartbeat")
        }
        guard let url else { return .notConfigured }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  response.url?.host == url.host,
                  response.url?.scheme == url.scheme else { return .unavailable }
            if service == .backend {
                let probe = try? JSONDecoder().decode(BackendProbeResponse.self, from: data)
                guard response.statusCode == 405,
                      probe?.error.code == "method_not_allowed" else { return .unavailable }
            } else {
                guard (200...299).contains(response.statusCode) else { return .unavailable }
            }
            return .connected
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            switch (error as? URLError)?.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet: return .offline
            case .timedOut: return .timedOut
            default: return .unavailable
            }
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            defer { group.cancelAll() }
            group.addTask { [session] in
                try await session.data(for: request)
            }
            group.addTask { [checkTimeout] in
                try await Task.sleep(for: checkTimeout)
                throw URLError(.timedOut)
            }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
    }

    private struct BackendProbeResponse: Decodable {
        let error: ProbeError

        struct ProbeError: Decodable {
            let code: String
        }
    }
}
