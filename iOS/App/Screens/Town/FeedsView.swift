import HearthCore
import HearthKit
import SwiftUI

/// Event feeds: what feeds Around town, and a chat where Claude finds more.
struct FeedsView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var typing: Bool

    var body: some View {
        let town = app.town
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    Text("Everything here feeds Around town. Claude keeps what fits you two and leaves the rest out.")
                        .font(.custom(Typeface.regular, size: 15, relativeTo: .body)).foregroundStyle(Theme.muted).padding(.horizontal, 4)
                    feedList
                    chat
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: town.chat.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
            // The proposal and its confirmation land at the bottom too: keep them above the composer.
            .onChange(of: town.proposal?.feed.name) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: town.addedFeed?.note) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await town.refresh() }
        .task { await town.refresh() }
    }

    var header: some View {
        let town = app.town
        let checked = town.feeds.compactMap(\.checkedAt).max()
        return HStack(spacing: 14) {
            Text("EV").font(.custom(Typeface.bold, size: 16, relativeTo: .headline)).foregroundStyle(Theme.iceSoft)
                .frame(width: 52, height: 52).background(Theme.iceDeep, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Event feeds").font(.hTitle).displayTracking().foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                Text(
                    "\(town.feeds.count) feed\(town.feeds.count == 1 ? "" : "s")"
                        + (checked.map { " · checked \(app.household.fmt.time($0))" } ?? "")
                )
                .font(.hMeta).foregroundStyle(Theme.muted)
            }
        }
    }

    var feedList: some View {
        let town = app.town
        return VStack(spacing: 0) {
            ForEach(Array(town.feeds.enumerated()), id: \.element.id) { index, feed in
                HStack(spacing: 12) {
                    IconTile(symbol: symbol(feed.kind), tint: feed.id == town.addedFeed?.id ? .ember : .neutral)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(feed.name).font(.hRowTitle).foregroundStyle(Theme.ink)
                            if feed.id == town.addedFeed?.id {
                                Text("New").font(.hTiny).foregroundStyle(Theme.onEmber).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.ember, in: Capsule())
                            }
                        }
                        Text(feed.sub).font(.hMeta).foregroundStyle(feed.problem == nil ? Theme.muted : Theme.emberSoft)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(feed.kind.label).font(.custom(Typeface.bold, size: 12, relativeTo: .caption)).foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { if index > 0 { Hairline() } }
                .contextMenu {
                    Button("Remove feed", systemImage: "minus.circle", role: .destructive) { Task { await town.remove(feed.id) } }
                }
            }
            if town.feeds.isEmpty {
                Text("No feeds yet. Ask Claude below to find a calendar for a place you like.").font(.hBody).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
            }
        }
        .padding(.horizontal, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Feeds")
    }

    func symbol(_ kind: Feed.Kind) -> String {
        switch kind {
        case .ical: "calendar"
        case .page: "doc.text"
        case .email: "envelope"
        }
    }

    @ViewBuilder var chat: some View {
        let town = app.town
        VStack(alignment: .leading, spacing: 12) {
            Text("Talk it through with Claude").eyebrow().padding(.horizontal, 4)
            ForEach(town.chat) { line in
                if line.fromOwner {
                    Text(line.text).font(.custom(Typeface.regular, size: 15, relativeTo: .body)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(
                            Theme.chip,
                            in: UnevenRoundedRectangle(
                                cornerRadii: .init(topLeading: 20, bottomLeading: 20, bottomTrailing: 6, topTrailing: 20))
                        )
                        .frame(maxWidth: 300, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else if !line.text.isEmpty {
                    Text(line.text).font(.custom(Typeface.regular, size: 15, relativeTo: .body)).foregroundStyle(Theme.inkSoft)
                        .lineSpacing(3).padding(.horizontal, 4).textSelection(.enabled)
                }
            }
            if town.chatPhase == .working {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.muted)
                    Text("Looking it up…").font(.hMeta).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 4)
            }
            if case .failed(let message) = town.chatPhase { Notice(text: message) }
            if let proposal = town.proposal { proposalCard(proposal) }
            if town.chat.isEmpty {
                Text("Try: \u{201C}The community center has a calendar online somewhere. Can you add it?\u{201D}")
                    .font(.hMeta).foregroundStyle(Theme.muted).padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder func proposalCard(_ proposal: FeedChatPrompt.Proposal) -> some View {
        let town = app.town
        VStack(alignment: .leading, spacing: 10) {
            Text("\(proposal.feed.name) · \(proposal.feed.kind == .ical ? "calendar feed" : "web page")")
                .font(.custom(Typeface.bold, size: 12, relativeTo: .caption)).foregroundStyle(Theme.ice)
            if let added = town.addedFeed {
                Label(added.note, systemImage: "checkmark").font(.custom(Typeface.semibold, size: 15, relativeTo: .body)).foregroundStyle(
                    Theme.iceInk)
                Text("They're in Around town now.").font(.hMeta).foregroundStyle(Theme.muted)
                TextButton(title: "Undo") { Task { await town.undoAdd() } }
            } else {
                if !proposal.feed.skip.isEmpty {
                    Text("Leaves out: " + proposal.feed.skip.joined(separator: ", ")).font(.hMeta).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 8) {
                    if !proposal.feed.skip.isEmpty, proposal.kept > 0 {
                        Button("Add, keep those \(proposal.kept)") { Task { await town.addProposed(keepAll: false) } }
                            .buttonStyle(.pill(.primary, height: 44))
                    }
                    Button(proposal.total > 0 ? "Add all \(proposal.total)" : "Add it") { Task { await town.addProposed(keepAll: true) } }
                        .buttonStyle(.pill(proposal.feed.skip.isEmpty ? .primary : .secondary, height: 44))
                }
                .disabled(town.chatPhase == .working)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            town.addedFeed == nil ? Theme.surface : Theme.iceDeep, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(
                town.addedFeed == nil ? Theme.ember : .clear, lineWidth: 1.5))
    }

    var composer: some View {
        @Bindable var town = app.town
        return HStack(spacing: 8) {
            TextField(
                "", text: $town.draft, prompt: Text("Tell Claude about a feed, or paste a link…").foregroundStyle(Theme.muted),
                axis: .vertical
            )
            .lineLimit(1...4)
            .font(.custom(Typeface.regular, size: 15, relativeTo: .body))
            .foregroundStyle(Theme.ink)
            .tint(Theme.ice)
            .focused($typing)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 46)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(Theme.stoneDeep, lineWidth: 1))
            .accessibilityLabel("Message Claude about event feeds")
            Button {
                typing = false
                Task { await town.send() }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.onEmber)
                    .frame(width: 46, height: 46).background(Theme.ember, in: Circle())
            }
            .accessibilityLabel("Send")
            .disabled(town.chatPhase == .working || town.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stoneDeep.opacity(0.6)).frame(height: 1) }
    }
}
