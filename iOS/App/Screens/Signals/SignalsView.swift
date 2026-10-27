import HearthCore
import HearthKit
import SwiftUI

/// Signals: everything that pinged overnight, turned down to what's worth a
/// look, with the rest quieted to a line each.
struct SignalsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Binding var tab: AppTab
    @Binding var path: [Destination]
    @State private var opened: TriagedMail?

    var body: some View {
        let signals = app.signals
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                            Text("Today")
                        }
                        .font(.custom(Typeface.semibold, size: 16, relativeTo: .body))
                        .foregroundStyle(Theme.ember)
                        .frame(minHeight: Theme.touch)
                    }
                    Spacer()
                    RoundIconButton(symbol: "gearshape", label: "Signal settings") { path.append(.sources) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Signals").font(.hTitle).displayTracking().foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(signals.summary).font(.custom(Typeface.regular, size: 15, relativeTo: .body)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 4)
                chips
                if let problem = signals.problem { Notice(text: problem) }
                attention
                quieted
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .refreshable {
            await app.inbox.refresh(force: true)
            await signals.refresh()
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $opened) { mail in ThreadView(mail: mail) }
    }

    var chips: some View {
        let signals = app.signals
        return HStack(spacing: 8) {
            chip("All", selected: signals.filter == nil) { signals.filter = nil }
            ForEach(signals.categories, id: \.self) { category in
                chip(category.label, selected: signals.filter == category) { signals.filter = category }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter signals")
    }

    func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline))
                .foregroundStyle(selected ? Theme.bg : Theme.chipInk)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(selected ? Theme.ink : Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var attention: some View {
        let signals = app.signals
        let rows = signals.worth + (signals.showLower ? signals.lower : [])
        return VStack(spacing: 0) {
            if rows.isEmpty {
                Text("Nothing's asking for you.").font(.hBody).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, signal in
                SignalRow(signal: signal, perform: perform)
                    .overlay(alignment: .top) { if index > 0 { Hairline() } }
            }
            if !signals.lower.isEmpty {
                Button {
                    withAnimation(.snappy) { signals.showLower.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(signals.showLower ? "Show less" : "\(signals.lower.count) more, lower priority")
                        Image(systemName: signals.showLower ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .bold))
                    }
                    .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ember)
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .overlay(alignment: .top) { Hairline() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Worth your attention")
    }

    @ViewBuilder var quieted: some View {
        let signals = app.signals
        if !signals.bundles.isEmpty || signals.cleared != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quieted for you · \(signals.quietCount)").eyebrow().padding(.horizontal, 4).padding(.top, 6)
                if let cleared = signals.cleared { Notice(symbol: "checkmark.circle", text: cleared, tint: .ice) }
                if !signals.bundles.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(signals.bundles.enumerated()), id: \.element.id) { index, bundle in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bundle.title).font(.custom(Typeface.semibold, size: 15, relativeTo: .body)).foregroundStyle(
                                        Theme.ink)
                                    Text(bundle.detail).font(.custom(Typeface.regular, size: 13, relativeTo: .footnote)).foregroundStyle(
                                        Theme.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if let action = bundle.action {
                                    Button {
                                        perform(action, bundle: bundle)
                                    } label: {
                                        if signals.working.contains(bundle.id) {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Text(action.label)
                                        }
                                    }
                                    .font(.custom(Typeface.semibold, size: 13, relativeTo: .footnote))
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 12)
                                    .frame(minWidth: 44, minHeight: 36)
                                    .background(Theme.chip, in: Capsule())
                                    .accessibilityLabel("\(action.label): \(bundle.title)")
                                }
                            }
                            .padding(.vertical, 12)
                            .overlay(alignment: .top) { if index > 0 { Hairline() } }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                }
            }
        }
    }

    func perform(_ action: Signal.Action, signal: Signal) {
        switch action {
        case .open(_, let url): openURL(url)
        case .read(_, let ref): opened = app.signals.mail(ref)
        case .remind(_, let title, let at): Task { await app.signals.remind(signal, title: title, at: at) }
        case .markRead: break
        case .review(_, let queue): review(queue)
        }
    }

    func perform(_ action: Signal.Action, bundle: SignalBundle) {
        switch action {
        case .markRead(_, let mail): Task { await app.signals.markRead(bundle, mail: mail) }
        case .review(_, let queue): review(queue)
        case .open(_, let url): openURL(url)
        case .read, .remind: break
        }
    }

    func review(_ queue: MailQueue) {
        app.inbox.queue = queue
        tab = .inbox
    }
}

/// One signal: its tile, where it came from, what it says, and its buttons.
private struct SignalRow: View {
    @Environment(AppModel.self) private var app
    let signal: Signal
    var perform: (Signal.Action, Signal) -> Void

    /// Weather in ice, people and church in ember, services neutral.
    var tint: Tint {
        switch signal.monogram {
        case "WX": .ice
        case "GH", "FB", "PC": signal.category == .church ? .ember : .neutral
        default: signal.category == .work ? .neutral : .ember
        }
    }

    var body: some View {
        let signals = app.signals
        HStack(alignment: .top, spacing: 12) {
            Text(signal.monogram)
                .font(.custom(Typeface.bold, size: 12, relativeTo: .caption))
                .tracking(0.3)
                .foregroundStyle(tint.foreground)
                .frame(width: 40, height: 40)
                .background(tint.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(signal.source).font(.custom(Typeface.semibold, size: 12, relativeTo: .caption)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(signals.age(signal.date)).font(.custom(Typeface.regular, size: 12, relativeTo: .caption))
                }
                .foregroundStyle(Theme.muted)
                Text(signal.title).font(.custom(Typeface.semibold, size: 15, relativeTo: .body)).foregroundStyle(Theme.ink)
                if !signal.detail.isEmpty {
                    Text(signal.detail).font(.custom(Typeface.regular, size: 13, relativeTo: .footnote)).foregroundStyle(Theme.muted)
                }
                if let done = signals.done[signal.id] {
                    Label(done, systemImage: "checkmark").font(.custom(Typeface.semibold, size: 13, relativeTo: .footnote))
                        .foregroundStyle(Theme.iceSoft).padding(.top, 6)
                } else if !signal.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(signal.actions.prefix(2).enumerated()), id: \.offset) { index, action in
                            Button(action.label) { perform(action, signal) }
                                .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline))
                                .foregroundStyle(index == 0 ? Theme.ink : Theme.muted)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 36)
                                .background(index == 0 ? Theme.chip : Color.clear, in: Capsule())
                                .disabled(signals.working.contains(signal.id))
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
    }
}
