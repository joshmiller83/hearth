import Foundation

/// A Messages API request, built to the rules of the 2026-10-21 API version and
/// the 5.5 models:
///
/// - no `temperature`, `top_p` or `top_k` (any value is a 400 on this version);
/// - no forced `tool_choice` (Opus 5.5 rejects `any`/`tool`): tools are `strict`
///   and JSON comes from `output_config.format` instead;
/// - thinking is always on, so `effort` is always set explicitly;
/// - no assistant prefill: the last message is the user's;
/// - the system prompt (and with it the tools, which come first) is cached;
/// - Opus requests opt into server-side refusal fallbacks (`fallbacks: "default"`).
public struct ClaudeRequest: Sendable {
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public var model: ClaudeModel
    public var maxTokens: Int
    public var system: String?
    public var messages: [ClaudeMessage]
    public var tools: [ClaudeTool]
    public var effort: ClaudeEffort
    /// A JSON schema the reply must match (`output_config.format`).
    public var outputSchema: JSONValue?
    /// Ask for summarized thinking blocks (for the Ask trace).
    public var showThinking: Bool
    public var stream: Bool
    /// Opt into server-side refusal fallbacks. Ignored for models without them.
    public var fallbacks: Bool
    /// Cache the whole conversation prefix too (tool loops resend it every turn).
    public var cacheConversation: Bool

    public init(
        model: ClaudeModel,
        maxTokens: Int = 16_000,
        system: String? = nil,
        messages: [ClaudeMessage],
        tools: [ClaudeTool] = [],
        effort: ClaudeEffort = .medium,
        outputSchema: JSONValue? = nil,
        showThinking: Bool = false,
        stream: Bool = false,
        fallbacks: Bool = true,
        cacheConversation: Bool = false
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.tools = tools
        self.effort = effort
        self.outputSchema = outputSchema
        self.showThinking = showThinking
        self.stream = stream
        self.fallbacks = fallbacks
        self.cacheConversation = cacheConversation
    }

    var usesFallbacks: Bool { fallbacks && model.supportsFallbacks }

    public var body: JSONValue {
        var object: JSONObject = [
            "model": .string(model.rawValue),
            "max_tokens": .int(maxTokens),
        ]
        if let system, !system.isEmpty {
            object["system"] = [["type": "text", "text": .string(system), "cache_control": ["type": "ephemeral"]]]
        }
        object["messages"] = .array(messages.map(\.json))
        if !tools.isEmpty {
            var toolJSON = tools.map { $0.json(eagerInputStreaming: false) }
            if system == nil || system?.isEmpty == true, case .object(var last)? = toolJSON.last {
                last["cache_control"] = ["type": "ephemeral"]
                toolJSON[toolJSON.count - 1] = .object(last)
            }
            object["tools"] = .array(toolJSON)
        }
        var outputConfig: JSONObject = ["effort": .string(effort.rawValue)]
        if let outputSchema {
            outputConfig["format"] = ["type": "json_schema", "schema": outputSchema]
        }
        object["output_config"] = .object(outputConfig)
        if showThinking {
            object["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        if cacheConversation {
            object["cache_control"] = ["type": "ephemeral"]
        }
        if stream { object["stream"] = true }
        if usesFallbacks { object["fallbacks"] = "default" }
        return .object(object)
    }

    public func headers(apiKey: String) -> [String: String] {
        var headers = [
            "x-api-key": apiKey,
            "anthropic-version": Self.apiVersion,
            "content-type": "application/json",
        ]
        if usesFallbacks { headers["anthropic-beta"] = Self.fallbackBeta }
        if stream { headers["accept"] = "text/event-stream" }
        return headers
    }
}
