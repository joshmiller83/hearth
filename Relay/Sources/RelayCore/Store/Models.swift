import Fluent
import Foundation
import HearthKit

/// A relay key. Only its SHA-256 is stored; the key itself is printed once by
/// `Run issue-key` and pasted into the phone.
public final class RelayKeyModel: Model, @unchecked Sendable {
    public static let schema = "relay_keys"

    @ID(key: .id) public var id: UUID?
    @Field(key: "label") public var label: String
    @Field(key: "hash") public var hash: String
    @Field(key: "created_at") public var createdAt: Date
    @OptionalField(key: "last_used_at") public var lastUsedAt: Date?
    @OptionalField(key: "revoked_at") public var revokedAt: Date?

    public init() {}

    public init(label: String, hash: String, createdAt: Date) {
        self.label = label
        self.hash = hash
        self.createdAt = createdAt
    }
}

/// A JSON blob under a name: the calendar cache, the mail snapshot, the brief,
/// the phone's uploaded context. Small, few, replaced whole.
public final class CacheEntryModel: Model, @unchecked Sendable {
    public static let schema = "cache"

    @ID(custom: "key", generatedBy: .user) public var id: String?
    @Field(key: "json") public var json: String
    @Field(key: "updated_at") public var updatedAt: Date

    public init() {}

    public init(key: String, json: String, updatedAt: Date) {
        self.id = key
        self.json = json
        self.updatedAt = updatedAt
    }
}

/// An approved action and what became of it. The id is the phone's idempotency key.
public final class ActionModel: Model, @unchecked Sendable {
    public static let schema = "actions"

    @ID(custom: "id", generatedBy: .user) public var id: String?
    @Field(key: "kind_json") public var kindJSON: String
    @Field(key: "context") public var context: String
    @Field(key: "approved_at") public var approvedAt: Date
    @OptionalField(key: "not_before") public var notBefore: Date?
    @Field(key: "state") public var state: String
    @OptionalField(key: "message") public var message: String?
    @OptionalField(key: "result_json") public var resultJSON: String?
    @Field(key: "attempts") public var attempts: Int
    @Field(key: "created_at") public var createdAt: Date
    @Field(key: "updated_at") public var updatedAt: Date

    public init() {}

    public init(action: ApprovedAction, state: ActionState, now: Date) throws {
        id = action.id
        kindJSON = String(decoding: try HearthJSON.encode(action.kind), as: UTF8.self)
        context = action.context.rawValue
        approvedAt = action.approvedAt
        notBefore = action.notBefore
        self.state = state.rawValue
        attempts = 0
        createdAt = now
        updatedAt = now
    }

    public func kind() throws -> ActionKind {
        try HearthJSON.decode(ActionKind.self, from: Data(kindJSON.utf8))
    }

    public var actionState: ActionState { ActionState(rawValue: state) ?? .failed }

    public func status() throws -> ActionStatus {
        ActionStatus(
            id: id ?? "",
            kind: try kind(),
            state: actionState,
            notBefore: notBefore,
            updatedAt: updatedAt,
            message: message,
            result: resultJSON.flatMap { try? JSONValue.parse($0) }
        )
    }
}

/// When each timed job last ran.
public final class JobRunModel: Model, @unchecked Sendable {
    public static let schema = "job_runs"

    @ID(custom: "name", generatedBy: .user) public var id: String?
    @OptionalField(key: "last_run") public var lastRun: Date?
    @OptionalField(key: "last_success") public var lastSuccess: Date?
    @OptionalField(key: "last_error") public var lastError: String?

    public init() {}

    public init(name: String) {
        id = name
    }
}

/// A phone's APNs device token.
public final class DeviceModel: Model, @unchecked Sendable {
    public static let schema = "devices"

    @ID(custom: "token", generatedBy: .user) public var id: String?
    @Field(key: "environment") public var environment: String
    @Field(key: "created_at") public var createdAt: Date
    @Field(key: "last_seen") public var lastSeen: Date

    public init() {}

    public init(token: String, environment: String, now: Date) {
        id = token
        self.environment = environment
        createdAt = now
        lastSeen = now
    }
}

public struct CreateSchema: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(RelayKeyModel.schema)
            .id()
            .field("label", .string, .required)
            .field("hash", .string, .required)
            .field("created_at", .datetime, .required)
            .field("last_used_at", .datetime)
            .field("revoked_at", .datetime)
            .unique(on: "hash")
            .create()
        try await database.schema(CacheEntryModel.schema)
            .field("key", .string, .identifier(auto: false))
            .field("json", .string, .required)
            .field("updated_at", .datetime, .required)
            .create()
        try await database.schema(ActionModel.schema)
            .field("id", .string, .identifier(auto: false))
            .field("kind_json", .string, .required)
            .field("context", .string, .required)
            .field("approved_at", .datetime, .required)
            .field("not_before", .datetime)
            .field("state", .string, .required)
            .field("message", .string)
            .field("result_json", .string)
            .field("attempts", .int, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()
        try await database.schema(JobRunModel.schema)
            .field("name", .string, .identifier(auto: false))
            .field("last_run", .datetime)
            .field("last_success", .datetime)
            .field("last_error", .string)
            .create()
        try await database.schema(DeviceModel.schema)
            .field("token", .string, .identifier(auto: false))
            .field("environment", .string, .required)
            .field("created_at", .datetime, .required)
            .field("last_seen", .datetime, .required)
            .create()
    }

    public func revert(on database: any Database) async throws {
        for schema in [DeviceModel.schema, JobRunModel.schema, ActionModel.schema, CacheEntryModel.schema, RelayKeyModel.schema] {
            try await database.schema(schema).delete()
        }
    }
}
