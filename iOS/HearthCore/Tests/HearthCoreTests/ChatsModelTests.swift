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
        #expect(titles == ["Carol Rivera", "72975", "Rivera cousins", "+15550100009", "Robin Rivera", "Coach Martinez"])
        let cousins = try #require(chats.threads.first { $0.thread.id == "cousins" })
        #expect(chats.preview(cousins) == "Jo: We have six folding ones")
        #expect(chats.messagesURL(cousins.thread) == nil)
        #expect(chats.messagesURL(try #require(chats.threads.first).thread)?.absoluteString == "sms:+15550100001")
        #expect(chats.statusLine.hasPrefix("10 texts in 6 conversations"))
    }

    @Test func aStrangersQuestionWaitsOnlyOnceContactsKnowsThem() async throws {
        let app = await loaded()
        #expect(TodaySummary.make(app: app).needsYou.filter { $0.kind == .text }.map(\.id) == ["mom#m3"])
        var services = AppServices.fixtures(waits: false)
        services.people = ContactsWithTheStore()
        let known = AppModel(services: services)
        await known.refreshAll()
        #expect(known.chats.waiting.map(\.thread.id) == ["mom", "store"])
        #expect(TodaySummary.make(app: known).needsYou.filter { $0.kind == .text }.map(\.id) == ["mom#m3", "store#s1"])
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

    @Test func aTextGoesToCapture() async throws {
        let app = await loaded()
        let mom = try #require(app.chats.waiting.first)
        await app.chats.capture(mom.unanswered, in: mom.thread)
        #expect(app.capture.noteText.contains("Carol Rivera: Are you all coming Sunday? I'm making the roast."))
    }
}

/// The household's contacts, with the store that texted saved among them.
struct ContactsWithTheStore: PeopleDirectory {
    func find(_ query: String) async throws -> [PersonCard] { try await FixturePeople().find(query) }

    func names(for handles: [String]) async -> [String: String] {
        var names = await FixturePeople().names(for: handles)
        if handles.map(ChatHandle.normalize).contains("5550100009") { names["5550100009"] = "Maple Grove Hardware" }
        return names
    }
}
