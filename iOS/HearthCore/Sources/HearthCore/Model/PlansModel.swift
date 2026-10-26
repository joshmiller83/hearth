import Foundation
import HearthKit
import Observation

/// The Plans screen: one agenda from every calendar, the invites waiting on the
/// owner, and their answers (sent after a 5-second undo window).
@MainActor
@Observable
public final class PlansModel {
    public static let undoSeconds: TimeInterval = 5

    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Where an answer to an invite stands.
    public struct Reply: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            /// Tapped; sends when the window closes unless undone.
            case waiting(until: Date)
            case sending
            case sent
            case failed(String)
        }

        public var response: RSVP
        public var state: State
    }

    let services: AppServices
    weak var app: AppModel?

    public private(set) var googleEvents: [AgendaEvent]
    public private(set) var appleEvents: [AgendaEvent] = []
    public private(set) var fetchedAt: Date?
    public private(set) var problems: [SourceProblem] = []
    public private(set) var phase: Phase = .idle
    public private(set) var replies: [String: Reply] = [:]
    public var selectedDay: Date
    public private(set) var calendarAccess: CalendarAccess

    init(services: AppServices) {
        self.services = services
        let cached = services.database.load(EventsResponse.self, key: StoreKey.googleEvents)
        googleEvents = cached?.events ?? []
        fetchedAt = cached?.fetchedAt
        problems = cached?.problems ?? []
        selectedDay = services.clock.now
        calendarAccess = services.calendar.access()
    }

    var now: Date { services.clock.now }
    public var household: Household { app?.household ?? .placeholder }

    /// Every calendar merged, with the owner's sent answers applied.
    public var agenda: Agenda {
        var events = googleEvents + appleEvents
        for index in events.indices {
            if let reply = replies[events[index].id], reply.state == .sent {
                events[index].myResponse = reply.response
            }
        }
        return Agenda(events: events, household: household)
    }

    public var week: [WeekDay] { agenda.week(from: now) }

    public var isToday: Bool { household.fmt.calendar.isDate(selectedDay, inSameDayAs: now) }

    /// The selected day's events, partner events retitled "<name> is busy: …".
    public var dayEvents: [AgendaEvent] { agenda.events(on: selectedDay) }

    /// Invites still waiting, plus any answered in this session (so the answer
    /// stays on screen until the next refresh moves it into the agenda).
    public var invites: [AgendaEvent] {
        let agenda = agenda
        let waiting = agenda.waitingOnMe(now: now)
        let answered = agenda.events.filter { replies[$0.id] != nil && !waiting.contains($0) && $0.end > now }
        return (waiting + answered).sorted { $0.start < $1.start }
    }

    // MARK: Loading

    /// The relay's cached events (or a fresh sweep with `force`) and EventKit's, merged.
    public func refresh(force: Bool = false) async {
        phase = .loading
        await refreshApple()
        guard let relay = app?.relay else {
            phase = googleEvents.isEmpty ? .failed(RelayError.notConfigured.description) : .loaded
            publishWidgets()
            return
        }
        let calendar = household.fmt.calendar
        let from = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        let to = calendar.date(byAdding: .day, value: 45, to: from) ?? now
        do {
            let answer = try await relay.events(from: from, to: to, refresh: force)
            googleEvents = answer.events
            fetchedAt = answer.fetchedAt
            problems = answer.problems
            try? services.database.save(answer, key: StoreKey.googleEvents, now: now)
            // Answers the relay now reflects don't need local overrides any more.
            replies = replies.filter { id, reply in
                reply.state != .sent || answer.events.first { $0.id == id }?.myResponse != reply.response
            }
            phase = .loaded
        } catch {
            phase = .failed((error as? RelayError)?.description ?? String(describing: error))
        }
        publishWidgets()
    }

    public func refreshApple() async {
        calendarAccess = services.calendar.access()
        guard calendarAccess == .full else { return }
        let calendar = household.fmt.calendar
        let from = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        let to = calendar.date(byAdding: .day, value: 45, to: from) ?? now
        appleEvents = await services.calendar.events(from: from, to: to, calendarIds: nil)
    }

    public func requestCalendarAccess() async {
        calendarAccess = await services.calendar.requestAccess()
        await refreshApple()
        publishWidgets()
    }

    func publishWidgets() {
        services.widgets.publish(WidgetSnapshot.make(agenda: agenda, now: now, fetchedAt: fetchedAt))
    }

    // MARK: Answering invites

    /// Starts the undo window for an answer; it sends when the window closes.
    public func reply(to event: AgendaEvent, _ response: RSVP) {
        guard case .google = event.source, response != .none, response != .needsAction else { return }
        let until = now.addingTimeInterval(Self.undoSeconds)
        replies[event.id] = Reply(response: response, state: .waiting(until: until))
        Task { [services] in
            await services.wait(Self.undoSeconds)
            await self.sendIfStillWaiting(event, response)
        }
    }

    /// Takes back an answer whose window is still open.
    public func undoReply(to event: AgendaEvent) {
        guard let reply = replies[event.id], case .waiting = reply.state else { return }
        replies[event.id] = nil
    }

    func sendIfStillWaiting(_ event: AgendaEvent, _ response: RSVP) async {
        guard let reply = replies[event.id], reply.response == response, case .waiting = reply.state else { return }
        guard case .google(let account, let calendarId, _) = event.source else { return }
        guard let relay = app?.relay else {
            replies[event.id]?.state = .failed(RelayError.notConfigured.description)
            return
        }
        replies[event.id]?.state = .sending
        let action = ApprovedAction(
            kind: .rsvp(account: account, calendarId: calendarId, eventId: event.sourceEventId, response: response),
            context: .plans, approvedAt: now)
        do {
            let status = try await relay.submit([action]).first
            switch status?.state {
            case .done:
                replies[event.id]?.state = .sent
            case .pending:
                // gmailkit is restarting; the relay will retry it.
                replies[event.id]?.state = .sent
            default:
                replies[event.id]?.state = .failed(status?.message ?? "The relay didn't send it.")
            }
        } catch {
            replies[event.id]?.state = .failed((error as? RelayError)?.description ?? String(describing: error))
        }
        publishWidgets()
    }

    // MARK: Words for the screen

    /// "Thu, Oct 29 · 7:00–8:00 PM".
    public func when(_ event: AgendaEvent) -> String {
        household.fmt.when(event.start, event.end, allDay: event.isAllDay)
    }

    /// "Landed on work@ · from office@church.example".
    public func inviteMeta(_ event: AgendaEvent) -> String {
        var parts: [String] = []
        if let account = event.source.account { parts.append("Landed on \(account)@") }
        if let organizer = event.organizer { parts.append("from \(Self.shortName(organizer))") }
        if !event.meetingLinks.isEmpty, let service = event.meetingService { parts.append("\(service) link in the invite") }
        return parts.joined(separator: " · ")
    }

    /// The line under an invite's buttons.
    public func inviteStatus(_ event: AgendaEvent) -> String {
        let who = event.organizer.map(Self.shortName) ?? "the organizer"
        guard let reply = replies[event.id] else { return "Your reply emails \(who)." }
        switch reply.state {
        case .waiting(let until):
            let seconds = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
            return "Sending \(reply.response.buttonLabel) in \(seconds) s"
        case .sending: return "Sending \(reply.response.buttonLabel)…"
        case .sent: return "\(reply.response.pastTense) · \(who) gets an email"
        case .failed(let message): return "Didn't send: \(message)"
        }
    }

    /// "office" from "office@church.example"; a display name stays as is.
    static func shortName(_ organizer: String) -> String {
        guard let at = organizer.firstIndex(of: "@") else { return organizer }
        return String(organizer[..<at])
    }

    /// The meta line under an agenda row: "work · Zoom", "Family · iCloud", "From Robin's calendar · busy only".
    public func rowMeta(_ event: AgendaEvent) -> String {
        if event.busyOnly { return "From \(event.source.account ?? "their")@ · shown as busy only" }
        var parts = [event.source.label]
        if case .apple = event.source { parts.append("iCloud") }
        if let service = event.meetingService { parts.append(service) }
        if event.isReminder { parts = ["Reminder"] }
        return parts.joined(separator: " · ")
    }

    public func rowTitle(_ event: AgendaEvent) -> String {
        BusyOnly.title(for: event, partnerName: household.partnerName)
    }
}
