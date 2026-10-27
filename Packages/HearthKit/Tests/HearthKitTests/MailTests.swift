import Foundation
import HearthKitTestSupport
import Testing

@testable import HearthKit

@Suite("Mail triage")
struct MailTests {
    func sorted() -> [String: TriagedMail] {
        var out: [String: TriagedMail] = [:]
        for item in Fixtures.inbox {
            if let triaged = MailRules.classify(item, rules: MailRules.defaults, now: Fixtures.now) { out[item.id] = triaged }
        }
        return out
    }

    @Test func theDefaultRulesSortTheMorning() {
        let s = sorted()
        #expect(s["m4"]?.queue == .reply && s["m4"]?.tag == "Invite")
        #expect(s["m5"]?.queue == .jobHunt && s["m5"]?.tag == "Application")
        #expect(s["m6"]?.queue == .jobHunt)
        #expect(s["m7"]?.queue == .jobHunt && s["m7"]?.tag == "Job alert")
        #expect(s["m8"]?.bundle == "GitHub" && s["m9"]?.bundle == "GitHub" && s["m8"]?.queue == .archive)
        #expect(s["m10"]?.queue == nil && s["m10"]?.tag == "GitHub")
        #expect(s["m11"]?.queue == .archive && s["m11"]?.tag == "Receipt")
        #expect(s["m12"]?.tag == "Newsletter")
        #expect(s["m13"]?.tag == "Receipt")
        #expect(s["m14"]?.queue == .delete && s["m14"]?.tag == "Promo")
        // Security alerts are never filed automatically.
        #expect(s["m15"]?.queue == nil && s["m15"]?.tag == "Security")
        // People writing to you, and anything else, go to Claude.
        for id in ["m1", "m2", "m3", "m16"] { #expect(s[id] == nil, "\(id) should be left for Claude") }
    }

    @Test func aRecentPromoIsArchivedNotDeleted() {
        var promo = Fixtures.inbox.first { $0.id == "m14" }!
        promo.date = Fixtures.at("2026-10-20T05:00")
        #expect(MailRules.classify(promo, rules: MailRules.defaults, now: Fixtures.now)?.queue == .archive)
    }

    @Test func theAccountsOwnJobHuntLabelCounts() {
        var mail = Fixtures.inbox.first { $0.id == "m16" }!
        mail.labels.append("Label_7")
        let triaged = MailRules.classify(mail, rules: MailRules.defaults, labelNames: ["Label_7": "Job Hunt"], now: Fixtures.now)
        #expect(triaged?.queue == .jobHunt)
        #expect(triaged?.sortedBy == .rule("job-label"))
    }

    @Test func disabledRulesAreSkipped() {
        var rules = MailRules.defaults
        rules[rules.firstIndex { $0.id == "receipts" }!].enabled = false
        let statement = Fixtures.inbox.first { $0.id == "m11" }!
        #expect(MailRules.classify(statement, rules: rules, now: Fixtures.now) == nil)
    }

    @Test func sendersParse() {
        let item = Fixtures.inbox[0]
        #expect(item.senderName == "Dana Whitfield")
        #expect(item.senderEmail == "dana@northbeam.example")
        #expect(item.senderDomain == "northbeam.example")
        #expect(item.initial == "D")
        let bare = MailItem(id: "x", threadId: "x", account: "work", from: "plain@example.com", subject: "Hi", date: Fixtures.now)
        #expect(bare.senderName == "plain@example.com")
    }

    @Test func gmailkitRowsBecomeItems() throws {
        let row = GmailkitMessageRow(
            id: "abc", thread_id: "t1", account: "sam@rivera.example", subject: "Hi", from: "A <a@b.example>", to: "sam@rivera.example",
            cc: "", date: "2026-10-26T13:02:11+00:00", snippet: "it&#39;s fine", labels: ["INBOX", "UNREAD"], unread: true,
            github_reason: "", list_id: "", delivered_to: nil, body_text: nil, body_html: nil, attachments: nil, error: nil)
        let item = try #require(MailItem(row: row, alias: { _ in "work" }))
        #expect(item.account == "work")
        #expect(item.snippet == "it’s fine")
        #expect(item.githubReason == nil && item.listId == nil)
        #expect(RFC3339.format(item.date) == "2026-10-26T13:02:11Z")
    }

    @Test func haikuSortsTheLeftoversCheaply() throws {
        let leftovers = Fixtures.inbox.filter { ["m1", "m2", "m16"].contains($0.id) }
        let request = SortPrompt.request(leftovers, household: Fixtures.household, labelNames: [:])
        #expect(request.model == .haiku)
        #expect(request.effort == .low)
        #expect(request.body["fallbacks"] == nil)
        let text = try #require(request.messages.first?.text)
        #expect(text.contains("0. account: work | from: Dana Whitfield <dana@northbeam.example>"))
        let reply = SortPrompt.Reply(results: [
            .init(index: 0, queue: "reply", tag: "Needs you", reason: "Recruiter asks for times"),
            .init(index: 2, queue: "keep", tag: "School", reason: "Practice moved"),
        ])
        let triaged = SortPrompt.triage(leftovers, reply: reply)
        #expect(triaged.map(\.queue) == [.reply, nil, nil])
        #expect(triaged[1].sortedBy == .unsorted)
        #expect(triaged[2].tag == "School" && triaged[2].sortedBy == .claude)
    }

    @Test func draftsGetTheThreadTheFreeTimeAndTheTone() throws {
        let agenda = Agenda(events: Fixtures.week, household: Fixtures.household)
        let free = agenda.freeWindows(from: Fixtures.now, days: 3)
        let fmt = Fixtures.household.fmt
        #expect(
            free.map { "\(fmt.weekday($0.start)) \(fmt.timeRange($0.start, $0.end))" } == [
                // 10:08–11:00 is under the hour minimum.
                "Mon 1:00–3:00 PM", "Mon 3:45–5:00 PM", "Tue 9:00 AM–5:00 PM", "Wed 9:00 AM–5:00 PM",
            ])
        let thread = [
            ThreadMessage(
                id: "m1", from: "Dana Whitfield <dana@northbeam.example>", to: "sam@rivera.example",
                date: Fixtures.at("2026-10-26T08:12"), subject: "Next steps", body: "Could you share a few windows?")
        ]
        let request = DraftPrompt.request(
            thread: thread, account: Fixtures.accounts[1], freeTime: free, tone: .shorter,
            household: Fixtures.household, now: Fixtures.now)
        #expect(request.model == .opus)
        #expect(request.effort == .low)
        let text = try #require(request.messages.first?.text)
        #expect(text.contains("Reply from: sam@rivera.example (work)."))
        #expect(text.contains("• Tue, Oct 27 · 9:00 AM–5:00 PM"))
        #expect(text.hasSuffix("Draft the reply, as short as it can be while still answering."))
        #expect(try #require(request.system).contains("sign off with just \"Sam\""))
    }

    @Test func quotedHistoryIsTrimmed() {
        let body = "Sounds good.\n\nSam\n\nOn Mon, Oct 26 Dana wrote:\n> Could you share times?"
        #expect(ThreadMessage.trimQuoted(body) == "Sounds good.\n\nSam")
        #expect(ThreadMessage.stripHTML("<p>Hi &amp; welcome</p><br>Thanks") == "Hi & welcome Thanks")
    }

    @Test func snapshotsFilterByQueueAndAccount() {
        let triaged = Fixtures.inbox.compactMap { MailRules.classify($0, rules: MailRules.defaults, now: Fixtures.now) }
        let snapshot = MailSnapshot(generatedAt: Fixtures.now, accounts: ["home", "work"], items: triaged)
        #expect(snapshot.items(in: .jobHunt).count == 3)
        #expect(snapshot.items(in: .archive, account: "home").count == 3)
        #expect(snapshot.kept().map(\.item.id).sorted() == ["m10", "m15"])
        #expect(snapshot.removing(account: "home", ids: ["m8", "m9"]).items(in: .archive, account: "home").count == 1)
    }

    @Test func leftOutMailStaysInTheInboxAndOutOfTheBrief() throws {
        let triaged = Fixtures.inbox.compactMap { MailRules.classify($0, rules: MailRules.defaults, now: Fixtures.now) }
        let snapshot = MailSnapshot(generatedAt: Fixtures.now, accounts: ["home", "work"], items: triaged)
        let invite = try #require(snapshot.items(in: .reply).first)
        let security = try #require(snapshot.kept().first)
        let left = snapshot.leavingOut([invite.id, security.id])
        #expect(left.items(in: .reply).count == snapshot.items(in: .reply).count - 1)
        #expect(left.kept().first { $0.id == invite.id }?.tag == "Left out")
        // Mail that was already kept keeps its own tag.
        #expect(left.kept().first { $0.id == security.id }?.tag == security.tag)
        let agenda = Agenda(events: [], household: Fixtures.household)
        let input = BriefInput.gather(agenda: agenda, mail: left, now: Fixtures.now)
        #expect(!input.needsYou.contains { $0.id == invite.id })
    }
}

@Suite("Morning brief")
struct BriefTests {
    @Test func theBriefSeesTheDayTheQueuesAndWhatsComing() throws {
        let agenda = Agenda(events: Fixtures.week, household: Fixtures.household)
        let triaged = Fixtures.inbox.map {
            MailRules.classify($0, rules: MailRules.defaults, now: Fixtures.now)
                ?? TriagedMail(item: $0, queue: .reply, tag: "Needs you", reason: "", sortedBy: .claude)
        }
        let mail = MailSnapshot(generatedAt: Fixtures.now, accounts: [], items: triaged, newCount: 16)
        let input = BriefInput.gather(agenda: agenda, mail: mail, now: Fixtures.now)
        #expect(input.needsYou.first?.text == "RSVP: Alumni mixer, Wed, Oct 28 · 8:00–9:00 PM")
        #expect(input.needsYou[1].text.contains("(Overlaps Bible study"))
        #expect(input.occasions.map(\.title) == ["Jordan's birthday"])
        #expect(input.queueCounts[.jobHunt] == 3)
        let request = BriefPrompt.request(input)
        #expect(request.model == .opus)
        #expect(request.effort == .medium)
        let text = try #require(request.messages.first?.text)
        #expect(text.contains("- 6:30–8:00 PM: Robin is busy: book club [robin]"))
        #expect(text.contains("Evenings free for both of them: Tue, Wed, Fri, Sat, Sun"))
        #expect(text.contains("Mail: 16 new since the last sweep."))
    }

    @Test func unknownIdsAreDroppedFromTheOrder() {
        let input = BriefInput(
            now: Fixtures.now, household: Fixtures.household, today: [], needsYou: [.init(id: "a", text: "x")],
            queueCounts: [:], newMail: 0, occasions: [], freeEvenings: [])
        let brief = BriefPrompt.brief(.init(headline: "Quiet day.", order: ["b", "a"], kindIdea: "", kindIdeaFor: nil), input: input)
        #expect(brief.order == ["a"])
        #expect(brief.kindIdea == nil)
        #expect(brief.day == "2026-10-26")
    }
}
