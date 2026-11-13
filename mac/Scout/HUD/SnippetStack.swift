import ScoutCore
import SwiftUI

struct SnippetStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dispatcher = model.dispatcher
        VStack(alignment: .trailing, spacing: 8) {
            if let session = model.session, session.phase == .live, let open = session.openSnippet {
                FormingCard(snippet: open, manual: session.segmentation == .manual, number: session.closedCount + 1, shortcut: model.breakShortcut.symbols.joined(), onCut: session.splitNow)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            ScoutScroll {
                VStack(spacing: 8) {
                    ForEach(dispatcher.cards.reversed()) { card in
                        SnippetCardView(card: card)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(.bottom, 8)
                .padding(.horizontal, 4)
            }
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
                StateTag(text: manual ? "Rec · Task \(number)" : "Rec · Listening", tone: .active)
                WaitingDots(color: Palette.accent)
                Spacer()
                if let context = snippet.primaryContext {
                    Text(context.app.name)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
                Button(action: onCut) {
                    HStack(spacing: 4) {
                        Image(systemName: "scissors")
                        Text(manual ? "Next" : "Cut")
                        if manual { KeyHint(shortcut) }
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(QuietButtonStyle())
            }
            Text(snippet.transcript.isEmpty ? "…" : SnippetCardView.excerpt(snippet.transcript, limit: 220))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.text)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 15)
        .padding([.trailing, .vertical], 12)
        .background(Palette.hud, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay(alignment: .leading) { StateRail(color: Palette.recording) }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.accent, lineWidth: 1.5)
        }
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

struct SnippetCardView: View {
    @Environment(AppModel.self) private var model
    let card: SnippetCard
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                CardStateTag(state: card.state)
                if let context = card.snippet.primaryContext {
                    Text(Self.where(context))
                        .font(Typography.caption)
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
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(Palette.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !card.state.isFinished {
            Text(Self.excerpt(card.transcript, limit: 180))
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            let targets = card.state.isFinished ? [] : Array(card.targets.prefix(2))
            if !targets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(targets) { target in
                        Text(target.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(Palette.fillRaised, in: .rect(cornerRadius: Radius.tag, style: .continuous))
                    }
                }
            }

            HStack(spacing: 8) {
                DestinationMenu(card: card)
                Spacer(minLength: 4)
                DeliveryControl(card: card)
            }
        }
        .padding(.leading, 15)
        .padding([.trailing, .vertical], 12)
        .background(Palette.hud, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay(alignment: .leading) { StateRail(color: CardStateTag.color(for: card.state)) }
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.stroke))
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)

        .onHover { hovering = $0 }
    }

    static func `where`(_ context: AppContext) -> String {
        guard let location = context.location, location != context.app.name else { return context.app.name }
        if location.hasPrefix(context.app.name) { return location }
        return "\(context.app.name) · \(location)"
    }

    static func excerpt(_ text: String, limit: Int) -> String {
        text.count > limit ? "…" + text.suffix(limit) : text
    }
}

private struct DestinationMenu: View {
    @Environment(AppModel.self) private var model
    let card: SnippetCard

    var body: some View {
        ScoutMenu {
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
                Text(card.destination?.label ?? "Choose destination")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(card.destination == nil ? Palette.caution : Palette.textSecondary)
        }
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
            EmptyView()
                .help(destination == "clipboard" ? "Copied to the clipboard" : "Sent to \(destination)")
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
                Circle().stroke(Palette.fillStrong, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: total > 0 ? remaining / total : 0)
                    .stroke(Palette.text, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
        }
    }
}

struct StateRail: View {
    var color: Color

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 3)
    }
}

struct CardStateTag: View {
    let state: SnippetCard.State

    var body: some View {
        switch state {
        case .needsDestination: StateTag(text: "Needs destination", tone: .caution)
        case .countdown: StateTag(text: "Sending", tone: .active)
        case .sending: StateTag(text: "Sending", tone: .active)
        case .sent("clipboard"): StateTag(text: "Copied", tone: .positive)
        case .sent: StateTag(text: "Sent", tone: .positive)
        case .failed: StateTag(text: "Failed", tone: .negative)
        case .copiedInstead: StateTag(text: "Copied", tone: .caution)
        case .withdrawn: StateTag(text: "Withdrawn", tone: .neutral)
        case .held: StateTag(text: "Held", tone: .neutral)
        case .preparing: StateTag(text: "Preparing", tone: .neutral)
        }
    }

    static func color(for state: SnippetCard.State) -> Color {
        switch state {
        case .needsDestination, .copiedInstead: Palette.caution
        case .countdown, .sending: Palette.accent
        case .sent: Palette.positive
        case .failed: Palette.negative
        case .withdrawn, .held, .preparing: Palette.stroke
        }
    }
}
