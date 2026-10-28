import Foundation
import HearthKit
import Observation

/// Texts, read only: what the Mac's Messages helper exported through the relay,
/// named from Contacts on this phone. The ones waiting on the owner go to
/// Today; Ask can search them; any text can go to Capture. Hearth never sends one.
@MainActor
@Observable
public final class ChatsModel {
    let services: AppServices
    weak var app: AppModel?

    public private(set) var status: ChatSourceStatus?
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
        threads = cached?.threads ?? []
        leftOut = Set(services.database.load([String].self, key: StoreKey.chatsLeftOut) ?? [])
    }

    var now: Date { services.clock.now }

    public func refresh() async {
        guard let relay = app?.relay else { return }
        do {
            let response = try await relay.chats()
            status = response.status
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

    /// The Mac can read texts right now.
    public var available: Bool { status?.state == .ok }

    /// Questions waiting on the owner, minus the ones they left out.
    public var waiting: [ChatSummary] { threads.filter { isWaiting($0) } }

    /// Someone the owner knows asked and they haven't answered. The relay knows who they've
    /// texted; this phone knows their contacts. A stranger's question waits on no one.
    public func isWaiting(_ summary: ChatSummary) -> Bool {
        guard !leftOut.contains(summary.waitingId) else { return false }
        return summary.waiting || (summary.asked && summary.thread.handles.contains { names[ChatHandle.normalize($0)] != nil })
    }

    public func leaveOut(_ summary: ChatSummary) {
        leftOut.insert(summary.waitingId)
        saveLeftOut()
    }

    func saveLeftOut() {
        try? services.database.save(leftOut.sorted(), key: StoreKey.chatsLeftOut, now: now)
    }

    // MARK: Names

    /// A contact's name, or the number as Messages has it.
    public func name(_ handle: String?) -> String {
        guard let handle else { return "You" }
        return names[ChatHandle.normalize(handle)] ?? handle
    }

    /// "Carol Rivera", "Rivera cousins", "Jo Rivera, Lou Rivera".
    public func title(_ thread: ChatThread) -> String {
        if let name = thread.name { return name }
        let people = thread.handles.map { name($0) }
        return people.isEmpty ? "A conversation" : people.joined(separator: ", ")
    }

    /// What the conversation's newest message says, with who said it in a group.
    public func preview(_ summary: ChatSummary) -> String {
        let message = summary.unanswered.last ?? summary.last
        let text = message.text.isEmpty ? (message.hasAttachment ? "A photo or file" : "") : message.text
        guard summary.thread.isGroup || message.fromMe else { return text }
        let who = message.fromMe ? "You" : name(message.sender).split(separator: " ").first.map(String.init) ?? name(message.sender)
        return "\(who): \(text)"
    }

    /// "Text · 2h ago", "SMS · yesterday".
    public func when(_ date: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 60 { return "\(max(1, minutes))m ago" }
        if minutes < 24 * 60 { return "\(minutes / 60)h ago" }
        let fmt = household.fmt
        return fmt.calendar.isDate(date, inSameDayAs: now.addingTimeInterval(-86400)) ? "yesterday" : fmt.shortDay(date)
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
        let lines = messages.filter { !$0.text.isEmpty }.map { "\(name($0.sender)): \($0.text)" }
        capture.noteText = "A text conversation with \(title(thread)):\n" + lines.joined(separator: "\n")
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
}

extension StoreKey {
    public static let chats = "relay.chats"
    public static let chatsLeftOut = "chats.leftOut"
}
