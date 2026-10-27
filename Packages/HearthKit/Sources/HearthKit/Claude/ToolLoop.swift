import Foundation

/// The result of running one tool for Claude.
public struct ToolOutcome: Sendable, Equatable {
    /// What goes back to Claude in the `tool_result`.
    public var text: String
    public var isError: Bool
    /// A short line for the owner's trace: "Searched 7 inboxes: 3 matches".
    public var trace: String

    public init(text: String, isError: Bool = false, trace: String) {
        self.text = text
        self.isError = isError
        self.trace = trace
    }
}

/// The tools a conversation may use and how to run them.
public protocol ClaudeToolbox: Sendable {
    var tools: [ClaudeTool] { get }
    func run(_ call: ToolUse) async -> ToolOutcome
}

/// What a tool loop reports as it goes.
public enum ToolLoopEvent: Sendable, Equatable {
    case stream(ClaudeStreamUpdate)
    case toolStarted(ToolUse)
    case toolFinished(ToolUse, ToolOutcome)
    /// The final reply and the whole transcript (append it to keep talking).
    case done(ClaudeResponse, transcript: [ClaudeMessage])
}

/// Runs a conversation with client tools to the end: stream a reply, run the
/// tools it asks for, send their results back, repeat.
///
/// The transcript is append-only. Each reply goes back exactly as it came
/// (thinking blocks and all), each round of results is one new user message,
/// and nothing earlier is ever edited, which is what preserved thinking requires.
///
/// A reply that calls only `terminal` tools ends the run once they've run: the
/// transcript then ends on that reply, and the caller owes their results at the
/// start of the next user message (Ask's proposals wait for the owner's tap).
public struct ToolLoop: Sendable {
    public var client: ClaudeClient
    public var maxRounds: Int

    public init(client: ClaudeClient, maxRounds: Int = 8) {
        self.client = client
        self.maxRounds = maxRounds
    }

    public func run(
        _ base: ClaudeRequest, toolbox: any ClaudeToolbox, terminal: Set<String> = []
    ) -> AsyncThrowingStream<ToolLoopEvent, any Error> {
        let client = self.client
        let maxRounds = self.maxRounds
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = base
                    request.tools = toolbox.tools
                    request.cacheConversation = true
                    // One more request than rounds of tools, so the last results get an answer.
                    for round in 0...maxRounds {
                        var reply: ClaudeResponse?
                        for try await update in client.stream(request) {
                            continuation.yield(.stream(update))
                            if case .finished(let finished) = update { reply = finished }
                        }
                        guard let reply else { throw ClaudeError.transport("No reply.") }
                        request.messages.append(reply.assistantMessage)

                        let calls = reply.toolUses
                        if reply.stopReason == .toolUse, !calls.isEmpty, calls.allSatisfy({ terminal.contains($0.name) }) {
                            for call in calls {
                                continuation.yield(.toolStarted(call))
                                continuation.yield(.toolFinished(call, await toolbox.run(call)))
                            }
                            continuation.yield(.done(reply, transcript: request.messages))
                            continuation.finish()
                            return
                        }
                        switch reply.stopReason {
                        case .toolUse where round < maxRounds:
                            var results: [ContentBlock] = []
                            for call in reply.toolUses {
                                continuation.yield(.toolStarted(call))
                                let outcome = await toolbox.run(call)
                                continuation.yield(.toolFinished(call, outcome))
                                results.append(.toolResult(id: call.id, text: outcome.text, isError: outcome.isError))
                            }
                            if round == maxRounds - 1 {
                                results.append(.text("That's the last tool call this turn. Answer with what you have."))
                            }
                            request.messages.append(.user(results))
                        case .toolUse:
                            throw ClaudeError.badOutput("Claude kept calling tools without answering.")
                        case .pauseTurn:
                            continue
                        case .maxTokens:
                            throw ClaudeError.truncated
                        default:
                            continuation.yield(.done(reply, transcript: request.messages))
                            continuation.finish()
                            return
                        }
                    }
                    throw ClaudeError.badOutput("Claude kept calling tools without answering.")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
