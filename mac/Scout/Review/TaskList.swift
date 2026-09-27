import ScoutCore
import SwiftUI

struct TaskList: View {
    let review: SessionReview
    let player: ReviewPlayer

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Tasks").eyebrowStyle(Palette.textTertiary)
                        Spacer()
                        Text(summary)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)

                    ForEach(Array(review.tasks.enumerated()), id: \.element.id) { index, card in
                        TaskRow(card: card, index: index, selected: card.snippet.id == review.selectedTask?.snippet.id)
                            .id(card.id)
                            .onTapGesture {
                                player.pause()
                                review.select(card)
                                player.seek(to: card.snippet.range.start)
                            }
                    }

                    if review.tasks.isEmpty {
                        Text(review.isLive ? "Tasks appear here as you talk." : "No tasks. Pick up speech below, or split the timeline.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.textTertiary)
                            .padding(10)
                    }

                    let leftovers = review.leftoverSpeech
                    if !leftovers.isEmpty {
                        Text("Not in a task yet")
                            .eyebrowStyle(Palette.amber.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                        ForEach(leftovers) { utterance in
                            let neighbor = review.neighbor(for: utterance)
                            LeftoverRow(
                                utterance: utterance,
                                neighborNumber: neighbor.flatMap { card in review.tasks.firstIndex { $0 === card }.map { $0 + 1 } },
                                onMakeTask: {
                                    player.pause()
                                    let card = review.makeTask(from: utterance)
                                    player.seek(to: card.snippet.range.start)
                                },
                                onAttach: {
                                    guard let neighbor else { return }
                                    player.pause()
                                    review.attach(utterance, to: neighbor)
                                    player.seek(to: neighbor.snippet.range.start)
                                },
                                onPreview: { player.seek(to: utterance.range.start) }
                            )
                        }
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.never)
            .onChange(of: review.selectedTask?.id) { _, id in
                guard let id else { return }
                withAnimation(Motion.smooth) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var summary: String {
        let count = review.tasks.count
        let waiting = review.unsentCount
        if count == 0 { return "" }
        return waiting == 0 ? "\(count) sent" : "\(waiting) of \(count) to send"
    }
}

private struct TaskRow: View {
    let card: SnippetCard
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? Palette.ink : Palette.text)
                .frame(width: 22, height: 22)
                .background(badgeColor.opacity(selected ? 1 : 0.35), in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(SessionTimeline.clock(card.snippet.range.start))
                        .monospacedDigit()
                    Text("·")
                    Text(String(format: "%.0f s", card.snippet.range.duration))
                        .monospacedDigit()
                    if let app = card.snippet.primaryContext?.app.name {
                        Text("·")
                        Text(app).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)
                StateLine(card: card)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.white.opacity(0.09) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Palette.flare.opacity(0.5) : .clear, lineWidth: 1)
        }
        .contentShape(.rect(cornerRadius: 12))
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private var badgeColor: Color {
        card.state.isFinished ? Palette.mint : (selected ? Palette.flare : Palette.beam)
    }
}

struct StateLine: View {
    let card: SnippetCard

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
    }

    private var symbol: String {
        switch card.state {
        case .sent: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .sending: "arrow.up.circle"
        case .countdown: "timer"
        case .needsDestination: "questionmark.circle"
        default: "circle.dashed"
        }
    }

    private var text: String {
        switch card.state {
        case .sent(let destination): "Sent to \(destination)"
        case .failed: "Couldn't send"
        case .sending: "Sending…"
        case .countdown: "Sending soon"
        case .needsDestination: "Choose where it goes"
        case .preparing: "Preparing"
        case .held, .withdrawn: card.destination.map { "To \($0.label)" } ?? "Ready"
        }
    }

    private var tint: Color {
        switch card.state {
        case .sent: Palette.mint
        case .failed: Palette.rose
        case .needsDestination: Palette.amber
        default: Palette.textSecondary
        }
    }
}

private struct LeftoverRow: View {
    let utterance: Utterance
    let neighborNumber: Int?
    let onMakeTask: () -> Void
    let onAttach: () -> Void
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("“\(utterance.text)”")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(perform: onPreview)
            HStack(spacing: 6) {
                Button(action: onMakeTask) {
                    Label("New task", systemImage: "plus")
                }
                .help("Make this its own task")
                if let neighborNumber {
                    Button(action: onAttach) {
                        Label("Add to task \(neighborNumber)", systemImage: "arrow.turn.left.up")
                    }
                    .help("Include this in task \(neighborNumber)")
                }
            }
            .buttonStyle(LeftoverActionStyle())
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.amber.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}

private struct LeftoverActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.amber)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Palette.amber.opacity(configuration.isPressed ? 0.3 : 0.14), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
