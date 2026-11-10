import AppKit
import SwiftUI

enum MenuBarIcon {
    static func image(scouting: Bool) -> NSImage {
        let renderer = ImageRenderer(content: MenuBarGlyph(scouting: scouting))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Scout")!
        image.isTemplate = !scouting
        image.accessibilityDescription = scouting ? "Scout is scouting" : "Scout"
        return image
    }
}

struct MenuBarGlyph: View {
    var scouting: Bool

    var body: some View {
        let ink = scouting ? Color(hex: 0xFF5A3C) : Color.black
        ZStack {
            Circle()
                .fill(ink.opacity(scouting ? 0.4 : 0.22))
                .frame(width: 17, height: 17)
                .blur(radius: 1.4)
            Circle()
                .strokeBorder(ink.opacity(0.7), lineWidth: 1.6)
                .frame(width: 15, height: 15)
            Circle()
                .fill(ink)
                .frame(width: 7.5, height: 7.5)
                .offset(x: -0.6, y: 0.7)
        }
        .frame(width: 18, height: 18)
    }
}
