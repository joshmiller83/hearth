import Crypto
import Foundation
import HearthKit
import HearthKitTestSupport
import Jobs
import NIOCore
import Testing
import Vapor

@testable import App
@testable import RelayCore

/// A Vapor `Client` that records requests and answers from a script.
final class FakeHTTPClient: Client, @unchecked Sendable {
    let eventLoop: any EventLoop
    private let lock = NSLock()
    private var statuses: [HTTPResponseStatus]
    private(set) var requests: [ClientRequest] = []

    init(eventLoop: any EventLoop, statuses: [HTTPResponseStatus]) {
        self.eventLoop = eventLoop
        self.statuses = statuses
    }

    func delegating(to eventLoop: any EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        lock.lock()
        requests.append(request)
        let status = statuses.isEmpty ? .ok : statuses.removeFirst()
        lock.unlock()
        return eventLoop.makeSucceededFuture(
            ClientResponse(status: status, body: ByteBuffer(string: status == .gone ? #"{"reason":"Unregistered"}"# : "")))
    }
}

@Suite("Brief and push")
struct BriefAndPushTests {
    static let key = P256.Signing.PrivateKey()

    func apns(_ client: any Client) throws -> APNsClient {
        try APNsClient(
            config: APNsConfig(
                keyPEM: Self.key.pemRepresentation, keyId: "KEY123", teamId: "TEAM456",
                topic: "com.example.hearth", sandbox: true), client: client)
    }

    func claudeBrief() -> ClaudeClient {
        let reply = BriefPrompt.Reply(
            headline: "Two invites need you. The rest can wait.", order: ["g:work:primary:huddle"],
            kindIdea: "Thursday is free for you both: dinner out?", kindIdeaFor: "Robin")
        let text = String(decoding: try! HearthJSON.encode(reply), as: UTF8.self)
        return ClaudeClient(apiKey: "k", transport: ScriptedTransport([ScriptedTransport.message(text: text)]), pause: { _ in })
    }

    @Test func theBriefIsWrittenAndItsPushWaitsForSeven() async throws {
        let clock = ManualClock(Fixtures.at("2026-10-26T06:30"))
        try await withTestApp(clock: clock, claude: claudeBrief()) { t in
            let key = try await t.key()
            _ = try await t.app.client2.send(.GET, RelayPath.calendarEvents, key: key)
            // Just the brief (the mail sweep would use Claude too).
            #expect(await t.app.relay.jobs.run(named: "brief", t.app.jobContext()))
            let response = try await t.app.client2.send(.GET, RelayPath.brief, key: key).decode(BriefResponse.self)
            #expect(response.brief?.headline == "Two invites need you. The rest can wait.")
            #expect(response.brief?.order == ["g:work:primary:huddle"])
            #expect(response.brief?.kindIdeaFor == "Robin")
            let push = try #require(try await PushModel.query(on: t.app.db).first())
            #expect(push.deliverAfter == Fixtures.at("2026-10-26T07:00"))
            #expect(push.alert?.title == "Good morning, Sam")
            // Tomorrow, yesterday's brief isn't today's.
            clock.set(Fixtures.at("2026-10-27T06:00"))
            #expect(try await t.app.client2.send(.GET, RelayPath.brief, key: key).decode(BriefResponse.self).brief == nil)
        }
    }

    @Test func noKeyOrBriefOffMeansNoBrief() async throws {
        try await withTestApp { t in
            let brief = try await BriefJob.write(t.app.jobContext())
            #expect(brief == nil)
        }
        try await withTestApp(claude: claudeBrief()) { t in
            var rules = HouseRules()
            rules.morningBrief = false
            try await Cache(db: t.app.db).set(PhoneContext(rules: rules, uploadedAt: t.clock.now), Cache.context, now: t.clock.now)
            let brief = try await BriefJob.write(t.app.jobContext())
            #expect(brief == nil)
        }
    }

    @Test func urgentPushesSkipQuietHours() async throws {
        try await withTestApp { t in
            let night = Fixtures.at("2026-10-26T23:00")
            let zone = Fixtures.zone
            let urgent = try await PushQueue.enqueue(
                PushAlert(title: "!", body: "Frost tonight", kind: "signal", urgency: .urgent),
                quietHours: QuietHours(), zone: zone, now: night, db: t.app.db)
            let normal = try await PushQueue.enqueue(
                PushAlert(title: "Hi", body: "Newsletter", kind: "signal"),
                quietHours: QuietHours(), zone: zone, now: night, db: t.app.db)
            #expect(urgent == night)
            #expect(normal == Fixtures.at("2026-10-27T07:00"))
        }
    }

    @Test func theProviderTokenIsAValidES256JWT() async throws {
        try await withTestApp { t in
            let client = try apns(FakeHTTPClient(eventLoop: t.app.eventLoopGroup.next(), statuses: []))
            let jwt = try await client.jwt(now: Date(timeIntervalSince1970: 1_800_000_000))
            let parts = jwt.split(separator: ".").map(String.init)
            #expect(parts.count == 3)
            func decode(_ part: String) -> Data {
                var s = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while s.count % 4 != 0 { s += "=" }
                return Data(base64Encoded: s)!
            }
            #expect(String(decoding: decode(parts[0]), as: UTF8.self) == #"{"alg":"ES256","kid":"KEY123"}"#)
            #expect(String(decoding: decode(parts[1]), as: UTF8.self) == #"{"iss":"TEAM456","iat":1800000000}"#)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
            #expect(Self.key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
            // Reused within 50 minutes.
            #expect(try await client.jwt(now: Date(timeIntervalSince1970: 1_800_000_600)) == jwt)
        }
    }

    @Test func duePushesGoToEveryDeviceAndDeadTokensAreDropped() async throws {
        try await withTestApp { t in
            let http = FakeHTTPClient(eventLoop: t.app.eventLoopGroup.next(), statuses: [.ok, .gone])
            let client = try apns(http)
            let good = String(repeating: "a", count: 64)
            let dead = String(repeating: "b", count: 64)
            for token in [good, dead] {
                try await DeviceModel(token: token, environment: "development", now: t.clock.now).create(on: t.app.db)
            }
            try await PushQueue.enqueue(
                PushAlert(title: "Hearth", body: "Hi", kind: "test", urgency: .urgent), quietHours: QuietHours(),
                zone: Fixtures.zone, now: t.clock.now, db: t.app.db)
            let sent = await PushQueue.sendDue(apns: client, db: t.app.db, now: t.clock.now, logger: t.app.logger)
            #expect(sent == 1)
            #expect(http.requests.count == 2)
            let request = try #require(http.requests.first)
            #expect(request.url.string.hasPrefix("https://api.sandbox.push.apple.com/3/device/"))
            #expect(request.headers.first(name: "apns-topic") == "com.example.hearth")
            #expect(request.headers.first(name: "apns-push-type") == "alert")
            #expect(request.headers.first(name: "authorization")?.hasPrefix("bearer ") == true)
            let body = try JSONValue.parse(Data(buffer: try #require(request.body)))
            #expect(body["aps"]?["alert"]?["body"]?.stringValue == "Hi")
            #expect(body["aps"]?["content-available"]?.intValue == 1)
            #expect(try await DeviceModel.query(on: t.app.db).count() == 1)
            #expect(try await PushModel.query(on: t.app.db).first()?.sentAt != nil)
        }
    }

    @Test func phonesRegisterTheirTokens() async throws {
        try await withTestApp { t in
            let key = try await t.key()
            let token = String(repeating: "c", count: 64)
            let ok = try await t.app.client2.send(
                .POST, RelayPath.devices, key: key, json: DeviceRegistration(token: token, environment: "development"))
            #expect(ok.status == .noContent)
            let again = try await t.app.client2.send(
                .POST, RelayPath.devices, key: key, json: DeviceRegistration(token: token, environment: "development"))
            #expect(again.status == .noContent)
            #expect(try await DeviceModel.query(on: t.app.db).count() == 1)
            let bad = try await t.app.client2.send(
                .POST, RelayPath.devices, key: key, json: DeviceRegistration(token: "nope", environment: "development"))
            #expect(bad.status == .badRequest)
        }
    }
}
