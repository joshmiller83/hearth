import HearthCore
import HearthKit
import SwiftUI

/// Facebook, as far as it can come in: Meta has no way for apps to read events
/// or groups, so Hearth uses its notification emails, shares and screenshots,
/// Add to Calendar, and the feeds of pages that post the same events.
struct FacebookView: View {
    @Environment(AppModel.self) private var app
    @State private var capturing = false
    @State private var reading: TriagedMail?

    var body: some View {
        let facebook = app.facebook
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Text("FB").font(.custom(Typeface.bold, size: 16, relativeTo: .headline)).foregroundStyle(Theme.chipInk)
                        .frame(width: 52, height: 52).background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Facebook").font(.hTitle).displayTracking().foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                        Text("Partial · 3 ways in").font(.hMeta).foregroundStyle(Theme.muted)
                    }
                }
                Notice(
                    symbol: "info.circle",
                    text:
                        "Meta no longer lets apps read your events or groups, so a direct connection isn't possible. Hearth brings Facebook in through side doors instead.",
                    tint: .ice)
                ways
                lately
                rules
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await facebook.refresh() }
        .sheet(isPresented: $capturing) { CaptureView() }
        .navigationDestination(item: $reading) { mail in ThreadView(mail: mail) }
    }

    var ways: some View {
        let facebook = app.facebook
        return VStack(alignment: .leading, spacing: 8) {
            Text("How it comes in").eyebrow().padding(.horizontal, 4)
            VStack(spacing: 0) {
                way(
                    "envelope", "Notification emails",
                    "Facebook emails invites, family-group posts and birthdays. Your rules keep what matters.",
                    "Via gmailkit · \(facebook.week.count) this week, \(facebook.keptThisWeek) kept")
                way(
                    "square.and.arrow.up", "Share or screenshot", "Share an event or screenshot it. Claude reads the date, time and place.",
                    "Share sheet · \(facebook.shares) this month")
                way(
                    "calendar.badge.plus", "Add to Calendar", "When an event shows Add to Calendar, tap it. It lands in Apple Calendar.",
                    "Picked up from \(app.household.familyCalendar)")
                HStack(alignment: .top, spacing: 12) {
                    IconTile(symbol: "dot.radiowaves.up.forward", tint: .neutral)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pages you follow").font(.hRowTitle).foregroundStyle(Theme.ink)
                        Text("Most post the same events on their own site. Claude adds those as feeds.").font(.hMeta).foregroundStyle(
                            Theme.muted)
                        NavigationLink("Open event feeds") { FeedsView() }
                            .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.ember)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Hairline() }
            }
            .padding(.horizontal, 14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
    }

    func way(_ symbol: String, _ title: String, _ detail: String, _ count: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, tint: .neutral)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.hRowTitle).foregroundStyle(Theme.ink)
                Text(detail).font(.hMeta).foregroundStyle(Theme.muted)
                Text(count).font(.custom(Typeface.semibold, size: 12, relativeTo: .caption)).foregroundStyle(Theme.ice)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { if title != "Notification emails" { Hairline() } }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder var lately: some View {
        let facebook = app.facebook
        if !facebook.events.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Lately from Facebook").eyebrow().padding(.horizontal, 4)
                ForEach(facebook.events.prefix(3)) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notification email · \(app.signals.age(item.date))").font(
                            .custom(Typeface.bold, size: 12, relativeTo: .caption)
                        )
                        .foregroundStyle(Theme.ice)
                        Text(item.subject).font(.custom(Typeface.bold, size: 17, relativeTo: .headline)).foregroundStyle(Theme.ink)
                        if !item.snippet.isEmpty { Text(item.snippet).font(.hMeta).foregroundStyle(Theme.muted) }
                        HStack(spacing: 8) {
                            Button("Add to \(app.household.familyCalendar)") {
                                capturing = true
                                Task { await facebook.capture(item) }
                            }
                            .buttonStyle(.pill(.primary, height: 42))
                            Button("Read") {
                                reading = TriagedMail(
                                    item: item, queue: nil, tag: "Facebook", reason: "Facebook", sortedBy: .rule("facebook"))
                            }
                            .buttonStyle(.pill(.secondary, height: 42))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                }
            }
        }
    }

    var rules: some View {
        let facebook = app.facebook
        return VStack(alignment: .leading, spacing: 10) {
            Text("Tell Claude what matters").eyebrow().padding(.horizontal, 4)
            let current = FacebookModel.chips(facebook.rules)
            if !current.isEmpty, facebook.proposal == nil { chips(current) }
            if facebook.phase == .working {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.muted)
                    Text("Reading your Facebook mail…").font(.hMeta).foregroundStyle(Theme.muted)
                }
            }
            if case .failed(let message) = facebook.phase { Notice(text: message) }
            if let proposal = facebook.proposal {
                Text(proposal.reply).font(.custom(Typeface.regular, size: 15, relativeTo: .body)).foregroundStyle(Theme.inkSoft)
                    .lineSpacing(3)
                chips(FacebookModel.chips(proposal.rules))
                Text("Last week that would have kept \(proposal.kept) of \(proposal.total).").font(.hMeta).foregroundStyle(Theme.muted)
                if facebook.saved {
                    Label("Saved. The relay sorts by these from the next sweep.", systemImage: "checkmark")
                        .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.iceSoft)
                } else {
                    Button("Use these rules") { facebook.save() }.buttonStyle(.pill(.primary, height: 44))
                }
            } else if current.isEmpty {
                Text("Try: \u{201C}Only the family group and anything from Mom. Skip Marketplace.\u{201D}").font(.hMeta).foregroundStyle(
                    Theme.muted
                )
                .padding(.horizontal, 4)
            }
        }
    }

    func chips(_ labels: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(labels, id: \.self) { label in
                Text(label).font(.custom(Typeface.semibold, size: 13, relativeTo: .footnote))
                    .foregroundStyle(label.hasPrefix("Archive") ? Theme.muted : Theme.iceSoft)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(label.hasPrefix("Archive") ? Theme.chip : Theme.iceDeep, in: Capsule())
            }
        }
    }

    var composer: some View {
        @Bindable var facebook = app.facebook
        return HStack(spacing: 8) {
            TextField(
                "", text: $facebook.draft, prompt: Text("Tell Claude what to keep from Facebook…").foregroundStyle(Theme.muted),
                axis: .vertical
            )
            .lineLimit(1...4)
            .font(.custom(Typeface.regular, size: 15, relativeTo: .body))
            .foregroundStyle(Theme.ink)
            .tint(Theme.ice)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 46)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(Theme.stoneDeep, lineWidth: 1))
            .accessibilityLabel("Message Claude about Facebook")
            Button {
                Task { await facebook.tell() }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.onEmber)
                    .frame(width: 46, height: 46).background(Theme.ember, in: Circle())
            }
            .accessibilityLabel("Send")
            .disabled(facebook.phase == .working || facebook.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stoneDeep.opacity(0.6)).frame(height: 1) }
    }
}
