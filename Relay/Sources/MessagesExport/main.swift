// hearth-messages: reads the Mac's Messages database and leaves an export for
// the relay. launchd runs it as the owner every two minutes
// (deploy/install-messages.sh). It needs Full Disk Access; without it, it says
// so in the status file and the phone's Sources screen shows how to grant it.
//
//   hearth-messages --out ~/HearthRelay/data [--db PATH] [--days 60] [--limit 20000]
import ChatReader
import Foundation
import HearthKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

guard let out = option("--out") else {
    FileHandle.standardError.write(Data("usage: hearth-messages --out DIR [--db PATH] [--days 60] [--limit 20000]\n".utf8))
    exit(2)
}
let path = option("--db") ?? ChatDatabase.defaultPath
let days = option("--days").flatMap(Int.init) ?? 60
let limit = option("--limit").flatMap(Int.init) ?? 20_000
let now = Date()
umask(0o077)

/// Skips the work when Messages hasn't written since the last export.
func changedSince(_ last: Date?) -> Bool {
    guard let last else { return true }
    let stamps = [path, path + "-wal"].compactMap {
        (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
    }
    return stamps.isEmpty || stamps.contains { $0 > last }
}

let statusURL = URL(fileURLWithPath: out).appendingPathComponent(ChatFiles.status)
let previous = (try? Data(contentsOf: statusURL)).flatMap { try? HearthJSON.decode(ChatSourceStatus.self, from: $0) }

do {
    try ChatDatabase.checkAccess(path)
    if let previous, previous.state == .ok, !changedSince(previous.exportedAt) {
        var status = previous
        status.checkedAt = now
        try ChatExportWriter.write(status, to: out)
        exit(0)
    }
    let export = try await ChatDatabase.read(path: path, days: days, limit: limit, now: now)
    try ChatExportWriter.write(export, to: out)
    try ChatExportWriter.write(
        ChatSourceStatus(
            state: .ok, checkedAt: now, exportedAt: now, threads: export.threads.count, messages: export.messages.count), to: out)
    print("hearth-messages: \(export.threads.count) conversations, \(export.messages.count) messages")
} catch let failure as ChatDatabase.Failure {
    let state: ChatSourceStatus.State = failure == .noAccess ? .needsAccess : .failed
    try? ChatExportWriter.write(ChatSourceStatus(state: state, checkedAt: now, message: failure.description), to: out)
    FileHandle.standardError.write(Data("hearth-messages: \(failure.description)\n".utf8))
} catch {
    try? ChatExportWriter.write(ChatSourceStatus(state: .failed, checkedAt: now, message: "\(error)"), to: out)
    FileHandle.standardError.write(Data("hearth-messages: \(error)\n".utf8))
}
