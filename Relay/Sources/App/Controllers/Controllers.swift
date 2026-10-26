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
            full.push = false
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
