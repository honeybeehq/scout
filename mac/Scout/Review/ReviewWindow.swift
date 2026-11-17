import AppKit
import ScoutCore
import SwiftUI

struct ReviewWindow: View {
    @Environment(AppModel.self) private var model
    @State private var player = ReviewPlayer()

    static let minimumSize = CGSize(width: 1140, height: 700)

    var body: some View {
        ReviewSurface(review: model.review, player: player)
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .scaledToUISize()
        .onAppear { model.windowOpened() }
        .onDisappear {
            player.detach()
            model.review?.save()
            model.windowClosed()
        }
    }
}

struct ReviewSurface: View {
    let review: SessionReview?
    let player: ReviewPlayer

    var body: some View {
        ZStack {
            Palette.canvas
                .ignoresSafeArea()
            if let review {
                ReviewContent(review: review, player: player)
                    .id(review.sessionID)
            } else {
                EmptyReview()
            }
        }
    }
}

private struct ReviewContent: View {
    @Environment(AppModel.self) private var model
    let review: SessionReview
    let player: ReviewPlayer
    @FocusState private var rootFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(review: review, player: player)
            if let error = review.saveError {
                SaveErrorBanner(review: review, error: error)
            }
            HStack(spacing: 0) {
                TaskList(review: review, player: player, onFocusRoot: { rootFocused = true })
                    .frame(width: 272)
                    .background(Palette.surface)
                Rectangle().fill(Palette.hairline).frame(width: 1)
                if let card = review.selectedTask {
                    TaskDetail(review: review, player: player, card: card)
                } else {
                    StageColumn(review: review, player: player)
                    Rectangle().fill(Palette.hairline).frame(width: 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No tasks yet")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Palette.text)
                        Text(review.leftoverSpeech.isEmpty ? "Nothing in this session became a task." : "Turn what you said into a task with New task in the list on the left.")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(width: TaskDetail.detailWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Palette.surface)
                }
            }
            TimelinePanel(review: review, player: player)
                .simultaneousGesture(TapGesture().onEnded { rootFocused = true })
        }
        .focusable()
        .focusEffectDisabled()
        .focused($rootFocused)
        .onAppear {
            if review.selectedTaskID == nil, let first = review.tasks.first { review.select(first) }
            player.attach(review)
            rootFocused = true
        }
        .onChange(of: review.video?.url) { player.attach(review) }
        .task(id: review.video?.url) { await review.loadFilmstrip() }
        .onKeyPress(.space) {
            guard !review.isEditingText else { return .ignored }
            player.toggle()
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !review.isEditingText else { return .ignored }
            player.pause()
            review.selectAdjacent(-1)
            player.seek(to: review.playhead)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !review.isEditingText else { return .ignored }
            player.pause()
            review.selectAdjacent(1)
            player.seek(to: review.playhead)
            return .handled
        }
    }
}

private struct SaveErrorBanner: View {
    let review: SessionReview
    let error: String

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(tone: .negative, size: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't save this session. Changes since the last save are lost if Scout quits.")
                    .font(.system(size: 12.5, weight: .medium))
                Text(error)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Try again") { review.save() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Palette.negativeWash)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

private struct ReviewHeader: View {
    @Environment(AppModel.self) private var model
    let review: SessionReview
    let player: ReviewPlayer
    @State private var sessions: [SessionSummary] = []

    var body: some View {
        HStack(spacing: 14) {
            ScoutMark(level: 3, pulsing: review.isFinishing)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .heavy))
                Text(subtitle)
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer()

            DiscardControl(question: "Discard session?", help: review.canDiscard ? "Discard session: delete its recording and tasks. Nothing is sent or copied." : "Sessions with sent tasks, or a video still being prepared, can't be discarded.", compact: true, asking: Bindable(review).confirmingDiscard) {
                player.detach()
                model.discard(review)
            }
            .disabled(!review.canDiscard)
            .opacity(review.canDiscard ? 1 : 0.5)

            ScoutMenu {
                ForEach(sessions) { summary in
                    Button {
                        model.openReview(summary)
                    } label: {
                        Text("\(summary.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(summary.taskCount) tasks" + (summary.unsentCount > 0 ? " · \(summary.unsentCount) waiting" : ""))
                    }
                }
                if sessions.isEmpty { Text("No earlier sessions") }
                if let debug = DebugRun.existing(in: review.directory) {
                    Divider()
                    Button("Reveal debug data") { model.revealDebugData(at: debug) }
                }
            } label: {
                Label("Sessions", systemImage: "clock.arrow.circlepath")
                    .modifier(SecondaryLabel())
            }
            .fixedSize()
            .onAppear { sessions = SessionLibrary.recent().filter { $0.id != review.sessionID } }

            if review.unsentCount > 0, let card = review.selectedTask ?? review.tasks.first {
                let missing = review.unsentCount - sendableCount
                ScoutMenu {
                    ForEach(model.dispatcher.destinations(for: card), id: \.self) { destination in
                        Button(destination.label) { review.assignDestinationToWaiting(destination) }
                    }
                } label: {
                    if missing > 0 {
                        Label(missing == 1 ? "1 needs a destination" : "\(missing) need a destination", systemImage: "arrow.turn.down.right")
                            .monospacedDigit()
                            .modifier(SecondaryLabel(caution: true))
                    } else {
                        Label("Send all to…", systemImage: "arrow.turn.down.right")
                            .modifier(SecondaryLabel())
                    }
                }
                .fixedSize()
                .help("Choose one destination for every task still waiting")
            }

            if !review.tasks.isEmpty {
                Button {
                    Task {
                        await model.sendAll(in: review)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if review.unsentCount == 0 { Image(systemName: "checkmark") }
                        Text(sendLabel).monospacedDigit()
                        if sendableCount > 0 { KeyHint("⌥⌘↩") }
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(sendableCount == 0)
                .keyboardShortcut(.return, modifiers: [.command, .option])
            }
        }
        .padding(.leading, 84)
        .padding(.trailing, 16)
        .frame(height: 54)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var sendLabel: String {
        if review.unsentCount == 0 { return "All sent" }
        if sendableCount == 0 { return "Send all" }
        if sendableCount == review.unsentCount, onlyClipboard { return review.unsentCount == 1 ? "Copy task" : "Copy all \(review.unsentCount)" }
        if sendableCount == review.unsentCount { return review.unsentCount == 1 ? "Send task" : "Send all \(review.unsentCount)" }
        return "Send \(sendableCount) ready"
    }

    private var onlyClipboard: Bool {
        review.tasks.allSatisfy { $0.isLocked || $0.destination == nil || $0.destination == .clipboard }
    }

    private var sendableCount: Int {
        review.tasks.filter { !$0.isLocked && $0.destination != nil }.count
    }

    private var title: String {
        "Session review"
    }

    private var subtitle: String {
        var parts = [review.startedAt.formatted(date: .abbreviated, time: .shortened), SessionTimeline.clock(review.duration)]
        let apps = review.apps.prefix(3)
        if !apps.isEmpty { parts.append(apps.joined(separator: ", ")) }
        parts.append(review.segmentation == .manual ? "Manual tasks" : "Automatic tasks")
        return parts.joined(separator: " · ")
    }
}

private struct TimelinePanel: View {
    let review: SessionReview
    let player: ReviewPlayer

    var body: some View {
        VStack(spacing: 6) {
            TransportBar(review: review, player: player)
            SessionTimeline(review: review, player: player)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Palette.sunken)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

private struct TransportBar: View {
    let review: SessionReview
    let player: ReviewPlayer

    var body: some View {
        HStack(spacing: 8) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.onInk)
                    .frame(width: 32, height: 28)
                    .background(Palette.ink, in: .rect(cornerRadius: Radius.control, style: .continuous))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(review.video == nil)
            .help("Play or pause (Space)")
            KeyHint("space")

            if let card = review.selectedTask {
                Text("\(Text(SessionTimeline.clock(max(0, review.playhead - card.snippet.range.start), precise: true)).foregroundStyle(Palette.text)) / \(SessionTimeline.clock(card.snippet.range.duration, precise: true))")
                    .font(Typography.numeric)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize()
                    .padding(.horizontal, 6)
            }

            if review.selectedTask != nil {
                TransportButton(title: "Loop task", symbol: "repeat", on: player.loopsTask) {
                    player.loopsTask.toggle()
                }
                .accessibilityAddTraits(player.loopsTask ? .isSelected : [])
            }

            Rectangle().fill(Palette.stroke).frame(width: 1, height: 16).padding(.horizontal, 4)

            if let card = review.selectedTask {
                TransportButton(title: "Split", symbol: "scissors", shortcut: "⌘B", enabled: review.canSplit(card, at: review.playhead)) {
                    player.pause()
                    review.split(card, at: review.playhead)
                }
                .keyboardShortcut(review.isEditingText ? nil : KeyboardShortcut("b", modifiers: .command))
                .help("Split the task at the playhead (⌘B)")
                TransportButton(title: "Join next", symbol: "arrow.right.to.line.compact", shortcut: "⌘J", enabled: review.canJoin(card)) {
                    review.join(card)
                }
                .keyboardShortcut(review.isEditingText ? nil : KeyboardShortcut("j", modifiers: .command))
                .help("Join with the next task (⌘J)")
                TransportButton(title: "Delete", symbol: "trash", shortcut: "⌘⌫", enabled: !card.isLocked) {
                    player.pause()
                    review.delete(card)
                }
                .keyboardShortcut(review.isEditingText ? nil : KeyboardShortcut(.delete, modifiers: .command))
                .help("Delete this task (⌘⌫)")
            }
            TransportButton(title: "Undo", symbol: "arrow.uturn.backward", shortcut: "⌘Z", enabled: review.canUndo) {
                review.undo()
            }
            .keyboardShortcut(review.isEditingText ? nil : KeyboardShortcut("z", modifiers: .command))
            .help("Undo (⌘Z)")

            Spacer(minLength: 12)
            if !review.tasks.isEmpty {
                ViewThatFits(in: .horizontal) {
                    Text("Drag a task's edge to trim it. Edges snap to pauses; hold ⌥ to place freely.")
                    Text("Drag an edge to trim it.")
                    Color.clear.frame(width: 0, height: 0)
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
            }
        }
        .frame(height: 30)
    }
}

private struct TransportButton: View {
    let title: String
    let symbol: String
    var shortcut: String?
    var enabled = true
    var on: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
                if let shortcut { KeyHint(shortcut) }
                if let on { Text(on ? "On" : "Off").foregroundStyle(on ? Palette.text : Palette.textTertiary).monospacedDigit() }
            }
            .font(.system(size: 12, weight: .semibold))
            .fixedSize()
            .padding(.leading, 9)
            .padding(.trailing, shortcut == nil ? 9 : 5)
            .frame(height: 26)
            .background(on == true ? Palette.fillStrong : Palette.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(enabled ? Palette.stroke : Palette.hairline))
            .foregroundStyle(enabled ? Palette.text : Palette.textQuaternary)
            .contentShape(.rect(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct EmptyReview: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [SessionSummary] = []

    var body: some View {
        VStack(spacing: 18) {
            ScoutMark(level: 3)
                .frame(width: 64, height: 64)
            Text("No session open")
                .font(Typography.title)
            Text("Stop scouting to review what you captured, or open an earlier session.")
                .foregroundStyle(Palette.textSecondary)
            VStack(spacing: 8) {
                ForEach(sessions) { summary in
                    Button {
                        model.openReview(summary)
                    } label: {
                        HStack {
                            Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 13, weight: .semibold))
                            Text(summary.titles.first ?? "No tasks")
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(summary.taskCount) tasks")
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .surfaceCard(Palette.surface)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 520)
        }
        .onAppear { sessions = SessionLibrary.recent() }
    }
}

private struct SecondaryLabel: ViewModifier {
    var caution = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(caution ? Palette.onCaution : Palette.text)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(caution ? Palette.cautionFill : Palette.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(caution ? Color.clear : Palette.stroke))
            .contentShape(.rect(cornerRadius: Radius.control))
    }
}
