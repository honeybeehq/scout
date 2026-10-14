import AppKit
import Carbon.HIToolbox

struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var key: String

    static let startScouting = KeyShortcut(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(controlKey | optionKey), key: "S")
    static let nextTask = KeyShortcut(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(controlKey | optionKey), key: "B")
    static let widenCapture = KeyShortcut(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(controlKey | optionKey), key: "E")
    static let followPointer = KeyShortcut(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(controlKey | optionKey | shiftKey), key: "E")

    var label: String { symbols.joined() }

    var symbols: [String] {
        var symbols: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { symbols.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols.append("⌘") }
        return symbols + [key]
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.key = key
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.charactersIgnoringModifiers, !characters.isEmpty
        else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let key = switch Int(event.keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        default: characters.uppercased()
        }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, key: key)
    }
}

final class GlobalHotkey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?
    private(set) static var lastPressTime: TimeInterval = 0

    private static let signature = OSType(0x5343_5554)
    private let id: UInt32
    private var reference: EventHotKeyRef?

    var isRegistered: Bool { reference != nil }

    init(action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = action
        Self.installEventHandlerIfNeeded()
    }

    @discardableResult
    func register(_ shortcut: KeyShortcut) -> Bool {
        unregister()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        if status != noErr { reference = nil }
        return status == noErr
    }

    func sendPressedEvent() -> OSStatus {
        var event: EventRef?
        var status = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), EventAttributes(kEventAttributeNone), &event)
        guard status == noErr, let event else { return status }
        defer { ReleaseEvent(event) }
        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        status = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        guard status == noErr else { return status }
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    func press(at time: TimeInterval) {
        Self.lastPressTime = time
        Self.handlers[id]?()
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            let pressed = GetEventTime(event)
            MainActor.assumeIsolated {
                GlobalHotkey.lastPressTime = pressed > 0 ? pressed : ProcessInfo.processInfo.systemUptime
                GlobalHotkey.handlers[id]?()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }
}
