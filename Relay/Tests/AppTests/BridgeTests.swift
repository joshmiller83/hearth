import Foundation
import HearthKit
import Logging
import RelayCore
import Testing

/// A stand-in for gmailkit's MCP server on the other end of a `MemoryChannel`.
/// It answers the handshake and `tools/call` from a table, slowly, and notes
/// whether two calls were ever in flight at once.
final class FakeMCPServer: @unchecked Sendable {
    let channel: MemoryChannel
    private let lock = NSLock()
    private var inFlight = 0
    private var peak = 0
    private var names: [String] = []
    private var didInitialize = false
    let answers: [String: String]
    let delay: UInt64 = 20_000_000

    init(channel: MemoryChannel, answers: [String: String]) {
        self.channel = channel
        self.answers = answers
    }

    var maxInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    var initialized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didInitialize
    }

    private func enter(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        inFlight += 1
        peak = max(peak, inFlight)
        names.append(name)
    }

    private func leave() {
        lock.lock()
        defer { lock.unlock() }
        inFlight -= 1
    }

    private func markInitialized() {
        lock.lock()
        defer { lock.unlock() }
        didInitialize = true
    }

    func serve() -> Task<Void, Never> {
        Task {
            for await line in channel.incoming {
                guard let message = try? JSONValue.parse(line), let method = message["method"]?.stringValue else { continue }
                let id = message["id"] ?? .null
                switch method {
                case "initialize":
                    let reply: JSONValue = [
                        "jsonrpc": "2.0", "id": id,
                        "result": [
                            "protocolVersion": "2025-06-18", "capabilities": ["tools": [:]],
                            "serverInfo": ["name": "gmailkit", "version": ""],
                        ],
                    ]
                    try? channel.send(reply.serialized())
                case "notifications/initialized":
                    markInitialized()
                case "tools/call":
                    let name = message["params"]?["name"]?.stringValue ?? ""
                    enter(name)
                    // Answer late, so a second request could arrive meanwhile if the client let it.
                    try? await Task.sleep(nanoseconds: delay)
                    let text = answers[name] ?? #"{"error": "unknown tool \#(name)"}"#
                    leave()
                    let reply: JSONValue = [
                        "jsonrpc": "2.0", "id": id,
                        "result": [
                            "content": [["type": "text", "text": .string(text)]], "isError": .bool(name == "explodes"),
                        ],
                    ]
                    try? channel.send(reply.serialized())
                default:
                    let reply: JSONValue = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "nope"]]
                    try? channel.send(reply.serialized())
                }
            }
        }
    }
}

@Suite("gmailkit bridge (MCP over stdio)")
struct BridgeTests {
    let accountsJSON =
        #"[{"email": "sam@rivera.example", "alias": "work", "name": "Sam", "enabled": true, "authorized": true, "notes": ""}]"#

    func connected(_ answers: [String: String]) async throws -> (MCPClient, FakeMCPServer, Task<Void, Never>) {
        let (clientSide, serverSide) = MemoryChannel.pair()
        let server = FakeMCPServer(channel: serverSide, answers: answers)
        let task = server.serve()
        let client = MCPClient(channel: clientSide)
        let info = try await client.start()
        #expect(info.name == "gmailkit")
        #expect(info.protocolVersion == "2025-06-18")
        return (client, server, task)
    }

    @Test func handshakeThenAToolCallReturnsParsedJSON() async throws {
        let (client, server, task) = try await connected(["gmail_accounts": accountsJSON])
        defer { task.cancel() }
        let value = try await client.callTool("gmail_accounts", arguments: [:])
        #expect(value[0]?["alias"]?.stringValue == "work")
        #expect(server.initialized)
    }

    @Test func gmailkitsErrorObjectsBecomeRemoteErrors() async throws {
        let (client, _, task) = try await connected(["gmail_modify_batch": #"{"error": "nothing to change"}"#, "explodes": "Traceback"])
        defer { task.cancel() }
        await #expect(throws: BridgeError.remote("nothing to change")) {
            try await client.callTool("gmail_modify_batch", arguments: [:])
        }
        await #expect(throws: BridgeError.remote("Traceback")) {
            try await client.callTool("explodes", arguments: [:])
        }
    }

    @Test func callsGoOneAtATime() async throws {
        let (client, server, task) = try await connected(["gmail_labels": "[]"])
        defer { task.cancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await client.callTool("gmail_labels", arguments: ["account": "work"]) }
            }
            try await group.waitForAll()
        }
        #expect(server.calls.count == 5)
        #expect(server.maxInFlight == 1)
    }

    @Test func whenTheServerGoesAwayCallsFail() async throws {
        let (client, server, task) = try await connected(["gmail_labels": "[]"])
        server.channel.close()
        task.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        await #expect(throws: BridgeError.self) {
            try await client.callTool("gmail_labels", arguments: [:])
        }
        #expect(await client.isOpen == false)
    }

    @Test func theBridgeRefusesToolsOffItsAllowlist() async throws {
        let bridge = GmailkitBridge(logger: Logger(label: "test")) { _ in MemoryChannel.pair().0 }
        await #expect(throws: BridgeError.notAllowed("gmail_delete_permanently")) {
            try await bridge.callWrite("gmail_delete_permanently", ["message_id": "m", "account": "work", "confirm": true])
        }
        await #expect(throws: BridgeError.notAllowed("gmail_save_attachments")) {
            try await bridge.callRead("gmail_save_attachments", [:])
        }
        // A read tool can't be used as a write and vice versa.
        await #expect(throws: BridgeError.notAllowed("gmail_reply")) { try await bridge.callRead("gmail_reply", [:]) }
        await #expect(throws: BridgeError.notAllowed("gmail_search")) { try await bridge.callWrite("gmail_search", [:]) }
        // No file paths, whatever the tool.
        await #expect(throws: BridgeError.notAllowed("gmail_reply with attachments")) {
            try await bridge.callWrite("gmail_reply", ["message_id": "m", "account": "w", "body": "x", "attachments": ["/etc/passwd"]])
        }
        #expect(!GmailkitTools.read.contains("gmail_delete_permanently") && !GmailkitTools.write.contains("gmail_delete_permanently"))
        #expect(GmailkitTools.read.isDisjoint(with: GmailkitTools.write))
    }

    @Test func theBridgeStartsGmailkitOnFirstUseAndLearnsTheAccounts() async throws {
        let holder = ServerHolder()
        let bridge = GmailkitBridge(logger: Logger(label: "test")) { _ in
            let (client, server) = MemoryChannel.pair()
            holder.start(
                FakeMCPServer(
                    channel: server,
                    answers: [
                        "gmail_accounts": #"[{"email": "Sam@Rivera.example", "alias": "work", "enabled": true, "authorized": true}]"#
                    ]))
            return client
        }
        #expect(await bridge.status().state == .down)
        let accounts = try await bridge.refreshAccounts()
        #expect(accounts.map(\.alias) == ["work"])
        #expect(await bridge.status().state == .up)
        #expect(await bridge.aliasMap() == ["sam@rivera.example": "work"])
        #expect(holder.launches == 1)
        await bridge.shutdown()
        holder.stop()
    }

    @Test func aFailedStartBacksOff() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_000_000))
        let attempts = Counter()
        let bridge = GmailkitBridge(logger: Logger(label: "test"), now: { clock.now }) { _ in
            attempts.increment()
            throw BridgeError.notRunning("no python")
        }
        await #expect(throws: BridgeError.self) { try await bridge.callRead("gmail_labels", ["account": "w"]) }
        await #expect(throws: BridgeError.self) { try await bridge.callRead("gmail_labels", ["account": "w"]) }
        #expect(attempts.value == 1)  // the second call waited out the backoff instead of relaunching
        #expect(await bridge.status().state == .down)
        clock.advance(3)
        await #expect(throws: BridgeError.self) { try await bridge.callRead("gmail_labels", ["account": "w"]) }
        #expect(attempts.value == 2)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

/// Keeps fake servers alive and counts launches.
final class ServerHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [(FakeMCPServer, Task<Void, Never>)] = []

    var launches: Int {
        lock.lock()
        defer { lock.unlock() }
        return servers.count
    }

    func start(_ server: FakeMCPServer) {
        let task = server.serve()
        lock.lock()
        defer { lock.unlock() }
        servers.append((server, task))
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        servers.forEach { $0.1.cancel() }
    }
}
