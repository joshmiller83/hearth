import Foundation
import HearthKit

/// Everything the relay reads from its environment. Tests build one by hand.
public struct RelayConfig: Sendable {
    public enum DatabaseLocation: Equatable, Sendable {
        case memory
        case file(String)
    }

    public var host = "127.0.0.1"
    public var port = 8791
    public var database: DatabaseLocation = .file("./data/hearth.sqlite")
    public var backupDirectory = "./data/backups"
    public var backupsKept = 30
    /// The gmailkit checkout (holds accounts.yaml and the encrypted token bundle).
    public var gmailkitDirectory = Paths.expandTilde("~/Developer/gh/gmail")
    /// Its venv's Python.
    public var gmailkitPython: String?
    /// `household.json`: names, which accounts are whose, the family calendar, the time zone.
    public var householdFile: String?
    /// A file holding the relay's own Anthropic key (the brief, sorting leftovers).
    public var anthropicKeyFile: String?
    /// The APNs key (.p8), its id, the team, and the app's bundle id; push is off without them.
    public var apnsKeyFile: String?
    public var apnsKeyId: String?
    public var apnsTeamId: String?
    public var apnsTopic = "com.joshmiller83.hearth"
    public var apnsSandbox = true
    /// The git commit being served, from bin/VERSION.
    public var commit: String?
    /// Run the timed jobs (only `serve` does; commands and tests don't).
    public var runJobs = false
    /// The relay's clock. Tests replace it.
    public var now: @Sendable () -> Date = { Date() }

    public init() {}

    public var python: String {
        gmailkitPython ?? Paths.join(gmailkitDirectory, ".venv/bin/python")
    }

    public static func fromEnvironment(_ env: [String: String]) -> RelayConfig {
        var c = RelayConfig()
        func value(_ name: String) -> String? {
            guard let v = env[name]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return Paths.expandTilde(v)
        }
        if let v = value("HEARTH_HOST") { c.host = v }
        if let v = value("HEARTH_PORT").flatMap(Int.init) { c.port = v }
        if let v = value("HEARTH_DB") { c.database = v == ":memory:" ? .memory : .file(v) }
        if let v = value("HEARTH_BACKUP_DIR") {
            c.backupDirectory = v
        } else if case .file(let path) = c.database {
            c.backupDirectory = Paths.join(Paths.parent(path), "backups")
        }
        if let v = value("HEARTH_GMAILKIT_DIR") { c.gmailkitDirectory = v }
        if let v = value("HEARTH_GMAILKIT_PYTHON") { c.gmailkitPython = v }
        if let v = value("HEARTH_HOUSEHOLD") { c.householdFile = v }
        if let v = value("HEARTH_ANTHROPIC_KEY_FILE") { c.anthropicKeyFile = v }
        if let v = value("HEARTH_APNS_KEY_FILE") { c.apnsKeyFile = v }
        if let v = value("HEARTH_APNS_KEY_ID") { c.apnsKeyId = v }
        if let v = value("HEARTH_APNS_TEAM_ID") { c.apnsTeamId = v }
        if let v = value("HEARTH_APNS_TOPIC") { c.apnsTopic = v }
        if let v = value("HEARTH_APNS_ENV") { c.apnsSandbox = v != "production" }
        c.commit = value("HEARTH_COMMIT")
        return c
    }

    /// True for `Run` and `Run serve …`: only a serving process runs the jobs.
    public static func isServeCommand(_ arguments: [String]) -> Bool {
        guard let command = arguments.dropFirst().first else { return true }
        return command == "serve"
    }

    /// Reads `household.json`, or a placeholder when there is none yet.
    public func loadHousehold() throws -> Household {
        guard let path = householdFile else { return .placeholder }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try HearthJSON.decode(Household.self, from: data)
    }

    /// The APNs settings, when all of them are present and the key reads.
    public func loadAPNs() -> APNsConfig? {
        guard let path = apnsKeyFile, let keyId = apnsKeyId, let teamId = apnsTeamId,
            let pem = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        return APNsConfig(keyPEM: pem, keyId: keyId, teamId: teamId, topic: apnsTopic, sandbox: apnsSandbox)
    }

    /// The relay's Anthropic key, trimmed, if a key file is configured and readable.
    public func loadAnthropicKey() -> String? {
        guard let path = anthropicKeyFile, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

/// Path helpers that work the same on Linux (no `NSString` bridging there).
public enum Paths {
    public static func expandTilde(_ path: String, home: String? = ProcessInfo.processInfo.environment["HOME"]) -> String {
        guard path == "~" || path.hasPrefix("~/"), let home else { return path }
        return home + path.dropFirst()
    }

    public static func parent(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    public static func join(_ directory: String, _ component: String) -> String {
        URL(fileURLWithPath: directory).appendingPathComponent(component).path
    }
}
