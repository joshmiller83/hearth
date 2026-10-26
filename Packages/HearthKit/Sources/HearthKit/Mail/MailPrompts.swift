import Foundation

/// Haiku sorts what the rules couldn't place.
public enum SortPrompt {
    public struct Result: Codable, Sendable, Equatable {
        public var index: Int
        /// reply, jobHunt, archive, delete or keep.
        public var queue: String
        public var tag: String
        public var reason: String

        public init(index: Int, queue: String, tag: String, reason: String) {
            self.index = index
            self.queue = queue
            self.tag = tag
            self.reason = reason
        }
    }

    public struct Reply: Codable, Sendable, Equatable {
        public var results: [Result]

        public init(results: [Result]) {
            self.results = results
        }
    }

    /// At most this many messages per request.
    public static let batchSize = 40

    public static func system(household: Household) -> String {
        """
        You sort email for \(household.ownerName)'s household so they can clear their inboxes with a few taps. \
        Nothing you decide happens without their approval, but a wrong "archive" or "delete" hides mail they needed, so \
        when unsure, choose keep.

        Queues:
        - reply: a real person wrote and expects an answer or a decision from them.
        - jobHunt: anything about \(household.ownerName)'s job search (applications, recruiters, interviews, job alerts).
        - archive: fine to file away unread: notifications, receipts, shipping, statements, digests, FYIs.
        - delete: junk: marketing, expired offers, spam-like mail.
        - keep: leave it in the inbox: security, legal, money problems, health, school, anything sensitive or unclear.

        For each message return its index, the queue, a tag of one or two words shown on its row ("Needs you", \
        "Receipt", "Newsletter", "Promo", "Recruiter", "School"), and a reason of at most ten words.
        """
    }

    public static func request(_ items: [MailItem], household: Household, labelNames: [String: String]) -> ClaudeRequest {
        var lines = ["Sort these messages:"]
        for (index, item) in items.enumerated() {
            let labels = item.labels.compactMap { labelNames[$0] ?? ($0.hasPrefix("CATEGORY_") ? $0 : nil) }
            lines.append(
                "\(index). account: \(item.account) | from: \(item.from) | subject: \(item.subject) | "
                    + "labels: \(labels.joined(separator: ", ")) | \(item.unread ? "unread" : "read") | snippet: \(item.snippet.prefix(200))"
            )
        }
        return ClaudeRequest(
            model: .haiku, maxTokens: 8_000, system: system(household: household),
            messages: [.user(lines.joined(separator: "\n"))], effort: .low,
            outputSchema: Schema.object([
                "results": Schema.array(
                    Schema.object([
                        "index": Schema.integer,
                        "queue": Schema.enumeration(["reply", "jobHunt", "archive", "delete", "keep"]),
                        "tag": Schema.string,
                        "reason": Schema.string,
                    ]))
            ]))
    }

    /// Haiku's answers as triage; messages it skipped stay kept.
    public static func triage(_ items: [MailItem], reply: Reply) -> [TriagedMail] {
        var byIndex: [Int: Result] = [:]
        for result in reply.results { byIndex[result.index] = result }
        return items.enumerated().map { index, item in
            guard let result = byIndex[index] else {
                return TriagedMail(item: item, queue: nil, tag: "Needs a look", reason: "Not sorted", sortedBy: .unsorted)
            }
            return TriagedMail(
                item: item, queue: MailQueue(rawValue: result.queue), tag: result.tag.isEmpty ? "Sorted" : result.tag,
                reason: result.reason, sortedBy: .claude)
        }
    }
}

/// Opus drafts a reply in the owner's voice.
public enum DraftPrompt {
    public enum Tone: String, Codable, Sendable, CaseIterable {
        case drafted
        case shorter
        case warmer

        public var label: String {
            switch self {
            case .drafted: "As drafted"
            case .shorter: "Shorter"
            case .warmer: "Warmer"
            }
        }
    }

    public struct Slot: Codable, Sendable, Equatable {
        /// "2026-10-28T13:00", local.
        public var start: String
        public var end: String

        public init(start: String, end: String) {
            self.start = start
            self.end = end
        }
    }

    public struct Draft: Codable, Sendable, Equatable {
        public var body: String
        /// The windows the draft offers, so they can be held on the calendar.
        public var offeredSlots: [Slot]
        /// What Claude used, for "What Claude looked at".
        public var lookedAt: [String]

        public init(body: String, offeredSlots: [Slot] = [], lookedAt: [String] = []) {
            self.body = body
            self.offeredSlots = offeredSlots
            self.lookedAt = lookedAt
        }
    }

    public static func system(household: Household) -> String {
        """
        You draft email replies for \(household.ownerName). They read and send every draft themselves.

        Write as \(household.ownerName): plain, warm and brief, the way a busy, kind person writes. No filler, no \
        "I hope this finds you well", no exclamation marks unless they used them first. Greet by first name and sign \
        off with just "\(household.ownerName)".

        Never invent facts, dates, promises or commitments. If the reply needs something you don't know, write around \
        it or leave a short placeholder in [brackets].

        When someone asks for times, offer three windows from the free time you're given, as bullets like \
        "• Wed, Oct 28 · 1:00–2:30 PM", in the length they asked for, and say which time zone. List the windows you \
        offered in offeredSlots (local times, YYYY-MM-DDTHH:MM). Otherwise offeredSlots is empty.

        lookedAt lists, in a few words each, what you used: "Free time across all 7 calendars, Wed–Fri", \
        "Your two earlier replies to Priya".
        """
    }

    public static func request(
        thread: [ThreadMessage], account: Account?, freeTime: [DateInterval], tone: Tone,
        household: Household, now: Date
    ) -> ClaudeRequest {
        let fmt = household.fmt
        var text = ["Today is \(fmt.longDay(now)), \(fmt.time(now)) (\(household.timeZone))."]
        if let account { text.append("Reply from: \(account.email) (\(account.alias)).") }
        text.append("The thread, oldest first:")
        for message in thread.suffix(6) {
            text.append(
                "---\nFrom: \(message.from)\nDate: \(fmt.shortDay(message.date)) \(fmt.time(message.date))\n\n\(message.body.prefix(4000))")
        }
        text.append("---")
        if !freeTime.isEmpty {
            text.append("Free time (local):")
            for window in freeTime.prefix(20) {
                text.append("• \(fmt.shortDay(window.start)) · \(fmt.timeRange(window.start, window.end))")
            }
        }
        switch tone {
        case .drafted: text.append("Draft the reply.")
        case .shorter: text.append("Draft the reply, as short as it can be while still answering.")
        case .warmer: text.append("Draft the reply, a little warmer and more personal, still brief.")
        }
        return ClaudeRequest(
            model: .opus, maxTokens: 16_000, system: system(household: household), messages: [.user(text.joined(separator: "\n"))],
            effort: tone == .drafted ? .medium : .low,
            outputSchema: Schema.object([
                "body": Schema.string,
                "offeredSlots": Schema.array(Schema.object(["start": Schema.string, "end": Schema.string])),
                "lookedAt": Schema.array(Schema.string),
            ]))
    }
}

extension Agenda {
    /// Working-hours windows with nothing of the owner's in them, for offering times.
    public func freeWindows(
        from now: Date, days: Int = 7, dayStart: Int = 9, dayEnd: Int = 17, minimum: TimeInterval = 3600,
        weekdaysOnly: Bool = true
    ) -> [DateInterval] {
        let calendar = household.fmt.calendar
        let busy = events.filter { $0.blocksTime && !$0.busyOnly }.map { DateInterval(start: $0.start, end: max($0.end, $0.start)) }
        var windows: [DateInterval] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                let open = calendar.date(bySettingHour: dayStart, minute: 0, second: 0, of: day),
                let close = calendar.date(bySettingHour: dayEnd, minute: 0, second: 0, of: day)
            else { continue }
            let weekday = calendar.component(.weekday, from: day)
            if weekdaysOnly, weekday == 1 || weekday == 7 { continue }
            var cursor = max(open, now)
            for block in busy.filter({ $0.end > cursor && $0.start < close }).sorted(by: { $0.start < $1.start }) {
                if block.start.timeIntervalSince(cursor) >= minimum { windows.append(DateInterval(start: cursor, end: block.start)) }
                cursor = max(cursor, block.end)
            }
            if close.timeIntervalSince(cursor) >= minimum { windows.append(DateInterval(start: cursor, end: close)) }
        }
        return windows
    }
}
