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
