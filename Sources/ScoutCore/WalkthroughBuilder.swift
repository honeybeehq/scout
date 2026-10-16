import Foundation

public struct WalkthroughBuilder: Sendable {
    public struct FrameRequest: Hashable, Sendable {
        public var time: SessionTime
        public var reason: Walkthrough.FrameReason
        public var file: String
        public var thumb: String
    }

    public struct StrokeSample: Hashable, Sendable {
        public var point: Point
        public var at: SessionTime

        public init(point: Point, at: SessionTime) {
            self.point = point
            self.at = at
        }
    }

    public struct Stroke: Hashable, Sendable {
        public var range: TimeRange
        public var samples: [StrokeSample]
        public var color: String?
        public var width: Double?

        public init(range: TimeRange, samples: [StrokeSample], color: String? = nil, width: Double? = nil) {
            self.range = range
            self.samples = samples
            self.color = color
            self.width = width
        }
    }

    public struct ScopeChange: Hashable, Sendable {
        public var at: SessionTime
        public var scope: Walkthrough.Scope
        public var bounds: Rect
        public var byUser: Bool

        public init(at: SessionTime, scope: Walkthrough.Scope, bounds: Rect, byUser: Bool) {
            self.at = at
            self.scope = scope
            self.bounds = bounds
            self.byUser = byUser
        }
    }

    public struct Finish: Sendable {
        public var end: SessionTime
        public var recorder: Walkthrough.Recorder
        public var permissions: Walkthrough.Permissions
        public var displays: [Walkthrough.Display]
        public var transcript: Walkthrough.Availability
        public var transcriptFailure: Walkthrough.TranscriptFailure?
        public var language: String?
        public var transcriptEngine: String?
        public var clip: Walkthrough.Clip?
        public var sourceFailed: Bool
        public var microphone: Walkthrough.Microphone?
        public var timeZone: TimeZone

        public init(
            end: SessionTime,
            recorder: Walkthrough.Recorder,
            permissions: Walkthrough.Permissions,
            displays: [Walkthrough.Display] = [],
            transcript: Walkthrough.Availability,
            transcriptFailure: Walkthrough.TranscriptFailure? = nil,
            language: String? = nil,
            transcriptEngine: String? = nil,
            clip: Walkthrough.Clip? = nil,
            sourceFailed: Bool = false,
            microphone: Walkthrough.Microphone? = nil,
            timeZone: TimeZone = .current
        ) {
            self.end = end
            self.recorder = recorder
            self.permissions = permissions
            self.displays = displays
            self.transcript = transcript
            self.transcriptFailure = transcriptFailure
            self.language = language
            self.transcriptEngine = transcriptEngine
            self.clip = clip
            self.sourceFailed = sourceFailed
            self.microphone = microphone
            self.timeZone = timeZone
        }
    }

    private struct CapturedFrame: Sendable {
        var bbox: Rect
        var scale: Double?
        var display: String?
    }

    public static let maximumFrames = 40
    public static let reservedForKeyMoments = 10
    public static let sceneSpacing: SessionTime = 2
    public static let sceneThreshold = 0.2
    public static let sceneSettle: SessionTime = 0.25
    public static let mergeWindow: SessionTime = 0.3
    public static let pointerFrameWindow: SessionTime = 2

    public let id: String
    public let startedAt: Date
    public private(set) var ledger = SessionLedger()
    public private(set) var strokes: [Stroke] = []
    public private(set) var scopes: [ScopeChange] = []
    public private(set) var semantics: [SemanticHit] = []
    private var requests: [FrameRequest] = []
    private var captured: [String: CapturedFrame] = [:]
    private var lastSceneAt: SessionTime = -.infinity

    public init(id: String, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }

    public var requestedFrames: [FrameRequest] { requests }

    public mutating func start() -> FrameRequest? {
        request(at: 0, reason: .start)
    }

    public mutating func record(_ signal: Signal) -> FrameRequest? {
        ledger.record(signal)
        switch signal {
        case .mark(let mark):
            return request(at: mark.at, reason: .pin)
        case .focus(let focus):
            let at = min(focus.range.start + 1, (focus.range.start + focus.range.end) / 2)
            guard !hasFrame(near: at, within: Self.sceneSpacing) else { return nil }
            return request(at: at, reason: .scene)
        case .visualChange(let change):
            guard change.magnitude >= Self.sceneThreshold, change.at - lastSceneAt >= Self.sceneSpacing else { return nil }
            lastSceneAt = change.at
            return request(at: change.at + Self.sceneSettle, reason: .scene)
        case .utterance, .context, .command, .clock:
            return nil
        }
    }

    public mutating func add(_ stroke: Stroke) -> FrameRequest? {
        strokes.append(stroke)
        ledger.extend(to: stroke.range.end)
        return request(at: stroke.range.end, reason: .stroke)
    }

    public mutating func add(_ change: ScopeChange) -> FrameRequest? {
        scopes.append(change)
        ledger.extend(to: change.at)
        return request(at: change.at, reason: .scope)
    }

    public mutating func add(_ hit: SemanticHit) -> FrameRequest? {
        semantics.append(hit)
        guard hit.via == .dwell, !hasFrame(near: hit.at, within: Self.sceneSpacing) else { return nil }
        return request(at: hit.at, reason: .scene)
    }

    public mutating func finish(at end: SessionTime) -> FrameRequest? {
        ledger.extend(to: end)
        return request(at: max(0, end - 0.05), reason: .end)
    }

    public mutating func captured(_ request: FrameRequest, bbox: Rect, scale: Double?, display: String? = nil) {
        captured[request.file] = CapturedFrame(bbox: bbox, scale: scale, display: display)
    }

    private func hasFrame(near time: SessionTime, within window: SessionTime) -> Bool {
        requests.contains { abs($0.time - time) <= window }
    }

    private mutating func request(at time: SessionTime, reason: Walkthrough.FrameReason) -> FrameRequest? {
        if let index = requests.firstIndex(where: { abs($0.time - time) <= Self.mergeWindow }) {
            if requests[index].reason == .scene, reason != .scene { requests[index].reason = reason }
            return nil
        }
        let limit: Int
        switch reason {
        case .end: limit = Self.maximumFrames
        case .scene: limit = Self.maximumFrames - Self.reservedForKeyMoments
        case .start, .pin, .click, .stroke, .scope: limit = Self.maximumFrames - 1
        }
        guard requests.count < limit else { return nil }
        let name = String(format: "%06d", Walkthrough.milliseconds(time))
        let request = FrameRequest(time: time, reason: reason, file: "frames/\(name).png", thumb: "frames/thumbs/\(name).jpg")
        requests.append(request)
        return request
    }

    public func build(_ finish: Finish) -> Walkthrough {
        let ms = Walkthrough.milliseconds
        let end = max(finish.end, ledger.end)

        let frameList = requests
            .filter { captured[$0.file] != nil }
            .sorted { $0.time < $1.time }
        var frames = frameList.enumerated().map { index, request -> Walkthrough.Frame in
            let capture = captured[request.file]!
            return Walkthrough.Frame(
                id: "f\(index + 1)",
                file: request.file,
                thumb: request.thumb,
                t: ms(request.time),
                bbox: Walkthrough.Box(capture.bbox),
                scale: capture.scale,
                display: capture.display,
                reason: request.reason
            )
        }
        func nearestFrame(to time: SessionTime, preferring reason: Walkthrough.FrameReason? = nil) -> Int? {
            if let reason, let exact = frameList.indices.first(where: { frameList[$0].reason == reason && abs(frameList[$0].time - time) <= Self.mergeWindow }) {
                return exact
            }
            let nearest = frameList.indices.min { abs(frameList[$0].time - time) < abs(frameList[$1].time - time) }
            guard let nearest, abs(frameList[nearest].time - time) <= Self.pointerFrameWindow else { return nil }
            return nearest
        }

        let pointerInputs = pointerMoments()
        var pointers: [Walkthrough.Pointer] = []
        for (index, moment) in pointerInputs.enumerated() {
            let id = "p\(index + 1)"
            let frameIndex = nearestFrame(to: moment.time, preferring: moment.via == .pin ? .pin : nil)
            var pointer = Self.pointer(id: id, moment: moment, context: ledger.context(at: moment.time))
            if let frameIndex {
                pointer.frame = frames[frameIndex].id
                frames[frameIndex].pointers = (frames[frameIndex].pointers ?? []) + [id]
            }
            pointers.append(pointer)
        }

        var drawings: [Walkthrough.Drawing] = []
        for (index, stroke) in strokes.sorted(by: { $0.range.start < $1.range.start }).enumerated() {
            let id = "d\(index + 1)"
            let points = stroke.samples.map { Walkthrough.StrokePoint(x: $0.point.x, y: $0.point.y, t: ms($0.at)) }
            let bbox = Self.bounds(of: stroke.samples.map(\.point), padding: (stroke.width ?? 0) / 2)
            var drawing = Walkthrough.Drawing(
                id: id,
                t: ms(stroke.range.start),
                end: ms(stroke.range.end),
                points: points,
                bbox: Walkthrough.Box(bbox),
                color: stroke.color,
                width: stroke.width,
                shape: Self.shape(of: stroke.samples.map(\.point), bounds: bbox)
            )
            drawing.near = Self.nearestPointer(to: bbox, during: stroke.range, in: pointers)
            if let frameIndex = nearestFrame(to: stroke.range.end, preferring: .stroke) {
                drawing.frame = frames[frameIndex].id
                frames[frameIndex].drawings = (frames[frameIndex].drawings ?? []) + [id]
            }
            drawings.append(drawing)
        }

        let utterances = ledger.utterances
        var segments = utterances.enumerated().map { index, utterance in
            Walkthrough.Segment(
                id: "s\(index + 1)",
                start: ms(utterance.range.start),
                end: ms(utterance.range.end),
                text: utterance.text,
                words: utterance.words.isEmpty ? nil : utterance.words.map { Walkthrough.TimedWord(text: $0.text, start: ms($0.range.start), end: ms($0.range.end)) }
            )
        }
        for pointer in pointers {
            guard let index = Self.segmentIndex(for: Double(pointer.t), in: segments) else { continue }
            segments[index].pointers = (segments[index].pointers ?? []) + [pointer.id]
        }
        for drawing in drawings {
            guard let index = Self.segmentIndex(for: Double(drawing.t), in: segments) else { continue }
            segments[index].drawings = (segments[index].drawings ?? []) + [drawing.id]
        }

        let transcriptReady = finish.transcript == .ready && finish.transcriptFailure == nil
        let asks = transcriptReady
            ? Walkthrough.Asks(status: .ready, engine: AskExtractor.engine, items: AskExtractor.asks(from: segments, pointers: pointers, drawings: drawings))
            : Walkthrough.Asks(status: .unavailable, items: [])

        let context = appContext()
        let denied = [finish.permissions.screen, finish.permissions.microphone].contains(.denied)
        let status: Walkthrough.Status = denied || !transcriptReady || finish.sourceFailed ? .partial : .ready

        return Walkthrough(
            id: id,
            createdAt: Self.timestamp(startedAt, in: finish.timeZone),
            duration: ms(end),
            title: Self.title(asks: asks.items, context: context),
            status: status,
            recorder: finish.recorder,
            capture: Walkthrough.Capture(
                permissions: finish.permissions,
                displays: finish.displays.isEmpty ? nil : finish.displays,
                scopes: scopes.map { Walkthrough.ScopeChange(t: ms($0.at), scope: $0.scope, bounds: Walkthrough.Box($0.bounds), by: $0.byUser ? "user" : "auto") },
                microphone: finish.microphone
            ),
            context: context,
            transcript: Walkthrough.Transcript(
                status: transcriptReady ? .ready : .unavailable,
                language: finish.language,
                engine: finish.transcriptEngine,
                failure: finish.transcriptFailure,
                segments: transcriptReady || finish.transcriptFailure != nil ? segments : []
            ),
            frames: frames,
            pointers: pointers,
            drawings: drawings,
            asks: asks,
            clip: finish.clip,
            events: events()
        )
    }

    private struct PointerMoment {
        var time: SessionTime
        var via: Walkthrough.Via
        var point: Point?
        var target: Target?
        var hit: SemanticHit?
    }

    public static let semanticDwellWindow: SessionTime = 0.75

    private func pointerMoments() -> [PointerMoment] {
        let pinHits = semantics.filter { $0.via == .pin }
        let pins = ledger.marks.map { mark in
            PointerMoment(time: mark.at, via: .pin, point: mark.point, target: mark.target, hit: pinHits.first { $0.markID == mark.id })
        }
        var dwellHits = semantics.filter { $0.via == .dwell }.sorted { $0.at < $1.at }
        var dwells: [PointerMoment] = []
        var previous: String?
        for focus in ledger.focuses {
            defer { previous = focus.target.id }
            guard focus.target.id != previous, let frame = focus.target.frame else { continue }
            let pinned = pins.contains { $0.target?.id == focus.target.id && abs($0.time - focus.range.start) <= 3 }
            guard !pinned else { continue }
            let center = Point(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            var moment = PointerMoment(time: focus.range.start, via: .dwell, point: center, target: focus.target)
            if let index = dwellHits.indices.min(by: { abs(dwellHits[$0].at - focus.range.start) < abs(dwellHits[$1].at - focus.range.start) }),
               abs(dwellHits[index].at - focus.range.start) <= Self.semanticDwellWindow {
                moment.hit = dwellHits.remove(at: index)
            }
            dwells.append(moment)
        }
        for hit in dwellHits {
            let pinned = pins.contains { $0.hit != nil && $0.hit?.stack.identity == hit.stack.identity && abs($0.time - hit.at) <= 3 }
            guard !pinned else { continue }
            dwells.append(PointerMoment(time: hit.at, via: .dwell, point: hit.point, hit: hit))
        }
        return (pins + dwells).sorted { $0.time < $1.time }
    }

    private static func pointer(id: String, moment: PointerMoment, context: AppContext?) -> Walkthrough.Pointer {
        let at = moment.hit?.point ?? moment.point ?? moment.target?.frame.map { Point(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) } ?? Point(x: 0, y: 0)
        var pointer = Walkthrough.Pointer(
            id: id,
            t: Walkthrough.milliseconds(moment.time),
            via: moment.via,
            at: Walkthrough.Spot(x: at.x, y: at.y),
            source: .none
        )
        if let target = moment.target {
            let bounds = target.frame.map(Walkthrough.Box.init)
            pointer.label = target.role != nil || target.label != nil || target.component != nil ? target.displayName : nil
            switch target.provider {
            case .accessibility:
                pointer.source = .ax
                pointer.ax = Walkthrough.AXElement(role: target.role, title: target.label, app: context?.app.name, bounds: bounds)
            case .web, .native:
                pointer.source = .sdk
                pointer.sdk = Walkthrough.SDKElement(component: target.component, source: target.source?.description, selector: target.selector)
                pointer.ax = bounds.map { Walkthrough.AXElement(role: target.role, title: target.label, app: context?.app.name, bounds: $0) }
                if target.provider == .web, let location = context?.location { pointer.url = location }
            case .region:
                pointer.label = nil
            }
        }
        if let hit = moment.hit, !hit.stack.levels.isEmpty {
            pointer.source = .apiary
            pointer.stack = hit.stack.levels
            pointer.label = hit.stack.label ?? pointer.label
            pointer.url = hit.stack.url ?? pointer.url
        }
        return pointer
    }

    private static func segmentIndex(for time: Double, in segments: [Walkthrough.Segment]) -> Int? {
        if let inside = segments.firstIndex(where: { Double($0.start) <= time && time <= Double($0.end) }) { return inside }
        let distance = { (segment: Walkthrough.Segment) -> Double in
            min(abs(Double(segment.start) - time), abs(Double(segment.end) - time))
        }
        guard let nearest = segments.indices.min(by: { distance(segments[$0]) < distance(segments[$1]) }),
              distance(segments[nearest]) <= Self.pointerFrameWindow * 1000
        else { return nil }
        return nearest
    }

    private static func nearestPointer(to bbox: Rect, during range: TimeRange, in pointers: [Walkthrough.Pointer]) -> String? {
        let candidates = pointers.filter { pointer in
            let point = Point(x: pointer.at.x, y: pointer.at.y)
            let element = pointer.ax?.bounds.map { Rect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            return bbox.contains(point) || element.map { bbox.intersects($0) } == true
        }
        let middle = (range.start + range.end) / 2 * 1000
        return candidates.min { abs(Double($0.t) - middle) < abs(Double($1.t) - middle) }?.id
    }

    static func bounds(of points: [Point], padding: Double) -> Rect {
        guard let first = points.first else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return Rect(x: minX - padding, y: minY - padding, width: maxX - minX + padding * 2, height: maxY - minY + padding * 2)
    }

    static func shape(of points: [Point], bounds: Rect) -> Walkthrough.Shape {
        guard let first = points.first, let last = points.last, points.count >= 3 else { return .free }
        let diagonal = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot()
        guard diagonal > 0 else { return .free }
        let gap = ((last.x - first.x) * (last.x - first.x) + (last.y - first.y) * (last.y - first.y)).squareRoot()
        if gap < diagonal * 0.25 {
            let aspect = bounds.width / max(bounds.height, 1)
            return aspect > 0.08 && aspect < 12 ? .circle : .free
        }
        if bounds.height < bounds.width * 0.2 { return .underline }
        return .free
    }

    private func appContext() -> Walkthrough.Context? {
        var moments: [Walkthrough.AppMoment] = []
        for change in ledger.contexts {
            let moment = Walkthrough.AppMoment(
                t: Walkthrough.milliseconds(change.at),
                bundleId: change.context.app.bundleID,
                name: change.context.app.name,
                windowTitle: change.context.windowTitle,
                url: change.context.location
            )
            if let last = moments.last, last.bundleId == moment.bundleId, last.name == moment.name, last.windowTitle == moment.windowTitle, last.url == moment.url { continue }
            moments.append(moment)
        }
        guard !moments.isEmpty else { return nil }
        let project = ledger.contexts.compactMap(\.context.project).last.map { Walkthrough.Project(root: $0.rootPath, branch: $0.gitBranch) }
        return Walkthrough.Context(apps: moments, project: project)
    }

    private func events() -> [Walkthrough.Event]? {
        var events: [Walkthrough.Event] = []
        var previous: AppContext?
        for change in ledger.contexts {
            defer { previous = change.context }
            guard let before = previous else { continue }
            let t = Walkthrough.milliseconds(change.at)
            if !before.app.isSameApp(as: change.context.app) {
                events.append(Walkthrough.Event(t: t, kind: .appSwitch, detail: change.context.app.name))
            } else if let location = change.context.location, location != before.location {
                events.append(Walkthrough.Event(t: t, kind: .navigate, detail: location))
            }
        }
        events += scopes.map { Walkthrough.Event(t: Walkthrough.milliseconds($0.at), kind: .scope, detail: $0.scope.rawValue) }
        events.sort { $0.t < $1.t }
        return events.isEmpty ? nil : events
    }

    private static func title(asks: [Walkthrough.Ask], context: Walkthrough.Context?) -> String? {
        if let first = asks.first?.text {
            return WalkthroughText.truncated(first, to: 80)
        }
        guard let app = context?.apps.first else { return nil }
        let place = app.url.flatMap(WalkthroughText.shortLocation) ?? app.windowTitle
        return WalkthroughText.truncated(["Walkthrough of", app.name, place.map { "· \($0)" }].compactMap { $0 }.joined(separator: " "), to: 80)
    }

    static func timestamp(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }
}

extension Rect {
    func intersects(_ other: Rect) -> Bool {
        x <= other.x + other.width && other.x <= x + width && y <= other.y + other.height && other.y <= y + height
    }
}
