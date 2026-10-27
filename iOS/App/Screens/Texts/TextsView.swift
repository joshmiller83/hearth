import HearthCore
import HearthKit
import SwiftUI

/// Recent text conversations, read only, from the Mac's Messages.
struct TextsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let chats = app.chats
        ScreenScroll {
            VStack(alignment: .leading, spacing: 4) {
                Text("Texts").font(.hTitle).displayTracking().foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                Text(chats.statusLine).font(.hMeta).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 4)
            if let problem = chats.problem { Notice(text: problem) }
            Card(padding: EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)) {
                if chats.threads.isEmpty {
                    Text("No conversations yet.").font(.hBody).foregroundStyle(Theme.muted).padding(.vertical, 14)
                }
                ForEach(Array(chats.threads.enumerated()), id: \.element.id) { index, summary in
                    NavigationLink {
                        TextThreadView(threadId: summary.thread.id)
                    } label: {
                        TextRow(summary: summary)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) { if index > 0 { Hairline() } }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await chats.refresh() }
    }
}

private struct TextRow: View {
    @Environment(AppModel.self) private var app
    let summary: ChatSummary

    var body: some View {
        let chats = app.chats
        let title = chats.title(summary.thread)
        HStack(alignment: .top, spacing: 12) {
            Text(String(title.prefix(1)).uppercased())
                .font(.custom(Typeface.bold, size: 15, relativeTo: .body)).foregroundStyle(Theme.chipInk)
                .frame(width: 36, height: 36).background(Theme.chip, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.custom(Typeface.semibold, size: 15, relativeTo: .body)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer()
                    Text(chats.when(summary.last.date)).font(.custom(Typeface.regular, size: 12, relativeTo: .caption))
                        .foregroundStyle(Theme.muted)
                }
                Text(chats.preview(summary)).font(.hMeta).foregroundStyle(Theme.muted).lineLimit(2)
                if summary.waiting && !chats.leftOut.contains(summary.waitingId) {
                    TagChip(text: "Waiting on you", style: .ember).padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One conversation's latest texts, and what Hearth can do with them: open it
/// in Messages, read it into Capture, or set a question aside.
struct TextThreadView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let threadId: String
    @State private var loaded: ChatThreadResponse?
    @State private var problem: String?
    @State private var capturing = false

    init(threadId: String, preloaded: ChatThreadResponse? = nil) {
        self.threadId = threadId
        _loaded = State(initialValue: preloaded)
    }

    var body: some View {
        let chats = app.chats
        let summary = chats.threads.first { $0.thread.id == threadId }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let thread = loaded?.thread ?? summary?.thread {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chats.title(thread)).font(.hTitle).displayTracking().foregroundStyle(Theme.ink)
                                .accessibilityAddTraits(.isHeader)
                            Text("\(thread.service) · read only. Hearth never sends a text.").font(.hMeta).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 4)
                    }
                    if let problem { Notice(text: problem) }
                    if loaded == nil, problem == nil { ProgressView().tint(Theme.muted).frame(maxWidth: .infinity).padding(.top, 24) }
                    ForEach(loaded?.messages ?? []) { message in
                        Bubble(message: message, group: loaded?.thread.isGroup ?? false)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .onChange(of: loaded?.messages.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom) { actions(summary) }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $capturing) { CaptureView() }
    }

    func load() async {
        do {
            loaded = try await app.chats.thread(threadId)
            problem = nil
        } catch {
            problem = (error as? RelayError)?.description ?? String(describing: error)
        }
    }

    @ViewBuilder func actions(_ summary: ChatSummary?) -> some View {
        let chats = app.chats
        let thread = loaded?.thread ?? summary?.thread
        let waiting = summary.map { $0.waiting && !chats.leftOut.contains($0.waitingId) } ?? false
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("Add to \(app.household.familyCalendar)") {
                    guard let thread else { return }
                    let theirs = summary?.unanswered.isEmpty == false ? summary!.unanswered : Array((loaded?.messages ?? []).suffix(5))
                    capturing = true
                    Task { await chats.capture(theirs, in: thread) }
                }
                .buttonStyle(.pill(.primary, height: 44))
                .disabled(thread == nil)
                if let thread, let url = chats.messagesURL(thread) {
                    Button("Open in Messages") { openURL(url) }.buttonStyle(.pill(.secondary, height: 44))
                }
            }
            if waiting, let summary {
                TextButton(title: "Not for me", color: Theme.muted) { chats.leaveOut(summary) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.tabBar.opacity(0.97))
        .overlay(alignment: .top) { Hairline() }
    }
}

private struct Bubble: View {
    @Environment(AppModel.self) private var app
    let message: ChatMessage
    let group: Bool

    var body: some View {
        let chats = app.chats
        VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 3) {
            if group, !message.fromMe {
                Text(chats.name(message.sender)).font(.custom(Typeface.semibold, size: 12, relativeTo: .caption))
                    .foregroundStyle(Theme.muted).padding(.horizontal, 6)
            }
            VStack(alignment: .leading, spacing: 4) {
                if message.hasAttachment {
                    Label("A photo or file", systemImage: "paperclip").font(.hMeta).foregroundStyle(Theme.muted)
                }
                if !message.text.isEmpty {
                    Text(message.text).font(.custom(Typeface.regular, size: 15, relativeTo: .body))
                        .foregroundStyle(message.fromMe ? Theme.onIce : Theme.ink).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                message.fromMe ? Theme.ice : Theme.surface,
                in: UnevenRoundedRectangle(
                    cornerRadii: message.fromMe
                        ? .init(topLeading: 18, bottomLeading: 18, bottomTrailing: 6, topTrailing: 18)
                        : .init(topLeading: 18, bottomLeading: 6, bottomTrailing: 18, topTrailing: 18))
            )
            .frame(maxWidth: 300, alignment: message.fromMe ? .trailing : .leading)
            Text(chats.when(message.date)).font(.custom(Typeface.regular, size: 11, relativeTo: .caption2)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, alignment: message.fromMe ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.fromMe ? "You" : chats.name(message.sender)), \(chats.when(message.date)): \(message.text)")
    }
}
