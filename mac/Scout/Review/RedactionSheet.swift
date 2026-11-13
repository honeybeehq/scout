import AVFoundation
import ScoutCore
import SwiftUI

struct RedactionSheet: View {
    enum Mode: String, Hashable, CaseIterable {
        case edit, preview

        var title: String {
            switch self {
            case .edit: "Hide parts"
            case .preview: "Preview upload"
            }
        }
    }

    @Environment(AppModel.self) private var model
    let review: SessionReview
    let card: SnippetCard

    @State private var frame: CGImage?
    @State private var strip: [CGImage] = []
    @State private var scrub: SessionTime = 0
    @State private var selection: TimeRange?
    @State private var dragStart: SessionTime?
    @State private var draft: CGRect?
    @State private var chosen: String?
    @State private var history: [ClipRedaction] = []
    @State private var suggestions: [RedactedRegion] = []
    @State private var media: RenderedMedia?
    @State private var rendering = false
    @State private var previewFrame: CGImage?
    @State private var previewTime: Double = 0

    private let canvasWidth: CGFloat = 540

    private var clip: TimeRange { card.clipRange }
    private var redaction: ClipRedaction { card.linearOptions.redaction ?? ClipRedaction() }
    private var mode: Mode { card.redactionSheet ?? .edit }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    if mode == .edit {
                        canvas
                        timeline
                        hint
                    } else {
                        preview
                    }
                }
                .frame(width: canvasWidth)
                sidebar
            }
            .padding(20)
            Spacer(minLength: 0)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            footer
        }
        .frame(width: 840, height: 700)
        .background(Palette.surface)
        .task {
            scrub = card.snippet.range.start
            await loadStrip()
            if !CredentialDetectors.installed.isEmpty, let video = review.video {
                let found = await CredentialDetectors.suggestions(for: video)
                suggestions = found.filter { suggestion in !redaction.regions.contains { $0.rect == suggestion.rect } }
            }
        }
        .task(id: scrub) {
            frame = await review.frame(at: scrub, maximumSize: CGSize(width: 1280, height: 800))
        }
        .task(id: renderKey) {
            media = nil
            guard mode == .preview else { return }
            rendering = true
            media = await model.dispatcher.preparedVideo(for: card)
            rendering = false
        }
        .task(id: media) {
            await play()
        }
    }

    private var renderKey: String {
        "\(mode.rawValue)|\(redaction.fingerprint)"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Video for Linear").eyebrowStyle(Palette.textTertiary)
                Text(card.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text("Hidden areas are covered with a solid block, not a blur. Cut parts are removed. Nothing leaves this Mac until you file.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            SegmentedChoice(options: Mode.allCases, selection: Binding(
                get: { mode },
                set: { card.redactionSheet = $0 }
            ), title: \.title)
        }
        .padding(20)
    }

    private var aspect: CGFloat {
        guard let frame, frame.height > 0 else { return 16 / 10 }
        return CGFloat(frame.width) / CGFloat(frame.height)
    }

    private var canvas: some View {
        let height = canvasWidth / aspect
        return ZStack(alignment: .topLeading) {
            if let frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Palette.sunken
            }
            ForEach(redaction.regions) { region in
                block(region, size: CGSize(width: canvasWidth, height: height), active: region.isActive(at: scrub))
            }
            ForEach(suggestions) { suggestion in
                let rect = viewRect(suggestion.rect, size: CGSize(width: canvasWidth, height: height))
                Rectangle()
                    .strokeBorder(Palette.caution, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .onTapGesture { accept(suggestion) }
                    .help("Suggested by \(suggestion.originName). Click to hide it.")
            }
            if let draft {
                Rectangle()
                    .fill(Color(cgColor: ClipRedactor.fillCG).opacity(0.85))
                    .overlay(Rectangle().strokeBorder(Palette.accent, lineWidth: 1.5))
                    .frame(width: draft.width, height: draft.height)
                    .offset(x: draft.minX, y: draft.minY)
            }
            if redaction.cuts(scrub) {
                ZStack {
                    Palette.scrim
                    Text("Cut from the clip")
                        .font(Typography.headline)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Color.black.opacity(0.6), in: .rect(cornerRadius: Radius.control, style: .continuous))
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: canvasWidth, height: height)
        .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 4).onChanged { value in
            draft = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                           width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                .intersection(CGRect(x: 0, y: 0, width: canvasWidth, height: height))
        }.onEnded { _ in
            defer { draft = nil }
            guard let draft, draft.width > 6, draft.height > 6 else { return }
            let rect = Rect(x: draft.minX / canvasWidth, y: draft.minY / height, width: draft.width / canvasWidth, height: draft.height / height)
            let region = RedactedRegion(rect: rect, range: selection)
            change { $0.regions.append(region) }
            chosen = region.id
        })
    }

    private func block(_ region: RedactedRegion, size: CGSize, active: Bool) -> some View {
        let rect = viewRect(region.rect, size: size)
        return Group {
            if active {
                Rectangle()
                    .fill(Color(cgColor: ClipRedactor.fillCG))
                    .overlay(Rectangle().strokeBorder(chosen == region.id ? Palette.accent : Color(cgColor: ClipRedactor.edgeCG), lineWidth: chosen == region.id ? 2 : 1.5))
            } else {
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .background(Color.black.opacity(0.12))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .onTapGesture { chosen = region.id }
    }

    private func viewRect(_ rect: Rect, size: CGSize) -> CGRect {
        CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }

    private var timeline: some View {
        let height: CGFloat = 44
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(strip.indices, id: \.self) { index in
                            Image(decorative: strip[index], scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: width / CGFloat(max(strip.count, 1)), height: height)
                                .clipped()
                        }
                    }
                    .frame(width: width, height: height, alignment: .leading)
                    .background(Palette.sunken)
                    ForEach(Array(redaction.mergedCuts(in: clip).enumerated()), id: \.offset) { _, cut in
                        Hatching()
                            .frame(width: max(2, x(cut.end, width) - x(cut.start, width)), height: height)
                            .offset(x: x(cut.start, width))
                    }
                    if let selection {
                        Rectangle()
                            .fill(Palette.accentWash)
                            .overlay(Rectangle().strokeBorder(Palette.accent, lineWidth: 1.5))
                            .frame(width: max(2, x(selection.end, width) - x(selection.start, width)), height: height)
                            .offset(x: x(selection.start, width))
                    }
                    Rectangle()
                        .fill(Palette.strokeStrong)
                        .frame(width: 2, height: height + 6)
                        .offset(x: x(scrub, width) - 1, y: -3)
                }
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let start = time(at: value.startLocation.x, width)
                    let now = time(at: value.location.x, width)
                    if abs(value.translation.width) > 3 {
                        selection = TimeRange(start: min(start, now), end: max(start, now))
                    }
                    scrub = now
                }.onEnded { value in
                    if abs(value.translation.width) <= 3 { selection = nil }
                })
            }
            .frame(height: height)
            .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
            HStack(spacing: 8) {
                Text(clock(scrub)).font(Typography.numeric).foregroundStyle(Palette.text)
                Text("of \(IssueComposer.clock(clip.duration))").font(Typography.caption).foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
                if let selection {
                    Text("Selected \(clock(selection.start))–\(clock(selection.end))")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Button("Cut this part") {
                        change { $0.excluded.append(selection) }
                        self.selection = nil
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(card.isLocked)
                }
            }
        }
    }

    private var hint: some View {
        Text(selection == nil
             ? "Drag on the picture to hide an area for the whole clip. Drag across the strip to select a part you can cut, or to hide an area only during that part."
             : "An area you draw now is hidden only during the selected part.")
            .font(Typography.caption)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var preview: some View {
        let height = canvasWidth / aspect
        return VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let previewFrame {
                    Image(decorative: previewFrame, scale: 1).resizable().interpolation(.high)
                } else {
                    Palette.sunken
                    if rendering {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Rendering the clip on this Mac…").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
            .frame(width: canvasWidth, height: height)
            .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
            if let media {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.fillStrong)
                        Capsule().fill(Palette.ink).frame(width: proxy.size.width * CGFloat(min(1, previewTime / max(media.duration, 0.01))))
                    }
                }
                .frame(height: 4)
                HStack(spacing: 6) {
                    StatusDot(tone: .neutral)
                    Text("This is exactly what will be uploaded: \(IssueComposer.clock(previewTime)) of \(IssueComposer.clock(media.duration)) · \(LinearSection.size(media.byteCount))\(media.isRedacted ? " · re-encoded as HEVC" : " · the original clip, no edits")")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            } else if !rendering {
                Text("Scout couldn't render this clip.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.negative)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hidden areas").eyebrowStyle(Palette.textTertiary)
                if redaction.regions.isEmpty {
                    empty("None yet")
                }
                ForEach(Array(redaction.regions.enumerated()), id: \.element.id) { index, region in
                    row(title: "Area \(index + 1)", detail: region.range.map { "\(clock($0.start))–\(clock($0.end))" } ?? "Whole clip", selected: chosen == region.id, cut: false) {
                        change { $0.regions.removeAll { $0.id == region.id } }
                    }
                    .onTapGesture {
                        chosen = region.id
                        if let range = region.range { scrub = range.start }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Cut from the clip").eyebrowStyle(Palette.textTertiary)
                let cuts = redaction.mergedCuts(in: clip)
                if cuts.isEmpty {
                    empty("Nothing cut")
                }
                ForEach(Array(cuts.enumerated()), id: \.offset) { _, cut in
                    row(title: "\(clock(cut.start))–\(clock(cut.end))", detail: "\(Int(cut.duration.rounded())) s", selected: false, cut: true) {
                        change { $0.excluded.removeAll { $0.start < cut.end && $0.end > cut.start } }
                    }
                    .onTapGesture { scrub = cut.start }
                }
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested").eyebrowStyle(Palette.textTertiary)
                    Text("\(suggestions.count) possible secrets found on screen.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Button("Hide all suggested") {
                        let accepted = suggestions
                        change { $0.regions += accepted }
                        suggestions = []
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text("Uploads").eyebrowStyle(Palette.textTertiary)
                Text("\(IssueComposer.clock(redaction.keptDuration(in: clip))) of \(IssueComposer.clock(clip.duration))")
                    .font(Typography.numeric)
                    .foregroundStyle(Palette.text)
                Text(pinNote)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pinNote: String {
        let marks = card.snippet.marks
        guard !marks.isEmpty else { return "No pins on this task." }
        let cut = marks.filter { redaction.cuts(near: $0.at, within: SnippetMedia.pinSlack) }.count
        let covered = marks.filter { !redaction.cuts(near: $0.at, within: SnippetMedia.pinSlack) && !redaction.regions(near: $0.at, within: SnippetMedia.pinSlack).isEmpty }.count
        var parts: [String] = []
        if covered > 0 { parts.append(covered == 1 ? "1 pin image gets the same blocks" : "\(covered) pin images get the same blocks") }
        if cut > 0 { parts.append(cut == 1 ? "1 pin in a cut part is left out" : "\(cut) pins in cut parts are left out") }
        return parts.isEmpty ? "Pin images aren't affected." : parts.joined(separator: ". ") + "."
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Palette.textQuaternary)
            .frame(height: 28)
    }

    private func row(title: String, detail: String, selected: Bool, cut: Bool, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if cut {
                Image(systemName: "scissors")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 14, height: 10)
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(cgColor: ClipRedactor.fillCG))
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Palette.stroke))
                    .frame(width: 14, height: 10)
            }
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.text)
            Text(detail).font(Typography.caption).foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 0)
            if !card.isLocked {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textTertiary)
                .help("Remove")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(selected ? Palette.selection : Palette.fill, in: .rect(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(selected ? Palette.stroke : Palette.hairline))
        .contentShape(.rect)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Undo") {
                guard let last = history.popLast() else { return }
                commit(last)
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(history.isEmpty || card.isLocked)
            .keyboardShortcut("z", modifiers: .command)
            Button("Remove all") { change { $0 = ClipRedaction() } }
                .buttonStyle(QuietButtonStyle())
                .disabled(redaction.isEmpty || card.isLocked)
            Spacer(minLength: 0)
            Text(redaction.isEmpty ? "No edits: the original clip uploads as it is." : "Only the edited clip can upload.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
            Button("Done") { card.redactionSheet = nil }
                .buttonStyle(PrimaryButtonStyle(large: false))
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func change(_ edit: (inout ClipRedaction) -> Void) {
        guard !card.isLocked else { return }
        var next = redaction
        edit(&next)
        guard next != redaction else { return }
        history.append(redaction)
        commit(next)
    }

    private func commit(_ next: ClipRedaction) {
        card.linearOptions.redaction = next.isEmpty ? nil : next
        review.edited(card)
    }

    private func accept(_ suggestion: RedactedRegion) {
        change { $0.regions.append(suggestion) }
        suggestions.removeAll { $0.id == suggestion.id }
    }

    private func x(_ time: SessionTime, _ width: CGFloat) -> CGFloat {
        CGFloat((time - clip.start) / max(clip.duration, 0.01)) * width
    }

    private func time(at x: CGFloat, _ width: CGFloat) -> SessionTime {
        clip.start + Double(min(max(0, x / max(width, 1)), 1)) * clip.duration
    }

    private func clock(_ time: SessionTime) -> String {
        IssueComposer.clock(max(0, time - clip.start))
    }

    private func loadStrip() async {
        let count = 12
        var images: [CGImage] = []
        for index in 0..<count {
            let at = clip.start + clip.duration * (Double(index) + 0.5) / Double(count)
            if let image = await review.frame(at: at, maximumSize: CGSize(width: 200, height: 125)) { images.append(image) }
        }
        strip = images
    }

    private func play() async {
        previewFrame = nil
        previewTime = 0
        guard let media else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.url))
        generator.maximumSize = CGSize(width: 1280, height: 800)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let step = 1.0 / 15
        while !Task.isCancelled {
            var at = 0.0
            while at < media.duration, !Task.isCancelled {
                let began = ContinuousClock.now
                if let image = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image {
                    previewFrame = image
                    previewTime = at
                }
                let spent = (ContinuousClock.now - began) / .seconds(1)
                try? await Task.sleep(for: .seconds(max(0, step - spent)))
                at += step
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
    }
}

private struct Hatching: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            context.stroke(path, with: .color(.white.opacity(0.45)), lineWidth: 1.5)
        }
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
        .allowsHitTesting(false)
    }
}

private extension RedactedRegion {
    var originName: String {
        if case .detector(let id) = origin { id } else { "you" }
    }
}
