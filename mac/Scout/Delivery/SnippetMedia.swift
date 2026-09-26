import AppKit
import ImageIO
import ScoutCore
import UniformTypeIdentifiers

enum SnippetMedia {
    static func attachments(for snippet: Snippet, recorder: SegmentedScreenRecorder, into directory: URL) async -> [ComposedTask.Attachment] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var attachments: [ComposedTask.Attachment] = []
        if let clip = try? await recorder.exportClip(from: snippet.range.start, to: snippet.range.end, padding: 1.0, into: directory.appendingPathComponent("clip.mp4")) {
            attachments.append(.init(kind: .video, url: clip.url))
        }
        for (index, mark) in snippet.marks.enumerated() {
            guard let frame = await recorder.snapshot(at: mark.at), let display = recorder.display else { continue }
            let image = outlined(frame, mark: mark, display: display) ?? frame
            let url = directory.appendingPathComponent("pin-\(index + 1).png")
            if write(image, to: url) { attachments.append(.init(kind: .image, url: url)) }
        }
        return attachments
    }

    private static func outlined(_ image: CGImage, mark: Mark, display: CaptureDisplay) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scaleX = Double(width) / Double(display.videoWidth)
        let scaleY = Double(height) / Double(display.videoHeight)

        func imageRect(_ rect: Rect) -> CGRect {
            let origin = display.videoPoint(forScreenPoint: CGPoint(x: rect.x, y: rect.y))
            let far = display.videoPoint(forScreenPoint: CGPoint(x: rect.x + rect.width, y: rect.y + rect.height))
            let top = Double(height) - origin.y * scaleY
            let bottom = Double(height) - far.y * scaleY
            return CGRect(x: origin.x * scaleX, y: bottom, width: (far.x - origin.x) * scaleX, height: top - bottom)
        }

        let flare = CGColor(srgbRed: 1, green: 0.416, blue: 0.239, alpha: 1)
        let beam = CGColor(srgbRed: 0.545, green: 0.588, blue: 1, alpha: 1)
        if let frame = mark.target?.frame {
            let rect = imageRect(frame).insetBy(dx: -4, dy: -4)
            context.setStrokeColor(beam)
            context.setLineWidth(max(3, Double(width) / 640))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.strokePath()
        }
        let point = imageRect(Rect(x: mark.point.x, y: mark.point.y, width: 0, height: 0)).origin
        let radius = max(7, Double(width) / 220)
        context.setFillColor(flare)
        context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(radius / 3.5)
        context.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        return context.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
