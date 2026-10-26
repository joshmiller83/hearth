import Foundation
import HearthKit
import Logging

/// The gmailkit tools the relay may call. Anything else is refused before it
/// reaches gmailkit: never `gmail_delete_permanently` (Trash only), never the
/// tools that read or write files on this Mac (`gmail_save_attachments`, and the
/// `attachments` arguments of send/draft/reply, which the relay never passes).
public enum GmailkitTools {
    /// Safe to call from jobs and from Ask's tool proxy.
    public static let read: Set<String> = [
        "gmail_accounts", "gmail_calendars", "gmail_calendar_events",
        "gmail_search", "gmail_unread", "gmail_read", "gmail_thread", "gmail_labels",
    ]

    /// Only the executor calls these, and only for actions the owner approved.
    public static let write: Set<String> = [
        "gmail_modify_batch", "gmail_reply", "gmail_draft", "gmail_send_draft", "gmail_delete_draft",
        "gmail_calendar_respond", "gmail_calendar_create_event", "gmail_calendar_delete_event",
    ]

    /// Arguments that would let a caller name a file on this Mac.
    public static let forbiddenArguments: Set<String> = ["attachments", "out_dir"]
}

/// Runs gmailkit as a child process (`python -m gmailkit.mcp_server` in its
/// checkout) and keeps one MCP session to it, restarting it when it exits.
public actor GmailkitBridge {
    public typealias Launcher = @Sendable (_ onExit: @escaping @Sendable (Int32) -> Void) throws -> any LineChannel

    private let launch: Launcher
    private let logger: Logger
    private let now: @Sendable () -> Date
    private var client: MCPClient?
    private var starting: Task<MCPClient, any Error>?
    private var state = BridgeStatus(state: .down, detail: "not started")
    private var failures = 0
    private var retryAfter: Date?
    private var accountList: [Account] = []

    public init(logger: Logger, now: @escaping @Sendable () -> Date = { Date() }, launch: @escaping Launcher) {
        self.launch = launch
        self.logger = logger
        self.now = now
    }

    /// The real launcher for a gmailkit checkout and its venv.
    public static func processLauncher(config: RelayConfig, logger: Logger) -> Launcher {
        { onExit in
            var environment = ProcessInfo.processInfo.environment
            // gmailkit finds its master key through `gh` (a private gist) when no
            // Keychain is unlocked, as in a launchd daemon; make sure it's on PATH.
            let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = path.contains("/usr/local/bin") ? path : "/usr/local/bin:/opt/homebrew/bin:" + path
            environment["PYTHONUNBUFFERED"] = "1"
            environment["PYTHONWARNINGS"] = "ignore::FutureWarning"
            environment.removeValue(forKey: "GMAIL_READONLY")
            return try ProcessChannel(
                executable: config.python,
                arguments: ["-m", "gmailkit.mcp_server"],
                directory: config.gmailkitDirectory,
                environment: environment,
                onStderr: { line in logger.debug("gmailkit: \(line)") },
                onExit: onExit
            )
        }
    }

    public func status() -> BridgeStatus { state }

    /// The cached account list (fetched once gmailkit is up).
    public func knownAccounts() -> [Account] { accountList }

    /// gmailkit's account email → alias, or the email itself when unknown.
    public func aliasMap() -> [String: String] {
        Dictionary(accountList.map { ($0.email.lowercased(), $0.alias) }, uniquingKeysWith: { a, _ in a })
    }

    /// Starts gmailkit now (at boot) rather than on the first call.
    public func warmUp() async {
        _ = try? await session()
        if accountList.isEmpty { _ = try? await refreshAccounts() }
    }

    @discardableResult
    public func refreshAccounts() async throws -> [Account] {
        let rows = try await callRead("gmail_accounts", [:])
        let decoded = try rows.decode([GmailkitAccountRow].self)
        accountList = decoded.map(\.account)
        return accountList
    }

    /// Calls a read-only tool.
    public func callRead(_ tool: String, _ arguments: JSONValue, timeout: TimeInterval = 300) async throws -> JSONValue {
        guard GmailkitTools.read.contains(tool) else { throw BridgeError.notAllowed(tool) }
        return try await call(tool, arguments, timeout: timeout)
    }

    /// Calls a tool that changes mail or calendars. Only the executor uses this.
    public func callWrite(_ tool: String, _ arguments: JSONValue, timeout: TimeInterval = 120) async throws -> JSONValue {
        guard GmailkitTools.write.contains(tool) else { throw BridgeError.notAllowed(tool) }
        return try await call(tool, arguments, timeout: timeout)
    }

    private func call(_ tool: String, _ arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        if let object = arguments.objectValue, let bad = object.keys.first(where: GmailkitTools.forbiddenArguments.contains) {
            throw BridgeError.notAllowed("\(tool) with \(bad)")
        }
        let client = try await session()
        do {
            return try await client.callTool(tool, arguments: arguments, timeout: timeout)
        } catch let error as BridgeError {
            if case .notRunning = error { lost("gmailkit exited") }
            if case .timeout = error {
                // A wedged gmailkit: start over on the next call.
                await client.shutdown()
                lost("gmailkit stopped answering")
            }
            throw error
        }
    }

    private func session() async throws -> MCPClient {
        if let client, await client.isOpen { return client }
        if let starting { return try await starting.value }
        if let retryAfter, now() < retryAfter {
            throw BridgeError.notRunning(state.detail ?? "restarting")
        }
        let task = Task { () throws -> MCPClient in
            let channel = try launch { [weak self] status in
                Task { await self?.exited(status) }
            }
            let client = MCPClient(channel: channel)
            do {
                let info = try await client.start()
                logger.info("gmailkit is up (\(info.name), MCP \(info.protocolVersion))")
            } catch {
                await client.shutdown()
                throw error
            }
            return client
        }
        starting = task
        state = BridgeStatus(state: .starting, detail: "starting", since: now())
        do {
            let client = try await task.value
            self.client = client
            starting = nil
            failures = 0
            retryAfter = nil
            state = BridgeStatus(state: .up, since: now())
            return client
        } catch {
            starting = nil
            failures += 1
            // 2 s, 4 s, 8 s … up to 5 minutes between attempts.
            let wait = min(300, pow(2, Double(failures)))
            retryAfter = now().addingTimeInterval(wait)
            let detail = "couldn't start gmailkit: \(error)"
            state = BridgeStatus(state: .down, detail: detail, since: now())
            logger.error("\(detail); retrying in \(Int(wait)) s")
            throw BridgeError.notRunning(detail)
        }
    }

    private func lost(_ reason: String) {
        client = nil
        state = BridgeStatus(state: .down, detail: reason, since: now())
    }

    private func exited(_ status: Int32) {
        logger.warning("gmailkit exited with status \(status)")
        lost("gmailkit exited (\(status))")
    }

    public func shutdown() async {
        await client?.shutdown()
        client = nil
        state = BridgeStatus(state: .down, detail: "shut down", since: now())
    }
}
