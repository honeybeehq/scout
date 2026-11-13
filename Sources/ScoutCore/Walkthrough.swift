import Foundation

public struct Walkthrough: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ready
        case partial
    }

    public enum Availability: String, Codable, Sendable {
        case ready
        case unavailable
    }

    public enum Grant: String, Codable, Sendable {
        case granted
        case denied
    }

    public struct Box: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double

        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x
            self.y = y
            self.w = max(0, w)
            self.h = max(0, h)
        }

        public init(_ rect: Rect) {
            self.init(x: rect.x, y: rect.y, w: rect.width, h: rect.height)
        }
    }

    public struct Spot: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Recorder: Codable, Hashable, Sendable {
        public var app = "Scout"
        public var version: String
        public var platform: String
        public var osVersion: String?

        public init(version: String, platform: String, osVersion: String? = nil) {
            self.version = version
            self.platform = platform
            self.osVersion = osVersion
        }
    }

    public struct Permissions: Codable, Hashable, Sendable {
        public var screen: Grant?
        public var microphone: Grant?
        public var accessibility: Grant?

        public init(screen: Grant? = nil, microphone: Grant? = nil, accessibility: Grant? = nil) {
            self.screen = screen
            self.microphone = microphone
            self.accessibility = accessibility
        }
    }

    public struct Display: Codable, Hashable, Sendable {
        public var id: String
        public var bounds: Box
        public var scale: Double

        public init(id: String, bounds: Box, scale: Double) {
            self.id = id
            self.bounds = bounds
            self.scale = scale
        }
    }

    public enum Scope: String, Codable, Sendable {
        case follow
        case pair
        case window
        case screen
    }

    public struct ScopeChange: Codable, Hashable, Sendable {
        public var t: Int
        public var scope: Scope
        public var bounds: Box
        public var by: String?

        public init(t: Int, scope: Scope, bounds: Box, by: String? = nil) {
            self.t = t
            self.scope = scope
            self.bounds = bounds
            self.by = by
        }
    }

    public struct Microphone: Codable, Hashable, Sendable {
        public var device: String?
        public var sampleRate: Double?
        public var channels: Int?
        public var buffers: Int
        public var peakDb: Double?
        public var restarts: Int
        public var retries: Int
        public var channelMode: String?
        public var channelSwitches: Int?
        public var droppedBuffers: Int?
        public var unlearnedClasses: Int?

        public init(device: String? = nil, sampleRate: Double? = nil, channels: Int? = nil, buffers: Int, peakDb: Double? = nil, restarts: Int = 0, retries: Int = 0, channelMode: String? = nil, channelSwitches: Int? = nil, droppedBuffers: Int? = nil, unlearnedClasses: Int? = nil) {
            self.device = device
            self.sampleRate = sampleRate
            self.channels = channels
            self.buffers = buffers
            self.peakDb = peakDb
            self.restarts = restarts
            self.retries = retries
            self.channelMode = channelMode
            self.channelSwitches = channelSwitches
            self.droppedBuffers = droppedBuffers
            self.unlearnedClasses = unlearnedClasses
        }
    }

    public struct Capture: Codable, Hashable, Sendable {
        public var permissions: Permissions
        public var displays: [Display]?
        public var scopes: [ScopeChange]
        public var microphone: Microphone?

        public init(permissions: Permissions, displays: [Display]? = nil, scopes: [ScopeChange] = [], microphone: Microphone? = nil) {
            self.permissions = permissions
            self.displays = displays
            self.scopes = scopes
            self.microphone = microphone
        }
    }

    public struct AppMoment: Codable, Hashable, Sendable {
        public var t: Int
        public var bundleId: String?
        public var name: String?
        public var windowTitle: String?
        public var url: String?

        public init(t: Int, bundleId: String? = nil, name: String? = nil, windowTitle: String? = nil, url: String? = nil) {
            self.t = t
            self.bundleId = bundleId
            self.name = name
            self.windowTitle = windowTitle
            self.url = url
        }
    }

    public struct Project: Codable, Hashable, Sendable {
        public var root: String
        public var branch: String?

        public init(root: String, branch: String? = nil) {
            self.root = root
            self.branch = branch
        }
    }

    public struct Context: Codable, Hashable, Sendable {
        public var apps: [AppMoment]
        public var project: Project?

        public init(apps: [AppMoment], project: Project? = nil) {
            self.apps = apps
            self.project = project
        }
    }

    public struct TimedWord: Codable, Hashable, Sendable {
        public var text: String
        public var start: Int
        public var end: Int

        public init(text: String, start: Int, end: Int) {
            self.text = text
            self.start = start
            self.end = end
        }

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            text = try container.decode(String.self)
            start = try container.decode(Int.self)
            end = try container.decode(Int.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(text)
            try container.encode(start)
            try container.encode(end)
        }
    }

    public struct Segment: Codable, Hashable, Sendable {
        public var id: String
        public var start: Int
        public var end: Int
        public var text: String
        public var words: [TimedWord]?
        public var pointers: [String]?
        public var drawings: [String]?

        public init(id: String, start: Int, end: Int, text: String, words: [TimedWord]? = nil, pointers: [String]? = nil, drawings: [String]? = nil) {
            self.id = id
            self.start = start
            self.end = end
            self.text = text
            self.words = words
            self.pointers = pointers
            self.drawings = drawings
        }
    }

    public struct TranscriptFailure: Codable, Hashable, Sendable {
        public enum Reason: String, Codable, Sendable {
            case analyzerFailed
            case noWords
            case noAudio
            case micStopped
        }

        public var reason: Reason
        public var message: String?
        public var t: Int?

        public init(reason: Reason, message: String? = nil, t: Int? = nil) {
            self.reason = reason
            self.message = message
            self.t = t
        }
    }

    public struct TranscriptEvent: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case stall
            case dropped
            case restart
            case error
        }

        public var kind: Kind
        public var t: Int
        public var until: Int?
        public var words: Int?
        public var message: String?

        public init(kind: Kind, t: Int, until: Int? = nil, words: Int? = nil, message: String? = nil) {
            self.kind = kind
            self.t = t
            self.until = until
            self.words = words
            self.message = message
        }
    }

    public struct Transcript: Codable, Hashable, Sendable {
        public var status: Availability
        public var language: String?
        public var engine: String?
        public var failure: TranscriptFailure?
        public var events: [TranscriptEvent]?
        public var segments: [Segment]

        public init(status: Availability, language: String? = nil, engine: String? = nil, failure: TranscriptFailure? = nil, events: [TranscriptEvent]? = nil, segments: [Segment]) {
            self.status = status
            self.language = language
            self.engine = engine
            self.failure = failure
            self.events = events
            self.segments = segments
        }

        public var isIncomplete: Bool {
            failure != nil || !(events ?? []).isEmpty
        }
    }

    public enum FrameReason: String, Codable, Sendable {
        case start
        case pin
        case click
        case stroke
        case scope
        case scene
        case end
    }

    public struct Frame: Codable, Hashable, Sendable {
        public var id: String
        public var file: String
        public var thumb: String?
        public var t: Int
        public var bbox: Box
        public var scale: Double?
        public var display: String?
        public var reason: FrameReason
        public var pointers: [String]?
        public var drawings: [String]?

        public init(id: String, file: String, thumb: String?, t: Int, bbox: Box, scale: Double?, display: String? = nil, reason: FrameReason, pointers: [String]? = nil, drawings: [String]? = nil) {
            self.id = id
            self.file = file
            self.thumb = thumb
            self.t = t
            self.bbox = bbox
            self.scale = scale
            self.display = display
            self.reason = reason
            self.pointers = pointers
            self.drawings = drawings
        }
    }

    public enum Via: String, Codable, Sendable {
        case pin
        case click
        case dwell
        case stroke
    }

    public enum PointerSource: String, Codable, Sendable {
        case apiary
        case sdk
        case ax
        case none
    }

    public struct AXElement: Codable, Hashable, Sendable {
        public var role: String?
        public var title: String?
        public var app: String?
        public var bounds: Box?

        public init(role: String? = nil, title: String? = nil, app: String? = nil, bounds: Box? = nil) {
            self.role = role
            self.title = title
            self.app = app
            self.bounds = bounds
        }
    }

    public struct SDKElement: Codable, Hashable, Sendable {
        public var component: String?
        public var source: String?
        public var selector: String?

        public init(component: String? = nil, source: String? = nil, selector: String? = nil) {
            self.component = component
            self.source = source
            self.selector = selector
        }
    }

    public struct Pointer: Codable, Hashable, Sendable {
        public var id: String
        public var t: Int
        public var via: Via
        public var at: Spot
        public var frame: String?
        public var source: PointerSource
        public var label: String?
        public var stack: [JSONValue]?
        public var ax: AXElement?
        public var sdk: SDKElement?
        public var url: String?

        public init(id: String, t: Int, via: Via, at: Spot, frame: String? = nil, source: PointerSource, label: String? = nil, stack: [JSONValue]? = nil, ax: AXElement? = nil, sdk: SDKElement? = nil, url: String? = nil) {
            self.id = id
            self.t = t
            self.via = via
            self.at = at
            self.frame = frame
            self.source = source
            self.label = label
            self.stack = stack
            self.ax = ax
            self.sdk = sdk
            self.url = url
        }
    }

    public enum Shape: String, Codable, Sendable {
        case free
        case circle
        case arrow
        case underline
        case box
    }

    public struct Drawing: Codable, Hashable, Sendable {
        public var id: String
        public var t: Int
        public var end: Int
        public var points: [StrokePoint]
        public var bbox: Box
        public var color: String?
        public var width: Double?
        public var shape: Shape?
        public var near: String?
        public var frame: String?

        public init(id: String, t: Int, end: Int, points: [StrokePoint], bbox: Box, color: String? = nil, width: Double? = nil, shape: Shape? = nil, near: String? = nil, frame: String? = nil) {
            self.id = id
            self.t = t
            self.end = end
            self.points = points
            self.bbox = bbox
            self.color = color
            self.width = width
            self.shape = shape
            self.near = near
            self.frame = frame
        }
    }

    public struct StrokePoint: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var t: Int

        public init(x: Double, y: Double, t: Int) {
            self.x = x
            self.y = y
            self.t = t
        }

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            x = try container.decode(Double.self)
            y = try container.decode(Double.self)
            t = try container.decode(Int.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(x)
            try container.encode(y)
            try container.encode(t)
        }
    }

    public struct Ask: Codable, Hashable, Sendable {
        public var id: String
        public var text: String
        public var segments: [String]?
        public var pointers: [String]?
        public var drawings: [String]?
        public var frame: String?

        public init(id: String, text: String, segments: [String]? = nil, pointers: [String]? = nil, drawings: [String]? = nil, frame: String? = nil) {
            self.id = id
            self.text = text
            self.segments = segments
            self.pointers = pointers
            self.drawings = drawings
            self.frame = frame
        }
    }

    public struct Asks: Codable, Hashable, Sendable {
        public var status: Availability
        public var engine: String?
        public var items: [Ask]

        public init(status: Availability, engine: String? = nil, items: [Ask]) {
            self.status = status
            self.engine = engine
            self.items = items
        }
    }

    public struct Clip: Codable, Hashable, Sendable {
        public var file = "clip.mp4"
        public var duration: Int
        public var sizeBytes: Int
        public var hasAudio: Bool
        public var bbox: Box?
        public var displays: [ClipDisplay]?

        public init(duration: Int, sizeBytes: Int, hasAudio: Bool, bbox: Box? = nil, displays: [ClipDisplay]? = nil) {
            self.duration = duration
            self.sizeBytes = sizeBytes
            self.hasAudio = hasAudio
            self.bbox = bbox
            self.displays = displays
        }
    }

    public struct ClipDisplay: Codable, Hashable, Sendable {
        public var t: Int
        public var display: String
        public var bbox: Box

        public init(t: Int, display: String, bbox: Box) {
            self.t = t
            self.display = display
            self.bbox = bbox
        }
    }

    public enum EventKind: String, Codable, Sendable {
        case click
        case scope
        case navigate
        case appSwitch
        case key
        case `break`
    }

    public struct Event: Codable, Hashable, Sendable {
        public var t: Int
        public var kind: EventKind
        public var detail: String?

        public init(t: Int, kind: EventKind, detail: String? = nil) {
            self.t = t
            self.kind = kind
            self.detail = detail
        }
    }

    public var schema = "walkthrough.v1"
    public var id: String
    public var createdAt: String
    public var duration: Int
    public var title: String?
    public var status: Status
    public var recorder: Recorder
    public var capture: Capture
    public var context: Context?
    public var transcript: Transcript
    public var frames: [Frame]
    public var pointers: [Pointer]
    public var drawings: [Drawing]
    public var asks: Asks
    public var clip: Clip?
    public var events: [Event]?

    public init(
        id: String,
        createdAt: String,
        duration: Int,
        title: String?,
        status: Status,
        recorder: Recorder,
        capture: Capture,
        context: Context?,
        transcript: Transcript,
        frames: [Frame],
        pointers: [Pointer],
        drawings: [Drawing],
        asks: Asks,
        clip: Clip?,
        events: [Event]?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.title = title
        self.status = status
        self.recorder = recorder
        self.capture = capture
        self.context = context
        self.transcript = transcript
        self.frames = frames
        self.pointers = pointers
        self.drawings = drawings
        self.asks = asks
        self.clip = clip
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case schema, id, createdAt, duration, title, status, recorder, capture, context, transcript, frames, pointers, drawings, asks, clip, events
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encode(recorder, forKey: .recorder)
        try container.encode(capture, forKey: .capture)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(frames, forKey: .frames)
        try container.encode(pointers, forKey: .pointers)
        try container.encode(drawings, forKey: .drawings)
        try container.encode(asks, forKey: .asks)
        try container.encode(clip, forKey: .clip)
        try container.encodeIfPresent(events, forKey: .events)
    }

    public static func milliseconds(_ time: SessionTime) -> Int {
        max(0, Int((time * 1000).rounded()))
    }
}

public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
