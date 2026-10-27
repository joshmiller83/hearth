import Foundation

/// A source of events around town: a calendar feed the relay fetches each
/// day, a web page Claude reads on Mondays, or a weekly email Claude reads.
public struct Feed: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case ical
        case page
        case email

        /// "iCal", "Page", "Email".
        public var label: String {
            switch self {
            case .ical: "iCal"
            case .page: "Page"
            case .email: "Email"
            }
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// The feed or page, for iCal and Page.
    public var url: URL?
    /// The sender, for Email ("office@church.example" or a domain).
    public var from: String?
    /// "church", "family", "tech": what the chips filter by.
    public var category: String
    /// Words that leave an event out ("fitness", "senior lunch"): what Claude
    /// suggested skipping when the feed was added.
    public var skip: [String]
    public var addedAt: Date
    public var checkedAt: Date?
    /// Events in the next 60 days, and how many of those are kept.
    public var total: Int
    public var kept: Int
    public var problem: String?

    public init(
        id: String = UUID().uuidString, name: String, kind: Kind, url: URL? = nil, from: String? = nil, category: String,
        skip: [String] = [],
        addedAt: Date, checkedAt: Date? = nil, total: Int = 0, kept: Int = 0, problem: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.from = from
        self.category = category
        self.skip = skip
        self.addedAt = addedAt
        self.checkedAt = checkedAt
        self.total = total
        self.kept = kept
        self.problem = problem
    }

    /// Whether an event makes it through the feed's skip words.
    public func keeps(_ event: FeedEvent) -> Bool {
        let text = (event.title + " " + (event.summary ?? "")).lowercased()
        return !skip.contains { !$0.isEmpty && text.contains($0.lowercased()) }
    }

    /// "Calendar feed · 4 of 22 kept".
    public var sub: String {
        let method =
            switch kind {
            case .ical: "Calendar feed"
            case .page: "No feed, so Claude reads it Mondays"
            case .email: "Read from its weekly email"
            }
        if let problem { return method + " · " + problem }
        if checkedAt == nil { return method + " · not checked yet" }
        return method + " · " + (kept == total ? "\(kept) kept" : "\(kept) of \(total) kept")
    }
}

/// One event from a feed.
public struct FeedEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var feedId: String
    public var uid: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var url: URL?
    /// The description's first line.
    public var summary: String?
    /// The listing says it's free.
    public var free: Bool

    public init(
        id: String, feedId: String, uid: String, title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil,
        url: URL? = nil, summary: String? = nil, free: Bool = false
    ) {
        self.id = id
        self.feedId = feedId
        self.uid = uid
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.url = url
        self.summary = summary
        self.free = free
    }
}

/// `GET /v1/feeds`: every feed, and the kept events of the next 60 days.
public struct FeedsResponse: Codable, Hashable, Sendable {
    public var feeds: [Feed]
    public var events: [FeedEvent]

    public init(feeds: [Feed], events: [FeedEvent]) {
        self.feeds = feeds
        self.events = events
    }
}

/// `POST /v1/feeds`.
public struct NewFeed: Codable, Hashable, Sendable {
    public var name: String
    public var kind: Feed.Kind
    public var url: URL?
    public var from: String?
    public var category: String
    public var skip: [String]

    public init(name: String, kind: Feed.Kind, url: URL? = nil, from: String? = nil, category: String, skip: [String] = []) {
        self.name = name
        self.kind = kind
        self.url = url
        self.from = from
        self.category = category
        self.skip = skip
    }
}

/// `POST /v1/feeds/preview`: a calendar feed read once, without adding it.
public struct FeedPreviewRequest: Codable, Hashable, Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }
}

public struct FeedPreview: Codable, Hashable, Sendable {
    public var url: URL
    /// The calendar's own name, when it gives one.
    public var name: String?
    /// The next 60 days.
    public var events: [FeedEvent]

    public init(url: URL, name: String?, events: [FeedEvent]) {
        self.url = url
        self.name = name
        self.events = events
    }
}

public enum FeedAddress {
    /// A web address the relay may fetch: https (webcal becomes https), a public
    /// host name, never this network (localhost, .local, private addresses).
    public static func safe(_ url: URL) -> URL? {
        var text = url.absoluteString
        if text.lowercased().hasPrefix("webcal://") { text = "https://" + text.dropFirst("webcal://".count) }
        guard let normalized = URL(string: text), normalized.scheme?.lowercased() == "https", let host = normalized.host?.lowercased(),
            host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        let blockedSuffixes = [".local", ".lan", ".home", ".internal", ".localdomain", ".arpa", ".test", ".localhost"]
        if host == "localhost" || blockedSuffixes.contains(where: host.hasSuffix) { return nil }
        // No address literals: names only, so nothing on this network by number.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) || host.contains(":") || host.hasPrefix("[") { return nil }
        if normalized.port != nil, normalized.port != 443 { return nil }
        return normalized
    }
}
