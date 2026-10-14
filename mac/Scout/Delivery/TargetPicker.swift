import AppKit
import Observation
import ScoutCore
import SwiftUI

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

    private(set) var phase: Phase = .finishing
    private(set) var walkthrough: FinishedWalkthrough?
    private(set) var targets: [ApiaryTarget] = []
    private(set) var source: Source = .loading
    var query = "" {
        didSet { selection = 0 }
    }
    var selection = 0
    private(set) var queued: DeliveryMode?
    private(set) var delivering = false
    private(set) var confirmation: String?
    private(set) var problem: String?
    var focusToken = 0

    var onChoose: ((ApiaryTarget, DeliveryMode) -> Void)?
    var onDismiss: (() -> Void)?

    var filtered: [ApiaryTarget] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return targets }
        return targets.filter { target in
            let haystack = [target.title, target.handle, target.subtitle, target.kind].compactMap { $0 }.joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var selected: ApiaryTarget? {
        let rows = filtered
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    var canPaste: Bool { source == .apiary }

    func reset(with walkthrough: FinishedWalkthrough? = nil) {
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
        focusToken += 1
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
        self.targets = targets
        self.source = source
        let moved = selection != 0 || !query.isEmpty
        if moved, let keep, let index = filtered.firstIndex(where: { $0.kind == keep.kind && $0.id == keep.id }) { selection = index } else { selection = 0 }
    }

    func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func choose(_ mode: DeliveryMode) {
        guard !delivering, confirmation == nil, let target = selected else { return }
        let mode = canPaste ? mode : .send
        if phase == .finishing {
            queued = mode
        }
        problem = nil
        onChoose?(target, mode)
    }

    func began() {
        delivering = true
        problem = nil
    }

    func confirm(_ text: String) {
        delivering = false
        queued = nil
        confirmation = text
    }

    func refuse(_ message: String) {
        delivering = false
        queued = nil
        problem = message
    }
}

final class TargetPickerController {
    static let size = CGSize(width: 460, height: 404)

    let model = TargetPickerModel()
    private var panel: PickerPanel?
    private var monitor: Any?
    private var closing: Task<Void, Never>?

    var isOpen: Bool { panel?.isVisible == true }

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
        let host = NSHostingView(rootView: TargetPickerView().environment(model).environment(\.colorScheme, .dark))
        host.sizingOptions = []
        panel.contentView = host
        panel.layoutIfNeeded()
        self.panel = panel
    }

    func open(near cursor: CGPoint) {
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
        panel.makeKey()
        panel.displayIfNeeded()
        listen()
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
            switch event.keyCode {
            case 125:
                model.move(1)
            case 126:
                model.move(-1)
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
            if let confirmation = model.confirmation {
                confirmed(confirmation)
            } else {
                header
                asks
                    .frame(height: 70, alignment: .topLeading)
                Divider().overlay(Palette.hairline)
                targetSection(query: $model.query)
                Spacer(minLength: 0)
                footer
            }
        }
        .frame(width: TargetPickerController.size.width, height: model.confirmation == nil ? TargetPickerController.size.height : 52, alignment: .topLeading)
        .background(Palette.night.opacity(0.94), in: .rect(cornerRadius: 20, style: .continuous))
        .glassEffect(.regular.tint(Palette.night.opacity(0.3)), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
        .onChange(of: model.focusToken, initial: true) { fieldFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Walkthrough")
                .font(Typography.headline)
            if let meta {
                Text(meta)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            switch model.phase {
            case .finishing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Finishing")
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            case .ready:
                StatusBadge(text: "Ready", tone: .positive)
            case .failed:
                StatusBadge(text: "Not saved", tone: .negative)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var meta: String? {
        guard let value = model.walkthrough?.walkthrough else { return nil }
        let pins = value.pointers.filter { $0.via == .pin }.count
        var parts = [WalkthroughText.clock(value.duration)]
        if pins > 0 { parts.append("\(pins) \(pins == 1 ? "pin" : "pins")") }
        let apiary = value.pointers.filter { $0.source == .apiary }.count
        if apiary > 0 { parts.append("\(apiary) in Apiary") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var asks: some View {
        switch model.phase {
        case .finishing:
            Text("The asks appear here when the transcript is done.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, 16)
        case .failed(let message):
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 16)
        case .ready:
            let items = model.walkthrough?.walkthrough.asks.items ?? []
            VStack(alignment: .leading, spacing: 3) {
                if items.isEmpty {
                    Text("No asks found. The agent reads the transcript.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { index, ask in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(Typography.mono)
                            .foregroundStyle(Palette.textQuaternary)
                        Text(ask.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                if items.count > 3 {
                    Text("+\(items.count - 3) more")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textQuaternary)
                }
            }
            .padding(.horizontal, 16)
            .transition(.opacity)
        }
    }

    private func targetSection(query: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.canPaste || model.source == .loading ? "Paste into" : "Send to")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
                Text("↑↓ choose · type to filter")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textQuaternary)
            }
            TextField("Type a session or Champion", text: query)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .focused($fieldFocused)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Palette.fill, in: .rect(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline))
            rows
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var rows: some View {
        let rows = model.filtered
        if rows.isEmpty {
            Text(emptyText)
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .padding(.vertical, 8)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(rows.prefix(200).enumerated()), id: \.element.key) { index, target in
                            row(target, selected: index == model.selection)
                                .contentShape(.rect)
                                .onTapGesture {
                                    model.selection = index
                                    model.choose(.paste)
                                }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 186)
                .onChange(of: model.selection) {
                    if let key = model.selected?.key { proxy.scrollTo(key) }
                }
            }
        }
    }

    private var emptyText: String {
        switch model.source {
        case .loading: "Loading chats…"
        case .none: "Apiary and hive aren't running. The walkthrough is on the clipboard."
        case .apiary, .hive: "Nothing matches “\(model.query)”."
        }
    }

    private func row(_ target: ApiaryTarget, selected: Bool) -> some View {
        HStack(spacing: 9) {
            StatusDot(tone: target.focused ? .active : (target.open ? .neutral : .neutral), size: 5)
                .opacity(target.focused || target.open ? 1 : 0.4)
            Text(target.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.text : Palette.textSecondary)
                .lineLimit(1)
            if target.focused {
                Text("focused chat")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: 6)
            Text(target.kind == "session" ? (target.handle ?? "") : target.kind)
                .font(Typography.mono)
                .foregroundStyle(Palette.textQuaternary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(selected ? Palette.fillStrong : .clear, in: .rect(cornerRadius: 7, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("esc", "clipboard only")
            if model.canPaste { hint("⌘↩", "send now") }
            Spacer()
            if let problem = model.problem {
                HStack(spacing: 6) {
                    StatusDot(tone: .negative)
                    Text(problem).lineLimit(1)
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            } else if model.queued != nil {
                Text("Sends when ready")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Button(model.canPaste ? "Paste ↩" : "Send ↩") { model.choose(.paste) }
                .buttonStyle(PrimaryButtonStyle(large: false))
                .disabled(model.selected == nil || model.delivering || model.queued != nil)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .frame(height: 18)
                .background(Palette.fillRaised, in: .rect(cornerRadius: 5, style: .continuous))
            Text(label)
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.textTertiary)
    }

    private func confirmed(_ text: String) -> some View {
        HStack(spacing: 8) {
            StatusDot(tone: .positive)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}
