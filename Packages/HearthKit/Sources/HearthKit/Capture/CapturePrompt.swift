import Foundation

/// The request that turns a capture into plans.
public enum CapturePrompt {
    public enum Source: String, Sendable {
        case note
        case flyer
        case paperCalendar
        case screenshot
        case shared

        var describe: String {
            switch self {
            case .note: "a quick note the owner typed or dictated"
            case .flyer: "a photo of a flyer or poster"
            case .paperCalendar: "a photo of a page of the family's handwritten paper calendar"
            case .screenshot: "a screenshot (a message, a post, an email, a web page)"
            case .shared: "something the owner shared into Hearth from another app"
            }
        }
    }

    /// The image to read, already scaled down (about 1,568 px on the long side is plenty).
    public struct Image: Sendable {
        public var data: Data
        public var mediaType: String

        public init(data: Data, mediaType: String = "image/jpeg") {
            self.data = data
            self.mediaType = mediaType
        }
    }

    /// The system prompt: who's who and how to read. It changes only when the
    /// household does, so it caches; today's date goes in the message instead.
    public static func system(household: Household) -> String {
        let partner = household.partnerName ?? "their partner"
        return """
            You read things the owner of a household wants on the calendar, and turn them into calendar entries for \
            Hearth, the household's assistant app. Nothing you return is added until the owner checks it, so say \
            plainly what you assumed.

            The household: the owner is \(household.ownerName); their partner is \(partner). The family calendar is \
            "\(household.familyCalendar)". They live in or near \(household.town.isEmpty ? "a small town" : household.town).

            How to read:
            - Only return entries the input actually contains. Never invent events. Skip decoration, slogans and ads.
            - Resolve relative dates ("thurs", "tomorrow", "next Tue", "the 5th") against today's date in the message, \
            choosing the next upcoming one. For a calendar page, use the month and year that make it current or upcoming.
            - Dates are YYYY-MM-DD and times HH:MM on a 24-hour clock, local time. No offsets.
            - Without a start time, an event is all day (startTime null), unless a time is the obvious reading, in \
            which case say so in guesses. "am" alone means 08:00 and "pm" alone 13:00 for reminders; note the guess.
            - Without an end time, leave endTime null for appointments (the app uses an hour) and add the guess \
            "One hour is a guess". For fairs, services and shows, use the end time printed, or null.
            - A question mark, "maybe", "tbd" or "?" means tentative: true.
            - The same thing written on the same weekday more than once on a calendar page is one repeating entry \
            (repeats weekly), not several.
            - Birthdays and anniversaries are all day, kind birthday or anniversary, repeating yearly.
            - "call…", "remember to…", "pick up…" with no meeting are kind reminder.
            - Someone else's entry gets their name first in the title: "\(partner): dentist". The owner's and the \
            whole family's don't. Put that person's name in person.
            - Keep titles short and in sentence case: "Fall craft fair", "Lunch with Ben". Put cost in cost, and \
            phone numbers or what to bring in notes.
            - source is the words exactly as written (for handwriting, your best transcription).
            - confidence: high when everything is legible and stated; medium when you inferred something; low when \
            you're unsure what it says.
            - When you can't decide something that matters (whose it is, the time, whether it's real), set question: \
            one short question and two or three options. Each option says what it changes (title, startTime, endTime, \
            allDay, person) or skip: true to leave the entry out. Always include a skip option.
            - summary is one plain sentence about what the input was and what you found.
            """
    }

    /// The user message: the date context, then the note or the image.
    public static func message(source: Source, text: String?, image: Image?, now: Date, household: Household) -> ClaudeMessage {
        let fmt = household.fmt
        var lines = [
            "Today is \(fmt.longDay(now)), \(RFC3339.day(now, zone: household.zone)), \(fmt.time(now)), time zone \(household.timeZone).",
            "This is \(source.describe).",
        ]
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(image == nil ? "The note:\n\(text)" : "The owner added:\n\(text)")
        }
        lines.append("Read it and return the entries.")
        var blocks: [ContentBlock] = []
        if let image { blocks.append(.image(image.data, mediaType: image.mediaType)) }
        blocks.append(.text(lines.joined(separator: "\n")))
        return .user(blocks)
    }

    public static func request(source: Source, text: String?, image: Image?, now: Date, household: Household) -> ClaudeRequest {
        ClaudeRequest(
            model: .opus,
            maxTokens: 16_000,
            system: system(household: household),
            messages: [message(source: source, text: text, image: image, now: now, household: household)],
            effort: .medium,
            outputSchema: schema
        )
    }

    public static let schema: JSONValue = {
        let option = Schema.object([
            "id": Schema.string,
            "label": Schema.string("A short button label: \"Mine\", \"Evening, 7 PM\", \"Skip\"."),
            "skip": Schema.boolean,
            "title": Schema.nullable(Schema.string),
            "startTime": Schema.nullable(Schema.string("HH:MM")),
            "endTime": Schema.nullable(Schema.string("HH:MM")),
            "allDay": Schema.nullable(Schema.boolean),
            "person": Schema.nullable(Schema.string),
        ])
        let entry = Schema.object([
            "id": Schema.string("e1, e2, …"),
            "kind": Schema.enumeration(CaptureEntry.Kind.allCases.map(\.rawValue)),
            "title": Schema.string,
            "date": Schema.string("YYYY-MM-DD"),
            "startTime": Schema.nullable(Schema.string("HH:MM, 24-hour; null for all day")),
            "endTime": Schema.nullable(Schema.string("HH:MM, 24-hour")),
            "location": Schema.nullable(Schema.string),
            "notes": Schema.nullable(Schema.string),
            "cost": Schema.nullable(Schema.string),
            "repeats": Schema.nullable(
                Schema.object([
                    "frequency": Schema.enumeration(["daily", "weekly", "monthly", "yearly"]),
                    "interval": Schema.integer,
                    "until": Schema.nullable(Schema.string("YYYY-MM-DD")),
                ])),
            "person": Schema.nullable(Schema.string),
            "tentative": Schema.boolean,
            "confidence": Schema.enumeration(["high", "medium", "low"]),
            "guesses": Schema.array(Schema.string),
            "question": Schema.nullable(
                Schema.object([
                    "text": Schema.string,
                    "options": Schema.array(option),
                ])),
            "source": Schema.string,
        ])
        return Schema.object([
            "summary": Schema.string,
            "entries": Schema.array(entry),
        ])
    }()
}
