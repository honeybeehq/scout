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

    static let flare = Color(hex: 0xFF6A3D)
    static let flareSoft = Color(hex: 0xFF9A6B)
    static let beam = Color(hex: 0x8B96FF)
    static let mint = Color(hex: 0x42E2A4)
    static let amber = Color(hex: 0xFFB84D)
    static let rose = Color(hex: 0xFF5876)

    static let text = Color.white
    static let textSecondary = Color.white.opacity(0.66)
    static let textTertiary = Color.white.opacity(0.42)
    static let hairline = Color.white.opacity(0.10)
    static let fill = Color.white.opacity(0.06)
    static let fillRaised = Color.white.opacity(0.10)

    static let flareGradient = LinearGradient(
        colors: [Color(hex: 0xFFB36B), flare, Color(hex: 0xFF3D6E)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
