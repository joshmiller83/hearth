import Crypto
import Foundation
import HearthKit
import Vapor

/// Secrets the relay hands out. Only their SHA-256 is stored.
enum Codes {
    /// A relay key: 32 random bytes, base64url without padding, with a prefix that
    /// says what it is when it turns up in a password manager.
    static func relayKey() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        let text = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "hrk_" + text
    }

    static func sha256Hex(_ s: String) -> String {
        let digits = Array("0123456789abcdef")
        return String(SHA256.hash(data: Data(s.utf8)).flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] })
    }
}

/// Turns every error into `APIErrorBody`. Errors the relay meant to raise keep
/// their status and sentence; anything else becomes a plain 500 so internals
/// never reach the client.
struct APIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            return Self.response(for: error, request: request)
        }
    }

    static func response(for error: any Error, request: Request) -> Response {
        let status: HTTPResponseStatus
        let reason: String
        var headers = HTTPHeaders()
        switch error {
        case let abort as any AbortError where abort.status.code < 500:
            status = abort.status
            reason = abort.reason
            headers = abort.headers
        case let abort as any AbortError:
            status = abort.status
            reason =
                abort.status == .serviceUnavailable || abort.status == .badGateway ? abort.reason : "Something went wrong on the relay."
            request.logger.report(error: abort)
        default:
            status = .internalServerError
            reason = "Something went wrong on the relay."
            request.logger.error("Unhandled error: \(String(reflecting: error))")
        }
        headers.contentType = .json
        let body = (try? HearthJSON.encode(APIErrorBody(reason: reason))) ?? Data()
        return Response(status: status, headers: headers, body: .init(data: body))
    }
}

extension Response {
    /// A JSON answer written with HearthJSON.
    static func json(_ value: some Encodable, status: HTTPResponseStatus = .ok) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: status, headers: headers, body: .init(data: try HearthJSON.encode(value)))
    }
}

extension Request {
    /// Decodes the body with HearthJSON, answering 400 with a plain sentence when it can't.
    func decodeJSON<T: Decodable>(_ type: T.Type) throws -> T {
        guard let buffer = body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "The request needs a JSON body.")
        }
        do {
            return try HearthJSON.decode(T.self, from: Data(buffer: buffer))
        } catch let error as DecodingError {
            throw Abort(.badRequest, reason: "The request body wasn't understood (\(error.shortDescription)).")
        }
    }

    /// An RFC 3339 query value; 400 when it's there but unreadable.
    func queryDate(_ name: String) throws -> Date? {
        guard let raw = query[String.self, at: name], !raw.isEmpty else { return nil }
        guard let date = RFC3339.date(raw) else { throw Abort(.badRequest, reason: "\(name) has to be an RFC 3339 date.") }
        return date
    }
}

extension DecodingError {
    var shortDescription: String {
        func path(_ ctx: Context) -> String {
            let p = ctx.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "body" : p
        }
        switch self {
        case .keyNotFound(let key, let ctx):
            let p = path(ctx)
            return "missing \(p == "body" ? key.stringValue : "\(p).\(key.stringValue)")"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            return "wrong type at \(path(ctx))"
        case .dataCorrupted(let ctx):
            return "bad value at \(path(ctx))"
        @unknown default:
            return "unreadable"
        }
    }
}
