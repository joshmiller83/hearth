import Foundation

/// What the share extension leaves for the app: a shared text, link or image,
/// waiting in the App Group until the app reads it with Claude.
public struct SharedItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case text
        case url
        case image
    }

    public var id: String
    public var kind: Kind
    public var createdAt: Date
    public var text: String?
    /// The image file's name beside the item's JSON.
    public var imageFile: String?
    /// Where it came from, if the sharing app said ("Safari", "Facebook").
    public var from: String?

    public init(
        id: String = UUID().uuidString, kind: Kind, createdAt: Date, text: String? = nil, imageFile: String? = nil,
        from: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.text = text
        self.imageFile = imageFile
        self.from = from
    }
}

/// A folder in the App Group: one JSON file per shared item, plus its image.
public struct SharedInbox: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func inAppGroup(_ appGroup: String?) -> SharedInbox {
        let base = AppDatabase.directory(appGroup: appGroup).deletingLastPathComponent()
        return SharedInbox(directory: base.appendingPathComponent("SharedInbox", isDirectory: true))
    }

    /// Saves a shared item (and its image) for the app to pick up.
    public func put(_ item: SharedItem, image: Data? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var item = item
        if let image {
            let name = item.id + ".jpg"
            try image.write(to: directory.appendingPathComponent(name), options: .atomic)
            item.imageFile = name
        }
        let data = try JSONEncoder().encode(item)
        try data.write(to: directory.appendingPathComponent(item.id + ".json"), options: .atomic)
    }

    /// Waiting items, oldest first.
    public func items() -> [SharedItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SharedItem.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func image(for item: SharedItem) -> Data? {
        item.imageFile.flatMap { try? Data(contentsOf: directory.appendingPathComponent($0)) }
    }

    public func remove(_ item: SharedItem) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.id + ".json"))
        if let image = item.imageFile { try? FileManager.default.removeItem(at: directory.appendingPathComponent(image)) }
    }
}
