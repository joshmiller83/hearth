import Foundation
import HearthKit
import HearthKitTestSupport
import Testing

@testable import HearthCore

@Suite("Texts")
@MainActor
struct ChatsModelTests {
    func loaded() async -> AppModel {
        let app = AppModel(services: .fixtures(waits: false))
        await app.refreshAll()
        return app
    }

    @Test func textsAreNamedFromContacts() async throws {
        let app = await loaded()
        let chats = app.chats
        #expect(chats.available)
        #expect(chats.waiting.map(\.thread.id) == ["mom"])
        let titles = chats.threads.map { chats.title($0.thread) }
        #expect(titles == ["Carol Rivera", "72975", "Rivera cousins", "Robin Rivera", "Coach Martinez"])
        let cousins = try #require(chats.threads.first { $0.thread.id == "cousins" })
        #expect(chats.preview(cousins) == "Jo: We have six folding ones")
        #expect(chats.messagesURL(cousins.thread) == nil)
        #expect(chats.messagesURL(try #require(chats.threads.first).thread)?.absoluteString == "sms:+15550100001")
        #expect(chats.statusLine.hasPrefix("9 texts in 5 conversations"))
    }

    @Test func notForMeLastsUntilTheyWriteAgain() async throws {
        let services = AppServices.fixtures(waits: false)
        let app = AppModel(services: services)
        await app.refreshAll()
        let mom = try #require(app.chats.waiting.first)
        app.chats.leaveOut(mom)
        #expect(app.chats.waiting.isEmpty)
        #expect(!TodaySummary.make(app: app).needsYou.contains { $0.kind == .text })
        // Remembered across launches, while it's the same last message.
        let again = AppModel(services: services)
        await again.refreshAll()
        #expect(again.chats.leftOut == ["mom#m3"])
        #expect(again.chats.waiting.isEmpty)
    }

    @Test func askSearchesTextsWithSomeone() async throws {
        let app = await loaded()
        let toolbox = app.ask.toolbox()
        #expect(toolbox.tools.contains { $0.name == AskTool.chatsSearch })
        let found = await toolbox.run(
            ToolUse(id: "t1", name: AskTool.chatsSearch, input: ["query": "", "person": "Mom", "days": 7]))
        #expect(!found.isError)
        #expect(found.text.contains("Carol Rivera, in Carol Rivera: Are you all coming Sunday?"))
        #expect(found.text.contains("[with a photo or file]"))
        #expect(!found.text.contains("Grab milk"))
        let nobody = await toolbox.run(
            ToolUse(id: "t2", name: AskTool.chatsSearch, input: ["query": "roast", "person": "Zed", "days": 7]))
        #expect(nobody.text.hasPrefix("No contact with a phone number"))
    }

    @Test func bridgedChatsGoByTheirNetworksNamesAndOpenThere() async throws {
        let app = await loaded()
        let chats = app.chats
        let dana = ChatThread(
            id: "!dana", source: ChatSource.whatsApp, handles: ["+15550100009"], service: "WhatsApp",
            names: ["+15550100009": "Dana Okafor"])
        #expect(chats.title(dana) == "Dana Okafor")
        #expect(chats.openLink(dana)?.title == "Open in WhatsApp")
        #expect(chats.openLink(dana)?.url.absoluteString == "https://wa.me/15550100009")
        let ana = ChatThread(
            id: "!ana", source: ChatSource.messenger, handles: ["facebook:100002"], service: "Messenger",
            names: ["facebook:100002": "Ana Ruiz"])
        #expect(chats.openLink(ana)?.url.absoluteString == "https://m.me/100002")
        let hidden = ChatThread(id: "!lid", source: ChatSource.whatsApp, handles: ["whatsapp:lid-42"], service: "WhatsApp")
        #expect(chats.openLink(hidden) == nil)
        #expect(chats.title(hidden) == "Someone on WhatsApp")
        let last = ChatMessage(
            id: "a1", threadId: "!ana", fromMe: false, sender: "facebook:100002", date: Fixtures.now.addingTimeInterval(-2 * 3600),
            text: "Hi")
        #expect(chats.meta(ChatSummary(thread: ana, last: last, unanswered: [], waiting: false)) == "Messenger · 2h ago")
        let signedOut = ChatSourceStatus(
            state: .needsAccess, message: "WhatsApp signed the bridge out. On the Mac: deploy/bridges/login.sh whatsapp",
            source: ChatSource.whatsApp)
        #expect(chats.bridgeLine(signedOut).hasSuffix("login.sh whatsapp"))
        // Fixtures have no bridges: Messages alone, as before.
        #expect(chats.bridges.isEmpty)
    }

    @Test func aTextGoesToCapture() async throws {
        let app = await loaded()
        let mom = try #require(app.chats.waiting.first)
        await app.chats.capture(mom.unanswered, in: mom.thread)
        #expect(app.capture.noteText.contains("Carol Rivera: Are you all coming Sunday? I'm making the roast."))
    }
}
