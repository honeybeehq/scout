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
            Capsule()
                .fill(ink.opacity(scouting ? 0.4 : 0.22))
                .frame(width: 9, height: 17)
                .blur(radius: 1.6)
            Capsule()
                .fill(BeamFill(color: ink))
                .frame(width: 5, height: 15)
        }
        .frame(width: 14, height: 18)
    }
}
