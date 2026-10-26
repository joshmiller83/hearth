import Foundation
import HearthKit
import NIOHTTP1
import Testing
import Vapor
import VaporTesting

@testable import App

/// A response with its body still raw, plus helpers to decode it with HearthJSON.
struct TestResponse {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let body: ByteBuffer

    var text: String { String(buffer: body) }

    func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try HearthJSON.decode(T.self, from: Data(buffer: body))
    }

    var errorReason: String? { (try? decode(APIErrorBody.self))?.reason }
}

/// Sends requests to the in-memory relay the way the phone would.
struct TestClient {
    let app: Application

    func send(
        _ method: HTTPMethod, _ path: String, key: String? = nil, headers: HTTPHeaders = [:],
        rawBody: ByteBuffer? = nil
    ) async throws -> TestResponse {
        var headers = headers
        if let key { headers.bearerAuthorization = BearerAuthorization(token: key) }
        let res = try await app.testing().sendRequest(method, path, headers: headers, body: rawBody)
        return TestResponse(status: res.status, headers: res.headers, body: res.body)
    }

    func send(_ method: HTTPMethod, _ path: String, key: String? = nil, json: some Encodable) async throws -> TestResponse {
        var headers = HTTPHeaders()
        headers.contentType = .json
        return try await send(method, path, key: key, headers: headers, rawBody: ByteBuffer(data: try HearthJSON.encode(json)))
    }
}

extension Application {
    var client2: TestClient { TestClient(app: self) }
}
