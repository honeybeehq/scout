import AVFoundation
import CoreImage
import Foundation
import ScoutCore

nonisolated struct RenderedMedia: Sendable, Hashable {
    let url: URL
    let range: TimeRange
    let duration: Double
    let byteCount: Int
    let redaction: ClipRedaction?

    fileprivate init(url: URL, range: TimeRange, duration: Double, redaction: ClipRedaction?) {
        self.url = url
        self.range = range
        self.duration = duration
        self.redaction = redaction
        byteCount = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    var isRedacted: Bool { redaction != nil }

    var hiddenParts: Int {
        (redaction?.regions.count ?? 0) + (redaction?.mergedCuts(in: range).count ?? 0)
    }
}

nonisolated enum ClipRedactor {
    static let fill = CIColor(red: 0.075, green: 0.082, blue: 0.106)
    static let edge = CIColor(red: 0.22, green: 0.235, blue: 0.282)
    static let fillCG = CGColor(srgbRed: 0.075, green: 0.082, blue: 0.106, alpha: 1)
    static let edgeCG = CGColor(srgbRed: 0.22, green: 0.235, blue: 0.282, alpha: 1)

    enum Failure: Error {
        case nothingLeft
        case noVideoTrack
        case exportFailed(String)
    }

    static func render(_ clip: ExportedClip, redaction: ClipRedaction?) async throws -> RenderedMedia {
        guard let redaction, !redaction.isEmpty else {
            return RenderedMedia(url: clip.url, range: clip.range, duration: clip.range.duration, redaction: nil)
        }
        let kept = redaction.kept(in: clip.range)
        guard !kept.isEmpty else { throw Failure.nothingLeft }
        let directory = clip.url.deletingLastPathComponent()
        let key = Dispatcher.fingerprint("\(clip.range.start)|\(clip.range.end)|\(redaction.fingerprint)")
        let output = directory.appendingPathComponent("clip-redacted-\(key).mp4")
        if FileManager.default.fileExists(atPath: output.path) {
            return RenderedMedia(url: output, range: clip.range, duration: kept.reduce(0) { $0 + $1.duration }, redaction: redaction)
        }
        for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent.hasPrefix("clip-redacted-") {
            try? FileManager.default.removeItem(at: old)
        }

        let source = AVURLAsset(url: clip.url)
        guard let track = try await source.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let trackRange = try await track.load(.timeRange)
        let composition = AVMutableComposition()
        guard let lane = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Failure.noVideoTrack }
        var cursor = CMTime.zero
        var spans: [Span] = []
        for range in kept {
            let start = CMTime(seconds: range.start - clip.range.start, preferredTimescale: 600)
            let end = CMTimeMinimum(CMTime(seconds: range.end - clip.range.start, preferredTimescale: 600), trackRange.end)
            guard end > start else { continue }
            let piece = CMTimeRange(start: start, end: end)
            try lane.insertTimeRange(piece, of: track, at: cursor)
            spans.append(Span(compositionStart: cursor.seconds, sessionStart: range.start))
            cursor = cursor + piece.duration
        }
        guard cursor > .zero else { throw Failure.nothingLeft }
        lane.preferredTransform = try await track.load(.preferredTransform)

        let regions = redaction.regions
        let spanList = spans
        let video = try await AVVideoComposition(applyingFiltersTo: composition) { parameters in
            let seconds = parameters.compositionTime.seconds
            let span = spanList.last { $0.compositionStart <= seconds + 0.0005 } ?? spanList[0]
            let time = span.sessionStart + seconds - span.compositionStart
            let active = regions.filter { $0.isActive(at: time) }
            return AVCIImageFilteringResult(resultImage: covered(parameters.sourceImage, regions: active))
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw Failure.exportFailed("HEVC export isn't available on this Mac.")
        }
        export.videoComposition = video
        let partial = directory.appendingPathComponent("clip-redacting.mp4")
        try? FileManager.default.removeItem(at: partial)
        do {
            try await export.export(to: partial, as: .mp4)
            try FileManager.default.moveItem(at: partial, to: output)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw Failure.exportFailed(error.localizedDescription)
        }
        return RenderedMedia(url: output, range: clip.range, duration: cursor.seconds, redaction: redaction)
    }

    static func covered(_ image: CIImage, regions: [RedactedRegion]) -> CIImage {
        guard !regions.isEmpty else { return image }
        let extent = image.extent
        let border = max(2, extent.width / 960)
        var result = image
        for region in regions {
            let rect = pixelRect(region.rect, in: extent.size, flipped: true).offsetBy(dx: extent.minX, dy: extent.minY)
            let outer = CIImage(color: edge).cropped(to: rect)
            let inner = CIImage(color: fill).cropped(to: rect.insetBy(dx: border, dy: border))
            result = inner.composited(over: outer).composited(over: result)
        }
        return result.cropped(to: extent)
    }

    static func covered(_ image: CGImage, regions: [RedactedRegion]) -> CGImage {
        guard !regions.isEmpty,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return image }
        let size = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        let border = max(2, size.width / 960)
        for region in regions {
            let rect = pixelRect(region.rect, in: size, flipped: true)
            context.setFillColor(edgeCG)
            context.fill(rect)
            context.setFillColor(fillCG)
            context.fill(rect.insetBy(dx: border, dy: border))
        }
        return context.makeImage() ?? image
    }

    static func pixelRect(_ rect: Rect, in size: CGSize, flipped: Bool) -> CGRect {
        let x = rect.x * size.width
        let width = rect.width * size.width
        let height = rect.height * size.height
        let y = flipped ? size.height - (rect.y * size.height) - height : rect.y * size.height
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    private struct Span: Sendable {
        var compositionStart: Double
        var sessionStart: Double
    }
}
