import AppKit
import CryptoKit
import SwiftUI

final class LookStore {
    static let shared = LookStore()

    struct Avatar {
        let image: NSImage
        let scale: CGFloat
        let body: CGFloat
    }

    private var avatars: [String: Avatar] = [:]
    private var absent: Set<String> = []
    private var icons: [String: NSImage] = [:]
    private let directory: URL

    init(directory: URL = ScoutPaths.support.appendingPathComponent("Looks", isDirectory: true)) {
        self.directory = directory
    }

    func avatar(_ look: ApiaryLook) -> Avatar? {
        if let avatar = avatars[look.key] { return avatar }
        let file = directory.appendingPathComponent(Self.fileName(look.key) + ".png")
        var data = look.image.flatMap(Self.decode(dataURL:))
        if data == nil, !absent.contains(look.key) { data = try? Data(contentsOf: file) }
        guard let data, let image = NSImage(data: data), let fit = Self.fit(image) else {
            absent.insert(look.key)
            return nil
        }
        if look.image != nil, !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        let avatar = Avatar(image: image, scale: fit.scale, body: fit.body)
        avatars[look.key] = avatar
        absent.remove(look.key)
        return avatar
    }

    func icon(_ look: ApiaryLook, dark: Bool, size: CGFloat) -> NSImage? {
        let id = "\(look.key)|\(dark)|\(size)"
        if let icon = icons[id] { return icon }
        let file = directory.appendingPathComponent(Self.fileName(look.key) + ".svg")
        var svg = look.iconSvg
        if let svg, !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? svg.write(to: file, atomically: true, encoding: .utf8)
        }
        if svg == nil { svg = try? String(contentsOf: file, encoding: .utf8) }
        guard let svg, let tint = LookTint(look, dark: dark) else { return nil }
        let source = Self.strokeAtLeast(1.5, displayedAt: size, in: svg.replacingOccurrences(of: "currentColor", with: tint.foregroundHex))
        guard let data = source.data(using: .utf8), let vector = NSImage(data: data), let image = Self.rasterize(vector, size: size) else { return nil }
        icons[id] = image
        return image
    }

    private static func rasterize(_ vector: NSImage, size: CGFloat) -> NSImage? {
        let scale: CGFloat = 3
        let pixels = Int(size * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        vector.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = CGSize(width: size, height: size)
        let image = NSImage(size: CGSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    private static func fileName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func decode(dataURL: String) -> Data? {
        guard dataURL.hasPrefix("data:image/png;base64,") else { return nil }
        return Data(base64Encoded: String(dataURL.dropFirst("data:image/png;base64,".count)), options: .ignoreUnknownCharacters)
    }

    private static func fit(_ image: NSImage) -> (scale: CGFloat, body: CGFloat)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for row in 0..<height {
            for column in 0..<width where pixels[(row * width + column) * 4 + 3] > 8 {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let centerX = CGFloat(width) / 2
        let centerY = CGFloat(height) / 2
        let reach = max((centerX - CGFloat(minX)) / CGFloat(width), (CGFloat(maxX + 1) - centerX) / CGFloat(width), (centerY - CGFloat(minY)) / CGFloat(height), (CGFloat(maxY + 1) - centerY) / CGFloat(height))
        let bodyHalf = max((CGFloat(maxY + 1) - centerY) / CGFloat(height), 0.05)
        let scale = min(0.8 / (2 * bodyHalf), 0.5 / reach)
        return (scale, 2 * bodyHalf * scale)
    }

    private static func strokeAtLeast(_ minimum: CGFloat, displayedAt size: CGFloat, in svg: String) -> String {
        var viewBox: CGFloat = 16
        if let match = svg.firstMatch(of: /viewBox="\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)\s*"/), let width = Double(match.1), let height = Double(match.2) {
            viewBox = CGFloat(max(width, height))
        }
        let floor = minimum * viewBox / size
        let format = { (value: CGFloat) in String(format: "%.3f", Double(value)) }
        guard svg.contains("stroke-width") else {
            return svg.replacing(/<svg\b/, maxReplacements: 1) { _ in "<svg stroke-width=\"\(format(floor))\"" }
        }
        return svg.replacing(/stroke-width\s*=\s*"([\d.]+)"/) { match in
            let value = CGFloat(Double(match.1) ?? 0)
            return "stroke-width=\"\(format(max(value, floor)))\""
        }
    }
}

struct LookTint {
    let foreground: NSColor
    let background: NSColor

    var foregroundHex: String { Self.hex(foreground) }

    init?(_ look: ApiaryLook, dark: Bool) {
        guard let raw = (dark ? look.tintDark ?? look.tint : look.tint).flatMap(Self.color) else { return nil }
        let base = dark ? NSColor(hex: 0x111113) : NSColor(hex: 0xFFFFFF)
        var foreground = raw
        var background = Self.mix(base, foreground, dark ? 0.16 : 0.12)
        var steps = 0
        while Self.contrast(foreground, background) < 3, steps < 8 {
            foreground = Self.mix(foreground, dark ? .white : .black, 0.12)
            background = Self.mix(base, foreground, dark ? 0.16 : 0.12)
            steps += 1
        }
        self.foreground = foreground
        self.background = background
    }

    static func color(_ hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(hex: value)
    }

    private static func components(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }

    private static func mix(_ a: NSColor, _ b: NSColor, _ amount: CGFloat) -> NSColor {
        let (ar, ag, ab) = components(a)
        let (br, bg, bb) = components(b)
        return NSColor(srgbRed: ar + (br - ar) * amount, green: ag + (bg - ag) * amount, blue: ab + (bb - ab) * amount, alpha: 1)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        let (r, g, b) = components(color)
        func channel(_ value: CGFloat) -> CGFloat { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func hex(_ color: NSColor) -> String {
        let (r, g, b) = components(color)
        return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

struct TargetIcon: View {
    static let size: CGFloat = 24
    static let radius: CGFloat = 6

    var target: ApiaryTarget
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let size = Self.size
        Group {
            if target.kind == TargetPickerModel.clipboardKind {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: size, height: size)
                    .background(Palette.raised, in: .rect(cornerRadius: Self.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Palette.hairline))
            } else if let look = target.look, let avatar = LookStore.shared.avatar(look) {
                Image(nsImage: avatar.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * avatar.scale, height: size * avatar.scale)
                    .frame(width: size, height: size)
            } else if let look = target.look, let tint = LookTint(look, dark: scheme == .dark) {
                Group {
                    if look.iconSvg != nil || target.isProject, let icon = LookStore.shared.icon(look, dark: scheme == .dark, size: 16) {
                        Image(nsImage: icon)
                            .frame(width: 16, height: 16)
                    } else {
                        Text(initial(look.glyph))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(nsColor: tint.foreground))
                    }
                }
                .frame(width: size, height: size)
                .background(Color(nsColor: tint.background), in: .rect(cornerRadius: Self.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color(nsColor: tint.foreground).opacity(0.22)))
            } else {
                Text(initial(target.look?.glyph))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: size, height: size)
                    .background(Palette.raised, in: .rect(cornerRadius: Self.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
            }
        }
        .frame(width: size, height: size)
    }

    private func initial(_ glyph: String?) -> String {
        if let glyph, let first = glyph.first { return String(first).uppercased() }
        let letter = target.title.first { $0.isLetter || $0.isNumber }
        return letter.map { String($0).uppercased() } ?? "·"
    }
}
