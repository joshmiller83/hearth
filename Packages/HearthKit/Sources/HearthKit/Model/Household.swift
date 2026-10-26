import Foundation

/// One Google account gmailkit holds, by its short alias ("team", "josh").
public struct Account: Codable, Hashable, Sendable, Identifiable {
    public var alias: String
    public var email: String
    public var name: String
    public var enabled: Bool
    /// gmailkit has a refresh token for it.
    public var authorized: Bool

    public var id: String { alias }

    public init(alias: String, email: String, name: String = "", enabled: Bool = true, authorized: Bool = true) {
        self.alias = alias
        self.email = email
        self.name = name
        self.enabled = enabled
        self.authorized = authorized
    }
}

/// Who lives here and how their calendars are treated. The relay reads it from a
/// git-ignored file (`deploy/household.json`) and hands it to the phone, so real
/// names and addresses never enter the repository.
public struct Household: Codable, Hashable, Sendable {
    /// The person Hearth works for: "Good morning, Sam."
    public var ownerName: String
    /// The account aliases that are the owner's own (holds and surprise plans go to `primaryAccount`).
    public var ownerAccounts: [String]
    public var primaryAccount: String
    /// The partner the surprise planner plans for, if any.
    public var partnerName: String?
    /// The partner's accounts: their events show only as "<name> is busy: …",
    /// read-only, without details.
    public var partnerAccounts: [String]
    /// Accounts the surprise guard keeps surprise plans off (the partner's, and any
    /// shared ones they read).
    public var guardedAccounts: [String]
    /// The shared Apple calendar new family events land in.
    public var familyCalendar: String
    /// IANA zone everything is shown in.
    public var timeZone: String
    /// "Around Maple Grove".
    public var town: String
    /// For weather alerts (NWS). Optional.
    public var latitude: Double?
    public var longitude: Double?

    public init(
        ownerName: String,
        ownerAccounts: [String],
        primaryAccount: String,
        partnerName: String? = nil,
        partnerAccounts: [String] = [],
        guardedAccounts: [String] = [],
        familyCalendar: String = "Family",
        timeZone: String = "America/New_York",
        town: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.ownerName = ownerName
        self.ownerAccounts = ownerAccounts
        self.primaryAccount = primaryAccount
        self.partnerName = partnerName
        self.partnerAccounts = partnerAccounts
        self.guardedAccounts = guardedAccounts
        self.familyCalendar = familyCalendar
        self.timeZone = timeZone
        self.town = town
        self.latitude = latitude
        self.longitude = longitude
    }

    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? TimeZone(identifier: "America/New_York")! }
    public var fmt: Fmt { Fmt(zone: zone) }

    public func isPartnerAccount(_ alias: String) -> Bool { partnerAccounts.contains(alias) }
    public func isGuarded(_ alias: String) -> Bool { guardedAccounts.contains(alias) || partnerAccounts.contains(alias) }

    /// A household with no partner, for a first run before the relay has answered.
    public static let placeholder = Household(ownerName: "there", ownerAccounts: [], primaryAccount: "")
}
