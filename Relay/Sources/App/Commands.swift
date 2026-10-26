import Fluent
import Foundation
import HearthKit
import Jobs
import RelayCore
import Vapor

/// `Run issue-key --label phone`: prints a new relay key once. Paste it into the
/// phone's Sources screen.
struct IssueKeyCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "label", help: "What the key is for, e.g. \"iPhone\".")
        var label: String?
        init() {}
    }

    var help: String { "Makes a relay key and prints it once. Only its hash is stored." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let key = try await RelayKeys.issue(label: signature.label ?? "phone", on: app.db, now: app.now)
        context.console.print("New relay key (\(signature.label ?? "phone")). It won't be shown again:")
        context.console.print("    \(key)")
    }
}

/// `Run pair --url https://hearth.example.com --label iPhone`: a new key inside a
/// `hearth://pair` link, for a QR code the phone's camera opens (deploy/pair.sh
/// draws it). The phone asks before it saves anything.
struct PairCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "url", help: "The relay's public address, e.g. https://hearth.example.com")
        var url: String?
        @Option(name: "label", help: "What the key is for.")
        var label: String?
        init() {}
    }

    var help: String { "Makes a relay key and prints a hearth://pair link that carries it." }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let url = signature.url, url.hasPrefix("https://") else {
            throw CommandFailure("Usage: Run pair --url https://<relay host> [--label iPhone]")
        }
        let app = context.application
        let key = try await RelayKeys.issue(label: signature.label ?? "iPhone", on: app.db, now: app.now)
        var parts = URLComponents()
        parts.scheme = "hearth"
        parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "relay", value: url), URLQueryItem(name: "key", value: key)]
        context.console.print(parts.string ?? "")
    }
}

/// `Run list-keys`
struct ListKeysCommand: AsyncCommand {
    struct Signature: CommandSignature { init() {} }

    var help: String { "Lists relay keys: id, label, when made, when last used, revoked." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let keys = try await RelayKeyModel.query(on: context.application.db).sort(\.$createdAt).all()
        if keys.isEmpty { context.console.print("No keys yet. Make one with: Run issue-key --label phone") }
        for key in keys {
            let used = key.lastUsedAt.map { RFC3339.format($0) } ?? "never"
            let revoked = key.revokedAt.map { " REVOKED \(RFC3339.format($0))" } ?? ""
            context.console.print(
                "\(key.id?.uuidString ?? "?")  \(key.label)  made \(RFC3339.format(key.createdAt))  used \(used)\(revoked)")
        }
    }
}

/// `Run revoke-key --id <uuid>`
struct RevokeKeyCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "id", help: "The key's id from list-keys.")
        var id: String?
        init() {}
    }

    var help: String { "Stops a relay key from working." }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let text = signature.id, let id = UUID(uuidString: text) else { throw CommandFailure("Usage: Run revoke-key --id <uuid>") }
        let app = context.application
        guard let key = try await RelayKeyModel.find(id, on: app.db) else { throw CommandFailure("There's no key with that id.") }
        key.revokedAt = app.now
        try await key.update(on: app.db)
        context.console.print("Revoked \(key.label).")
    }
}

/// `Run backup`
struct BackupCommand: AsyncCommand {
    struct Signature: CommandSignature { init() {} }

    var help: String { "Writes a VACUUM INTO copy to the backups folder and keeps the newest 30." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let url = try await Backups.run(app: context.application)
        context.console.print("Backed up to \(url.path).")
    }
}

/// `Run run-job calendar`: runs one job now.
struct RunJobCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "name", help: "The job: calendar.")
        var name: String
        init() {}
    }

    var help: String { "Runs one of the relay's jobs now, whatever its schedule." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let names = app.relay.jobs.jobs.map(\.name)
        guard await app.relay.jobs.run(named: signature.name, app.jobContext()) else {
            throw CommandFailure("No job named \(signature.name). Jobs: \(names.joined(separator: ", "))")
        }
        let status = await app.relay.jobs.statuses(app.jobContext()).first { $0.name == signature.name }
        if let error = status?.lastError {
            throw CommandFailure("\(signature.name) failed: \(error)")
        }
        context.console.print("\(signature.name) ran.")
        if let bridge = app.relay.google.bridge { await bridge.shutdown() }
    }
}

/// `Run brief`: writes today's brief now (and queues its push unless `--no-push`).
struct BriefCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "no-push", help: "Write it without queueing a push.")
        var noPush: Bool
        init() {}
    }

    var help: String { "Writes today's morning brief now." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let brief = try await BriefJob.write(app.jobContext(), push: !signature.noPush) else {
            throw CommandFailure("No brief: the morning brief is off, or the relay has no Claude key (HEARTH_ANTHROPIC_KEY_FILE).")
        }
        context.console.print(brief.headline)
        if let idea = brief.kindIdea { context.console.print("Kind idea: \(idea)") }
    }
}

/// `Run push-test`: sends a test push to every registered phone now.
struct PushTestCommand: AsyncCommand {
    struct Signature: CommandSignature { init() {} }

    var help: String { "Sends a test push to every registered phone." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let apns = app.relay.apns else { throw CommandFailure("Push is off: set the HEARTH_APNS_* settings.") }
        try await PushQueue.enqueue(
            PushAlert(title: "Hearth", body: "Pushes work.", kind: "test", urgency: .urgent), quietHours: QuietHours(enabled: false),
            zone: app.relay.household.zone, now: app.now, db: app.db)
        let sent = await PushQueue.sendDue(apns: apns, db: app.db, now: app.now, logger: app.logger)
        context.console.print(sent > 0 ? "Sent." : "Nothing was delivered; see the log.")
    }
}
