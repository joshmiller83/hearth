import Foundation
import HearthKit

/// The texts `hearth-messages` exported, as the relay serves them. The relay
/// never opens the Messages database: it reads the helper's files, again only
/// when they change.
public actor ChatStore {
    /// The helper runs every two minutes; quiet for this long, it's stopped.
    public static let staleAfter: TimeInterval = 15 * 60

    let directory: String?
    private var cached: (modified: Date, export: ChatExport)?

    public init(directory: String?) {
        self.directory = directory
    }

    func url(_ name: String) -> URL? {
        directory.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
    }

    /// The latest export, or nil when there's none (or the helper can't read Messages).
    public func export() -> ChatExport? {
        guard let url = url(ChatFiles.export),
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        if let cached, cached.modified == modified { return cached.export }
        guard let data = try? Data(contentsOf: url), let export = try? HearthJSON.decode(ChatExport.self, from: data) else { return nil }
        cached = (modified, export)
        return export
    }

    public func status(now: Date) -> ChatSourceStatus {
        guard let url = url(ChatFiles.status), let data = try? Data(contentsOf: url),
            var status = try? HearthJSON.decode(ChatSourceStatus.self, from: data)
        else { return .notInstalled }
        if let checked = status.checkedAt, now.timeIntervalSince(checked) > Self.staleAfter {
            status.state = .notRunning
            status.message = "Hearth's Messages helper hasn't run since then. Is this Mac logged in?"
        }
        return status
    }

    /// An export only while it's current: what the routes and Ask may use.
    public func current(now: Date) -> ChatExport? {
        status(now: now).state == .ok ? export() : nil
    }
}
