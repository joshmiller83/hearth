import SwiftUI

/// Bricolage Grotesque for display type, Figtree for everything else. Made with
/// `relativeTo:` so every size follows Dynamic Type.
enum Typeface {
    static let display = "BricolageGrotesque-Bold"
    static let displayHeavy = "BricolageGrotesque-ExtraBold"
    static let regular = "Figtree-Regular"
    static let medium = "Figtree-Medium"
    static let semibold = "Figtree-SemiBold"
    static let bold = "Figtree-Bold"
}

extension Font {
    /// "Good morning, Josh." 34 pt display.
    static let hTitle = Font.custom(Typeface.display, size: 34, relativeTo: .largeTitle)
    /// "Hearth" in the header, 18 pt display.
    static let hBrand = Font.custom(Typeface.display, size: 18, relativeTo: .headline)
    /// Card titles, 16 pt.
    static let hCardTitle = Font.custom(Typeface.semibold, size: 16, relativeTo: .headline)
    /// Row titles, 15 pt.
    static let hRowTitle = Font.custom(Typeface.semibold, size: 15, relativeTo: .body)
    /// Body copy, 15 pt.
    static let hBody = Font.custom(Typeface.regular, size: 15, relativeTo: .body)
    /// Buttons, 15 pt bold.
    static let hButton = Font.custom(Typeface.bold, size: 15, relativeTo: .body)
    /// Secondary lines, 13 pt.
    static let hMeta = Font.custom(Typeface.regular, size: 13, relativeTo: .footnote)
    /// Small strong labels ("Join", chips), 14 pt.
    static let hLabel = Font.custom(Typeface.bold, size: 14, relativeTo: .subheadline)
    /// "NEEDS YOU · 3": 12 pt bold, spaced, upper case (apply `.eyebrow()`).
    static let hEyebrow = Font.custom(Typeface.bold, size: 12, relativeTo: .caption)
    /// Big numbers: times on the Next up tile, dates in lists.
    static let hNumber = Font.custom(Typeface.bold, size: 17, relativeTo: .headline)
    static let hNumberLarge = Font.custom(Typeface.bold, size: 20, relativeTo: .title3)
    /// Tab and tiny labels, 11 pt.
    static let hTiny = Font.custom(Typeface.bold, size: 11, relativeTo: .caption2)
}

extension View {
    /// The design's eyebrow label: upper case, spaced, muted unless told otherwise.
    func eyebrow(_ color: Color = Theme.muted) -> some View {
        font(.hEyebrow).tracking(0.72).textCase(.uppercase).foregroundStyle(color)
    }

    /// The design's display tracking for the big title.
    func displayTracking() -> some View {
        tracking(-0.85)
    }
}
