import ScoutCore
import SwiftUI

struct SnippetStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dispatcher = model.dispatcher
        VStack(alignment: .trailing, spacing: 10) {
            if let session = model.session, session.phase == .live, let open = session.openSnippet {
                FormingCard(snippet: open, manual: session.segmentation == .manual, number: session.closedCount + 1, shortcut: model.breakShortcut.symbols.joined(), onCut: session.splitNow)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(dispatcher.cards.reversed()) { card in
                        SnippetCardView(card: card)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)

            if dispatcher.cards.contains(where: { $0.state.isFinished }) {
                Button("Clear sent") { withAnimation(Motion.smooth) { dispatcher.dismissDelivered() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .scaledToUISize()
        .animation(Motion.smooth, value: dispatcher.cards.map(\.id))
        .onChange(of: dispatcher.cards.count) { model.stackChanged() }
        .animation(Motion.smooth, value: model.session?.openSnippet?.id)
    }
}

private struct FormingCard: View {
    let snippet: Snippet
    let manual: Bool
    let number: Int
    let shortcut: String
    let onCut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                WaitingDots(color: Palette.textSecondary)
                Text(manual ? "Task \(number)" : "Listening")
                    .eyebrowStyle()
                Spacer()
                if let context = snippet.primaryContext {
                    Text(context.app.name)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
                Button(action: onCut) {
                    Label(manual ? "Next \(shortcut)" : "Cut", systemImage: "scissors")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(manual ? Palette.text : Palette.textSecondary)
            }
            Text(snippet.transcript.isEmpty ? "…" : SnippetCardView.excerpt(snippet.transcript, limit: 220))
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .glassEffect(.regular.tint(Palette.ink.opacity(0.5)), in: .rect(cornerRadius: 18))
    }
}

struct SnippetCardView: View {
    @Environment(AppModel.self) private var model
    let card: SnippetCard
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if let context = card.snippet.primaryContext {
                    Text(Self.where(context))
                        .font(Typography.mono)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if hovering {
                    Button {
                        withAnimation(Motion.smooth) { card.state.isFinished ? model.dispatcher.removeFromStack(card) : model.dispatcher.withdraw(card) }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textTertiary)
                    .help("Dismiss")
                }
            }

            Text(card.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(2)

            Text(Self.excerpt(card.transcript, limit: 180))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(3)

            let targets = card.targets.prefix(2)
            if !targets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(targets)) { target in
                        Text(target.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Palette.fillRaised, in: .capsule)
                    }
                }
            }

            HStack(spacing: 8) {
                DestinationMenu(card: card)
                Spacer(minLength: 4)
                DeliveryControl(card: card)
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(Palette.ink.opacity(0.45)), in: .rect(cornerRadius: 18))
        .opacity(card.state.isFinished ? 0.72 : 1)
        .onHover { hovering = $0 }
    }

    static func `where`(_ context: AppContext) -> String {
        if let location = context.location { return "\(context.app.name) · \(location)" }
        return context.app.name
    }

    static func excerpt(_ text: String, limit: Int) -> String {
        text.count > limit ? "…" + text.suffix(limit) : text
    }
}

private struct DestinationMenu: View {
    @Environment(AppModel.self) private var model
    let card: SnippetCard

    var body: some View {
        Menu {
            ForEach(model.dispatcher.destinations(for: card), id: \.self) { destination in
                Button(destination.label) { model.dispatcher.choose(destination, for: card) }
            }
        } label: {
            HStack(spacing: 5) {
                if card.destination == nil {
                    StatusDot(tone: .caution, size: 5)
                } else {
                    Image(systemName: "arrow.turn.down.right")
                }
                Text(card.destination?.label ?? "Choose where to send")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.textSecondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(maxWidth: 230, alignment: .leading)
        .disabled(card.state == .sending || card.state.isFinished)
    }
}

private struct DeliveryControl: View {
    @Environment(AppModel.self) private var model
    let card: SnippetCard

    var body: some View {
        switch card.state {
        case .preparing:
            ProgressView().controlSize(.mini)
        case .countdown(let until):
            Button {
                model.dispatcher.hold(card)
            } label: {
                HStack(spacing: 6) {
                    CountdownRing(until: until, total: model.dispatcher.autoSendDelay)
                    Text("Hold")
                }
                .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)
            .help("Sending soon. Click to hold.")
        case .needsDestination, .held:
            Button("Send") { Task { await model.dispatcher.send(card) } }
                .buttonStyle(PrimaryButtonStyle(large: false))
                .disabled(card.destination == nil)
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Sending").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
        case .sent(let destination):
            Label("Sent", systemImage: "checkmark")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize()
                .help("Sent to \(destination)")
        case .withdrawn:
            EmptyView()
        case .failed, .copiedInstead:
            Button {
                Task { await model.dispatcher.send(card) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(card.state.problem ?? "")
        }
    }
}

private struct CountdownRing: View {
    let until: Date
    let total: TimeInterval

    var body: some View {
        let until = until
        let total = total
        TimelineView(.animation(minimumInterval: 1 / 30)) { @Sendable context in
            let remaining = max(0, until.timeIntervalSince(context.date))
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: total > 0 ? remaining / total : 0)
                    .stroke(Palette.text, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
        }
    }
}
