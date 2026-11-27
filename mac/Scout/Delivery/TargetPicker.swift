import AppKit
import Observation
import ScoutCore
import SwiftUI

struct TargetSection: Identifiable, Equatable {
    enum Group: String, CaseIterable {
        case suggested
        case focused
        case champions
        case projects
        case sessions
        case other

        var title: String {
            switch self {
            case .suggested: "Suggested"
            case .focused: "Focused chat"
            case .champions: "Champions"
            case .projects: "Project orchestrators"
            case .sessions: "Sessions"
            case .other: "Other"
            }
        }
    }

    var group: Group
    var rows: [ApiaryTarget]
    var start: Int

    var id: String { group.rawValue }
}

@Observable
final class TargetPickerModel {
    enum Phase: Equatable {
        case finishing
        case ready
        case failed(String)
    }

    enum Source: Equatable {
        case loading
        case apiary
        case hive
        case none
    }

    static let clipboardKind = "clipboard"

    static let clipboard: ApiaryTarget = {
        var target = ApiaryTarget(kind: clipboardKind, id: clipboardKind, sessionID: nil, title: "Clipboard only", subtitle: "Copy the walkthrough and send nothing")
        target.viaApiary = false
        return target
    }()

    private(set) var phase: Phase = .finishing
    private(set) var walkthrough: FinishedWalkthrough?
    private(set) var targets: [ApiaryTarget] = [] {
        didSet {
            searchIndex = targets.map(\.searchText)
            suggestedKey = SafeSendVariant.mockSuggestion.flatMap { word in targets.first { $0.title.lowercased().contains(word) }?.key }
            regroup()
        }
    }
    @ObservationIgnored private var searchIndex: [String] = []
    private(set) var sections: [TargetSection] = []
    private(set) var filtered: [ApiaryTarget] = []
    private(set) var source: Source = .loading
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            selection = 0
            regroup()
        }
    }
    var selection = 0 {
        didSet {
            if armed != nil, armed != selected?.key { armed = nil }
        }
    }
    let variant = SafeSendVariant.current
    private(set) var suggestedKey: String?
    private(set) var armed: String?
    private(set) var pending: PendingSend?
    @ObservationIgnored private var holding: Task<Void, Never>?
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored private(set) var pointed = false
    private(set) var queued: DeliveryMode?
    private(set) var delivering = false
    private(set) var confirmation: String?
    private(set) var problem: String?
    private(set) var progress: String?
    private(set) var caution = false
    var focusToken = 0

    var onChoose: ((ApiaryTarget, DeliveryMode) -> Void)?
    var onDismiss: (() -> Void)?
    var onRevealDebug: ((URL) -> Void)?

    init() {
        regroup()
    }

    var debugDirectory: URL? {
        walkthrough?.debugDirectory.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private func section(of target: ApiaryTarget) -> TargetSection.Group {
        if target.kind == Self.clipboardKind { return .other }
        if target.key == suggestedKey { return .suggested }
        if target.focused { return .focused }
        if target.isProject { return .projects }
        if target.isChampion { return .champions }
        return .sessions
    }

    private static func score(_ target: ApiaryTarget, text: String, words: [Substring]) -> Int? {
        let title = target.title.lowercased()
        var total = 0
        for word in words {
            guard text.contains(word) else { return nil }
            if title.hasPrefix(word) {
                total += 0
            } else if title.contains(" \(word)") || title.contains("(\(word)") {
                total += 1
            } else if title.contains(word) {
                total += 2
            } else {
                total += 4
            }
        }
        return total
    }

    private func regroup() {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        var buckets: [TargetSection.Group: [(Int, Int, ApiaryTarget)]] = [:]
        let rows: [(ApiaryTarget, String)] = Array(zip(targets, searchIndex)) + [(Self.clipboard, Self.clipboard.searchText + " copy")]
        for (index, row) in rows.enumerated() {
            guard let score = words.isEmpty ? 0 : Self.score(row.0, text: row.1, words: words) else { continue }
            buckets[section(of: row.0), default: []].append((score, index, row.0))
        }
        var built: [TargetSection] = []
        var start = 0
        for kind in TargetSection.Group.allCases {
            guard let bucket = buckets[kind], !bucket.isEmpty else { continue }
            let sorted = bucket.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.2)
            built.append(TargetSection(group: kind, rows: sorted, start: start))
            start += sorted.count
        }
        sections = built
        filtered = built.flatMap(\.rows)
    }

    var selected: ApiaryTarget? {
        filtered.indices.contains(selection) ? filtered[selection] : nil
    }

    var matchCount: Int {
        filtered.filter { $0.kind != Self.clipboardKind }.count
    }

    var canPaste: Bool { source == .apiary && selected?.viaApiary == true }

    var choosesClipboard: Bool { selected?.kind == Self.clipboardKind }

    var isCompact: Bool { confirmation != nil || progress != nil }

    var isBound: Bool { progress != nil }

    func reset(with walkthrough: FinishedWalkthrough? = nil) {
        holding?.cancel()
        holding = nil
        pending = nil
        armed = nil
        phase = walkthrough == nil ? .finishing : .ready
        self.walkthrough = walkthrough
        targets = []
        source = .loading
        query = ""
        selection = 0
        queued = nil
        delivering = false
        confirmation = nil
        problem = nil
        progress = nil
        caution = false
        focusToken += 1
    }

    func bind(_ target: ApiaryTarget, saying text: String) {
        targets = [target]
        source = .apiary
        queued = .paste
        progress = text
    }

    func ready(_ walkthrough: FinishedWalkthrough) {
        self.walkthrough = walkthrough
        phase = .ready
    }

    func failed(_ message: String) {
        phase = .failed(message)
        queued = nil
    }

    func setTargets(_ targets: [ApiaryTarget], source: Source) {
        let keep = selected
        let moved = selection != 0 || !query.isEmpty
        self.targets = targets
        self.source = source
        if moved, let keep, let index = filtered.firstIndex(where: { $0.key == keep.key }) { selection = index } else { selection = 0 }
    }

    func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        pointed = false
        selection = (selection + delta + count) % count
    }

    func jump(_ delta: Int) {
        let starts = sections.map(\.start)
        guard !starts.isEmpty else { return }
        pointed = false
        if delta > 0 {
            selection = starts.first { $0 > selection } ?? starts[0]
        } else {
            let current = starts.last { $0 <= selection } ?? 0
            selection = current < selection ? current : (starts.last { $0 < current } ?? starts[starts.count - 1])
        }
    }

    var suggested: ApiaryTarget? {
        targets.first { $0.key == suggestedKey }
    }

    func unusual(_ target: ApiaryTarget) -> String? {
        guard variant == .unusual, target.kind != Self.clipboardKind, target.key != suggestedKey, !target.focused else { return nil }
        if let home = suggested?.workspaceLabel ?? targets.first(where: \.focused)?.workspaceLabel, let workspace = target.workspaceLabel, workspace != home {
            return "Other workspace"
        }
        return target.open ? nil : "Not recent"
    }

    func tap(_ index: Int) {
        guard pending == nil, !delivering, confirmation == nil, filtered.indices.contains(index) else { return }
        let target = filtered[index]
        pointed = true
        switch variant {
        case .off, .undo:
            selection = index
            choose(.paste)
        case .select:
            if armed == target.key {
                choose(.paste)
            } else {
                selection = index
                armed = target.key
            }
        case .unusual:
            if unusual(target) == nil || armed == target.key {
                selection = index
                choose(.paste)
            } else {
                selection = index
                armed = target.key
            }
        }
    }

    func choose(_ mode: DeliveryMode) {
        guard !delivering, confirmation == nil, pending == nil, let target = selected else { return }
        armed = nil
        if target.kind == Self.clipboardKind {
            onDismiss?()
            return
        }
        let mode = canPaste ? mode : .send
        if variant == .undo {
            hold(target, mode)
            return
        }
        commit(target, mode)
    }

    private func commit(_ target: ApiaryTarget, _ mode: DeliveryMode) {
        if phase == .finishing {
            queued = mode
        }
        problem = nil
        onChoose?(target, mode)
    }

    private func hold(_ target: ApiaryTarget, _ mode: DeliveryMode) {
        let seconds = SafeSendVariant.undoSeconds
        pending = PendingSend(target: target, mode: mode, started: Date(), seconds: seconds)
        holding?.cancel()
        holding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    func release() {
        guard let pending else { return }
        holding?.cancel()
        holding = nil
        self.pending = nil
        commit(pending.target, pending.mode)
    }

    func undo() {
        guard let pending else { return }
        holding?.cancel()
        holding = nil
        self.pending = nil
        if let index = filtered.firstIndex(where: { $0.key == pending.target.key }) { selection = index }
        focusToken += 1
    }

    func began() {
        delivering = true
        problem = nil
    }

    func confirm(_ text: String, caution: Bool = false) {
        delivering = false
        queued = nil
        confirmation = text
        self.caution = caution
    }

    func refuse(_ message: String) {
        delivering = false
        queued = nil
        problem = message
    }
}

final class TargetPickerController {
    static let size = CGSize(width: 460, height: 520)

    let model = TargetPickerModel()
    private var panel: PickerPanel?
    private var monitor: Any?
    private var closing: Task<Void, Never>?

    var isOpen: Bool { panel?.isVisible == true }

    var frame: CGRect? { panel?.frame }

    func prepare() {
        guard panel == nil else { return }
        let panel = PickerPanel(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.sharingType = SimulationMode.panelSharing
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: TargetPickerView().environment(model))
        host.sizingOptions = []
        panel.contentView = host
        panel.layoutIfNeeded()
        self.panel = panel
    }

    func open(near cursor: CGPoint, takingKeys: Bool = true) {
        prepare()
        guard let panel else { return }
        closing?.cancel()
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: Self.size)
        var origin = CGPoint(x: cursor.x + 12, y: cursor.y - Self.size.height - 12)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - Self.size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        if takingKeys {
            panel.makeKey()
            listen()
        } else {
            panel.resignKey()
            stopListening()
        }
    }

    func close(after delay: Duration = .zero) {
        closing?.cancel()
        closing = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            if delay > .zero {
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    panel.animator().alphaValue = 0
                }
            }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.stopListening()
        }
    }

    func compact() {
        guard let panel else { return }
        var frame = panel.frame
        let height: CGFloat = 52
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    var windowState: [String: Any] {
        guard let panel else { return ["panel": "none"] }
        return [
            "visible": panel.isVisible,
            "alpha": panel.alphaValue,
            "frame": [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height],
            "content": panel.contentView.map { [$0.frame.width, $0.frame.height] } ?? [],
            "onScreen": panel.isOnActiveSpace,
            "occlusionVisible": panel.occlusionState.contains(.visible),
            "level": panel.level.rawValue,
        ]
    }

    func snapshot() -> NSBitmapImageRep? {
        if let panel, panel.isVisible, let image = SnapshotMode.windowImage(CGWindowID(panel.windowNumber)) {
            return NSBitmapImageRep(cgImage: image)
        }
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func post(_ key: PickerKey) {
        guard let panel else { return }
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: key.modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: key.characters,
            charactersIgnoringModifiers: key.characters,
            isARepeat: false,
            keyCode: key.code
        )
        if let event { NSApp.postEvent(event, atStart: false) }
    }

    private func listen() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel || event.windowNumber == panel.windowNumber else { return event }
            let model = self.model
            if model.pending != nil {
                switch event.keyCode {
                case 53: model.undo()
                case 6 where event.modifierFlags.contains(.command): model.undo()
                case 36, 76: model.release()
                default: break
                }
                return nil
            }
            switch event.keyCode {
            case 125:
                model.move(1)
            case 126:
                model.move(-1)
            case 48:
                model.jump(event.modifierFlags.contains(.shift) ? -1 : 1)
            case 36, 76:
                model.choose(event.modifierFlags.contains(.command) ? .send : .paste)
            case 53:
                model.onDismiss?()
            default:
                return event
            }
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct PickerKey {
    var code: UInt16
    var characters: String
    var modifiers: NSEvent.ModifierFlags = []

    static let down = PickerKey(code: 125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!))
    static let up = PickerKey(code: 126, characters: String(UnicodeScalar(NSUpArrowFunctionKey)!))
    static let enter = PickerKey(code: 36, characters: "\r")
    static let commandEnter = PickerKey(code: 36, characters: "\r", modifiers: .command)
    static let escape = PickerKey(code: 53, characters: "\u{1B}")
    static let tab = PickerKey(code: 48, characters: "\t")
    static let shiftTab = PickerKey(code: 48, characters: "\t", modifiers: .shift)
    static let delete = PickerKey(code: 51, characters: "\u{7F}")

    static func character(_ value: Character) -> PickerKey {
        PickerKey(code: 0, characters: String(value))
    }
}

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct TargetPickerView: View {
    @Environment(TargetPickerModel.self) private var model
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            if let line = model.confirmation ?? model.progress {
                confirmed(line)
            } else {
                header
                search(query: $model.query)
                list
                Rectangle().fill(Palette.hairline).frame(height: 1)
                if let pending = model.pending {
                    undoBar(pending)
                } else {
                    footer
                }
            }
        }
        .frame(width: TargetPickerController.size.width, height: model.isCompact ? 52 : TargetPickerController.size.height, alignment: .topLeading)
        .background(Palette.hud, in: .rect(cornerRadius: Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
        .clipShape(.rect(cornerRadius: Radius.panel, style: .continuous))
        .onChange(of: model.focusToken, initial: true) { fieldFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Send walkthrough")
                    .font(Typography.headline)
                    .foregroundStyle(Palette.text)
                if let meta {
                    Text(meta)
                        .font(Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                badge
            }
            summary
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 16, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var badge: some View {
        switch model.phase {
        case .finishing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Finishing")
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
        case .ready:
            if model.walkthrough?.walkthrough.transcript.failure != nil {
                StatusBadge(text: "No transcript", tone: .caution)
            } else if model.walkthrough?.walkthrough.transcript.isIncomplete == true {
                StatusBadge(text: "Transcript gaps", tone: .caution)
            } else {
                StatusBadge(text: "Ready", tone: .positive)
            }
        case .failed:
            StatusBadge(text: "Not saved", tone: .negative)
        }
    }

    private var meta: String? {
        guard let value = model.walkthrough?.walkthrough else { return nil }
        let pins = value.pointers.filter { $0.via == .pin }.count
        let asks = value.asks.items.count
        var parts = [WalkthroughText.clock(value.duration)]
        if pins > 0 { parts.append("\(pins) \(pins == 1 ? "pin" : "pins")") }
        if asks > 0 { parts.append("\(asks) \(asks == 1 ? "ask" : "asks")") }
        return parts.joined(separator: " · ")
    }

    private var summary: Text {
        switch model.phase {
        case .finishing:
            return Text("The asks appear here when the transcript is done.").foregroundStyle(Palette.textTertiary)
        case .failed(let message):
            return Text(message)
        case .ready:
            guard let walkthrough = model.walkthrough?.walkthrough else { return Text("") }
            if let failure = walkthrough.transcript.failure {
                return Text("\(Text(TranscriptProblem.title(failure)).foregroundStyle(Palette.text)). \(TranscriptProblem.detail(failure))")
            }
            if let events = walkthrough.transcript.events, !events.isEmpty {
                return Text("\(Text(TranscriptProblem.gapsTitle(events)).foregroundStyle(Palette.text)). \(TranscriptProblem.gapsDetail(events))")
            }
            let items = walkthrough.asks.items
            guard let first = items.first else { return Text("No asks found. The agent reads the transcript.").foregroundStyle(Palette.textTertiary) }
            guard items.count > 1 else { return Text(first.text) }
            return Text("\(first.text)  \(Text("+\(items.count - 1) more").foregroundStyle(Palette.textTertiary))")
        }
    }

    private func search(query: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
            TextField("Find a Champion, Project or session", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Palette.text)
                .focused($fieldFocused)
            if !model.query.isEmpty {
                Text("\(model.matchCount) \(model.matchCount == 1 ? "match" : "matches")")
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var note: String? {
        switch model.source {
        case .loading where model.targets.isEmpty: return "Loading chats…"
        case .none: return "Apiary and hive aren't running. The walkthrough is on the clipboard."
        default: return !model.query.isEmpty && model.matchCount == 0 ? "Nothing matches “\(model.query)”." : nil
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let note {
                        Text(note)
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                    }
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(Array(section.rows.enumerated()), id: \.element.key) { offset, target in
                                let index = section.start + offset
                                row(target, focused: section.group == .focused, selected: index == model.selection)
                                    .id(target.key)
                                    .contentShape(.rect)
                                    .onTapGesture { model.tap(index) }
                                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.frames[target.key] = $0 }
                            }
                        } header: {
                            sectionHeader(section)
                                .id("group:\(section.id)")
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
            .allowsHitTesting(model.pending == nil)
            .onChange(of: model.selection) {
                guard !model.pointed else { return }
                if let section = model.sections.first(where: { $0.start == model.selection }) {
                    proxy.scrollTo("group:\(section.id)", anchor: .top)
                } else if let key = model.selected?.key {
                    proxy.scrollTo(key)
                }
            }
        }
    }

    private func sectionHeader(_ section: TargetSection) -> some View {
        HStack(spacing: 6) {
            if section.group == .suggested {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.accentText)
            }
            Text(section.group.title)
                .font(Typography.label)
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(section.group == .suggested ? Palette.accentText : Palette.textTertiary)
            if section.group != .other, section.group != .suggested {
                Text("\(section.rows.count)")
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            if section.group == .suggested {
                Text("via TypeSafe")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }

    private func subtitle(_ target: ApiaryTarget, focused: Bool) -> String {
        if target.kind == TargetPickerModel.clipboardKind { return target.subtitle ?? "" }
        var parts: [String] = []
        if focused { parts.append(target.isProject ? "Orchestrator" : target.isChampion ? "Champion" : "Session") }
        if !target.isProject, !target.isChampion, let detail = target.subtitle ?? target.handle { parts.append(detail) }
        if let workspace = target.workspaceName { parts.append(workspace) }
        if let state = target.state { parts.append(state) }
        return parts.joined(separator: " · ")
    }

    private func row(_ target: ApiaryTarget, focused: Bool, selected: Bool) -> some View {
        let caution = model.unusual(target)
        let armed = model.armed == target.key
        let warn = armed && caution != nil
        let ink = selected && !warn
        let suggested = target.key == model.suggestedKey
        let base = subtitle(target, focused: focused)
        let detail = caution.map { reason in warn ? "\(reason) · click again to send" : [reason, base].filter { !$0.isEmpty }.joined(separator: " · ") } ?? base
        let fill: Color = ink ? Palette.ink : warn ? Palette.cautionFill.opacity(0.16) : suggested ? Palette.accentWash : .clear
        let edge: Color = warn ? Palette.caution.opacity(0.6) : suggested && !ink ? Palette.accent.opacity(0.35) : .clear
        return HStack(spacing: 10) {
            TargetIcon(target: target)
            VStack(alignment: .leading, spacing: 1) {
                HighlightText(
                    text: target.title,
                    query: model.query,
                    color: ink ? Palette.onInk : Palette.text,
                    dim: ink ? Palette.onInk.opacity(0.72) : Palette.textSecondary
                )
                .lineLimit(1)
                if !detail.isEmpty {
                    HStack(spacing: 4) {
                        if caution != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(ink ? Palette.onInk.opacity(0.72) : Palette.caution)
                        }
                        Text(detail)
                            .font(Typography.caption)
                            .foregroundStyle(ink ? Palette.onInk.opacity(0.72) : warn ? Palette.caution : Palette.textTertiary)
                            .lineLimit(1)
                            .help(detail)
                    }
                }
            }
            Spacer(minLength: 6)
            if armed, !warn {
                Text("Click again to send")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.onInk.opacity(0.8))
            }
            if selected {
                KeyHint("↩", emphasized: true)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(fill, in: .rect(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(edge, lineWidth: 1))
        .opacity(model.pending.map { $0.target.key == target.key ? 1 : 0.4 } ?? 1)
        .animation(Motion.snappy, value: armed)
        .animation(Motion.snappy, value: model.pending == nil)
    }

    private func undoBar(_ pending: PendingSend) -> some View {
        TimelineView(.animation) { context in
            let left = max(0, pending.seconds - context.date.timeIntervalSince(pending.started))
            HStack(spacing: 10) {
                TargetIcon(target: pending.target)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sent to \(Text(pending.target.title).fontWeight(.semibold))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Text("Delivers in \(Int(left.rounded(.up))) s")
                        .font(Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: 6)
                Button { model.undo() } label: {
                    HStack(spacing: 6) {
                        Text("Undo")
                        KeyHint("esc")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(large: false))
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.frames["undo"] = $0 }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Palette.accent)
                        .frame(width: proxy.size.width * left / max(pending.seconds, 0.1), height: 2)
                }
                .frame(height: 2)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("⇥", "Next group")
            hint("esc", "Clipboard only")
            if model.canPaste { hint("⌘↩", "Send now") }
            Spacer(minLength: 6)
            if let problem = model.problem {
                HStack(spacing: 6) {
                    StatusDot(tone: .negative)
                    Text(problem).lineLimit(1)
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .help(problem)
            } else if model.queued != nil {
                Text("Sends when ready")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            } else if let debug = model.debugDirectory {
                Button("Debug data") { model.onRevealDebug?(debug) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Open this walkthrough's debug folder in Finder")
            }
            Button { model.choose(.paste) } label: {
                HStack(spacing: 6) {
                    Text(model.choosesClipboard ? "Copy" : model.canPaste ? "Paste" : "Send")
                    KeyHint("↩", emphasized: true)
                }
            }
            .buttonStyle(PrimaryButtonStyle(large: false))
            .disabled(model.selected == nil || model.delivering || model.queued != nil)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyHint(key)
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private func confirmed(_ text: String) -> some View {
        HStack(spacing: 8) {
            if model.confirmation == nil {
                ProgressView().controlSize(.mini)
            } else {
                StatusDot(tone: model.caution ? .caution : .positive)
            }
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}

struct HighlightText: View {
    var text: String
    var query: String
    var size: CGFloat = 13
    var color: Color = Palette.text
    var dim: Color = Palette.textSecondary

    var body: some View {
        let runs = Self.runs(text, query)
        if runs.count == 1, !runs[0].1 {
            Text(text).font(.system(size: size, weight: .medium)).foregroundStyle(color)
        } else {
            runs.reduce(Text("")) { result, run in
                let piece = Text(run.0)
                    .font(.system(size: size, weight: run.1 ? .bold : .medium))
                    .foregroundStyle(run.1 ? color : dim)
                return Text("\(result)\(piece)")
            }
        }
    }

    static func runs(_ text: String, _ query: String) -> [(String, Bool)] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0) }
        let source = Array(text)
        let lower = source.map { $0.lowercased().first ?? $0 }
        guard !words.isEmpty else { return [(text, false)] }
        var mask = Array(repeating: false, count: source.count)
        for word in words where word.count <= lower.count {
            var start = 0
            while start + word.count <= lower.count {
                if Array(lower[start..<(start + word.count)]) == word {
                    for index in start..<(start + word.count) { mask[index] = true }
                    start += word.count
                } else {
                    start += 1
                }
            }
        }
        var runs: [(String, Bool)] = []
        for (index, character) in source.enumerated() {
            if let last = runs.last, last.1 == mask[index] {
                runs[runs.count - 1].0.append(character)
            } else {
                runs.append((String(character), mask[index]))
            }
        }
        return runs.isEmpty ? [(text, false)] : runs
    }
}

enum TranscriptProblem {
    static func title(_ failure: Walkthrough.TranscriptFailure) -> String {
        switch failure.reason {
        case .analyzerFailed: "Transcription failed"
        case .noWords: "No words were recognized"
        case .noAudio: "No audio captured"
        case .micStopped: "The microphone stopped"
        }
    }

    static func detail(_ failure: Walkthrough.TranscriptFailure) -> String {
        switch failure.reason {
        case .analyzerFailed: "Speech wasn't transcribed. The walkthrough tells the agent the transcript is missing; pins, drawings and frames are kept."
        case .noWords: "Audio was recorded but nothing came out. The walkthrough tells the agent the transcript is missing, not empty."
        case .noAudio: "\(sentence(failure.message ?? "the microphone sent no audio")) The walkthrough tells the agent nothing was recorded, not that nothing was said."
        case .micStopped: "\(sentence(failure.message ?? "the microphone stopped")) The walkthrough keeps what was heard before it and says the rest is missing."
        }
    }

    static func gapsTitle(_ events: [Walkthrough.TranscriptEvent]) -> String {
        let stalls = events.filter { $0.kind == .stall }.count
        let dropped = events.filter { $0.kind == .dropped }.count
        if stalls > 0, dropped == 0 { return stalls == 1 ? "Transcription stalled once" : "Transcription stalled \(stalls) times" }
        if dropped > 0, stalls == 0 { return "Some words were never finalised" }
        return "The transcript has gaps"
    }

    static func gapsDetail(_ events: [Walkthrough.TranscriptEvent]) -> String {
        let spans = events.compactMap { event -> String? in
            switch event.kind {
            case .stall: event.until.map { "\(WalkthroughText.clock(event.t))–\(WalkthroughText.clock($0))" } ?? "from \(WalkthroughText.clock(event.t))"
            case .dropped: "\(event.words ?? 0) words at \(WalkthroughText.clock(event.t))"
            case .restart: "mic restart at \(WalkthroughText.clock(event.t))"
            case .error: "error at \(WalkthroughText.clock(event.t))"
            }
        }
        return "Words may be missing (\(spans.joined(separator: ", "))). The walkthrough tells the agent where."
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let capitalized = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        return capitalized.hasSuffix(".") ? capitalized : capitalized + "."
    }
}
