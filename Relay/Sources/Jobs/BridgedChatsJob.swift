import Foundation
import HearthKit
import Logging
import RelayCore

/// Every two minutes: WhatsApp and Messenger, from the Mac's bridges (deploy/bridges).
/// It reads the private homeserver's /sync as the account the bridges work for, and asks
/// each bridge whether it's still signed in. Read only: it never sends to a room, joins
/// one or marks anything read. What it reads lands beside `hearth-messages`' export, so
/// Texts, Today and Ask take both alike.
public struct BridgedChatsJob: RelayJob {
    public let name = "bridges"
    public let schedule = JobSchedule.every(2 * 60)

    public init() {}

    public func run(_ context: JobContext) async throws {
        guard let matrix = context.matrix, let chats = context.chats, let http = context.http else { return }
        try await Self.read(matrix, into: chats, http: http, context)
    }

    public static func read(_ matrix: MatrixAccess, into chats: ChatStore, http: any HTTPTransport, _ context: JobContext) async throws {
        let now = context.now()
        let previous = await chats.bridgedExport()
        func fail(_ problem: String) async throws {
            let statuses = matrix.networks.map { BridgedChats.status($0, whoami: nil, export: previous, problem: problem, now: now) }
            try await chats.saveBridged(nil, statuses: statuses)
            context.logger.warning("bridges: \(problem)")
        }
        let login = "On the Mac: deploy/bridges/login.sh \(matrix.networks.first?.source ?? ChatSource.whatsApp)"
        guard let token = matrix.token() else {
            try await fail("The relay has no Matrix token yet. \(login)")
            return
        }
        // With nothing kept from before, start over with every room's latest.
        var since: String?
        if previous != nil { since = try await context.cache.get(String.self, Cache.bridgesSince) }
        guard let request = BridgedChats.syncRequest(homeserver: matrix.homeserver, token: token, since: since) else {
            try await fail("\(matrix.homeserver) isn't an address.")
            return
        }
        let sync: MatrixSync
        do {
            sync = try await Self.sync(request, http: http, login: login)
        } catch {
            try await fail(String(describing: error))
            throw error
        }

        let sources = Set(matrix.networks.map(\.source))
        let export = BridgedChats.apply(sync, to: previous, owner: matrix.owner, sources: sources, now: now)
        var statuses: [ChatSourceStatus] = []
        for network in matrix.networks {
            let whoami = await Self.whoami(network, token: token, owner: matrix.owner, http: http)
            statuses.append(BridgedChats.status(network, whoami: whoami, export: export, now: now))
        }
        try await chats.saveBridged(export, statuses: statuses)
        try await context.cache.set(sync.next_batch, Cache.bridgesSince, now: now)
        let states = statuses.map { "\($0.source ?? "?") \($0.state.rawValue)" }.joined(separator: ", ")
        context.logger.info("bridges: \(export.threads.count) chats, \(export.messages.count) messages; \(states)")
    }

    static func sync(_ request: HTTPRequest, http: any HTTPTransport, login: String) async throws -> MatrixSync {
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw TransportError("The Mac's Matrix server isn't answering (\(error)).")
        }
        switch response.status {
        case 200:
            break
        case 401:
            throw TransportError("The Mac's Matrix server refused the relay's token. \(login)")
        default:
            throw TransportError("The Mac's Matrix server answered \(response.status).")
        }
        do {
            return try MatrixSync.decode(response.body)
        } catch {
            throw TransportError("The Mac's Matrix server sent something Hearth couldn't read: \(error)")
        }
    }

    /// The bridge's whoami, or nil when it doesn't answer.
    static func whoami(_ network: BridgeNetwork, token: String, owner: String, http: any HTTPTransport) async -> JSONValue? {
        guard let request = BridgedChats.whoamiRequest(network, token: token, owner: owner),
            let response = try? await http.send(request), response.status == 200
        else { return nil }
        return try? JSONValue.parse(response.body)
    }
}
