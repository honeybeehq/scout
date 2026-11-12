import ScoutCore
import SwiftUI

struct OptimisePanel: View {
    let review: SessionReview
    let player: ReviewPlayer
    @Environment(\.stillRender) private var still

    private var optimise: OptimiseReview { review.optimise }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch optimise.state {
            case .idle:
                idle
            case .preparing, .running:
                running
            case .ready:
                ready
            case .failed(let message):
                failed(message)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .animation(Motion.smooth, value: optimise.state)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                optimise.start()
            } label: {
                Label("Optimise tasks", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(review.unsentCount == 0)
            .help("Claude suggests merges, splits, titles, frames and questions. Nothing changes until you accept.")
            Text(review.unsentCount == 0 ? "Every task is sent, so there is nothing left to optimise." : "Sends the transcript and frames to Claude, never the video.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(tone: .active)
                Text(optimise.state == .preparing ? "Getting ready…" : "Claude is optimising…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                Button("Cancel") { optimise.cancel() }
                    .buttonStyle(QuietButtonStyle())
                    .padding(.vertical, -6)
            }
            ProgressSweep(animated: !still)
            HStack(spacing: 6) {
                Text(optimise.phase ?? "Reading the session")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Elapsed(since: optimise.startedAt, still: still)
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.textTertiary)
        }
    }

    private var ready: some View {
        let counts = Counts(optimise)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Text(counts.headline)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            if let error = optimise.error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StatusDot(tone: .negative, size: 5)
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            }
            if !counts.detail.isEmpty {
                Text(counts.accepted > 0 && review.canUndo ? counts.detail + " · ⌘Z undoes" : counts.detail)
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(Palette.textTertiary)
            }
            if counts.pending > 0 {
                HStack(spacing: 6) {
                    if counts.bulk > 0 {
                    Button {
                        optimise.acceptAll()
                    } label: {
                        Text(counts.bulk == counts.pending ? "Accept all \(counts.bulk)" : "Accept \(counts.bulk)")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(InkButtonStyle())
                    }
                    if let next = nextTask {
                        Button {
                            player.pause()
                            review.select(next)
                            player.seek(to: next.snippet.range.start)
                        } label: {
                            Label(counts.bulk > 0 ? "Next" : "Show it", systemImage: "arrow.down")
                                .frame(maxWidth: counts.bulk > 0 ? nil : .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Go to the next task with a suggestion")
                    }
                }
                if counts.crossing > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "scissors")
                        Text(counts.crossing == 1 ? "1 crosses a cut you made. Accept it on its task." : "\(counts.crossing) cross cuts you made. Accept those on their tasks.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                }
            } else {
                Button {
                    optimise.start()
                } label: {
                    Label("Optimise again", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(review.unsentCount == 0)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(tone: .negative)
                Text("Optimise didn't finish")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
            }
            Text(message.localizedCaseInsensitiveContains("unchanged") ? message : "\(message) Your tasks are as you left them.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button {
                optimise.start()
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var nextTask: SnippetCard? {
        let withSuggestions = review.tasks.filter { !optimise.proposals(for: $0.snippet.id).isEmpty }
        guard !withSuggestions.isEmpty else { return nil }
        let current = review.tasks.firstIndex { $0.snippet.id == review.selectedTask?.snippet.id } ?? -1
        return withSuggestions.first { card in (review.tasks.firstIndex { $0 === card } ?? 0) > current } ?? withSuggestions.first.flatMap { $0.snippet.id == review.selectedTask?.snippet.id ? nil : $0 }
    }

    struct Counts {
        var total = 0
        var pending = 0
        var accepted = 0
        var rejected = 0
        var stale = 0
        var crossing = 0
        var tasks = 0

        init(_ optimise: OptimiseReview) {
            var touched = Set<String>()
            for proposal in optimise.proposals {
                total += 1
                switch optimise.status(for: proposal) {
                case .pending:
                    pending += 1
                    if proposal.crossesMarkedCut == true { crossing += 1 }
                    if let first = proposal.tasks.first { touched.insert(first) }
                case .accepted: accepted += 1
                case .rejected: rejected += 1
                case .stale: stale += 1
                }
            }
            tasks = touched.count
        }

        var bulk: Int { pending - crossing }

        var headline: String {
            if total == 0 { return "No suggestions. The tasks look right." }
            if pending == 0 { return total == 1 ? "The suggestion is decided" : "All \(total) suggestions decided" }
            let noun = pending == 1 ? "suggestion" : "suggestions"
            return tasks <= 1 ? "\(pending) \(noun) left" : "\(pending) \(noun) on \(tasks) tasks"
        }

        var detail: String {
            var parts: [String] = []
            if accepted > 0 { parts.append("\(accepted) accepted") }
            if rejected > 0 { parts.append("\(rejected) dismissed") }
            if stale > 0 { parts.append("\(stale) no longer fit") }
            return parts.joined(separator: " · ")
        }
    }
}

struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(isEnabled ? Palette.onInk : Palette.textTertiary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(isEnabled ? Palette.ink : Palette.fillRaised, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(.rect(cornerRadius: Radius.control))
    }
}

private struct ProgressSweep: View {
    var animated: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.fillRaised)
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: width * 0.32)
                    .offset(x: (animated ? phase : 0.34) * width * 1.32 - width * 0.32)
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .accessibilityLabel("Working")
    }
}

private struct Elapsed: View {
    let since: Date?
    let still: Bool

    var body: some View {
        if still {
            text(42)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                text(since.map { context.date.timeIntervalSince($0) } ?? 0)
            }
        }
    }

    private func text(_ seconds: TimeInterval) -> some View {
        Text("\(SessionTimeline.clock(max(0, seconds))) of \(SessionTimeline.clock(180))")
            .monospacedDigit()
            .fixedSize()
    }
}

struct SuggestionsSection: View {
    let review: SessionReview
    let player: ReviewPlayer
    let card: SnippetCard

    var body: some View {
        let optimise = review.optimise
        let pending = optimise.proposals(for: card.snippet.id)
        let decided = optimise.proposals.filter { $0.tasks.contains(card.snippet.id) && [.accepted, .rejected].contains(optimise.status(for: $0)) }
        if !pending.isEmpty || !decided.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Palette.textTertiary)
                    Text("Claude suggests").eyebrowStyle(Palette.textTertiary)
                    Spacer(minLength: 0)
                    if !pending.isEmpty {
                        Text("\(pending.count) to decide")
                            .font(Typography.caption.monospacedDigit())
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                ForEach(pending) { proposal in
                    SuggestionCard(review: review, player: player, card: card, proposal: proposal)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                ForEach(decided) { proposal in
                    DecidedLine(review: review, proposal: proposal, taskID: card.snippet.id)
                }
            }
            .animation(Motion.smooth, value: pending.map(\.id))
        }
    }
}

private struct SuggestionCard: View {
    let review: SessionReview
    let player: ReviewPlayer
    let card: SnippetCard
    let proposal: OptimiseProposal

    var body: some View {
        let optimise = review.optimise
        let blocked = optimise.validationMessage(for: proposal)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: Wording.symbol(proposal.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 14)
                Text(Wording.heading(proposal, in: review, from: card.snippet.id))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if proposal.crossesMarkedCut == true {
                CutNotice(proposal: proposal)
            }
            SuggestionBody(review: review, player: player, card: card, proposal: proposal)
            Text(proposal.why)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(Wording.accept(proposal.kind)) {
                    player.pause()
                    withAnimation(Motion.smooth) { optimise.accept(proposal.id) }
                }
                .buttonStyle(InkButtonStyle())
                .disabled(blocked != nil)
                .help(blocked ?? "Accept this suggestion. ⌘Z undoes it.")
                Button("Dismiss") {
                    withAnimation(Motion.smooth) { optimise.reject(proposal.id) }
                }
                .buttonStyle(QuietButtonStyle())
                if let blocked {
                    Text(blocked)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(Palette.surface, stroke: Palette.stroke)
    }
}

private struct CutNotice: View {
    let proposal: OptimiseProposal

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "scissors")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.at.map { "Crosses the cut you made at \(SessionTimeline.clock(Double($0) / 1000))" } ?? "Crosses a cut you made")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .monospacedDigit()
                Text("You pressed ⌃⌥B or said “new task” there. Accept all leaves this one for you.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fill, in: .rect(cornerRadius: Radius.control, style: .continuous))
        .overlay(alignment: .leading) { StateRail(color: Palette.cautionFill).padding(.vertical, 6) }
    }
}

private struct SuggestionBody: View {
    let review: SessionReview
    let player: ReviewPlayer
    let card: SnippetCard
    let proposal: OptimiseProposal

    var body: some View {
        let cards = proposal.tasks.compactMap { id in review.tasks.first { $0.snippet.id == id } }
        switch proposal.kind {
        case .merge:
            BeforeAfter {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cards, id: \.id) { task in
                        TaskChip(number: number(task), title: task.title, range: task.snippet.range)
                    }
                }
            } after: {
                TaskChip(number: cards.first.map(number) ?? 0, title: proposal.title ?? cards.first?.title ?? "", range: cards.dropFirst().reduce(cards.first?.snippet.range ?? TimeRange(start: 0, end: 0)) { $0.union($1.snippet.range) }, emphasised: true)
            }
        case .split:
            let at = Double(proposal.at ?? 0) / 1000
            let range = card.snippet.range
            let first = excerpt(card, before: at)
            let second = excerpt(card, after: at)
            let excerpts = !first.isEmpty && !second.isEmpty
            BeforeAfter {
                TaskChip(number: number(card), title: card.title, range: range)
            } after: {
                VStack(alignment: .leading, spacing: 4) {
                    TaskChip(number: number(card), title: card.title, range: TimeRange(start: range.start, end: at), excerpt: excerpts ? first : "", emphasised: true)
                    HStack(spacing: 5) {
                        Image(systemName: "scissors").font(.system(size: 9, weight: .bold))
                        Text("Split at \(SessionTimeline.clock(at, precise: true))").monospacedDigit()
                        Rectangle().fill(Palette.stroke).frame(height: 1)
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.leading, 4)
                    TaskChip(number: number(card) + 1, title: proposal.title ?? "New task", range: TimeRange(start: at, end: range.end), excerpt: excerpts ? second : "", emphasised: true)
                }
            }
        case .retitle:
            BeforeAfter {
                Text(card.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } after: {
                Text(proposal.title ?? "")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .attach, .detach:
            VStack(alignment: .leading, spacing: 6) {
                if let frames = proposal.frames, !frames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(frames, id: \.self) { ms in
                                FrameThumb(review: review, time: Double(ms) / 1000, adding: proposal.kind == .attach)
                                    .onTapGesture { player.pause(); player.seek(to: Double(ms) / 1000) }
                            }
                        }
                    }
                }
                ForEach(proposal.pointers ?? [], id: \.self) { ms in
                    PointerLine(card: card, time: Double(ms) / 1000, adding: proposal.kind == .attach)
                }
            }
        case .flag:
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Palette.ink).frame(width: 2)
                Text(proposal.question ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .drop:
            BeforeAfter {
                TaskChip(number: number(card), title: card.title, range: card.snippet.range)
            } after: {
                Text("Deleted. The speech goes back to Not in a task yet.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func number(_ task: SnippetCard) -> Int {
        (review.tasks.firstIndex { $0 === task } ?? 0) + 1
    }

    private func excerpt(_ task: SnippetCard, before at: SessionTime) -> String {
        let text = task.snippet.utterances.filter { $0.range.end <= at + 0.05 }.map(\.text).joined(separator: " ")
        guard text.count > 64 else { return text }
        let tail = text.suffix(64)
        return "…" + (tail.firstIndex(of: " ").map { String(tail[tail.index(after: $0)...]) } ?? String(tail))
    }

    private func excerpt(_ task: SnippetCard, after at: SessionTime) -> String {
        let text = task.snippet.utterances.filter { $0.range.end > at + 0.05 }.map(\.text).joined(separator: " ")
        return text.count > 64 ? String(text.prefix(64)).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}

private struct BeforeAfter<Before: View, After: View>: View {
    @ViewBuilder var before: Before
    @ViewBuilder var after: After

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Now").eyebrowStyle(Palette.textTertiary)
            before
                .background(Palette.fill, in: .rect(cornerRadius: Radius.control, style: .continuous))
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)
                Text("After").eyebrowStyle(Palette.textSecondary)
            }
            .padding(.top, 3)
            after
                .background(Palette.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.ink, lineWidth: 1.25))
        }
    }
}

private struct TaskChip: View {
    var number: Int
    var title: String
    var range: TimeRange
    var excerpt: String = ""
    var emphasised = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(format: "%02d", number))
                .font(.system(size: 10, weight: .heavy).monospacedDigit())
                .foregroundStyle(emphasised ? Palette.onInk : Palette.textSecondary)
                .frame(width: 22, height: 17)
                .background(emphasised ? Palette.ink : Palette.fillRaised, in: .rect(cornerRadius: Radius.tag, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: emphasised ? .bold : .semibold))
                    .foregroundStyle(emphasised ? Palette.text : Palette.textSecondary)
                    .lineLimit(emphasised ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(SessionTimeline.clock(range.start))–\(SessionTimeline.clock(range.end)) · \(String(format: "%.0f s", range.duration))")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.textTertiary)
                if !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FrameThumb: View {
    let review: SessionReview
    let time: SessionTime
    let adding: Bool
    @State private var image: CGImage?
    @Environment(\.stillFrame) private var stillFrame

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                Palette.sunken
                if let shown = image ?? stillFrame {
                    Image(decorative: shown, scale: 1).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 84, height: 52)
            .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(adding ? Palette.ink : Palette.stroke, style: StrokeStyle(lineWidth: adding ? 1.25 : 1, dash: adding ? [] : [3, 2])))
            .opacity(adding ? 1 : 0.55)
            Text("\(adding ? "+" : "−") \(SessionTimeline.clock(time, precise: true))")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.textSecondary)
        }
        .task(id: time) {
            if stillFrame == nil { image = await review.frame(at: time, maximumSize: CGSize(width: 240, height: 150)) }
        }
        .help(adding ? "Add the frame at this moment to the task" : "Leave this frame out of the task")
    }
}

private struct PointerLine: View {
    let card: SnippetCard
    let time: SessionTime
    let adding: Bool

    var body: some View {
        let focus = card.snippet.focuses.min { abs($0.range.start - time) < abs($1.range.start - time) }
        HStack(spacing: 7) {
            Image(systemName: adding ? "plus" : "minus")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 16, height: 16)
                .background(Palette.fillRaised, in: .rect(cornerRadius: Radius.tag, style: .continuous))
            Image(systemName: "cursorarrow.rays").foregroundStyle(Palette.textTertiary)
            Text(focus.flatMap { $0.target.label ?? $0.target.role } ?? "Pointer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(adding ? Palette.text : Palette.textSecondary)
                .strikethrough(!adding, color: Palette.textTertiary)
                .lineLimit(1)
            Text(SessionTimeline.clock(time, precise: true))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 0)
        }
    }
}

private struct DecidedLine: View {
    let review: SessionReview
    let proposal: OptimiseProposal
    var taskID: String?

    var body: some View {
        let status = review.optimise.status(for: proposal)
        HStack(spacing: 7) {
            Image(systemName: status == .accepted ? "checkmark" : status == .stale ? "exclamationmark.circle" : "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(status == .accepted ? Palette.text : Palette.textTertiary)
                .frame(width: 14)
            Text(line(status))
                .font(.system(size: 12, weight: status == .accepted ? .semibold : .regular))
                .foregroundStyle(status == .accepted ? Palette.textSecondary : Palette.textTertiary)
                .lineLimit(2)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(Palette.fill, in: .rect(cornerRadius: Radius.control, style: .continuous))
    }

    private func line(_ status: OptimiseReview.ProposalStatus) -> String {
        let heading = Wording.heading(proposal, in: review, from: taskID)
        switch status {
        case .accepted: return Wording.done(proposal, heading: heading)
        case .rejected: return "Dismissed: \(heading.prefix(1).lowercased() + heading.dropFirst())"
        case .stale: return "\(heading): \(review.optimise.validationMessage(for: proposal) ?? "no longer fits")"
        case .pending: return heading
        }
    }
}

enum Wording {
    static func symbol(_ kind: OptimiseProposal.Kind) -> String {
        switch kind {
        case .merge: "arrow.merge"
        case .split: "scissors"
        case .retitle: "character.cursor.ibeam"
        case .attach: "plus.square"
        case .detach: "minus.square"
        case .flag: "questionmark.bubble"
        case .drop: "trash"
        }
    }

    static func heading(_ proposal: OptimiseProposal, in review: SessionReview, from taskID: String? = nil) -> String {
        let others = proposal.tasks.filter { $0 != (taskID ?? proposal.tasks.first) }
        let numbers = others.compactMap { id in review.tasks.firstIndex { $0.snippet.id == id }.map { String($0 + 1) } }
        let frames = proposal.frames?.count ?? 0
        let pointers = proposal.pointers?.count ?? 0
        let things = [frames > 0 ? (frames == 1 ? "a frame" : "\(frames) frames") : nil, pointers > 0 ? (pointers == 1 ? "a pointer" : "\(pointers) pointers") : nil].compactMap { $0 }.joined(separator: " and ")
        switch proposal.kind {
        case .merge: return numbers.isEmpty ? "Merge with the next task" : "Merge with task " + numbers.joined(separator: " and ")
        case .split: return "Split into two tasks"
        case .retitle: return "Clearer title"
        case .attach: return "Add " + (things.isEmpty ? "frames" : things)
        case .detach: return "Leave out " + (things.isEmpty ? "frames" : things)
        case .flag: return "Ask before sending"
        case .drop: return "Delete this task"
        }
    }

    static func accept(_ kind: OptimiseProposal.Kind) -> String {
        switch kind {
        case .merge: "Merge"
        case .split: "Split"
        case .retitle: "Use title"
        case .attach: "Add"
        case .detach: "Leave out"
        case .flag: "Add question"
        case .drop: "Delete"
        }
    }

    static func done(_ proposal: OptimiseProposal, heading: String) -> String {
        switch proposal.kind {
        case .merge: "Merged"
        case .split: "Split into two tasks"
        case .retitle: "Title changed"
        case .attach: heading.replacingOccurrences(of: "Add ", with: "Added ")
        case .detach: heading.replacingOccurrences(of: "Leave out ", with: "Left out ")
        case .flag: "Question added to the task"
        case .drop: "Deleted"
        }
    }
}

struct SuggestionCount: View {
    let count: Int
    var selected = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
            Text("\(count)").monospacedDigit()
        }
        .font(.system(size: 10.5, weight: .bold))
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .overlay(RoundedRectangle(cornerRadius: Radius.tag, style: .continuous).strokeBorder(Palette.stroke))
        .fixedSize()
        .help(count == 1 ? "1 suggestion from Claude" : "\(count) suggestions from Claude")
    }
}
