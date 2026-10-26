import HearthCore
import HearthKit
import SwiftUI

/// Plans: one agenda from every calendar, and the invites waiting on you.
struct PlansView: View {
    enum Mode: Hashable {
        case agenda
        case aroundTown
    }

    @Environment(AppModel.self) private var app
    @Binding var showCapture: Bool
    @State private var mode: Mode = .agenda

    var body: some View {
        ScreenScroll {
            HStack {
                Text("Plans").font(.hTitle).displayTracking().foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                RoundIconButton(symbol: "plus", label: "Add an event from a photo or a note", filled: true) { showCapture = true }
            }
            .padding(.leading, 4)

            SegmentedPills(options: [(Mode.agenda, "Agenda"), (Mode.aroundTown, "Around town")], selection: $mode)

            switch mode {
            case .agenda: AgendaSection()
            case .aroundTown: AroundTownPlaceholder()
            }
        }
        .refreshable { await app.refreshAll(force: true) }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The week strip, the invites, and the selected day's events.
struct AgendaSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let plans = app.plans
        VStack(alignment: .leading, spacing: 14) {
            if case .failed(let message) = plans.phase {
                Notice(text: message)
            }
            if plans.calendarAccess == .notDetermined {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Add your iCloud calendars").font(.hCardTitle).foregroundStyle(Theme.ink)
                        Text("Family and Birthdays live on this phone. Hearth reads them to build one agenda.")
                            .font(.hMeta).foregroundStyle(Theme.muted)
                        Button("Allow calendar access") { Task { await plans.requestCalendarAccess() } }
                            .buttonStyle(.pill(.secondary))
                    }
                }
            }
            WeekStrip()
            let invites = plans.invites
            if !invites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Waiting on you · \(invites.filter(\.isWaitingOnMe).count)").eyebrow()
                        .padding(.horizontal, 4).padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(invites) { InviteCard(event: $0) }
                }
            }
            DayList()
        }
    }
}

/// Seven days from today; an ember dot marks a day with an invite, a muted one a day with plans.
struct WeekStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let plans = app.plans
        let calendar = app.household.fmt.calendar
        HStack(spacing: 4) {
            ForEach(plans.week) { day in
                let selected = calendar.isDate(day.date, inSameDayAs: plans.selectedDay)
                Button {
                    plans.selectedDay = day.date
                } label: {
                    VStack(spacing: 2) {
                        Text(day.tag).font(.hTiny).foregroundStyle(selected ? Theme.onEmber : Theme.muted)
                        Text("\(day.number)").font(.custom(selected ? Typeface.bold : Typeface.semibold, size: 18, relativeTo: .headline))
                            .foregroundStyle(selected ? Theme.onEmber : Theme.ink)
                        Circle()
                            .fill(day.mark == .invite ? Theme.ember : day.mark == .plans ? Theme.muted : .clear)
                            .frame(width: 4, height: 4)
                            .opacity(selected ? 0 : 1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(selected ? Theme.ember : .clear, in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(weekdayLabel(day))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This week")
    }

    func weekdayLabel(_ day: WeekDay) -> String {
        let fmt = app.household.fmt
        var label = fmt.longDay(day.date)
        if day.mark == .invite { label += ", invites waiting" } else if day.mark == .plans { label += ", has plans" }
        return label
    }
}

/// One invite: what, when, where it landed, any clash, and Yes / Maybe / No.
struct InviteCard: View {
    @Environment(AppModel.self) private var app
    let event: AgendaEvent

    var body: some View {
        let plans = app.plans
        let reply = plans.replies[event.id]
        Card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(.custom(Typeface.bold, size: 16, relativeTo: .headline)).foregroundStyle(Theme.ink)
                    Text(plans.when(event)).font(.custom(Typeface.regular, size: 14, relativeTo: .subheadline)).foregroundStyle(
                        Theme.inkSoft)
                    Text(plans.inviteMeta(event)).font(.hMeta).foregroundStyle(Theme.muted)
                }
                if let conflict = plans.agenda.conflictSentence(for: event) {
                    Notice(text: conflict)
                }
                HStack(spacing: 6) {
                    ForEach([RSVP.accepted, .tentative, .declined], id: \.self) { response in
                        let pressed = reply?.response == response
                        Button(response.buttonLabel) { plans.reply(to: event, response) }
                            .font(.hLabel)
                            .foregroundStyle(pressed ? Theme.bg : Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(pressed ? Theme.ink : Theme.chip, in: Capsule())
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(pressed ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Reply to \(event.title)")
                // Ticks once a second while an answer is waiting to send.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack {
                        Text(plans.inviteStatus(event)).font(.custom(Typeface.regular, size: 12, relativeTo: .caption)).foregroundStyle(
                            Theme.muted)
                        Spacer()
                        if case .waiting = reply?.state {
                            Button("Undo") { plans.undoReply(to: event) }
                                .font(.hLabel).foregroundStyle(Theme.ember)
                                .frame(minHeight: 32)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("invite-\(event.sourceEventId)")
    }
}

/// The selected day across every calendar, with the NOW line.
struct DayList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        let plans = app.plans
        let fmt = app.household.fmt
        let events = plans.dayEvents
        let now = app.now
        VStack(alignment: .leading, spacing: 8) {
            Text(plans.isToday ? "Today · every calendar" : "\(fmt.shortDay(plans.selectedDay)) · every calendar").eyebrow()
                .padding(.horizontal, 4).padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            Card(padding: EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14)) {
                if events.isEmpty {
                    Text("Nothing on the calendar.").font(.hBody).foregroundStyle(Theme.muted).padding(.vertical, 14)
                }
                let nowIndex = plans.isToday ? events.firstIndex { $0.start > now && !$0.isAllDay } ?? events.count : nil
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    if index == nowIndex { NowLine(time: fmt.time(now)) }
                    AgendaRow(
                        event: event, isPast: plans.isToday && event.end <= now && !event.isAllDay,
                        isLast: index == events.count - 1
                    ) { url in openURL(url) }
                }
                if let nowIndex, nowIndex == events.count, !events.isEmpty { NowLine(time: fmt.time(now)) }
            }
        }
    }
}

struct NowLine: View {
    let time: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.ember).frame(width: 8, height: 8)
            Text("NOW · \(time)").font(.custom(Typeface.bold, size: 12, relativeTo: .caption)).foregroundStyle(Theme.ember)
            Rectangle().fill(Theme.ember).frame(height: 1)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now, \(time)")
    }
}

struct AgendaRow: View {
    @Environment(AppModel.self) private var app
    let event: AgendaEvent
    var isPast = false
    var isLast = false
    var join: (URL) -> Void

    var body: some View {
        let plans = app.plans
        let fmt = app.household.fmt
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                if event.isAllDay {
                    Text("All day").font(.custom(Typeface.bold, size: 14, relativeTo: .subheadline))
                } else {
                    Text(fmt.time(event.start)).font(.custom(Typeface.bold, size: 14, relativeTo: .subheadline))
                    Text(event.isReminder ? "reminder" : fmt.timeNoMeridiem(event.end))
                        .font(.custom(Typeface.regular, size: 12, relativeTo: .caption)).foregroundStyle(Theme.muted)
                }
            }
            .foregroundStyle(Theme.ink)
            .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(plans.rowTitle(event))
                    .font(.hRowTitle)
                    .foregroundStyle(event.busyOnly || isPast ? Theme.muted : Theme.ink)
                    .lineLimit(2)
                Text(plans.rowMeta(event)).font(.hMeta).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isPast, let link = event.meetingLinks.first.flatMap(URL.init(string:)) {
                Button("Join") { join(link) }
                    .font(.hLabel)
                    .foregroundStyle(Theme.onIce)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Theme.ice, in: Capsule())
                    .buttonStyle(.plain)
                    .accessibilityLabel("Join \(event.meetingService ?? "call"): \(event.title)")
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { if !isLast { Hairline() } }
        .opacity(isPast ? 0.7 : 1)
        .accessibilityElement(children: .combine)
    }
}
