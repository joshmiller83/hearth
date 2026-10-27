import Fluent
import Foundation
import HearthKit
import Logging
import RelayCore

/// Every 6 hours: each calendar feed is fetched and read. On Mondays (and when
/// a feed is new) the relay's Claude reads the pages and weekly emails that
/// have no feed. Only public https addresses are fetched.
public struct FeedsJob: RelayJob {
    public static let window: TimeInterval = 60 * 86400
    public static let maxBytes = 2_000_000

    public let name = "feeds"
    public let schedule = JobSchedule.every(6 * 3600)

    public init() {}

    public func run(_ context: JobContext) async throws {
        let feeds = try await FeedStore(context.cache).feeds()
        let monday = context.household.fmt.calendar.component(.weekday, from: context.now()) == 2
        for feed in feeds where feed.kind == .ical || monday || feed.checkedAt == nil {
            try await Self.check(feed.id, context)
        }
    }

    /// Reads one feed now and stores what it holds.
    public static func check(_ id: String, _ context: JobContext) async throws {
        let store = FeedStore(context.cache)
        guard let feed = try await store.feeds().first(where: { $0.id == id }) else { return }
        let now = context.now()
        let household = context.household
        var events: [FeedEvent] = []
        var problem: String?
        do {
            switch feed.kind {
            case .ical:
                guard let url = feed.url, let http = context.http else { throw FeedError.noAddress }
                events = try await calendar(url, feedId: feed.id, http: http, zone: household.zone, now: now).events
            case .page:
                guard let url = feed.url, let http = context.http else { throw FeedError.noAddress }
                guard let claude = context.claude else { throw FeedError.noClaude }
                let html = try await fetch(url, accept: "text/html", http: http)
                events = try await read(
                    PageEventsPrompt.text(fromHTML: html), source: url.absoluteString, feed: feed, claude: claude, context: context)
            case .email:
                guard let from = feed.from, !from.isEmpty else { throw FeedError.noAddress }
                guard let claude = context.claude else { throw FeedError.noClaude }
                let rows = try await context.google.search(
                    query: "from:\(from) newer_than:10d", account: "all", limit: 3, metadataOnly: false)
                guard let newest = rows.filter({ $0.error == nil }).max(by: { ($0.date ?? "") < ($1.date ?? "") }),
                    let thread = newest.thread_id
                else { throw FeedError.nothingNew }
                let messages = try await context.google.thread(id: thread, account: newest.account)
                let text = messages.compactMap { $0.body_text ?? $0.snippet }.joined(separator: "\n\n")
                events = try await read(text, source: "an email from \(from)", feed: feed, claude: claude, context: context)
            }
        } catch {
            problem = (error as? FeedError)?.description ?? "couldn't read it (\(error))"
        }
        try await store.replaceEvents(of: feed.id, with: problem == nil ? events : nil, now: now)
        let kept = events.filter(feed.keeps).count
        try await store.update(feed.id, now: now) { feed in
            feed.checkedAt = now
            feed.problem = problem
            if problem == nil {
                feed.total = events.count
                feed.kept = kept
            }
        }
        context.logger.info("feeds: \(feed.name): \(problem ?? "\(kept) of \(events.count) kept")")
    }

    /// A calendar feed's name and its next 60 days.
    public static func calendar(_ url: URL, feedId: String, http: any HTTPTransport, zone: TimeZone, now: Date) async throws
        -> (name: String?, events: [FeedEvent])
    {
        let text = try await fetch(url, accept: "text/calendar", http: http)
        guard text.contains("BEGIN:VCALENDAR") else { throw FeedError.notACalendar }
        return (ICS.calendarName(text), ICS.events(text, feedId: feedId, zone: zone, from: now, to: now.addingTimeInterval(window)))
    }

    static func fetch(_ url: URL, accept: String, http: any HTTPTransport) async throws -> String {
        guard let safe = FeedAddress.safe(url) else { throw FeedError.notPublic }
        let request = HTTPRequest(url: safe, headers: ["User-Agent": WeatherJob.userAgent, "Accept": accept], timeout: 30)
        let response = try await http.send(request)
        guard response.status == 200 else { throw FeedError.status(response.status) }
        guard response.body.count <= maxBytes else { throw FeedError.tooBig }
        return String(decoding: response.body, as: UTF8.self)
    }

    static func read(_ text: String, source: String, feed: Feed, claude: ClaudeClient, context: JobContext) async throws -> [FeedEvent] {
        let now = context.now()
        let request = PageEventsPrompt.request(text: text, source: source, household: context.household, now: now)
        let (reply, _) = try await claude.structured(request, as: PageEventsPrompt.Reply.self)
        return PageEventsPrompt.events(reply, feedId: feed.id, zone: context.household.zone, from: now, to: now.addingTimeInterval(window))
    }
}

public enum FeedError: Error, Equatable, Sendable, CustomStringConvertible {
    case noAddress
    case notPublic
    case notACalendar
    case noClaude
    case nothingNew
    case tooBig
    case status(Int)

    public var description: String {
        switch self {
        case .noAddress: "it has no address"
        case .notPublic: "only public https addresses can be fetched"
        case .notACalendar: "that address isn't a calendar feed"
        case .noClaude: "reading it needs the relay's Claude key"
        case .nothingNew: "no email from it in the last 10 days"
        case .tooBig: "it's over 2 MB"
        case .status(let code): "the site answered \(code)"
        }
    }
}

/// The feeds and their events, in the relay's cache. Each change re-reads the
/// list first, so a feed added while a check runs isn't lost.
public struct FeedStore: Sendable {
    let cache: Cache

    public init(_ cache: Cache) {
        self.cache = cache
    }

    public func feeds() async throws -> [Feed] { try await cache.get([Feed].self, Cache.feeds) ?? [] }

    public func events() async throws -> [FeedEvent] { try await cache.get([FeedEvent].self, Cache.feedEvents) ?? [] }

    public func add(_ feed: Feed, now: Date) async throws {
        try await cache.set(try await feeds() + [feed], Cache.feeds, now: now)
    }

    public func remove(_ id: String, now: Date) async throws {
        try await cache.set(try await feeds().filter { $0.id != id }, Cache.feeds, now: now)
        try await cache.set(try await events().filter { $0.feedId != id }, Cache.feedEvents, now: now)
    }

    public func update(_ id: String, now: Date, _ change: (inout Feed) -> Void) async throws {
        var all = try await feeds()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        try await cache.set(all, Cache.feeds, now: now)
    }

    /// Swaps in a feed's events; nil keeps the last good ones.
    public func replaceEvents(of id: String, with events: [FeedEvent]?, now: Date) async throws {
        guard let events else { return }
        let others = try await self.events().filter { $0.feedId != id && $0.end > now }
        try await cache.set((others + events).sorted { $0.start < $1.start }, Cache.feedEvents, now: now)
    }

    /// What the phone shows: every feed, and the kept events still ahead.
    public func response(now: Date) async throws -> FeedsResponse {
        let feeds = try await feeds()
        let byId = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        let events = try await events().filter { event in
            guard let feed = byId[event.feedId] else { return false }
            return event.end > now && feed.keeps(event)
        }
        return FeedsResponse(feeds: feeds, events: events)
    }
}
