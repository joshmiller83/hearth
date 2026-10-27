import Foundation
import HearthKit

extension Fixtures {
    /// The household's texts, as `hearth-messages` exports them. Mom is waiting on an answer;
    /// the rest aren't (no question, a short code, a group that doesn't name Sam, too old).
    public static var chats: ChatExport {
        func text(_ id: String, _ thread: String, _ sender: String?, _ local: String, _ text: String, attachment: Bool = false)
            -> ChatMessage
        {
            ChatMessage(
                id: id, threadId: thread, fromMe: sender == nil, sender: sender, date: at(local), text: text, hasAttachment: attachment)
        }
        return ChatExport(
            exportedAt: now, since: now.addingTimeInterval(-60 * 86400),
            threads: [
                ChatThread(id: "mom", handles: ["+15550100001"]),
                ChatThread(id: "robin", handles: ["+15550100002"]),
                ChatThread(id: "cousins", name: "Rivera cousins", handles: ["+15550100003", "lou.rivera@example.com"]),
                ChatThread(id: "bank", handles: ["72975"], service: "SMS"),
                ChatThread(id: "coach", handles: ["+15550100005"]),
            ],
            messages: [
                text("c1", "coach", "+15550100005", "2026-10-20T17:02", "Can the kids do 5:30 Thursday instead?"),
                text("r1", "robin", nil, "2026-10-25T18:40", "On my way home"),
                text("r2", "robin", "+15550100002", "2026-10-25T18:41", "Grab milk please", attachment: false),
                text("g1", "cousins", "lou.rivera@example.com", "2026-10-25T20:15", "Who's bringing chairs to the potluck?"),
                text("g2", "cousins", "+15550100003", "2026-10-25T20:20", "We have six folding ones"),
                text("b1", "bank", "72975", "2026-10-26T07:55", "Your code is 418230. Didn't ask for it? Call us."),
                text("m1", "mom", nil, "2026-10-25T09:00", "We made it home!"),
                text("m2", "mom", "+15550100001", "2026-10-26T08:12", "Are you all coming Sunday? I'm making the roast."),
                text("m3", "mom", "+15550100001", "2026-10-26T08:13", "Bring the good serving dish if you still have it", attachment: true),
            ])
    }

    /// Contacts' names for those numbers and emails (normalized).
    public static let chatNames: [String: String] = [
        "5550100001": "Carol Rivera", "5550100002": "Robin Rivera", "5550100003": "Jo Rivera", "lou.rivera@example.com": "Lou Rivera",
        "5550100005": "Coach Martinez",
    ]
}

extension Fixtures {
    /// The account the bridges work for, on the household's homeserver.
    public static let matrixOwner = "@hearth:rivera.local"
    /// Ghosts: Dana on WhatsApp; Lee and Ana on Messenger; the WhatsApp bridge's bot.
    public static let matrixDana = "@whatsapp_15550100009:rivera.local"
    public static let matrixLee = "@facebook_100001:rivera.local"
    public static let matrixAna = "@facebook_100002:rivera.local"
    static let matrixBot = "@whatsappbot:rivera.local"

    static func millis(_ local: String) -> Int { Int(at(local).timeIntervalSince1970 * 1000) }

    static func member(_ user: String, _ name: String? = nil, membership: String = "join") -> String {
        let display = name.map { #","displayname":"\#($0)""# } ?? ""
        return #"{"type":"m.room.member","state_key":"\#(user)","sender":"\#(user)","#
            + #""content":{"membership":"\#(membership)"\#(display)}}"#
    }

    static func bridge(_ network: String, _ type: String) -> String {
        #"{"type":"m.bridge","state_key":"net.maunium.\#(network)","#
            + #""content":{"protocol":{"id":"\#(network)"},"com.beeper.room_type.v2":"\#(type)"}}"#
    }

    static func roomName(_ name: String) -> String {
        #"{"type":"m.room.name","state_key":"","content":{"name":"\#(name)"}}"#
    }

    static func said(_ id: String, _ sender: String, _ local: String, _ content: String) -> String {
        #"{"type":"m.room.message","event_id":"\#(id)","sender":"\#(sender)","#
            + #""origin_server_ts":\#(millis(local)),"content":\#(content)}"#
    }

    static func text(_ body: String) -> String { #"{"msgtype":"m.text","body":"\#(body)"}"# }

    static func room(state: [String], timeline: [String]) -> String {
        #"{"state":{"events":[\#(state.joined(separator: ","))]},"#
            + #""timeline":{"events":[\#(timeline.joined(separator: ","))]}}"#
    }

    static func sync(_ batch: String, _ rooms: [(String, String)]) -> Data {
        let joined = rooms.map { #""\#($0.0)":\#($0.1)"# }.joined(separator: ",")
        return Data(#"{"next_batch":"\#(batch)","rooms":{"join":{\#(joined)}}}"#.utf8)
    }

    /// The homeserver's first /sync: a WhatsApp chat with Dana, who asked something; a
    /// Messenger group that doesn't name Sam; and the WhatsApp bridge's management room
    /// and space, which aren't chats.
    public static var matrixFirstSync: Data {
        let dana = room(
            state: [
                bridge("whatsapp", "dm"), roomName("Dana Okafor"), member(matrixOwner, "Sam"), member(matrixBot),
                member(matrixDana, "Dana Okafor (WA)"),
            ],
            timeline: [
                said("$d1", matrixOwner, "2026-10-25T19:00", text("Hi Dana! Got your number from the school list")),
                said("$d2", matrixDana, "2026-10-26T07:30", text("Are you still coming to the bake sale Saturday?")),
                said("$d3", matrixDana, "2026-10-26T07:31", #"{"msgtype":"m.image","body":"IMG_0042.jpg","filename":"IMG_0042.jpg"}"#),
                said("$d4", matrixBot, "2026-10-26T07:32", #"{"msgtype":"m.notice","body":"Call started"}"#),
            ])
        let porch = room(
            state: [
                bridge("facebook", ""), roomName("Porch crew"), member(matrixOwner, "Sam"), member(matrixLee, "Lee Park"),
                member(matrixAna, "Ana Ruiz"),
            ],
            timeline: [
                said("$p1", matrixLee, "2026-10-26T09:00", text("Who has the ladder?")),
                said("$p2", matrixAna, "2026-10-26T09:05", text("Not me")),
            ])
        let management = room(
            state: [member(matrixOwner, "Sam"), member(matrixBot)],
            timeline: [said("$m1", matrixBot, "2026-10-26T06:00", text("Successfully logged in"))])
        let space = room(state: [bridge("whatsapp", "space"), roomName("WhatsApp")], timeline: [])
        return sync(
            "s1",
            [
                ("!dana:rivera.local", dana), ("!porch:rivera.local", porch), ("!mgmt:rivera.local", management),
                ("!space:rivera.local", space),
            ])
    }

    /// The next /sync: Sam answers Dana, Lee edits his question, and Ana starts a
    /// Messenger chat asking something.
    public static var matrixNextSync: Data {
        let edit =
            #"{"msgtype":"m.text","body":"* Who has the tall ladder?","m.new_content":{"msgtype":"m.text","#
            + #""body":"Who has the tall ladder?"},"m.relates_to":{"rel_type":"m.replace","event_id":"$p1"}}"#
        let dana = room(state: [], timeline: [said("$d5", matrixOwner, "2026-10-26T09:30", text("Yes! Bringing muffins"))])
        let porch = room(state: [], timeline: [said("$p3", matrixLee, "2026-10-26T09:40", edit)])
        let ana = room(
            state: [bridge("facebook", "dm"), roomName("Ana Ruiz"), member(matrixOwner, "Sam"), member(matrixAna, "Ana Ruiz")],
            timeline: [said("$a1", matrixAna, "2026-10-26T10:00", text("Can you send me the potluck address?"))])
        return sync("s2", [("!dana:rivera.local", dana), ("!porch:rivera.local", porch), ("!ana:rivera.local", ana)])
    }
}
