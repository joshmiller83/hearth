import Foundation
import Security

/// Where Hearth keeps its three secrets: the relay's URL, the relay key, and the
/// Claude API key. Pasted once in Sources, kept in the Keychain on this device only.
public protocol SecretStore: Sendable {
    func read(_ name: SecretName) -> String?
    func write(_ value: String?, for name: SecretName) throws
}

public enum SecretName: String, CaseIterable, Sendable {
    case relayURL = "relay-url"
    case relayKey = "relay-key"
    case claudeKey = "claude-key"
}

/// The relay URL and key together, or nothing.
public struct RelayCredentials: Equatable, Sendable {
    public var url: URL
    public var key: String

    public init(url: URL, key: String) {
        self.url = url
        self.key = key
    }

    public static func load(from store: any SecretStore) -> RelayCredentials? {
        guard let text = store.read(.relayURL), let url = URL(string: text), url.scheme?.hasPrefix("http") == true,
            let key = store.read(.relayKey), !key.isEmpty
        else { return nil }
        return RelayCredentials(url: url, key: key)
    }

    /// Accepts "hearth.example.com", "https://hearth.example.com/", or with a path; returns the origin.
    public static func normalize(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var parts = URLComponents(string: trimmed), let host = parts.host, !host.isEmpty else { return nil }
        guard parts.scheme == "https" || host == "localhost" || host == "127.0.0.1" else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }
}

/// Keychain items readable after the first unlock since a reboot, so the StandBy
/// widgets can refresh at night while the phone stays locked. With an access
/// group, the app and its widget extension share them.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "hearth", accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public enum KeychainError: Error, Equatable {
        case status(OSStatus)
    }

    private func query(_ name: SecretName) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name.rawValue,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func read(_ name: SecretName) -> String? {
        var query = self.query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String?, for name: SecretName) throws {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query(name) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(name) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query(name).merging(attributes) { $1 } as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.status(added) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }
}

/// Secrets in memory, for tests and fixture runs.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretName: String]

    public init(_ values: [SecretName: String] = [:]) {
        self.values = values
    }

    public func read(_ name: SecretName) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[name]
    }

    public func write(_ value: String?, for name: SecretName) throws {
        lock.lock()
        defer { lock.unlock() }
        values[name] = value
    }
}

/// `hearth://pair?relay=https://…&key=hrk_…`: what `deploy/pair.sh` puts in its QR code.
/// Opening one never saves anything by itself; the app asks first.
public struct PairLink: Equatable, Sendable {
    public var relay: URL
    public var key: String

    public init?(url: URL) {
        guard url.scheme == "hearth", url.host == "pair",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let relayText = items.first(where: { $0.name == "relay" })?.value,
            let relay = RelayCredentials.normalize(relayText), relay.scheme == "https",
            let key = items.first(where: { $0.name == "key" })?.value, key.hasPrefix("hrk_"), key.count > 20
        else { return nil }
        self.relay = relay
        self.key = key
    }
}
