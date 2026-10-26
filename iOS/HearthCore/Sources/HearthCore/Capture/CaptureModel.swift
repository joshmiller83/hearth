import Foundation
import HearthKit
import Observation

/// "Snap it, say it, or share it. Nothing lands on a calendar until you say so."
///
/// One capture at a time: Claude reads a note or a photo, the owner answers
/// what Claude asked and fixes what it misread, then adds the result to the
/// Family calendar (and Reminders). Adding can be taken back for 10 seconds.
@MainActor
@Observable
public final class CaptureModel {
    public static let undoSeconds: TimeInterval = 10

    public enum Phase: Equatable, Sendable {
        case idle
        case reading
        case review
        case adding
        /// Added; Undo works until then.
        case added(until: Date)
        case failed(String)
    }

    public struct Session: Equatable, Sendable {
        public var id: String
        public var source: CapturePrompt.Source
        public var text: String?
        /// The scaled-down photo sent to Claude.
        public var image: Data?
        public var reading: CaptureReading?
        /// Entry id → the option the owner picked.
        public var answers: [String: String] = [:]
        /// Entry id → the owner's fixed version.
        public var edits: [String: CaptureEntry] = [:]
        /// Entries the owner took out.
        public var removed: Set<String> = []
        public var calendarId: String?
        public var remind = true
        public var eventIds: [String] = []
        public var reminderIds: [String] = []
    }

    let services: AppServices
    weak var app: AppModel?
    let inbox: SharedInbox?

    public var noteText = ""
    public private(set) var session: Session?
    public private(set) var phase: Phase = .idle
    public private(set) var recent: [CaptureRecord] = []
    public private(set) var shared: [SharedItem] = []
    public private(set) var writableCalendars: [AppleCalendarInfo] = []

    init(services: AppServices, inbox: SharedInbox?) {
        self.services = services
        self.inbox = inbox
        recent = services.database.recentCaptures()
    }

    var now: Date { services.clock.now }
    var household: Household { app?.household ?? .placeholder }

    // MARK: Reading

    /// Reads the quick note.
    public func readNote() async {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session = Session(id: UUID().uuidString, source: .note, text: text)
        await read()
    }

    /// Reads a photo: a flyer, a page of the paper calendar, a screenshot.
    public func read(photo: Data, source: CapturePrompt.Source, caption: String? = nil) async {
        guard let image = ImageShrinker.jpeg(photo) else {
            phase = .failed("That photo couldn't be opened.")
            return
        }
        session = Session(id: UUID().uuidString, source: source, text: caption, image: image)
        await read()
    }

    /// Reads something the share extension left.
    public func read(shared item: SharedItem) async {
        let image = inbox?.image(for: item).flatMap { ImageShrinker.jpeg($0) }
        session = Session(id: UUID().uuidString, source: .shared, text: item.text, image: image)
        await read()
        if case .review = phase {
            inbox?.remove(item)
            refreshShared()
        }
    }

    func read() async {
        guard var current = session else { return }
        phase = .reading
        await loadCalendars()
        guard let claude = app?.claude else {
            phase = .failed(ClaudeError.noKey.description)
            return
        }
        let request = CapturePrompt.request(
            source: current.source, text: current.text,
            image: current.image.map { CapturePrompt.Image(data: $0) }, now: now, household: household)
        do {
            let (reading, _) = try await claude.structured(request, as: CaptureReading.self)
            guard session?.id == current.id else { return }  // started over meanwhile
            current.reading = reading
            current.calendarId = familyCalendarId
            session = current
            phase = reading.entries.isEmpty ? .failed("Claude didn't find anything to add in that.") : .review
            record(current, status: .read)
        } catch {
            guard session?.id == current.id else { return }
            phase = .failed((error as? ClaudeError)?.description ?? String(describing: error))
            record(current, status: .failed)
        }
    }

    /// Opens a reading for review without asking Claude: a recent capture again, or a test.
    public func load(_ reading: CaptureReading, source: CapturePrompt.Source, id: String = UUID().uuidString) async {
        await loadCalendars()
        var current = Session(id: id, source: source)
        current.reading = reading
        current.calendarId = familyCalendarId
        session = current
        phase = .review
    }

    // MARK: Review

    /// Original entries sorted into needs-a-look, new and already-on-a-calendar.
    public var triage: CaptureTriage? {
        guard let entries = session?.reading?.entries, let app else { return nil }
        return CaptureMatcher.triage(entries.map { session?.edits[$0.id] ?? $0 }, agenda: app.plans.agenda)
    }

    /// What "Add" will add: new entries and answered questions, edits applied,
    /// skips and removals left out, matches never duplicated.
    public var toAdd: [CaptureEntry] {
        guard let session, let triage else { return [] }
        let answered = triage.needsLook.compactMap { entry -> CaptureEntry? in
            guard let choice = session.answers[entry.id], let option = entry.question?.options.first(where: { $0.id == choice })
            else { return nil }
            return entry.answering(option)
        }
        return (triage.new + answered).filter { !session.removed.contains($0.id) }
    }

    /// Questions still without an answer.
    public var openQuestions: Int {
        guard let session, let triage else { return 0 }
        return triage.needsLook.filter { session.answers[$0.id] == nil && !session.removed.contains($0.id) }.count
    }

    public func answer(_ entryId: String, with optionId: String) {
        session?.answers[entryId] = optionId
    }

    public func edit(_ entry: CaptureEntry) {
        session?.edits[entry.id] = entry
    }

    public func remove(_ entryId: String) {
        session?.removed.insert(entryId)
    }

    public func setRemind(_ on: Bool) {
        session?.remind = on
    }

    public func setCalendar(_ id: String) {
        session?.calendarId = id
    }

    /// "Add to Family", "Add 4 to Family", "Add reminder".
    public var addLabel: String {
        let entries = toAdd
        let name = calendarName
        if case .added = phase { return entries.count > 1 ? "Added \(entries.count) to \(name)" : "Added to \(name)" }
        if entries.allSatisfy({ $0.kind == .reminder }) && !entries.isEmpty {
            return entries.count > 1 ? "Add \(entries.count) reminders" : "Add reminder"
        }
        return entries.count > 1 ? "Add \(entries.count) to \(name)" : "Add to \(name)"
    }

    public var calendarName: String {
        writableCalendars.first { $0.id == session?.calendarId }?.title ?? household.familyCalendar
    }

    /// The default alarm for an entry: the evening before at 7 PM when it's at
    /// least a day off, otherwise an hour before; nil if that's already past.
    public func alarm(for entry: CaptureEntry) -> Date? {
        guard let interval = entry.interval(in: household.zone) else { return nil }
        let calendar = household.fmt.calendar
        if interval.start.timeIntervalSince(now) >= 20 * 3600,
            let dayBefore = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: interval.start)),
            let evening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: dayBefore), evening > now
        {
            return evening
        }
        let hourBefore = interval.start.addingTimeInterval(-3600)
        return hourBefore > now ? hourBefore : nil
    }

    /// "Remind us Friday at 7 PM", "Remind us an hour before", "Remind us the evening before".
    public var remindLabel: String {
        let alarms = toAdd.filter { $0.kind != .reminder }.compactMap(alarm(for:))
        guard alarms.count == 1, let alarm = alarms.first else { return "Remind us the evening before" }
        let fmt = household.fmt
        if let start = toAdd.first?.interval(in: household.zone)?.start, start.timeIntervalSince(alarm) <= 3600 {
            return "Remind us an hour before"
        }
        return "Remind us \(Fmt.weekdaysLong[fmt.calendar.component(.weekday, from: alarm) - 1]) at \(fmt.time(alarm, compact: true))"
    }

    // MARK: Adding

    public func add() async {
        guard var current = session, phase == .review else { return }
        let entries = toAdd
        guard !entries.isEmpty else { return }
        phase = .adding
        let zone = household.zone
        var events: [EventDraft] = []
        var reminders: [ReminderDraft] = []
        for entry in entries {
            guard let interval = entry.interval(in: zone) else { continue }
            let notes = Self.notes(for: entry)
            if entry.kind == .reminder {
                reminders.append(ReminderDraft(title: entry.title, due: interval.start, notes: notes, repeats: entry.repeats))
            } else {
                events.append(
                    EventDraft(
                        title: entry.title, start: interval.start, end: interval.end, isAllDay: entry.isAllDay,
                        location: entry.location, notes: notes, tentative: entry.tentative,
                        alarm: current.remind ? alarm(for: entry) : nil,
                        repeats: entry.repeats))
            }
        }
        do {
            if !events.isEmpty {
                if services.calendar.access() != .full { _ = await services.calendar.requestAccess() }
                guard let calendarId = current.calendarId ?? familyCalendarId else {
                    throw CalendarWriteError.noCalendar(household.familyCalendar)
                }
                current.eventIds = try await services.calendar.add(events, to: calendarId)
            }
            if !reminders.isEmpty {
                if services.calendar.remindersAccess() != .full { _ = await services.calendar.requestRemindersAccess() }
                current.reminderIds = try await services.calendar.add(reminders)
            }
        } catch {
            // Don't leave half a capture behind.
            try? await services.calendar.removeEvents(current.eventIds)
            phase = .failed((error as? CalendarWriteError)?.description ?? String(describing: error))
            return
        }
        session = current
        let until = now.addingTimeInterval(Self.undoSeconds)
        phase = .added(until: until)
        record(current, status: .added)
        noteText = ""
        await app?.plans.refreshApple()
        app?.plans.publishWidgets()
    }

    /// Takes the capture back off the calendar, within the undo window.
    public func undo() async {
        guard case .added(let until) = phase, now <= until, var current = session else { return }
        try? await services.calendar.removeEvents(current.eventIds)
        try? await services.calendar.removeReminders(current.reminderIds)
        current.eventIds = []
        current.reminderIds = []
        session = current
        phase = .review
        record(current, status: .undone)
        await app?.plans.refreshApple()
    }

    /// Whether Undo still works.
    public var canUndo: Bool {
        if case .added(let until) = phase { return now <= until }
        return false
    }

    public func startOver() {
        session = nil
        phase = .idle
    }

    // MARK: Lists

    public func refreshShared() {
        shared = inbox?.items() ?? []
    }

    public func reloadRecent() {
        recent = services.database.recentCaptures()
    }

    /// The line under a recent capture.
    public func recentDetail(_ record: CaptureRecord) -> String {
        let fmt = household.fmt
        let reading = record.decodedReading
        switch record.status {
        case .failed: return "Couldn't read it"
        case .undone: return "Taken back"
        case .added:
            let entries = reading?.entries ?? []
            if entries.count == 1, let entry = entries.first, let start = entry.interval(in: household.zone)?.start {
                return entry.kind == .reminder
                    ? "Reminder set · \(fmt.weekday(start)) \(fmt.time(start))" : "Added · \(fmt.shortDay(start))"
            }
            return "Added \(entries.count) entries"
        case .read:
            let open = reading?.entries.filter { $0.question != nil }.count ?? 0
            if open > 0 { return "\(open) entr\(open == 1 ? "y" : "ies") waiting on you" }
            return "Read \(fmt.relative(record.createdAt, now: now)) · ready to add"
        }
    }

    /// "Craft fair flyer", "Fridge calendar, November", "“call plumber tue am”".
    public func recentTitle(_ record: CaptureRecord) -> String {
        let reading = record.decodedReading
        let first = reading?.entries.first
        switch CapturePrompt.Source(rawValue: record.source) {
        case .note: return "“\(record.summary)”"
        case .flyer: return (first?.title ?? "A") + " flyer"
        case .paperCalendar:
            let month = first.flatMap { RFC3339.parse($0.date, zone: household.zone)?.date }
                .map { Fmt.monthsLong[household.fmt.calendar.component(.month, from: $0) - 1] }
            return "Fridge calendar" + (month.map { ", \($0)" } ?? "")
        case .screenshot: return "Screenshot · " + (first?.title ?? "")
        default: return first?.title ?? record.summary
        }
    }

    // MARK: Plumbing

    func loadCalendars() async {
        writableCalendars = await services.calendar.calendars().filter { $0.allowsModifications && !$0.isBirthdays && !$0.isSubscribed }
    }

    /// The household's family calendar on this phone, by name.
    var familyCalendarId: String? {
        let name = household.familyCalendar.lowercased()
        return writableCalendars.first { $0.title.lowercased() == name }?.id
    }

    static func notes(for entry: CaptureEntry) -> String? {
        var parts: [String] = []
        if let notes = entry.notes, !notes.isEmpty { parts.append(notes) }
        if let cost = entry.cost, !cost.isEmpty { parts.append("Cost: \(cost)") }
        if !entry.source.isEmpty { parts.append("From Hearth: “\(entry.source)”") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func record(_ session: Session, status: CaptureRecord.Status) {
        var record =
            services.database.capture(id: session.id)
            ?? CaptureRecord(
                id: session.id, source: session.source.rawValue, createdAt: now, status: status,
                summary: session.source == .note ? (session.text ?? "") : (session.reading?.summary ?? ""),
                reading: session.reading, thumbnail: session.image.flatMap(ImageShrinker.thumbnail))
        record.status = status
        record.updatedAt = now
        record.eventIds = session.eventIds
        record.reminderIds = session.reminderIds
        if let reading = session.reading { record.reading = try? HearthJSON.encode(reading) }
        try? services.database.save(record)
        reloadRecent()
    }
}
