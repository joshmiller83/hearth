import Foundation
import HearthKit
import RelayCore
import Vapor

/// Texts and bridged chats, read only: the conversations `hearth-messages` exported and
/// the bridges job read, and the ones waiting on the owner. Nothing here can send.
struct ChatsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("v1", "chats") { req async throws -> Response in
            let chats = req.relay.chats
            let status = await chats.status(now: req.now)
            let threads =
                await chats.current(now: req.now).map {
                    Chats.summaries($0, ownerName: req.relay.household.ownerName, now: req.now)
                } ?? []
            return try .json(ChatsResponse(status: status, threads: threads, sources: await chats.statuses(now: req.now)))
        }

        // Messages' ids ("iMessage;-;+15550100001") ride in the query, not the path.
        routes.get("v1", "chats", "thread") { req async throws -> Response in
            guard let id = req.query[String.self, at: "id"], !id.isEmpty else { throw Abort(.badRequest, reason: "Which conversation?") }
            guard let export = await req.relay.chats.current(now: req.now) else {
                throw Abort(.serviceUnavailable, reason: "Texts can't be read right now. See Messages in Sources.")
            }
            guard let thread = Chats.thread(id, in: export) else { throw Abort(.notFound, reason: "There's no such conversation.") }
            return try .json(thread)
        }
    }
}
