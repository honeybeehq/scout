import AppKit
import ScoutCore
import SwiftUI

struct ReviewWindow: View {
    @Environment(AppModel.self) private var model
    @State private var player = ReviewPlayer()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.night, Palette.ink], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if let review = model.review {
                ReviewContent(review: review, player: player)
                    .id(review.sessionID)
            } else {
                EmptyReview()
            }
        }
        .frame(minWidth: 1040, minHeight: 700)
        .environment(\.colorScheme, .dark)
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
            HStack(spacing: 0) {
                TaskList(review: review, player: player, onFocusRoot: { rootFocused = true })
                    .frame(width: 300)
                    .background(Color.black.opacity(0.18))
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

private struct ReviewHeader: View {
    @Environment(AppModel.self) private var model
    let review: SessionReview
    let player: ReviewPlayer
    @State private var sessions: [SessionSummary] = []

    var body: some View {
        HStack(spacing: 14) {
            ScoutMark(litArcs: 3, pulsing: review.isFinishing)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer()

            Menu {
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
                    .font(.system(size: 12.5, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(GlassPillButtonStyle())
            .fixedSize()
            .onAppear { sessions = SessionLibrary.recent().filter { $0.id != review.sessionID } }

            if review.unsentCount > 0 {
                let missing = review.unsentCount - sendableCount
                if missing > 0 {
                    Text(missing == 1 ? "1 task needs a destination" : "\(missing) tasks need a destination")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.amber)
                }
                if let card = review.selectedTask ?? review.tasks.first {
                    Menu {
                        ForEach(model.dispatcher.destinations(for: card), id: \.self) { destination in
                            Button(destination.label) { review.assignDestinationToWaiting(destination) }
                        }
                    } label: {
                        Label("Send all to…", systemImage: "arrow.turn.down.right")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .menuStyle(.button)
                    .buttonStyle(GlassPillButtonStyle())
                    .fixedSize()
                }
            }

            Button {
                Task {
                    await model.sendAll(in: review)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(sendLabel)
                    Text("⌥⌘↩").font(Typography.mono).opacity(0.7)
                }
            }
            .buttonStyle(FlareButtonStyle(large: false))
            .disabled(sendableCount == 0)
            .keyboardShortcut(.return, modifiers: [.command, .option])
        }
        .padding(.leading, 84)
        .padding(.trailing, 20)
        .frame(height: 58)
        .background(Palette.night.opacity(0.5))
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
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color.black.opacity(0.28))
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func toolbarButton(_ title: String, symbol: String, shortcut: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.white.opacity(enabled ? 0.07 : 0.03), in: .capsule)
            .foregroundStyle(enabled ? Palette.text : Palette.textTertiary)
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
            ScoutMark(litArcs: 3)
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
                        .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 520)
        }
        .onAppear { sessions = SessionLibrary.recent() }
    }
}
