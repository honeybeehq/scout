import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScoutCore
@preconcurrency import ScreenCaptureKit

nonisolated struct CaptureDisplay: Sendable, Hashable, Codable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let pointPixelScale: Double
    let videoWidth: Int
    let videoHeight: Int

    var contentRect: CGRect {
        let video = CGSize(width: videoWidth, height: videoHeight)
        guard frame.width > 0, frame.height > 0 else { return CGRect(origin: .zero, size: video) }
        let fit = min(video.width / frame.width, video.height / frame.height)
        let size = CGSize(width: frame.width * fit, height: frame.height * fit)
        return CGRect(x: (video.width - size.width) / 2, y: (video.height - size.height) / 2, width: size.width, height: size.height)
    }

    func videoPoint(forScreenPoint point: CGPoint) -> CGPoint {
        let content = contentRect
        return CGPoint(
            x: content.minX + (point.x - frame.minX) * content.width / frame.width,
            y: content.minY + (point.y - frame.minY) * content.height / frame.height
        )
    }

    func cropped(_ image: CGImage) -> CGImage? {
        let content = contentRect
        let scaleX = Double(image.width) / Double(videoWidth)
        let scaleY = Double(image.height) / Double(videoHeight)
        let rect = CGRect(x: content.minX * scaleX, y: content.minY * scaleY, width: content.width * scaleX, height: content.height * scaleY).integral
        guard rect.width < Double(image.width) - 1 || rect.height < Double(image.height) - 1 else { return image }
        return image.cropping(to: rect)
    }
}

nonisolated struct CaptureDisplays: Sendable, Hashable, Codable {
    struct Hop: Sendable, Hashable, Codable {
        let at: SessionTime
        let display: CaptureDisplay
    }

    struct Span: Sendable, Hashable {
        let start: SessionTime
        let display: CaptureDisplay
    }

    let start: CaptureDisplay
    let hops: [Hop]

    init(start: CaptureDisplay, hops: [Hop] = []) {
        self.start = start
        self.hops = hops
    }

    func display(at time: SessionTime) -> CaptureDisplay {
        hops.last { $0.at <= time }?.display ?? start
    }

    var spans: [Span] {
        var spans = [Span(start: 0, display: start)]
        for hop in hops where hop.display != spans.last?.display {
            spans.append(Span(start: hop.at, display: hop.display))
        }
        return spans
    }

    var used: [CaptureDisplay] {
        var seen: Set<CGDirectDisplayID> = []
        return spans.map(\.display).filter { seen.insert($0.displayID).inserted }
    }
}

nonisolated struct CaptureTarget: @unchecked Sendable {
    let display: CaptureDisplay
    let filter: SCContentFilter

    static func displayUnderPointer(maxLongEdge: Int) async throws -> (target: CaptureTarget, content: SCShareableContent) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let displays = content.displays
        guard let display = displays.first(where: { CGDisplayBounds($0.displayID).contains(pointer) })
            ?? displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? displays.first
        else { throw ScreenCaptureError.noDisplay }
        return (make(display: display, content: content, maxLongEdge: maxLongEdge), content)
    }

    static func make(display: SCDisplay, content: SCShareableContent, maxLongEdge: Int, videoSize fixed: (width: Int, height: Int)? = nil) -> CaptureTarget {
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let scout = content.applications.filter { $0.processID == ownProcess }
        let filter = SCContentFilter(display: display, excludingApplications: scout, exceptingWindows: [])
        let info = SCShareableContent.info(for: filter)
        let scale = Double(info.pointPixelScale)
        let pointSize = info.contentRect.size
        let size = fixed ?? videoSize(pixelWidth: pointSize.width * scale, pixelHeight: pointSize.height * scale, maxLongEdge: maxLongEdge)
        let captured = CaptureDisplay(
            displayID: display.displayID,
            frame: CGDisplayBounds(display.displayID),
            pointPixelScale: scale,
            videoWidth: size.width,
            videoHeight: size.height
        )
        return CaptureTarget(display: captured, filter: filter)
    }

    func streamConfiguration(framesPerSecond: Int32) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = display.videoWidth
        configuration.height = display.videoHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.queueDepth = 6
        return configuration
    }

    private static func videoSize(pixelWidth: Double, pixelHeight: Double, maxLongEdge: Int) -> (width: Int, height: Int) {
        let longEdge = max(pixelWidth, pixelHeight)
        let factor = longEdge > Double(maxLongEdge) ? Double(maxLongEdge) / longEdge : 1
        func even(_ value: Double) -> Int { max(2, Int((value * factor / 2).rounded()) * 2) }
        return (even(pixelWidth), even(pixelHeight))
    }
}
