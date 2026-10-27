import ChatReader
import Foundation
import HearthKit
import HearthKitTestSupport
import RelayCore
import Testing
import Vapor

@testable import App

@Suite("Bridged chats")
struct BridgedChatRouteTests {
    static func access(_ dir: String, networks: [BridgeNetwork] = BridgeNetwork.all, token: String? = "relay-token") throws
        -> MatrixAccess
    {
        let tokenFile = dir + "/matrix-token"
        if let token { try Data((token + "\n").utf8).write(to: URL(fileURLWithPath: tokenFile)) }
        return MatrixAccess(homeserver: "http://127.0.0.1:8008", tokenFile: tokenFile, owner: Fixtures.matrixOwner, networks: networks)
    }

    static func whoami(_ state: String) -> ScriptedTransport.Reply {
        .response(HTTPResponse(status: 200, body: Data(#"{"logins":[{"id":"x","name":"Sam","state":{"state_event":"\#(state)"}}]}"#.utf8)))
    }

    @Test func whatsAppAndMessengerJoinTheTexts() async throws {
        let dir = try ChatRouteTests.directory()
        try ChatExportWriter.write(Fixtures.chats, to: dir)
        try ChatExportWriter.write(
            ChatSourceStatus(state: .ok, checkedAt: Fixtures.now, exportedAt: Fixtures.now, threads: 5, messages: 9), to: dir)
        let matrix = try Self.access(dir)
        let http = ScriptedTransport([
            .response(HTTPResponse(status: 200, body: Fixtures.matrixFirstSync)),
            Self.whoami("CONNECTED"),
            .failure("connection refused"),  // Messenger's bridge isn't up yet
            .response(HTTPResponse(status: 200, body: Fixtures.matrixNextSync)),
            Self.whoami("CONNECTED"),
            Self.whoami("CONNECTED"),
        ])
        try await withTestApp(
            http: http,
            adjust: {
                $0.chatsDirectory = dir
                $0.matrix = matrix
            }
        ) { t in
            let key = try await t.key()
            #expect(await t.app.relay.jobs.run(named: "bridges", t.app.jobContext()))
            let first = http.requests
            #expect(first.count == 3)
            #expect(first[0].url.path == "/_matrix/client/v3/sync")
            #expect(first[0].url.query?.contains("since=") == false)
            #expect(first[0].headers["Authorization"] == "Bearer relay-token")
            #expect(first[1].url.port == 29318 && first[2].url.port == 29319)

            let list = try await t.app.client2.send(.GET, RelayPath.chats, key: key).decode(ChatsResponse.self)
            #expect(list.status.state == .ok)
            let sources = list.sources ?? []
            #expect(sources.map(\.source) == [ChatSource.iMessage, ChatSource.whatsApp, ChatSource.messenger])
            #expect(sources.map(\.state) == [.ok, .ok, .failed])
            // Messenger's bridge didn't answer, so its chats wait; WhatsApp's sit with the texts.
            let ids = list.threads.map(\.thread.id)
            #expect(ids.contains("!dana:rivera.local") && ids.contains("mom") && !ids.contains("!porch:rivera.local"))
            #expect(list.threads.filter(\.waiting).map(\.thread.id).sorted() == ["!dana:rivera.local", "mom"])
            let dana = try await t.app.client2.send(.GET, RelayPath.chatThread + "?id=%21dana%3Arivera.local", key: key)
                .decode(ChatThreadResponse.self)
            #expect(dana.thread.service == "WhatsApp")
            #expect(dana.messages.map(\.id) == ["$d1", "$d2", "$d3"])

            // Two minutes on, the next sync carries on from the first.
            t.clock.advance(2 * 60)
            #expect(await t.app.relay.jobs.run(named: "bridges", t.app.jobContext()))
            #expect(http.requests[3].url.query?.contains("since=s1") == true)
            #expect(http.requests.allSatisfy { $0.method == "GET" && $0.body == nil })
            let after = try await t.app.client2.send(.GET, RelayPath.chats, key: key).decode(ChatsResponse.self)
            #expect(after.sources?.map(\.state) == [.ok, .ok, .ok])
            #expect(after.threads.filter(\.waiting).map(\.thread.id).sorted() == ["!ana:rivera.local", "mom"])

            // Ask finds Lee by the name Messenger gives him.
            let found = try await t.app.client2.send(
                .POST, RelayPath.tools + "/chats_search", key: key, json: ChatSearchRequest(query: "ladder", days: 7, person: "lee")
            ).decode(ChatSearchResponse.self)
            #expect(found.messages.map(\.id) == ["$p1"])
            #expect(found.messages.first?.text == "Who has the tall ladder?")

            let health = try await t.app.client2.send(.GET, RelayPath.health, key: key).decode(HealthResponse.self)
            #expect(health.chatSources?.map(\.source) == [ChatSource.iMessage, ChatSource.whatsApp, ChatSource.messenger])
            #expect(health.jobs?.contains { $0.name == "bridges" && $0.lastError == nil } == true)
        }
    }

    @Test func withoutAnAccountTheBridgesSaySo() async throws {
        let dir = try ChatRouteTests.directory()
        let matrix = try Self.access(dir, networks: [.whatsApp], token: nil)
        let http = ScriptedTransport([])
        try await withTestApp(
            http: http,
            adjust: {
                $0.chatsDirectory = dir
                $0.matrix = matrix
            }
        ) { t in
            let key = try await t.key()
            #expect(await t.app.relay.jobs.run(named: "bridges", t.app.jobContext()))
            #expect(http.requests.isEmpty)
            let list = try await t.app.client2.send(.GET, RelayPath.chats, key: key).decode(ChatsResponse.self)
            let whatsApp = try #require(list.sources?.last)
            #expect(whatsApp.source == ChatSource.whatsApp && whatsApp.state == .failed)
            #expect(whatsApp.message?.contains("deploy/bridges/login.sh") == true)
            #expect(list.threads.isEmpty)
        }
    }

    @Test func aSignedOutBridgeKeepsItsChatsBack() async throws {
        let dir = try ChatRouteTests.directory()
        let matrix = try Self.access(dir, networks: [.whatsApp])
        let http = ScriptedTransport([
            .response(HTTPResponse(status: 200, body: Fixtures.matrixFirstSync)), Self.whoami("BAD_CREDENTIALS"),
        ])
        try await withTestApp(
            http: http,
            adjust: {
                $0.chatsDirectory = dir
                $0.matrix = matrix
            }
        ) { t in
            let key = try await t.key()
            #expect(await t.app.relay.jobs.run(named: "bridges", t.app.jobContext()))
            let list = try await t.app.client2.send(.GET, RelayPath.chats, key: key).decode(ChatsResponse.self)
            #expect(list.sources?.last?.state == .needsAccess)
            #expect(list.threads.isEmpty)
            // The job ran fine: a signed-out bridge is the owner's to fix, not an error.
            let health = try await t.app.client2.send(.GET, RelayPath.health, key: key).decode(HealthResponse.self)
            #expect(health.jobs?.first { $0.name == "bridges" }?.lastError == nil)
        }
    }
}
