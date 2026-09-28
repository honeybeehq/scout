import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum Palette {
    static let ink = Color(hex: 0x07080D)
    static let night = Color(hex: 0x0E1020)
    static let indigo = Color(hex: 0x1C2156)
    static let plum = Color(hex: 0x3B1650)

    static let accent = Color(hex: 0xFF6A3D)
    static let positive = Color(hex: 0x5CCF9E)
    static let caution = Color(hex: 0xE9AE57)
    static let negative = Color(hex: 0xEE6078)

    static let text = Color.white
    static let textSecondary = Color.white.opacity(0.64)
    static let textTertiary = Color.white.opacity(0.40)
    static let textQuaternary = Color.white.opacity(0.24)
    static let hairline = Color.white.opacity(0.08)
    static let stroke = Color.white.opacity(0.14)
    static let fill = Color.white.opacity(0.05)
    static let fillRaised = Color.white.opacity(0.09)
    static let fillStrong = Color.white.opacity(0.14)

    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0xFF8152), accent],
        startPoint: .top,
        endPoint: .bottom
    )
}
