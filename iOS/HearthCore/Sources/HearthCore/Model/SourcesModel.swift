import Foundation
import HearthKit
import Observation

/// The Sources screen: the relay's address and key, the Claude key, the
/// connection's health, and the owner's switches.
@MainActor
@Observable
public final class SourcesModel {
    public enum Check: Equatable, Sendable {
        case idle
        case checking
        case ok(String)
        case failed(String)
    }

    let services: AppServices
    weak var app: AppModel?

    public var relayURLText: String
    public var relayKeyText: String = ""
    public var claudeKeyText: String = ""
    public private(set) var relayCheck: Check = .idle
    public private(set) var claudeCheck: Check = .idle

    init(services: AppServices) {
        self.services = services
        relayURLText = services.secrets.read(.relayURL) ?? ""
    }

    public var hasRelayKey: Bool { !(services.secrets.read(.relayKey) ?? "").isEmpty }
    public var hasClaudeKey: Bool { !(services.secrets.read(.claudeKey) ?? "").isEmpty }

    /// Saves whatever was typed (blank key fields keep the stored key), then checks the relay.
    public func saveRelay() async {
        guard let url = RelayCredentials.normalize(relayURLText) else {
            relayCheck = .failed("That doesn't look like the relay's https address.")
            return
        }
        do {
            try services.secrets.write(url.absoluteString, for: .relayURL)
            let key = relayKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { try services.secrets.write(key, for: .relayKey) }
        } catch {
            relayCheck = .failed("Couldn't save to the Keychain (\(error)).")
            return
        }
        relayURLText = url.absoluteString
        relayKeyText = ""
        app?.credentialsChanged()
        await checkRelay()
    }

    public func checkRelay() async {
        guard let app else { return }
        relayCheck = .checking
        if let health = await app.refreshHealth() {
            let accounts = health.accounts?.count ?? 0
            let state = health.gmailkit?.state.rawValue ?? "unknown"
            relayCheck = .ok("Connected · gmailkit \(state) · \(accounts) account\(accounts == 1 ? "" : "s")")
            await app.plans.refresh()
            await app.uploadContext()
        } else {
            relayCheck = .failed(app.relayProblem ?? "Couldn't reach the relay.")
        }
    }

    public func saveClaudeKey() async {
        let key = claudeKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard key.hasPrefix("sk-ant-") else {
            claudeCheck = .failed("Claude keys start with sk-ant-.")
            return
        }
        do {
            try services.secrets.write(key, for: .claudeKey)
        } catch {
            claudeCheck = .failed("Couldn't save to the Keychain (\(error)).")
            return
        }
        claudeKeyText = ""
        app?.credentialsChanged()
        await checkClaude()
    }

    /// A one-word Haiku call: proves the key works for a fraction of a cent.
    public func checkClaude() async {
        guard let claude = app?.claude else {
            claudeCheck = .failed(ClaudeError.noKey.description)
            return
        }
        claudeCheck = .checking
        do {
            _ = try await claude.send(
                ClaudeRequest(model: .haiku, maxTokens: 512, messages: [.user("Reply with the word ok.")], effort: .low))
            claudeCheck = .ok("Key works")
        } catch {
            claudeCheck = .failed((error as? ClaudeError)?.description ?? String(describing: error))
        }
    }

    /// Saves what a `hearth://pair` link carried (after the owner confirmed it), then checks it.
    public func pair(_ link: PairLink) async {
        do {
            try services.secrets.write(link.relay.absoluteString, for: .relayURL)
            try services.secrets.write(link.key, for: .relayKey)
        } catch {
            relayCheck = .failed("Couldn't save to the Keychain (\(error)).")
            return
        }
        relayURLText = link.relay.absoluteString
        app?.credentialsChanged()
        await checkRelay()
    }

    public func forgetRelay() {
        try? services.secrets.write(nil, for: .relayKey)
        app?.credentialsChanged()
        relayCheck = .idle
    }

    public func forgetClaude() {
        try? services.secrets.write(nil, for: .claudeKey)
        app?.credentialsChanged()
        claudeCheck = .idle
    }
}
