import HearthCore
import HearthKit
import SwiftUI

/// Ask Hearth: questions across mail, calendars and people. Claude shows what it
/// checked, answers, and proposes steps that wait for the owner's tap.
struct AskView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var typing: Bool
    @State private var changing = false

    var body: some View {
        let ask = app.ask
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    Text("Reads every source. Acts only when you say so.")
                        .font(.custom(Typeface.regular, size: 14, relativeTo: .subheadline))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 4)
                        .padding(.top, -6)
                    ForEach(ask.turns) { turn in
                        TurnView(turn: turn, change: change).id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: ask.turns.last?.answer) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: ask.turns.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom) { composer }
        .toolbar(.hidden, for: .navigationBar)
    }

    var header: some View {
        HStack(spacing: 8) {
            Text("Ask").font(.hTitle).displayTracking().foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if !app.ask.turns.isEmpty, !app.ask.isWorking {
                RoundIconButton(symbol: "square.and.pencil", label: "New conversation") { app.ask.startOver() }
            }
            HStack(spacing: 6) {
                Circle().fill(Theme.ice).frame(width: 7, height: 7).accessibilityHidden(true)
                Text("Claude Opus 5.5")
            }
            .font(.custom(Typeface.bold, size: 12, relativeTo: .caption))
            .foregroundStyle(Theme.chipInk)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.chip, in: Capsule())
        }
        .padding(.leading, 4)
    }

    /// The chips and the field, above the tab bar.
    var composer: some View {
        @Bindable var ask = app.ask
        return VStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(ask.suggestions, id: \.self) { suggestion in
                        Button(suggestion) { send(suggestion) }
                            .font(.custom(Typeface.semibold, size: 13, relativeTo: .footnote))
                            .foregroundStyle(Theme.chipInk)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .overlay(Capsule().strokeBorder(Theme.stoneDeep, lineWidth: 1))
                            .disabled(ask.isWorking)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            HStack(spacing: 8) {
                TextField(
                    "", text: $ask.draft,
                    prompt: Text(changing ? "What should change?" : "Ask across mail, calendars, people…").foregroundStyle(Theme.muted),
                    axis: .vertical
                )
                .lineLimit(1...4)
                .font(.custom(Typeface.regular, size: 15, relativeTo: .body))
                .foregroundStyle(Theme.ink)
                .tint(Theme.ice)
                .focused($typing)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 46)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(Theme.stoneDeep, lineWidth: 1))
                .accessibilityLabel("Ask Hearth")
                Button {
                    // Dictation is the keyboard's own microphone.
                    typing = true
                } label: {
                    Image(systemName: "mic").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.ink)
                        .frame(width: 46, height: 46).background(Theme.chip, in: Circle())
                }
                .accessibilityLabel("Dictate")
                Button {
                    send(nil)
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.onEmber)
                        .frame(width: 46, height: 46).background(Theme.ember, in: Circle())
                }
                .accessibilityLabel("Send")
                .disabled(ask.isWorking || ask.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stoneDeep.opacity(0.6)).frame(height: 1) }
    }

    func send(_ text: String?) {
        changing = false
        typing = false
        Task { await app.ask.ask(text) }
    }

    func change() {
        changing = true
        typing = true
    }
}

/// One question and everything that came of it.
private struct TurnView: View {
    @Environment(AppModel.self) private var app
    let turn: AskModel.Turn
    var change: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(turn.question)
                .font(.custom(Typeface.regular, size: 15, relativeTo: .body))
                .lineSpacing(3)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Theme.chip,
                    in: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 20, bottomLeading: 20, bottomTrailing: 6, topTrailing: 20))
                )
                .frame(maxWidth: 300, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if !turn.trace.isEmpty || turn.phase == .working {
                TraceCard(turn: turn)
            }
            if !turn.answer.isEmpty {
                Text(turn.answer)
                    .font(.custom(Typeface.regular, size: 15, relativeTo: .body))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.inkSoft)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            if case .failed(let message) = turn.phase { Notice(text: message) }
            if !turn.proposals.isEmpty, turn.phase == .answered {
                switch turn.run {
                case .done(let summary): DoneCard(turn: turn, summary: summary)
                case .waiting, .running, .failed: ProposalCard(turn: turn, change: change)
                }
            }
        }
    }
}

/// "Checked 4 sources · 2.8 s", and what each one was.
private struct TraceCard: View {
    let turn: AskModel.Turn
    @State private var open = true

    var title: String {
        if turn.phase == .working, turn.trace.contains(where: { !$0.finished }) || turn.trace.isEmpty {
            return turn.trace.isEmpty ? "Thinking…" : "Checking \(turn.trace.count) source\(turn.trace.count == 1 ? "" : "s")…"
        }
        var text = "Checked \(turn.trace.count) source\(turn.trace.count == 1 ? "" : "s")"
        if let seconds = turn.seconds, seconds >= 0.1 { text += " · " + String(format: "%.1f s", seconds) }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if turn.phase == .working {
                        ProgressView().controlSize(.mini).tint(Theme.muted)
                    } else {
                        Image(systemName: "checklist").font(.system(size: 14, weight: .semibold))
                    }
                    Text(title).frame(maxWidth: .infinity, alignment: .leading)
                    if !turn.trace.isEmpty {
                        Text(open ? "Hide" : "Show").font(.custom(Typeface.semibold, size: 12, relativeTo: .caption)).foregroundStyle(
                            Theme.ember)
                    }
                }
                .font(.custom(Typeface.semibold, size: 13, relativeTo: .footnote))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Shown" : "Hidden")
            if open, !turn.trace.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(turn.trace) { line in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.tool).foregroundStyle(Theme.iceSoft)
                            Text(line.finished ? line.detail : "…").foregroundStyle(Theme.muted)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(2)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// "Waiting for your OK": the steps, ticked or not, and Do these N.
private struct ProposalCard: View {
    @Environment(AppModel.self) private var app
    let turn: AskModel.Turn
    var change: () -> Void

    var cta: String {
        switch turn.chosenCount {
        case 0: "Pick at least one"
        case 1: "Do this one"
        default: "Do these \(turn.chosenCount)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Waiting for your OK").eyebrow(Theme.emberSoft).padding(.bottom, 4)
            ForEach(Array(turn.proposals.enumerated()), id: \.element.id) { index, proposal in
                let on = turn.selected.contains(proposal.id)
                Button {
                    app.ask.toggle(proposal.id, in: turn.id)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.ember : .clear)
                            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(on ? Theme.ember : Theme.stone, lineWidth: 2)
                            if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Theme.onEmber) }
                        }
                        .frame(width: 22, height: 22)
                        .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(proposal.label).font(.custom(Typeface.semibold, size: 15, relativeTo: .body)).foregroundStyle(Theme.ink)
                            if !proposal.detail.isEmpty {
                                Text(proposal.detail).font(.custom(Typeface.regular, size: 13, relativeTo: .footnote)).foregroundStyle(
                                    Theme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { if index > 0 { Hairline() } }
                .accessibilityAddTraits(on ? .isSelected : [])
                .disabled(turn.run == .running)
            }
            if let problem = turn.undoProblem { Notice(text: problem) }
            if case .failed(let message) = turn.run { Notice(text: message) }
            HStack(spacing: 8) {
                Button {
                    Task { await app.ask.approve(turn.id) }
                } label: {
                    if turn.run == .running { ProgressView().tint(Theme.onEmber) } else { Text(cta) }
                }
                .buttonStyle(.pill(.primary, height: 46))
                .disabled(turn.chosenCount == 0 || turn.run == .running)
                Button("Change", action: change)
                    .buttonStyle(.pill(.secondary, height: 46))
                    .fixedSize()
            }
            .padding(.top, 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.ember, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed actions")
    }
}

/// "Done. …" with Undo, plus anything to copy or open.
private struct DoneCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let turn: AskModel.Turn
    let summary: String
    @State private var copied: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.onIce)
                .frame(width: 32, height: 32).background(Theme.ice, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Done. \(summary)").font(.custom(Typeface.bold, size: 15, relativeTo: .body)).foregroundStyle(Theme.iceInk)
                ForEach(turn.notes) { note in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note.text).font(.custom(Typeface.regular, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.inkSoft)
                            .textSelection(.enabled)
                        Button(copied == note.id ? "Copied" : "Copy") {
                            UIPasteboard.general.string = note.text
                            copied = note.id
                        }
                        .font(.custom(Typeface.bold, size: 14, relativeTo: .subheadline))
                        .foregroundStyle(Theme.iceSoft)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                ForEach(turn.links) { link in
                    if let url = link.url {
                        Button("Open \(url.host ?? "the page")") { openURL(url) }
                            .font(.custom(Typeface.bold, size: 14, relativeTo: .subheadline))
                            .foregroundStyle(Theme.iceSoft)
                    }
                }
                TextButton(title: "Undo") { Task { await app.ask.undo(turn.id) } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Theme.iceDeep, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Done")
    }
}
