import SwiftUI

/// The design's colors, straight from the artifact. Hearth is dark only.
enum Theme {
    static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    // Surfaces
    static let bg = hex(0x141210)
    static let surface = hex(0x1E1B17)
    static let line = hex(0x2E2A24)
    static let chip = hex(0x2A2620)
    static let tabBar = hex(0x181512)

    // Text
    static let ink = hex(0xF4EFE8)
    static let inkSoft = hex(0xE6DFD5)
    static let muted = hex(0xA89F93)
    static let chipInk = hex(0xD9D1C6)

    // Ember: what needs you, the owner's actions, the partner card.
    static let ember = hex(0xFF8A3D)
    static let emberSoft = hex(0xFFB37F)
    static let emberDeep = hex(0x3A2416)
    static let emberLine = hex(0x4A2E1A)
    static let onEmber = hex(0x1A120B)

    // Ice: plans, calls, the calendar.
    static let ice = hex(0x8EC5E8)
    static let iceSoft = hex(0xA9D6F2)
    static let iceDeep = hex(0x172631)
    static let iceInk = hex(0xDCEEFA)
    static let onIce = hex(0x0D1A22)

    // Stone: archive and delete queues.
    static let stone = hex(0x6B6358)
    static let stoneDeep = hex(0x3A352E)

    static let cardRadius: CGFloat = 20
    static let tileRadius: CGFloat = 14
    static let touch: CGFloat = 44
}
