import Foundation
import HearthKitTestSupport
import Testing

@testable import HearthKit

@Suite("gmailkit rows")
struct GmailkitRowTests {
    /// The shape `gmail_calendar_events` returns, with fictional data.
    let eventsJSON = #"""
        [
          {"account": "sam@rivera.example", "calendar": "Sam Rivera", "calendar_id": "primary", "id": "evt1",
           "ical_uid": "evt1@google.com", "recurring_event_id": "", "summary": "Leaders huddle",
           "start": "2026-10-29T19:00-04:00", "end": "2026-10-29T20:00-04:00", "all_day": false, "timezone": "America/New_York",
           "status": "confirmed", "location": "", "organizer": "office@church.example", "my_response": "needsAction",
           "attendees": [{"email": "sam@rivera.example", "name": "", "response": "needsAction", "optional": false}],
           "meeting_links": [], "hangout_link": "", "html_link": "https://www.google.com/calendar/event?eid=1",
           "description": "", "transparency": "opaque", "visibility": "default", "updated": "2026-10-20T12:00:00.000Z"},
          {"account": "robin@rivera.example", "calendar": "Robin", "calendar_id": "primary", "id": "evt2",
           "summary": "book club", "start": "2026-10-26T18:30-04:00", "end": "2026-10-26T20:00-04:00", "all_day": false,
           "location": "Library", "my_response": "", "meeting_links": ["https://zoom.us/j/9"], "description": "Chapter 4"},
          {"account": "sam.home@example.com", "calendar": "Holidays in United States", "calendar_id": "en.usa#holiday@group.v.calendar.google.com",
           "id": "h1", "summary": "Halloween", "start": "2026-10-31", "end": "2026-11-01", "all_day": true, "transparency": "transparent"},
          {"account": "sam.home@example.com", "id": "gone", "summary": "Cancelled thing", "status": "cancelled",
           "start": "2026-10-27T09:00-04:00", "end": "2026-10-27T10:00-04:00"},
          {"account": "kid.rivera@example.com", "error": "[kid.rivera@example.com] Calendar API error 401: invalid_grant"}
        ]
        """#

    func alias(_ email: String) -> String {
        Fixtures.accounts.first { $0.email == email }?.alias ?? email
    }

    func events() throws -> [AgendaEvent] {
        let rows = try HearthJSON.decode([GmailkitEventRow].self, from: Data(eventsJSON.utf8))
        #expect(rows.count == 5)
        #expect(rows.last?.error != nil)
        return rows.compactMap { $0.agendaEvent(alias: alias, household: Fixtures.household) }
    }

    @Test func rowsBecomeAgendaEvents() throws {
        let events = try events()
        #expect(events.map(\.title) == ["Leaders huddle", "book club", "Halloween"])
        let huddle = events[0]
        #expect(huddle.id == "g:work:primary:evt1")
        #expect(huddle.source == .google(account: "work", calendarId: "primary", calendarName: "Sam Rivera"))
        #expect(huddle.iCalUID == "evt1@google.com")
        #expect(huddle.myResponse == .needsAction)
        #expect(huddle.location == nil)
        #expect(RFC3339.format(huddle.start) == "2026-10-29T23:00:00Z")
        #expect(huddle.attendeeCount == 1)
    }

    @Test func thePartnersEventsArriveBusyOnly() throws {
        let book = try events()[1]
        #expect(book.busyOnly)
        #expect(book.location == nil && book.meetingLinks.isEmpty && book.notes == nil)
    }

    @Test func allDayAndFreeEvents() throws {
        let halloween = try events()[2]
        #expect(halloween.isAllDay)
        #expect(halloween.transparent)
        #expect(!halloween.blocksTime)
        #expect(halloween.source.label == "Holidays in United States")
        #expect(RFC3339.format(halloween.start, zone: Fixtures.zone) == "2026-10-31T00:00:00-04:00")
    }

    @Test func accountRowsBecomeAccounts() throws {
        let json =
            #"[{"email": "sam@rivera.example", "alias": "work", "name": "Sam Rivera", "enabled": true, "authorized": true, "notes": ""}]"#
        let rows = try HearthJSON.decode([GmailkitAccountRow].self, from: Data(json.utf8))
        #expect(rows.map(\.account) == [Account(alias: "work", email: "sam@rivera.example", name: "Sam Rivera")])
    }

    @Test func messageRowsDecode() throws {
        let json = #"""
            [{"id": "m1", "thread_id": "t1", "account": "sam@rivera.example", "subject": "Panel times?", "from": "Priya <p@x.example>",
              "to": "sam@rivera.example", "date": "2026-10-26T13:02:11+00:00", "snippet": "Could you do", "labels": ["INBOX", "UNREAD", "Label_7"],
              "unread": true, "cc": "", "github_reason": "", "list_id": "", "delivered_to": "sam@rivera.example"},
             {"account": "kid.rivera@example.com", "error": "boom"}]
            """#
        let rows = try HearthJSON.decode([GmailkitMessageRow].self, from: Data(json.utf8))
        #expect(rows[0].labels == ["INBOX", "UNREAD", "Label_7"])
        #expect(rows[1].error == "boom")
    }
}
