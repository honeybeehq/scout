import AppKit
import ScoutCore
import SwiftUI

struct ReviewWindow: View {
    @Environment(AppModel.self) private var model
    @State private var player = ReviewPlayer()

    var body: some View {
        ZStack {
            Palette.canvas
                .ignoresSafeArea()
            if let review = model.review {
                ReviewContent(review: review, player: player)
                    .id(review.sessionID)
            } else {
                EmptyReview()
            }
        }
        .frame(minWidth: 1140, minHeight: 700)
        .scaledToUISize()
        .onAppear { model.windowOpened() }
        .onDisappear {
            player.detach()
            model.review?.save()
            model.windowClosed()
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
                    .frame(width: 300)
                    .background(Palette.surface)
                Rectangle().fill(Palette.hairline).frame(width: 1)
                if let card = review.selectedTask {
                    TaskDetail(review: review, player: player, card: card)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 30))
                            .foregroundStyle(Palette.textTertiary)
                        Text(review.leftoverSpeech.isEmpty ? "Nothing to review in this session." : "No tasks yet. Pick up speech from the list on the left.")
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            ScoutMenu {
                ForEach(sessions) { summary in
                    Button {
                        model.openReview(summary)
                    } label: {
                        Text("\(summary.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(summary.taskCount) tasks" + (summary.unsentCount > 0 ? " · \(summary.unsentCount) waiting" : ""))
                    }
                }
                if sessions.isEmpty { Text("No earlier sessions") }
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

            Button {
                Task {
                    await model.sendAll(in: review)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(sendLabel).monospacedDigit()
                    KeyHint("⌥⌘↩", emphasized: true)
                }
            }
            .buttonStyle(PrimaryButtonStyle(large: false))
            .disabled(sendableCount == 0)
            .keyboardShortcut(.return, modifiers: [.command, .option])
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
        if sendableCount == review.unsentCount { return review.unsentCount == 1 ? "Send task" : "Send all \(review.unsentCount)" }
        return "Send \(sendableCount) ready"
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
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("Timeline").eyebrowStyle(Palette.textTertiary)
                Text("Drag a task's edge to trim it. Edges snap to pauses in your speech.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                Spacer()
                if let card = review.selectedTask {
                    toolbarButton("Split", symbol: "scissors", shortcut: "⌘B", enabled: review.canSplit(card, at: review.playhead)) {
                        player.pause()
                        review.split(card, at: review.playhead)
                    }
                    .keyboardShortcut(review.isEditingText ? nil : KeyboardShortcut("b", modifiers: .command))
                    toolbarButton("Join next", symbol: "arrow.right.to.line.compact", shortcut: "⌘J", enabled: review.canJoin(card)) {
                        review.join(card)
                    }
                    .keyboardShortcut(review.isEditingText ? nil : KeyboardShortcut("j", modifiers: .command))
                    toolbarButton("Delete", symbol: "trash", shortcut: "⌘⌫", enabled: !card.isLocked) {
                        player.pause()
                        review.delete(card)
                    }
                    .keyboardShortcut(review.isEditingText ? nil : KeyboardShortcut(.delete, modifiers: .command))
                }
                toolbarButton("Undo", symbol: "arrow.uturn.backward", shortcut: "⌘Z", enabled: review.canUndo) {
                    review.undo()
                }
                .keyboardShortcut(review.isEditingText ? nil : KeyboardShortcut("z", modifiers: .command))
            }
            SessionTimeline(review: review, player: player)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(Palette.sunken)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func toolbarButton(_ title: String, symbol: String, shortcut: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
                KeyHint(shortcut)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .frame(height: 26)
            .background(Palette.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(enabled ? Palette.stroke : Palette.hairline))
            .foregroundStyle(enabled ? Palette.text : Palette.textQuaternary)
            .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("\(title) (\(shortcut))")
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
