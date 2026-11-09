import SwiftUI

nonisolated enum Typography {
    static let display = Font.system(size: 34, weight: .heavy).width(.condensed)
    static let title = Font.system(size: 22, weight: .bold)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let callout = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 11, weight: .medium)
    static let label = Font.system(size: 10, weight: .bold)
    static let mono = Font.system(size: 11.5, weight: .medium, design: .monospaced)
    static let numeric = Font.system(size: 12, weight: .semibold).monospacedDigit()
    static let key = Font.system(size: 10.5, weight: .semibold).monospacedDigit()
    static let transcript = Font.system(size: 22, weight: .semibold)
}

extension View {
    func eyebrowStyle(_ color: Color = Palette.textTertiary) -> some View {
        font(Typography.label)
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}
