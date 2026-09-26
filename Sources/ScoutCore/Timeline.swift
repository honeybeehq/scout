import Foundation

public typealias SessionTime = Double

public struct TimeRange: Codable, Hashable, Sendable {
    public var start: SessionTime
    public var end: SessionTime

    public init(start: SessionTime, end: SessionTime) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: Double { end - start }

    public func contains(_ time: SessionTime) -> Bool {
        time >= start && time <= end
    }

    public func overlap(with other: TimeRange) -> Double {
        max(0, min(end, other.end) - max(start, other.start))
    }

    public func union(_ other: TimeRange) -> TimeRange {
        TimeRange(start: min(start, other.start), end: max(end, other.end))
    }
}

public struct Point: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Rect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(_ point: Point) -> Bool {
        point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
    }
}
