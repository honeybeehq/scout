import AppKit
import Observation
import ServiceManagement

@Observable
final class AppModel {
    let permissions = PermissionCenter()
    let onboarding = OnboardingModel()
    let transcriber = LiveTranscriber()
    let integrations: Integrations
    let dispatcher: Dispatcher
    let hud = HUDController()
    let bridge = BridgeServer()
    private(set) var session: ScoutingSession?
    var openOnboarding: (() -> Void)?

    private(set) var shortcut: KeyShortcut
    private(set) var shortcutRegistered = false
    private(set) var isScouting = false

    private var hotkey: GlobalHotkey?

    private static let shortcutKey = "shortcut.startScouting"

    init() {
        let integrations = Integrations()
        self.integrations = integrations
        dispatcher = Dispatcher(integrations: integrations, bridge: bridge)
        if let data = UserDefaults.standard.data(forKey: Self.shortcutKey),
           let saved = try? JSONDecoder().decode(KeyShortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .startScouting
        }
        let hotkey = GlobalHotkey { [weak self] in self?.toggleScouting() }
        self.hotkey = hotkey
        shortcutRegistered = hotkey.register(shortcut)
        dispatcher.dryRun = SimulationMode.isDryRun
        bridge.start()
        if let audio = SimulationMode.audioFile {
            Task { await SimulationMode.run(model: self, audio: audio) }
        }
    }

    func updateShortcut(_ newShortcut: KeyShortcut) {
        shortcut = newShortcut
        shortcutRegistered = hotkey?.register(newShortcut) ?? false
        if let data = try? JSONEncoder().encode(newShortcut) {
            UserDefaults.standard.set(data, forKey: Self.shortcutKey)
        }
    }

    func suspendShortcut() {
        hotkey?.unregister()
    }

    func resumeShortcut() {
        shortcutRegistered = hotkey?.register(shortcut) ?? false
    }

    func toggleScouting() {
        isScouting ? stopScouting() : startScouting()
    }

    func startScouting(inputFile: URL? = nil, onInputFinished: (() -> Void)? = nil) {
        guard !isScouting else { return }
        guard inputFile != nil || permissions.state(of: .microphone).isGranted else {
            onboarding.go(to: .access)
            openOnboarding?()
            return
        }
        let session = ScoutingSession(bridge: bridge)
        session.transcriber.inputFile = inputFile
        session.transcriber.onInputFinished = onInputFinished
        session.onSnippetClosed = { [weak self, weak session] snippet, immediate in
            guard let self, let session else { return }
            dispatcher.accept(snippet, from: session, sendImmediately: immediate)
        }
        self.session = session
        isScouting = true
        hud.show(model: self)
        Task { await session.start() }
    }

    func stopScouting() {
        guard isScouting, let session else { return }
        isScouting = false
        Task {
            await session.stop()
            hud.hidePill()
            stackChanged()
        }
    }

    func stackChanged() {
        if !isScouting && dispatcher.cards.isEmpty {
            hud.hideAll()
        }
    }

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSSound.beep()
            }
        }
    }
}
