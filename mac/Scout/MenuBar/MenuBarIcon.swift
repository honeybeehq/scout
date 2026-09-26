import AppKit
import SwiftUI

enum MenuBarIcon {
    static func image(scouting: Bool) -> NSImage {
        let renderer = ImageRenderer(content: glyph(scouting: scouting))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Scout")!
        image.isTemplate = !scouting
        image.accessibilityDescription = scouting ? "Scout is scouting" : "Scout"
        return image
    }

    private static func glyph(scouting: Bool) -> some View {
        ScoutMark(
            litArcs: 3,
            arcColor: scouting ? Palette.flare : .black,
            pointerStyle: AnyShapeStyle(scouting ? Color.white : Color.black)
        )
        .frame(width: 18, height: 18)
        .offset(x: -2, y: -2)
        .frame(width: 18, height: 16)
    }
}
