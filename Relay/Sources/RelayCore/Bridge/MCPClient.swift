import Foundation
import HearthKit

/// A small MCP client over a `LineChannel`: JSON-RPC 2.0, one message per line,
/// the stdio transport gmailkit serves. It does the handshake, calls tools one at
/// a time, answers the server's pings, and fails everything waiting if the
/// server goes away.
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"

    public struct ServerInfo: Sendable, Equatable {
        public var name: String
        public var version: String
        public var protocolVersion: String
    }

    private let channel: any LineChannel
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var reader: Task<Void, Never>?
    private var closedError: BridgeError?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(channel: any LineChannel) {
        self.channel = channel
    }

    public var isOpen: Bool { closedError == nil }

    /// Starts reading and runs the `initialize` handshake.
    public func start(clientName: String = "hearth-relay", clientVersion: String = "1") async throws -> ServerInfo {
        startReader()
        let result = try await request(
            "initialize",
            params: [
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": [:],
                "clientInfo": ["name": .string(clientName), "version": .string(clientVersion)],
            ], timeout: 60)
        try notify("notifications/initialized")
        return ServerInfo(
            name: result["serverInfo"]?["name"]?.stringValue ?? "",
            version: result["serverInfo"]?["version"]?.stringValue ?? "",
            protocolVersion: result["protocolVersion"]?.stringValue ?? ""
        )
    }

    /// Calls a tool and returns its result: gmailkit answers every tool with one
    /// text block holding JSON, which is parsed here. A tool that answered
    /// `{"error": …}` (gmailkit's guardrails, a Google error) throws `.remote`.
    /// Calls wait their turn: gmailkit's Google clients aren't safe to use from
    /// two requests at once.
    public func callTool(_ name: String, arguments: JSONValue, timeout: TimeInterval = 180) async throws -> JSONValue {
        await acquire()
        defer { release() }
        let result = try await request("tools/call", params: ["name": .string(name), "arguments": arguments], timeout: timeout)
        let text = result["content"]?[0]?["text"]?.stringValue ?? result["structuredContent"]?["result"]?.stringValue
        if result["isError"]?.boolValue == true {
            throw BridgeError.remote(text ?? "\(name) failed")
        }
        guard let text else { throw BridgeError.badReply("\(name) returned no text") }
        let value: JSONValue
        do {
            value = try JSONValue.parse(text)
        } catch {
            throw BridgeError.badReply("\(name) returned text that isn't JSON")
        }
        if case .object(let object) = value, let message = object["error"]?.stringValue {
            throw BridgeError.remote(message)
        }
        return value
    }

    /// Closes the channel; everything waiting fails.
    public func shutdown() {
        channel.close()
        finish(.notRunning("shut down"))
    }

    // MARK: Plumbing

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func startReader() {
        guard reader == nil else { return }
        let stream = channel.incoming
        reader = Task { [weak self] in
            for await line in stream {
                await self?.handle(line)
            }
            await self?.finish(.notRunning("gmailkit exited"))
        }
    }

    private func notify(_ method: String) throws {
        let message: JSONValue = ["jsonrpc": "2.0", "method": .string(method)]
        try channel.send(message.serialized())
    }

    private func request(_ method: String, params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        if let closedError { throw closedError }
        let id = nextID
        nextID += 1
        let message: JSONValue = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try channel.send(message.serialized())
            } catch {
                pending[id] = nil
                continuation.resume(throwing: BridgeError.notRunning(String(describing: error)))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(id, method: method)
            }
        }
    }

    private func expire(_ id: Int, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: BridgeError.timeout(method))
    }

    private func handle(_ line: String) {
        // gmailkit may print a stray non-JSON line (a library warning); skip it.
        guard let message = try? JSONValue.parse(line) else { return }
        if let method = message["method"]?.stringValue {
            // A request or notification from the server.
            guard let id = message["id"] else { return }
            let reply: JSONValue =
                method == "ping"
                ? ["jsonrpc": "2.0", "id": id, "result": [:]]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
            try? channel.send(reply.serialized())
            return
        }
        guard let id = message["id"]?.intValue, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            continuation.resume(throwing: BridgeError.remote(error["message"]?.stringValue ?? "MCP error"))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func finish(_ error: BridgeError) {
        if closedError == nil { closedError = error }
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
