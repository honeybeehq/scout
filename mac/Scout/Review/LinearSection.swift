import AppKit
import ScoutCore
import SwiftUI

struct LinearSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.stillRender) private var still
    let review: SessionReview
    let card: SnippetCard
    let target: LinearTarget
    @State private var previewing = false
    @State private var writing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(alignment: .leading, spacing: 0) {
                summary
                SettingRow(title: "Labels", detail: nil) { labels }
                SettingRow(title: "Priority", detail: nil) { priority }
                SettingRow(title: "Video", detail: videoDetail) { video }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(Palette.surface, stroke: Palette.stroke)
            if !card.isLocked {
                DuplicateRow(review: review, card: card, target: target)
            }
            HStack(spacing: 8) {
                Button(card.linearOptions.addTo == nil ? "Preview issue" : "Preview comment") { previewing = true }
                    .buttonStyle(SecondaryButtonStyle())
                Text(leavesTheMac)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: card.briefInput.fingerprint) {
            guard !still else { return }
            await model.linear.loadTeamDetails(target.team.id)
            await model.dispatcher.ensureBrief(for: card)
        }
        .task(id: duplicateKey) {
            guard !still, !card.isLocked else { return }
            await model.dispatcher.checkDuplicates(for: card, in: target, excluding: review.ownLinearIssueIDs, debounce: card.duplicates != .idle)
        }
        .task(id: videoKey) {
            guard !still, !card.isLocked, includesVideo else { return }
            _ = await model.dispatcher.preparedVideo(for: card)
        }
        .sheet(isPresented: $previewing) {
            IssuePreview(draft: model.dispatcher.previewIssue(for: card), target: target, outgoing: Self.outgoing(card, dispatcher: model.dispatcher)) { previewing = false }
        }
        .sheet(isPresented: Binding(get: { card.redactionSheet != nil }, set: { if !$0 { card.redactionSheet = nil } })) {
            RedactionSheet(review: review, card: card)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Linear issue").eyebrowStyle(Palette.textTertiary)
            if card.brief?.edited == true { StateTag(text: "Edited", tone: .neutral) }
            Spacer(minLength: 0)
            if !card.isLocked, OnDeviceSummariser.isAvailable {
                Button(card.brief?.edited == true ? "Use the generated one" : "Regenerate") {
                    Task {
                        await model.dispatcher.ensureBrief(for: card, regenerate: true)
                        review.edited(card)
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(card.isBriefing)
                .padding(.vertical, -6)
            }
        }
        .frame(height: 14)
    }

    @ViewBuilder
    private var summary: some View {
        if card.isBriefing && card.brief?.edited != true || card.brief == nil && !card.isLocked && !still {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Summarising on this Mac…")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.vertical, 12)
        } else if let brief = card.brief, brief.hasSummary || brief.edited || writing && !card.isLocked {
            VStack(alignment: .leading, spacing: 8) {
                BriefField(label: "Problem", text: text(\.problem), locked: card.isLocked)
                BriefField(label: "Expected", text: text(\.expected), locked: card.isLocked)
                BriefField(label: "Actual", text: text(\.actual), locked: card.isLocked)
                BriefField(label: "Steps", text: lines(\.steps), locked: card.isLocked, placeholder: "One step per line")
                BriefField(label: "Done when", text: lines(\.acceptance), locked: card.isLocked, placeholder: "One check per line")
            }
            .padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(OnDeviceSummariser.isAvailable ? "Nothing to summarise yet, so the issue leads with what you said." : "Apple Intelligence is off on this Mac, so the issue leads with what you said.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !card.isLocked {
                    Button("Write a summary") { writing = true }
                        .buttonStyle(QuietButtonStyle())
                        .padding(.horizontal, -8)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private var labels: some View {
        let all = model.dispatcher.teamLabels(target.team.id)
        let chosen = model.dispatcher.labelIDs(for: card, team: target.team.id)
        let names = chosen.compactMap { id in all.first { $0.id == id } }
        let others = all.filter { !chosen.contains($0.id) }
        return HStack(spacing: 6) {
            if names.isEmpty {
                Text("None").font(Typography.caption).foregroundStyle(Palette.textTertiary)
            }
            ForEach(names) { label in
                HStack(spacing: 4) {
                    Text(label.name).lineLimit(1)
                    if !card.isLocked {
                        Button {
                            setLabels(chosen.filter { $0 != label.id })
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.textTertiary)
                        .help("Remove \(label.name)")
                    }
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Palette.fill, in: .rect(cornerRadius: Radius.tag, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.tag, style: .continuous).strokeBorder(Palette.hairline))
            }
            if !card.isLocked, !others.isEmpty {
                ScoutMenu {
                    ForEach(others) { label in
                        Button(label.name) { setLabels(chosen + [label.id]) }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Palette.surface, in: .rect(cornerRadius: Radius.tag, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.tag, style: .continuous).strokeBorder(Palette.stroke))
                }
                .fixedSize()
                .help("Add a label from \(target.team.key)")
            }
        }
    }

    private var priority: some View {
        let current = LinearPriority(rawValue: model.dispatcher.priority(for: card)) ?? .none
        return ChoiceMenu(options: LinearPriority.allCases, selection: Binding(
            get: { current },
            set: { value in
                card.linearOptions.priority = value.rawValue
                review.edited(card)
            }
        ), title: \.title)
        .disabled(card.isLocked)
    }

    private var duplicateKey: String {
        "\(target.team.id)|\(card.isLocked)|\(Dispatcher.duplicateTerm(for: card))"
    }

    private var includesVideo: Bool { model.dispatcher.includesVideo(card) }

    private var videoKey: String {
        "\(includesVideo)|\(card.snippet.range.start)|\(card.snippet.range.end)|\(card.linearOptions.redaction?.fingerprint ?? "")"
    }

    private var video: some View {
        HStack(spacing: 10) {
            if includesVideo, !card.isLocked {
                Button("Hide parts…") { card.redactionSheet = .edit }
                    .buttonStyle(SecondaryButtonStyle())
                    .fixedSize()
            }
            Toggle("", isOn: Binding(
                get: { includesVideo },
                set: { value in
                    card.linearOptions.includeVideo = value
                    review.edited(card)
                }
            ))
            .toggleStyle(SignalToggleStyle())
            .accessibilityLabel("Include video")
            .disabled(card.isLocked || !card.hasRecording)
            .help(card.hasRecording ? "Upload this task's clip to Linear" : "This task has no recording")
        }
    }

    private var videoDetail: String {
        guard card.hasRecording else { return "This task has no recording." }
        if card.linearReceipt?.unlinkedClip == true, card.linearReceipt?.video == nil { return Self.unlinkedNote }
        if let uploaded = card.linearReceipt?.video {
            return "Uploaded \(Self.size(uploaded.byteCount ?? 0))" + (card.linearReceipt?.clipAttachmentID == nil ? "." : " and attached to the issue.")
        }
        guard includesVideo else { return "Off. The clip stays on this Mac." }
        var first = [IssueComposer.clock(model.dispatcher.clipDuration(for: card))]
        if let media = card.preparedVideo, media.redaction == card.linearOptions.redaction {
            first.append(Self.size(media.byteCount))
        } else if card.isPreparingVideo {
            first.append(card.linearOptions.redaction == nil ? "measuring…" : "rendering…")
        }
        var edits: [String] = []
        if let redaction = card.linearOptions.redaction {
            let areas = redaction.regions.count
            let cuts = redaction.mergedCuts(in: card.clipRange).count
            if areas > 0 { edits.append(areas == 1 ? "1 area hidden" : "\(areas) areas hidden") }
            if cuts > 0 { edits.append(cuts == 1 ? "1 part cut" : "\(cuts) parts cut") }
        }
        return ([first.joined(separator: " · ")] + (edits.isEmpty ? [] : [edits.joined(separator: " · ")])).joined(separator: "\n")
    }

    private var leavesTheMac: String {
        if let added = card.linearReceipt?.addedTo { return "Added to \(added.identifier) as a comment." }
        if let issue = card.linearReceipt?.issue { return "Filed in \(target.team.key) as \(issue.identifier)." }
        let outgoing = Self.outgoing(card, dispatcher: model.dispatcher)
        if let addTo = card.linearOptions.addTo {
            return "\(outgoing.list) go to \(addTo.identifier) as a comment.\(outgoing.video ? "" : " No video.")"
        }
        return "\(outgoing.list) go to \(target.team.key) when you file.\(outgoing.video ? "" : " No video.")"
    }

    static func outgoing(_ card: SnippetCard, dispatcher: Dispatcher) -> (list: String, video: Bool) {
        let redaction = card.linearOptions.redaction
        let images = card.hasRecording ? card.snippet.marks.filter { redaction?.cuts(near: $0.at, within: SnippetMedia.pinSlack) != true }.count : 0
        var parts = ["Text"]
        if images > 0 { parts.append(images == 1 ? "1 image" : "\(images) images") }
        let video = dispatcher.includesVideo(card)
        if video {
            let size = card.preparedVideo.flatMap { $0.redaction == redaction ? Self.size($0.byteCount) : nil }
            parts.append("1 video" + (size.map { " (\($0))" } ?? ""))
        }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1] : parts[0]
        return (list, video)
    }

    static let unlinkedNote = "A clip was uploaded earlier and is no longer linked."

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func setLabels(_ ids: [String]) {
        card.linearOptions.labelIDs = ids
        review.edited(card)
    }

    private func text(_ path: WritableKeyPath<TaskBrief, String?>) -> Binding<String> {
        Binding(
            get: { card.brief?[keyPath: path] ?? "" },
            set: { value in edit { $0[keyPath: path] = value.isEmpty ? nil : value } }
        )
    }

    private func lines(_ path: WritableKeyPath<TaskBrief, [String]>) -> Binding<String> {
        Binding(
            get: { card.brief?[keyPath: path].joined(separator: "\n") ?? "" },
            set: { value in edit { $0[keyPath: path] = value.isEmpty ? [] : value.components(separatedBy: "\n") } }
        )
    }

    private func edit(_ change: (inout TaskBrief) -> Void) {
        guard var brief = card.brief, !card.isLocked else { return }
        change(&brief)
        brief.edited = true
        card.brief = brief
        review.edited(card)
    }
}

struct DuplicateRow: View {
    let review: SessionReview
    let card: SnippetCard
    let target: LinearTarget

    var body: some View {
        if let chosen = card.linearOptions.addTo {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Adds a comment to \(chosen.identifier)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    CandidateTitle(title: chosen.title)
                }
                Spacer(minLength: 0)
                Button("File new") { choose(nil) }
                    .buttonStyle(QuietButtonStyle())
                    .fixedSize()
                    .help("File this task as its own issue instead")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(Palette.surface, stroke: Palette.stroke)
        } else {
            switch card.duplicates {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Looking for similar open issues in \(target.team.key)…")
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
            case .failed:
                HStack(spacing: 6) {
                    StatusDot(tone: .neutral)
                    Text("Couldn't check \(target.team.key) for similar issues.")
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
            case .found(_, let candidates) where !candidates.isEmpty:
                if card.linearOptions.fileNew == true {
                    HStack(spacing: 6) {
                        StatusDot(tone: .neutral)
                        Text(candidates.count == 1 ? "Files as a new issue. 1 similar open issue." : "Files as a new issue. \(candidates.count) similar open issues.")
                        Spacer(minLength: 0)
                        Button("Show") { card.linearOptions.fileNew = nil; review.edited(card) }
                            .buttonStyle(QuietButtonStyle())
                            .padding(.vertical, -6)
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                } else {
                    found(candidates)
                }
            default:
                EmptyView()
            }
        }
    }

    private func found(_ candidates: [LinearCandidate]) -> some View {
        let first = candidates[0]
        let rest = Array(candidates.dropFirst())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(tone: .caution)
                Text(candidates.count == 1 ? "Similar open issue" : "Similar open issues")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: first.identifier)
                    .font(Typography.mono)
                    .foregroundStyle(Palette.text)
                    .fixedSize()
                CandidateTitle(title: first.title)
                    .layoutPriority(-1)
                if let state = first.state {
                    Spacer(minLength: 0)
                    Text(verbatim: state)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: 8) {
                Button("Add to it") { choose(first) }
                    .buttonStyle(SecondaryButtonStyle())
                    .fixedSize()
                    .help(Text(verbatim: "Add this task to \(first.identifier) as a comment"))
                Button("File new") { choose(nil) }
                    .buttonStyle(QuietButtonStyle())
                    .fixedSize()
                Spacer(minLength: 0)
                if !rest.isEmpty {
                    ScoutMenu {
                        ForEach(rest) { candidate in
                            Button {
                                choose(candidate)
                            } label: {
                                Text(verbatim: "Add to \(candidate.identifier) · \(RemoteText.clean(candidate.title, limit: 60))")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("More (\(rest.count))")
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                    }
                    .fixedSize()
                    .help("Other similar open issues in \(target.team.key)")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(Palette.surface, stroke: Palette.stroke)
    }

    private func choose(_ candidate: LinearCandidate?) {
        guard !card.isLocked else { return }
        card.linearOptions.addTo = candidate
        card.linearOptions.fileNew = candidate == nil ? true : nil
        review.edited(card)
    }
}

private struct CandidateTitle: View {
    let title: String

    var body: some View {
        Text(verbatim: RemoteText.clean(title))
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(Text(verbatim: RemoteText.clean(title)))
    }
}

private struct BriefField: View {
    let label: String
    @Binding var text: String
    let locked: Bool
    var placeholder = "Not said"
    @Environment(\.stillRender) private var still

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 72, alignment: .leading)
            if locked || still {
                Text(text.isEmpty ? "–" : text)
                    .foregroundStyle(text.isEmpty ? Palette.textQuaternary : Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .foregroundStyle(Palette.text)
            }
        }
        .font(.system(size: 12.5))
    }
}

struct IssuePreview: View {
    let draft: IssueDraft
    let target: LinearTarget
    let outgoing: (list: String, video: Bool)
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview · \(target.label)").eyebrowStyle(Palette.textTertiary)
                Text(draft.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    StatusDot(tone: .neutral)
                    Text(summary)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(20)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ScoutScroll(indicators: .automatic) {
                Text(draft.markdown)
                    .font(Typography.mono)
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(Palette.sunken)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                Text(outgoing.video ? "This is the exact text Scout sends. Images and the video upload when you file." : "This is the exact text Scout sends. Images upload when you file.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("# \(draft.title)\n\n\(draft.markdown)", forType: .string)
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Done", action: close)
                    .buttonStyle(PrimaryButtonStyle(large: false))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 620)
        .background(Palette.surface)
    }

    private var summary: String {
        "Leaves this Mac when you file: \(outgoing.list.prefix(1).lowercased() + outgoing.list.dropFirst()) → Linear \(target.team.key).\(outgoing.video ? "" : " No video.")"
    }
}
