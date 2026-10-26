import Foundation
import HearthKit

/// An `HTTPTransport` that answers from a script and remembers what it was sent,
/// for testing the Claude client and the relay client without a network.
public final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    public enum Reply: Sendable {
        case response(HTTPResponse)
        /// A streamed reply: its status and its lines.
        case stream(status: Int, lines: [String])
        /// The connection fails.
        case failure(String)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var sent: [HTTPRequest] = []

    public init(_ replies: [Reply]) {
        self.replies = replies
    }

    public var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    /// The JSON bodies sent, parsed.
    public var bodies: [JSONValue] {
        requests.compactMap { $0.body.flatMap { try? JSONValue.parse($0) } }
    }

    private func next(_ request: HTTPRequest) throws -> Reply {
        lock.lock()
        defer { lock.unlock() }
        sent.append(request)
        guard !replies.isEmpty else { throw TransportError("ScriptedTransport ran out of replies") }
        return replies.removeFirst()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch try next(request) {
        case .response(let response): return response
        case .stream(let status, let lines): return HTTPResponse(status: status, body: Data(lines.joined(separator: "\n").utf8))
        case .failure(let message): throw TransportError(message)
        }
    }

    public func streamLines(_ request: HTTPRequest) async throws -> HTTPLineStream {
        let reply = try next(request)
        let (status, lines): (Int, [String])
        switch reply {
        case .stream(let s, let l): (status, lines) = (s, l)
        case .response(let response):
            (status, lines) = (response.status, String(decoding: response.body, as: UTF8.self).components(separatedBy: "\n"))
        case .failure(let message): throw TransportError(message)
        }
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return HTTPLineStream(status: status, lines: stream)
    }

    // MARK: Building replies

    public static func json(_ status: Int = 200, _ text: String) -> Reply {
        .response(HTTPResponse(status: status, headers: ["content-type": "application/json"], body: Data(text.utf8)))
    }

    /// A non-streamed Messages reply with one text block.
    public static func message(text: String, stopReason: String = "end_turn", model: String = "claude-opus-5-5") -> Reply {
        let body: JSONValue = [
            "id": "msg_test", "type": "message", "role": "assistant", "model": .string(model),
            "content": [["type": "text", "text": .string(text)]],
            "stop_reason": .string(stopReason), "stop_details": nil,
            "usage": ["input_tokens": 120, "output_tokens": 40],
        ]
        return json(200, body.serialized())
    }

    /// A streamed reply made of SSE lines for the given blocks.
    public static func streamed(_ blocks: [JSONValue], stopReason: String, model: String = "claude-opus-5-5") -> Reply {
        var lines: [String] = []
        func event(_ name: String, _ data: JSONValue) {
            lines.append("event: \(name)")
            lines.append("data: \(data.serialized())")
            lines.append("")
        }
        event(
            "message_start",
            [
                "type": "message_start",
                "message": [
                    "id": "msg_stream", "type": "message", "role": "assistant", "model": .string(model), "content": [],
                    "stop_reason": nil, "usage": ["input_tokens": 200, "output_tokens": 1, "cache_read_input_tokens": 150],
                ],
            ])
        for (index, block) in blocks.enumerated() {
            let i = JSONValue.int(index)
            switch block["type"]?.stringValue {
            case "text":
                event("content_block_start", ["type": "content_block_start", "index": i, "content_block": ["type": "text", "text": ""]])
                let text = block["text"]?.stringValue ?? ""
                let half = text.index(text.startIndex, offsetBy: text.count / 2)
                for piece in [String(text[..<half]), String(text[half...])] where !piece.isEmpty {
                    event(
                        "content_block_delta",
                        ["type": "content_block_delta", "index": i, "delta": ["type": "text_delta", "text": .string(piece)]])
                }
            case "thinking":
                event(
                    "content_block_start",
                    ["type": "content_block_start", "index": i, "content_block": ["type": "thinking", "thinking": ""]])
                event(
                    "content_block_delta",
                    ["type": "content_block_delta", "index": i, "delta": ["type": "thinking_delta", "thinking": block["thinking"] ?? ""]])
                event(
                    "content_block_delta",
                    [
                        "type": "content_block_delta", "index": i,
                        "delta": ["type": "signature_delta", "signature": block["signature"] ?? ""],
                    ])
            case "tool_use":
                event(
                    "content_block_start",
                    [
                        "type": "content_block_start", "index": i,
                        "content_block": [
                            "type": "tool_use", "id": block["id"] ?? "", "name": block["name"] ?? "", "input": [:],
                        ],
                    ])
                let input = (block["input"] ?? [:]).serialized()
                let cut = input.index(input.startIndex, offsetBy: input.count / 2)
                for piece in [String(input[..<cut]), String(input[cut...])] {
                    event(
                        "content_block_delta",
                        ["type": "content_block_delta", "index": i, "delta": ["type": "input_json_delta", "partial_json": .string(piece)]])
                }
            default:
                event("content_block_start", ["type": "content_block_start", "index": i, "content_block": block])
            }
            event("content_block_stop", ["type": "content_block_stop", "index": i])
        }
        event(
            "message_delta",
            [
                "type": "message_delta", "delta": ["stop_reason": .string(stopReason), "stop_sequence": nil],
                "usage": ["output_tokens": 87],
            ])
        event("message_stop", ["type": "message_stop"])
        return .stream(status: 200, lines: lines)
    }
}
