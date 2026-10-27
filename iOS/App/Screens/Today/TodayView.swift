import HearthCore
import HearthKit
import SwiftUI

/// Today: the next thing, what needs you, and what's coming. The layout stays
/// put; only the parts that take judgment change.
struct TodayView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Binding var tab: AppTab
    @Binding var showCapture: Bool
    @Binding var path: [Destination]

    var body: some View {
        let today = TodaySummary.make(app: app)
        ScreenScroll {
            header
            greeting(today)
            if !app.isConfigured {
                setupCard
            }
            if let next = today.nextUp {
                nextUpCard(next, label: today.nextUpLabel ?? "Next up", meta: today.nextUpMeta ?? "")
            }
            if !today.needsYou.isEmpty {
                needsYouCard(today.needsYou)
            }
            if let idea = today.kindIdea {
                kindIdeaCard(idea, for: today.kindIdeaFor)
            }
            if let triage = today.triage {
                triageCard(triage, newMail: today.newMail)
            }
            if !today.comingUp.isEmpty {
                comingUpCard(today.comingUp)
            }
        }
        .refreshable { await app.refreshAll(force: true) }
        .toolbar(.hidden, for: .navigationBar)
    }

    var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "flame")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.ember)
                    .accessibilityHidden(true)
                Text("Hearth").font(.hBrand).foregroundStyle(Theme.ink)
            }
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            HStack(spacing: 2) {
                RoundIconButton(symbol: "plus", label: "Add to Hearth: a photo or a note") { showCapture = true }
                RoundIconButton(symbol: "bell", label: "Signals", badge: app.signals.badge) { path.append(.signals) }
                Button {
                    path.append(.sources)
                } label: {
                    Avatar(initial: String(app.household.ownerName.prefix(1)).uppercased())
                        .frame(width: Theme.touch, height: Theme.touch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sources and rules")
            }
        }
    }

    func greeting(_ today: TodaySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(today.dateLine).eyebrow()
                .padding(.bottom, 6)
            Text(today.greeting)
                .font(.hTitle).displayTracking()
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(today.sweepLine)
                .font(.hBody).foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .padding(.top, 8)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    var setupCard: some View {
        Card(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16), border: Theme.emberLine) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect your relay").eyebrow(Theme.emberSoft)
                Text("Hearth reads mail and Google calendars through the relay on your Mac. Paste its address and key in Sources.")
                    .font(.hBody).foregroundStyle(Theme.muted)
                Button("Open Sources") { path.append(.sources) }
                    .buttonStyle(.pill(.primary))
            }
        }
    }

    func nextUpCard(_ event: AgendaEvent, label: String, meta: String) -> some View {
        let fmt = app.household.fmt
        return Card {
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(fmt.timeNoMeridiem(event.start)).font(.hNumber)
                    Text(fmt.meridiem(event.start)).font(.hTiny).tracking(0.44)
                }
                .foregroundStyle(Theme.iceSoft)
                .frame(width: 56, height: 56)
                .background(Theme.iceDeep, in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).eyebrow(Theme.ice)
                    Text(event.title).font(.hCardTitle).foregroundStyle(Theme.ink).lineLimit(2)
                    Text(meta).font(.hMeta).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(label). \(event.title) at \(fmt.time(event.start)). \(meta)")
                if let link = event.meetingLinks.first.flatMap(URL.init(string:)) {
                    Button {
                        openURL(link)
                    } label: {
                        Image(systemName: "video")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.onIce)
                            .frame(width: 48, height: 48)
                            .background(Theme.ice, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Join \(event.meetingService ?? "call")")
                }
            }
        }
        .accessibilityIdentifier("next-up")
    }

    func needsYouCard(_ items: [TodaySummary.NeedsYou]) -> some View {
        ListCard(title: "Needs you · \(items.count)", link: ("All queues", { tab = .inbox })) {
            ForEach(items) { item in
                switch item.kind {
                case .invite:
                    LinkRow(symbol: "calendar", tint: .ice, title: item.title, detail: item.detail) { tab = .plans }
                case .text:
                    let summary = app.chats.waiting.first { $0.waitingId == item.id }
                    LinkRow(symbol: "message", tint: .ember, title: item.title, detail: item.detail) {
                        if let summary { path.append(.texts(summary.thread.id)) }
                    }
                    .contextMenu {
                        if let summary { Button("Not for me", systemImage: "minus.circle") { app.chats.leaveOut(summary) } }
                    }
                    .accessibilityAction(named: "Not for me") { if let summary { app.chats.leaveOut(summary) } }
                case .reply:
                    LinkRow(symbol: "arrowshape.turn.up.left", tint: .ember, title: item.title, detail: item.detail) { tab = .inbox }
                        .contextMenu {
                            Button("Not for me", systemImage: "minus.circle") { app.inbox.leaveOut(item.id) }
                        }
                        .accessibilityAction(named: "Not for me") { app.inbox.leaveOut(item.id) }
                case .signal:
                    LinkRow(symbol: "bell", tint: .neutral, title: item.title, detail: item.detail) { path.append(.signals) }
                }
            }
        }
        .accessibilityIdentifier("needs-you")
    }

    /// The brief's one kind idea: the design's "A small surprise for …" card.
    func kindIdeaCard(_ idea: String, for person: String?) -> some View {
        Card(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16), border: Theme.emberLine) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Avatar(initial: String((person ?? "♥").prefix(1)), size: 42, ring: Theme.ember)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.map { "A small idea for \($0)" } ?? "A small idea").eyebrow(Theme.emberSoft)
                        Text(idea).font(.hCardTitle).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Button("Plan it quietly") { tab = .people }.buttonStyle(.pill(.primary))
                    Button("Not this week") { app.kindIdeaDismissed = true }.buttonStyle(.pill(.secondary))
                }
            }
        }
    }

    /// The design's stacked bar: Reply ember, Job hunt ice, Archive stone, Delete dark stone.
    func triageCard(_ triage: [(queue: MailQueue, count: Int)], newMail: Int) -> some View {
        Card(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Inbox, triaged").eyebrow()
                    Spacer()
                    Text("\(newMail) new since the last sweep").font(.hMeta).foregroundStyle(Theme.muted)
                }
                GeometryReader { geo in
                    let total = max(1, triage.reduce(0) { $0 + $1.count })
                    HStack(spacing: 3) {
                        ForEach(triage, id: \.queue) { entry in
                            RoundedRectangle(cornerRadius: 5).fill(color(entry.queue))
                                .frame(width: max(entry.count > 0 ? 6 : 0, (geo.size.width - 9) * CGFloat(entry.count) / CGFloat(total)))
                        }
                    }
                }
                .frame(height: 10)
                .accessibilityHidden(true)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 8) {
                    ForEach(triage, id: \.queue) { entry in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(color(entry.queue)).frame(width: 10, height: 10)
                            Text(entry.queue.label).font(.custom(Typeface.regular, size: 14, relativeTo: .subheadline)).foregroundStyle(
                                Theme.ink)
                            Spacer()
                            Text("\(entry.count)").font(.custom(Typeface.bold, size: 14, relativeTo: .subheadline)).foregroundStyle(
                                Theme.ink)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Button("Review the queues") { tab = .inbox }.buttonStyle(.pill(.secondary))
            }
        }
    }

    func color(_ queue: MailQueue) -> Color {
        switch queue {
        case .reply: Theme.ember
        case .jobHunt: Theme.ice
        case .archive: Theme.stone
        case .delete: Theme.stoneDeep
        }
    }

    func comingUpCard(_ events: [AgendaEvent]) -> some View {
        let fmt = app.household.fmt
        return ListCard(title: "Coming up", link: ("See all", { tab = .plans })) {
            ForEach(events) { event in
                HStack(spacing: 12) {
                    DateColumn(tag: fmt.weekdayTag(event.start), day: fmt.dayOfMonth(event.start))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.hRowTitle).foregroundStyle(Theme.ink).lineLimit(2)
                        Text(event.isAllDay ? "All day · \(event.source.label)" : "\(fmt.time(event.start)) · \(event.source.label)")
                            .font(.hMeta).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Hairline() }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
