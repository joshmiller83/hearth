import Foundation

/// The models Hearth uses. Opus plans, writes and reads photos; Haiku sorts.
public enum ClaudeModel: String, Codable, Sendable, CaseIterable {
    case opus = "claude-opus-5-5"
    case haiku = "claude-haiku-5-5"

    /// Server-side refusal fallbacks exist for Opus 5.5 only; Haiku 5.5 rejects a fallback list.
    public var supportsFallbacks: Bool { self == .opus }
}

/// How hard the model thinks. Both models always think; effort sets how much.
public enum ClaudeEffort: String, Codable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max
}

public enum ClaudeRole: String, Codable, Sendable {
    case user
    case assistant
}

/// One content block, kept as the exact JSON the API sent (or that Hearth built),
/// with typed views on top. Thinking blocks, signatures and block types Hearth
/// doesn't know pass through untouched.
public struct ContentBlock: Sendable, Hashable {
    public var json: JSONObject

    public init(json: JSONObject) {
        self.json = json
    }

    public var type: String { json["type"]?.stringValue ?? "" }

    // MARK: Builders

    public static func text(_ text: String, cache: Bool = false) -> ContentBlock {
        var object: JSONObject = ["type": "text", "text": .string(text)]
        if cache { object["cache_control"] = ["type": "ephemeral"] }
        return ContentBlock(json: object)
    }

    /// A base64 image. `mediaType`: image/jpeg, image/png, image/gif or image/webp.
    public static func image(base64 data: String, mediaType: String) -> ContentBlock {
        ContentBlock(json: [
            "type": "image",
            "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(data)],
        ])
    }

    public static func image(_ data: Data, mediaType: String) -> ContentBlock {
        image(base64: data.base64EncodedString(), mediaType: mediaType)
    }

    public static func toolResult(id: String, text: String, isError: Bool = false) -> ContentBlock {
        var object: JSONObject = ["type": "tool_result", "tool_use_id": .string(id), "content": .string(text)]
        if isError { object["is_error"] = true }
        return ContentBlock(json: object)
    }

    // MARK: Views

    /// The text of a `text` block.
    public var text: String? { type == "text" ? json["text"]?.stringValue : nil }

    /// The summarized reasoning of a `thinking` block, when the request asked to see it.
    public var thinking: String? { type == "thinking" ? json["thinking"]?.stringValue : nil }

    public var toolUse: ToolUse? {
        guard type == "tool_use", let id = json["id"]?.stringValue, let name = json["name"]?.stringValue else { return nil }
        return ToolUse(id: id, name: name, input: json["input"] ?? .object(JSONObject()))
    }

    /// A `fallback` block: the request was declined by one model and continued on another.
    public var fallback: (from: String, to: String)? {
        guard type == "fallback" else { return nil }
        return (json["from"]?["model"]?.stringValue ?? "", json["to"]?["model"]?.stringValue ?? "")
    }
}

/// A tool call the model asked for.
public struct ToolUse: Sendable, Hashable {
    public var id: String
    public var name: String
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// One turn of a conversation.
public struct ClaudeMessage: Sendable, Hashable {
    public var role: ClaudeRole
    public var content: [ContentBlock]

    public init(role: ClaudeRole, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> ClaudeMessage {
        ClaudeMessage(role: .user, content: [.text(text)])
    }

    public static func user(_ blocks: [ContentBlock]) -> ClaudeMessage {
        ClaudeMessage(role: .user, content: blocks)
    }

    public var json: JSONValue {
        ["role": .string(role.rawValue), "content": .array(content.map { .object($0.json) })]
    }

    /// The text blocks joined.
    public var text: String {
        content.compactMap(\.text).joined()
    }
}

/// A tool Claude may call: a name, what it's for, and its input's JSON schema.
/// Or one of Anthropic's server tools (web search, web fetch), which Claude runs
/// itself: those have a type instead, and never reach the toolbox.
public struct ClaudeTool: Sendable, Hashable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// Guarantees schema-valid input (and needs `additionalProperties: false` on every object).
    public var strict: Bool
    /// A server tool's versioned type, "web_search_20260209".
    public var serverType: String?
    /// For server tools: how many calls a request may make.
    public var maxUses: Int?

    public init(name: String, description: String, inputSchema: JSONValue, strict: Bool = true) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
    }

    /// Searching the web, run by Anthropic.
    public static func webSearch(maxUses: Int = 5) -> ClaudeTool {
        var tool = ClaudeTool(name: "web_search", description: "", inputSchema: .null, strict: false)
        tool.serverType = "web_search_20260209"
        tool.maxUses = maxUses
        return tool
    }

    /// Reading a web page, run by Anthropic.
    public static func webFetch(maxUses: Int = 5) -> ClaudeTool {
        var tool = ClaudeTool(name: "web_fetch", description: "", inputSchema: .null, strict: false)
        tool.serverType = "web_fetch_20260209"
        tool.maxUses = maxUses
        return tool
    }

    func json(eagerInputStreaming: Bool) -> JSONValue {
        if let serverType {
            var object: JSONObject = ["type": .string(serverType), "name": .string(name)]
            if let maxUses { object["max_uses"] = .int(maxUses) }
            return .object(object)
        }
        var object: JSONObject = [
            "name": .string(name),
            "description": .string(description),
            "input_schema": inputSchema,
        ]
        if strict { object["strict"] = true }
        if eagerInputStreaming { object["eager_input_streaming"] = true }
        return .object(object)
    }
}
