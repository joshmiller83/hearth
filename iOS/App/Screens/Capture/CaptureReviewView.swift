import HearthCore
import HearthKit
import SwiftUI

/// What Claude read from a photo (or a shared item): the questions it has, the
/// new entries, what's already on a calendar, then where it all goes.
struct CaptureReviewView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: CaptureEntry?

    var body: some View {
        let capture = app.capture
        ScreenScroll {
            if let session = capture.session {
                header(session)
                switch capture.phase {
                case .reading:
                    readingCard
                case .failed(let message):
                    Notice(text: message)
                    Button("Start over") { capture.startOver() }.buttonStyle(.pill(.secondary))
                default:
                    if let triage = capture.triage {
                        if !triage.needsLook.isEmpty { needsLook(triage.needsLook, session: session) }
                        if !triage.new.isEmpty { newEntries(triage.new, session: session) }
                        if !triage.alreadyOn.isEmpty { alreadyOn(triage.alreadyOn) }
                        whereItGoes(capture)
                    }
                }
            }
        }
        .navigationTitle("Add to Hearth")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { entry in
            EntryEditor(entry: entry) { capture.edit($0) }
        }
    }

    func header(_ session: CaptureModel.Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sourceLine(session.source)).eyebrow()
            if let data = session.image, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
                    .accessibilityLabel("Your photo")
            } else if let text = session.text {
                Text("“\(text)”").font(.hBody).foregroundStyle(Theme.inkSoft)
            }
            if let summary = session.reading?.summary {
                Text(summary).font(.hMeta).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 4)
    }

    func sourceLine(_ source: CapturePrompt.Source) -> String {
        switch source {
        case .flyer: "From your photo · just now"
        case .paperCalendar: "From your photo · paper calendar"
        case .screenshot: "From a screenshot"
        case .shared: "Shared with Hearth"
        case .note: "From your note"
        }
    }

    var readingCard: some View {
        Card {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude is reading it").font(.hRowTitle).foregroundStyle(Theme.ink)
                    Text("Handwriting takes a little longer.").font(.hMeta).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    func needsLook(_ entries: [CaptureEntry], session: CaptureModel.Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Needs a look · \(entries.count)").eyebrow().padding(.horizontal, 4)
            ForEach(entries) { entry in
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.source).font(.custom(Typeface.semibold, size: 15, relativeTo: .body)).italic()
                                .foregroundStyle(Theme.emberSoft)
                            Spacer()
                            Text(readingLine(entry)).font(.hMeta).foregroundStyle(Theme.muted)
                        }
                        if let question = entry.question {
                            Text(question.text).font(.hBody).foregroundStyle(Theme.inkSoft)
                            HStack(spacing: 6) {
                                ForEach(question.options) { option in
                                    let picked = session.answers[entry.id] == option.id
                                    Button(option.label) { app.capture.answer(entry.id, with: option.id) }
                                        .font(.hLabel)
                                        .foregroundStyle(picked ? Theme.bg : Theme.ink)
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                        .background(picked ? Theme.ink : Theme.chip, in: Capsule())
                                        .buttonStyle(.plain)
                                        .accessibilityAddTraits(picked ? .isSelected : [])
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func newEntries(_ entries: [CaptureEntry], session: CaptureModel.Session) -> some View {
        let kept = entries.filter { !session.removed.contains($0.id) }
        let events = kept.filter { $0.kind != .reminder }.count
        return ListCard(title: entries.count == 1 ? "Claude read" : "New · \(kept.count) entries, \(events) events") {
            if entries.count == 1, let entry = entries.first {
                fieldRows(session.edits[entry.id] ?? entry)
            } else {
                ForEach(entries) { entry in
                    let removed = session.removed.contains(entry.id)
                    HStack(spacing: 12) {
                        Button {
                            editing = session.edits[entry.id] ?? entry
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entryTitle(entry)).font(.hRowTitle).foregroundStyle(removed ? Theme.muted : Theme.ink)
                                    .strikethrough(removed)
                                Text(([readingLine(entry)] + entry.guesses).joined(separator: ". "))
                                    .font(.hMeta).foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !removed {
                            Button {
                                app.capture.remove(entry.id)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Leave out \(entry.title)")
                        }
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { Hairline() }
                }
            }
        }
    }

    /// The flyer's one entry, line by line; tap a line to fix it.
    func fieldRows(_ entry: CaptureEntry) -> some View {
        VStack(spacing: 0) {
            field("Event", entry.title, entry)
            field("When", readingLine(entry), entry)
            if let location = entry.location { field("Where", location, entry) }
            if let cost = entry.cost { field("Cost", cost, entry) }
            if !entry.guesses.isEmpty {
                Text(entry.guesses.joined(separator: ". ")).font(.custom(Typeface.semibold, size: 12, relativeTo: .caption))
                    .foregroundStyle(Theme.emberSoft).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        }
    }

    func field(_ label: String, _ value: String, _ entry: CaptureEntry) -> some View {
        Button {
            editing = entry
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(.custom(Typeface.bold, size: 12, relativeTo: .caption)).foregroundStyle(Theme.muted)
                    .frame(width: 56, alignment: .leading)
                Text(value).font(.hRowTitle).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Hairline() }
        .accessibilityHint("Tap to fix it")
    }

    func alreadyOn(_ matches: [CaptureTriage.Match]) -> some View {
        ListCard(title: "Already on a calendar · \(matches.count)") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(matches) { match in
                    Text("\(match.entry.title) · \(match.event.source.label)").font(.hMeta).foregroundStyle(Theme.inkSoft)
                }
                Text("Matched and merged, not duplicated.").font(.hMeta).foregroundStyle(Theme.muted).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Hairline() }
        }
    }

    func whereItGoes(_ capture: CaptureModel) -> some View {
        let session = capture.session
        return VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    Menu {
                        ForEach(capture.writableCalendars) { calendar in
                            Button(calendar.title) { capture.setCalendar(calendar.id) }
                        }
                    } label: {
                        HStack {
                            Text("Calendar").font(.custom(Typeface.bold, size: 12, relativeTo: .caption)).foregroundStyle(Theme.muted)
                            Spacer()
                            Text("\(capture.calendarName) · iCloud").font(.hRowTitle).foregroundStyle(Theme.ink)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        .padding(.vertical, 10)
                    }
                    Toggle(
                        isOn: Binding(
                            get: { session?.remind ?? true }, set: { value in MainActor.assumeIsolated { capture.setRemind(value) } })
                    ) {
                        Text(capture.remindLabel).font(.hRowTitle).foregroundStyle(Theme.ink)
                    }
                    .tint(Theme.ember)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { Hairline() }
                }
            }
            Group {
                switch capture.phase {
                case .added:
                    UndoButton(label: capture.addLabel)
                case .adding:
                    ProgressView().frame(maxWidth: .infinity, minHeight: Theme.touch)
                default:
                    Button(capture.addLabel) { Task { await capture.add() } }
                        .buttonStyle(.pill(.primary))
                        .disabled(capture.toAdd.isEmpty)
                }
            }
            Text(footnote(capture)).font(.hMeta).foregroundStyle(Theme.muted).padding(.horizontal, 4)
        }
    }

    func footnote(_ capture: CaptureModel) -> String {
        if case .added = capture.phase { return "Added to \(capture.calendarName). Undo works for 10 seconds." }
        let open = capture.openQuestions
        if open > 0 { return open == 1 ? "1 entry still needs a look." : "\(open) entries still need a look." }
        if capture.toAdd.contains(where: \.tentative) { return "Tentative where you wrote a question mark." }
        return "Nothing goes on the calendar until you tap Add."
    }

    func readingLine(_ entry: CaptureEntry) -> String {
        let fmt = app.household.fmt
        guard let interval = entry.interval(in: app.household.zone) else { return entry.date }
        if entry.kind == .reminder { return "\(fmt.shortDay(interval.start)) · reminder at \(fmt.time(interval.start))" }
        var line = fmt.when(interval.start, interval.end, allDay: entry.isAllDay)
        if let repeats = entry.repeats {
            line += " · every \(repeats.frequency == .weekly ? fmt.weekday(interval.start) : repeats.frequency.rawValue)"
        }
        return line
    }

    func entryTitle(_ entry: CaptureEntry) -> String {
        entry.tentative ? entry.title + " (tentative)" : entry.title
    }
}

/// Fix what Claude misread.
struct EntryEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let entry: CaptureEntry
    let save: (CaptureEntry) -> Void
    @State private var title = ""
    @State private var location = ""
    @State private var day = Date()
    @State private var start = Date()
    @State private var end = Date()
    @State private var allDay = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                Toggle("All day", isOn: $allDay)
                DatePicker("Day", selection: $day, displayedComponents: .date)
                if !allDay {
                    DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
                }
                TextField("Where", text: $location)
            }
            .environment(\.timeZone, app.household.zone)
            .navigationTitle("Fix it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(edited)
                        dismiss()
                    }
                }
            }
            .onAppear(perform: load)
        }
        .preferredColorScheme(.dark)
    }

    func load() {
        title = entry.title
        location = entry.location ?? ""
        allDay = entry.isAllDay
        if let interval = entry.interval(in: app.household.zone) {
            day = interval.start
            start = interval.start
            end = interval.end
        }
    }

    var edited: CaptureEntry {
        var e = entry
        let zone = app.household.zone
        let calendar = app.household.fmt.calendar
        e.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? entry.title : title
        e.location = location.isEmpty ? nil : location
        e.date = RFC3339.day(day, zone: zone)
        if allDay {
            e.startTime = nil
            e.endTime = nil
        } else {
            func hhmm(_ date: Date) -> String {
                let c = calendar.dateComponents([.hour, .minute], from: date)
                return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            }
            e.startTime = hhmm(start)
            e.endTime = hhmm(end)
        }
        e.guesses = []
        return e
    }
}
