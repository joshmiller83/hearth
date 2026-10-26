import HearthCore
import HearthKit
import PhotosUI
import SwiftUI

/// Add to Hearth: a quick note, a flyer, a page of the paper calendar, a
/// screenshot, or something shared in. Nothing lands on a calendar until you say so.
struct CaptureView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @FocusState private var noteFocused: Bool
    @State private var showReview = false
    @State private var pickFlyer = false
    @State private var showCamera = false
    @State private var showScanner = false
    @State private var flyerItem: PhotosPickerItem?
    @State private var screenshotItem: PhotosPickerItem?

    var body: some View {
        @Bindable var capture = app.capture
        NavigationStack {
            ScreenScroll {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add to Hearth").font(.hTitle).displayTracking().foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Snap it, say it, or share it. Nothing lands on a calendar until you say so.")
                        .font(.hBody).foregroundStyle(Theme.muted).lineSpacing(3)
                }
                .padding(.horizontal, 4)

                noteCard(capture)
                tiles
                Text("Or share from any app: Facebook, Messages, Safari, Photos.")
                    .font(.hMeta).foregroundStyle(Theme.muted).padding(.horizontal, 4)
                if !capture.shared.isEmpty { sharedList(capture) }
                if !capture.recent.isEmpty { recentList(capture) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showReview) { CaptureReviewView() }
        }
        .preferredColorScheme(.dark)
        .onAppear { capture.refreshShared() }
        .confirmationDialog("A flyer or poster", isPresented: $pickFlyer) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take a photo") { showCamera = true }
            }
            Button("Choose a photo") { flyerPickerShown = true }
        }
        .photosPicker(isPresented: $flyerPickerShown, selection: $flyerItem, matching: .images)
        .photosPicker(isPresented: $screenshotPickerShown, selection: $screenshotItem, matching: .screenshots)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in readPhoto(data, .flyer) }.ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner { data in readPhoto(data, .paperCalendar) }.ignoresSafeArea()
        }
        .onChange(of: flyerItem) { _, item in load(item, as: .flyer) }
        .onChange(of: screenshotItem) { _, item in load(item, as: .screenshot) }
    }

    @State private var flyerPickerShown = false
    @State private var screenshotPickerShown = false

    func noteCard(_ capture: CaptureModel) -> some View {
        @Bindable var capture = capture
        let partner = (app.household.partnerName ?? "robin").lowercased()
        let reviewingNote = capture.session?.source == .note && capture.phase != .idle
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Quick note").eyebrow()
                    Spacer()
                    Button {
                        noteFocused = true
                    } label: {
                        Image(systemName: "mic").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36).background(Theme.chip, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dictate a note")
                    .accessibilityHint("Opens the keyboard; tap its microphone to dictate.")
                }
                TextField("dentist for \(partner) thurs 3pm", text: $capture.noteText, axis: .vertical)
                    .focused($noteFocused)
                    .submitLabel(.done)
                    .fieldStyle()
                    .accessibilityLabel("Quick note")
                    .onSubmit { Task { await capture.readNote() } }
                if reviewingNote {
                    NotePreview()
                } else {
                    Text("Claude reads this when you tap the button, then shows you the event before it goes anywhere.")
                        .font(.hMeta).foregroundStyle(Theme.muted)
                }
                noteButton(capture)
            }
        }
    }

    @ViewBuilder
    func noteButton(_ capture: CaptureModel) -> some View {
        let reviewingNote = capture.session?.source == .note
        switch capture.phase {
        case .reading where reviewingNote:
            HStack(spacing: 8) {
                ProgressView().tint(Theme.onEmber)
                Text("Claude is reading it")
            }
            .font(.hButton).foregroundStyle(Theme.iceSoft)
            .frame(maxWidth: .infinity, minHeight: Theme.touch)
            .background(Theme.iceDeep, in: Capsule())
        case .review where reviewingNote:
            Button(capture.addLabel) { Task { await capture.add() } }
                .buttonStyle(.pill(.primary))
                .disabled(capture.toAdd.isEmpty)
        case .added where reviewingNote:
            UndoButton(label: capture.addLabel)
        case .adding where reviewingNote:
            ProgressView().frame(maxWidth: .infinity, minHeight: Theme.touch)
        default:
            Button("Have Claude read it") {
                noteFocused = false
                Task { await capture.readNote() }
            }
            .buttonStyle(.pill(.primary))
            .disabled(capture.noteText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if case .failed(let message) = capture.phase, reviewingNote {
            Notice(text: message)
        }
    }

    var tiles: some View {
        HStack(spacing: 8) {
            tile("Flyer or poster", symbol: "photo") { pickFlyer = true }
            tile("Paper calendar", symbol: "calendar.badge.plus") { showScanner = true }
            tile("Screenshot", symbol: "rectangle.on.rectangle") { screenshotPickerShown = true }
        }
    }

    func tile(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.emberSoft)
                Text(title).font(.custom(Typeface.semibold, size: 13, relativeTo: .footnote)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    func sharedList(_ capture: CaptureModel) -> some View {
        ListCard(title: "Shared with Hearth · \(capture.shared.count)") {
            ForEach(capture.shared) { item in
                HStack(spacing: 12) {
                    IconTile(symbol: item.kind == .image ? "photo" : item.kind == .url ? "link" : "text.alignleft", tint: .ice)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text ?? (item.kind == .image ? "A shared image" : "Shared"))
                            .font(.hRowTitle).foregroundStyle(Theme.ink).lineLimit(2)
                        Text(item.from.map { "From \($0)" } ?? "Shared").font(.hMeta).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Read it") {
                        showReview = true
                        Task { await capture.read(shared: item) }
                    }
                    .font(.hLabel).foregroundStyle(Theme.onEmber)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Theme.ember, in: Capsule())
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Hairline() }
            }
        }
    }

    func recentList(_ capture: CaptureModel) -> some View {
        ListCard(title: "Recent") {
            ForEach(capture.recent) { record in
                Button {
                    guard record.status == .read, let reading = record.decodedReading,
                        let source = CapturePrompt.Source(rawValue: record.source)
                    else { return }
                    Task {
                        await capture.load(reading, source: source, id: record.id)
                        showReview = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        Thumbnail(data: record.thumbnail, source: record.source)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capture.recentTitle(record)).font(.hRowTitle).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(capture.recentDetail(record)).font(.hMeta).foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Hairline() }
            }
        }
    }

    func load(_ item: PhotosPickerItem?, as source: CapturePrompt.Source) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            readPhoto(data, source)
        }
    }

    func readPhoto(_ data: Data, _ source: CapturePrompt.Source) {
        showReview = true
        Task { await app.capture.read(photo: data, source: source) }
    }
}

/// The parsed preview under the quick note: what Claude made of it.
struct NotePreview: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let capture = app.capture
        if case .review = capture.phase, let entry = capture.toAdd.first {
            EntrySummaryRow(entry: entry, calendar: "\(capture.calendarName) · iCloud")
        } else if case .added = capture.phase, let entry = capture.toAdd.first {
            EntrySummaryRow(entry: entry, calendar: "\(capture.calendarName) · iCloud")
        }
    }
}

/// "Robin: dentist / Thu, Oct 29 · 3:00–4:00 PM / Family · iCloud / One hour is a guess".
struct EntrySummaryRow: View {
    @Environment(AppModel.self) private var app
    let entry: CaptureEntry
    let calendar: String

    var body: some View {
        let fmt = app.household.fmt
        let interval = entry.interval(in: app.household.zone)
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: entry.kind == .reminder ? "bell" : "calendar", tint: .ice)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.hRowTitle).foregroundStyle(Theme.ink)
                if let interval {
                    Text(
                        entry.kind == .reminder
                            ? "\(fmt.shortDay(interval.start)) · \(fmt.time(interval.start))"
                            : fmt.when(interval.start, interval.end, allDay: entry.isAllDay)
                    )
                    .font(.custom(Typeface.regular, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.inkSoft)
                }
                HStack(spacing: 8) {
                    Text(entry.kind == .reminder ? "Reminders" : calendar).font(.hMeta).foregroundStyle(Theme.muted)
                    ForEach(entry.guesses, id: \.self) { guess in
                        Text(guess).font(.custom(Typeface.semibold, size: 12, relativeTo: .caption)).foregroundStyle(Theme.emberSoft)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Theme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// "Added to Family" with Undo while the window is open.
struct UndoButton: View {
    @Environment(AppModel.self) private var app
    let label: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let capture = app.capture
            HStack(spacing: 10) {
                Label(label, systemImage: "checkmark")
                    .font(.hButton).foregroundStyle(Theme.iceSoft)
                    .frame(maxWidth: .infinity, minHeight: Theme.touch)
                    .background(Theme.iceDeep, in: Capsule())
                if capture.canUndo {
                    Button("Undo") { Task { await capture.undo() } }
                        .buttonStyle(.pill(.secondary))
                        .frame(width: 96)
                }
            }
        }
    }
}

struct Thumbnail: View {
    let data: Data?
    let source: String

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: source == "note" ? "text.quote" : "photo")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.chipInk)
            }
        }
        .frame(width: 44, height: 44)
        .background(Theme.chip)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}
