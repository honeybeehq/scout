import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ScoutCore
import UniformTypeIdentifiers

nonisolated struct MediaView: Sendable, Equatable {
    let bbox: Rect
    let display: String
}

nonisolated protocol WalkthroughMedia: Sendable {
    var displays: [Walkthrough.Display] { get }
    func view(at time: SessionTime) -> MediaView?
    func frame(at time: SessionTime) async -> CGImage?
    func exportClip(through end: SessionTime, to destination: URL) async -> Walkthrough.Clip?
}

nonisolated extension CaptureDisplays {
    func view(at time: SessionTime) -> MediaView {
        let display = display(at: time)
        return MediaView(bbox: Rect(display.frame), display: String(display.displayID))
    }

    var walkthroughDisplays: [Walkthrough.Display] {
        used.map { Walkthrough.Display(id: String($0.displayID), bounds: Walkthrough.Box(Rect($0.frame)), scale: $0.pointPixelScale) }
    }

    func clipped(_ clip: Walkthrough.Clip?, startingAt clipStart: SessionTime) -> Walkthrough.Clip? {
        guard var clip else { return nil }
        let first = display(at: clipStart)
        let later = spans.filter { $0.start > clipStart && Walkthrough.milliseconds($0.start - clipStart) < clip.duration }
        let shown = [Span(start: clipStart, display: first)] + later
        clip.bbox = Walkthrough.Box(Rect(first.frame))
        clip.displays = shown.count > 1
            ? shown.map { Walkthrough.ClipDisplay(t: Walkthrough.milliseconds($0.start - clipStart), display: String($0.display.displayID), bbox: Walkthrough.Box(Rect($0.display.frame))) }
            : nil
        return clip
    }
}

nonisolated struct LiveWalkthroughMedia: WalkthroughMedia {
    let recorder: SegmentedScreenRecorder

    var displays: [Walkthrough.Display] {
        recorder.displays?.walkthroughDisplays ?? []
    }

    func view(at time: SessionTime) -> MediaView? {
        recorder.displays?.view(at: time)
    }

    func frame(at time: SessionTime) async -> CGImage? {
        let wait = time - recorder.sessionTimeNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard let image = await recorder.snapshot(at: time) else { return nil }
        return recorder.displays?.display(at: time).cropped(image) ?? image
    }

    func exportClip(through end: SessionTime, to destination: URL) async -> Walkthrough.Clip? {
        guard let clip = try? await recorder.exportClip(from: 0, to: end, padding: 0, into: destination) else { return nil }
        let made = await WalkthroughImages.clip(at: clip.url, bbox: nil)
        return recorder.displays?.clipped(made, startingAt: clip.range.start) ?? made
    }
}

nonisolated struct FixtureWalkthroughMedia: WalkthroughMedia {
    let video: URL
    let screen: Rect
    let offset: SessionTime
    var hops: CaptureDisplays?

    var displays: [Walkthrough.Display] {
        hops?.walkthroughDisplays ?? [Walkthrough.Display(id: "fixture", bounds: Walkthrough.Box(screen), scale: 1)]
    }

    func view(at time: SessionTime) -> MediaView? {
        hops?.view(at: time) ?? MediaView(bbox: screen, display: "fixture")
    }

    func frame(at time: SessionTime) async -> CGImage? {
        let asset = AVURLAsset(url: video)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let image = try? await generator.image(at: CMTime(seconds: min(max(0, time - offset), max(0, duration - 0.1)), preferredTimescale: 600)).image else { return nil }
        return hops?.display(at: time).cropped(image) ?? image
    }

    func exportClip(through end: SessionTime, to destination: URL) async -> Walkthrough.Clip? {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration).seconds,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { return nil }
        export.timeRange = CMTimeRange(start: .zero, end: CMTime(seconds: min(duration, max(0, end - offset)), preferredTimescale: 600))
        try? FileManager.default.removeItem(at: destination)
        guard (try? await export.export(to: destination, as: .mp4)) != nil else { return nil }
        let made = await WalkthroughImages.clip(at: destination, bbox: screen)
        return hops.map { $0.clipped(made, startingAt: offset) } ?? made
    }
}

nonisolated enum WalkthroughImages {
    static let frameLongEdge = 1600
    static let thumbLongEdge = 320

    static func write(_ image: CGImage, frame: URL, thumb: URL) -> Bool {
        guard let full = scaled(image, longEdge: frameLongEdge),
              encode(full, as: .png, to: frame, quality: nil),
              let small = scaled(image, longEdge: thumbLongEdge)
        else { return false }
        return encode(small, as: .jpeg, to: thumb, quality: 0.8)
    }

    static func pixelWidth(of image: CGImage) -> Int {
        let long = max(image.width, image.height)
        return long > frameLongEdge ? Int((Double(image.width) * Double(frameLongEdge) / Double(long)).rounded()) : image.width
    }

    static func clip(at url: URL, bbox: Rect?) async -> Walkthrough.Clip? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        else { return nil }
        let audio = (try? await asset.loadTracks(withMediaType: .audio).isEmpty == false) ?? false
        return Walkthrough.Clip(duration: Walkthrough.milliseconds(duration), sizeBytes: size, hasAudio: audio, bbox: bbox.map(Walkthrough.Box.init))
    }

    private static func scaled(_ image: CGImage, longEdge: Int) -> CGImage? {
        let long = max(image.width, image.height)
        guard long > longEdge else { return image }
        let factor = Double(longEdge) / Double(long)
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, as type: UTType, to url: URL, quality: Double?) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination)
    }
}
