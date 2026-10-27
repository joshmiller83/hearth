import Foundation
import HearthKit
import HearthKitTestSupport
import Testing

@Suite("People")
struct PeopleTests {
    let household = Fixtures.household
    var mom: Person { Person(card: Fixtures.people[0]) }
    var robin: Person {
        var robin = Person(card: Fixtures.people[1], isPartner: true)
        robin.anniversary = MonthDay(month: 11, day: 14, year: 2012)
        return robin
    }

    @Test func contactsBecomePeople() {
        #expect(mom.shortName == "Mom")
        #expect(mom.birthday == MonthDay(month: 11, day: 3, year: 1956))
        #expect(mom.initial == "M")
        #expect(robin.shortName == "Robin")
        #expect(Person(id: "d", name: "Gary Rivera", relation: "father").shortName == "Dad")
    }

    @Test func occasionsComeInOrder() {
        let birthdays = Fixtures.apple(
            "kevin", "Kevin's Birthday", "2026-11-09T00:00", "2026-11-10T00:00", calendar: "Birthdays", allDay: true)
        // The same day as Mom's: the Birthdays calendar's copy isn't listed twice.
        let duplicate = Fixtures.apple(
            "mom", "Carol Rivera's Birthday", "2026-11-03T00:00", "2026-11-04T00:00", calendar: "Birthdays", allDay: true)
        let agenda = Agenda(events: Fixtures.week + [birthdays, duplicate], household: household)
        let occasions = Occasions.upcoming(people: [mom, robin], agenda: agenda, now: Fixtures.now)
        // Jordan's comes from the fixtures' Birthdays calendar.
        #expect(occasions.map(\.title) == ["Jordan's birthday", "Mom’s birthday", "Kevin's Birthday", "Anniversary with Robin"])
        #expect(occasions.map(\.daysAway) == [1, 8, 14, 19])
        let birthday = occasions[1]
        #expect(Occasions.mailBy(birthday, now: Fixtures.now, calendar: household.fmt.calendar) == Fixtures.at("2026-10-29T00:00"))
        // Too late to mail one: no date.
        #expect(Occasions.mailBy(occasions[0], now: Fixtures.now, calendar: household.fmt.calendar) == nil)
    }

    @Test func ideasArriveCheckedAndWithoutReplies() {
        let reply: JSONValue = [
            "ideas": [
                [
                    "person": "Mom", "source": "Mom's birthday is Tuesday", "title": "Call Mom on her birthday",
                    "body": "Tuesday evening is open.",
                    "actions": [
                        [
                            "kind": "hold", "label": "Hold Tue 7:30 PM", "detail": "Private", "done": "Tuesday call held",
                            "title": "Call Mom",
                            "start": "2026-11-03T19:30", "end": "2026-11-03T20:00", "account": "", "message_id": "", "text": "", "url": "",
                        ],
                        [
                            "kind": "reply", "label": "Reply", "detail": "", "done": "", "title": "", "start": "", "end": "",
                            "account": "home", "message_id": "m3", "text": "Hi", "url": "",
                        ],
                    ],
                ],
                ["person": "", "source": "", "title": "", "body": "", "actions": []],
            ]
        ]
        let ideas = PeopleIdeasPrompt.ideas(reply, household: household, now: Fixtures.now)
        #expect(ideas.count == 1)
        #expect(ideas[0].actions.map(\.kind) == [.hold])
        #expect(ideas[0].actions[0].id == "idea1-p1")
        #expect(ideas[0].actions[0].account == "work")
    }

    @Test func theIdeasRequestNamesPeopleNotPronouns() {
        let request = PeopleIdeasPrompt.request(
            people: [mom, robin], occasions: [], mail: Array(Fixtures.archived), free: [], household: household, now: Fixtures.now)
        let body = request.body
        #expect(body["model"]?.stringValue == "claude-opus-5-5")
        #expect(body["output_config"]?["effort"]?.stringValue == "medium")
        #expect(body["system"]?[0]?["text"]?.stringValue?.contains("not by pronouns") == true)
        let message = body["messages"]?[0]?["content"]?[0]?["text"]?.stringValue ?? ""
        #expect(message.contains("- Mom (Carol Rivera) · mother · lives in Springfield"))
        #expect(message.contains("- Robin (Robin Rivera) · partner"))
        #expect(message.contains("Garden's put to bed"))
    }

    @Test func plansAreTidied() {
        let reply: JSONValue = [
            "plans": [
                [
                    "tag": "From your list: Thai food", "title": "Thai dinner on Market St", "sub": "7:00 PM, table for two.",
                    "short": "the Thai dinner", "start": "19:00", "minutes": 150,
                ],
                ["tag": "Low-key", "title": "A night in", "sub": "", "short": "a night in", "start": "evening", "minutes": 2000],
            ]
        ]
        let plans = PartnerPlanPrompt.plans(reply)
        #expect(plans.map(\.id) == ["plan1", "plan2"])
        #expect(plans[1].start == "18:30")
        #expect(plans[1].minutes == 360)
    }

    @Test func eveningsAndBusyDays() {
        let agenda = Agenda(events: Fixtures.week, household: household)
        let monday = PartnerWeek.eveningOpen(agenda: agenda, day: Fixtures.at("2026-10-26T00:00"))
        #expect(!monday.open)
        #expect(monday.blocker == "Robin is busy: book club")
        let busy = ["09", "10", "11"].map { hour in
            Fixtures.google("w\(hour)", "meeting", "2026-10-28T\(hour):00", "2026-10-28T\(hour):45", account: "robin")
        }
        let week = Agenda(events: Fixtures.week + busy, household: household)
        let busiest = PartnerWeek.busiestDay(agenda: week, now: Fixtures.now)
        #expect(busiest?.day == Fixtures.at("2026-10-28T00:00"))
        #expect(busiest?.count == 3)
        #expect(PartnerWeek.busiestDay(agenda: agenda, now: Fixtures.now) == nil)
    }
}
