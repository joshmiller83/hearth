import AppKit
import Foundation
import HearthKit
import HearthKitTestSupport

// Live checks of the capture prompt. Needs ANTHROPIC_API_KEY. Writes each raw
// reading to evals/out/ (git-ignored) and prints a pass/fail line per case.

struct Case {
    var name: String
    var source: CapturePrompt.Source
    var text: String?
    var image: Data?
    var check: (CaptureReading) -> [String]
}

func entry(_ reading: CaptureReading, titled words: String...) -> CaptureEntry? {
    reading.entries.first { e in words.allSatisfy { e.title.lowercased().contains($0) } }
}

/// Draws lines of text on a page, like a flyer or a calendar, and returns a JPEG.
func draw(_ lines: [(String, CGFloat, Bool)], size: CGSize = CGSize(width: 900, height: 1200)) -> Data {
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.9, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    var y = size.height - 80
    for (text, fontSize, bold) in lines {
        let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont(name: "Noteworthy-Light", size: fontSize) ?? .systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)]
        let string = NSAttributedString(string: text, attributes: attributes)
        let width = string.size().width
        string.draw(at: NSPoint(x: (size.width - width) / 2, y: y))
        y -= fontSize * 1.6
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
}

let cases: [Case] = [
    Case(name: "note: partner's dentist", source: .note, text: "dentist for robin thurs 3pm") { r in
        guard let e = entry(r, titled: "dentist") else { return ["no dentist entry"] }
        var problems: [String] = []
        if !e.title.lowercased().contains("robin") { problems.append("title should name Robin: \(e.title)") }
        if e.date != "2026-10-29" { problems.append("date \(e.date), wanted 2026-10-29") }
        if e.startTime != "15:00" { problems.append("start \(e.startTime ?? "nil"), wanted 15:00") }
        if e.guesses.isEmpty { problems.append("no guess flagged for the missing end time") }
        return problems
    },
    Case(name: "note: a reminder", source: .note, text: "call plumber tue am") { r in
        guard let e = r.entries.first else { return ["nothing read"] }
        var problems: [String] = []
        if e.kind != .reminder { problems.append("kind \(e.kind), wanted reminder") }
        if e.date != "2026-10-27" { problems.append("date \(e.date), wanted 2026-10-27") }
        if e.startTime != "08:00" { problems.append("time \(e.startTime ?? "nil"), wanted 08:00") }
        return problems
    },
    Case(name: "note: a weekly practice", source: .note, text: "soccer practice every tuesday 5:30-7 starting nov 3") { r in
        guard let e = entry(r, titled: "soccer") else { return ["no soccer entry"] }
        var problems: [String] = []
        if e.repeats?.frequency != .weekly { problems.append("doesn't repeat weekly") }
        if e.date != "2026-11-03" { problems.append("date \(e.date), wanted 2026-11-03") }
        if e.startTime != "17:30" || e.endTime != "19:00" { problems.append("times \(e.startTime ?? "-")–\(e.endTime ?? "-")") }
        return problems
    },
    Case(name: "note: a birthday", source: .note, text: "jordan's bday nov 12") { r in
        guard let e = r.entries.first else { return ["nothing read"] }
        var problems: [String] = []
        if e.kind != .birthday { problems.append("kind \(e.kind), wanted birthday") }
        if !e.isAllDay { problems.append("should be all day") }
        if e.repeats?.frequency != .yearly { problems.append("should repeat yearly") }
        return problems
    },
    Case(name: "flyer: craft fair", source: .flyer, image: draw([
        ("COMMUNITY CENTER", 34, true), ("Fall Craft Fair", 72, true), ("Saturday, Nov. 7", 44, true), ("10 AM – 3 PM", 44, true),
        ("Main gym · Free admission", 32, false), ("Handmade gifts · Bake sale · Live music", 28, false), ("Vendor tables: 717-555-0134", 26, false),
    ])) { r in
        guard let e = entry(r, titled: "craft") else { return ["no craft fair entry"] }
        var problems: [String] = []
        if e.date != "2026-11-07" { problems.append("date \(e.date), wanted 2026-11-07") }
        if e.startTime != "10:00" || e.endTime != "15:00" { problems.append("times \(e.startTime ?? "-")–\(e.endTime ?? "-")") }
        if e.cost?.lowercased().contains("free") != true { problems.append("cost \(e.cost ?? "nil"), wanted free") }
        if r.entries.count != 1 { problems.append("\(r.entries.count) entries, wanted 1 (ads and slogans aren't events)") }
        return problems
    },
    Case(name: "paper calendar: November page", source: .paperCalendar, image: draw([
        ("NOVEMBER", 48, true), ("Sun 1 — greeter 9:30", 36, false), ("Thu 5 — trash · Ben 12", 36, false),
        ("Tue 10 — Dr Ahn 3:30?", 36, false), ("Thu 12 — trash", 36, false), ("Fri 13 — Robin girls nt", 36, false),
    ])) { r in
        var problems: [String] = []
        let trash = r.entries.filter { $0.title.lowercased().contains("trash") }
        if trash.count != 1 || trash.first?.repeats?.frequency != .weekly { problems.append("trash should be one weekly entry, got \(trash.count)") }
        if let ahn = entry(r, titled: "ahn") {
            if !ahn.tentative { problems.append("Dr Ahn should be tentative") }
            if ahn.question == nil { problems.append("Dr Ahn should ask whose it is") }
        } else {
            problems.append("no Dr Ahn entry")
        }
        if let ben = entry(r, titled: "ben"), ben.startTime != "12:00" { problems.append("Ben read at \(ben.startTime ?? "nil"), wanted noon") }
        return problems
    },
]

guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
    print("Set ANTHROPIC_API_KEY to run the live prompt checks (they cost a few cents).")
    exit(2)
}
let client = ClaudeClient(apiKey: key, transport: URLSessionTransport())
let out = URL(fileURLWithPath: "evals/out", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var failures = 0
var dollars = 0.0
for test in cases {
    let request = CapturePrompt.request(
        source: test.source, text: test.text, image: test.image.map { CapturePrompt.Image(data: $0) },
        now: Fixtures.now, household: Fixtures.household)
    do {
        let (reading, response) = try await client.structured(request, as: CaptureReading.self)
        dollars += response.usage.dollars(model: .opus)
        try HearthJSON.encoder(pretty: true).encode(reading)
            .write(to: out.appendingPathComponent(test.name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ":", with: "") + ".json"))
        let problems = test.check(reading)
        if problems.isEmpty {
            print("✓ \(test.name)")
        } else {
            failures += 1
            print("✗ \(test.name): " + problems.joined(separator: "; "))
        }
    } catch {
        failures += 1
        print("✗ \(test.name): \(error)")
    }
}
print(String(format: "%d of %d passed · about $%.3f", cases.count - failures, cases.count, dollars))
exit(failures == 0 ? 0 : 1)
