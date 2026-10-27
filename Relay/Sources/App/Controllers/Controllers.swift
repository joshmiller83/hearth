import Executor
import Fluent
import Foundation
import HearthKit
import Jobs
import RelayCore
import Vapor

struct HealthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get { _ in "hearth-relay\n" }

        // Without the key: only "ok". With it: gmailkit, the accounts, the
        // household and the jobs, for the Sources screen.
        routes.get("v1", "health") { req async throws -> Response in
            let services = req.relay
            let basic = HealthResponse(status: "ok", version: RelayInfo.version, commit: services.config.commit)
            guard req.headers.bearerAuthorization != nil, try await RelayKeys.check(req) else {
                return try .json(basic)
            }
            var full = basic
            full.now = req.now
            full.gmailkit = await services.google.reader.status()
            full.accounts = try? await services.google.reader.accounts()
            full.household = services.household
            full.jobs = await services.jobs.statuses(req.application.jobContext())
            full.claude = services.claude != nil
            full.push = services.apns != nil
            full.chats = await services.chats.status(now: req.now)
            return try .json(full)
        }
    }
}

struct CalendarController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Every Google calendar, from the 15-minute cache; `refresh=1` sweeps now.
        routes.get("v1", "calendar", "events") { req async throws -> Response in
            let now = req.now
            let from = try req.queryDate("from") ?? now.addingTimeInterval(-86400)
            let to = try req.queryDate("to") ?? now.addingTimeInterval(30 * 86400)
            guard from < to else { throw Abort(.badRequest, reason: "from has to come before to.") }
            let refresh = ["1", "true", "yes"].contains(req.query[String.self, at: "refresh"] ?? "")

            let cache = Cache(db: req.db)
            var snapshot = try await cache.get(EventsResponse.self, Cache.events)
            if refresh || snapshot == nil {
                do {
                    snapshot = try await req.relay.refresher.refresh(req.application.jobContext())
                } catch {
                    guard var stale = snapshot else {
                        throw Abort(.serviceUnavailable, reason: "Couldn't read Google Calendar: \(error)")
                    }
                    stale.problems.append(SourceProblem(source: "relay", message: "Showing the last sweep: \(error)"))
                    snapshot = stale
                }
            }
            return try .json(CalendarSnapshot.window(snapshot!, from: from, to: to))
        }
    }
}

struct ActionsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Approved actions: run now, or held until `notBefore`.
        routes.post("v1", "actions") { req async throws -> Response in
            let batch = try req.decodeJSON(ActionBatch.self)
            guard !batch.actions.isEmpty else { throw Abort(.badRequest, reason: "No actions to run.") }
            guard batch.actions.count <= 50 else { throw Abort(.badRequest, reason: "At most 50 actions at a time.") }
            let statuses = try await req.relay.executor.submit(batch.actions)
            return try .json(ActionStatuses(actions: statuses))
        }

        routes.get("v1", "actions") { req async throws -> Response in
            let ids = (req.query[String.self, at: "ids"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
            guard !ids.isEmpty, ids.count <= 100 else { throw Abort(.badRequest, reason: "Pass ids=a,b,c (at most 100).") }
            return try .json(ActionStatuses(actions: try await req.relay.executor.statuses(ids: ids)))
        }

        // Take back an action that hasn't run yet.
        routes.delete("v1", "actions", ":id") { req async throws -> Response in
            guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
            do {
                return try .json(CancelResponse(action: try await req.relay.executor.cancel(id: id)))
            } catch ActionExecutor.CancelError.notFound {
                throw Abort(.notFound, reason: "There's no action with that id.")
            } catch ActionExecutor.CancelError.alreadyFinished(let state) {
                throw Abort(.conflict, reason: "It already finished (\(state.rawValue)), so there's nothing to cancel.")
            }
        }
    }
}

struct ContextController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // The phone's switches and Apple calendars, for the jobs that need them.
        routes.post("v1", "context") { req async throws -> HTTPStatus in
            let context = try req.decodeJSON(PhoneContext.self)
            let cache = Cache(db: req.db)
            try await cache.set(context, Cache.context, now: req.now)
            if let rules = context.mailRules { try await cache.set(rules, Cache.mailRules, now: req.now) }
            return .noContent
        }
    }
}

struct MailController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Every inbox, triaged by the last sweep; `refresh=1` sweeps now.
        routes.get("v1", "mail", "snapshot") { req async throws -> Response in
            let refresh = ["1", "true", "yes"].contains(req.query[String.self, at: "refresh"] ?? "")
            let cache = Cache(db: req.db)
            if !refresh, let snapshot = try await cache.get(MailSnapshot.self, Cache.mailSnapshot) {
                return try .json(snapshot)
            }
            do {
                return try .json(try await MailSweepJob.sweep(req.application.jobContext()))
            } catch {
                if let stale = try await cache.get(MailSnapshot.self, Cache.mailSnapshot) {
                    var out = stale
                    out.problems.append(SourceProblem(source: "relay", message: "Showing the last sweep: \(error)"))
                    return try .json(out)
                }
                throw Abort(.serviceUnavailable, reason: "Couldn't read the inboxes: \(error)")
            }
        }

        // One thread, with the text of each message.
        routes.get("v1", "mail", "threads", ":account", ":thread") { req async throws -> Response in
            guard let account = req.parameters.get("account"), let thread = req.parameters.get("thread") else { throw Abort(.badRequest) }
            do {
                let rows = try await req.relay.google.reader.thread(id: thread, account: account)
                return try .json(ThreadResponse(account: account, threadId: thread, messages: rows.compactMap(ThreadMessage.init(row:))))
            } catch let error as BridgeError {
                throw Abort(.badGateway, reason: error.description)
            }
        }
    }
}

struct BriefController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Today's brief, once the 6:30 job has written it.
        routes.get("v1", "brief") { req async throws -> Response in
            let brief = try await Cache(db: req.db).get(Brief.self, Cache.brief)
            let today = RFC3339.day(req.now, zone: req.relay.household.zone)
            return try .json(BriefResponse(brief: brief?.day == today ? brief : nil))
        }

        // The phone's APNs token.
        routes.post("v1", "devices") { req async throws -> HTTPStatus in
            let registration = try req.decodeJSON(DeviceRegistration.self)
            guard registration.token.count >= 32, registration.token.allSatisfy(\.isHexDigit) else {
                throw Abort(.badRequest, reason: "That isn't an APNs device token.")
            }
            if let device = try await DeviceModel.find(registration.token, on: req.db) {
                device.lastSeen = req.now
                device.environment = registration.environment
                try await device.update(on: req.db)
            } else {
                try await DeviceModel(token: registration.token, environment: registration.environment, now: req.now).create(on: req.db)
            }
            return .noContent
        }
    }
}

/// Ask's read-only tools. Only the tools named here run; anything else (every
/// write, every other gmailkit tool) is a 404.
struct ToolsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("v1", "tools", ":name") { req async throws -> Response in
            let name = req.parameters.get("name") ?? ""
            switch name {
            case AskTool.gmailSearch:
                let search = try req.decodeJSON(GmailSearchRequest.self)
                let query = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { throw Abort(.badRequest, reason: "Search for something.") }
                let reader = req.relay.google.reader
                let aliases = await reader.aliases()
                guard search.account == "all" || aliases.values.contains(search.account) else {
                    throw Abort(.badRequest, reason: "There's no account called \(search.account).")
                }
                let limit = min(max(search.limit, 1), GmailSearchRequest.maxLimit)
                do {
                    let rows = try await reader.search(query: query, account: search.account, limit: limit, metadataOnly: false)
                    var problems: [SourceProblem] = []
                    var messages: [MailItem] = []
                    for row in rows {
                        let alias = aliases[row.account.lowercased()] ?? row.account
                        if let error = row.error {
                            problems.append(SourceProblem(source: alias, message: error))
                        } else if let item = MailItem(row: row, alias: { aliases[$0.lowercased()] ?? $0 }) {
                            messages.append(item)
                        }
                    }
                    messages.sort { $0.date > $1.date }
                    return try .json(GmailSearchResponse(messages: Array(messages.prefix(limit)), problems: problems))
                } catch let error as BridgeError {
                    throw Abort(.badGateway, reason: error.description)
                }
            case AskTool.chatsSearch:
                let search = try req.decodeJSON(ChatSearchRequest.self)
                guard let export = await req.relay.chats.current(now: req.now) else {
                    throw Abort(.serviceUnavailable, reason: "Texts can't be read right now. See Messages in Sources.")
                }
                return try .json(Chats.search(export, search, now: req.now))
            default:
                throw Abort(.notFound, reason: "Ask has no tool called \(name).")
            }
        }
    }
}

struct SignalsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // What the relay watches for the phone (the weather); `refresh=1` checks now.
        routes.get("v1", "signals") { req async throws -> Response in
            if ["1", "true", "yes"].contains(req.query[String.self, at: "refresh"] ?? "") {
                return try .json(try await WeatherJob.check(req.application.jobContext()))
            }
            let cached = try await Cache(db: req.db).get(RelaySignals.self, Cache.signals)
            return try .json(cached ?? RelaySignals(signals: [], fetchedAt: nil))
        }
    }
}

struct FeedsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Every feed, and the kept events still ahead.
        routes.get("v1", "feeds") { req async throws -> Response in
            try .json(try await FeedStore(Cache(db: req.db)).response(now: req.now))
        }

        // A new feed, read at once.
        routes.post("v1", "feeds") { req async throws -> Response in
            let new = try req.decodeJSON(NewFeed.self)
            let name = new.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw Abort(.badRequest, reason: "A feed needs a name.") }
            var url: URL?
            switch new.kind {
            case .ical, .page:
                guard let address = new.url, let safe = FeedAddress.safe(address) else {
                    throw Abort(.badRequest, reason: "Only public https addresses can be feeds.")
                }
                url = safe
            case .email:
                guard let from = new.from, from.contains("@") || from.contains(".") else {
                    throw Abort(.badRequest, reason: "An email feed needs the sender's address.")
                }
            }
            let feed = Feed(
                name: name, kind: new.kind, url: url, from: new.from, category: new.category, skip: new.skip, addedAt: req.now)
            let store = FeedStore(Cache(db: req.db))
            try await store.add(feed, now: req.now)
            try await FeedsJob.check(feed.id, req.application.jobContext())
            return try .json(try await store.response(now: req.now), status: .created)
        }

        routes.delete("v1", "feeds", ":id") { req async throws -> Response in
            guard let id = req.parameters.get("id") else { throw Abort(.badRequest) }
            let store = FeedStore(Cache(db: req.db))
            guard try await store.feeds().contains(where: { $0.id == id }) else { throw Abort(.notFound, reason: "No such feed.") }
            try await store.remove(id, now: req.now)
            return try .json(try await store.response(now: req.now))
        }

        // A calendar feed read once, for the chat's preview. Nothing is saved.
        routes.post("v1", "feeds", "preview") { req async throws -> Response in
            let preview = try req.decodeJSON(FeedPreviewRequest.self)
            guard let url = FeedAddress.safe(preview.url) else {
                throw Abort(.badRequest, reason: "Only public https addresses can be read.")
            }
            do {
                let read = try await FeedsJob.calendar(
                    url, feedId: "preview", http: req.relay.http, zone: req.relay.household.zone, now: req.now)
                return try .json(FeedPreview(url: url, name: read.name, events: read.events))
            } catch let error as FeedError {
                throw Abort(.unprocessableEntity, reason: "Couldn't read that feed: \(error.description).")
            }
        }
    }
}
