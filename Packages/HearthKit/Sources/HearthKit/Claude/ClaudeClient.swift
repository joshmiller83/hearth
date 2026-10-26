import Foundation

/// Calls the Messages API over raw HTTPS (there is no official Swift SDK).
public struct ClaudeClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public var apiKey: String
    public var transport: any HTTPTransport
    public var endpoint: URL
    /// Extra tries after a retryable failure (429, 5xx, 529, a dropped connection).
    public var retries: Int
    public var pause: @Sendable (TimeInterval) async throws -> Void

    public init(
        apiKey: String,
        transport: any HTTPTransport,
        endpoint: URL = ClaudeClient.endpoint,
        retries: Int = 2,
        pause: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.endpoint = endpoint
        self.retries = retries
        self.pause = pause
    }

    func httpRequest(_ request: ClaudeRequest) -> HTTPRequest {
        HTTPRequest(
            url: endpoint, method: "POST", headers: request.headers(apiKey: apiKey),
            body: request.body.data, timeout: request.stream ? 600 : 300)
    }

    static func backoff(attempt: Int, retryAfter: String?) -> TimeInterval {
        if let retryAfter, let seconds = Double(retryAfter) { return min(seconds, 30) }
        return [2.0, 5.0, 10.0][min(attempt, 2)]
    }

    /// Sends a request and waits for the whole reply. A refusal throws `.refusal`.
    public func send(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        guard !apiKey.isEmpty else { throw ClaudeError.noKey }
        var request = request
        request.stream = false
        var attempt = 0
        while true {
            let response: HTTPResponse
            do {
                response = try await transport.send(httpRequest(request))
            } catch {
                if attempt < retries {
                    try await pause(Self.backoff(attempt: attempt, retryAfter: nil))
                    attempt += 1
                    continue
                }
                throw ClaudeError.transport(String(describing: error))
            }
            if response.status == 200 {
                let reply = try ClaudeResponse(json: JSONValue.parse(response.body))
                if reply.stopReason == .refusal {
                    throw ClaudeError.refusal(category: reply.stopDetails?["category"]?.stringValue)
                }
                return reply
            }
            let error = ClaudeError.from(status: response.status, body: response.body)
            if error.isRetryable, attempt < retries {
                try await pause(Self.backoff(attempt: attempt, retryAfter: response.header("retry-after")))
                attempt += 1
                continue
            }
            throw error
        }
    }

    /// Sends a request with an output schema and decodes the reply's JSON as `T`.
    public func structured<T: Decodable & Sendable>(_ request: ClaudeRequest, as type: T.Type = T.self) async throws -> (
        value: T, response: ClaudeResponse
    ) {
        let reply = try await send(request)
        if reply.stopReason == .maxTokens { throw ClaudeError.truncated }
        do {
            let value = try JSONValue.parse(reply.text).decode(T.self)
            return (value, reply)
        } catch {
            throw ClaudeError.badOutput(String(describing: error))
        }
    }

    /// Streams a reply. The last update is `.finished` with the whole reply.
    /// Failures before the first byte are retried; a stream cut off midway is not
    /// (its partial output has already been shown).
    public func stream(_ request: ClaudeRequest) -> AsyncThrowingStream<ClaudeStreamUpdate, any Error> {
        var request = request
        request.stream = true
        let http = httpRequest(request)
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !client.apiKey.isEmpty else { throw ClaudeError.noKey }
                    var attempt = 0
                    var opened: HTTPLineStream?
                    while opened == nil {
                        let stream: HTTPLineStream
                        do {
                            stream = try await client.transport.streamLines(http)
                        } catch {
                            if attempt < client.retries {
                                try await client.pause(Self.backoff(attempt: attempt, retryAfter: nil))
                                attempt += 1
                                continue
                            }
                            throw ClaudeError.transport(String(describing: error))
                        }
                        if stream.status == 200 {
                            opened = stream
                            break
                        }
                        var body = ""
                        for try await line in stream.lines { body += line + "\n" }
                        let error = ClaudeError.from(status: stream.status, body: Data(body.utf8))
                        if error.isRetryable, attempt < client.retries {
                            try await client.pause(Self.backoff(attempt: attempt, retryAfter: stream.headers["retry-after"]))
                            attempt += 1
                            continue
                        }
                        throw error
                    }
                    var accumulator = ClaudeStreamAccumulator()
                    for try await line in opened!.lines {
                        for update in try accumulator.feed(line: line) {
                            if case .finished(let reply) = update, reply.stopReason == .refusal {
                                throw ClaudeError.refusal(category: reply.stopDetails?["category"]?.stringValue)
                            }
                            continuation.yield(update)
                        }
                    }
                    if accumulator.response == nil {
                        throw ClaudeError.transport("The stream ended early.")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
