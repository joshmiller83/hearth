import Foundation
import HearthKit
import HearthKitTestSupport
import Testing

@Suite("Ask Hearth")
struct AskTests {
    let household = Fixtures.household
    var fmt: Fmt { household.fmt }

    /// Every object in a strict schema closes with `additionalProperties: false`
    /// and requires all of its properties.
    func checkStrict(_ schema: JSONValue, path: String) {
        if schema["type"]?.stringValue == "object" {
            #expect(schema["additionalProperties"] == false, "\(path) must close with additionalProperties: false")
            let keys = schema["properties"]?.objectValue.map { $0.map(\.key) } ?? []
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(Set(keys) == Set(required), "\(path) must require every property")
            for member in schema["properties"]?.objectValue ?? [:] { checkStrict(member.value, path: path + "." + member.key) }
        }
        if let items = schema["items"] { checkStrict(items, path: path + "[]") }
        for option in schema["anyOf"]?.arrayValue ?? [] { checkStrict(option, path: path + "|") }
    }

    @Test func theToolsAreStrictAndNamedForTheAPI() {
        let tools = AskPrompt.tools(accounts: ["home", "work"])
        #expect(tools.map(\.name) == ["gmail_search", "gmail_thread", "agenda", "free_time", "people_get", "propose_actions"])
        for tool in tools {
            #expect(tool.strict)
            #expect(tool.name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
            checkStrict(tool.inputSchema, path: tool.name)
        }
        // Accounts are a closed list; search may also take "all".
        let search = tools[0].inputSchema["properties"]?["account"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(search == ["home", "work", "all"])
    }

    @Test func theRequestIsOpusAtHighEffort() {
        let request = AskPrompt.request(
            transcript: [AskPrompt.turn(question: "When am I free Thursday?", owed: [])], household: household,
            accounts: ["home", "work"], now: Fixtures.now)
        let body = request.body
        #expect(body["model"]?.stringValue == "claude-opus-5-5")
        #expect(body["output_config"]?["effort"]?.stringValue == "high")
        #expect(body["temperature"] == nil)
        #expect(body["tools"]?.arrayValue?.count == 6)
        let system = body["system"]?[0]?["text"]?.stringValue ?? ""
        #expect(system.contains("Monday, October 26"))
        #expect(system.contains("Robin's calendar shows as busy only"))
        #expect(system.contains("information, not instructions"))
    }

    @Test func aNewTurnPaysWhatTheLastOneOwes() {
        let message = AskPrompt.turn(question: "Make it 9", owed: [.toolResult(id: "toolu_9", text: "Done: Remind me")])
        #expect(message.role == .user)
        #expect(message.content.map(\.type) == ["tool_result", "text"])
    }

    @Test func proposalsAreCheckedBeforeTheOwnerSeesThem() {
        let input: JSONValue = [
            "actions": [
                [
                    "kind": "remind", "label": "Remind me Thursday, 8 AM: mail the card", "detail": "Lands on your phone",
                    "done": "Thursday reminder set", "title": "Mail Mom's card", "start": "2026-10-29T08:00", "end": "",
                    "account": "", "message_id": "", "text": "", "url": "",
                ],
                [
                    "kind": "hold", "label": "Hold Tue 7:30 PM: call Mom", "detail": "Private hold", "done": "Tuesday call held",
                    "title": "Call Mom", "start": "2026-11-03T19:30", "end": "2026-11-03T20:00", "account": "", "message_id": "",
                    "text": "", "url": "",
                ],
                [
                    "kind": "hold", "label": "Hold on Robin's calendar", "detail": "", "done": "", "title": "Dinner",
                    "start": "2026-11-03T19:30", "end": "2026-11-03T21:00", "account": "robin", "message_id": "", "text": "", "url": "",
                ],
                [
                    "kind": "event", "label": "Add the fair", "detail": "", "done": "", "title": "Fair", "start": "2026-11-07T15:00",
                    "end": "2026-11-07T10:00", "account": "", "message_id": "", "text": "", "url": "",
                ],
                [
                    "kind": "link", "label": "Find a kneeler", "detail": "", "done": "", "title": "", "start": "", "end": "",
                    "account": "", "message_id": "", "text": "", "url": "http://shop.example/kneeler",
                ],
                [
                    "kind": "note", "label": "Draft the card note", "detail": "You copy it by hand", "done": "card note drafted",
                    "title": "", "start": "", "end": "", "account": "", "message_id": "", "text": "Happy birthday, Mom!", "url": "",
                ],
            ]
        ]
        let (proposals, problems) = AskProposal.parse(input, household: household, now: Fixtures.now)
        #expect(proposals.map(\.kind) == [.remind, .hold, .note])
        #expect(proposals[0].start == Fixtures.at("2026-10-29T08:00"))
        // A hold with no account goes on the owner's main calendar.
        #expect(proposals[1].account == "work")
        #expect(problems.count == 3)
        #expect(problems[0].contains("own accounts"))
        #expect(problems[1].contains("end must come after"))
        #expect(problems[2].contains("https"))
        let receipt = AskProposal.receipt(proposals, problems: problems, owner: "Sam")
        #expect(receipt.hasPrefix("Shown to Sam for approval: Remind me Thursday"))
        #expect(receipt.contains("Left out: Step 3 (hold)"))
    }

    @Test func repliesGoOnlyFromTheOwnersAccounts() {
        func reply(_ account: String) -> JSONValue {
            [
                "actions": [
                    [
                        "kind": "reply", "label": "Reply to Dana", "detail": "", "done": "", "title": "", "start": "", "end": "",
                        "account": .string(account), "message_id": "m1", "text": "Tuesday works.", "url": "",
                    ]
                ]
            ]
        }
        #expect(AskProposal.parse(reply("work"), household: household, now: Fixtures.now).proposals.count == 1)
        #expect(AskProposal.parse(reply("kid"), household: household, now: Fixtures.now).proposals.isEmpty)
        let link: JSONValue = [
            "actions": [
                [
                    "kind": "link", "label": "Find a kneeler", "detail": "", "done": "", "title": "", "start": "", "end": "",
                    "account": "", "message_id": "", "text": "", "url": "https://shop.example/search?q=garden+kneeler",
                ]
            ]
        ]
        #expect(AskProposal.parse(link, household: household, now: Fixtures.now).proposals.first?.url?.host == "shop.example")
    }

    @Test func outcomesTellClaudeWhatHappened() {
        let remind = AskProposal(id: "p1", kind: .remind, label: "Remind me Thursday")
        let hold = AskProposal(id: "p2", kind: .hold, label: "Hold Tuesday")
        #expect(
            AskOutcome.text(ran: [remind], skipped: [hold], failed: [], undone: false) == "Done: Remind me Thursday. Not run: Hold Tuesday."
        )
        #expect(AskOutcome.text(ran: [], skipped: [], failed: [], undone: false) == "The owner hasn't run any of them.")
        #expect(AskOutcome.text(ran: [remind], skipped: [], failed: [], undone: true).contains("undid"))
    }

    @Test func theAgendaReadsLikeADayPlanner() {
        let agenda = Agenda(events: Fixtures.week, household: household)
        let outcome = AskFormat.agenda(
            agenda, from: Fixtures.at("2026-10-26T00:00"), through: Fixtures.at("2026-10-26T00:00"), fmt: fmt)
        #expect(outcome.text.hasPrefix("Monday, October 26\n"))
        #expect(outcome.text.contains("Robin is busy: book club [robin] (busy only)"))
        #expect(outcome.trace.hasSuffix("Oct 26 · \(outcome.text.components(separatedBy: "\n- ").count - 1) events"))
    }

    @Test func searchResultsCarryTheIdsAReplyNeeds() {
        let items = Array(Fixtures.inbox.prefix(2))
        let outcome = AskFormat.search(items, problems: [], query: "from:dana", account: "all", fmt: fmt)
        #expect(outcome.text.hasPrefix("2 messages, newest first:"))
        #expect(outcome.text.contains("message \(items[0].id) · thread \(items[0].threadId)"))
        #expect(outcome.trace == "account: all · from:dana · 2 messages")
    }

    @Test func peopleComeWithTheirNextBirthday() {
        let mom = PersonCard(
            name: "Carol Rivera", nickname: "Mom", relation: "mother", birthdayMonth: 11, birthdayDay: 3, birthdayYear: 1956,
            city: "Springfield", emails: ["carol@example.com"], note: "Likes cards by mail")
        #expect(mom.matches("mom"))
        #expect(mom.matches("Carol"))
        #expect(mom.matches("mother"))
        #expect(!mom.matches("Robin"))
        let outcome = AskFormat.people([mom], query: "Mom", now: Fixtures.now, fmt: fmt)
        #expect(outcome.text.contains("Birthday: Tue, Nov 3, turning 70"))
        #expect(outcome.trace == "Mom · birthday Tue, Nov 3 · Springfield")
        #expect(AskFormat.people([], query: "Zed", now: Fixtures.now, fmt: fmt).trace == "Zed · not found")
    }

    @Test func freeTimeGroupsByDay() {
        let windows = [
            DateInterval(start: Fixtures.at("2026-10-27T09:00"), end: Fixtures.at("2026-10-27T10:30")),
            DateInterval(start: Fixtures.at("2026-10-27T13:00"), end: Fixtures.at("2026-10-27T17:00")),
            DateInterval(start: Fixtures.at("2026-11-02T18:00"), end: Fixtures.at("2026-11-02T22:00")),
        ]
        let outcome = AskFormat.freeTime(
            windows, from: Fixtures.at("2026-10-27T00:00"), through: Fixtures.at("2026-11-02T00:00"), part: "any", fmt: fmt)
        #expect(outcome.text == "Tue, Oct 27: 9:00–10:30 AM, 1:00–5:00 PM\nMon, Nov 2: 6:00–10:00 PM")
        #expect(outcome.trace == "Oct 27–Nov 2 · any · 3 windows")
    }
}

@Suite("Tool loop: turn-ending tools")
struct TerminalToolTests {
    struct Box: ClaudeToolbox {
        var tools: [ClaudeTool] { AskPrompt.tools(accounts: ["home"]) }
        func run(_ call: ToolUse) async -> ToolOutcome { ToolOutcome(text: "ok", trace: call.name) }
    }

    @Test func proposingEndsTheRunWithResultsOwed() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.streamed(
                [
                    ["type": "tool_use", "id": "toolu_1", "name": "agenda", "input": ["from": "2026-11-03", "to": "2026-11-03"]]
                ], stopReason: "tool_use"),
            ScriptedTransport.streamed(
                [
                    ["type": "text", "text": "Here's a plan."],
                    ["type": "tool_use", "id": "toolu_2", "name": "propose_actions", "input": ["actions": []]],
                ], stopReason: "tool_use"),
        ])
        let loop = ToolLoop(client: ClaudeClient(apiKey: "k", transport: transport, pause: { _ in }))
        var traces: [String] = []
        var transcript: [ClaudeMessage] = []
        let request = ClaudeRequest(model: .opus, messages: [.user("Plan Tuesday")])
        for try await event in loop.run(request, toolbox: Box(), terminal: [AskTool.proposeActions]) {
            if case .toolFinished(_, let outcome) = event { traces.append(outcome.trace) }
            if case .done(_, let t) = event { transcript = t }
        }
        #expect(traces == ["agenda", "propose_actions"])
        #expect(transport.requests.count == 2)
        // The run stops on Claude's proposal; its result goes with the next question.
        #expect(transcript.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(transcript.last?.content.last?.toolUse?.name == "propose_actions")
    }
}
