import AppKit
import ScoutCore
import SwiftUI

struct TaskDetail: View {
    @Environment(AppModel.self) private var model
    let review: SessionReview
    let player: ReviewPlayer
    let card: SnippetCard

    static let detailWidth: CGFloat = 340

    var body: some View {
        HStack(spacing: 0) {
            StageColumn(review: review, player: player, card: card)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Palette.hairline).frame(width: 1)
            VStack(spacing: 0) {
                ScoutScroll(indicators: .automatic) {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            TitleField(review: review, card: card)
                            ContextSection(card: card)
                        }
                        TranscriptField(review: review, card: card)
                        TargetsSection(review: review, card: card)
                        RuntimeNotes(card: card)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HandoffBar(review: review, card: card)
            }
            .frame(width: Self.detailWidth)
            .background(Palette.surface)
        }
    }
}

private struct StageColumn: View {
    let review: SessionReview
    let player: ReviewPlayer
    let card: SnippetCard
    @Environment(\.stillRender) private var still
    @Environment(\.stillFrame) private var stillFrame

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                if still, let stillFrame {
                    Image(decorative: stillFrame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.sunken)
                } else if review.video != nil {
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
                    .background(Palette.sunken)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.stroke))
            .onTapGesture { player.toggle() }

            PinsSection(review: review, player: player, card: card)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
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
    @Environment(\.stillRender) private var still

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(position)
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(Palette.textTertiary)
            if still {
                Text(card.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
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
            .font(.system(size: 19, weight: .bold))
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

    private var position: String {
        let range = card.snippet.range
        let number = (review.tasks.firstIndex { $0 === card } ?? 0) + 1
        return "Task \(number) of \(review.tasks.count) · \(SessionTimeline.clock(range.start))–\(SessionTimeline.clock(range.end))"
    }
}

private struct TranscriptField: View {
    let review: SessionReview
    let card: SnippetCard
    @FocusState private var focused: Bool
    @State private var width: CGFloat = 340
    @Environment(\.stillRender) private var still

    static let fontSize: CGFloat = 13.5
    static let lineSpacing: CGFloat = 3

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let bounds = ((text.isEmpty ? " " : text) + " ") as NSString
        let rect = bounds.boundingRect(
            with: CGSize(width: max(40, width - 10), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: style]
        )
        return ceil(rect.height) + 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("What you said").eyebrowStyle(Palette.textTertiary)
                if card.transcriptOverride != nil {
                    StateTag(text: "Edited", tone: .neutral)
                    Spacer(minLength: 0)
                    if !card.isLocked {
                        Button("Use the original") {
                            card.transcriptOverride = nil
                            review.edited(card)
                        }
                        .buttonStyle(QuietButtonStyle())
                        .padding(.vertical, -6)
                    }
                }
            }
            .frame(height: 14)
            if card.isLocked {
                Text(card.transcript)
                    .font(.system(size: Self.fontSize))
                    .lineSpacing(Self.lineSpacing)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Palette.fill, in: .rect(cornerRadius: Radius.card, style: .continuous))
            } else if still {
                Text(card.transcript)
                    .font(.system(size: Self.fontSize))
                    .lineSpacing(Self.lineSpacing)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Palette.surface, in: .rect(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.stroke))
            } else {
                TextEditor(text: Binding(
                    get: { card.transcript },
                    set: { value in
                        card.transcriptOverride = value == card.snippet.transcript ? nil : value
                        review.edited(card)
                    }
                ))
                .font(.system(size: Self.fontSize))
                .lineSpacing(Self.lineSpacing)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .focused($focused)
                .frame(height: Self.height(for: card.transcript, width: width))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .padding(.horizontal, 7)
                .padding(.vertical, 10)
                .background(Palette.surface, in: .rect(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(focused ? Palette.accent : Palette.stroke, lineWidth: focused ? 1.5 : 1))
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
                    .lineLimit(2)
                    .truncationMode(.tail)
                if let source = target.source {
                    Text(source.description)
                        .font(Typography.mono)
                        .foregroundStyle(Palette.textTertiary)
                } else if let parent = target.ancestry.first {
                    Text("in \(parent)")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            if !locked {
                Spacer(minLength: 0)
                Button(action: toggle) {
                    Image(systemName: excluded ? "plus" : "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Palette.fillRaised, in: .rect(cornerRadius: Radius.tag + 1))
                }
                .buttonStyle(.plain)
                .help(excluded ? "Include again" : "Leave out of the task")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, locked ? 12 : 8)
        .padding(.vertical, 8)
        .background(excluded ? Color.clear : Palette.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                ScoutScroll(axis: .horizontal) {
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
            }
        }
    }
}

private struct PinThumbnail: View {
    let review: SessionReview
    let mark: Mark
    let number: Int
    @State private var image: CGImage?
    @Environment(\.stillFrame) private var stillFrame

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image = image ?? stillFrame {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Palette.fill
                }
            }
            .frame(width: 128, height: 80)
            .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(alignment: .topLeading) {
                PinBadge(number: number)
                    .padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
            Text(mark.target?.displayName ?? "Pinned spot")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 128, alignment: .topLeading)
        }
        .task(id: mark.id) {
            image = await review.frame(at: mark.at, maximumSize: CGSize(width: 480, height: 300))
        }
    }
}

private struct ContextSection: View {
    let card: SnippetCard

    var body: some View {
        if card.snippet.primaryContext != nil || card.project != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let context = card.snippet.primaryContext {
                    let location = (context.location ?? context.windowTitle).flatMap { $0 == context.app.name ? nil : $0 }
                    (Text(context.app.name).fontWeight(.semibold).foregroundStyle(Palette.text) + Text(location.map { "  \($0)" } ?? "").foregroundStyle(Palette.textSecondary))
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let project = card.project {
                    Text(project.rootPath.replacingOccurrences(of: NSHomeDirectory(), with: "~") + (project.gitBranch.map { " · \($0)" } ?? ""))
                        .font(Typography.mono)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
    }
}

private struct RuntimeNotes: View {
    let card: SnippetCard

    var body: some View {
        if !card.runtimeNotes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("From the app").eyebrowStyle(Palette.textTertiary)
                ForEach(card.runtimeNotes, id: \.self) { note in
                    Label {
                        Text(note)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.negative)
                    }
                    .font(Typography.mono)
                    .foregroundStyle(Palette.textSecondary)
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
        VStack(alignment: .leading, spacing: 10) {
            if case .sent(let destination) = card.state {
                HStack(spacing: 10) {
                    Label("Sent to \(destination)", systemImage: "checkmark")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.positive)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Copy task") { copy() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                if let message = card.state.problem {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        StatusDot(tone: .negative, size: 6)
                        Text(message).lineLimit(2)
                    }
                    .help(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                }
                DestinationPicker(card: card)
                HStack(spacing: 8) {
                    Button("Copy") { copy() }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer(minLength: 0)
                    if card.state == .sending {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task {
                            await model.dispatcher.send(card)
                            review.save()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(card.state == .sending ? "Sending…" : "Send task")
                            KeyHint("⌘↩", emphasized: true)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(large: false))
                    .disabled(card.destination == nil || card.isLocked)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
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
        ScoutMenu {
            ForEach(model.dispatcher.destinations(for: card), id: \.self) { destination in
                Button(destination.label) { model.dispatcher.choose(destination, for: card) }
            }
        } label: {
            let missing = card.destination == nil
            HStack(spacing: 6) {
                Image(systemName: missing ? "exclamationmark.circle.fill" : "arrow.turn.down.right")
                Text(card.destination?.label ?? "Choose destination")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
            }
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(missing ? Palette.onCaution : Palette.text)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .background(missing ? Palette.cautionFill : Palette.canvas, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(missing ? Color.clear : Palette.stroke))
        }
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
            let size = Self.size(of: subview, within: width)
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
            let size = Self.size(of: subview, within: bounds.width)
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

    private static func size(of subview: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return ideal.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
    }
}
