import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    enum Pane: String, CaseIterable {
        case general, voice, agents, linear, sdks
    }

    @Environment(AppModel.self) private var model
    @State private var pane: Pane

    static let size = CGSize(width: 620, height: 620)

    init(pane: Pane? = nil) {
        _pane = State(initialValue: pane ?? SettingsView.requestedPane ?? .general)
    }

    static var requestedPane: Pane? {
        let prefix = "--settings-pane="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.flatMap { Pane(rawValue: String($0.dropFirst(prefix.count))) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Array(Pane.allCases.enumerated()), id: \.element) { index, item in
                    PaneTab(title: item.title, symbol: item.symbol, shortcut: "⌘\(index + 1)", selected: pane == item) {
                        withAnimation(Motion.snappy) { pane = item }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Palette.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }

            Group {
                switch pane {
                case .general: GeneralSettings()
                case .voice: VoiceSettings()
                case .agents: AgentSettings()
                case .linear: LinearSettings(scrollAnchor: SnapshotMode.linearScrollAnchor)
                case .sdks: SDKSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Palette.canvas)
        .scaledToUISize()
    }
}

extension SettingsView.Pane {
    var title: String {
        switch self {
        case .general: "General"
        case .voice: "Voice"
        case .agents: "Agents"
        case .linear: "Linear"
        case .sdks: "SDKs"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .voice: "waveform"
        case .agents: "arrow.turn.down.right"
        case .linear: "checklist"
        case .sdks: "chevron.left.forwardslash.chevron.right"
        }
    }
}

private struct PaneTab: View {
    var title: String
    var symbol: String
    var shortcut: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                KeyHint(shortcut, emphasized: selected)
            }
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(selected ? Palette.onInk : Palette.textSecondary)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 28)
            .background(selected ? Palette.ink : Color.clear, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).eyebrowStyle(Palette.textTertiary)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(Palette.surface)
        }
    }
}

struct SettingRow<Trailing: View>: View {
    var title: String
    var detail: String?
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.headline).foregroundStyle(Palette.text)
                if let detail {
                    Text(detail)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
    }
}

struct SettingNote: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 10)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScoutScroll {
            generalSections
        }
    }

    private var generalSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            UISizeSection()
            SettingsSection(title: "Scouting") {
                SettingRow(title: "Start or stop scouting", detail: "Works in any app. Change it in the setup guide.", divider: false) {
                    KeyHint(model.shortcut.symbols.joined(), large: true)
                }
                SettingRow(title: "Aim and pin", detail: "Hold ⌥ while scouting, then click an element.") {
                    KeyHint("⌥", large: true)
                }
                SettingRow(title: "Next task", detail: "While scouting, ends the current task and starts the next.") {
                    KeyHint(model.breakShortcut.symbols.joined(), large: true)
                }
                SettingRow(title: "Discard recording", detail: "While scouting, asks to discard; press it again to delete the recording. Esc keeps it.") {
                    KeyHint(model.discardShortcut.symbols.joined(), large: true)
                }
            }
            SplittingSection()
            SettingsSection(title: "App") {
                SettingRow(title: "Open Scout at login", detail: nil, divider: false) {
                    Toggle("", isOn: $opensAtLogin)
                        .toggleStyle(SignalToggleStyle())
                        .labelsHidden()
                        .onChange(of: opensAtLogin) { _, enabled in model.opensAtLogin = enabled }
                }
                SettingRow(title: "Sessions folder", detail: ScoutPaths.support.appendingPathComponent("Sessions").path) {
                    Button("Show") { NSWorkspace.shared.open(ScoutPaths.support.appendingPathComponent("Sessions")) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                UpdatesSection()
            }
        }
        .padding(20)
    }
}

private struct UpdatesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updates = model.updates
        SettingsSection(title: "Updates") {
            SettingRow(title: "Automatically check for updates", detail: "Once a day. Scout asks before it installs anything.", divider: false) {
                Toggle("", isOn: $updates.checksAutomatically)
                    .toggleStyle(SignalToggleStyle())
                    .labelsHidden()
                    .disabled(!updates.isConfigured)
            }
            SettingRow(title: "Version \(updates.version)", detail: updates.unavailableReason) {
                Button("Check for Updates…") { updates.check() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!updates.canCheckNow)
            }
        }
    }
}

private struct SplittingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsSection(title: "Tasks") {
            SettingRow(title: "Start a new task", detail: nil, divider: false) {
                SegmentedChoice(options: Segmentation.allCases, selection: $preferences.segmentation, title: \.title)
            }
            SettingNote(text: preferences.segmentation.explanation)
            SettingRow(title: "Open the review after scouting", detail: "Trim clips, fix splits and send tasks.") {
                ChoiceMenu(options: ReviewOpening.allCases, selection: $preferences.reviewOpening, title: \.title)
            }
        }
    }
}

private struct UISizeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsSection(title: "Display") {
            SettingRow(title: "Interface size", detail: "Text, controls and panels in every Scout window.", divider: false) {
                SegmentedChoice(options: UISize.allCases, selection: $preferences.uiSize, title: \.title)
            }
            SettingRow(title: "Appearance", detail: nil) {
                SegmentedChoice(options: ColorMode.allCases, selection: $preferences.colorMode, title: \.title)
            }
        }
    }
}

private struct AgentSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var integrations = model.integrations
        @Bindable var preferences = model.preferences
        ScoutScroll {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: "Routing") {
                    SettingRow(title: "Where tasks go", detail: nil, divider: false) {
                        SegmentedChoice(options: DeliveryRoute.allCases, selection: $integrations.route, title: \.title)
                    }
                    SettingNote(text: integrations.route.explanation)
                    SettingRow(title: "Agent for new sessions", detail: "Used when Scout starts a session for a task.") {
                        ChoiceMenu(options: Preferences.agents, selection: $preferences.defaultAgent) { $0 }
                    }
                }
                SettingsSection(title: "Sending") {
                    SettingRow(title: "Send automatically", detail: "Each task waits a moment so you can hold it or change where it goes.", divider: false) {
                        Toggle("", isOn: $preferences.autoSend)
                            .toggleStyle(SignalToggleStyle())
                            .labelsHidden()
                    }
                    if preferences.autoSend {
                        SettingRow(title: "Wait before sending", detail: nil) {
                            NumberStepper(value: $preferences.autoSendDelay, range: 1...30, unit: "s")
                        }
                    }
                    SettingRow(title: "Attach video clips", detail: "The part of the recording each task covers.") {
                        Toggle("", isOn: $preferences.includeClips)
                            .toggleStyle(SignalToggleStyle())
                            .labelsHidden()
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct SDKSettings: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    private let viteSnippet = """
    // vite.config.ts
    import scout from "@scout/vite"
    export default { plugins: [scout()] }
    """

    var body: some View {
        let bridge = model.bridge
        ScoutScroll {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: "Bridge") {
                    SettingRow(title: "Status", detail: bridge.port.map { "Listening on 127.0.0.1:\($0)" } ?? bridge.failure ?? "Starting…", divider: false) {
                        StatusBadge(text: bridge.port == nil ? "Off" : "On", tone: bridge.port == nil ? .negative : .positive)
                    }
                    let apps = bridge.clients.filter { $0.hello != nil }
                    if apps.isEmpty {
                        SettingNote(text: "No apps connected. Add the SDK to a dev server and open the app.")
                    } else {
                        ForEach(apps) { client in
                            HStack(spacing: 10) {
                                StatusDot(tone: .positive)
                                Text(client.name).font(.system(size: 13, weight: .semibold))
                                Text(client.hello?.app?.framework?.name ?? client.hello?.app?.kind ?? "")
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textTertiary)
                                Spacer()
                                Text(client.hello?.project?.root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
                                    .font(Typography.mono)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
                SettingsSection(title: "Add to a Vite app") {
                    Text(viteSnippet)
                        .font(Typography.mono)
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Palette.sunken, in: .rect(cornerRadius: Radius.control, style: .continuous))
                        .padding(.top, 12)
                    HStack {
                        Text("Development only. The plugin does nothing in production builds.")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(viteSnippet, forType: .string)
                            copied = true
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(20)
        }
    }
}
