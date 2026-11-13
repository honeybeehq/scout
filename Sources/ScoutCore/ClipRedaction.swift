import Foundation

public struct RedactedRegion: Codable, Hashable, Sendable, Identifiable {
    public enum Origin: Codable, Hashable, Sendable {
        case user
        case detector(String)
    }

    public var id: String
    public var rect: Rect
    public var range: TimeRange?
    public var origin: Origin

    public init(id: String = UUID().uuidString, rect: Rect, range: TimeRange? = nil, origin: Origin = .user) {
        self.id = id
        self.rect = RedactedRegion.clamped(rect)
        self.range = range
        self.origin = origin
    }

    public func isActive(at time: SessionTime) -> Bool {
        range?.contains(time) ?? true
    }

    public static func clamped(_ rect: Rect) -> Rect {
        let x = min(max(0, rect.x), 1)
        let y = min(max(0, rect.y), 1)
        return Rect(x: x, y: y, width: min(max(0, rect.width), 1 - x), height: min(max(0, rect.height), 1 - y))
    }
}

public struct ClipRedaction: Codable, Hashable, Sendable {
    public var excluded: [TimeRange]
    public var regions: [RedactedRegion]

    public init(excluded: [TimeRange] = [], regions: [RedactedRegion] = []) {
        self.excluded = excluded
        self.regions = regions
    }

    public var isEmpty: Bool {
        excluded.isEmpty && regions.isEmpty
    }

    public func regions(at time: SessionTime) -> [RedactedRegion] {
        regions.filter { $0.isActive(at: time) }
    }

    public func cuts(_ time: SessionTime) -> Bool {
        excluded.contains { $0.contains(time) }
    }

    public func regions(near time: SessionTime, within slack: Double) -> [RedactedRegion] {
        regions.filter { region in
            guard let range = region.range else { return true }
            return range.start <= time + slack && range.end >= time - slack
        }
    }

    public func cuts(near time: SessionTime, within slack: Double) -> Bool {
        excluded.contains { $0.start <= time + slack && $0.end >= time - slack }
    }

    public func kept(in range: TimeRange) -> [TimeRange] {
        var kept: [TimeRange] = []
        var cursor = range.start
        for cut in mergedCuts(in: range) {
            if cut.start > cursor { kept.append(TimeRange(start: cursor, end: cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if range.end > cursor { kept.append(TimeRange(start: cursor, end: range.end)) }
        return kept.filter { $0.duration >= 0.05 }
    }

    public func keptDuration(in range: TimeRange) -> Double {
        kept(in: range).reduce(0) { $0 + $1.duration }
    }

    public func mergedCuts(in range: TimeRange) -> [TimeRange] {
        let clipped = excluded
            .map { TimeRange(start: max($0.start, range.start), end: min($0.end, range.end)) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        var merged: [TimeRange] = []
        for cut in clipped {
            if let last = merged.last, cut.start <= last.end {
                merged[merged.count - 1] = TimeRange(start: last.start, end: max(last.end, cut.end))
            } else {
                merged.append(cut)
            }
        }
        return merged
    }

    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }
}
