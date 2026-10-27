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
}

public struct NoPeople: PeopleDirectory {
    public init() {}
    public func find(_ query: String) async throws -> [PersonCard] { [] }
}

/// The fictional household's people.
public struct FixturePeople: PeopleDirectory {
    public init() {}
    public func find(_ query: String) async throws -> [PersonCard] { Fixtures.people.filter { $0.matches(query) } }
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
