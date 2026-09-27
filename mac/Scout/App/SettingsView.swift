import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    enum Pane: String, CaseIterable {
        case general, agents, sdks
    }

    @Environment(AppModel.self) private var model
    @State private var pane = SettingsView.requestedPane ?? .general

    static var requestedPane: Pane? {
        let prefix = "--settings-pane="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.flatMap { Pane(rawValue: String($0.dropFirst(prefix.count))) }
    }

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("Agents", systemImage: "hexagon", value: .agents) { AgentSettings() }
            Tab("SDKs", systemImage: "chevron.left.forwardslash.chevron.right", value: .sdks) { SDKSettings() }
        }
        .frame(width: 560, height: 420)
        .environment(\.colorScheme, .dark)
        .background(Palette.ink)
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).eyebrowStyle(Palette.textTertiary)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(Palette.night.opacity(0.35)), in: .rect(cornerRadius: 18))
        }
    }
}

private struct SettingRow<Trailing: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.headline)
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
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsSection(title: "Scouting") {
                    SettingRow(title: "Start or stop scouting", detail: "Works in any app. Change it in the setup guide.") {
                        KeyCombo(symbols: model.shortcut.symbols, size: 26)
                    }
                    SettingRow(title: "Aim and pin", detail: "Hold ⌥ while scouting, then click an element.") {
                        Keycap(symbol: "⌥", size: 26)
                    }
                    SettingRow(title: "Next task", detail: "While scouting, ends the current task and starts the next.") {
                        KeyCombo(symbols: model.breakShortcut.symbols, size: 26)
                    }
                }
                SplittingSection()
                SettingsSection(title: "App") {
                    SettingRow(title: "Open Scout at login", detail: nil) {
                        Toggle("", isOn: $opensAtLogin)
                            .toggleStyle(.switch)
                            .tint(Palette.flare)
                            .labelsHidden()
                            .onChange(of: opensAtLogin) { _, enabled in model.opensAtLogin = enabled }
                    }
                    SettingRow(title: "Sessions folder", detail: ScoutPaths.support.appendingPathComponent("Sessions").path) {
                        Button("Show") { NSWorkspace.shared.open(ScoutPaths.support.appendingPathComponent("Sessions")) }
                            .buttonStyle(GlassPillButtonStyle())
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct SplittingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsSection(title: "Tasks") {
            Picker("Start a new task", selection: $preferences.segmentation) {
                ForEach(Segmentation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(preferences.segmentation.explanation)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            SettingRow(title: "Open the review after scouting", detail: "Trim clips, fix splits and send tasks.") {
                Picker("", selection: $preferences.reviewOpening) {
                    ForEach(ReviewOpening.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

private struct AgentSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var integrations = model.integrations
        @Bindable var preferences = model.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsSection(title: "Routing") {
                    Picker("Where tasks go", selection: $integrations.route) {
                        ForEach(DeliveryRoute.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(integrations.route.explanation)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    SettingRow(title: "Agent for new sessions", detail: "Used when Scout starts a session for a task.") {
                        Picker("", selection: $preferences.defaultAgent) {
                            ForEach(Preferences.agents, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                SettingsSection(title: "Sending") {
                    SettingRow(title: "Send automatically", detail: "Each task waits a moment so you can hold it or change where it goes.") {
                        Toggle("", isOn: $preferences.autoSend)
                            .toggleStyle(.switch)
                            .tint(Palette.flare)
                            .labelsHidden()
                    }
                    if preferences.autoSend {
                        SettingRow(title: "Wait before sending", detail: nil) {
                            Stepper("\(Int(preferences.autoSendDelay)) s", value: $preferences.autoSendDelay, in: 1...30, step: 1)
                                .fixedSize()
                        }
                    }
                    SettingRow(title: "Attach video clips", detail: "The part of the recording each task covers.") {
                        Toggle("", isOn: $preferences.includeClips)
                            .toggleStyle(.switch)
                            .tint(Palette.flare)
                            .labelsHidden()
                    }
                }
            }
            .padding(24)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsSection(title: "Bridge") {
                    SettingRow(title: "Status", detail: bridge.port.map { "Listening on 127.0.0.1:\($0)" } ?? bridge.failure ?? "Starting…") {
                        StatusBadge(text: bridge.port == nil ? "Off" : "On", tone: bridge.port == nil ? .warning : .success)
                    }
                    let apps = bridge.clients.filter { $0.hello != nil }
                    if apps.isEmpty {
                        Text("No apps connected. Add the SDK to a dev server and open the app.")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textTertiary)
                    } else {
                        ForEach(apps) { client in
                            HStack(spacing: 10) {
                                Circle().fill(Palette.mint).frame(width: 7, height: 7)
                                Text(client.name).font(.system(size: 13, weight: .semibold))
                                Text(client.hello?.app?.framework?.name ?? client.hello?.app?.kind ?? "")
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textTertiary)
                                Spacer()
                                Text(client.hello?.project?.root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
                                    .font(Typography.mono)
                                    .foregroundStyle(Palette.beam)
                            }
                        }
                    }
                }
                SettingsSection(title: "Add to a Vite app") {
                    Text(viteSnippet)
                        .font(Typography.mono)
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                        .buttonStyle(GlassPillButtonStyle())
                    }
                }
            }
            .padding(24)
        }
    }
}
