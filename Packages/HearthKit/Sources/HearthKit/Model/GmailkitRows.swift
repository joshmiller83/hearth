import Foundation

// The rows gmailkit's MCP tools return, as it writes them (snake_case keys,
// account emails rather than aliases). The relay decodes these and converts them
// to Hearth's types. Every field is optional because a sweep that fails for one
// account returns `{"account": …, "error": …}` in the same list.

/// A row from `gmail_accounts`.
public struct GmailkitAccountRow: Decodable, Sendable, Equatable {
    public var email: String
    public var alias: String
    public var name: String?
    public var enabled: Bool?
    public var authorized: Bool?
    public var notes: String?

    public var account: Account {
        Account(alias: alias, email: email, name: name ?? "", enabled: enabled ?? true, authorized: authorized ?? false)
    }
}

/// A row from `gmail_calendars`.
public struct GmailkitCalendarRow: Decodable, Sendable, Equatable {
    public var account: String
    public var id: String?
    public var summary: String?
    public var primary: Bool?
    public var access_role: String?
    public var hidden: Bool?
    public var error: String?

    public init(
        account: String, id: String? = nil, summary: String? = nil, primary: Bool? = nil, access_role: String? = nil,
        hidden: Bool? = nil, error: String? = nil
    ) {
        self.account = account
        self.id = id
        self.summary = summary
        self.primary = primary
        self.access_role = access_role
        self.hidden = hidden
        self.error = error
    }
}

/// An attendee on a gmailkit event row.
public struct GmailkitAttendee: Decodable, Sendable, Equatable {
    public var email: String?
    public var name: String?
    public var response: String?
    public var optional: Bool?
}

/// A row from `gmail_calendar_events` (and the event `gmail_calendar_respond` /
/// `gmail_calendar_create_event` return).
public struct GmailkitEventRow: Decodable, Sendable, Equatable {
    public var account: String
    public var calendar: String?
    public var calendar_id: String?
    public var id: String?
    public var ical_uid: String?
    public var recurring_event_id: String?
    public var summary: String?
    public var start: String?
    public var end: String?
    public var all_day: Bool?
    public var status: String?
    public var location: String?
    public var organizer: String?
    public var my_response: String?
    public var attendees: [GmailkitAttendee]?
    public var meeting_links: [String]?
    public var html_link: String?
    public var description: String?
    public var transparency: String?
    public var visibility: String?
    public var error: String?

    public init(
        account: String, calendar: String? = nil, calendar_id: String? = nil, id: String? = nil, ical_uid: String? = nil,
        summary: String? = nil, start: String? = nil, end: String? = nil, all_day: Bool? = nil, status: String? = nil,
        location: String? = nil, organizer: String? = nil, my_response: String? = nil, meeting_links: [String]? = nil,
        description: String? = nil, transparency: String? = nil, error: String? = nil
    ) {
        self.account = account
        self.calendar = calendar
        self.calendar_id = calendar_id
        self.id = id
        self.ical_uid = ical_uid
        self.summary = summary
        self.start = start
        self.end = end
        self.all_day = all_day
        self.status = status
        self.location = location
        self.organizer = organizer
        self.my_response = my_response
        self.meeting_links = meeting_links
        self.description = description
        self.transparency = transparency
        self.error = error
    }

    /// This row as an `AgendaEvent`, or nil for error rows, cancelled events and
    /// rows without usable times. `alias` maps gmailkit's account email to its alias.
    public func agendaEvent(alias: (String) -> String, household: Household) -> AgendaEvent? {
        guard error == nil, let id, !id.isEmpty, status != "cancelled",
            let startText = start, let endText = end,
            let startParsed = RFC3339.parse(startText, zone: household.zone),
            let endParsed = RFC3339.parse(endText, zone: household.zone)
        else { return nil }

        let accountAlias = alias(account)
        let calendarId = calendar_id ?? calendar ?? "primary"
        var event = AgendaEvent(
            id: "g:\(accountAlias):\(calendarId):\(id)",
            source: .google(account: accountAlias, calendarId: calendarId, calendarName: calendar ?? calendarId),
            sourceEventId: id,
            iCalUID: (ical_uid?.isEmpty ?? true) ? nil : ical_uid,
            title: (summary?.isEmpty ?? true) ? "(no title)" : summary!,
            start: startParsed.date,
            end: max(endParsed.date, startParsed.date),
            isAllDay: all_day ?? startParsed.isDateOnly,
            location: location.flatMap { $0.isEmpty ? nil : $0 },
            notes: description.flatMap { $0.isEmpty ? nil : $0 },
            meetingLinks: meeting_links ?? [],
            myResponse: RSVP(google: my_response ?? ""),
            organizer: organizer.flatMap { $0.isEmpty ? nil : $0 },
            attendeeCount: attendees?.count ?? 0,
            transparent: transparency == "transparent",
            url: html_link.flatMap { $0.isEmpty ? nil : $0 }
        )
        if household.isPartnerAccount(accountAlias) {
            event = BusyOnly.redact(event)
        }
        return event
    }
}

/// A row from `gmail_search` (`metadata_only: true` adds the triage headers).
public struct GmailkitMessageRow: Decodable, Sendable, Equatable {
    public var id: String?
    public var thread_id: String?
    public var account: String
    public var subject: String?
    public var from: String?
    public var to: String?
    public var cc: String?
    public var date: String?
    public var snippet: String?
    public var labels: [String]?
    public var unread: Bool?
    public var github_reason: String?
    public var list_id: String?
    public var delivered_to: String?
    public var body_text: String?
    public var body_html: String?
    public var attachments: [GmailkitAttachment]?
    public var error: String?

    public init(
        id: String? = nil, thread_id: String? = nil, account: String, subject: String? = nil, from: String? = nil,
        to: String? = nil, cc: String? = nil, date: String? = nil, snippet: String? = nil, labels: [String]? = nil,
        unread: Bool? = nil, github_reason: String? = nil, list_id: String? = nil, delivered_to: String? = nil,
        body_text: String? = nil, body_html: String? = nil, attachments: [GmailkitAttachment]? = nil, error: String? = nil
    ) {
        self.id = id
        self.thread_id = thread_id
        self.account = account
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.snippet = snippet
        self.labels = labels
        self.unread = unread
        self.github_reason = github_reason
        self.list_id = list_id
        self.delivered_to = delivered_to
        self.body_text = body_text
        self.body_html = body_html
        self.attachments = attachments
        self.error = error
    }

    /// A row for this item, as gmailkit would send it (for fakes).
    public init(item: MailItem, email: String, body: String? = nil) {
        self.init(
            id: item.id, thread_id: item.threadId, account: email, subject: item.subject, from: item.from, to: item.to, cc: item.cc,
            date: RFC3339.format(item.date), snippet: item.snippet, labels: item.labels, unread: item.unread,
            github_reason: item.githubReason ?? "", list_id: item.listId ?? "", body_text: body)
    }
}

public struct GmailkitAttachment: Decodable, Sendable, Equatable {
    public var filename: String?
    public var mime_type: String?
    public var size: Int?
}

/// A row from `gmail_labels`.
public struct GmailkitLabelRow: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String?

    public init(id: String, name: String, type: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
    }
}

/// Every write tool answers with an object, or `{"error": …}` when gmailkit refused.
public struct GmailkitErrorRow: Decodable, Sendable, Equatable {
    public var error: String
}
