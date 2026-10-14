import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ScoutCore
import UniformTypeIdentifiers

nonisolated protocol WalkthroughMedia: Sendable {
    var bounds: Rect? { get }
    var displays: [Walkthrough.Display] { get }
    func frame(at time: SessionTime) async -> CGImage?
    func exportClip(through end: SessionTime, to destination: URL) async -> Walkthrough.Clip?
}

nonisolated struct LiveWalkthroughMedia: WalkthroughMedia {
    let recorder: SegmentedScreenRecorder

    var bounds: Rect? {
        recorder.currentCaptureDisplay.map { Rect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height) }
    }

    var displays: [Walkthrough.Display] {
        recorder.displaysUsed.map { display in
            let frame = Walkthrough.Box(x: display.frame.minX, y: display.frame.minY, w: display.frame.width, h: display.frame.height)
            return Walkthrough.Display(id: String(display.displayID), bounds: frame, scale: display.pointPixelScale)
        }
    }

    func frame(at time: SessionTime) async -> CGImage? {
        let wait = time - recorder.sessionTimeNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        return await recorder.snapshot(at: time)
    }

    func exportClip(through end: SessionTime, to destination: URL) async -> Walkthrough.Clip? {
        guard let clip = try? await recorder.exportClip(from: 0, to: end, padding: 0, into: destination) else { return nil }
        return await WalkthroughImages.clip(at: clip.url, bbox: bounds)
    }
}

nonisolated struct FixtureWalkthroughMedia: WalkthroughMedia {
    let video: URL
    let screen: Rect
    let offset: SessionTime

    var bounds: Rect? { screen }

    var displays: [Walkthrough.Display] {
        [Walkthrough.Display(id: "fixture", bounds: Walkthrough.Box(screen), scale: 1)]
    }

    func frame(at time: SessionTime) async -> CGImage? {
        let asset = AVURLAsset(url: video)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: min(max(0, time - offset), max(0, duration - 0.1)), preferredTimescale: 600)).image
    }

    func exportClip(through end: SessionTime, to destination: URL) async -> Walkthrough.Clip? {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration).seconds,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { return nil }
        export.timeRange = CMTimeRange(start: .zero, end: CMTime(seconds: min(duration, max(0, end - offset)), preferredTimescale: 600))
        try? FileManager.default.removeItem(at: destination)
        guard (try? await export.export(to: destination, as: .mp4)) != nil else { return nil }
        return await WalkthroughImages.clip(at: destination, bbox: screen)
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
