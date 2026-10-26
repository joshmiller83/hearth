import HearthCore
import HearthKit
import SwiftUI

/// A thread and Claude's draft. It sends only when you tap Send.
struct ThreadView: View {
    @Environment(AppModel.self) private var app
    @State private var model: ThreadModel?
    let mail: TriagedMail

    var body: some View {
        Group {
            if let model {
                ThreadContent(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            }
        }
        .task {
            guard model == nil else { return }
            let thread = ThreadModel(mail: mail, app: app)
            model = thread
            await thread.load()
            await thread.draft()
        }
    }
}

private struct ThreadContent: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ThreadModel
    @State private var editing = false
    @State private var showEarlier = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.mail.item.subject).font(.custom(Typeface.display, size: 26, relativeTo: .title)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 6) {
                        TagChip(text: model.mail.item.account, style: .plain)
                        TagChip(text: model.mail.tag, style: TagChip.style(for: model.mail.tag))
                    }
                }
                .padding(.horizontal, 4)
                switch model.phase {
                case .loading: ProgressView().frame(maxWidth: .infinity)
                case .failed(let message): Notice(text: message)
                case .loaded: messages
                }
                draftCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom) { sendBar }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.archive() }
                } label: {
                    Image(systemName: "archivebox")
                }
                .accessibilityLabel("Archive thread")
            }
        }
    }

    @ViewBuilder var messages: some View {
        let earlier = model.messages.dropLast()
        if !earlier.isEmpty {
            Button(showEarlier ? "Hide earlier messages" : "\(earlier.count) earlier message\(earlier.count == 1 ? "" : "s")") {
                showEarlier.toggle()
            }
            .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline))
            .foregroundStyle(Theme.ember)
            .frame(minHeight: 32)
            if showEarlier {
                ForEach(Array(earlier)) { message in MessageCard(message: message) }
            }
        }
        if let latest = model.messages.last { MessageCard(message: latest) }
    }

    var draftCard: some View {
        Card(border: Theme.emberLine) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude's draft").eyebrow(Theme.emberSoft)
                        Text(model.fromLine).font(.hMeta).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button(editing ? "Done" : "Edit") { editing.toggle() }
                        .font(.hLabel).foregroundStyle(Theme.ember).frame(minHeight: 32)
                }
                HStack(spacing: 6) {
                    ForEach(DraftPrompt.Tone.allCases, id: \.self) { tone in
                        let selected = model.tone == tone
                        Button(tone.label) { Task { await model.draft(tone) } }
                            .font(.custom(Typeface.bold, size: 13, relativeTo: .footnote))
                            .foregroundStyle(selected ? Theme.bg : Theme.chipInk)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(selected ? Theme.ink : .clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Theme.ink : Theme.stoneDeep, lineWidth: 1))
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Rewrite the draft")
                switch model.drafting {
                case .drafting:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Claude is drafting…").font(.hMeta).foregroundStyle(Theme.muted)
                    }
                case .failed(let message):
                    Notice(text: message)
                default:
                    if editing {
                        TextEditor(text: $model.body)
                            .font(.hBody).foregroundStyle(Theme.ink)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220)
                            .padding(8)
                            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        Text(model.body).font(.hBody).foregroundStyle(Theme.ink).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                if let looked = model.lookedAt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What Claude looked at").font(.custom(Typeface.bold, size: 12, relativeTo: .caption)).foregroundStyle(
                            Theme.muted)
                        Text(looked).font(.hMeta).foregroundStyle(Theme.inkSoft)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if let label = model.holdLabel {
                    Toggle(isOn: $model.holdSlots) {
                        Text(label).font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.ink)
                    }
                    .tint(Theme.ember)
                }
            }
        }
    }

    var sendBar: some View {
        VStack(spacing: 6) {
            switch model.sending {
            case .sent:
                Label("Sent", systemImage: "checkmark").font(.hButton).foregroundStyle(Theme.iceSoft)
                    .frame(maxWidth: .infinity, minHeight: Theme.touch).background(Theme.iceDeep, in: Capsule())
            case .scheduled(let date):
                let fmt = app.household.fmt
                Label("Sends \(fmt.weekday(date)) at \(fmt.time(date))", systemImage: "clock").font(.hButton).foregroundStyle(Theme.iceSoft)
                    .frame(maxWidth: .infinity, minHeight: Theme.touch).background(Theme.iceDeep, in: Capsule())
            case .sending:
                ProgressView().frame(maxWidth: .infinity, minHeight: Theme.touch)
            default:
                if case .failed(let message) = model.sending { Notice(text: message) }
                HStack(spacing: 8) {
                    Button {
                        Task { await model.send(at: model.tomorrowMorning) }
                    } label: {
                        Label("Tomorrow 8 AM", systemImage: "clock")
                    }
                    .buttonStyle(.pill(.secondary))
                    Button {
                        Task { await model.send() }
                    } label: {
                        Label("Send now", systemImage: "paperplane")
                    }
                    .buttonStyle(.pill(.primary))
                }
                .disabled(model.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.drafting == .drafting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.tabBar.opacity(0.97))
        .overlay(alignment: .top) { Hairline() }
    }
}

private struct MessageCard: View {
    @Environment(AppModel.self) private var app
    let message: ThreadMessage

    var body: some View {
        let fmt = app.household.fmt
        let sender = MailItem(id: message.id, threadId: "", account: "", from: message.from, subject: "", date: message.date)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(sender.initial).font(.custom(Typeface.bold, size: 15, relativeTo: .body)).foregroundStyle(Theme.chipInk)
                        .frame(width: 36, height: 36).background(Theme.chip, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sender.senderName).font(.hRowTitle).foregroundStyle(Theme.ink)
                        Text("to \(message.to.split(separator: "@").first.map(String.init) ?? message.to) · \(fmt.time(message.date))")
                            .font(.hMeta).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Text(message.body).font(.hBody).foregroundStyle(Theme.inkSoft).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}
