import AppKit
import SwiftUI

nonisolated extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkOpacity : lightOpacity)
        })
    }
}

nonisolated extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

nonisolated enum Palette {
    static let canvas = Color(light: 0xF6F6F4, dark: 0x0A0A0C)
    static let surface = Color(light: 0xFFFFFF, dark: 0x141417)
    static let raised = Color(light: 0xEEEEEB, dark: 0x1E1E22)
    static let sunken = Color(light: 0xE9E9E6, dark: 0x060608)
    static let hud = Color(light: 0xFFFFFF, dark: 0x111113)

    static let text = Color(light: 0x0B0B0D, dark: 0xF6F6F8)
    static let textSecondary = Color(light: 0x45454D, dark: 0xB4B4BD)
    static let textTertiary = Color(light: 0x63636C, dark: 0x8C8C96)
    static let textQuaternary = Color(light: 0x9C9CA3, dark: 0x55555D)

    static let hairline = Color(light: 0xE0E0DC, dark: 0x26262B)
    static let stroke = Color(light: 0xC9C9C4, dark: 0x3A3A41)
    static let strokeStrong = Color(light: 0x0B0B0D, dark: 0xF6F6F8)

    static let fill = Color(light: 0x0B0B0D, dark: 0xFFFFFF, lightOpacity: 0.04, darkOpacity: 0.05)
    static let fillRaised = Color(light: 0x0B0B0D, dark: 0xFFFFFF, lightOpacity: 0.07, darkOpacity: 0.09)
    static let fillStrong = Color(light: 0x0B0B0D, dark: 0xFFFFFF, lightOpacity: 0.12, darkOpacity: 0.15)

    static let accent = Color(light: 0xF0482A, dark: 0xFF5A3C)
    static let accentText = Color(light: 0xC23113, dark: 0xFF7A5E)
    static let onAccent = Color(light: 0x0B0B0D, dark: 0x0B0B0D)
    static let accentWash = Color(light: 0xF0482A, dark: 0xFF5A3C, lightOpacity: 0.08, darkOpacity: 0.12)
    static let selection = Color(light: 0x0B0B0D, dark: 0xFFFFFF, lightOpacity: 0.06, darkOpacity: 0.08)

    static let recording = accent
    static let positive = Color(light: 0x0E7D3A, dark: 0x3DDC84)
    static let caution = Color(light: 0x8A5300, dark: 0xFFB224)
    static let cautionFill = Color(light: 0xF5A524, dark: 0xFFB224)
    static let onCaution = Color(light: 0x1A1300, dark: 0x0B0B0D)
    static let ink = Color(light: 0x1C1C1E, dark: 0xF2F2F4)
    static let onInk = Color(light: 0xFFFFFF, dark: 0x0B0B0D)
    static let negative = Color(light: 0xC81E44, dark: 0xFF4F6E)
    static let negativeFill = Color(light: 0xC8102E, dark: 0xC8102E)
    static let negativeWash = Color(light: 0xC81E44, dark: 0xFF4F6E, lightOpacity: 0.10, darkOpacity: 0.16)

    static let scrim = Color.black.opacity(0.28)
}
