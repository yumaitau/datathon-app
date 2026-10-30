import Foundation
import Observation

enum APIError: LocalizedError, Equatable {
    case offline
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case server(Int, String)
    case decoding(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .offline: String(localized: "You're offline. Try again when you have coverage.")
        case .unauthorized: String(localized: "Your sign-in has expired. Please sign in again.")
        case .forbidden(let m): m.isEmpty ? String(localized: "You don't have permission to do that.") : m
        case .notFound(let m): m.isEmpty ? String(localized: "Not found.") : m
        case .server(_, let m): m.isEmpty ? String(localized: "Something went wrong. Please try again.") : m
        case .decoding(let m): String(localized: "Unexpected response from server.") + " (\(m))"
        case .invalidURL: String(localized: "The server address in Settings is not valid.")
        }
    }

    var isOffline: Bool { self == .offline }
}

struct NetworkLogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let method: String
    let path: String
    let status: Int?
    let bytesSent: Int
    let bytesReceived: Int
    let payloadBytes: Int?
    let compressedBytes: Int?
    let lite: Bool
    let durationMs: Int
    let error: String?

    var isSync: Bool { path.hasPrefix("/api/sync") }
}

@Observable
final class NetworkLog {
    private(set) var entries: [NetworkLogEntry] = []

    func record(_ entry: NetworkLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }

    func clear() { entries.removeAll() }
}

/// HTTP client for the MyMob API.
///
/// Two sessions: `session` never uses ultra-constrained (satellite) paths, so images,
/// feeds and everything else stay off the satellite link. `liteSession` opts in and is
/// used only for the batched `/api/sync/lite` request.
final class APIClient {
    var baseURL: () -> String
    var tokenProvider: () -> String?
    var forceOffline: () -> Bool
    var onUnauthorized: () -> Void = {}
    let log: NetworkLog

    private let session: URLSession
    private let liteSession: URLSession

    init(log: NetworkLog,
         baseURL: @escaping () -> String,
         tokenProvider: @escaping () -> String?,
         forceOffline: @escaping () -> Bool) {
        self.log = log
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.forceOffline = forceOffline

        let standard = URLSessionConfiguration.default
        standard.allowsUltraConstrainedNetworkAccess = false
        standard.timeoutIntervalForRequest = 20
        standard.waitsForConnectivity = false
        session = URLSession(configuration: standard)

        let lite = URLSessionConfiguration.ephemeral
        lite.allowsUltraConstrainedNetworkAccess = true
        lite.timeoutIntervalForRequest = 30
        lite.waitsForConnectivity = false
        lite.httpAdditionalHeaders = ["Accept-Encoding": "gzip"]
        lite.urlCache = nil
        liteSession = URLSession(configuration: lite)
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send("GET", path, body: Optional<OKResponse>.none)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, _ body: B) async throws -> T {
        try await send("POST", path, body: body)
    }

    func post<T: Decodable>(_ path: String) async throws -> T {
        try await send("POST", path, body: [String: String]())
    }

    func delete<T: Decodable>(_ path: String) async throws -> T {
        try await send("DELETE", path, body: Optional<OKResponse>.none)
    }

    func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B?, lite: Bool = false) async throws -> T {
        if forceOffline() { throw APIError.offline }
        let trimmed = baseURL().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) + path : trimmed + path) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Belt and braces: per-request flag mirrors the session it travels on.
        request.allowsUltraConstrainedNetworkAccess = lite
        if let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var sent = 0
        if let body {
            let data = try JSONEncoder.api.encode(body)
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            sent = data.count
        }

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (lite ? liteSession : session).data(for: request)
        } catch {
            let mapped = Self.map(error)
            log.record(NetworkLogEntry(date: started, method: method, path: path, status: nil, bytesSent: sent,
                                       bytesReceived: 0, payloadBytes: nil, compressedBytes: nil, lite: lite,
                                       durationMs: Int(Date().timeIntervalSince(started) * 1000),
                                       error: mapped.localizedDescription))
            throw mapped
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        log.record(NetworkLogEntry(
            date: started, method: method, path: path, status: status, bytesSent: sent,
            bytesReceived: data.count,
            payloadBytes: (http?.value(forHTTPHeaderField: "X-Payload-Bytes")).flatMap { Int($0) },
            compressedBytes: (http?.value(forHTTPHeaderField: "X-Compressed-Bytes")).flatMap { Int($0) },
            lite: lite, durationMs: Int(Date().timeIntervalSince(started) * 1000), error: nil))

        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            switch status {
            case 401:
                if !path.hasPrefix("/api/auth") { onUnauthorized() }
                throw APIError.unauthorized
            case 403: throw APIError.forbidden(message)
            case 404: throw APIError.notFound(message)
            default: throw APIError.server(status, message)
            }
        }
        do {
            return try JSONDecoder.api.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error).prefix(200).description)
        }
    }

    static func map(_ error: Error) -> APIError {
        if let api = error as? APIError { return api }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .timedOut, .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed, .secureConnectionFailed:
                return .offline
            default:
                return .server(-1, url.localizedDescription)
            }
        }
        return .server(-1, error.localizedDescription)
    }
}

extension APIClient: SyncTransport {
    func fullSync(_ request: SyncRequest) async throws -> SyncResponse {
        try await send("POST", "/api/sync", body: request)
    }

    func liteSync(_ request: SyncRequest) async throws -> LiteSyncResponse {
        try await send("POST", "/api/sync/lite", body: request, lite: true)
    }
}
