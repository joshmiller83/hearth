import Foundation
import HearthKit
import Observation

/// Texts and chats, read only: what the Mac's Messages helper exported and the relay
/// read from the Mac's WhatsApp and Messenger bridges, named from Contacts on this
/// phone. The ones waiting on the owner go to Today; Ask can search them; any message
/// can go to Capture. Hearth never sends one.
@MainActor
@Observable
public final class ChatsModel {
    let services: AppServices
    weak var app: AppModel?

    /// Messages (iMessage and SMS).
    public private(set) var status: ChatSourceStatus?
    /// Every source: Messages, then each bridge the Mac runs.
    public private(set) var sources: [ChatSourceStatus]
    /// Most recent first.
    public private(set) var threads: [ChatSummary]
    /// Contacts' names, keyed by `ChatHandle.normalize`.
    public private(set) var names: [String: String] = [:]
    public private(set) var problem: String?
    /// Waiting texts the owner said aren't for them (`ChatSummary.waitingId`); a new message brings one back.
    public private(set) var leftOut: Set<String>

    init(services: AppServices) {
        self.services = services
        let cached = services.database.load(ChatsResponse.self, key: StoreKey.chats)
        status = cached?.status
        sources = cached?.sources ?? []
        threads = cached?.threads ?? []
        leftOut = Set(services.database.load([String].self, key: StoreKey.chatsLeftOut) ?? [])
    }

    var now: Date { services.clock.now }

    public func refresh() async {
        guard let relay = app?.relay else { return }
        do {
            let response = try await relay.chats()
            status = response.status
            sources = response.sources ?? []
            threads = response.threads
            problem = nil
            try? services.database.save(response, key: StoreKey.chats, now: now)
            names = await services.people.names(for: Array(Set(threads.flatMap(\.thread.handles))))
            let current = leftOut.intersection(threads.map(\.waitingId))
            if current != leftOut {
                leftOut = current
                saveLeftOut()
            }
        } catch {
            problem = (error as? RelayError)?.description ?? String(describing: error)
        }
    }

    /// The Mac can read something right now: texts, or a bridged chat network.
    public var available: Bool { status?.state == .ok || bridges.contains { $0.state == .ok } }

    /// The bridges the Mac runs (WhatsApp, Messenger), whatever their state.
    public var bridges: [ChatSourceStatus] { sources.filter { ($0.source ?? ChatSource.iMessage) != ChatSource.iMessage } }

    /// Questions waiting on the owner, minus the ones they left out.
    public var waiting: [ChatSummary] { threads.filter { $0.waiting && !leftOut.contains($0.waitingId) } }

    public func leaveOut(_ summary: ChatSummary) {
        leftOut.insert(summary.waitingId)
        saveLeftOut()
    }

    func saveLeftOut() {
        try? services.database.save(leftOut.sorted(), key: StoreKey.chatsLeftOut, now: now)
    }

    // MARK: Names

    /// A contact's name, else the name WhatsApp or Messenger gives them, else the number.
    public func name(_ handle: String?, in thread: ChatThread? = nil) -> String {
        guard let handle else { return "You" }
        return ChatHandle.name(handle, contacts: names, in: thread)
    }

    /// "Carol Rivera", "Rivera cousins", "Jo Rivera, Lou Rivera".
    public func title(_ thread: ChatThread) -> String {
        if let name = thread.name { return name }
        let people = thread.handles.map { name($0, in: thread) }
        return people.isEmpty ? "A conversation" : people.joined(separator: ", ")
    }

    /// What the conversation's newest message says, with who said it in a group.
    public func preview(_ summary: ChatSummary) -> String {
        let message = summary.unanswered.last ?? summary.last
        let text = message.text.isEmpty ? (message.hasAttachment ? "A photo or file" : "") : message.text
        guard summary.thread.isGroup || message.fromMe else { return text }
        let full = name(message.sender, in: summary.thread)
        let who = message.fromMe ? "You" : full.split(separator: " ").first.map(String.init) ?? full
        return "\(who): \(text)"
    }

    /// A row's time, with where it's from when that isn't Messages: "WhatsApp · 2h ago".
    public func meta(_ summary: ChatSummary) -> String {
        let time = when(summary.last.date)
        return summary.thread.source == ChatSource.iMessage ? time : "\(summary.thread.service) · \(time)"
    }

    /// "Text · 2h ago", "SMS · yesterday".
    public func when(_ date: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 60 { return "\(max(1, minutes))m ago" }
        if minutes < 24 * 60 { return "\(minutes / 60)h ago" }
        let fmt = household.fmt
        return fmt.calendar.isDate(date, inSameDayAs: now.addingTimeInterval(-86400)) ? "yesterday" : fmt.shortDay(date)
    }

    /// Where to open a one-on-one conversation: Messages, WhatsApp or Messenger. Groups have
    /// no address, and neither does someone WhatsApp shows without a number.
    public func openLink(_ thread: ChatThread) -> (title: String, url: URL)? {
        switch thread.source {
        case ChatSource.iMessage:
            return messagesURL(thread).map { (title: "Open in Messages", url: $0) }
        case ChatSource.whatsApp:
            guard !thread.isGroup, let handle = thread.handles.first, ChatHandle.network(handle) == nil else { return nil }
            return URL(string: "https://wa.me/" + handle.filter(\.isNumber)).map { (title: "Open in WhatsApp", url: $0) }
        case ChatSource.messenger:
            guard !thread.isGroup, let id = thread.handles.first.flatMap(ChatHandle.network)?.id, id.allSatisfy(\.isNumber) else {
                return nil
            }
            return URL(string: "https://m.me/" + id).map { (title: "Open in Messenger", url: $0) }
        default:
            return nil
        }
    }

    /// Opens the conversation in Messages; only one-on-one conversations have an address.
    public func messagesURL(_ thread: ChatThread) -> URL? {
        guard !thread.isGroup, let handle = thread.handles.first,
            let encoded = handle.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "+@.")))
        else { return nil }
        return URL(string: "sms:" + encoded)
    }

    var household: Household { app?.household ?? .placeholder }

    // MARK: A conversation

    public func thread(_ id: String) async throws -> ChatThreadResponse {
        guard let relay = app?.relay else { throw RelayError.notConfigured }
        return try await relay.chatThread(id: id)
    }

    /// Hands their latest texts to Capture, the way it reads a note.
    public func capture(_ messages: [ChatMessage], in thread: ChatThread) async {
        guard let capture = app?.capture, !messages.isEmpty else { return }
        capture.startOver()
        let lines = messages.filter { !$0.text.isEmpty }.map { "\(name($0.sender, in: thread)): \($0.text)" }
        let kind = thread.source == ChatSource.iMessage ? "A text conversation" : "A \(thread.service) conversation"
        capture.noteText = "\(kind) with \(title(thread)):\n" + lines.joined(separator: "\n")
        await capture.readNote()
    }

    /// The Sources line: "Read 9 texts in 5 conversations at 10:07 AM".
    public var statusLine: String {
        guard let status else { return "Not set up. Run deploy/install-messages.sh on the Mac." }
        switch status.state {
        case .ok:
            let at = status.checkedAt.map { " · checked \(household.fmt.time($0))" } ?? ""
            return "\(status.messages) texts in \(status.threads) conversations, the last 60 days\(at)"
        case .needsAccess:
            return "Waiting for Full Disk Access on the Mac."
        case .notInstalled:
            return "Not set up. Run deploy/install-messages.sh on the Mac."
        case .notRunning, .failed:
            return status.message ?? "The Mac couldn't read Messages."
        }
    }

    /// A bridge's line: "48 messages in 12 chats, the last 60 days", or what to do on the Mac.
    public func bridgeLine(_ source: ChatSourceStatus) -> String {
        switch source.state {
        case .ok:
            let at = source.checkedAt.map { " · checked \(household.fmt.time($0))" } ?? ""
            return "\(source.messages) messages in \(source.threads) chats, the last 60 days\(at)"
        case .notInstalled:
            return "Not set up. See Message bridges in docs/deploy.md."
        case .needsAccess, .notRunning, .failed:
            return source.message ?? "The Mac couldn't read \(ChatSource.label(source.source ?? ""))."
        }
    }

    /// Texts' header: Messages' line, or the bridges' when Messages isn't set up.
    public var overview: String {
        let reading = bridges.filter { $0.state == .ok }
        guard (status?.state ?? .notInstalled) == .notInstalled, !reading.isEmpty else { return statusLine }
        return reading.map { "\(ChatSource.label($0.source ?? "")): \(bridgeLine($0))" }.joined(separator: "\n")
    }
}

extension StoreKey {
    public static let chats = "relay.chats"
    public static let chatsLeftOut = "chats.leftOut"
}
