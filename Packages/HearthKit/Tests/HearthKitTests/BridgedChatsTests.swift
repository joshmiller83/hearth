import Foundation
import HearthKitTestSupport
import Testing

@testable import HearthKit

@Suite("Bridged chats")
struct BridgedChatsTests {
    static let both: Set<String> = [ChatSource.whatsApp, ChatSource.messenger]

    static func first(sources: Set<String> = both) throws -> ChatExport {
        BridgedChats.apply(
            try MatrixSync.decode(Fixtures.matrixFirstSync), to: nil, owner: Fixtures.matrixOwner, sources: sources, now: Fixtures.now)
    }

    @Test func ghostsBecomeHandles() {
        #expect(BridgedChats.handle(ghost: "@whatsapp_15550100009:rivera.local", source: "whatsapp") == "+15550100009")
        #expect(BridgedChats.handle(ghost: "@whatsapp_lid-42:rivera.local", source: "whatsapp") == "whatsapp:lid-42")
        #expect(BridgedChats.handle(ghost: "@facebook_100001:rivera.local", source: "facebook") == "facebook:100001")
        #expect(BridgedChats.handle(ghost: "@whatsappbot:rivera.local", source: "whatsapp") == nil)
        #expect(BridgedChats.handle(ghost: Fixtures.matrixOwner, source: "whatsapp") == nil)
        #expect(BridgedChats.handle(ghost: "@facebook_100001:rivera.local", source: "whatsapp") == nil)
    }

    @Test func aNetworksIdIsNeverAPhoneNumber() {
        // Fifteen digits would otherwise come out as someone's last ten in Contacts.
        #expect(ChatHandle.normalize("facebook:100012345678901") == "facebook:100012345678901")
        #expect(ChatHandle.normalize("+15550100009") == "5550100009")
        #expect(ChatHandle.isPerson("facebook:100001"))
        #expect(ChatHandle.isPerson("whatsapp:lid-42"))
        #expect(!ChatHandle.isPerson("whatsapp:bot-867"))
        #expect(ChatHandle.display("facebook:100001") == "Someone on Messenger")
        #expect(ChatHandle.display("+15550100009") == "+15550100009")
    }

    @Test func aFirstSyncBringsTheChatsAndNothingElse() throws {
        let export = try Self.first()
        #expect(export.threads.map(\.id) == ["!dana:rivera.local", "!porch:rivera.local"])
        let dana = export.threads[0]
        #expect(dana.source == ChatSource.whatsApp && dana.service == "WhatsApp")
        #expect(dana.name == nil)  // a one-to-one chat goes by the person
        #expect(dana.handles == ["+15550100009"])
        #expect(dana.names == ["+15550100009": "Dana Okafor"])  // without " (WA)"
        let porch = export.threads[1]
        #expect(porch.name == "Porch crew" && porch.service == "Messenger")
        #expect(porch.handles == ["facebook:100001", "facebook:100002"])
        #expect(porch.isGroup)
        // The bot's notice and the management room are left out; the photo is noted, not named.
        #expect(export.messages.map(\.id) == ["$d1", "$d2", "$d3", "$p1", "$p2"])
        let mine = export.messages[0]
        #expect(mine.fromMe && mine.sender == nil)
        let photo = export.messages[2]
        #expect(photo.hasAttachment && photo.text.isEmpty && photo.sender == "+15550100009")
        #expect(photo.date == Fixtures.at("2026-10-26T07:31"))
    }

    @Test func onlyTheBridgesAskedForAreKept() throws {
        let export = try Self.first(sources: [ChatSource.whatsApp])
        #expect(export.threads.map(\.source) == [ChatSource.whatsApp])
        #expect(!export.messages.contains { $0.threadId == "!porch:rivera.local" })
    }

    @Test func theNextSyncAddsAnswersEditsAndNewChats() throws {
        let first = try Self.first()
        let next = BridgedChats.apply(
            try MatrixSync.decode(Fixtures.matrixNextSync), to: first, owner: Fixtures.matrixOwner, sources: Self.both, now: Fixtures.now)
        #expect(next.threads.map(\.id) == ["!dana:rivera.local", "!porch:rivera.local", "!ana:rivera.local"])
        // Dana's chat kept its people though this sync only brought a message.
        #expect(next.threads[0].handles == ["+15550100009"])
        #expect(next.messages.first { $0.id == "$p1" }?.text == "Who has the tall ladder?")
        #expect(!next.messages.contains { $0.id == "$p3" })
        // The same sync again changes nothing.
        let again = BridgedChats.apply(
            try MatrixSync.decode(Fixtures.matrixNextSync), to: next, owner: Fixtures.matrixOwner, sources: Self.both, now: Fixtures.now)
        #expect(again.messages.map(\.id) == next.messages.map(\.id))

        let summaries = Chats.summaries(next, ownerName: "Sam", now: Fixtures.now)
        // Sam answered Dana; Ana asked on Messenger; the porch group doesn't name Sam.
        #expect(summaries.filter(\.waiting).map(\.thread.id) == ["!ana:rivera.local"])
    }

    @Test func leftRoomsAndOldMessagesGo() throws {
        let first = try Self.first()
        let left = try MatrixSync.decode(Data(#"{"next_batch":"s9","rooms":{"leave":{"!porch:rivera.local":{}}}}"#.utf8))
        let after = BridgedChats.apply(left, to: first, owner: Fixtures.matrixOwner, sources: Self.both, now: Fixtures.now)
        #expect(after.threads.map(\.id) == ["!dana:rivera.local"])
        #expect(!after.messages.contains { $0.threadId == "!porch:rivera.local" })
        let later = Fixtures.now.addingTimeInterval(61 * 86400)
        let aged = BridgedChats.apply(left, to: first, owner: Fixtures.matrixOwner, sources: Self.both, now: later)
        #expect(aged.messages.isEmpty)
        // The room stays, so a message months from now still knows who's in it.
        #expect(aged.threads.map(\.id) == ["!dana:rivera.local"])
    }

    @Test func requestsAreReadsAsTheOwner() throws {
        let sync = try #require(BridgedChats.syncRequest(homeserver: "http://127.0.0.1:8008/", token: "tok", since: "s1"))
        #expect(sync.method == "GET")
        #expect(sync.url.path == "/_matrix/client/v3/sync")
        #expect(sync.url.query?.contains("since=s1") == true)
        #expect(sync.url.query?.contains("timeout=0") == true)
        #expect(sync.headers["Authorization"] == "Bearer tok")
        let whoami = try #require(BridgedChats.whoamiRequest(.messenger, token: "tok", owner: Fixtures.matrixOwner))
        #expect(whoami.method == "GET")
        #expect(whoami.url.port == 29319)
        #expect(whoami.url.path == "/_matrix/provision/v3/whoami")
        #expect(whoami.url.query?.contains("user_id=") == true)
    }

    @Test func aBridgesStatusSaysWhatToDo() throws {
        let export = try Self.first()
        func whoami(_ state: String) throws -> JSONValue {
            try JSONValue.parse(#"{"logins":[{"id":"x","name":"Sam","state":{"state_event":"\#(state)"}}]}"#)
        }
        let ok = BridgedChats.status(.whatsApp, whoami: try whoami("CONNECTED"), export: export, now: Fixtures.now)
        #expect(ok.state == .ok && ok.source == ChatSource.whatsApp && ok.threads == 1 && ok.messages == 3)
        let out = BridgedChats.status(.whatsApp, whoami: try whoami("BAD_CREDENTIALS"), export: export, now: Fixtures.now)
        #expect(out.state == .needsAccess && out.message?.contains("deploy/bridges/login.sh whatsapp") == true)
        let none = BridgedChats.status(.messenger, whoami: try JSONValue.parse(#"{"logins":[]}"#), export: export, now: Fixtures.now)
        #expect(none.state == .needsAccess)
        let quiet = BridgedChats.status(.messenger, whoami: nil, export: export, now: Fixtures.now)
        #expect(quiet.state == .failed)
    }

    @Test func askFindsSomeoneByTheNetworksName() throws {
        let export = try Self.first()
        let found = Chats.search(export, ChatSearchRequest(query: "", days: 7, person: "lee"), now: Fixtures.now)
        #expect(found.messages.map(\.id) == ["$p2", "$p1"])
        let outcome = AskFormat.chats(found, names: [:], query: "", person: "Lee", fmt: Fixtures.household.fmt)
        #expect(outcome.text.contains("Lee Park, in Messenger group Porch crew: Who has the ladder?"))
        let nobody = Chats.search(export, ChatSearchRequest(query: "", days: 7, person: "zed"), now: Fixtures.now)
        #expect(nobody.messages.isEmpty)
    }

    @Test func exportsMerge() throws {
        let merged = try #require(ChatExport.merged([Fixtures.chats, try Self.first()]))
        #expect(merged.threads.count == Fixtures.chats.threads.count + 2)
        #expect(merged.source == ChatSource.all)
        #expect(ChatExport.merged([Fixtures.chats]) == Fixtures.chats)
        #expect(ChatExport.merged([]) == nil)
    }
}
