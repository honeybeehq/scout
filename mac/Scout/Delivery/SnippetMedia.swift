import AppKit
import AVFoundation
import ImageIO
import ScoutCore
import UniformTypeIdentifiers

enum SnippetMedia {
    static func clip(for snippet: Snippet, recorder: SegmentedScreenRecorder, into directory: URL) async -> ExportedClip? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try? await recorder.exportClip(from: snippet.range.start, to: snippet.range.end, padding: 1.0, into: directory.appendingPathComponent("clip.mp4"))
    }

    static func clip(for snippet: Snippet, video: ExportedClip, into directory: URL) async -> ExportedClip? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = max(0, snippet.range.start - 1 - video.range.start)
        let end = min(video.range.duration, snippet.range.end + 1 - video.range.start)
        let clipURL = directory.appendingPathComponent("clip.mp4")
        try? FileManager.default.removeItem(at: clipURL)
        guard end > start, let export = AVAssetExportSession(asset: AVURLAsset(url: video.url), presetName: AVAssetExportPresetPassthrough) else { return nil }
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        guard (try? await export.export(to: clipURL, as: .mp4)) != nil else { return nil }
        return ExportedClip(url: clipURL, range: TimeRange(start: video.range.start + start, end: video.range.start + end))
    }

    static func attachments(for snippet: Snippet, recorder: SegmentedScreenRecorder, into directory: URL, clip includesClip: Bool = true, redaction: ClipRedaction? = nil) async -> [ComposedTask.Attachment] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var attachments: [ComposedTask.Attachment] = []
        if includesClip, let clip = await clip(for: snippet, recorder: recorder, into: directory) {
            attachments.append(.init(kind: .video, url: clip.url))
        }
        for (index, mark) in snippet.marks.enumerated() {
            guard redaction?.cuts(mark.at) != true,
                  let display = recorder.displays?.display(at: mark.at), display.frame.contains(CGPoint(x: mark.point.x, y: mark.point.y)),
                  let captured = await recorder.snapshot(at: mark.at)
            else { continue }
            let frame = ClipRedactor.covered(captured, regions: redaction?.regions(at: mark.at) ?? [])
            let image = shot(frame, mark: mark, display: display)
            let url = directory.appendingPathComponent("pin-\(index + 1).png")
            if write(image, to: url) { attachments.append(.init(kind: .image, url: url)) }
        }
        return attachments
    }

    static func attachments(for snippet: Snippet, video: ExportedClip, displays: CaptureDisplays?, into directory: URL, clip includesClip: Bool = true, redaction: ClipRedaction? = nil) async -> [ComposedTask.Attachment] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var attachments: [ComposedTask.Attachment] = []
        if includesClip, let clip = await clip(for: snippet, video: video, into: directory) {
            attachments.append(.init(kind: .video, url: clip.url))
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video.url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        for (index, mark) in snippet.marks.enumerated() {
            guard redaction?.cuts(mark.at) != true else { continue }
            let time = CMTime(seconds: max(0, mark.at - video.range.start), preferredTimescale: 600)
            guard let captured = try? await generator.image(at: time).image else { continue }
            let frame = ClipRedactor.covered(captured, regions: redaction?.regions(at: mark.at) ?? [])
            let display = displays?.display(at: mark.at)
            let onDisplay = display.map { $0.frame.contains(CGPoint(x: mark.point.x, y: mark.point.y)) } ?? false
            let image = onDisplay ? display.map { shot(frame, mark: mark, display: $0) } ?? frame : display?.cropped(frame) ?? frame
            let url = directory.appendingPathComponent("pin-\(index + 1).png")
            if write(image, to: url) { attachments.append(.init(kind: .image, url: url)) }
        }
        return attachments
    }

    static func optimiseAttachments(for card: SnippetCard, existing: [ComposedTask.Attachment], into directory: URL) async throws -> [ComposedTask.Attachment] {
        guard let selection = card.optimiseAttachments else { return existing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marks = card.deliverableSnippet.marks
        var result = existing.filter { !$0.url.lastPathComponent.hasPrefix("optimise-") }.filter { attachment in
            guard attachment.url.lastPathComponent.hasPrefix("pin-"), let number = Int(attachment.url.deletingPathExtension().lastPathComponent.dropFirst(4)), marks.indices.contains(number - 1) else { return true }
            return !(selection.excludedFrames ?? []).contains(Walkthrough.milliseconds(marks[number - 1].at))
        }
        if let video = card.sessionVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video.url))
            generator.maximumSize = CGSize(width: 1600, height: 1600)
            generator.appliesPreferredTrackTransform = true
            for milliseconds in selection.frames {
                let time = CMTime(seconds: max(0, Double(milliseconds) / 1000 - video.range.start), preferredTimescale: 600)
                let image = try await generator.image(at: time).image
                let url = directory.appendingPathComponent("optimise-\(milliseconds).png")
                if write(image, to: url) { result.append(.init(kind: .image, url: url)) }
            }
        }
        if card.sessionVideo == nil {
            for milliseconds in selection.frames {
                guard let path = selection.frameFiles?[milliseconds] else { continue }
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) { result.append(.init(kind: .image, url: url)) }
            }
        }
        let pointerFile = directory.appendingPathComponent("optimise-evidence.json")
        try JSONEncoder().encode(selection).write(to: pointerFile, options: .atomic)
        result.append(.init(kind: .file, url: pointerFile))
        return result
    }

    private static func shot(_ frame: CGImage, mark: Mark, display: CaptureDisplay) -> CGImage {
        let image = outlined(frame, mark: mark, display: display) ?? frame
        return display.cropped(image) ?? image
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
