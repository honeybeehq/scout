import Foundation

public enum CaptureScope: String, Codable, Hashable, Sendable {
    case follow, pair, window, screen
}

public struct CaptureRegion: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case pane, window, display
    }

    public var id: String
    public var kind: Kind
    public var bounds: Rect
    public var label: String
    public var displayID: UInt32
    public var displayBounds: Rect
    public var windowBounds: Rect?

    public init(id: String, kind: Kind, bounds: Rect, label: String, displayID: UInt32, displayBounds: Rect, windowBounds: Rect? = nil) {
        self.id = id
        self.kind = kind
        self.bounds = bounds
        self.label = label
        self.displayID = displayID
        self.displayBounds = displayBounds
        self.windowBounds = windowBounds
    }
}

public struct ScopeChange: Codable, Hashable, Sendable {
    public var at: SessionTime
    public var scope: CaptureScope
    public var bounds: Rect
    public var displayID: UInt32?
    public var region: String?
    public var byUser: Bool

    public init(at: SessionTime, scope: CaptureScope, bounds: Rect, displayID: UInt32?, region: String?, byUser: Bool) {
        self.at = at
        self.scope = scope
        self.bounds = bounds
        self.displayID = displayID
        self.region = region
        self.byUser = byUser
    }
}

public struct StrokePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var at: SessionTime

    public init(x: Double, y: Double, at: SessionTime) {
        self.x = x
        self.y = y
        self.at = at
    }
}

public struct Stroke: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var start: SessionTime
    public var end: SessionTime
    public var points: [StrokePoint]
    public var bounds: Rect
    public var color: String
    public var width: Double

    public init(id: String, points: [StrokePoint], color: String, width: Double) {
        self.id = id
        self.points = points
        self.color = color
        self.width = width
        start = points.first?.at ?? 0
        end = points.last?.at ?? start
        bounds = Rect.enclosing(points.map { Point(x: $0.x, y: $0.y) })
    }
}

public struct CaptureTimeline: Codable, Hashable, Sendable {
    public var scopes: [ScopeChange] = []
    public var strokes: [Stroke] = []

    public init() {}
}

public struct ScopeMachine: Sendable {
    public struct Suggestion: Hashable, Sendable {
        public var first: CaptureRegion
        public var second: CaptureRegion
        public var bounds: Rect
        public var until: SessionTime
    }

    public static let dwell: SessionTime = 0.25
    public static let backAndForthWindow: SessionTime = 6
    public static let suggestionLifetime: SessionTime = 4

    public private(set) var scope: CaptureScope = .follow
    public private(set) var followed: CaptureRegion?
    public private(set) var bounds: Rect?
    public private(set) var displayID: UInt32?
    public private(set) var suggestion: Suggestion?
    public private(set) var underPointer: CaptureRegion?

    private var previous: CaptureRegion?
    private var pending: (region: CaptureRegion, since: SessionTime)?
    private var visits: [(id: String, at: SessionTime)] = []
    private var pair: (CaptureRegion, CaptureRegion)?

    public init() {}

    public var label: String {
        switch scope {
        case .follow: followed?.label ?? ""
        case .pair: "Both areas"
        case .window: "Window"
        case .screen: "Screen"
        }
    }

    public mutating func pointer(over region: CaptureRegion?, at now: SessionTime) -> ScopeChange? {
        if let suggestion, now >= suggestion.until { self.suggestion = nil }
        underPointer = region
        guard let region else {
            pending = nil
            return nil
        }
        switch scope {
        case .follow:
            guard let followed else { return settle(on: region, at: now) }
            if followed.id == region.id {
                pending = nil
                return followed.bounds == region.bounds ? nil : settle(on: region, at: now)
            }
            if let pending, pending.region.id == region.id {
                return now - pending.since >= Self.dwell ? settle(on: region, at: now) : nil
            }
            pending = (region, now)
            return nil
        case .screen:
            guard region.displayID != displayID else { return nil }
            return apply(.screen, bounds: region.displayBounds, displayID: region.displayID, region: nil, at: now, byUser: false)
        case .pair, .window:
            return nil
        }
    }

    public mutating func expand(at now: SessionTime) -> ScopeChange? {
        guard let anchor = underPointer ?? followed else { return nil }
        let current = bounds
        var next = scope
        for _ in 0..<4 {
            next = Self.after(next)
            guard let candidate = target(for: next, anchor: anchor) else { continue }
            if next == .follow || candidate.bounds != current {
                pair = next == .pair ? pairRegions(anchor: anchor) : nil
                suggestion = nil
                if next == .follow {
                    return follow(at: now)
                }
                return apply(next, bounds: candidate.bounds, displayID: candidate.displayID, region: nil, at: now, byUser: true)
            }
        }
        return nil
    }

    public mutating func follow(at now: SessionTime) -> ScopeChange? {
        suggestion = nil
        pair = nil
        pending = nil
        let region = underPointer ?? followed
        guard let region else {
            scope = .follow
            return nil
        }
        if scope == .follow, followed?.id == region.id { return nil }
        if let followed, followed.id != region.id { previous = followed }
        followed = region
        return apply(.follow, bounds: region.bounds, displayID: region.displayID, region: region.label, at: now, byUser: true)
    }

    private static func after(_ scope: CaptureScope) -> CaptureScope {
        switch scope {
        case .follow: .pair
        case .pair: .window
        case .window: .screen
        case .screen: .follow
        }
    }

    private func target(for scope: CaptureScope, anchor: CaptureRegion) -> (bounds: Rect, displayID: UInt32)? {
        switch scope {
        case .follow:
            return (anchor.bounds, anchor.displayID)
        case .pair:
            guard let (a, b) = pairRegions(anchor: anchor) else { return nil }
            return (a.bounds.union(b.bounds).intersection(a.displayBounds) ?? a.bounds, a.displayID)
        case .window:
            guard let window = anchor.windowBounds ?? (anchor.kind == .window ? anchor.bounds : nil) else { return nil }
            return (window, anchor.displayID)
        case .screen:
            return (anchor.displayBounds, anchor.displayID)
        }
    }

    private func pairRegions(anchor: CaptureRegion) -> (CaptureRegion, CaptureRegion)? {
        if let suggestion { return (suggestion.first, suggestion.second) }
        if let pair { return pair }
        let current = followed ?? anchor
        guard let other = previous, other.id != current.id, other.displayID == current.displayID else { return nil }
        return (other, current)
    }

    private mutating func settle(on region: CaptureRegion, at now: SessionTime) -> ScopeChange? {
        pending = nil
        if let followed, followed.id != region.id { previous = followed }
        followed = region
        noteVisit(region, at: now)
        return apply(.follow, bounds: region.bounds, displayID: region.displayID, region: region.label, at: now, byUser: false)
    }

    private mutating func noteVisit(_ region: CaptureRegion, at now: SessionTime) {
        if visits.last?.id != region.id { visits.append((region.id, now)) }
        visits.removeAll { now - $0.at > Self.backAndForthWindow }
        guard visits.count >= 3 else { return }
        let last = visits.suffix(3).map(\.id)
        guard last[0] == last[2], last[0] != last[1], let previous, previous.displayID == region.displayID else { return }
        suggestion = Suggestion(
            first: previous,
            second: region,
            bounds: previous.bounds.union(region.bounds),
            until: now + Self.suggestionLifetime
        )
    }

    private mutating func apply(_ scope: CaptureScope, bounds: Rect, displayID: UInt32, region: String?, at now: SessionTime, byUser: Bool) -> ScopeChange? {
        let changed = scope != self.scope || bounds != self.bounds || displayID != self.displayID
        self.scope = scope
        self.bounds = bounds
        self.displayID = displayID
        guard changed else { return nil }
        return ScopeChange(at: now, scope: scope, bounds: bounds, displayID: displayID, region: region, byUser: byUser)
    }
}

extension Rect {
    public static func enclosing(_ points: [Point]) -> Rect {
        guard let first = points.first else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func union(_ other: Rect) -> Rect {
        let minX = min(x, other.x), minY = min(y, other.y)
        return Rect(x: minX, y: minY, width: max(x + width, other.x + other.width) - minX, height: max(y + height, other.y + other.height) - minY)
    }

    public func intersection(_ other: Rect) -> Rect? {
        let minX = max(x, other.x), minY = max(y, other.y)
        let maxX = min(x + width, other.x + other.width), maxY = min(y + height, other.y + other.height)
        guard maxX > minX, maxY > minY else { return nil }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
