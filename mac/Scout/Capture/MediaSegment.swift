import Foundation
import ScoutCore

nonisolated struct MediaSegment: Sendable, Hashable, Codable {
    let sequence: Int
    let url: URL
    let range: TimeRange
    let byteCount: Int

    func overlaps(_ other: TimeRange) -> Bool {
        range.end > other.start && range.start < other.end
    }
}

nonisolated struct ExportedClip: Sendable, Hashable {
    let url: URL
    let range: TimeRange
}

nonisolated struct CaptureStatistics: Sendable, Hashable, Codable {
    var framesCaptured = 0
    var framesAppended = 0
    var framesRepeated = 0
    var framesDropped = 0
    var visualSamples = 0
    var visualSampleMicroseconds = 0.0

    var averageVisualSampleMicroseconds: Double {
        visualSamples == 0 ? 0 : visualSampleMicroseconds / Double(visualSamples)
    }
}
