import AppKit
import SwiftUI

struct AppIconArtwork: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(hex: 0x1B1F4F), Color(hex: 0x0A0B14)], startPoint: .top, endPoint: .bottom)
                )
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(
                    RadialGradient(colors: [Palette.accent.opacity(0.55), .clear], center: UnitPoint(x: 0.78, y: 0.86), startRadius: 10, endRadius: 520)
                )
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 5
                )
            ScoutMark(litArcs: 3)
                .frame(width: 600, height: 600)
                .offset(x: -24, y: -24)
        }
        .frame(width: 824, height: 824)
        .frame(width: 1024, height: 1024)
    }
}

@main
struct AppIconRenderer {
    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
        var images: [[String: String]] = []
        for size in sizes {
            let pixels = size.points * size.scale
            let renderer = ImageRenderer(content: AppIconArtwork())
            renderer.scale = Double(pixels) / 1024
            guard let cgImage = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let name = "icon_\(size.points)x\(size.points)@\(size.scale)x.png"
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
            images.append(["idiom": "mac", "size": "\(size.points)x\(size.points)", "scale": "\(size.scale)x", "filename": name])
        }
        let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
        let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("Contents.json"))
    }
}
