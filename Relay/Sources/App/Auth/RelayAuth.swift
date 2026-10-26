import Fluent
import Foundation
import NIOCore
import RelayCore
import Vapor

/// Checks `Authorization: Bearer <relay key>` against the stored hashes.
/// Wrong keys count against the client address; too many in 15 minutes and it
/// gets 429s until the window passes.
struct RelayKeyMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard try await RelayKeys.check(request) else {
            throw Abort(.unauthorized, headers: ["WWW-Authenticate": "Bearer"], reason: "This needs the relay key from Sources.")
        }
        return try await next.respond(to: request)
    }
}

enum RelayKeys {
    /// True when the request carries a live key. Throws 429 when the address is locked out.
    static func check(_ request: Request) async throws -> Bool {
        let ip = request.clientIP
        let limiter = request.application.failedAuth
        if let wait = await limiter.lockedFor(ip, now: request.now) {
            throw Abort(
                .tooManyRequests, headers: ["Retry-After": String(Int(wait.rounded(.up)))],
                reason: "Too many wrong keys. Try again in a few minutes.")
        }
        guard let token = request.headers.bearerAuthorization?.token, !token.isEmpty else { return false }
        let hash = Codes.sha256Hex(token)
        guard
            let key = try await RelayKeyModel.query(on: request.db)
                .filter(\.$hash == hash)
                .filter(\.$revokedAt == nil)
                .first()
        else {
            await limiter.fail(ip, now: request.now)
            return false
        }
        // Note the use at most once an hour, so reads don't turn into writes.
        if key.lastUsedAt.map({ request.now.timeIntervalSince($0) > 3600 }) ?? true {
            key.lastUsedAt = request.now
            try? await key.update(on: request.db)
        }
        return true
    }

    /// Makes a key, stores its hash, and returns the key (shown once).
    static func issue(label: String, on db: any Database, now: Date) async throws -> String {
        let key = Codes.relayKey()
        try await RelayKeyModel(label: label, hash: Codes.sha256Hex(key), createdAt: now).create(on: db)
        return key
    }
}

/// Counts wrong keys per address in a sliding window. In memory: a restart forgives.
actor FailedAuthLimiter {
    let limit: Int
    let window: TimeInterval
    private var failures: [String: [Date]] = [:]

    init(limit: Int = 10, window: TimeInterval = 15 * 60) {
        self.limit = limit
        self.window = window
    }

    func fail(_ ip: String, now: Date) {
        var list = failures[ip, default: []].filter { now.timeIntervalSince($0) < window }
        list.append(now)
        failures[ip] = list
        if failures.count > 1000 {
            failures = failures.filter { $0.value.contains { now.timeIntervalSince($0) < window } }
        }
    }

    /// How long `ip` must wait, or nil when it may try.
    func lockedFor(_ ip: String, now: Date) -> TimeInterval? {
        let list = failures[ip, default: []].filter { now.timeIntervalSince($0) < window }
        guard list.count >= limit, let oldest = list.first else { return nil }
        return max(1, window - now.timeIntervalSince(oldest))
    }
}

/// The address a request really came from. Behind the Cloudflare tunnel every
/// connection comes from cloudflared on this Mac, so `CF-Connecting-IP` is
/// believed only when the peer is localhost; anyone else could forge it.
enum ClientIP {
    static func resolve(peer: SocketAddress?, headers: HTTPHeaders) -> String {
        guard let ip = peer?.ipAddress else { return "unknown" }
        if ip == "127.0.0.1" || ip == "::1",
            let forwarded = headers.first(name: "CF-Connecting-IP")?.trimmingCharacters(in: .whitespaces),
            !forwarded.isEmpty
        {
            return forwarded
        }
        return ip
    }
}

extension Request {
    var clientIP: String { ClientIP.resolve(peer: remoteAddress, headers: headers) }
}
