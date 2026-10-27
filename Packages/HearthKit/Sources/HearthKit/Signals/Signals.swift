import Foundation

/// Something worth a glance that isn't an invite or a reply: a review requested
/// on GitHub, a frost warning, a scheduling email, a package arriving today, a
/// note from family.
public struct Signal: Codable, Hashable, Sendable, Identifiable {
    public enum Category: String, Codable, Hashable, Sendable, CaseIterable {
        case work
        case family
        case church

        public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    /// The email a signal came from.
    public struct MailRef: Codable, Hashable, Sendable {
        public var account: String
        public var messageId: String
        public var threadId: String

        public init(account: String, messageId: String, threadId: String) {
            self.account = account
            self.messageId = messageId
            self.threadId = threadId
        }
    }

    public enum Action: Codable, Hashable, Sendable {
        /// Open a web page.
        case open(label: String, url: URL)
        /// Read the email in Hearth (and answer it there).
        case read(label: String, mail: MailRef)
        /// A reminder on the phone.
        case remind(label: String, title: String, at: Date)
        /// Archive the emails behind it, marking them read.
        case markRead(label: String, mail: [MailRef])
        /// Look at an Inbox queue.
        case review(label: String, queue: MailQueue)

        public var label: String {
            switch self {
            case .open(let label, _), .read(let label, _), .remind(let label, _, _), .markRead(let label, _), .review(let label, _): label
            }
        }
    }

    public var id: String
    public var category: Category
    /// The tile's letters: "GH", "WX", "M".
    public var monogram: String
    /// "GitHub · via home".
    public var source: String
    public var date: Date
    public var title: String
    public var detail: String
    /// 2: pressing (the relay pushes it); 1: worth a look; 0: lower priority.
    public var priority: Int
    /// The first is the main button.
    public var actions: [Action]

    public init(
        id: String, category: Category, monogram: String, source: String, date: Date, title: String, detail: String,
        priority: Int = 1, actions: [Action] = []
    ) {
        self.id = id
        self.category = category
        self.monogram = monogram
        self.source = source
        self.date = date
        self.title = title
        self.detail = detail
        self.priority = priority
        self.actions = actions
    }
}

/// Notifications turned down to one line: "GitHub, subscribed threads · 38 updates".
public struct SignalBundle: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var count: Int
    public var action: Signal.Action?

    public init(id: String, title: String, detail: String, count: Int, action: Signal.Action? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.count = count
        self.action = action
    }
}

/// `GET /v1/signals`: what the relay watches for the phone (the weather, so far).
public struct RelaySignals: Codable, Hashable, Sendable {
    public var signals: [Signal]
    public var fetchedAt: Date?
    public var problems: [SourceProblem]

    public init(signals: [Signal], fetchedAt: Date?, problems: [SourceProblem] = []) {
        self.signals = signals
        self.fetchedAt = fetchedAt
        self.problems = problems
    }
}

public enum Signals {
    /// Most pressing first, then newest.
    public static func sorted(_ signals: [Signal]) -> [Signal] {
        signals.sorted { ($0.priority, $0.date) > ($1.priority, $1.date) }
    }

    // MARK: Mail

    static let attentionReasons: Set<String> = [
        "review_requested", "mention", "team_mention", "assign", "security_alert", "author", "manual",
    ]
    static let relations = ["mom", "dad", "mother", "father", "grandma", "grandpa", "nana", "papa", "gram", "pop pop"]
    static let carriers = ["usps.com", "ups.com", "fedex.com", "dhl.com", "amazon.com", "ontrac.com"]
    static let shippingWords = [
        "delivered", "out for delivery", "arriving", "arrives", "has shipped", "shipped:", "your package", "tracking",
    ]
    static let pressingShipping = ["out for delivery", "arriving today", "arrives today", "delivery exception", "delayed", "attempted"]

    /// The mail that's really a notification, as signals and quieted bundles.
    public static func fromMail(_ snapshot: MailSnapshot, household: Household, now: Date) -> (signals: [Signal], bundles: [SignalBundle]) {
        var signals: [Signal] = []
        var githubQuiet: [TriagedMail] = []
        var facebookQuiet: [TriagedMail] = []
        var shippingQuiet: [TriagedMail] = []
        var promos: [TriagedMail] = []
        var newsletters: [TriagedMail] = []
        let recent = now.addingTimeInterval(-72 * 3600)

        for mail in snapshot.items {
            let item = mail.item
            let from = item.from.lowercased()
            let subject = item.subject.lowercased()
            let text = subject + " " + item.snippet.lowercased()
            let ref = Signal.MailRef(account: item.account, messageId: item.id, threadId: item.threadId)
            let fresh = item.date >= recent

            if from.contains("notifications@github.com") || item.githubReason != nil {
                if let reason = item.githubReason, attentionReasons.contains(reason) {
                    signals.append(github(mail, reason: reason, ref: ref))
                } else {
                    githubQuiet.append(mail)
                }
            } else if from.contains("planningcenteronline.com") {
                signals.append(
                    Signal(
                        id: mail.id, category: .church, monogram: "PC", source: "Planning Center · \(item.account)", date: item.date,
                        title: item.subject, detail: item.snippet, priority: fresh ? 1 : 0, actions: [.read(label: "Read", mail: ref)]))
            } else if from.contains("facebookmail.com") {
                if subject.contains("event") || subject.contains("invited") {
                    signals.append(
                        Signal(
                            id: mail.id, category: .family, monogram: "FB", source: "Facebook · notification email", date: item.date,
                            title: item.subject, detail: item.snippet, priority: fresh ? 1 : 0, actions: [.read(label: "Read", mail: ref)]))
                } else {
                    facebookQuiet.append(mail)
                }
            } else if carriers.contains(where: { item.senderDomain.hasSuffix($0) }) || shippingWords.contains(where: subject.contains) {
                if pressingShipping.contains(where: text.contains) {
                    signals.append(
                        Signal(
                            id: mail.id, category: .family, monogram: monogram(item.senderName),
                            source: "\(item.senderName) · \(item.account)",
                            date: item.date, title: item.subject, detail: item.snippet, priority: fresh ? 1 : 0,
                            actions: [.read(label: "Read", mail: ref)]))
                } else {
                    shippingQuiet.append(mail)
                }
            } else if mail.tag == "Family" || isFamily(item.senderName, household: household) {
                signals.append(
                    Signal(
                        id: mail.id, category: .family, monogram: monogram(item.senderName), source: "\(item.senderName) · \(item.account)",
                        date: item.date, title: item.subject, detail: item.snippet, priority: fresh || mail.queue == .reply ? 1 : 0,
                        actions: [.read(label: mail.queue == .reply ? "Reply" : "Read", mail: ref)]))
            } else if from.contains("church") {
                signals.append(
                    Signal(
                        id: mail.id, category: .church, monogram: monogram(item.senderName), source: "\(item.senderName) · \(item.account)",
                        date: item.date, title: item.subject, detail: item.snippet, priority: fresh ? 1 : 0,
                        actions: [.read(label: mail.queue == .reply ? "Reply" : "Read", mail: ref)]))
            } else if mail.queue == .delete || mail.tag == "Promo" {
                promos.append(mail)
            } else if mail.tag == "Newsletter" {
                newsletters.append(mail)
            }
        }

        var bundles: [SignalBundle] = []
        func refs(_ mail: [TriagedMail]) -> [Signal.MailRef] {
            mail.map { Signal.MailRef(account: $0.item.account, messageId: $0.item.id, threadId: $0.item.threadId) }
        }
        if !githubQuiet.isEmpty {
            let mentions = signals.contains { $0.monogram == "GH" }
            bundles.append(
                SignalBundle(
                    id: "github", title: "GitHub, subscribed threads",
                    detail: count(githubQuiet.count, "update") + (mentions ? "" : " · none mention you"), count: githubQuiet.count,
                    action: .markRead(label: "Mark read", mail: refs(githubQuiet))))
        }
        if !promos.isEmpty {
            let doomed = promos.filter { $0.queue == .delete }.count
            let inboxes = Set(promos.map(\.item.account)).count
            var detail = "\(promos.count) across \(count(inboxes, "inbox", plural: "inboxes"))"
            if doomed > 0 { detail += " · \(doomed) queued for delete" }
            bundles.append(
                SignalBundle(
                    id: "promotions", title: "Promotions", detail: detail, count: promos.count,
                    action: .review(label: "Review", queue: doomed > 0 ? .delete : .archive)))
        }
        if !newsletters.isEmpty {
            bundles.append(
                SignalBundle(
                    id: "newsletters", title: "Newsletters", detail: "\(newsletters.count) · waiting in Archive",
                    count: newsletters.count, action: .review(label: "Review", queue: .archive)))
        }
        if !shippingQuiet.isEmpty {
            bundles.append(
                SignalBundle(
                    id: "shipping", title: "Shipping", detail: count(shippingQuiet.count, "update") + " · nothing late",
                    count: shippingQuiet.count, action: .markRead(label: "Mark read", mail: refs(shippingQuiet))))
        }
        if !facebookQuiet.isEmpty {
            bundles.append(
                SignalBundle(
                    id: "facebook", title: "Facebook", detail: count(facebookQuiet.count, "notification"), count: facebookQuiet.count,
                    action: .markRead(label: "Mark read", mail: refs(facebookQuiet))))
        }
        return (signals, bundles)
    }

    /// "Review requested on #412" from a GitHub notification email.
    static func github(_ mail: TriagedMail, reason: String, ref: Signal.MailRef) -> Signal {
        let item = mail.item
        let thread = GitHubSubject(item.subject)
        let number = thread.number.map { "#\($0)" }
        let title: String
        switch reason {
        case "review_requested": title = number.map { "Review requested on \($0)" } ?? thread.title
        case "mention", "team_mention": title = number.map { "You were mentioned on \($0)" } ?? thread.title
        case "assign": title = number.map { "Assigned to you: \($0)" } ?? thread.title
        case "security_alert": title = "Security alert in \(thread.repoName ?? "a repository")"
        default: title = number.map { "New activity on \($0)" } ?? thread.title
        }
        var actions: [Signal.Action] = []
        if let url = thread.url { actions.append(.open(label: thread.isPullRequest ? "Open PR" : "Open on GitHub", url: url)) }
        actions.append(.read(label: "Read", mail: ref))
        return Signal(
            id: mail.id, category: .work, monogram: "GH", source: "GitHub · via \(item.account)", date: item.date, title: title,
            detail: [thread.repoName, thread.title == title ? nil : thread.title].compactMap { $0 }.joined(separator: " · "),
            actions: actions)
    }

    static func isFamily(_ sender: String, household: Household) -> Bool {
        let name = sender.lowercased()
        if relations.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) { return true }
        if let partner = household.partnerName?.lowercased(), !partner.isEmpty {
            return name == partner || name.hasPrefix(partner + " ")
        }
        return false
    }

    static func monogram(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.count > 1 ? [words[0], words[1]].compactMap(\.first) : words.first.map { [$0.first!] } ?? ["?"]
        return String(letters).uppercased()
    }

    static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? noun : plural ?? noun + "s")
    }

    // MARK: The summary line

    /// When the night's quiet hours began: 9 PM last night (or tonight, after 9).
    public static func since(now: Date, quiet: QuietHours, zone: TimeZone) -> Date {
        let calendar = RFC3339.calendar(zone)
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(bySettingHour: quiet.startHour, minute: 0, second: 0, of: today) ?? today
        return start <= now ? start : calendar.date(byAdding: .day, value: -1, to: start) ?? start
    }

    /// "34 notifications since 9 PM, from 11 sources. Nine are worth a look."
    public static func summary(mail: MailSnapshot?, worth: Int, household: Household, quiet: QuietHours, now: Date) -> String {
        let start = since(now: now, quiet: quiet, zone: household.zone)
        let hour = household.fmt.time(start, compact: true)
        let new = mail?.items.filter { $0.item.date >= start } ?? []
        let sources = Set(new.map(\.item.senderDomain)).count
        let first =
            new.isEmpty
            ? "Nothing new since \(hour)."
            : "\(count(new.count, "notification")) since \(hour), from \(count(sources, "source"))."
        let second =
            switch worth {
            case 0: "Nothing needs a look."
            case 1: "One is worth a look."
            default: "\(spelled(worth)) are worth a look."
            }
        return first + " " + second
    }

    static func spelled(_ n: Int) -> String {
        let words = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve"]
        return n < words.count ? words[n] : String(n)
    }

    // MARK: Weather

    /// Home's point for the weather service, rounded to about a kilometer.
    public static func point(_ household: Household) -> String? {
        guard let lat = household.latitude, let lon = household.longitude else { return nil }
        func round(_ value: Double) -> String { String((value * 100).rounded() / 100) }
        return "\(round(lat)),\(round(lon))"
    }

    /// The National Weather Service's alerts for home, and a frost warning when
    /// the coming night drops to freezing and no alert has said so already.
    public static func weather(alerts: JSONValue?, forecast: JSONValue?, household: Household, now: Date) -> [Signal] {
        let fmt = household.fmt
        let place = household.town.isEmpty ? "Home" : household.town
        let details: URL? = point(household).flatMap { point in
            let parts = point.split(separator: ",")
            return URL(string: "https://forecast.weather.gov/MapClick.php?lat=\(parts[0])&lon=\(parts[1])")
        }
        let calendar = fmt.calendar
        let fivePM = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now) ?? now
        let reminder: Signal.Action? =
            fivePM.timeIntervalSince(now) >= 15 * 60
            ? .remind(label: "Remind me at 5", title: "Cover the tender plants", at: fivePM) : nil

        var out: [Signal] = []
        var frostSaid = false
        for feature in alerts?["features"]?.arrayValue ?? [] {
            guard let p = feature["properties"], let event = p["event"]?.stringValue,
                p["status"]?.stringValue ?? "Actual" == "Actual", p["messageType"]?.stringValue != "Cancel"
            else { continue }
            let ends = (p["ends"]?.stringValue ?? p["expires"]?.stringValue).flatMap { RFC3339.date($0) }
            if let ends, ends < now { continue }
            let onset = (p["onset"]?.stringValue ?? p["effective"]?.stringValue).flatMap { RFC3339.date($0) } ?? now
            let cold = event.lowercased().contains("frost") || event.lowercased().contains("freeze")
            frostSaid = frostSaid || cold
            var title = event
            if let ends {
                title +=
                    calendar.isDate(ends, inSameDayAs: now) ? " until \(fmt.time(ends))" : " until \(fmt.weekday(ends)) \(fmt.time(ends))"
            }
            let advice = firstSentence(p["instruction"]?.stringValue) ?? firstSentence(p["description"]?.stringValue) ?? ""
            let severity = p["severity"]?.stringValue ?? ""
            var actions: [Signal.Action] = []
            if cold, let reminder { actions.append(reminder) }
            if let details { actions.append(.open(label: "Details", url: details)) }
            out.append(
                Signal(
                    id: "wx:\(event):\(RFC3339.day(onset, zone: household.zone))", category: .family, monogram: "WX",
                    source: "National Weather Service", date: onset, title: title,
                    detail: [place, advice].filter { !$0.isEmpty }.joined(separator: ". "),
                    priority: severity == "Severe" || severity == "Extreme" ? 2 : 1, actions: actions))
        }

        if !frostSaid, let night = forecast?["properties"]?["periods"]?.arrayValue?.first(where: { $0["isDaytime"]?.boolValue == false }),
            let start = night["startTime"]?.stringValue.flatMap({ RFC3339.date($0) }), start.timeIntervalSince(now) < 24 * 3600,
            var low = night["temperature"]?.doubleValue
        {
            if night["temperatureUnit"]?.stringValue == "C" { low = low * 9 / 5 + 32 }
            if low <= 32 {
                let name = night["name"]?.stringValue ?? "Tonight"
                let when = name.lowercased() == "tonight" ? "tonight" : name.lowercased()
                var actions: [Signal.Action] = []
                if let reminder { actions.append(reminder) }
                if let details { actions.append(.open(label: "Details", url: details)) }
                out.append(
                    Signal(
                        id: "wx:frost:\(RFC3339.day(start, zone: household.zone))", category: .family, monogram: "WX",
                        source: "National Weather Service", date: now, title: "Frost \(when), low of \(Int(low.rounded()))°F",
                        detail: "\(place). Cover anything tender before sundown.", actions: actions))
            }
        }
        return out
    }

    static func firstSentence(_ text: String?) -> String? {
        guard let text = text?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        let cleaned = text.hasPrefix("* ") ? String(text.dropFirst(2)) : text
        if let end = cleaned.range(of: ". ") { return String(cleaned[..<end.lowerBound]) + "." }
        return cleaned
    }
}

/// The parts of a GitHub notification subject: "Re: [owner/repo] Title (PR #412)".
struct GitHubSubject {
    var repo: String?
    var title: String
    var number: Int?
    var isPullRequest: Bool

    init(_ subject: String) {
        var text = subject.trimmingCharacters(in: .whitespaces)
        while text.lowercased().hasPrefix("re: ") { text = String(text.dropFirst(4)) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            repo = String(text[text.index(after: text.startIndex)..<close])
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        isPullRequest = text.contains("(PR #")
        // "(PR #412)", "(Issue #45)", "(#212)" at the end, or "#218" anywhere.
        if let hash = text.lastIndex(of: "#") {
            let digits = text[text.index(after: hash)...].prefix { $0.isNumber }
            number = Int(digits)
        }
        if text.hasSuffix(")"), let open = text.lastIndex(of: "("), text[open...].contains("#") {
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        title = text
    }

    var repoName: String? { repo.map { $0.split(separator: "/").last.map(String.init) ?? $0 } }

    /// GitHub sends /issues/N on to the pull request when it is one.
    var url: URL? {
        guard let repo, repo.contains("/"), let number else { return nil }
        return URL(string: "https://github.com/\(repo)/issues/\(number)")
    }
}
