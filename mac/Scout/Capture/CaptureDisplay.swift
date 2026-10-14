import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

nonisolated struct CaptureDisplay: Sendable, Hashable, Codable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let pointPixelScale: Double
    let videoWidth: Int
    let videoHeight: Int

    func videoPoint(forScreenPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - frame.minX) * Double(videoWidth) / frame.width,
            y: (point.y - frame.minY) * Double(videoHeight) / frame.height
        )
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
