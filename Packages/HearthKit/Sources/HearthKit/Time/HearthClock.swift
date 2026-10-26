import Foundation

/// Where "now" comes from. Everything that depends on the time takes one, so
/// tests pin it and move it instead of sleeping.
public protocol HearthClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: HearthClock {
    public init() {}
    public var now: Date { Date() }
}

/// A clock tests set and move.
public final class ManualClock: HearthClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date) {
        current = start
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }

    public func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
