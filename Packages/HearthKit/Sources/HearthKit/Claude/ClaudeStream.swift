import Foundation

/// What a streaming reply produces as it arrives.
public enum ClaudeStreamUpdate: Sendable, Equatable {
    case started(model: String)
    case textDelta(String)
    case thinkingDelta(String)
    case toolUseStarted(id: String, name: String)
    case blockFinished(ContentBlock)
    case finished(ClaudeResponse)
}

/// Builds a reply from Server-Sent Events.
///
/// Every `data:` line of the Messages stream is a JSON object with a `type`, so
/// the accumulator works line by line and ignores `event:` lines and blank
/// separators (URLSession's line reader drops blank lines anyway).
public struct ClaudeStreamAccumulator: Sendable {
    private var message: JSONObject = [:]
    private var blocks: [Int: JSONObject] = [:]
    private var buffers: [Int: String] = [:]
    private var signatures: [Int: String] = [:]
    private var stopReason: String?
    private var stopDetails: JSONValue?
    private var usage: JSONObject = [:]
    public private(set) var response: ClaudeResponse?

    public init() {}

    /// Feeds one line of the stream. Returns the updates it produced.
    public mutating func feed(line: String) throws -> [ClaudeStreamUpdate] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return [] }
        return try apply(JSONValue.parse(payload))
    }

    public mutating func apply(_ event: JSONValue) throws -> [ClaudeStreamUpdate] {
        switch event["type"]?.stringValue {
        case "message_start":
            message = event["message"]?.objectValue ?? [:]
            if let u = message["usage"]?.objectValue { usage = u }
            return [.started(model: message["model"]?.stringValue ?? "")]

        case "content_block_start":
            guard let index = event["index"]?.intValue, let block = event["content_block"]?.objectValue else { return [] }
            blocks[index] = block
            buffers[index] = ""
            if block["type"]?.stringValue == "tool_use" {
                return [.toolUseStarted(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "")]
            }
            return []

        case "content_block_delta":
            guard let index = event["index"]?.intValue, let delta = event["delta"] else { return [] }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                buffers[index, default: ""] += text
                return [.textDelta(text)]
            case "thinking_delta":
                let text = delta["thinking"]?.stringValue ?? ""
                buffers[index, default: ""] += text
                return [.thinkingDelta(text)]
            case "input_json_delta":
                buffers[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
                return []
            case "signature_delta":
                signatures[index, default: ""] += delta["signature"]?.stringValue ?? ""
                return []
            default:
                return []
            }

        case "content_block_stop":
            guard let index = event["index"]?.intValue, var block = blocks[index] else { return [] }
            let buffer = buffers[index] ?? ""
            switch block["type"]?.stringValue {
            case "text":
                block["text"] = .string(buffer)
            case "thinking":
                block["thinking"] = .string(buffer)
                if let signature = signatures[index] { block["signature"] = .string(signature) }
            case "tool_use", "server_tool_use":
                block["input"] = buffer.trimmingCharacters(in: .whitespaces).isEmpty ? .object([:]) : try JSONValue.parse(buffer)
            default:
                break
            }
            blocks[index] = block
            return [.blockFinished(ContentBlock(json: block))]

        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            if let details = event["delta"]?["stop_details"], !details.isNull { stopDetails = details }
            if let u = event["usage"]?.objectValue {
                for member in u { usage[member.key] = member.value }
            }
            return []

        case "message_stop":
            let content = blocks.keys.sorted().compactMap { blocks[$0].map(ContentBlock.init(json:)) }
            let finished = ClaudeResponse(
                id: message["id"]?.stringValue ?? "",
                model: message["model"]?.stringValue ?? "",
                content: content,
                stopReason: StopReason(stopReason),
                stopDetails: stopDetails,
                usage: ClaudeUsage(json: .object(usage))
            )
            response = finished
            return [.finished(finished)]

        case "error":
            let type = event["error"]?["type"]?.stringValue ?? "error"
            let message = event["error"]?["message"]?.stringValue ?? "stream error"
            throw ClaudeError.http(status: type == "overloaded_error" ? 529 : 500, type: type, message: message)

        default:  // ping, and event types added later
            return []
        }
    }
}
