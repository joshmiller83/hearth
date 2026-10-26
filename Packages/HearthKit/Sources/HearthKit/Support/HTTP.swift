import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A request in transport-neutral form. The app sends these with URLSession; the
/// relay sends them with Vapor's HTTP client, so HearthKit never touches the network itself.
public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 60) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A header, matched without regard to case.
    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

/// A streamed response: its status and headers, then the body one line at a time.
public struct HTTPLineStream: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var lines: AsyncThrowingStream<String, any Error>

    public init(status: Int, headers: [String: String] = [:], lines: AsyncThrowingStream<String, any Error>) {
        self.status = status
        self.headers = headers
        self.lines = lines
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func streamLines(_ request: HTTPRequest) async throws -> HTTPLineStream
}

public struct TransportError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

#if !canImport(FoundationNetworking)
/// URLSession on Apple platforms. (Linux's URLSession can't stream, so the relay
/// brings its own transport.)
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    func urlRequest(_ request: HTTPRequest) -> URLRequest {
        var r = URLRequest(url: request.url, timeoutInterval: request.timeout)
        r.httpMethod = request.method
        for (name, value) in request.headers { r.setValue(value, forHTTPHeaderField: name) }
        r.httpBody = request.body
        return r
    }

    static func headers(_ response: URLResponse) -> (Int, [String: String]) {
        guard let http = response as? HTTPURLResponse else { return (0, [:]) }
        var out: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { out[k] = v }
        }
        return (http.statusCode, out)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: urlRequest(request))
        let (status, headers) = Self.headers(response)
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    public func streamLines(_ request: HTTPRequest) async throws -> HTTPLineStream {
        let (bytes, response) = try await session.bytes(for: urlRequest(request))
        let (status, headers) = Self.headers(response)
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPLineStream(status: status, headers: headers, lines: lines)
    }
}
#endif
