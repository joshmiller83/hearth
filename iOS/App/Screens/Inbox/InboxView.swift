import HearthCore
import HearthKit
import SwiftUI

/// Every inbox, sorted into queues. Nothing moves until you approve a queue.
struct InboxView: View {
    @Environment(AppModel.self) private var app
    @State private var opened: TriagedMail?

    var body: some View {
        let inbox = app.inbox
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Inbox").font(.hTitle).displayTracking().foregroundStyle(Theme.ink)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
                AccountChips()
                Text(inbox.sweepLine).font(.custom(Typeface.regular, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
                if case .failed(let message) = inbox.phase { Notice(text: message) }
                if let unsorted = inbox.unsortedNote { Notice(symbol: "tray", text: unsorted, tint: .ice) }
                QueueTiles()
                QueueList(opened: $opened)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom) { ActionBar(opened: $opened) }
        .refreshable { await inbox.refresh(force: true) }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $opened) { mail in ThreadView(mail: mail) }
    }
}

private struct AccountChips: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let inbox = app.inbox
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip("All \(inbox.accounts.count)", selected: inbox.account == nil) { inbox.account = nil }
                ForEach(inbox.accounts, id: \.self) { account in
                    chip(account, selected: inbox.account == account) { inbox.account = account }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accounts")
    }

    func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom(selected ? Typeface.bold : Typeface.semibold, size: 14, relativeTo: .subheadline))
                .foregroundStyle(selected ? Theme.bg : Theme.chipInk)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(selected ? Theme.ink : Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct QueueTiles: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let inbox = app.inbox
        HStack(spacing: 6) {
            ForEach(MailQueue.allCases, id: \.self) { queue in
                let selected = inbox.queue == queue
                Button {
                    inbox.queue = queue
                } label: {
                    VStack(spacing: 2) {
                        Text("\(inbox.count(queue))").font(.custom(Typeface.bold, size: 22, relativeTo: .title2))
                        Text(queue.label).font(.custom(Typeface.semibold, size: 12, relativeTo: .caption))
                    }
                    .foregroundStyle(selected ? Theme.emberSoft : Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(
                        selected ? Theme.emberDeep : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                            .strokeBorder(selected ? Theme.ember : Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(queue.label), \(inbox.count(queue))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct QueueList: View {
    @Environment(AppModel.self) private var app
    @Binding var opened: TriagedMail?
    @State private var showLeftOut = false

    var body: some View {
        let inbox = app.inbox
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(inbox.headline).eyebrow().accessibilityAddTraits(.isHeader)
                Spacer()
                Text("Times in \(zoneName)").font(.custom(Typeface.regular, size: 12, relativeTo: .caption)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 4)
            if inbox.queue == .archive, let kept = inbox.keptNote {
                Notice(symbol: "lock", text: kept, tint: .ice)
            }
            Card(padding: EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)) {
                if inbox.rows.isEmpty {
                    Text(inbox.snapshot == nil ? "Waiting for the first sweep." : "Nothing here.")
                        .font(.hBody).foregroundStyle(Theme.muted).padding(.vertical, 14)
                }
                ForEach(Array(inbox.rows.enumerated()), id: \.element.id) { index, row in
                    MailRow(row: row) { if !row.isBundle { opened = row.first } }
                        .overlay(alignment: .top) { if index > 0 { Hairline() } }
                }
            }
            if inbox.leftOutCount > 0 { leftOut }
        }
        .onChange(of: inbox.queue) { showLeftOut = false }
    }

    /// "2 left out · they stay in your inbox", folded; Archive them (an errant reply needn't sit there).
    @ViewBuilder var leftOut: some View {
        let inbox = app.inbox
        let folded = inbox.leftOutRows
        HStack(spacing: 4) {
            Button {
                withAnimation(.snappy) { showLeftOut.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if !folded.isEmpty {
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                            .rotationEffect(.degrees(showLeftOut ? 90 : 0))
                    }
                    Text("\(inbox.leftOutCount) left out · stay\(inbox.leftOutCount == 1 ? "s" : "") in your inbox")
                        .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline))
                }
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, minHeight: Theme.touch, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(folded.isEmpty)
            .accessibilityHint(folded.isEmpty ? "" : showLeftOut ? "Hides them" : "Shows them")
            if inbox.queue != .archive {
                TextButton(title: "Archive them") { inbox.archiveLeftOut() }
            }
        }
        .padding(.horizontal, 4)
        if showLeftOut, !folded.isEmpty {
            Card(padding: EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)) {
                ForEach(Array(folded.enumerated()), id: \.element.id) { index, row in
                    MailRow(row: row) { if !row.isBundle { opened = row.first } }
                        .overlay(alignment: .top) { if index > 0 { Hairline() } }
                }
            }
        }
    }

    var zoneName: String {
        let zone = app.household.zone
        return zone.identifier.hasPrefix("America/New_York")
            ? "Eastern" : (zone.localizedName(for: .generic, locale: .current) ?? zone.identifier)
    }
}

private struct MailRow: View {
    @Environment(AppModel.self) private var app
    let row: InboxModel.Row
    let open: () -> Void

    var body: some View {
        let inbox = app.inbox
        let left = inbox.isLeftOut(row)
        HStack(alignment: .center, spacing: 4) {
            content.opacity(left ? 0.45 : 1)
            Button {
                withAnimation(.snappy) { inbox.toggle(row) }
            } label: {
                ZStack {
                    Circle().fill(left ? Color.clear : Theme.emberDeep)
                    Circle().strokeBorder(left ? Theme.stone : Theme.emberLine, lineWidth: 1.5)
                    if !left { Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.emberSoft) }
                }
                .frame(width: 24, height: 24)
                .frame(width: Theme.touch, height: Theme.touch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(left ? "Put back in \(inbox.queue.label)" : "Leave out of \(inbox.queue.label)")
            .accessibilityValue(row.isBundle ? (row.first.bundle ?? "Bundle") : row.first.item.senderName)
        }
    }

    var content: some View {
        let mail = row.first
        let item = mail.item
        let left = app.inbox.isLeftOut(row)
        return Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Text(row.isBundle ? String(mail.bundle?.prefix(1) ?? "B") : item.initial)
                    .font(.custom(Typeface.bold, size: 15, relativeTo: .body))
                    .foregroundStyle(Theme.chipInk)
                    .frame(width: 36, height: 36)
                    .background(Theme.chip, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.isBundle ? (mail.bundle ?? "Bundle") : item.senderName)
                            .font(.custom(item.unread ? Typeface.bold : Typeface.semibold, size: 15, relativeTo: .body))
                            .foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer()
                        Text(app.inbox.time(item.date)).font(.custom(Typeface.regular, size: 12, relativeTo: .caption)).foregroundStyle(
                            Theme.muted)
                    }
                    Text(row.isBundle ? "\(row.items.count) updates on subscribed threads" : item.subject)
                        .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                    Text(row.isBundle ? "Nothing mentions you, assigns you, or asks for your review." : item.snippet)
                        .font(.hMeta).foregroundStyle(Theme.muted).lineLimit(2)
                    HStack(spacing: 6) {
                        TagChip(text: item.account, style: .plain)
                        TagChip(text: left ? TriagedMail.leftOutTag : mail.tag, style: left ? .plain : TagChip.style(for: mail.tag))
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

struct TagChip: View {
    enum Style {
        case ember
        case ice
        case plain
    }

    let text: String
    let style: Style

    static func style(for tag: String) -> Style {
        switch tag {
        case "Needs you", "Draft ready", "Family", "Security", "2 worth a look": .ember
        case "Invite", "Application", "Job hunt", "Job alert", "New issue", "Recruiter": .ice
        default: .plain
        }
    }

    var body: some View {
        Text(text)
            .font(.custom(Typeface.bold, size: 11, relativeTo: .caption2))
            .foregroundStyle(style == .ember ? Theme.emberSoft : style == .ice ? Theme.iceSoft : Theme.chipInk)
            .padding(.horizontal, 8)
            .frame(minHeight: 20)
            .background(style == .ember ? Theme.emberDeep : style == .ice ? Theme.iceDeep : Theme.chip, in: Capsule())
    }
}

/// The queue's button, always there; above it, each approved batch's countdown, Undo, and what happened.
private struct ActionBar: View {
    @Environment(AppModel.self) private var app
    @Binding var opened: TriagedMail?

    var body: some View {
        let inbox = app.inbox
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 6) {
                ForEach(inbox.approvals) { approval in
                    status(approval)
                }
                Button(inbox.actionLabel) {
                    if inbox.queue == .reply {
                        opened = inbox.rows.first { !inbox.isLeftOut($0) }?.first
                    } else {
                        inbox.approve()
                    }
                }
                .buttonStyle(.pill(.primary))
                .disabled(inbox.count(inbox.queue) == 0)
                Text(inbox.actionNote).font(.custom(Typeface.regular, size: 12, relativeTo: .caption)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Theme.tabBar.opacity(0.97))
            .overlay(alignment: .top) { Hairline() }
            .animation(.snappy, value: inbox.approvals.map(\.id))
        }
    }

    /// "Archiving 34 in 7 s · Undo", "Archiving 34…", "✓ Archived 34 ✕".
    func status(_ approval: InboxModel.Approval) -> some View {
        let inbox = app.inbox
        let failed: Bool = if case .failed = approval.state { true } else { false }
        return HStack(spacing: 8) {
            switch approval.state {
            case .waiting:
                Text(inbox.doing(approval)).foregroundStyle(Theme.iceSoft)
                Spacer(minLength: 4)
                TextButton(title: "Undo", color: Theme.ember) { inbox.undo(approval.id) }
            case .sending:
                ProgressView().tint(Theme.iceSoft)
                Text(inbox.doing(approval)).foregroundStyle(Theme.iceSoft)
                Spacer(minLength: 4)
            case .done, .failed:
                Label(inbox.doing(approval), systemImage: failed ? "exclamationmark.circle" : "checkmark")
                    .foregroundStyle(failed ? Theme.emberSoft : Theme.iceSoft)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    inbox.dismiss(approval.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
                        .frame(width: Theme.touch, height: Theme.touch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .font(.custom(Typeface.semibold, size: 15, relativeTo: .body))
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(minHeight: Theme.touch)
        .background(failed ? Theme.emberDeep : Theme.iceDeep, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}
