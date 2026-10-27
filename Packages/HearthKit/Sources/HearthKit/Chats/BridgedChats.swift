import Foundation

// WhatsApp and Messenger, as the Mac's bridges keep them (deploy/bridges): each chat
// a room on a private Matrix homeserver, each person in it a "ghost" user
// (@whatsapp_15550100009:hearth.local), the owner's own messages sent as the account
// the bridges work for. The relay reads those rooms with the client API's /sync, read
// only, every two minutes, and keeps them as a `ChatExport` like the one
// `hearth-messages` writes, so Texts, Today and Ask take them the same way.

/// A bridge the relay reads, and the port its provisioning API answers on (127.0.0.1).
public struct BridgeNetwork: Sendable, Hashable {
    public var source: String
    public var port: Int

    public init(source: String, port: Int) {
        self.source = source
        self.port = port
    }

    /// The mautrix bridges' default ports; deploy/bridges/networks.sh has the same table.
    public static let whatsApp = BridgeNetwork(source: ChatSource.whatsApp, port: 29318)
    public static let messenger = BridgeNetwork(source: ChatSource.messenger, port: 29319)
    public static let all = [whatsApp, messenger]

    public static func named(_ source: String) -> BridgeNetwork? { all.first { $0.source == source } }

    /// "WhatsApp", "Messenger".
    public var label: String { ChatSource.label(source) }
}

/// The parts of a Matrix `/sync` response Hearth reads.
public struct MatrixSync: Decodable, Sendable {
    public var next_batch: String
    public var rooms: Rooms?

    public struct Rooms: Decodable, Sendable {
        public var join: [String: Room]?
        public var leave: [String: Room]?
    }

    public struct Room: Decodable, Sendable {
        public var state: Events?
        public var timeline: Events?
    }

    public struct Events: Decodable, Sendable {
        public var events: [Event]?
    }

    public struct Event: Decodable, Sendable {
        public var type: String
        public var event_id: String?
        public var sender: String?
        /// Milliseconds since 1970.
        public var origin_server_ts: Double?
        /// Present on state events (a member's user id, or "").
        public var state_key: String?
        public var content: JSONValue?
    }

    public static func decode(_ data: Data) throws -> MatrixSync {
        try JSONDecoder().decode(MatrixSync.self, from: data)
    }
}

public enum BridgedChats {
    /// Like texts: the last 60 days, at most this many messages.
    public static let window: TimeInterval = 60 * 86400
    public static let maxMessages = 20_000

    /// Only rooms: no presence, receipts, typing or account data. A room new to the relay
    /// brings its latest 50 messages, as many as the bridges backfill.
    static let filter =
        #"{"presence":{"not_types":["*"]},"account_data":{"not_types":["*"]},"room":{"ephemeral":{"not_types":["*"]},"#
        + #""account_data":{"not_types":["*"]},"timeline":{"limit":50}}}"#

    /// `GET /_matrix/client/v3/sync`, returning at once: everything since `since`, or
    /// every room's state and latest messages without it.
    public static func syncRequest(homeserver: String, token: String, since: String?) -> HTTPRequest? {
        let base = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        var components = URLComponents(string: base + "/_matrix/client/v3/sync")
        var items = [URLQueryItem(name: "timeout", value: "0"), URLQueryItem(name: "filter", value: filter)]
        if let since { items.append(URLQueryItem(name: "since", value: since)) }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        return HTTPRequest(url: url, headers: ["Authorization": "Bearer \(token)"], timeout: 60)
    }

    /// The bridge's own view of its login (`/_matrix/provision/v3/whoami`), asked as the owner.
    public static func whoamiRequest(_ network: BridgeNetwork, token: String, owner: String) -> HTTPRequest? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = network.port
        components.path = "/_matrix/provision/v3/whoami"
        components.queryItems = [URLQueryItem(name: "user_id", value: owner)]
        guard let url = components.url else { return nil }
        return HTTPRequest(url: url, headers: ["Authorization": "Bearer \(token)"], timeout: 15)
    }

    /// "+15550100009" for @whatsapp_15550100009:…, "whatsapp:lid-42" for @whatsapp_lid-42:…,
    /// "facebook:1000…" for @facebook_1000…:…; nil for anyone else (the bridge's bot, the owner).
    public static func handle(ghost user: String, source: String) -> String? {
        guard user.hasPrefix("@"), let colon = user.firstIndex(of: ":") else { return nil }
        let localpart = user[user.index(after: user.startIndex)..<colon]
        let prefix = source + "_"
        guard localpart.hasPrefix(prefix) else { return nil }
        let id = String(localpart.dropFirst(prefix.count))
        guard !id.isEmpty else { return nil }
        if source == ChatSource.whatsApp, id.allSatisfy(\.isNumber) { return "+" + id }
        return source + ":" + id
    }

    /// Folds a sync into what the relay had: rooms' names and people, new messages, edits,
    /// rooms left. Keeps every bridged room it has seen (an incremental sync only says what
    /// changed), the last 60 days of messages, and nothing from other rooms (the bridges'
    /// management rooms and spaces). `owner` is the account the bridges work for.
    public static func apply(_ sync: MatrixSync, to previous: ChatExport?, owner: String, sources: Set<String>, now: Date) -> ChatExport {
        var threads: [String: ChatThread] = [:]
        var order: [String] = []
        for thread in previous?.threads ?? [] where threads[thread.id] == nil {
            threads[thread.id] = thread
            order.append(thread.id)
        }
        var messages = previous?.messages ?? []
        var index = Dictionary(messages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })

        for room in (sync.rooms?.leave ?? [:]).keys { threads[room] = nil }

        for (roomId, room) in (sync.rooms?.join ?? [:]).sorted(by: { $0.key < $1.key }) {
            let timeline = room.timeline?.events ?? []
            var state = RoomState(threads[roomId])
            state.apply((room.state?.events ?? []) + timeline.filter { $0.state_key != nil })
            guard let thread = state.thread(id: roomId, sources: sources) else {
                threads[roomId] = nil
                continue
            }
            if threads[roomId] == nil { order.append(roomId) }
            threads[roomId] = thread

            for event in timeline where event.type == "m.room.message" && event.state_key == nil {
                guard let id = event.event_id, index[id] == nil, let content = event.content else { continue }
                if content["m.relates_to"]?["rel_type"]?.stringValue == "m.replace" {
                    if let target = content["m.relates_to"]?["event_id"]?.stringValue, let at = index[target],
                        let body = content["m.new_content"]?["body"]?.stringValue
                    {
                        messages[at].text = ChatMessage.clean(body)
                    }
                    continue
                }
                guard let item = chatMessage(event, id: id, content: content, in: thread, owner: owner) else { continue }
                index[id] = messages.count
                messages.append(item)
            }
        }

        let cutoff = now.addingTimeInterval(-window)
        let kept = messages.filter { threads[$0.threadId] != nil && $0.date >= cutoff }.sorted { $0.date < $1.date }
        return ChatExport(
            exportedAt: now, source: ChatSource.all, since: cutoff, threads: order.compactMap { threads[$0] },
            messages: Array(kept.suffix(maxMessages)))
    }

    /// A message the owner can read: text, a caption, or a note that a photo or file came.
    /// The bridges' own notices (calls, errors) and anything from outside the chat are skipped.
    static func chatMessage(_ event: MatrixSync.Event, id: String, content: JSONValue, in thread: ChatThread, owner: String)
        -> ChatMessage?
    {
        guard let sender = event.sender, let millis = event.origin_server_ts else { return nil }
        let fromMe = sender == owner
        let ghost = fromMe ? nil : handle(ghost: sender, source: thread.source)
        guard fromMe || ghost != nil else { return nil }
        let kind = content["msgtype"]?.stringValue ?? "m.text"
        guard kind != "m.notice" else { return nil }
        let body = content["body"]?.stringValue ?? ""
        let media = ["m.image", "m.video", "m.audio", "m.file"].contains(kind)
        var text = body
        if media {
            // A file's body is its name unless a caption came with it.
            let filename = content["filename"]?.stringValue
            text = filename != nil && filename != body ? body : ""
        }
        return ChatMessage(
            id: id, threadId: thread.id, fromMe: fromMe, sender: ghost, date: Date(timeIntervalSince1970: millis / 1000),
            text: ChatMessage.clean(text), hasAttachment: media)
    }

    /// A bridge's status for the phone, from its provisioning API's whoami (nil: it didn't
    /// answer) and what the relay holds from it. `problem` is a failure before that (no
    /// token, the homeserver didn't answer).
    public static func status(
        _ network: BridgeNetwork, whoami: JSONValue?, export: ChatExport?, problem: String? = nil, now: Date
    ) -> ChatSourceStatus {
        let threads = (export?.threads ?? []).filter { $0.source == network.source }
        let ids = Set(threads.map(\.id))
        let count = (export?.messages ?? []).filter { ids.contains($0.threadId) }.count
        func make(_ state: ChatSourceStatus.State, _ message: String?) -> ChatSourceStatus {
            ChatSourceStatus(
                state: state, checkedAt: now, exportedAt: export?.exportedAt, threads: threads.count, messages: count, message: message,
                source: network.source)
        }
        let login = "On the Mac: deploy/bridges/login.sh \(network.source)"
        if let problem { return make(.failed, problem) }
        guard let whoami else { return make(.failed, "The \(network.label) bridge isn't answering on the Mac.") }
        let states = (whoami["logins"]?.arrayValue ?? []).compactMap { $0["state"]?["state_event"]?.stringValue }
        guard !states.isEmpty else { return make(.needsAccess, "Not signed in to \(network.label) yet. \(login)") }
        if states.contains(where: { ["CONNECTED", "CONNECTING", "BACKFILLING", "TRANSIENT_DISCONNECT"].contains($0) }) {
            return make(.ok, nil)
        }
        if states.contains(where: { ["BAD_CREDENTIALS", "LOGGED_OUT"].contains($0) }) {
            return make(.needsAccess, "\(network.label) signed the bridge out. \(login)")
        }
        return make(.failed, "The \(network.label) bridge says \(states.joined(separator: ", ")).")
    }
}

/// A room as the state events seen so far describe it.
private struct RoomState {
    var source: String?
    /// "dm", "group_dm", "" (a group) or "space"; nil until a bridge-info event says.
    var roomType: String?
    var roomName: String??
    var handles: [String]
    var names: [String: String]
    var previousName: String?

    init(_ thread: ChatThread?) {
        source = thread?.source
        handles = thread?.handles ?? []
        names = thread?.names ?? [:]
        previousName = thread?.name
    }

    mutating func apply(_ events: [MatrixSync.Event]) {
        // The bridge-info event first: it says whose ghosts the members are.
        for event in events where event.type == "m.bridge" || event.type == "uk.half-shot.bridge" {
            if let id = event.content?["protocol"]?["id"]?.stringValue { source = id }
            if let type = event.content?["com.beeper.room_type.v2"]?.stringValue { roomType = type }
        }
        for event in events {
            switch event.type {
            case "m.room.name":
                let name = event.content?["name"]?.stringValue ?? ""
                roomName = .some(name.isEmpty ? nil : name)
            case "m.room.member":
                guard let source, let user = event.state_key, let ghost = BridgedChats.handle(ghost: user, source: source) else {
                    continue
                }
                if event.content?["membership"]?.stringValue == "join" {
                    if !handles.contains(ghost) { handles.append(ghost) }
                    let name = Self.clean(event.content?["displayname"]?.stringValue ?? "")
                    if !name.isEmpty { names[ghost] = name }
                } else {
                    handles.removeAll { $0 == ghost }
                    names[ghost] = nil
                }
            default:
                continue
            }
        }
    }

    /// WhatsApp's default ghost names end in " (WA)"; Hearth shows where a chat is from itself.
    static func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix(" (WA)") ? String(trimmed.dropLast(5)) : trimmed
    }

    func thread(id: String, sources: Set<String>) -> ChatThread? {
        guard let source, sources.contains(source), roomType != "space" else { return nil }
        // A one-to-one chat goes by the person (Contacts first); only a group keeps the room's name.
        let isDM = roomType.map { $0 == "dm" } ?? (previousName == nil && handles.count <= 1)
        let name = isDM ? nil : (roomName ?? previousName)
        return ChatThread(
            id: id, source: source, name: name, handles: handles.sorted(), service: ChatSource.label(source),
            names: names.isEmpty ? nil : names)
    }
}
