import Foundation
import HearthKitTestSupport
import Testing

@testable import HearthKit

@Suite("Claude requests")
struct ClaudeRequestTests {
    @Test func opusRequestsFollowThe2026Rules() throws {
        let schema: JSONValue = [
            "type": "object", "properties": ["title": ["type": "string"]], "required": ["title"], "additionalProperties": false,
        ]
        let request = ClaudeRequest(
            model: .opus, maxTokens: 4000, system: "You read flyers.", messages: [.user("hi")],
            effort: .medium, outputSchema: schema)
        let body = request.body
        #expect(body["model"]?.stringValue == "claude-opus-5-5")
        #expect(body["max_tokens"]?.intValue == 4000)
        #expect(body["system"]?[0]?["cache_control"]?["type"]?.stringValue == "ephemeral")
        #expect(body["output_config"]?["effort"]?.stringValue == "medium")
        #expect(body["output_config"]?["format"]?["type"]?.stringValue == "json_schema")
        #expect(body["output_config"]?["format"]?["schema"] == schema)
        #expect(body["fallbacks"]?.stringValue == "default")
        for banned in ["temperature", "top_p", "top_k", "tool_choice", "thinking", "stream"] {
            #expect(body[banned] == nil, "\(banned) must not be sent")
        }
        let headers = request.headers(apiKey: "sk-test")
        #expect(headers["anthropic-version"] == "2026-10-21")
        #expect(headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
        #expect(headers["x-api-key"] == "sk-test")
    }

    @Test func haikuNeverSendsFallbacks() {
        let request = ClaudeRequest(model: .haiku, messages: [.user("sort this")], effort: .low)
        #expect(request.body["fallbacks"] == nil)
        #expect(request.headers(apiKey: "k")["anthropic-beta"] == nil)
        #expect(request.body["output_config"]?["effort"]?.stringValue == "low")
    }

    @Test func toolsAreStrictAndCachedWithoutASystemPrompt() {
        let tool = ClaudeTool(
            name: "agenda", description: "Read the agenda.",
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false])
        let request = ClaudeRequest(model: .opus, messages: [.user("what's on")], tools: [tool], showThinking: true, stream: true)
        let body = request.body
        #expect(body["tools"]?[0]?["strict"]?.boolValue == true)
        #expect(body["tools"]?[0]?["cache_control"]?["type"]?.stringValue == "ephemeral")
        #expect(body["thinking"]?["display"]?.stringValue == "summarized")
        #expect(body["stream"]?.boolValue == true)
        #expect(request.headers(apiKey: "k")["accept"] == "text/event-stream")
    }

    @Test func imagesAreBase64Blocks() {
        let block = ContentBlock.image(Data([1, 2, 3]), mediaType: "image/jpeg")
        #expect(
            JSONValue.object(block.json).serialized()
                == #"{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"AQID"}}"#)
    }
}

@Suite("Claude client")
struct ClaudeClientTests {
    func client(_ transport: ScriptedTransport) -> ClaudeClient {
        ClaudeClient(apiKey: "sk-test", transport: transport, pause: { _ in })
    }

    @Test func sendReturnsTheReply() async throws {
        let transport = ScriptedTransport([ScriptedTransport.message(text: "Hello.")])
        let reply = try await client(transport).send(ClaudeRequest(model: .opus, messages: [.user("hi")]))
        #expect(reply.text == "Hello.")
        #expect(reply.stopReason == .endTurn)
        #expect(reply.usage.inputTokens == 120)
        #expect(transport.requests.first?.url == ClaudeClient.endpoint)
    }

    @Test func overloadedIsRetriedThenSucceeds() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.json(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            .failure("connection reset"),
            ScriptedTransport.message(text: "ok"),
        ])
        let reply = try await client(transport).send(ClaudeRequest(model: .haiku, messages: [.user("x")]))
        #expect(reply.text == "ok")
        #expect(transport.requests.count == 3)
    }

    @Test func aBadKeyIsNotRetried() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.json(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        ])
        await #expect(throws: ClaudeError.http(status: 401, type: "authentication_error", message: "invalid x-api-key")) {
            try await client(transport).send(ClaudeRequest(model: .opus, messages: [.user("x")]))
        }
        #expect(ClaudeError.http(status: 401, type: "", message: "").description.contains("API key"))
    }

    @Test func refusalsThrow() async throws {
        let transport = ScriptedTransport([ScriptedTransport.message(text: "", stopReason: "refusal")])
        await #expect(throws: ClaudeError.refusal(category: nil)) {
            try await client(transport).send(ClaudeRequest(model: .opus, messages: [.user("x")]))
        }
    }

    @Test func missingKeyFailsFast() async {
        let none = ClaudeClient(apiKey: "", transport: ScriptedTransport([]))
        await #expect(throws: ClaudeError.noKey) { try await none.send(ClaudeRequest(model: .opus, messages: [.user("x")])) }
    }

    @Test func structuredOutputDecodes() async throws {
        struct Entry: Decodable, Sendable, Equatable {
            var title: String
            var start: Date
        }
        let transport = ScriptedTransport([
            ScriptedTransport.message(text: #"{"title":"Trunk or Treat","start":"2026-10-31T16:00:00-04:00"}"#)
        ])
        let (entry, _) = try await client(transport).structured(ClaudeRequest(model: .opus, messages: [.user("flyer")]), as: Entry.self)
        #expect(entry == Entry(title: "Trunk or Treat", start: RFC3339.date("2026-10-31T20:00:00Z")!))
    }

    @Test func streamingAssemblesThinkingTextAndTools() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.streamed(
                [
                    ["type": "thinking", "thinking": "Check the calendar.", "signature": "sig-abc"],
                    ["type": "text", "text": "Let me look."],
                    ["type": "tool_use", "id": "toolu_1", "name": "agenda", "input": ["to": "2026-10-30", "from": "2026-10-26"]],
                ], stopReason: "tool_use")
        ])
        var texts: [String] = []
        var final: ClaudeResponse?
        for try await update in client(transport).stream(ClaudeRequest(model: .opus, messages: [.user("free friday?")])) {
            if case .textDelta(let t) = update { texts.append(t) }
            if case .finished(let r) = update { final = r }
        }
        let reply = try #require(final)
        #expect(texts.joined() == "Let me look.")
        #expect(reply.stopReason == .toolUse)
        #expect(reply.content.map(\.type) == ["thinking", "text", "tool_use"])
        #expect(reply.content[0].json["signature"]?.stringValue == "sig-abc")
        // Input keys arrive in the model's order and stay that way.
        #expect(reply.toolUses.first?.input.serialized() == #"{"to":"2026-10-30","from":"2026-10-26"}"#)
        #expect(reply.usage.outputTokens == 87)
        #expect(reply.usage.cacheReadTokens == 150)
        #expect(transport.bodies.first?["stream"]?.boolValue == true)
    }

    @Test func aStreamErrorEventThrows() async throws {
        let transport = ScriptedTransport([
            .stream(
                status: 200,
                lines: [
                    #"data: {"type":"message_start","message":{"id":"m","type":"message","model":"claude-opus-5-5","content":[],"usage":{}}}"#,
                    #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
                ])
        ])
        await #expect(throws: ClaudeError.self) {
            for try await _ in client(transport).stream(ClaudeRequest(model: .opus, messages: [.user("x")])) {}
        }
    }
}

@Suite("Tool loop")
struct ToolLoopTests {
    struct AgendaBox: ClaudeToolbox {
        var tools: [ClaudeTool] {
            [
                ClaudeTool(
                    name: "agenda", description: "Events in a range.",
                    inputSchema: [
                        "type": "object", "properties": ["from": ["type": "string"], "to": ["type": "string"]],
                        "required": ["from", "to"], "additionalProperties": false,
                    ])
            ]
        }
        func run(_ call: ToolUse) async -> ToolOutcome {
            ToolOutcome(text: #"[{"title":"Bible study","start":"Thu 7 PM"}]"#, trace: "Read the agenda: 1 event")
        }
    }

    @Test func runsToolsAndKeepsTheTranscriptAppendOnly() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.streamed(
                [
                    ["type": "thinking", "thinking": "Need the agenda.", "signature": "s1"],
                    ["type": "tool_use", "id": "toolu_1", "name": "agenda", "input": ["from": "2026-10-29", "to": "2026-10-29"]],
                ], stopReason: "tool_use"),
            ScriptedTransport.streamed([["type": "text", "text": "Thursday has Bible study at 7."]], stopReason: "end_turn"),
        ])
        let loop = ToolLoop(client: ClaudeClient(apiKey: "k", transport: transport, pause: { _ in }))
        var traces: [String] = []
        var done: (ClaudeResponse, [ClaudeMessage])?
        for try await event in loop.run(ClaudeRequest(model: .opus, messages: [.user("Thursday?")]), toolbox: AgendaBox()) {
            if case .toolFinished(_, let outcome) = event { traces.append(outcome.trace) }
            if case .done(let reply, let transcript) = event { done = (reply, transcript) }
        }
        let (reply, transcript) = try #require(done)
        #expect(reply.text == "Thursday has Bible study at 7.")
        #expect(traces == ["Read the agenda: 1 event"])
        #expect(transcript.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(transcript[1].content.first?.json["signature"]?.stringValue == "s1")
        #expect(transcript[2].content.first?.json["tool_use_id"]?.stringValue == "toolu_1")

        // The second request resent the first turn exactly as it came back.
        let second = try #require(transport.bodies.last)
        let resent = try #require(second["messages"]?[1])
        #expect(resent == transcript[1].json)
        #expect(second["cache_control"]?["type"]?.stringValue == "ephemeral")
        #expect(second["tools"]?[0]?["name"]?.stringValue == "agenda")
    }

    @Test func endlessToolCallsStop() async throws {
        let toolTurn = ScriptedTransport.streamed(
            [
                ["type": "tool_use", "id": "t", "name": "agenda", "input": ["from": "a", "to": "b"]]
            ], stopReason: "tool_use")
        let transport = ScriptedTransport(Array(repeating: toolTurn, count: 3))
        let loop = ToolLoop(client: ClaudeClient(apiKey: "k", transport: transport, pause: { _ in }), maxRounds: 2)
        await #expect(throws: ClaudeError.self) {
            for try await _ in loop.run(ClaudeRequest(model: .opus, messages: [.user("x")]), toolbox: AgendaBox()) {}
        }
        #expect(transport.requests.count == 3)
        // The last round told Claude to wrap up.
        let last = try #require(transport.bodies.last?["messages"]?.arrayValue?.last)
        #expect(last["content"]?.arrayValue?.last?["text"]?.stringValue?.contains("last tool call") == true)
    }
}
