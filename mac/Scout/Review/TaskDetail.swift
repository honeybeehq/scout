import AppKit
import ScoutCore
import SwiftUI

struct TaskDetail: View {
    @Environment(AppModel.self) private var model
    let review: SessionReview
    let player: ReviewPlayer
    let card: SnippetCard

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 20) {
                        PlayerPanel(review: review, player: player, card: card)
                        PinsSection(review: review, player: player, card: card)
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, alignment: .top)

                    VStack(alignment: .leading, spacing: 20) {
                        TitleField(review: review, card: card)
                        TranscriptField(review: review, card: card)
                        TargetsSection(review: review, card: card)
                        ContextSection(card: card)
                    }
                    .frame(width: 380, alignment: .top)
                }
                .padding(24)
            }
            .scrollIndicators(.automatic)

            HandoffBar(review: review, card: card)
        }
    }
}

private struct PlayerPanel: View {
    let review: SessionReview
    let player: ReviewPlayer
    let card: SnippetCard

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if review.video != nil {
                    PlayerSurface(player: player.player)
                } else {
                    VStack(spacing: 10) {
                        if review.isFinishing {
                            ProgressView().controlSize(.small)
                            Text("Preparing the video…")
                                .font(Typography.caption)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 28, weight: .medium))
                            Text("No screen recording for this session.")
                                .font(Typography.caption)
                        }
                    }
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.ink)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxHeight: 420)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .onTapGesture { player.toggle() }

            HStack(spacing: 14) {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.1), in: .circle)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(review.video == nil)
                .help("Play or pause (Space)")

                Text("\(SessionTimeline.clock(max(0, review.playhead - card.snippet.range.start), precise: true)) / \(SessionTimeline.clock(card.snippet.range.duration, precise: true))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)

                Spacer()

                Toggle(isOn: Bindable(player).loopsTask) {
                    Label("Loop task", systemImage: "repeat")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .foregroundStyle(player.loopsTask ? Palette.flareSoft : Palette.textTertiary)

                Button {
                    player.pause()
                    if let second = review.split(card, at: review.playhead) {
                        review.selectedTaskID = card.snippet.id
                        _ = second
                    }
                } label: {
                    Label("Split here", systemImage: "scissors")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(review.canSplit(card, at: review.playhead) ? Palette.textSecondary : Palette.textTertiary.opacity(0.5))
                .disabled(!review.canSplit(card, at: review.playhead))
            }
        }
    }

    private var aspect: CGFloat {
        guard let display = review.display, display.videoHeight > 0 else { return 16 / 10 }
        return CGFloat(display.videoWidth) / CGFloat(display.videoHeight)
    }
}

private struct TitleField: View {
    let review: SessionReview
    let card: SnippetCard
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Task").eyebrowStyle(Palette.textTertiary)
            TextField("What should the agent do?", text: Binding(
                get: { card.title },
                set: { value in
                    card.isUserEditing = true
                    card.title = value
                    card.isUserEditing = false
                    review.edited(card)
                }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Palette.text)
            .disabled(card.isLocked)
            .focused($focused)
            .onChange(of: focused) { _, value in
                review.isEditingText = value
                if value { review.beginTextEdit() }
            }
        }
    }
}

private struct TranscriptField: View {
    let review: SessionReview
    let card: SnippetCard
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What you said").eyebrowStyle(Palette.textTertiary)
                if card.transcriptOverride != nil {
                    Text("Edited")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.amber)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Palette.amber.opacity(0.14), in: .capsule)
                    Spacer()
                    if !card.isLocked {
                        Button("Use the original") {
                            card.transcriptOverride = nil
                            review.edited(card)
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }
            }
            if card.isLocked {
                Text(card.transcript)
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.03), in: .rect(cornerRadius: 12, style: .continuous))
            } else {
                TextField("What should change?", text: Binding(
                    get: { card.transcript },
                    set: { value in
                        card.transcriptOverride = value == card.snippet.transcript ? nil : value
                        review.edited(card)
                    }
                ), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5))
                .lineSpacing(4)
                .lineLimit(3...)
                .padding(12)
                .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? Palette.flare.opacity(0.5) : Color.white.opacity(0.08)))
                .focused($focused)
                .onChange(of: focused) { _, value in
                    review.isEditingText = value
                    if value { review.beginTextEdit() }
                }
            }
        }
    }
}

private struct TargetsSection: View {
    let review: SessionReview
    let card: SnippetCard

    var body: some View {
        let targets = card.snippet.targets
        if !targets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pointed at").eyebrowStyle(Palette.textTertiary)
                FlowLayout(spacing: 8) {
                    ForEach(targets) { target in
                        TargetChip(target: target, excluded: card.excludedTargetIDs.contains(target.id), locked: card.isLocked) {
                            if card.excludedTargetIDs.contains(target.id) {
                                card.excludedTargetIDs.remove(target.id)
                            } else {
                                card.excludedTargetIDs.insert(target.id)
                            }
                            review.edited(card)
                        }
                    }
                }
            }
        }
    }
}

private struct TargetChip: View {
    let target: Target
    let excluded: Bool
    let locked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .strikethrough(excluded)
                if let source = target.source {
                    Text(source.description)
                        .font(Typography.mono)
                        .foregroundStyle(Palette.beam)
                } else if let parent = target.ancestry.first {
                    Text("in \(parent)")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            if !locked {
                Button(action: toggle) {
                    Image(systemName: excluded ? "plus" : "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.08), in: .circle)
                }
                .buttonStyle(.plain)
                .help(excluded ? "Include again" : "Leave out of the task")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, locked ? 12 : 8)
        .padding(.vertical, 8)
        .background(Palette.beam.opacity(excluded ? 0.04 : 0.12), in: .rect(cornerRadius: 10, style: .continuous))
        .opacity(excluded ? 0.5 : 1)
    }
}

private struct PinsSection: View {
    let review: SessionReview
    let player: ReviewPlayer
    let card: SnippetCard

    var body: some View {
        let marks = card.snippet.marks
        if !marks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pins").eyebrowStyle(Palette.textTertiary)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                            PinThumbnail(review: review, mark: mark, number: index + 1)
                                .onTapGesture {
                                    player.pause()
                                    player.seek(to: mark.at)
                                }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct PinThumbnail: View {
    let review: SessionReview
    let mark: Mark
    let number: Int
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.05)
                }
            }
            .frame(width: 168, height: 104)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text("\(number)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Palette.flare, in: .circle)
                    .padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            Text(mark.target?.displayName ?? "Pinned spot")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .frame(width: 168, alignment: .leading)
        }
        .task(id: mark.id) {
            image = await review.frame(at: mark.at, maximumSize: CGSize(width: 480, height: 300))
        }
    }
}

private struct ContextSection: View {
    let card: SnippetCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.snippet.primaryContext != nil || card.project != nil {
                Text("Where").eyebrowStyle(Palette.textTertiary)
                VStack(alignment: .leading, spacing: 4) {
                    if let context = card.snippet.primaryContext {
                        HStack(spacing: 6) {
                            Text(context.app.name).font(.system(size: 13, weight: .semibold))
                            if let location = context.location ?? context.windowTitle, location != context.app.name {
                                Text(location)
                                    .font(Typography.mono)
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    if let project = card.project {
                        Text("Repo \(project.rootPath)" + (project.gitBranch.map { " · \($0)" } ?? ""))
                            .font(Typography.mono)
                            .foregroundStyle(Palette.beam)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            if !card.runtimeNotes.isEmpty {
                Text("From the app").eyebrowStyle(Palette.textTertiary).padding(.top, 8)
                ForEach(card.runtimeNotes, id: \.self) { note in
                    Text(note)
                        .font(Typography.mono)
                        .foregroundStyle(Palette.rose.opacity(0.9))
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct HandoffBar: View {
    @Environment(AppModel.self) private var model
    let review: SessionReview
    let card: SnippetCard

    var body: some View {
        HStack(spacing: 14) {
            if case .sent(let destination) = card.state {
                Label("Sent to \(destination)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.mint)
                    .lineLimit(1)
                Spacer()
                Button("Copy task") { copy() }
                    .buttonStyle(GlassPillButtonStyle())
            } else {
                Text("Send to").font(Typography.caption).foregroundStyle(Palette.textTertiary)
                DestinationPicker(card: card)
                    .frame(maxWidth: 360, alignment: .leading)
                Spacer()
                if case .failed(let message) = card.state {
                    Text(message)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.rose)
                        .lineLimit(1)
                }
                if card.state == .sending {
                    ProgressView().controlSize(.small)
                }
                Button("Copy") { copy() }
                    .buttonStyle(QuietButtonStyle())
                Button {
                    Task {
                        await model.dispatcher.send(card)
                        review.save()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Send task")
                        Text("⌘↩").font(Typography.mono).opacity(0.7)
                    }
                }
                .buttonStyle(FlareButtonStyle(large: false))
                .disabled(card.destination == nil || card.isLocked)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .background(Palette.night.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func copy() {
        let snippet = card.deliverableSnippet
        let markdown = (try? TaskComposer.compose(snippet, title: card.title, project: card.project, runtimeNotes: card.runtimeNotes, sessionDirectory: card.sessionDirectory).markdown) ?? card.transcript
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }
}

struct DestinationPicker: View {
    @Environment(AppModel.self) private var model
    let card: SnippetCard

    var body: some View {
        Menu {
            ForEach(model.dispatcher.destinations(for: card), id: \.self) { destination in
                Button(destination.label) { model.dispatcher.choose(destination, for: card) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                Text(card.destination?.label ?? "Choose where to send")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(card.destination == nil ? Palette.amber : Palette.text)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.white.opacity(0.07), in: .capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(card.isLocked)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
