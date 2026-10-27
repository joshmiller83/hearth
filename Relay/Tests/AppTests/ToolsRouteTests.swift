import Foundation
import HearthKit
import HearthKitTestSupport
import Testing
import Vapor

@testable import App

@Suite("Ask's tools")
struct ToolsRouteTests {
    @Test func askCanSearchMail() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            let res = try await t.app.client2.send(
                .POST, RelayPath.tools + "/gmail_search", key: key, json: GmailSearchRequest(query: "from:dana", account: "all", limit: 5))
            #expect(res.status == .ok)
            let answer = try res.decode(GmailSearchResponse.self)
            #expect(answer.messages.map(\.id) == ["m1"])
            #expect(answer.messages.first?.account == "work")
            #expect(t.google.searches == ["from:dana"])
        }
    }

    @Test func onlyAsksReadToolsRun() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            let search = GmailSearchRequest(query: "dana")
            for name in ["gmail_reply", "gmail_delete_permanently", "gmail_save_attachments", "gmail_modify_batch", "nope"] {
                let res = try await t.app.client2.send(.POST, RelayPath.tools + "/" + name, key: key, json: search)
                #expect(res.status == .notFound, "\(name) must not run")
            }
            let noAccount = try await t.app.client2.send(
                .POST, RelayPath.tools + "/gmail_search", key: key, json: GmailSearchRequest(query: "dana", account: "nobody"))
            #expect(noAccount.status == .badRequest)
            let blank = try await t.app.client2.send(
                .POST, RelayPath.tools + "/gmail_search", key: key, json: GmailSearchRequest(query: "  "))
            #expect(blank.status == .badRequest)
            let noKey = try await t.app.client2.send(.POST, RelayPath.tools + "/gmail_search", json: search)
            #expect(noKey.status == .unauthorized)
            #expect(t.google.searches.isEmpty)
        }
    }
}
