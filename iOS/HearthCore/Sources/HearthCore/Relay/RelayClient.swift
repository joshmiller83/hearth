import Foundation
import HearthKit

/// What the app asks of the relay.
public protocol RelayAPI: Sendable {
    func health() async throws -> HealthResponse
    func events(from: Date, to: Date, refresh: Bool) async throws -> EventsResponse
    func submit(_ actions: [ApprovedAction]) async throws -> [ActionStatus]
    func statuses(ids: [String]) async throws -> [ActionStatus]
    func cancel(id: String) async throws -> ActionStatus
    func uploadContext(_ context: PhoneContext) async throws
}

public enum RelayError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConfigured
    case unauthorized
    case http(status: Int, reason: String)
    case offline(String)
    case badReply(String)

    public var description: String {
        switch self {
        case .notConfigured: "Add the relay's address and key in Sources."
        case .unauthorized: "The relay didn't accept the key. Check it in Sources."
        case .http(_, let reason): reason
        case .offline(let detail): "Can't reach the relay (\(detail))."
        case .badReply(let detail): "The relay's answer didn't make sense (\(detail))."
        }
    }
}

/// `RelayAPI` over HTTPS with the relay key.
public struct RelayClient: RelayAPI {
    public let credentials: RelayCredentials
    public let transport: any HTTPTransport

    public init(credentials: RelayCredentials, transport: any HTTPTransport) {
        self.credentials = credentials
        self.transport = transport
    }

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var parts = URLComponents(url: credentials.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return parts.url!
    }

    func call<T: Decodable>(_ method: String, _ url: URL, body: Data? = nil, timeout: TimeInterval = 30, as type: T.Type) async throws -> T
    {
        let data = try await raw(method, url, body: body, timeout: timeout)
        do {
            return try HearthJSON.decode(T.self, from: data)
        } catch {
            throw RelayError.badReply(String(describing: error))
        }
    }

    func raw(_ method: String, _ url: URL, body: Data? = nil, timeout: TimeInterval = 30) async throws -> Data {
        var headers = ["authorization": "Bearer \(credentials.key)", "accept": "application/json"]
        if body != nil { headers["content-type"] = "application/json" }
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(url: url, method: method, headers: headers, body: body, timeout: timeout))
        } catch {
            throw RelayError.offline((error as? URLError)?.localizedDescription ?? String(describing: error))
        }
        switch response.status {
        case 200..<300:
            return response.body
        case 401:
            throw RelayError.unauthorized
        default:
            let reason =
                (try? HearthJSON.decode(APIErrorBody.self, from: response.body))?.reason ?? "The relay answered \(response.status)."
            throw RelayError.http(status: response.status, reason: reason)
        }
    }

    public func health() async throws -> HealthResponse {
        try await call("GET", url(RelayPath.health), as: HealthResponse.self)
    }

    public func events(from: Date, to: Date, refresh: Bool) async throws -> EventsResponse {
        var query = ["from": RFC3339.format(from), "to": RFC3339.format(to)]
        if refresh { query["refresh"] = "1" }
        // A forced sweep reads every calendar on every account; give it time.
        return try await call("GET", url(RelayPath.calendarEvents, query: query), timeout: refresh ? 120 : 30, as: EventsResponse.self)
    }

    public func submit(_ actions: [ApprovedAction]) async throws -> [ActionStatus] {
        let body = try HearthJSON.encode(ActionBatch(actions: actions))
        return try await call("POST", url(RelayPath.actions), body: body, timeout: 120, as: ActionStatuses.self).actions
    }

    public func statuses(ids: [String]) async throws -> [ActionStatus] {
        try await call("GET", url(RelayPath.actions, query: ["ids": ids.joined(separator: ",")]), as: ActionStatuses.self).actions
    }

    public func cancel(id: String) async throws -> ActionStatus {
        try await call("DELETE", url(RelayPath.actions + "/" + id), as: CancelResponse.self).action
    }

    public func uploadContext(_ context: PhoneContext) async throws {
        _ = try await raw("POST", url(RelayPath.context), body: try HearthJSON.encode(context))
    }
}
