import Foundation

/// A two-way, line-at-a-time connection: what MCP's stdio transport is. The real
/// one talks to a child process's pipes; tests use an in-memory pair.
public protocol LineChannel: Sendable {
    /// Lines from the other side, until it closes.
    var incoming: AsyncStream<String> { get }
    func send(_ line: String) throws
    func close()
}

/// A child process's stdin and stdout as a `LineChannel`. stderr lines go to `onStderr`.
public final class ProcessChannel: LineChannel, @unchecked Sendable {
    public let incoming: AsyncStream<String>
    private let process: Process
    private let stdin: FileHandle
    private let lock = NSLock()
    private var closed = false

    /// Starts `executable` with `arguments` in `directory`.
    public init(
        executable: String,
        arguments: [String],
        directory: String,
        environment: [String: String],
        onStderr: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { onExit($0.terminationStatus) }

        var continuation: AsyncStream<String>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.process = process
        stdin = input.fileHandleForWriting
        try process.run()

        // Plain threads doing blocking reads: they don't tie up the cooperative
        // pool, and they end by themselves at EOF when the process exits.
        let out = continuation!
        Self.readLines(from: output.fileHandleForReading, name: "gmailkit-stdout", { out.yield($0) }, done: { out.finish() })
        Self.readLines(from: errors.fileHandleForReading, name: "gmailkit-stderr", onStderr, done: {})
    }

    private static func readLines(
        from handle: FileHandle, name: String, _ onLine: @escaping @Sendable (String) -> Void,
        done: @escaping @Sendable () -> Void
    ) {
        let thread = Thread {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    onLine(String(decoding: line, as: UTF8.self))
                }
            }
            if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
            done()
        }
        thread.name = name
        thread.start()
    }

    public func send(_ line: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw BridgeError.notRunning("gmailkit isn't running") }
        try stdin.write(contentsOf: Data((line + "\n").utf8))
    }

    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        try? stdin.close()
        if process.isRunning { process.terminate() }
    }

    public var isRunning: Bool { process.isRunning }
    public var pid: Int32 { process.processIdentifier }
}

/// Two in-memory channels wired to each other, for tests: what one sends, the other receives.
public final class MemoryChannel: LineChannel, @unchecked Sendable {
    public let incoming: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private weak var peer: MemoryChannel?
    private var closed = false

    private init() {
        var c: AsyncStream<String>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public static func pair() -> (MemoryChannel, MemoryChannel) {
        let a = MemoryChannel()
        let b = MemoryChannel()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    public func send(_ line: String) throws {
        lock.lock()
        let isClosed = closed
        let other = peer
        lock.unlock()
        guard !isClosed, let other else { throw BridgeError.notRunning("channel closed") }
        other.continuation.yield(line)
    }

    public func close() {
        lock.lock()
        closed = true
        let other = peer
        lock.unlock()
        continuation.finish()
        other?.continuation.finish()
    }
}

public enum BridgeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// gmailkit isn't running (yet, or any more).
    case notRunning(String)
    /// gmailkit took too long to answer.
    case timeout(String)
    /// gmailkit answered with a JSON-RPC error, or a tool returned `{"error": …}`.
    case remote(String)
    /// The bridge refused to call a tool that isn't on its allowlist.
    case notAllowed(String)
    case badReply(String)

    public var description: String {
        switch self {
        case .notRunning(let s): "gmailkit isn't running: \(s)"
        case .timeout(let s): "gmailkit didn't answer in time: \(s)"
        case .remote(let s): s
        case .notAllowed(let s): "Not allowed: \(s)"
        case .badReply(let s): "gmailkit's answer didn't make sense: \(s)"
        }
    }
}
