import AVFoundation
import CoreGraphics
import Foundation
import ScoutCore

nonisolated enum ClipCutter {
    private static let timescale: CMTimeScale = 90_000

    static func export(_ range: TimeRange, initSegment: URL, segments: [MediaSegment], to destination: URL) async throws {
        let fragments = try assemble(initSegment: initSegment, segments: segments)
        defer { try? FileManager.default.removeItem(at: fragments) }
        let asset = AVURLAsset(url: fragments)
        let timeline = try await Timeline(asset: asset, firstSegmentStart: segments[0].range.start)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ScreenCaptureError.exportFailed("passthrough export isn't available for this recording.")
        }
        session.timeRange = CMTimeRange(
            start: timeline.assetTime(range.start),
            duration: CMTime(seconds: range.duration, preferredTimescale: timescale)
        )
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        do {
            try await session.export(to: destination, as: .mp4)
        } catch {
            throw ScreenCaptureError.exportFailed(error.localizedDescription)
        }
    }

    static func frame(at time: SessionTime, initSegment: URL, segments: [MediaSegment]) async throws -> CGImage {
        let fragments = try assemble(initSegment: initSegment, segments: segments)
        defer { try? FileManager.default.removeItem(at: fragments) }
        let asset = AVURLAsset(url: fragments)
        let timeline = try await Timeline(asset: asset, firstSegmentStart: segments[0].range.start)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: timeline.assetTime(time)).image
    }

    private static func assemble(initSegment: URL, segments: [MediaSegment]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "scout-fragments-\(UUID().uuidString).mp4")
        try Data(contentsOf: initSegment).write(to: url)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.seekToEnd()
        for segment in segments {
            try output.write(contentsOf: Data(contentsOf: segment.url))
        }
        return url
    }

    private struct Timeline {
        let offset: Double

        init(asset: AVURLAsset, firstSegmentStart: SessionTime) async throws {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ScreenCaptureError.exportFailed("the recording has no video track.")
            }
            let trackStart = try await track.load(.timeRange).start.seconds
            offset = trackStart - firstSegmentStart
        }

        func assetTime(_ time: SessionTime) -> CMTime {
            CMTime(seconds: time + offset, preferredTimescale: ClipCutter.timescale)
        }
    }
}
