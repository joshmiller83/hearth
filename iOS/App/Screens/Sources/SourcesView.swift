import HearthCore
import HearthKit
import SwiftUI
import UserNotifications

/// Sources & rules: where Hearth reads from, its keys, and the owner's switches.
struct SourcesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScreenScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sources").font(.hTitle).displayTracking().foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Hearth reads from many places and depends on none of them. Each one plugs in through its own adapter.")
                    .font(.hBody).foregroundStyle(Theme.muted).lineSpacing(3)
            }
            .padding(.horizontal, 4)

            GmailkitCard()
            RelayCard()
            ClaudeCard()
            NotificationsCard()
            CalendarsCard()
            HowTodayCard()
            RulesCard()
            MailRulesCard()
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StatusPill: View {
    var text: String
    var good: Bool

    var body: some View {
        Text(text)
            .font(.custom(Typeface.bold, size: 12, relativeTo: .caption))
            .foregroundStyle(good ? Theme.iceSoft : Theme.emberSoft)
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .background(good ? Theme.iceDeep : Theme.emberDeep, in: Capsule())
    }
}

private struct LetterTile: View {
    var letters: String
    var tint: Tint = .neutral

    var body: some View {
        Text(letters)
            .font(.custom(Typeface.bold, size: 13, relativeTo: .footnote))
            .foregroundStyle(tint.foreground)
            .frame(width: 38, height: 38)
            .background(tint.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// gmailkit, through the relay: its state, the accounts, the last sweep.
private struct GmailkitCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let health = app.health
        let state = health?.gmailkit?.state
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    LetterTile(letters: "GK", tint: .ember)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("gmailkit").font(.hRowTitle).foregroundStyle(Theme.ink)
                        Text("Mail and Google Calendar · MCP over a private relay").font(.hMeta).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let state {
                        StatusPill(text: state == .up ? "Healthy" : state == .starting ? "Starting" : "Down", good: state == .up)
                    }
                }
                if let accounts = health?.accounts, !accounts.isEmpty {
                    FlowChips(items: accounts.map(\.alias))
                }
                Text(sweepLine(health)).font(.hMeta).foregroundStyle(Theme.muted).lineSpacing(2)
                if let problem = app.relayProblem {
                    Notice(text: problem)
                }
            }
        }
    }

    func sweepLine(_ health: HealthResponse?) -> String {
        let keys = "Refresh tokens stay in gmailkit's encrypted bundle; the phone holds only a relay key."
        guard let health, let fmt = Optional(app.household.fmt) else { return keys }
        if let calendar = health.jobs?.first(where: { $0.name == "calendar" }), let last = calendar.lastSuccess {
            return "Last calendar sweep \(fmt.time(last)). " + keys
        }
        return keys
    }
}

/// Account aliases as chips that wrap.
struct FlowChips: View {
    var items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.custom(Typeface.semibold, size: 13, relativeTo: .footnote))
                    .foregroundStyle(Theme.chipInk)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .background(Theme.chip, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A simple wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The relay's address and key.
private struct RelayCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var sources = app.sources
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Relay").eyebrow()
                TextField("hearth.example.com", text: $sources.relayURLText)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fieldStyle()
                    .accessibilityLabel("Relay address")
                SecureField(sources.hasRelayKey ? "Key saved (paste to replace)" : "Relay key (hrk_…)", text: $sources.relayKeyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fieldStyle()
                    .accessibilityLabel("Relay key")
                Button("Save and check") { Task { await sources.saveRelay() } }
                    .buttonStyle(.pill(.primary))
                CheckLine(check: sources.relayCheck)
            }
        }
    }
}

/// The Claude API key.
private struct ClaudeCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var sources = app.sources
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    LetterTile(letters: "AI", tint: .ice)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude API").font(.hRowTitle).foregroundStyle(Theme.ink)
                        Text("Key in the iOS Keychain. Opus 5.5 plans, writes and reads photos; Haiku 5.5 sorts.")
                            .font(.hMeta).foregroundStyle(Theme.muted)
                    }
                }
                SecureField(sources.hasClaudeKey ? "Key saved (paste to replace)" : "sk-ant-…", text: $sources.claudeKeyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fieldStyle()
                    .accessibilityLabel("Claude API key")
                HStack(spacing: 8) {
                    Button("Save") { Task { await sources.saveClaudeKey() } }
                        .buttonStyle(.pill(.primary))
                    if sources.hasClaudeKey {
                        Button("Check") { Task { await sources.checkClaude() } }
                            .buttonStyle(.pill(.secondary))
                    }
                }
                CheckLine(check: sources.claudeCheck)
            }
        }
    }
}

private struct CheckLine: View {
    var check: SourcesModel.Check

    var body: some View {
        switch check {
        case .idle: EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.hMeta).foregroundStyle(Theme.muted)
            }
        case .ok(let text): Notice(symbol: "checkmark.circle", text: text, tint: .ice)
        case .failed(let text): Notice(text: text)
        }
    }
}

private struct CalendarsCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let accounts = app.health?.accounts?.count
        let access = app.plans.calendarAccess
        ListCard(title: "Calendars") {
            row(
                letters: "GC", title: "Google Calendar",
                detail: accounts.map { "All \($0) accounts, through gmailkit" } ?? "Through gmailkit, once the relay is connected",
                status: app.plans.fetchedAt != nil ? "Synced" : nil)
            row(
                letters: "iC", title: "Apple Calendar",
                detail: "Family and Birthdays, from iCloud. New family events land in \(app.household.familyCalendar).",
                status: access == .full ? "Synced" : nil)
            if access != .full {
                Button(access == .denied ? "Open Settings to allow calendars" : "Allow calendar access") {
                    if access == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    } else {
                        Task { await app.plans.requestCalendarAccess() }
                    }
                }
                .buttonStyle(.pill(.secondary))
                .padding(.bottom, 10)
            }
        }
    }

    func row(letters: String, title: String, detail: String, status: String?) -> some View {
        HStack(spacing: 12) {
            LetterTile(letters: letters)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.hRowTitle).foregroundStyle(Theme.ink)
                Text(detail).font(.hMeta).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let status { StatusPill(text: status, good: true) }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Hairline() }
    }
}

private struct HowTodayCard: View {
    var body: some View {
        ListCard(title: "How Today gets built") {
            step("Every 15 min", "Sync and sort", "No AI", "Mail, calendars and feeds, filed by your rules.")
            step("As it arrives", "Read the messy stuff", "Claude", "Photos, handwriting, notes, and pages without a feed.")
            step("6:30 AM", "Write the brief", "Claude", "What needs you, what can wait, one kind idea.")
            step("When you ask", "Ask and source chats", "Claude", "Answers, plans and new feeds, each waiting for your OK.")
            Text("The Today layout stays put. Claude only fills in the parts that take judgment.")
                .font(.hMeta).foregroundStyle(Theme.muted)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Hairline() }
        }
    }

    func step(_ when: String, _ title: String, _ who: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(when).font(.custom(Typeface.bold, size: 12, relativeTo: .caption)).foregroundStyle(Theme.emberSoft)
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.hRowTitle).foregroundStyle(Theme.ink)
                    Text(who).font(.hTiny).foregroundStyle(who == "No AI" ? Theme.chipInk : Theme.iceSoft)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(who == "No AI" ? Theme.chip : Theme.iceDeep, in: Capsule())
                }
                Text(detail).font(.hMeta).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Hairline() }
        .accessibilityElement(children: .combine)
    }
}

private struct RulesCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let rules = app.rules
        let partner = app.household.partnerName ?? "your partner"
        ListCard(title: "Rules") {
            toggle(
                "Ask before acting", "Sending, archiving, RSVPs and new calendar events wait for a tap. Always on.",
                isOn: true, locked: true
            ) { _ in }
            toggle(
                "Surprise guard", "Plans for \(partner) stay off their accounts and the shared Family calendar until you reveal them",
                isOn: rules.surpriseGuard
            ) { on in
                var new = rules
                new.surpriseGuard = on
                app.setRules(new)
            }
            toggle("Quiet hours, 9 PM–7 AM", "Family and anything urgent still get through", isOn: rules.quietHours.enabled) { on in
                var new = rules
                new.quietHours.enabled = on
                app.setRules(new)
            }
            toggle("Morning brief at 6:30 AM", "Queues and the brief are ready before you wake up", isOn: rules.morningBrief) { on in
                var new = rules
                new.morningBrief = on
                app.setRules(new)
            }
        }
    }

    func toggle(_ title: String, _ detail: String, isOn: Bool, locked: Bool = false, set: @escaping @MainActor (Bool) -> Void)
        -> some View
    {
        Toggle(isOn: Binding(get: { isOn }, set: { value in MainActor.assumeIsolated { set(value) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.hRowTitle).foregroundStyle(Theme.ink)
                Text(detail).font(.hMeta).foregroundStyle(Theme.muted)
            }
        }
        .tint(Theme.ember)
        .disabled(locked)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Hairline() }
    }
}

extension View {
    /// The design's text field: chip background, rounded, 44 points tall.
    func fieldStyle() -> some View {
        font(.hBody)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.touch)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The mail rules, each with a switch and how much of the inbox it catches now.
private struct MailRulesCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ListCard(title: "Mail rules") {
            ForEach(app.mailRules) { rule in
                Toggle(
                    isOn: Binding(get: { rule.enabled }, set: { on in MainActor.assumeIsolated { app.setMailRule(rule.id, enabled: on) } })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name).font(.hRowTitle).foregroundStyle(Theme.ink)
                        Text(detail(rule)).font(.hMeta).foregroundStyle(Theme.muted)
                    }
                }
                .tint(Theme.ember)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Hairline() }
            }
            Text("Rules run first, with no AI. Claude sorts only what no rule places, and nothing moves until you approve a queue.")
                .font(.hMeta).foregroundStyle(Theme.muted)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Hairline() }
        }
    }

    func detail(_ rule: MailRule) -> String {
        let destination: String
        switch rule.outcome {
        case .queue(let queue, _, let bundle): destination = bundle.map { "\(queue.label), bundled as \($0)" } ?? queue.label
        case .keep: destination = "Stays in the inbox"
        }
        let count = app.mailRuleMatches(rule)
        return count > 0 ? "\(destination) · \(count) in your inboxes now" : destination
    }
}

/// Pushes from the relay: the morning brief, scheduled sends, urgent signals.
private struct NotificationsCard: View {
    @Environment(AppModel.self) private var app
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    IconTile(symbol: "bell.badge", tint: .ember)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications").font(.hRowTitle).foregroundStyle(Theme.ink)
                        Text(detail).font(.hMeta).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                switch status {
                case .notDetermined:
                    Button("Allow notifications") {
                        Task {
                            _ = await Notifications.enable()
                            status = await Notifications.status()
                        }
                    }
                    .buttonStyle(.pill(.secondary))
                case .denied:
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.pill(.secondary))
                default:
                    EmptyView()
                }
            }
        }
        .task { status = await Notifications.status() }
    }

    var detail: String {
        let push = app.health?.push == true
        switch status {
        case .authorized, .provisional, .ephemeral:
            return push
                ? "On. The brief arrives after quiet hours; urgent things don't wait."
                : "On here. The relay needs its APNs key to send them."
        case .denied: return "Off in Settings."
        default: return "The 6:30 brief, scheduled sends, and anything urgent. Quiet from 9 PM to 7 AM."
        }
    }
}
