import Foundation
import HearthKit
import Observation

/// Around town: events from the feeds the relay follows, matched to the
/// evenings and weekends the owner and their partner both have open; and the
/// chat where Claude finds new feeds.
@MainActor
@Observable
public final class TownModel {
    public enum Filter: Hashable, Sendable {
        case forYouTwo
        case category(String)
        case free
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case working
        case failed(String)
    }

    public struct ChatLine: Identifiable, Equatable, Sendable {
        public let id: Int
        public var fromOwner: Bool
        public var text: String
    }

    let services: AppServices
    weak var app: AppModel?

    public private(set) var feeds: [Feed]
    public private(set) var events: [FeedEvent]
    public private(set) var problem: String?
    public var filter: Filter = .forYouTwo
    /// Events put on the family calendar from here: feed event → calendar event.
    private(set) var added: [String: String]

    public private(set) var chat: [ChatLine] = []
    public private(set) var chatPhase: Phase = .idle
    public private(set) var proposal: FeedChatPrompt.Proposal?
    /// After "Add": the new feed, for Undo, and what was added.
    public private(set) var addedFeed: (id: String, note: String)?
    public var draft = ""
    private(set) var transcript: [ClaudeMessage] = []
    /// propose_feed calls awaiting their result, and what became of them.
    private var owed: [String] = []
    private var outcome = "The owner hasn't decided yet."

    init(services: AppServices) {
        self.services = services
        let cached = services.database.load(FeedsResponse.self, key: StoreKey.feeds)
        feeds = cached?.feeds ?? []
        events = cached?.events ?? []
        added = services.database.load([String: String].self, key: StoreKey.townAdded) ?? [:]
    }

    var now: Date { services.clock.now }
    var household: Household { app?.household ?? .placeholder }

    public func refresh() async {
        guard let relay = app?.relay else { return }
        do {
            apply(try await relay.feeds())
            problem = nil
        } catch {
            problem = (error as? RelayError)?.description ?? String(describing: error)
        }
    }

    func apply(_ response: FeedsResponse) {
        feeds = response.feeds
        events = response.events.filter { $0.end > now }.sorted { $0.start < $1.start }
        try? services.database.save(response, key: StoreKey.feeds, now: now)
    }

    // MARK: Around town

    public func feed(_ event: FeedEvent) -> Feed? { feeds.first { $0.id == event.feedId } }

    /// The chips: "For you two", each category the feeds have, "Free".
    public var chips: [(filter: Filter, label: String)] {
        var categories: [String] = []
        for feed in feeds where !categories.contains(feed.category) { categories.append(feed.category) }
        return [(.forYouTwo, "For you two")] + categories.map { (.category($0), $0.prefix(1).uppercased() + $0.dropFirst()) } + [
            (.free, "Free")
        ]
    }

    /// An evening or a weekend, with nothing on anyone's calendar then.
    public func fits(_ event: FeedEvent) -> Bool {
        guard !event.isAllDay else { return false }
        let calendar = household.fmt.calendar
        let weekday = calendar.component(.weekday, from: event.start)
        let evening = calendar.component(.hour, from: event.start) >= 17
        guard evening || weekday == 1 || weekday == 7 else { return false }
        let agenda = app?.plans.agenda.events ?? []
        return !agenda.contains { $0.blocksTime && !$0.isAllDay && $0.start < event.end && $0.end > event.start }
    }

    public var shown: [FeedEvent] {
        events.filter { event in
            switch filter {
            case .forYouTwo: fits(event)
            case .category(let category): feed(event)?.category == category
            case .free: event.free
            }
        }
    }

    /// This weekend's first event that fits, for the big card.
    public var featured: FeedEvent? {
        let calendar = household.fmt.calendar
        return events.first { event in
            let weekday = calendar.component(.weekday, from: event.start)
            return event.start.timeIntervalSince(now) < 7 * 86400 && (weekday == 1 || weekday == 6 || weekday == 7) && fits(event)
        }
    }

    /// "Downtown · 9 AM–12 PM".
    public func place(_ event: FeedEvent) -> String {
        let fmt = household.fmt
        let when = event.isAllDay ? "all day" : fmt.timeRange(event.start, event.end, compact: true)
        return [event.location, when].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Borough events page · free · Thursday evening is open".
    public func why(_ event: FeedEvent) -> String {
        let fmt = household.fmt
        var parts = [feed(event)?.name ?? "A feed"]
        if event.free { parts.append("free") }
        if fits(event) {
            let weekday = fmt.calendar.component(.weekday, from: event.start)
            parts.append(weekday == 1 || weekday == 7 ? "you're both free" : "\(Fmt.weekdaysLong[weekday - 1]) evening is open")
        }
        return parts.joined(separator: " · ")
    }

    public func isAdded(_ event: FeedEvent) -> Bool { added[event.id] != nil }

    /// Puts an event on the family calendar, or takes it back off.
    public func toggle(_ event: FeedEvent) async {
        let calendar = services.calendar
        do {
            if let existing = added[event.id] {
                try await calendar.removeEvents([existing])
                added[event.id] = nil
            } else {
                if calendar.access() != .full, await calendar.requestAccess() != .full { throw CalendarWriteError.noAccess }
                let family = household.familyCalendar.lowercased()
                guard let target = await calendar.calendars().first(where: { $0.title.lowercased() == family && $0.allowsModifications })
                else { throw CalendarWriteError.noCalendar(household.familyCalendar) }
                let draft = EventDraft(
                    title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay, location: event.location,
                    notes: "From \(feed(event)?.name ?? "a feed"), via Hearth.")
                if let id = try await calendar.add([draft], to: target.id).first { added[event.id] = id }
            }
            problem = nil
            try? services.database.save(added, key: StoreKey.townAdded, now: now)
            await app?.plans.refreshApple()
        } catch {
            problem = (error as? CalendarWriteError)?.description ?? String(describing: error)
        }
    }

    /// What "Send to …" shares.
    public func shareText(_ event: FeedEvent) -> String {
        let fmt = household.fmt
        let when = event.isAllDay ? fmt.shortDay(event.start) : "\(fmt.shortDay(event.start)), \(fmt.timeRange(event.start, event.end))"
        return "\(event.title): \(when)\(event.location.map { " at \($0)" } ?? ""). Want to go?"
    }

    // MARK: Finding feeds with Claude

    public func send(_ text: String? = nil) async {
        let message = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, chatPhase != .working else { return }
        draft = ""
        chat.append(ChatLine(id: chat.count, fromOwner: true, text: message))
        guard let claude = app?.claude else {
            chatPhase = .failed(ClaudeError.noKey.description)
            return
        }
        chatPhase = .working
        let results: [ContentBlock] = owed.map { .toolResult(id: $0, text: outcome) }
        var request = ClaudeRequest(
            model: .opus, maxTokens: 12_000, system: FeedChatPrompt.system(household: household, feeds: feeds, now: now),
            messages: transcript + [.user(results + [.text(message)])], effort: .medium)
        request.tools = FeedChatPrompt.tools()
        let reply = ChatLine(id: chat.count, fromOwner: false, text: "")
        chat.append(reply)
        var paragraphBreak = false
        do {
            let toolbox = FeedToolbox(relay: app?.relay, fmt: household.fmt)
            for try await event in ToolLoop(client: claude).run(request, toolbox: toolbox, terminal: [FeedChatPrompt.proposeFeed]) {
                switch event {
                case .stream(.textDelta(let text)):
                    if paragraphBreak, !chat[reply.id].text.isEmpty { chat[reply.id].text += "\n\n" }
                    chat[reply.id].text += text
                    paragraphBreak = false
                case .toolFinished(let call, _):
                    paragraphBreak = true
                    if call.name == FeedChatPrompt.proposeFeed {
                        proposal = FeedChatPrompt.proposal(call.input)
                        addedFeed = nil
                    }
                case .done(_, let finished):
                    transcript = finished
                    let last = finished.last
                    let calls = last?.role == .assistant ? (last?.content.compactMap(\.toolUse) ?? []) : []
                    owed = calls.filter { $0.name == FeedChatPrompt.proposeFeed }.map(\.id)
                    outcome = "The owner hasn't decided yet."
                    // Idle in the same step the proposal's buttons appear, so they're never shown disabled.
                    chatPhase = .idle
                default:
                    break
                }
            }
            chatPhase = .idle
        } catch {
            chatPhase = .failed(AskModel.describe(error))
        }
    }

    /// "Add, keep those 3" or "Add all 14".
    public func addProposed(keepAll: Bool) async {
        guard let proposal, let relay = app?.relay else { return }
        var feed = proposal.feed
        if keepAll { feed.skip = [] }
        chatPhase = .working
        do {
            let response = try await relay.addFeed(feed)
            apply(response)
            let made = response.feeds.last { $0.name == feed.name && $0.url == feed.url }
            let kept = made.map { keepAll ? "all \($0.total)" : "\($0.kept) of \($0.total) kept" } ?? ""
            let note = "Added the \(feed.name.lowercased()) feed\(kept.isEmpty ? "" : ", \(kept)")"
            addedFeed = made.map { ($0.id, note) }
            outcome = note + "."
            chatPhase = .idle
        } catch {
            chatPhase = .failed((error as? RelayError)?.description ?? String(describing: error))
        }
    }

    public func undoAdd() async {
        guard let added = addedFeed else { return }
        await remove(added.id)
        addedFeed = nil
        outcome = "The owner added it, then took it back off."
    }

    public func remove(_ id: String) async {
        guard let relay = app?.relay else { return }
        do {
            apply(try await relay.removeFeed(id: id))
        } catch {
            problem = (error as? RelayError)?.description ?? String(describing: error)
        }
    }

    public func startOver() {
        guard chatPhase != .working else { return }
        chat = []
        transcript = []
        owed = []
        proposal = nil
        addedFeed = nil
        chatPhase = .idle
    }
}

/// The feed chat's own tools: previews through the relay; proposals wait for the owner.
struct FeedToolbox: ClaudeToolbox {
    let relay: (any RelayAPI)?
    let fmt: Fmt

    var tools: [ClaudeTool] { FeedChatPrompt.tools() }

    func run(_ call: ToolUse) async -> ToolOutcome {
        switch call.name {
        case FeedChatPrompt.previewFeed:
            guard let relay, let address = call.input["url"]?.stringValue.flatMap(URL.init(string:)) else {
                return ToolOutcome(text: "That isn't an address the relay can read.", isError: true, trace: "preview")
            }
            do {
                return FeedChatPrompt.describe(try await relay.previewFeed(address), fmt: fmt)
            } catch {
                return ToolOutcome(text: "Couldn't read it: \(AskModel.describe(error))", isError: true, trace: "preview failed")
            }
        case FeedChatPrompt.proposeFeed:
            return ToolOutcome(text: "Shown to the owner.", trace: "proposed")
        default:
            return ToolOutcome(text: "There's no tool called \(call.name).", isError: true, trace: "unknown")
        }
    }
}

extension StoreKey {
    public static let feeds = "relay.feeds"
    public static let townAdded = "town.added"
}
