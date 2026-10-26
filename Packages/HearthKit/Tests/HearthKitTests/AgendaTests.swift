import Foundation
import HearthKitTestSupport
import Testing

@testable import HearthKit

@Suite("Agenda merge, invites and conflicts")
struct AgendaTests {
    let agenda = Agenda(events: Fixtures.week, household: Fixtures.household)

    @Test func copiesOfOneInviteBecomeOneRow() throws {
        let mixers = agenda.events.filter { $0.title == "Alumni mixer" }
        #expect(mixers.count == 1)
        let mixer = try #require(mixers.first)
        // The copy waiting on an answer wins, so RSVP goes to the right account.
        #expect(mixer.source.account == "school")
        #expect(mixer.myResponse == .needsAction)
        #expect(mixer.alsoOn == [.google(account: "work", calendarId: "primary", calendarName: "primary")])
    }

    @Test func copiesWithoutAUIDMatchOnTitleAndTime() {
        let google = Fixtures.google("lunch-g", "Lunch with Robin!", "2026-10-26T12:15", "2026-10-26T13:00", account: "home")
        let apple = Fixtures.apple("lunch", "lunch with robin", "2026-10-26T12:16", "2026-10-26T13:00")
        let merged = AgendaMerge.merge([apple, google])
        #expect(merged.count == 1)
        #expect(merged[0].source.account == "home")
        #expect(merged[0].alsoOn.count == 1)
    }

    @Test func recurringInstancesStayApart() {
        let monday = Fixtures.google("w1", "Standup", "2026-10-26T09:00", "2026-10-26T09:15", uid: "standup@x")
        let tuesday = Fixtures.google("w2", "Standup", "2026-10-27T09:00", "2026-10-27T09:15", uid: "standup@x")
        #expect(AgendaMerge.merge([monday, tuesday]).count == 2)
    }

    @Test func differentTimesAreDifferentEvents() {
        let a = Fixtures.google("a", "Practice", "2026-10-26T17:00", "2026-10-26T18:00")
        let b = Fixtures.apple("b", "Practice", "2026-10-26T18:00", "2026-10-26T19:00")
        #expect(AgendaMerge.merge([a, b]).count == 2)
    }

    @Test func theOwnersCopyBeatsThePartnersBusyOnlyCopy() throws {
        let theirs = Fixtures.google("t", "Dinner party", "2026-10-30T18:00", "2026-10-30T21:00", account: "robin", uid: "party@x")
        let mine = Fixtures.google(
            "m", "Dinner party", "2026-10-30T18:00", "2026-10-30T21:00", account: "home", uid: "party@x",
            response: .accepted, location: "12 Elm St")
        let merged = AgendaMerge.merge([theirs, mine])
        let only = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(!only.busyOnly)
        #expect(only.location == "12 Elm St")
    }

    @Test func nextUpIsTheCoffeeChat() throws {
        let next = try #require(agenda.nextUp(now: Fixtures.now))
        #expect(next.title == "Coffee chat, agency lead")
        #expect(next.meetingService == "Zoom")
        #expect(Fixtures.household.fmt.relative(next.start, now: Fixtures.now) == "in 52 min")
    }

    @Test func nextUpSkipsThePartnersEventsAndReminders() throws {
        let evening = Fixtures.at("2026-10-26T17:00")
        // The 5:30 reminder, Robin's 6:30 book club and the unanswered mixer aren't "next up" for Sam.
        let next = try #require(agenda.nextUp(now: evening))
        #expect(next.title == "Bible study")
    }

    @Test func invitesWaitingOnMeAreSoonestFirst() {
        #expect(agenda.waitingOnMe(now: Fixtures.now).map(\.title) == ["Alumni mixer", "Leaders huddle"])
        #expect(agenda.waitingOnMe(now: Fixtures.at("2026-10-29T08:00")).map(\.title) == ["Leaders huddle"])
    }

    @Test func theHuddleOverlapsBibleStudy() throws {
        let huddle = try #require(agenda.events.first { $0.title == "Leaders huddle" })
        #expect(agenda.conflictSentence(for: huddle) == "Overlaps Bible study, 7:00–8:30 PM on Small group")
        let mixer = try #require(agenda.events.first { $0.title == "Alumni mixer" })
        #expect(agenda.conflictSentence(for: mixer) == nil)
    }

    @Test func thePartnersEventsNeverConflict() throws {
        let late = Fixtures.google("late", "Late call", "2026-10-26T19:00", "2026-10-26T19:30", response: .needsAction)
        let agenda = Agenda(events: Fixtures.week + [late], household: Fixtures.household)
        let call = try #require(agenda.events.first { $0.title == "Late call" })
        #expect(agenda.conflicts(with: call).isEmpty)
    }

    @Test func todayHasEveryCalendarAndNoDeclines() {
        let declined = Fixtures.google("no", "Webinar", "2026-10-26T14:00", "2026-10-26T15:00", response: .declined)
        let agenda = Agenda(events: Fixtures.week + [declined], household: Fixtures.household)
        let titles = agenda.events(on: Fixtures.now).map(\.title)
        #expect(
            titles == [
                "Coffee chat, agency lead", "Lunch with Robin", "Module weekly sync",
                "Cover the plants, frost tonight", "book club",
            ])
    }

    @Test func allDayEventsComeFirstOnTheirDay() {
        let tuesday = agenda.events(on: Fixtures.at("2026-10-27T09:00"))
        #expect(tuesday.first?.title == "Jordan's birthday")
        #expect(tuesday.first?.isAllDay == true)
    }

    @Test func theWeekStripMarksInvitesAndPlans() {
        let week = agenda.week(from: Fixtures.now)
        #expect(week.map(\.tag) == ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"])
        #expect(week.map(\.number) == [26, 27, 28, 29, 30, 31, 1])
        #expect(week.map(\.mark) == [.plans, .plans, .invite, .invite, .none, .plans, .plans])
        #expect(week[0].isToday && !week[1].isToday)
    }

    @Test func freeEveningsSkipBothCalendars() {
        let free = agenda.freeEvenings(now: Fixtures.now, days: 7)
        let days = free.map { Fixtures.household.fmt.weekday($0.start) }
        // Mon: Robin's book club. Wed: the mixer invite doesn't block yet; Thu: Bible study.
        #expect(days == ["Tue", "Wed", "Fri", "Sat", "Sun"])
    }
}
