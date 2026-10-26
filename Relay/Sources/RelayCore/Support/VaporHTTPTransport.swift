import Foundation
import HearthKit
import NIOCore
import Vapor

/// HearthKit's `HTTPTransport` over Vapor's HTTP client, so the relay's Claude
/// calls work on Linux too (Linux's URLSession can't stream).
public struct VaporHTTPTransport: HTTPTransport {
    let client: any Client

    public init(client: any Client) {
        self.client = client
    }

    func clientRequest(_ request: HTTPRequest) -> ClientRequest {
        var headers = HTTPHeaders()
        for (name, value) in request.headers { headers.replaceOrAdd(name: name, value: value) }
        var r = ClientRequest(method: HTTPMethod(rawValue: request.method), url: URI(string: request.url.absoluteString), headers: headers)
        if let body = request.body { r.body = ByteBuffer(data: body) }
        r.timeout = .seconds(Int64(request.timeout))
        return r
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await client.send(clientRequest(request))
        var headers: [String: String] = [:]
        for (name, value) in response.headers { headers[name.lowercased()] = value }
        let body = response.body.map { Data(buffer: $0) } ?? Data()
        return HTTPResponse(status: Int(response.status.code), headers: headers, body: body)
    }

    /// The relay never streams (its Claude calls are short and structured), so a
    /// "stream" here is the whole body split into lines.
    public func streamLines(_ request: HTTPRequest) async throws -> HTTPLineStream {
        let response = try await send(request)
        let lines = String(decoding: response.body, as: UTF8.self).components(separatedBy: "\n")
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return HTTPLineStream(status: response.status, headers: response.headers, lines: stream)
    }
}
