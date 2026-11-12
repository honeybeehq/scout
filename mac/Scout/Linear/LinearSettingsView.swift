import AppKit
import ScoutCore
import SwiftUI

struct LinearSettings: View {
    @Environment(AppModel.self) private var model
    var scrollAnchor: String?

    var body: some View {
        let account = model.linear
        ScrollViewReader { proxy in
            ScoutScroll {
                VStack(alignment: .leading, spacing: 16) {
                    LinearAccountSection(account: account)
                    LinearRoutingSection(account: account).id("routing")
                    LinearFilingSection(preferences: account.preferences).id("filing")
                }
                .padding(20)
            }
            .onAppear {
                if let scrollAnchor { proxy.scrollTo(scrollAnchor, anchor: .top) }
            }
        }
        .task { await account.refresh() }
    }
}

private struct LinearAccountSection: View {
    @Bindable var account: LinearAccount

    var body: some View {
        SettingsSection(title: "Account") {
            switch account.status {
            case .disconnected(let error):
                keyEntry(error: error, connecting: false)
            case .connecting:
                keyEntry(error: nil, connecting: true)
            case .connected(let hint, let check):
                connected(hint: hint, check: check)
            }
        }
    }

    private func keyEntry(error: LinearError?, connecting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Personal API key").font(Typography.headline).foregroundStyle(Palette.text)
            HStack(spacing: 8) {
                SecureField("lin_api_…", text: $account.draftKey)
                    .textFieldStyle(.plain)
                    .font(Typography.mono)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Palette.sunken, in: .rect(cornerRadius: Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
                    .disabled(connecting)
                    .onSubmit { Task { await account.connect() } }
                Button(connecting ? "Checking…" : "Connect") { Task { await account.connect() } }
                    .buttonStyle(PrimaryButtonStyle(large: false))
                    .disabled(connecting || account.draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                StatusLine(tone: .negative, text: error.message)
            }
            Text("Create one in Linear under Settings → Security & access. Scout keeps it in your Mac's Keychain.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    private func connected(hint: LinearKeyHint, check: LinearAccount.Check) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                switch check {
                case .checking:
                    StatusLine(tone: .neutral, text: "Checking your key…")
                case .passed(let viewer, let date):
                    StatusDot(tone: .positive)
                    Text("Connected as \(viewer.name)").font(Typography.headline).foregroundStyle(Palette.text)
                    Text("\(viewer.organization.name) (\(viewer.organization.urlKey))")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .help("Checked \(date.formatted(.relative(presentation: .named)))")
                case .failed(let error):
                    StatusLine(tone: .negative, text: error.message)
                }
                Spacer(minLength: 8)
                if case .passed(_, let date) = check {
                    Text(Date.now.timeIntervalSince(date) < 60 ? "Checked just now" : "Checked \(date.formatted(date: .omitted, time: .shortened))")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.vertical, 12)
            SettingRow(title: "API key", detail: nil) {
                HStack(spacing: 6) {
                    Text(hint.masked)
                        .font(Typography.mono)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.trailing, 6)
                    Button("Test") { Task { await account.check() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(check == .checking)
                    Button("Remove") { account.remove() }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }
}

private struct LinearRoutingSection: View {
    @Bindable var account: LinearAccount
    @State private var sources: [LinearSource] = []

    var body: some View {
        let preferences = account.preferences
        SettingsSection(title: "Where issues go") {
            if !account.isConnected {
                SettingNote(text: preferences.routes.isEmpty ? "Connect Linear to choose teams and projects." : "Connect Linear to use these. Until then they're inactive.")
                    .padding(.top, 10)
            } else if case .failed(let error) = account.teams {
                StatusLine(tone: .negative, text: error.message)
                    .padding(.top, 10)
            }
            SettingRow(title: "Default team", detail: defaultCaption, divider: false) {
                HStack(spacing: 6) {
                    TeamPickerButton(account: account, pickerID: "default", selection: preferences.defaultTeam) { team in
                        preferences.defaultTeam = team
                        Task { await account.loadTeamDetails(team.id) }
                    }
                    if let team = preferences.defaultTeam {
                        ProjectPicker(account: account, teamID: team.id, selection: preferences.defaultProject) { preferences.defaultProject = $0 }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Per app or repo").font(Typography.headline).foregroundStyle(Palette.text)
                Text("A repo match wins over an app match. Anything else goes to the default team.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            ForEach(preferences.routes) { route in
                RouteRow(account: account, route: route)
            }
            addMenu
                .padding(.vertical, 8)
        }
        .task { sources = await LinearSource.recent() }
    }

    private var defaultCaption: String {
        guard let team = account.preferences.defaultTeam else { return "Without one, Scout asks for a team when you file." }
        let labelCount = account.labels[team.id]?.value?.count
        let projectCount = account.projects[team.id]?.value?.count
        guard let labelCount, let projectCount else { return "Tasks with no matching app or repo go here." }
        return "Tasks with no match go here. \(team.key) has \(projectCount) open projects, \(labelCount) labels."
    }

    private var addMenu: some View {
        let mapped = Set(account.preferences.routes.map(\.match))
        let available = sources.filter { !mapped.contains($0.match) }
        return ScoutMenu {
            if available.isEmpty {
                Text("No recent apps or repos")
            }
            ForEach(available) { source in
                Button("\(source.name) · \(source.detail)") { add(source) }
            }
        } label: {
            Label("Add from recent sessions", systemImage: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(height: 26)
                .contentShape(.rect)
        }
        .fixedSize()
        .disabled(!account.isConnected || account.teams.value == nil)
    }

    private func add(_ source: LinearSource) {
        guard let team = account.preferences.defaultTeam ?? account.teams.value?.first else { return }
        account.preferences.routes.append(LinearRoute(match: source.match, name: source.name, team: team, project: nil))
        account.openTeamPicker = account.preferences.routes.last?.pickerID
    }
}

private struct RouteRow: View {
    var account: LinearAccount
    var route: LinearRoute

    var body: some View {
        let preferences = account.preferences
        let missing = account.teams.value != nil && account.team(id: route.team.id) == nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: route.isRepo ? "folder" : "app.dashed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 14)
                Text(route.name)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text(route.detail)
                    .font(Typography.mono)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if !account.isConnected {
                    StatusBadge(text: "Inactive", tone: .neutral)
                } else if missing {
                    StatusBadge(text: "Team not found", tone: .caution)
                }
                Button {
                    preferences.routes.removeAll { $0.id == route.id }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(QuietButtonStyle())
                .help("Remove this mapping")
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textQuaternary)
                    .frame(width: 14)
                    .padding(.trailing, 2)
                TeamPickerButton(account: account, pickerID: route.pickerID, selection: route.team) { team in
                    preferences.setTeam(team, for: route)
                    Task { await account.loadTeamDetails(team.id) }
                }
                ProjectPicker(account: account, teamID: route.team.id, selection: route.project) { preferences.setProject($0, for: route) }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

private struct PickerLabel: View {
    var text: String
    var placeholder: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .lineLimit(1)
                .foregroundStyle(placeholder ? Palette.textSecondary : Palette.text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Palette.textTertiary)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
        .fixedSize()
        .contentShape(.rect(cornerRadius: Radius.control))
    }
}

private struct TeamPickerButton: View {
    @Bindable var account: LinearAccount
    var pickerID: String
    var selection: LinearTeam?
    var choose: (LinearTeam) -> Void

    var body: some View {
        Button {
            account.openTeamPicker = pickerID
        } label: {
            PickerLabel(text: selection?.label ?? "Choose a team", placeholder: selection == nil)
        }
        .buttonStyle(.plain)
        .disabled(!account.isConnected || account.teams.value == nil)
        .background(PopoverAnchor(isPresented: account.openTeamPicker == pickerID, onClose: {
            if account.openTeamPicker == pickerID { account.openTeamPicker = nil }
        }) {
            TeamList(teams: account.teams.value ?? [], selectedID: selection?.id) { team in
                account.openTeamPicker = nil
                choose(team)
            }
        })
    }
}

private struct PopoverAnchor<Content: View>: NSViewRepresentable {
    var isPresented: Bool
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var onClose: () -> Void = {}

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            onClose()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClose = onClose
        guard isPresented else {
            coordinator.popover?.close()
            return
        }
        if let host = coordinator.popover?.contentViewController as? NSHostingController<Content> {
            host.rootView = content()
            return
        }
        let host = NSHostingController(rootView: content())
        host.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = SnapshotMode.directory == nil ? .transient : .applicationDefined
        popover.appearance = view.window?.effectiveAppearance
        popover.contentViewController = host
        popover.delegate = coordinator
        coordinator.popover = popover
        DispatchQueue.main.async {
            guard view.window != nil, coordinator.popover === popover else { return }
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}

private struct TeamList: View {
    var teams: [LinearTeam]
    var selectedID: String?
    var choose: (LinearTeam) -> Void
    @State private var search = ""

    private var filtered: [LinearTeam] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return teams }
        return teams.filter { $0.key.localizedCaseInsensitiveContains(term) || $0.name.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Find a team", text: $search)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Palette.sunken, in: .rect(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { team in
                        Button {
                            choose(team)
                        } label: {
                            HStack(spacing: 10) {
                                Text(team.key)
                                    .font(Typography.mono)
                                    .foregroundStyle(Palette.textSecondary)
                                    .frame(width: 52, alignment: .leading)
                                Text(team.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.text)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if team.id == selectedID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Palette.text)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(team.id == selectedID ? Palette.selection : .clear, in: .rect(cornerRadius: Radius.control, style: .continuous))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    if filtered.isEmpty {
                        Text("No team matches.")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(8)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 300)
        .background(Palette.surface)
    }
}

private struct ProjectPicker: View {
    var account: LinearAccount
    var teamID: String
    var selection: LinearProjectRef?
    var choose: (LinearProjectRef?) -> Void

    var body: some View {
        let state = account.projects[teamID] ?? .idle
        let projects = state.value ?? []
        ScoutMenu {
            Button("No project") { choose(nil) }
            if !projects.isEmpty { Divider() }
            ForEach(projects) { project in
                Button(project.name) { choose(LinearProjectRef(project)) }
            }
        } label: {
            PickerLabel(text: selection?.name ?? (state == .loading ? "Loading projects…" : "No project"), placeholder: selection == nil)
        }
        .fixedSize()
        .disabled(!account.isConnected)
        .task(id: teamID) { await account.loadTeamDetails(teamID) }
    }
}

private struct StatusLine: View {
    var tone: Tone
    var text: String

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(tone: tone)
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
        }
    }
}

private struct LinearFilingSection: View {
    @Bindable var preferences: LinearPreferences

    var body: some View {
        SettingsSection(title: "Filing") {
            SettingRow(title: "Automatic tasks", detail: nil, divider: false) {
                structurePicker($preferences.automaticStructure)
            }
            SettingRow(title: "Manual tasks", detail: nil) {
                structurePicker($preferences.manualStructure)
            }
            SettingRow(title: "Include video", detail: "Starting value of each task's video switch. The clip leaves your Mac only when it's on.") {
                Toggle("", isOn: $preferences.includesVideo)
                    .toggleStyle(SignalToggleStyle())
                    .labelsHidden()
            }
            SettingNote(text: "You can change the structure for each recording in the review. Issues land in the team's backlog.")
        }
    }

    private func structurePicker(_ selection: Binding<LinearStructure>) -> some View {
        ChoiceMenu(options: LinearStructure.allCases, selection: selection, title: \.title)
    }
}

nonisolated struct LinearSource: Identifiable, Hashable, Sendable {
    var match: LinearRoute.Match
    var name: String
    var detail: String

    var id: LinearRoute.Match { match }

    static func recent() async -> [LinearSource] {
        await Task.detached(priority: .utility) {
            var seen = Set<LinearRoute.Match>()
            var sources: [LinearSource] = []
            for summary in SessionLibrary.recent(limit: 20) {
                for change in SessionLibrary.ledger(in: summary.directory).contexts {
                    let context = change.context
                    if let project = context.project {
                        let source = LinearSource(
                            match: .repo(rootPath: project.rootPath),
                            name: project.name ?? URL(fileURLWithPath: project.rootPath).lastPathComponent,
                            detail: (project.rootPath as NSString).abbreviatingWithTildeInPath
                        )
                        if seen.insert(source.match).inserted { sources.append(source) }
                    }
                    if let bundleID = context.app.bundleID, bundleID != Bundle.main.bundleIdentifier {
                        let source = LinearSource(match: .app(bundleID: bundleID), name: context.app.name, detail: bundleID)
                        if seen.insert(source.match).inserted { sources.append(source) }
                    }
                }
            }
            return sources
        }.value
    }
}

extension LinearRoute {
    var pickerID: String {
        switch match {
        case .repo(let rootPath): "repo:\(rootPath)"
        case .app(let bundleID): "app:\(bundleID)"
        }
    }

    fileprivate var isRepo: Bool {
        if case .repo = match { true } else { false }
    }
}
