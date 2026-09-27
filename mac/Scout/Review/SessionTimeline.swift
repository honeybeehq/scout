import AppKit
import ScoutCore
import SwiftUI

struct TimelineScale {
    var duration: SessionTime
    var width: CGFloat
    var inset: CGFloat = 16

    var track: CGFloat { max(1, width - inset * 2) }

    func x(_ time: SessionTime) -> CGFloat {
        inset + CGFloat(time / max(duration, 0.001)) * track
    }

    func time(_ x: CGFloat) -> SessionTime {
        min(max(0, Double((x - inset) / track) * duration), duration)
    }

    var rulerStep: SessionTime {
        let steps: [SessionTime] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { CGFloat($0 / max(duration, 0.001)) * track >= 64 } ?? 900
    }
}

struct SessionTimeline: View {
    let review: SessionReview
    let player: ReviewPlayer

    @State private var hoverX: CGFloat?
    @State private var draggingEdge: String?

    static let filmTop: CGFloat = 18
    static let filmHeight: CGFloat = 58
    static let speechTop: CGFloat = 84
    static let height: CGFloat = 120

    var body: some View {
        GeometryReader { proxy in
            let scale = TimelineScale(duration: review.duration, width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawFilmstrip(in: &context, scale: scale)
                    drawTasks(in: &context, scale: scale)
                    drawSpeech(in: &context, scale: scale)
                    drawContexts(in: &context, scale: scale)
                    drawRuler(in: &context, scale: scale, size: size)
                }
                .contentShape(Rectangle())
                .gesture(scrub(scale))
                .onContinuousHover { phase in
                    if case .active(let location) = phase { hoverX = location.x } else { hoverX = nil }
                }

                ForEach(Array(review.tasks.enumerated()), id: \.element.id) { index, card in
                    taskLabel(card, index: index, scale: scale)
                    if !card.isLocked {
                        edgeHandle(card, edge: .start, scale: scale)
                        edgeHandle(card, edge: .end, scale: scale)
                    }
                }

                if let hoverX, draggingEdge == nil {
                    hoverMarker(at: hoverX, scale: scale)
                }
                playhead(scale: scale)
            }
            .coordinateSpace(.named("timeline"))
        }
        .frame(height: Self.height)
    }

    private func scrub(_ scale: TimelineScale) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                let time = scale.time(value.location.x)
                if value.translation == .zero {
                    player.pause()
                    if let card = review.tasks.first(where: { $0.snippet.range.contains(time) }) {
                        review.selectedTaskID = card.snippet.id
                    }
                }
                player.seek(to: time)
            }
    }

    private func taskColor(_ card: SnippetCard) -> Color {
        if card.state.isFinished { return Palette.mint }
        if card.snippet.id == review.selectedTask?.snippet.id { return Palette.flare }
        return Palette.beam
    }

    private func drawFilmstrip(in context: inout GraphicsContext, scale: TimelineScale) {
        let track = CGRect(x: scale.inset, y: Self.filmTop, width: scale.track, height: Self.filmHeight)
        let shape = Path(roundedRect: track, cornerRadius: 10, style: .continuous)
        context.fill(shape, with: .color(Color.white.opacity(0.05)))
        let frames = review.filmstrip
        if let first = frames.first {
            let aspect = CGFloat(first.width) / CGFloat(max(first.height, 1))
            let tileWidth = Self.filmHeight * aspect
            let tiles = max(1, Int((track.width / tileWidth).rounded(.up)))
            var film = context
            film.clip(to: shape)
            for tile in 0..<tiles {
                let frame = frames[min(frames.count - 1, tile * frames.count / tiles)]
                let rect = CGRect(x: track.minX + CGFloat(tile) * tileWidth, y: track.minY, width: tileWidth, height: track.height)
                film.draw(Image(decorative: frame, scale: 1), in: rect)
            }
        }
        var dimmed = context
        dimmed.clip(to: shape)
        var uncovered = Path(track)
        for card in review.tasks {
            let range = card.snippet.range
            uncovered = uncovered.subtracting(Path(CGRect(x: scale.x(range.start), y: track.minY, width: scale.x(range.end) - scale.x(range.start), height: track.height)))
        }
        dimmed.fill(uncovered, with: .color(Palette.ink.opacity(0.62)))
    }

    private func drawTasks(in context: inout GraphicsContext, scale: TimelineScale) {
        for card in review.tasks {
            let range = card.snippet.range
            let rect = CGRect(x: scale.x(range.start), y: Self.filmTop, width: max(2, scale.x(range.end) - scale.x(range.start)), height: Self.filmHeight)
                .insetBy(dx: 1, dy: 1)
            let shape = Path(roundedRect: rect, cornerRadius: 9, style: .continuous)
            let color = taskColor(card)
            let selected = card.snippet.id == review.selectedTask?.snippet.id
            var band = context
            band.clip(to: shape)
            band.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 4)), with: .color(color.opacity(selected ? 1 : 0.7)))
            context.stroke(shape, with: .color(color.opacity(selected ? 1 : 0.5)), lineWidth: selected ? 2 : 1.25)
        }
    }

    private func drawSpeech(in context: inout GraphicsContext, scale: TimelineScale) {
        let covered = review.tasks.map(\.snippet.range)
        for utterance in review.ledger.utterances {
            let middle = (utterance.range.start + utterance.range.end) / 2
            let inTask = covered.contains { middle >= $0.start && middle < $0.end }
            let rect = CGRect(x: scale.x(utterance.range.start), y: Self.speechTop, width: max(3, scale.x(utterance.range.end) - scale.x(utterance.range.start)), height: 8)
            let shape = Path(roundedRect: rect, cornerRadius: 4)
            if inTask {
                context.fill(shape, with: .color(Color.white.opacity(0.32)))
            } else {
                context.fill(shape, with: .color(Palette.amber.opacity(0.22)))
                context.stroke(shape, with: .color(Palette.amber.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        for mark in review.ledger.marks {
            let center = CGPoint(x: scale.x(mark.at), y: Self.speechTop + 4)
            let dot = Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
            context.fill(dot, with: .color(Palette.flare))
            context.stroke(dot, with: .color(.white), lineWidth: 1.5)
        }
    }

    private func drawContexts(in context: inout GraphicsContext, scale: TimelineScale) {
        var lastLabelX: CGFloat = -.infinity
        var previousApp: String?
        for change in review.ledger.contexts {
            let name = change.context.app.name
            guard name != previousApp else { continue }
            previousApp = name
            let x = scale.x(change.at)
            context.fill(Path(CGRect(x: x - 0.5, y: 3, width: 1, height: 12)), with: .color(Color.white.opacity(0.35)))
            guard x - lastLabelX > 90 else { continue }
            lastLabelX = x
            context.draw(
                Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.textTertiary),
                at: CGPoint(x: x + 4, y: 9),
                anchor: .leading
            )
        }
    }

    private func drawRuler(in context: inout GraphicsContext, scale: TimelineScale, size: CGSize) {
        let step = scale.rulerStep
        var time: SessionTime = 0
        while time <= scale.duration + 0.001 {
            let x = scale.x(time)
            context.fill(Path(CGRect(x: x - 0.5, y: 100, width: 1, height: 4)), with: .color(Color.white.opacity(0.25)))
            context.draw(
                Text(Self.clock(time)).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Palette.textTertiary),
                at: CGPoint(x: x, y: 112),
                anchor: .center
            )
            time += step
        }
    }

    private func taskLabel(_ card: SnippetCard, index: Int, scale: TimelineScale) -> some View {
        let range = card.snippet.range
        let width = scale.x(range.end) - scale.x(range.start)
        let color = taskColor(card)
        return Text("\(index + 1)")
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .foregroundStyle(card.snippet.id == review.selectedTask?.snippet.id ? Palette.ink : .white)
            .frame(minWidth: 18, minHeight: 18)
            .background(color.opacity(card.snippet.id == review.selectedTask?.snippet.id ? 1 : 0.5), in: .circle)
            .position(x: scale.x(range.start) + min(16, width / 2), y: Self.filmTop + 15)
            .opacity(width > 14 ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func edgeHandle(_ card: SnippetCard, edge: SessionReview.Edge, scale: TimelineScale) -> some View {
        let range = card.snippet.range
        let x = scale.x(edge == .start ? range.start : range.end)
        let key = "\(card.snippet.id)-\(edge == .start ? "start" : "end")"
        let active = draggingEdge == key || card.snippet.id == review.selectedTask?.snippet.id
        return Capsule()
            .fill(active ? Color.white : Color.white.opacity(0.0001))
            .frame(width: 4, height: 24)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(width: 14, height: Self.filmHeight)
            .contentShape(Rectangle())
            .position(x: x, y: Self.filmTop + Self.filmHeight / 2)
            .pointerStyle(.frameResize(position: edge == .start ? .leading : .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        if draggingEdge == nil {
                            draggingEdge = key
                            player.pause()
                            review.beginBoundaryDrag()
                            review.selectedTaskID = card.snippet.id
                        }
                        let snap = !NSEvent.modifierFlags.contains(.option)
                        review.moveBoundary(of: card, edge: edge, to: scale.time(value.location.x), snap: snap)
                        player.seek(to: edge == .start ? card.snippet.range.start : card.snippet.range.end)
                    }
                    .onEnded { _ in draggingEdge = nil }
            )
            .help(edge == .start ? "Drag to move where this task starts. Hold ⌥ to skip snapping." : "Drag to move where this task ends. Hold ⌥ to skip snapping.")
    }

    private func hoverMarker(at x: CGFloat, scale: TimelineScale) -> some View {
        let time = scale.time(x)
        return ZStack(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: Self.speechTop + 10 - 2)
            Text(Self.clock(time, precise: true))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(Color.white.opacity(0.85), in: .capsule)
                .offset(y: -1)
                .fixedSize()
        }
        .position(x: x, y: (Self.speechTop + 8) / 2)
        .allowsHitTesting(false)
    }

    private func playhead(scale: TimelineScale) -> some View {
        let x = scale.x(review.playhead)
        return ZStack(alignment: .top) {
            Rectangle().fill(Color.white).frame(width: 1.5, height: Self.speechTop + 12)
            Circle().fill(Color.white).frame(width: 9, height: 9).offset(y: -2)
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
        .position(x: x, y: (Self.speechTop + 12) / 2)
        .allowsHitTesting(false)
    }

    static func clock(_ seconds: SessionTime, precise: Bool = false) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return precise ? String(format: "%d:%04.1f", minutes, rest) : String(format: "%d:%02d", minutes, Int(rest))
    }
}
