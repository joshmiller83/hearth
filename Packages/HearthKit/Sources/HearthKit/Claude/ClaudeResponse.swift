import Foundation

public enum StopReason: Sendable, Equatable {
    case endTurn
    case maxTokens
    case stopSequence
    case toolUse
    /// A server tool paused a long turn; send the conversation back to continue it.
    case pauseTurn
    /// A safety classifier declined (and any fallback declined too).
    case refusal
    case contextWindowExceeded
    case other(String)

    public init(_ text: String?) {
        switch text {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "stop_sequence": self = .stopSequence
        case "tool_use": self = .toolUse
        case "pause_turn": self = .pauseTurn
        case "refusal": self = .refusal
        case "model_context_window_exceeded": self = .contextWindowExceeded
        default: self = .other(text ?? "")
        }
    }
}

public struct ClaudeUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    init(json: JSONValue?) {
        inputTokens = json?["input_tokens"]?.intValue ?? 0
        outputTokens = json?["output_tokens"]?.intValue ?? 0
        cacheReadTokens = json?["cache_read_input_tokens"]?.intValue ?? 0
        cacheCreationTokens = json?["cache_creation_input_tokens"]?.intValue ?? 0
    }

    /// Rough dollars at Hearth's models' list prices (per million tokens), for the
    /// eval report and logs. Cache reads bill at a tenth, writes at 1.25×.
    public func dollars(model: ClaudeModel) -> Double {
        let (inPrice, outPrice): (Double, Double) = model == .opus ? (4, 20) : (0.10, 0.50)
        let input = Double(inputTokens) + Double(cacheReadTokens) * 0.1 + Double(cacheCreationTokens) * 1.25
        return (input * inPrice + Double(outputTokens) * outPrice) / 1_000_000
    }
}

/// A complete reply.
public struct ClaudeResponse: Sendable, Equatable {
    public var id: String
    public var model: String
    public var content: [ContentBlock]
    public var stopReason: StopReason
    /// For refusals: `{"category": "cyber" | …}`. Informational.
    public var stopDetails: JSONValue?
    public var usage: ClaudeUsage

    public init(
        id: String, model: String, content: [ContentBlock], stopReason: StopReason, stopDetails: JSONValue? = nil,
        usage: ClaudeUsage = ClaudeUsage()
    ) {
        self.id = id
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.stopDetails = stopDetails
        self.usage = usage
    }

    public init(json: JSONValue) throws {
        guard json["type"]?.stringValue == "message", let blocks = json["content"]?.arrayValue else {
            throw ClaudeError.badOutput("The reply wasn't a message.")
        }
        id = json["id"]?.stringValue ?? ""
        model = json["model"]?.stringValue ?? ""
        content = blocks.compactMap { $0.objectValue.map(ContentBlock.init(json:)) }
        stopReason = StopReason(json["stop_reason"]?.stringValue)
        stopDetails = json["stop_details"]
        usage = ClaudeUsage(json: json["usage"])
    }

    /// Every text block, joined.
    public var text: String { content.compactMap(\.text).joined() }

    public var toolUses: [ToolUse] { content.compactMap(\.toolUse) }

    /// The reply as the assistant turn to append to the history, unchanged.
    public var assistantMessage: ClaudeMessage { ClaudeMessage(role: .assistant, content: content) }

    /// True when a fallback model finished this turn.
    public var servedByFallback: Bool { content.contains { $0.type == "fallback" } }
}

public enum ClaudeError: Error, Equatable, Sendable, CustomStringConvertible {
    case noKey
    /// The API answered with an error: its status, error type and message.
    case http(status: Int, type: String, message: String)
    /// Declined by the safety classifiers (after any fallback).
    case refusal(category: String?)
    /// Ran out of `max_tokens` before finishing structured output.
    case truncated
    case badOutput(String)
    case transport(String)

    public var description: String {
        switch self {
        case .noKey: "Add your Claude API key in Sources."
        case .http(let status, let type, let message):
            switch status {
            case 401: "Claude didn't accept the API key. Check it in Sources."
            case 429: "Claude is rate-limiting this key. Try again in a minute."
            case 529, 503: "Claude is overloaded right now. Try again in a minute."
            default: "Claude answered \(status) (\(type)): \(message)"
            }
        case .refusal: "Claude declined this one. Try rewording it."
        case .truncated: "Claude's answer was cut off. Try something shorter."
        case .badOutput(let detail): "Claude's answer didn't make sense (\(detail))."
        case .transport(let detail): "Couldn't reach Claude: \(detail)"
        }
    }

    /// Worth trying again after a pause.
    public var isRetryable: Bool {
        if case .http(let status, _, _) = self { return [408, 429, 500, 502, 503, 504, 529].contains(status) }
        if case .transport = self { return true }
        return false
    }

    static func from(status: Int, body: Data) -> ClaudeError {
        let json = try? JSONValue.parse(body)
        let type = json?["error"]?["type"]?.stringValue ?? "error"
        let message = json?["error"]?["message"]?.stringValue ?? String(decoding: body.prefix(300), as: UTF8.self)
        return .http(status: status, type: type, message: message)
    }
}
