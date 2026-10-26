import Crypto
import Fluent
import Foundation
import HearthKit
import Vapor

/// What a push says.
public struct PushAlert: Codable, Hashable, Sendable {
    public var title: String
    public var body: String
    /// "brief", "action", "signal", "test": the app opens the right screen.
    public var kind: String
    public var urgency: PushUrgency

    public init(title: String, body: String, kind: String, urgency: PushUrgency = .normal) {
        self.title = title
        self.body = body
        self.kind = kind
        self.urgency = urgency
    }
}

/// The APNs key (a .p8 from the Apple Developer site) and where pushes go.
public struct APNsConfig: Sendable {
    public var keyPEM: String
    public var keyId: String
    public var teamId: String
    /// The app's bundle id.
    public var topic: String
    /// Xcode installs use the sandbox ("development").
    public var sandbox: Bool

    public init(keyPEM: String, keyId: String, teamId: String, topic: String, sandbox: Bool) {
        self.keyPEM = keyPEM
        self.keyId = keyId
        self.teamId = teamId
        self.topic = topic
        self.sandbox = sandbox
    }

    public var host: String { sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com" }
}

/// Sends pushes over HTTP/2 with a token (ES256 JWT) that's renewed every 50 minutes.
public actor APNsClient {
    public enum Outcome: Equatable, Sendable {
        case sent
        /// The device token is gone (app removed, token rotated): forget it.
        case unregistered
        case failed(String)
    }

    let config: APNsConfig
    let key: P256.Signing.PrivateKey
    let client: any Client
    private var token: (value: String, made: Date)?

    public init(config: APNsConfig, client: any Client) throws {
        self.config = config
        key = try P256.Signing.PrivateKey(pemRepresentation: config.keyPEM)
        self.client = client
    }

    /// The provider token: header and claims, signed with the key.
    func jwt(now: Date) throws -> String {
        if let token, now.timeIntervalSince(token.made) < 50 * 60 { return token.value }
        let header = Self.base64url(Data(#"{"alg":"ES256","kid":"\#(config.keyId)"}"#.utf8))
        let claims = Self.base64url(Data(#"{"iss":"\#(config.teamId)","iat":\#(Int(now.timeIntervalSince1970))}"#.utf8))
        let signature = try key.signature(for: Data((header + "." + claims).utf8))
        let value = header + "." + claims + "." + Self.base64url(signature.rawRepresentation)
        token = (value, now)
        return value
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func payload(_ alert: PushAlert) -> Data {
        let body: JSONValue = [
            "aps": [
                "alert": ["title": .string(alert.title), "body": .string(alert.body)],
                "sound": "default",
                "thread-id": .string(alert.kind),
                // Wakes Hearth in the background too, so Today and the StandBy widgets catch up.
                "content-available": 1,
                "interruption-level": .string(alert.urgency == .urgent ? "time-sensitive" : "active"),
            ],
            "hearth": ["kind": .string(alert.kind)],
        ]
        return body.data
    }

    public func send(_ alert: PushAlert, to device: String, now: Date) async -> Outcome {
        do {
            var headers = HTTPHeaders()
            headers.add(name: "authorization", value: "bearer " + (try jwt(now: now)))
            headers.add(name: "apns-topic", value: config.topic)
            headers.add(name: "apns-push-type", value: "alert")
            headers.add(name: "apns-priority", value: alert.urgency == .normal ? "5" : "10")
            headers.add(name: "apns-expiration", value: String(Int(now.timeIntervalSince1970) + 6 * 3600))
            let response = try await client.post(URI(string: config.host + "/3/device/" + device), headers: headers) { request in
                request.body = ByteBuffer(data: Self.payload(alert))
            }
            switch response.status.code {
            case 200: return .sent
            case 410: return .unregistered
            case 400 where response.body.map { String(buffer: $0) }?.contains("BadDeviceToken") == true: return .unregistered
            default:
                let reason = response.body.map { String(buffer: $0) } ?? ""
                return .failed("APNs \(response.status.code) \(reason)")
            }
        } catch {
            return .failed(String(describing: error))
        }
    }
}

/// A push waiting for its time (quiet hours) or to be sent.
public final class PushModel: Model, @unchecked Sendable {
    public static let schema = "pushes"

    @ID(key: .id) public var id: UUID?
    @Field(key: "alert_json") public var alertJSON: String
    @Field(key: "deliver_after") public var deliverAfter: Date
    @OptionalField(key: "sent_at") public var sentAt: Date?
    @Field(key: "attempts") public var attempts: Int
    @OptionalField(key: "last_error") public var lastError: String?
    @Field(key: "created_at") public var createdAt: Date

    public init() {}

    public var alert: PushAlert? { try? HearthJSON.decode(PushAlert.self, from: Data(alertJSON.utf8)) }
}

public struct CreatePushes: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(PushModel.schema)
            .id()
            .field("alert_json", .string, .required)
            .field("deliver_after", .datetime, .required)
            .field("sent_at", .datetime)
            .field("attempts", .int, .required)
            .field("last_error", .string)
            .field("created_at", .datetime, .required)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(PushModel.schema).delete()
    }
}

/// Queues pushes so quiet hours hold them, and sends what's due.
public enum PushQueue {
    /// Queues a push; ordinary ones wait out quiet hours, family and urgent ones don't.
    @discardableResult
    public static func enqueue(_ alert: PushAlert, quietHours: QuietHours, zone: TimeZone, now: Date, db: any Database) async throws -> Date
    {
        let model = PushModel()
        model.alertJSON = String(decoding: try HearthJSON.encode(alert), as: UTF8.self)
        model.deliverAfter =
            quietHours.shouldDeliver(alert.urgency, at: now, zone: zone) ? now : quietHours.nextAllowed(after: now, zone: zone)
        model.attempts = 0
        model.createdAt = now
        try await model.create(on: db)
        return model.deliverAfter
    }

    /// Sends due pushes to every device. Returns how many went out.
    @discardableResult
    public static func sendDue(apns: APNsClient, db: any Database, now: Date, logger: Logger) async -> Int {
        guard let due = try? await dueQuery(db: db, now: now), !due.isEmpty,
            let devices = try? await DeviceModel.query(on: db).all(), !devices.isEmpty
        else { return 0 }
        var sent = 0
        for push in due {
            guard let alert = push.alert else { continue }
            var delivered = false
            var errors: [String] = []
            for device in devices {
                switch await apns.send(alert, to: device.id ?? "", now: now) {
                case .sent: delivered = true
                case .unregistered: try? await device.delete(on: db)
                case .failed(let reason): errors.append(reason)
                }
            }
            push.attempts += 1
            if delivered || push.attempts >= 5 {
                push.sentAt = now
                if delivered { sent += 1 }
            }
            push.lastError = errors.first
            try? await push.update(on: db)
            if let error = errors.first { logger.warning("push \(alert.kind): \(error)") }
        }
        return sent
    }

    static func dueQuery(db: any Database, now: Date) async throws -> [PushModel] {
        try await PushModel.query(on: db).filter(\.$sentAt == nil).filter(\.$deliverAfter <= now).all()
    }
}
