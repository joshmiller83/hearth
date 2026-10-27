import Foundation
import HearthKit
import HearthKitTestSupport

#if canImport(Contacts)
import Contacts
#endif

public enum PeopleError: Error, Equatable, Sendable, CustomStringConvertible {
    case noAccess

    public var description: String {
        switch self {
        case .noAccess: "Hearth can't read your contacts. Allow it in Settings › Hearth › Contacts."
        }
    }
}

/// The owner's contacts, as Ask's people_get reads them.
public protocol PeopleDirectory: Sendable {
    func find(_ query: String) async throws -> [PersonCard]
    /// Contacts' names for phone numbers and emails, keyed by `ChatHandle.normalize`; unknown ones are left out.
    func names(for handles: [String]) async -> [String: String]
    /// Someone's phone numbers and emails (normalized), for finding their texts.
    func handles(for query: String) async -> [String]
}

extension PeopleDirectory {
    public func names(for handles: [String]) async -> [String: String] { [:] }
    public func handles(for query: String) async -> [String] { [] }
}

public struct NoPeople: PeopleDirectory {
    public init() {}
    public func find(_ query: String) async throws -> [PersonCard] { [] }
}

/// The fictional household's people.
public struct FixturePeople: PeopleDirectory {
    public init() {}
    public func find(_ query: String) async throws -> [PersonCard] { Fixtures.people.filter { $0.matches(query) } }

    public func names(for handles: [String]) async -> [String: String] {
        Fixtures.chatNames.filter { handles.map(ChatHandle.normalize).contains($0.key) }
    }

    public func handles(for query: String) async -> [String] {
        let names = Set(Fixtures.people.filter { $0.matches(query) }.map(\.name))
        return Fixtures.chatNames.filter { names.contains($0.value) }.map(\.key).sorted()
    }
}

#if canImport(Contacts)
/// The Contacts app, read when Ask asks (the first time, iOS asks the owner).
/// Contact notes aren't read: that needs an entitlement Apple grants case by case.
public struct ContactsDirectory: PeopleDirectory {
    public init() {}

    public func find(_ query: String) async throws -> [PersonCard] {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            guard (try? await store.requestAccess(for: .contacts)) == true else { throw PeopleError.noAccess }
        case .denied, .restricted:
            throw PeopleError.noAccess
        default:
            break
        }
        let keys: [any CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as NSString, CNContactBirthdayKey as NSString, CNContactDatesKey as NSString,
            CNContactPostalAddressesKey as NSString, CNContactEmailAddressesKey as NSString,
            CNContactPhoneNumbersKey as NSString,
        ]
        func named(_ name: String) -> [CNContact] {
            (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
        }
        var contacts = named(query)
        var relation: String?
        if contacts.isEmpty, let label = Self.relationLabel(query) {
            // "Mom": a card (usually the owner's own) names who their mother is.
            var name: String?
            let request = CNContactFetchRequest(keysToFetch: [CNContactRelationsKey as NSString])
            try? store.enumerateContacts(with: request) { contact, stop in
                if let match = contact.contactRelations.first(where: { $0.label == label }) {
                    name = match.value.name
                    stop.pointee = true
                }
            }
            if let name {
                relation = CNLabeledValue<CNContactRelation>.localizedString(forLabel: label)
                contacts = named(name)
            }
        }
        return contacts.prefix(3).map { Self.card($0, relation: relation) }
    }

    /// Only when the owner already allowed Contacts: texts never prompt for it.
    var allowed: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        #if os(iOS)
        return status == .authorized || status == .limited
        #else
        return status == .authorized
        #endif
    }

    public func names(for handles: [String]) async -> [String: String] {
        let wanted = Set(handles.map(ChatHandle.normalize))
        guard allowed, !wanted.isEmpty else { return [:] }
        let keys: [any CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as NSString,
            CNContactEmailAddressesKey as NSString, CNContactOrganizationNameKey as NSString,
        ]
        var out: [String: String] = [:]
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, stop in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            guard !name.isEmpty else { return }
            let handles =
                contact.phoneNumbers.map { ChatHandle.normalize($0.value.stringValue) }
                + contact.emailAddresses.map { ChatHandle.normalize($0.value as String) }
            for handle in handles where wanted.contains(handle) && out[handle] == nil { out[handle] = name }
            if out.count == wanted.count { stop.pointee = true }
        }
        return out
    }

    public func handles(for query: String) async -> [String] {
        guard allowed else { return [] }
        let keys: [any CNKeyDescriptor] = [CNContactPhoneNumbersKey as NSString, CNContactEmailAddressesKey as NSString]
        let store = CNContactStore()
        var contacts =
            (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)) ?? []
        if contacts.isEmpty, let label = Self.relationLabel(query) {
            var name: String?
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: [CNContactRelationsKey as NSString])) { contact, stop in
                if let match = contact.contactRelations.first(where: { $0.label == label }) {
                    name = match.value.name
                    stop.pointee = true
                }
            }
            if let name {
                contacts =
                    (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
            }
        }
        return contacts.prefix(3).flatMap { contact in
            contact.phoneNumbers.map { ChatHandle.normalize($0.value.stringValue) }
                + contact.emailAddresses.map { ChatHandle.normalize($0.value as String) }
        }
    }

    static func relationLabel(_ query: String) -> String? {
        switch query.lowercased().trimmingCharacters(in: .whitespaces) {
        case "mom", "mum", "mother", "mama": CNLabelContactRelationMother
        case "dad", "father", "papa": CNLabelContactRelationFather
        case "sister": CNLabelContactRelationSister
        case "brother": CNLabelContactRelationBrother
        case "wife", "husband", "spouse": CNLabelContactRelationSpouse
        case "partner": CNLabelContactRelationPartner
        default: nil
        }
    }

    static func card(_ contact: CNContact, relation: String?) -> PersonCard {
        let anniversary = contact.dates.first { $0.label == CNLabelDateAnniversary }.map { $0.value as DateComponents }
        let city = contact.postalAddresses.first?.value.city ?? ""
        return PersonCard(
            name: CNContactFormatter.string(from: contact, style: .fullName) ?? contact.nickname,
            nickname: contact.nickname.isEmpty ? nil : contact.nickname, relation: relation,
            birthdayMonth: contact.birthday?.month, birthdayDay: contact.birthday?.day, birthdayYear: contact.birthday?.year,
            anniversaryMonth: anniversary?.month, anniversaryDay: anniversary?.day, city: city.isEmpty ? nil : city,
            emails: contact.emailAddresses.prefix(3).map { $0.value as String }, hasPhone: !contact.phoneNumbers.isEmpty)
    }
}
#endif
