import Foundation
import HearthKit
import Observation

/// Facebook, through its side doors: the notification emails (kept or archived
/// by rules Claude writes from what the owner says), shares and screenshots,
/// and the pages that post the same events on feeds.
@MainActor
@Observable
public final class FacebookModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case working
        case failed(String)
    }

    public struct Proposal: Equatable, Sendable {
        public var reply: String
        public var rules: [MailRule]
        public var kept: Int
        public var total: Int
    }

    let services: AppServices
    weak var app: AppModel?

    /// Facebook's emails from the last two weeks, archived ones included.
    public private(set) var mail: [MailItem] = []
    public private(set) var phase: Phase = .idle
    public private(set) var proposal: Proposal?
    public private(set) var saved = false
    public var draft = ""

    init(services: AppServices) {
        self.services = services
    }

    var now: Date { services.clock.now }

    public func refresh() async {
        guard let relay = app?.relay else { return }
        let search = GmailSearchRequest(query: "from:facebookmail.com newer_than:14d", account: "all", limit: 25)
        if let found = try? await relay.searchMail(search) { mail = found.messages }
    }

    /// The last seven days.
    public var week: [MailItem] { mail.filter { now.timeIntervalSince($0.date) < 7 * 86400 } }

    /// How many of this week's the current rules keep.
    public var keptThisWeek: Int {
        let rules = app?.mailRules ?? MailRules.defaults
        return week.filter { MailRules.classify($0, rules: rules, now: now)?.queue == nil }.count
    }

    /// Invites and new events: what "Lately from Facebook" offers to add.
    public var events: [MailItem] {
        mail.filter { item in
            let subject = item.subject.lowercased()
            return subject.contains("event") || subject.contains("invited you")
        }
    }

    /// Shared or screenshotted into Hearth this month.
    public var shares: Int {
        app?.capture.recent.filter {
            ($0.source == "shared" || $0.source == "screenshot") && now.timeIntervalSince($0.createdAt) < 30 * 86400
        }.count
            ?? 0
    }

    /// The rules Facebook's mail goes by now.
    public var rules: [MailRule] { (app?.mailRules ?? []).filter { $0.id.hasPrefix("facebook-") } }

    /// Starts reading an event email the way Capture reads a note.
    public func capture(_ item: MailItem) async {
        guard let capture = app?.capture else { return }
        capture.startOver()
        capture.noteText = "\(item.subject). \(item.snippet)"
        await capture.readNote()
    }

    /// "Only the family group and anything from Mom": Claude writes the rules.
    public func tell(_ text: String? = nil) async {
        let instruction = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        guard let claude = app?.claude, let household = app?.household else {
            phase = .failed(ClaudeError.noKey.description)
            return
        }
        draft = ""
        phase = .working
        saved = false
        if mail.isEmpty { await refresh() }
        do {
            let request = FacebookRulesPrompt.request(instruction: instruction, subjects: mail.map(\.subject), household: household)
            let (reply, _) = try await claude.structured(request, as: FacebookRulesPrompt.Reply.self)
            let rules = FacebookRulesPrompt.rules(reply)
            let preview = FacebookRulesPrompt.preview(rules, mail: mail, now: now)
            proposal = Proposal(reply: reply.reply, rules: rules, kept: preview.kept, total: preview.total)
            phase = .idle
        } catch {
            phase = .failed(AskModel.describe(error))
        }
    }

    /// Puts the proposed rules ahead of Hearth's defaults; the relay sorts by them from the next sweep.
    public func save() {
        guard let proposal else { return }
        app?.setFacebookRules(proposal.rules)
        saved = true
    }

    /// "Keep: Rivera Family", "Archive: the rest".
    public static func chips(_ rules: [MailRule]) -> [String] {
        rules.flatMap { rule -> [String] in
            switch rule.outcome {
            case .keep:
                let phrases = rule.match.subjectContains.filter { !FacebookRulesPrompt.invitePhrases.contains($0) }
                var chips = phrases.map { "Keep: \($0)" }
                if rule.match.subjectContains.contains("birthday") { chips.append("Keep: invites, birthdays") }
                return chips
            case .queue:
                return ["Archive: the rest"]
            }
        }
    }
}
