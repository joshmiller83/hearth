import Foundation
import HearthKitTestSupport
import Testing

@testable import HearthKit

@Suite("Texts")
struct ChatsTests {
    /// An NSAttributedString as Messages archives it (made with NSArchiver from made-up text).
    static let archived = Data(
        base64Encoded:
            "BAtzdHJlYW10eXBlZIHoA4QBQISEhBJOU0F0dHJpYnV0ZWRTdHJpbmcAhIQITlNPYmplY3QAhZKEhIQITlNTdHJpbmcBlIQBKxdDYW4geW91IGdyYWIgbWlsaz8g8J+lm4aEAmlJARWShISEDE5TRGljdGlvbmFyeQCUhAFpAIaG"
    )!

    @Test func theTextComesOutOfAnAttributedBody() {
        #expect(TypedStream.text(from: Self.archived) == "Can you grab milk? 🥛")
    }

    @Test(arguments: [200, 70_000])
    func longerTextsCarryLongerLengths(count: Int) {
        // The same archive up to the string's "+", then a two- or four-byte length.
        let bytes = [UInt8](Self.archived)
        let plus = bytes.firstIndex(of: 0x2B)!
        var blob = Array(bytes[...plus])
        let length: [UInt8]
        if count < 65_536 {
            length = [0x81, UInt8(count & 0xFF), UInt8(count >> 8)]
        } else {
            length = [0x82] + (0..<4).map { (shift: Int) -> UInt8 in UInt8((count >> (8 * shift)) & 0xFF) }
        }
        blob += length
        blob += [UInt8](repeating: UInt8(ascii: "a"), count: count)
        blob.append(0x86)
        #expect(TypedStream.text(from: Data(blob))?.count == count)
    }

    @Test func noiseIsntText() {
        #expect(TypedStream.text(from: Data("hello".utf8)) == nil)
        #expect(TypedStream.text(from: Data(Self.archived.prefix(90))) == nil)
        #expect(ChatMessage.clean("\u{FFFC}Look at this") == "Look at this")
    }

    @Test func handlesMatchTheWayContactsWritesThem() {
        #expect(ChatHandle.normalize("+1 (555) 010-0001") == "5550100001")
        #expect(ChatHandle.normalize("+15550100001") == "5550100001")
        #expect(ChatHandle.normalize("Lou.Rivera@Example.com") == "lou.rivera@example.com")
        #expect(ChatHandle.normalize("72975") == "72975")
        #expect(ChatHandle.isPerson("+15550100001"))
        #expect(!ChatHandle.isPerson("72975"))
        #expect(!ChatHandle.isPerson("no-reply@example.com"))
    }

    @Test func onlyMomIsWaiting() throws {
        let summaries = Chats.summaries(Fixtures.chats, ownerName: "Sam", now: Fixtures.now)
        #expect(summaries.map(\.thread.id) == ["mom", "bank", "cousins", "robin", "coach"])
        #expect(summaries.filter(\.waiting).map(\.thread.id) == ["mom"])
        let mom = try #require(summaries.first)
        #expect(mom.unanswered.map(\.id) == ["m2", "m3"])
        #expect(mom.waitingId == "mom#m3")
    }

    @Test func aGroupWaitsOnlyWhenItNamesTheOwner() {
        let group = ChatThread(id: "g", handles: ["+15550100003", "+15550100004"])
        func asked(_ text: String) -> Bool {
            let message = ChatMessage(id: "x", threadId: "g", fromMe: false, sender: "+15550100003", date: Fixtures.now, text: text)
            return Chats.isWaiting(thread: group, unanswered: [message], ownerName: "Sam", now: Fixtures.now)
        }
        #expect(!asked("Who's bringing chairs?"))
        #expect(asked("Sam, can you bring the table?"))
        #expect(!asked("Samantha, can you bring the table?"))
        #expect(!asked("Sam's bringing the table."))
    }

    @Test func searchFindsEveryWordWithThePersonAsked() {
        let export = Fixtures.chats
        let roast = Chats.search(export, ChatSearchRequest(query: "sunday ROAST", days: 30), now: Fixtures.now)
        #expect(roast.messages.map(\.id) == ["m2"])
        #expect(roast.threads.map(\.id) == ["mom"])
        let withMom = Chats.search(export, ChatSearchRequest(query: "", handles: ["(555) 010-0001"], days: 30), now: Fixtures.now)
        #expect(withMom.messages.map(\.id) == ["m3", "m2", "m1"])
        let recent = Chats.search(export, ChatSearchRequest(query: "", days: 2, limit: 3), now: Fixtures.now)
        #expect(recent.messages.map(\.id) == ["m3", "m2", "b1"])
        let outcome = AskFormat.chats(roast, names: Fixtures.chatNames, query: "sunday roast", person: "", fmt: Fixtures.household.fmt)
        #expect(outcome.text.contains("Carol Rivera, in Carol Rivera: Are you all coming Sunday?"))
        #expect(outcome.trace == "Texts “sunday roast” · 1 found")
    }

    @Test func aConversationsLatestMessages() throws {
        let mom = try #require(Chats.thread("mom", in: Fixtures.chats, limit: 2))
        #expect(mom.messages.map(\.id) == ["m2", "m3"])
        #expect(Chats.thread("nobody", in: Fixtures.chats) == nil)
    }

    @Test func askOffersTextsOnlyWhenTheyCanBeRead() {
        #expect(!AskPrompt.tools(accounts: ["home"]).contains { $0.name == AskTool.chatsSearch })
        let tools = AskPrompt.tools(accounts: ["home"], texts: true)
        #expect(tools.map(\.name).suffix(2) == [AskTool.chatsSearch, AskTool.proposeActions])
        #expect(AskPrompt.system(household: Fixtures.household, now: Fixtures.now, texts: true).contains("recent texts and chats"))
    }
}
