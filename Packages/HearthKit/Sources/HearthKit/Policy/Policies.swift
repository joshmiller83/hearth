import Foundation

/// "Ask before acting": nothing writes to mail or calendars without the owner's
/// tap. The relay checks every action against this before it runs.
public enum ApprovalPolicy {
    /// An approval older than this is stale (a replayed or forgotten request).
    public static let maxAge: TimeInterval = 24 * 3600

    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case missingKey
        case approvalInFuture
        case approvalTooOld
        case notBeforeTooFar

        public var description: String {
            switch self {
            case .missingKey: "The action has no id, so it can't be run safely."
            case .approvalInFuture: "The approval time is in the future."
            case .approvalTooOld: "That approval is more than a day old. Approve it again."
            case .notBeforeTooFar: "Scheduled actions can be at most 30 days out."
            }
        }
    }

    public static func check(_ action: ApprovedAction, now: Date) -> Refusal? {
        if action.id.trimmingCharacters(in: .whitespaces).isEmpty { return .missingKey }
        if action.approvedAt > now.addingTimeInterval(5 * 60) { return .approvalInFuture }
        if now.timeIntervalSince(action.approvedAt) > maxAge, action.notBefore == nil { return .approvalTooOld }
        if let notBefore = action.notBefore, notBefore.timeIntervalSince(action.approvedAt) > 30 * 86400 { return .notBeforeTooFar }
        return nil
    }
}

/// "Plans for Robin stay off their accounts and the shared Family calendar until
/// you reveal them." Surprise plans may only touch the owner's own accounts.
public enum SurpriseGuard {
    public static func refusal(for action: ApprovedAction, household: Household, guardOn: Bool) -> String? {
        guard guardOn, action.context == .surprise else { return nil }
        let account = action.kind.account
        if household.isGuarded(account) || !household.ownerAccounts.contains(account) {
            let name = household.partnerName ?? "your partner"
            return "The surprise guard keeps plans for \(name) off \(account). Hold it on \(household.primaryAccount) instead."
        }
        if case .rsvp = action.kind {
            return "The surprise guard doesn't answer invites for a surprise plan."
        }
        return nil
    }
}

/// "Quiet hours, 9 PM–7 AM. Family and anything urgent still get through."
public struct QuietHours: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var startHour: Int
    public var endHour: Int

    public init(enabled: Bool = true, startHour: Int = 21, endHour: Int = 7) {
        self.enabled = enabled
        self.startHour = startHour
        self.endHour = endHour
    }

    public func isQuiet(at date: Date, zone: TimeZone) -> Bool {
        guard enabled else { return false }
        let hour = RFC3339.calendar(zone).component(.hour, from: date)
        return startHour > endHour ? (hour >= startHour || hour < endHour) : (hour >= startHour && hour < endHour)
    }

    /// When a held notification may go out: the end of the current quiet stretch.
    public func nextAllowed(after date: Date, zone: TimeZone) -> Date {
        guard isQuiet(at: date, zone: zone) else { return date }
        let calendar = RFC3339.calendar(zone)
        var day = calendar.startOfDay(for: date)
        if calendar.component(.hour, from: date) >= endHour, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            day = next
        }
        return calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: day) ?? date
    }

    /// Family and urgent pushes always go; the rest wait for morning.
    public func shouldDeliver(_ urgency: PushUrgency, at date: Date, zone: TimeZone) -> Bool {
        urgency != .normal || !isQuiet(at: date, zone: zone)
    }
}

public enum PushUrgency: String, Codable, Hashable, Sendable {
    case normal
    case family
    case urgent
}

/// The owner's switches on the Sources screen. The phone keeps them and uploads
/// them with its context so the relay's jobs follow them too.
public struct HouseRules: Codable, Hashable, Sendable {
    public var askBeforeActing: Bool
    public var surpriseGuard: Bool
    public var quietHours: QuietHours
    public var morningBrief: Bool
    public var briefHour: Int
    public var briefMinute: Int

    public init(
        askBeforeActing: Bool = true, surpriseGuard: Bool = true, quietHours: QuietHours = QuietHours(),
        morningBrief: Bool = true, briefHour: Int = 6, briefMinute: Int = 30
    ) {
        self.askBeforeActing = askBeforeActing
        self.surpriseGuard = surpriseGuard
        self.quietHours = quietHours
        self.morningBrief = morningBrief
        self.briefHour = briefHour
        self.briefMinute = briefMinute
    }
}
