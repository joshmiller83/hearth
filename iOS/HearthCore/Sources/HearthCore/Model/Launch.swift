import Foundation
import HearthKit
import HearthKitTestSupport

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Writes the widgets' snapshot to the App Group and asks WidgetKit to redraw.
public struct WidgetCenterPublisher: WidgetPublishing {
    public let file: WidgetSnapshotFile

    public init(file: WidgetSnapshotFile) {
        self.file = file
    }

    public func publish(_ snapshot: WidgetSnapshot) {
        try? file.write(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

extension AppServices {
    /// The real thing: Keychain, the App Group database, EventKit, the relay over HTTPS.
    public static func live(appGroup: String?, keychainGroup: String?) throws -> AppServices {
        let directory = AppDatabase.directory(appGroup: appGroup)
        let transport = URLSessionTransport()
        return AppServices(
            secrets: KeychainSecretStore(accessGroup: keychainGroup),
            database: try AppDatabase.open(directory: directory),
            calendar: EventKitCalendar(),
            people: ContactsDirectory(),
            makeRelay: { RelayClient(credentials: $0, transport: transport) },
            makeClaude: { ClaudeClient(apiKey: $0, transport: transport) },
            widgets: WidgetCenterPublisher(file: WidgetSnapshotFile(directory: directory)),
            inbox: .inAppGroup(appGroup)
        )
    }

    /// The fictional Rivera household on the design's Monday, offline: for UI
    /// tests, previews and screenshots. Actions "succeed" instantly.
    public static func fixtures(now: Date = Fixtures.now, waits: Bool = true) -> AppServices {
        let relay = FixtureRelay()
        let wait: @Sendable (TimeInterval) async -> Void
        if waits {
            wait = { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        } else {
            wait = { _ in }
        }
        let database = try! AppDatabase.inMemory()
        var robin = Person(card: Fixtures.people[1], isPartner: true)
        robin.anniversary = MonthDay(month: 11, day: 14, year: 2012)
        try? database.save([robin, Person(card: Fixtures.people[0])], key: StoreKey.people, now: now)
        try? database.save(PartnerPlan(loves: ["Thai food", "Mystery novels"]), key: StoreKey.partnerPlan, now: now)
        return AppServices(
            secrets: MemorySecretStore([.relayURL: "https://relay.example", .relayKey: "hrk_fixture", .claudeKey: "sk-ant-fixture"]),
            database: database,
            calendar: FixtureCalendar(),
            people: FixturePeople(),
            clock: ManualClock(now),
            makeRelay: { _ in relay },
            makeClaude: { ClaudeClient(apiKey: $0, transport: FixtureClaude(), pause: { _ in }) },
            inbox: SharedInbox(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("hearth-inbox-\(UUID().uuidString)")),
            wait: wait
        )
    }
}

/// A relay that answers from the fixtures.
public actor FixtureRelay: RelayAPI {
    private var sent: [ApprovedAction] = []

    public init() {}

    public var submitted: [ApprovedAction] { sent }

    public func health() async throws -> HealthResponse {
        HealthResponse(
            status: "ok", version: "fixture", commit: "fixture", now: Fixtures.now,
            gmailkit: BridgeStatus(state: .up, since: Fixtures.now), accounts: Fixtures.accounts, household: Fixtures.household,
            jobs: [
                JobStatus(
                    name: "calendar", lastRun: Fixtures.now.addingTimeInterval(-6 * 60),
                    lastSuccess: Fixtures.now.addingTimeInterval(-6 * 60))
            ],
            claude: true, push: false)
    }

    public func events(from: Date, to: Date, refresh: Bool) async throws -> EventsResponse {
        let google = Fixtures.week.filter { if case .google = $0.source { return true } else { return false } }
        let calendars = Fixtures.accounts.map { CalendarInfo(id: "primary", account: $0.alias, name: $0.name, isPrimary: true) }
        return EventsResponse(events: google, calendars: calendars, fetchedAt: Fixtures.now.addingTimeInterval(-6 * 60))
    }

    public func submit(_ actions: [ApprovedAction]) async throws -> [ActionStatus] {
        sent.append(contentsOf: actions)
        return actions.map { action in
            if let notBefore = action.notBefore, notBefore > action.approvedAt {
                return ActionStatus(id: action.id, kind: action.kind, state: .pending, notBefore: notBefore, updatedAt: Fixtures.now)
            }
            var result: JSONValue?
            if case .createHold = action.kind { result = ["event_id": .string("hold-" + action.id.prefix(8)), "calendar_id": "primary"] }
            return ActionStatus(id: action.id, kind: action.kind, state: .done, updatedAt: Fixtures.now, result: result)
        }
    }

    public func statuses(ids: [String]) async throws -> [ActionStatus] {
        sent.filter { ids.contains($0.id) }.map { ActionStatus(id: $0.id, kind: $0.kind, state: .done, updatedAt: Fixtures.now) }
    }

    public func cancel(id: String) async throws -> ActionStatus {
        guard let action = sent.first(where: { $0.id == id }) else { throw RelayError.http(status: 404, reason: "No such action.") }
        return ActionStatus(id: id, kind: action.kind, state: .cancelled, updatedAt: Fixtures.now)
    }

    public func uploadContext(_ context: PhoneContext) async throws {}

    public func mailSnapshot(refresh: Bool) async throws -> MailSnapshot {
        let triaged = Fixtures.inbox.map { item in
            MailRules.classify(item, rules: MailRules.defaults, labelNames: [:], now: Fixtures.now)
                ?? TriagedMail(item: item, queue: .reply, tag: "Needs you", reason: "Someone wrote to you", sortedBy: .claude)
        }
        return MailSnapshot(
            generatedAt: Fixtures.now.addingTimeInterval(-6 * 60), accounts: Fixtures.accounts.map(\.alias),
            items: triaged, newCount: triaged.count, jobHuntLabels: ["work": "Label_7"])
    }

    public func brief() async throws -> Brief? {
        Brief(
            generatedAt: Fixtures.now.addingTimeInterval(-3 * 3600), day: "2026-10-26",
            headline: "Two invites and two replies need you. The rest can wait.",
            order: ["g:work:primary:huddle", "work:m1", "g:school:primary:mixer", "home:m2"],
            kindIdea: "Thursday evening is free for you both. Robin mentioned the new Thai place.", kindIdeaFor: "Robin")
    }

    public func registerDevice(_ registration: DeviceRegistration) async throws {}

    public func signals() async throws -> RelaySignals {
        let frost = Signal(
            id: "wx:frost:2026-10-26", category: .family, monogram: "WX", source: "National Weather Service",
            date: Fixtures.now.addingTimeInterval(-2 * 3600), title: "Frost tonight, low of 29°F",
            detail: "Maple Grove. Cover anything tender before sundown.",
            actions: [.remind(label: "Remind me at 5", title: "Cover the tender plants", at: Fixtures.at("2026-10-26T17:00"))])
        return RelaySignals(signals: [frost], fetchedAt: Fixtures.now.addingTimeInterval(-10 * 60))
    }

    public func searchMail(_ search: GmailSearchRequest) async throws -> GmailSearchResponse {
        let words = search.query.lowercased().split(separator: " ").compactMap { $0.split(separator: ":").last.map(String.init) }
            .filter { !$0.hasSuffix("d") || Int($0.dropLast()) == nil }
        let hits = (Fixtures.inbox + Fixtures.archived).filter { item in
            (search.account == "all" || item.account == search.account)
                && words.contains { (item.from + " " + item.subject + " " + item.snippet).lowercased().contains($0) }
        }
        return GmailSearchResponse(messages: Array(hits.sorted { $0.date > $1.date }.prefix(search.limit)))
    }

    public func thread(account: String, threadId: String) async throws -> ThreadResponse {
        let item = Fixtures.inbox.first { $0.threadId == threadId }
        let body =
            "Hi Sam,\n\nThanks again for Friday. The team enjoyed hearing about your work. Next step is a 90-minute panel with engineering and product. Could you send a few windows Wednesday through Friday this week?\n\nBest,\nDana"
        return ThreadResponse(
            account: account, threadId: threadId,
            messages: [
                ThreadMessage(
                    id: item?.id ?? "m1", from: item?.from ?? "Dana Whitfield <dana@northbeam.example>",
                    to: "sam@rivera.example", date: item?.date ?? Fixtures.now, subject: item?.subject ?? "Next steps", body: body)
            ])
    }
}

/// Apple calendars from the fixtures; writes are kept in memory so tests can check them.
public final class FixtureCalendar: AppleCalendar, @unchecked Sendable {
    private struct State {
        var events: [String: EventDraft] = [:]
        var reminders: [String: ReminderDraft] = [:]
        var counter = 0
    }

    private let lock = NSLock()
    private var state = State()

    public init() {}

    /// Runs `body` with the state locked (synchronously: locks can't be held across awaits).
    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    public var events: [EventDraft] { locked { $0.events.sorted { $0.key < $1.key }.map(\.value) } }
    public var reminders: [ReminderDraft] { locked { $0.reminders.sorted { $0.key < $1.key }.map(\.value) } }

    public func add(_ drafts: [EventDraft], to calendarId: String) async throws -> [String] {
        locked { state in
            drafts.map { draft in
                state.counter += 1
                let id = "ev\(state.counter)"
                state.events[id] = draft
                return id
            }
        }
    }

    public func removeEvents(_ ids: [String]) async throws {
        locked { state in for id in ids { state.events[id] = nil } }
    }

    public func remindersAccess() -> CalendarAccess { .full }
    public func requestRemindersAccess() async -> CalendarAccess { .full }

    public func add(_ reminders: [ReminderDraft]) async throws -> [String] {
        locked { state in
            reminders.map { draft in
                state.counter += 1
                let id = "rem\(state.counter)"
                state.reminders[id] = draft
                return id
            }
        }
    }

    public func removeReminders(_ ids: [String]) async throws {
        locked { state in for id in ids { state.reminders[id] = nil } }
    }

    public func access() -> CalendarAccess { .full }
    public func requestAccess() async -> CalendarAccess { .full }

    public func calendars() async -> [AppleCalendarInfo] {
        [
            AppleCalendarInfo(id: "family", title: "Family", source: "iCloud", isICloud: true),
            AppleCalendarInfo(id: "birthdays", title: "Birthdays", source: "Other", isICloud: false, isBirthdays: true),
        ]
    }

    public func events(from: Date, to: Date, calendarIds: Set<String>?) async -> [AgendaEvent] {
        Fixtures.week.filter { $0.source.isApple && $0.start < to && $0.end >= from }
    }

    public func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// Claude, faked for fixture runs: a note about the dentist, a flyer for a craft
/// fair, or (for anything else) a single plain event, read instantly.
public struct FixtureClaude: HTTPTransport {
    public init() {}

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = request.body.flatMap { try? JSONValue.parse($0) }
        let properties = body?["output_config"]?["format"]?["schema"]?["properties"]
        if properties?["ideas"] != nil { return Self.reply(Self.peopleIdeas.serialized()) }
        if properties?["plans"] != nil { return Self.reply(Self.partnerPlans.serialized()) }
        let content = body?["messages"]?[0]?["content"]?.arrayValue ?? []
        let text = content.compactMap { $0["text"]?.stringValue }.joined(separator: " ").lowercased()
        let hasImage = content.contains { $0["type"]?.stringValue == "image" }
        if body?["output_config"]?["format"]?["schema"]?["properties"]?["offeredSlots"] != nil {
            let shorter = text.contains("as short as it can be")
            let draft = DraftPrompt.Draft(
                body: shorter
                    ? "Hi Dana,\n\nGlad to. Any of these work (Eastern):\n\n• Tue, Oct 27 · 9:00–10:30 AM\n• Wed, Oct 28 · 1:00–2:30 PM\n\nSam"
                    : "Hi Dana,\n\nThanks, I enjoyed Friday too. Any of these 90-minute windows work on my end (Eastern):\n\n• Tue, Oct 27 · 9:00–10:30 AM\n• Wed, Oct 28 · 1:00–2:30 PM\n\nHappy to flex if the panel's calendars are tight.\n\nSam",
                offeredSlots: [
                    .init(start: "2026-10-27T09:00", end: "2026-10-27T10:30"), .init(start: "2026-10-28T13:00", end: "2026-10-28T14:30"),
                ],
                lookedAt: ["Free time across every calendar, Tue–Wed", "Dana's message"])
            return Self.reply(String(decoding: try HearthJSON.encode(draft), as: UTF8.self))
        }
        let reading: CaptureReading
        if hasImage {
            reading = CaptureReading(
                summary: "A flyer for the Fall Craft Fair on Sat, Nov 7.",
                entries: [
                    CaptureEntry(
                        id: "e1", title: "Fall craft fair", date: "2026-11-07", startTime: "10:00", endTime: "15:00",
                        location: "Community center, main gym", notes: "Vendor tables: 555-0134", cost: "Free",
                        source: "Fall Craft Fair · Saturday, Nov. 7 · 10 AM – 3 PM")
                ])
        } else if text.contains("dentist") {
            reading = CaptureReading(
                summary: "A dentist appointment for Robin on Thursday.",
                entries: [
                    CaptureEntry(
                        id: "e1", title: "Robin: dentist", date: "2026-10-29", startTime: "15:00", person: "Robin",
                        confidence: .high, guesses: ["One hour is a guess"], source: "dentist for robin thurs 3pm")
                ])
        } else {
            reading = CaptureReading(
                summary: "One plan.",
                entries: [
                    CaptureEntry(id: "e1", title: "Plan", date: "2026-10-27", startTime: "18:00", source: text)
                ])
        }
        return Self.reply(String(decoding: try HearthJSON.encode(reading), as: UTF8.self))
    }

    static func reply(_ text: String) -> HTTPResponse {
        let message: JSONValue = [
            "id": "msg_fixture", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
            "content": [["type": "text", "text": .string(text)]],
            "stop_reason": "end_turn", "usage": ["input_tokens": 900, "output_tokens": 120],
        ]
        return HTTPResponse(status: 200, body: message.data)
    }

    /// Ask's conversations, streamed: a birthday to plan, or a look at the week.
    public func streamLines(_ request: HTTPRequest) async throws -> HTTPLineStream {
        let messages = request.body.flatMap { try? JSONValue.parse($0) }?["messages"]?.arrayValue ?? []
        let last = messages.last?["content"]?.arrayValue ?? []
        let question = last.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined().lowercased()
        let reply: ScriptedTransport.Reply
        if !question.isEmpty {
            reply = question.contains("birthday") ? Self.birthdayLookup : Self.weekLookup
        } else {
            // Tool results: answer the round that asked for them.
            let asked = messages.dropLast().last?["content"]?.arrayValue ?? []
            let names = asked.compactMap { $0["type"]?.stringValue == "tool_use" ? $0["name"]?.stringValue : nil }
            reply = names.contains(AskTool.peopleGet) ? Self.birthdayPlan : Self.weekAnswer
        }
        guard case .stream(let status, let lines) = reply else { throw TransportError("No fixture reply.") }
        return HTTPLineStream(
            status: status,
            lines: AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            })
    }

    static let birthdayLookup = ScriptedTransport.streamed(
        [
            ["type": "thinking", "thinking": "Her birthday, her recent mail, and the days around it.", "signature": "fixture"],
            ["type": "tool_use", "id": "toolu_people", "name": "people_get", "input": ["name": "Mom"]],
            [
                "type": "tool_use", "id": "toolu_search", "name": "gmail_search",
                "input": ["query": "from:carol newer_than:60d", "account": "all", "limit": 10],
            ],
            ["type": "tool_use", "id": "toolu_agenda", "name": "agenda", "input": ["from": "2026-11-01", "to": "2026-11-04"]],
        ], stopReason: "tool_use")

    static let birthdayPlan = ScriptedTransport.streamed(
        [
            [
                "type": "text",
                "text": .string(
                    "Here’s a plan. Her birthday is Tuesday, Nov 3, and a card has to go in the mail by Thursday to get there in time.\n\n"
                        + "In her Oct 12 email she said her old garden kneeler finally gave out, so that’s an easy gift. "
                        + "Tuesday you’re free after 7, and she’s said evenings after 7 are best for a call."),
            ],
            [
                "type": "tool_use", "id": "toolu_propose", "name": "propose_actions",
                "input": [
                    "actions": [
                        step(
                            "note", "Draft the birthday card note", "From her last few emails. You copy it by hand.", "card note drafted",
                            text:
                                "Happy birthday, Mom! I hope the tulips come up beautifully, and that the new kneeler saves your knees. Love you."
                        ),
                        step(
                            "remind", "Remind me Thursday, 8 AM: mail the card", "Lands on your phone, not a shared calendar",
                            "Thursday reminder set", title: "Mail Mom's birthday card", start: "2026-10-29T08:00"),
                        step(
                            "hold", "Hold Tue, Nov 3, 7:30 PM: call Mom", "Private hold on work · nothing sent to anyone",
                            "Tuesday call held", title: "Call Mom", start: "2026-11-03T19:30", end: "2026-11-03T20:00"),
                        step(
                            "link", "Find a garden kneeler, delivered by Nov 3", "Opens a store search. You check out.",
                            "store search ready", url: "https://shop.example/search?q=garden+kneeler"),
                    ]
                ],
            ],
        ], stopReason: "tool_use")

    static let weekLookup = ScriptedTransport.streamed(
        [["type": "tool_use", "id": "toolu_week", "name": "agenda", "input": ["from": "2026-10-26", "to": "2026-11-01"]]],
        stopReason: "tool_use")

    static let weekAnswer = ScriptedTransport.streamed(
        [
            [
                "type": "text",
                "text":
                    "Two invites are waiting on you: the leaders huddle Thursday, which overlaps Bible study, and the alumni mixer Wednesday.\n\nEverything else this week can wait.",
            ]
        ], stopReason: "end_turn")

    static let peopleIdeas: JSONValue = [
        "ideas": [
            [
                "person": "Mom", "source": "Mom's birthday is Tuesday", "title": "Call Mom Tuesday evening",
                "body": "Tuesday after 7 is open, and a call lands better than a text on a birthday.",
                "actions": [
                    step(
                        "hold", "Hold Tue 7:30 PM", "Private hold · nothing sent to anyone", "Tuesday call held", title: "Call Mom",
                        start: "2026-11-03T19:30", end: "2026-11-03T20:00")
                ],
            ],
            [
                "person": "Mom", "source": "From Mom's Oct 12 email", "title": "A new garden kneeler",
                "body": "The old one finally gave out. One that arrives by Tuesday would make the day.",
                "actions": [
                    step(
                        "link", "Find a kneeler", "Opens a store search. You check out.", "store search ready",
                        url: "https://shop.example/search?q=garden+kneeler")
                ],
            ],
            [
                "person": "Robin", "source": "Robin's Wednesday looks full", "title": "A note for Robin's long Wednesday",
                "body": "Three meetings back to back. A short note at lunch is enough.",
                "actions": [
                    step(
                        "remind", "Nudge me Wed 11:55 AM", "Lands on your phone", "Wednesday nudge set", title: "Send Robin a note",
                        start: "2026-10-28T11:55"),
                    step(
                        "note", "Draft a note", "You send it yourself", "note drafted",
                        text: "Thinking of you on the long day. Dinner's on me tonight."),
                ],
            ],
        ]
    ]

    static let partnerPlans: JSONValue = [
        "plans": [
            [
                "tag": "From your list: Thai food", "title": "Thai dinner downtown",
                "sub": "7:00 PM, a table for two. A walk after if it's mild.",
                "short": "the Thai dinner", "start": "19:00", "minutes": 150,
            ],
            [
                "tag": "Needs one detail from you", "title": "Recreate your first date",
                "sub": "Tell Hearth where it was, and Claude handles the rest.", "short": "your first date, again", "start": "18:30",
                "minutes": 180,
            ],
            [
                "tag": "Low-key", "title": "A night in, done properly",
                "sub": "Cook together, a mystery to read aloud, phones in a drawer.",
                "short": "a night in", "start": "18:00", "minutes": 180,
            ],
        ]
    ]

    static func step(
        _ kind: String, _ label: String, _ detail: String, _ done: String, title: String = "", start: String = "", end: String = "",
        text: String = "", url: String = ""
    ) -> JSONValue {
        [
            "kind": .string(kind), "label": .string(label), "detail": .string(detail), "done": .string(done), "title": .string(title),
            "start": .string(start), "end": .string(end), "account": "", "message_id": "", "text": .string(text), "url": .string(url),
        ]
    }
}
