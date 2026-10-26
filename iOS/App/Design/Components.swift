import SwiftUI

/// A rounded card on the surface color with a hairline border.
struct Card<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    var border: Color = Theme.line
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(border, lineWidth: 1))
    }
}

/// A list card: an eyebrow header (with an optional link), then rows split by hairlines.
struct ListCard<Content: View>: View {
    var title: String
    var link: (label: String, action: () -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        Card(padding: EdgeInsets(top: 6, leading: 14, bottom: 4, trailing: 14)) {
            HStack {
                Text(title).eyebrow()
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let link {
                    Button(link.label, action: link.action)
                        .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ember)
                        .frame(minHeight: 32)
                }
            }
            .padding(.vertical, 8)
            content
        }
    }
}

/// The design's colored tiles behind icons.
enum Tint {
    case ember
    case ice
    case neutral

    var background: Color {
        switch self {
        case .ember: Theme.emberDeep
        case .ice: Theme.iceDeep
        case .neutral: Theme.chip
        }
    }

    var foreground: Color {
        switch self {
        case .ember: Theme.emberSoft
        case .ice: Theme.iceSoft
        case .neutral: Theme.chipInk
        }
    }
}

/// A 38-point rounded tile with an SF Symbol.
struct IconTile: View {
    var symbol: String
    var tint: Tint
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint.foreground)
            .frame(width: size, height: size)
            .background(tint.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row in a list card: tile, title and detail, chevron, hairline above.
struct LinkRow: View {
    var symbol: String
    var tint: Tint
    var title: String
    var detail: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.hRowTitle).foregroundStyle(Theme.ink)
                    Text(detail).font(.hMeta).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Hairline() }
        .accessibilityElement(children: .combine)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }
}

/// The design's pill buttons: ember for the main action, chip for the other.
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case ice
    }

    var kind: Kind = .primary
    var height: CGFloat = Theme.touch

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hButton)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 14)
            .background(background, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    var foreground: Color {
        switch kind {
        case .primary: Theme.onEmber
        case .secondary: Theme.ink
        case .ice: Theme.onIce
        }
    }

    var background: Color {
        switch kind {
        case .primary: Theme.ember
        case .secondary: Theme.chip
        case .ice: Theme.ice
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(_ kind: PillButtonStyle.Kind, height: CGFloat = Theme.touch) -> PillButtonStyle {
        PillButtonStyle(kind: kind, height: height)
    }
}

/// A 44-point round header button with an SF Symbol and an optional badge.
struct RoundIconButton: View {
    var symbol: String
    var label: String
    var badge: Int = 0
    var filled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: Theme.touch, height: Theme.touch)
                .background(filled ? Theme.chip : Color.clear, in: Circle())
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.hTiny)
                            .foregroundStyle(Theme.onEmber)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Theme.ember, in: Capsule())
                            .offset(x: 1, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(label): \(badge)" : label)
    }
}

/// The owner's initial in a round chip ("J"), the way into Sources.
struct Avatar: View {
    var initial: String
    var size: CGFloat = 34
    var ring: Color?

    var body: some View {
        Text(initial)
            .font(.custom(Typeface.bold, size: size * 0.42, relativeTo: .body))
            .foregroundStyle(ring == nil ? Theme.ink : Theme.emberSoft)
            .frame(width: size, height: size)
            .background(ring == nil ? Theme.chip : Theme.emberDeep, in: Circle())
            .overlay { if let ring { Circle().strokeBorder(ring, lineWidth: 2) } }
    }
}

/// "SAT / 31" in a 44-point column.
struct DateColumn: View {
    var tag: String
    var day: Int

    var body: some View {
        VStack(spacing: 0) {
            Text(tag).font(.hTiny).tracking(0.66).foregroundStyle(Theme.emberSoft)
            Text("\(day)").font(.hNumberLarge).foregroundStyle(Theme.ink)
        }
        .frame(width: 44)
        .accessibilityElement(children: .combine)
    }
}

/// A segmented pair of pills ("Agenda | Around town").
struct SegmentedPills<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.custom(selected ? Typeface.bold : Typeface.semibold, size: 14, relativeTo: .subheadline))
                        .foregroundStyle(selected ? Theme.bg : Theme.chipInk)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(selected ? Theme.ink : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
    }
}

/// A screen's scrolling column with the design's padding.
struct ScreenScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
    }
}

/// A notice inside a screen: what's wrong and, often, what to do.
struct Notice: View {
    var symbol: String = "exclamationmark.circle"
    var text: String
    var tint: Tint = .ember

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.custom(Typeface.semibold, size: 13, relativeTo: .footnote))
        .foregroundStyle(tint.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
