import Foundation
import HearthKit

/// The texts `hearth-messages` exported, and the WhatsApp and Messenger chats the relay's
/// bridges job read, as the relay serves them. The relay never opens the Messages
/// database: it reads the helper's files, again only when they change. The bridges'
/// share sits beside them, in files the job writes.
public actor ChatStore {
    /// The helper and the job run every two minutes; quiet for this long, they've stopped.
    public static let staleAfter: TimeInterval = 15 * 60

    typealias Loaded = (modified: Date, export: ChatExport)

    let directory: String?
    /// The Mac runs bridges for the relay to read; without them, files a past setup left are ignored.
    let readsBridges: Bool
    private var cached: Loaded?
    private var cachedBridged: Loaded?

    public init(directory: String?, readsBridges: Bool = false) {
        self.directory = directory
        self.readsBridges = readsBridges
    }

    func url(_ name: String) -> URL? {
        directory.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
    }

    private func load(_ name: String, cached: Loaded?) -> Loaded? {
        guard let url = url(name),
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        if let cached, cached.modified == modified { return cached }
        guard let data = try? Data(contentsOf: url), let export = try? HearthJSON.decode(ChatExport.self, from: data) else { return nil }
        return (modified, export)
    }

    static func stale(_ status: ChatSourceStatus, now: Date, message: String) -> ChatSourceStatus {
        var status = status
        if let checked = status.checkedAt, now.timeIntervalSince(checked) > staleAfter {
            status.state = .notRunning
            status.message = message
        }
        return status
    }

    // MARK: Messages (hearth-messages)

    /// The latest export, or nil when there's none (or the helper can't read Messages).
    public func export() -> ChatExport? {
        cached = load(ChatFiles.export, cached: cached)
        return cached?.export
    }

    public func status(now: Date) -> ChatSourceStatus {
        guard let url = url(ChatFiles.status), let data = try? Data(contentsOf: url),
            let status = try? HearthJSON.decode(ChatSourceStatus.self, from: data)
        else { return .notInstalled }
        return Self.stale(status, now: now, message: "Hearth's Messages helper hasn't run since then. Is this Mac logged in?")
    }

    // MARK: The bridges (BridgedChatsJob)

    /// What the bridges job last read, every bridge's rooms together.
    public func bridgedExport() -> ChatExport? {
        guard readsBridges else { return nil }
        cachedBridged = load(ChatFiles.bridgedExport, cached: cachedBridged)
        return cachedBridged?.export
    }

    /// One per bridge the Mac runs; empty when it runs none.
    public func bridgedStatuses(now: Date) -> [ChatSourceStatus] {
        guard readsBridges, let url = url(ChatFiles.bridgedStatus), let data = try? Data(contentsOf: url),
            let statuses = try? HearthJSON.decode([ChatSourceStatus].self, from: data)
        else { return [] }
        return statuses.map { Self.stale($0, now: now, message: "The relay hasn't read the bridges since then.") }
    }

    /// Keeps what the job read (mode 600). A nil export leaves the last one in place.
    public func saveBridged(_ export: ChatExport?, statuses: [ChatSourceStatus]) throws {
        if let export {
            try save(HearthJSON.encode(export), as: ChatFiles.bridgedExport)
            cachedBridged = nil
        }
        try save(HearthJSON.encode(statuses), as: ChatFiles.bridgedStatus)
    }

    private func save(_ data: Data, as name: String) throws {
        guard let url = url(name) else { return }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Together

    /// Every source's status: Messages, then each bridge.
    public func statuses(now: Date) -> [ChatSourceStatus] {
        var messages = status(now: now)
        messages.source = ChatSource.iMessage
        return [messages] + bridgedStatuses(now: now)
    }

    /// What the routes and Ask may use: every source that's current, as one export.
    /// A source that can't be read right now (stopped, signed out) is left out entirely.
    public func current(now: Date) -> ChatExport? {
        var exports: [ChatExport] = []
        if status(now: now).state == .ok, let messages = export() { exports.append(messages) }
        let readable = Set(bridgedStatuses(now: now).filter { $0.state == .ok }.compactMap(\.source))
        if !readable.isEmpty, let bridged = bridgedExport() {
            let threads = bridged.threads.filter { readable.contains($0.source) }
            let ids = Set(threads.map(\.id))
            exports.append(
                ChatExport(
                    exportedAt: bridged.exportedAt, source: bridged.source, since: bridged.since, threads: threads,
                    messages: bridged.messages.filter { ids.contains($0.threadId) }))
        }
        return ChatExport.merged(exports)
    }
}

/// Where the relay reads the Mac's Matrix homeserver (deploy/bridges): its address, the
/// file holding the relay's token, the account the bridges work for, and which bridges run.
public struct MatrixAccess: Sendable, Equatable {
    public var homeserver: String
    public var tokenFile: String
    public var owner: String
    public var networks: [BridgeNetwork]

    public init(homeserver: String, tokenFile: String, owner: String, networks: [BridgeNetwork]) {
        self.homeserver = homeserver
        self.tokenFile = tokenFile
        self.owner = owner
        self.networks = networks
    }

    /// The token, trimmed; nil until deploy/bridges/login.sh has made it.
    public func token() -> String? {
        guard let text = try? String(contentsOfFile: tokenFile, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

extension Cache {
    /// Where the bridges job's next /sync carries on from.
    public static let bridgesSince = "bridges.since"
}
