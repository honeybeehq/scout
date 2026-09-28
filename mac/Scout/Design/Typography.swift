import SwiftUI

enum Typography {
    static let hero = Font.system(size: 52, weight: .bold).width(.expanded)
    static let title = Font.system(size: 30, weight: .semibold)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 14, weight: .regular)
    static let caption = Font.system(size: 12, weight: .medium)
    static let eyebrow = Font.system(size: 11, weight: .semibold).width(.expanded)
    static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let transcript = Font.system(size: 26, weight: .medium)
}

extension View {
    func eyebrowStyle(_ color: Color = Palette.textTertiary) -> some View {
        font(Typography.eyebrow)
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}
