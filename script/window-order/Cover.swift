import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSScreen.main!.visibleFrame
        window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Cover window (another app)"
        window.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.93, blue: 0.85, alpha: 1)
        let label = NSTextField(labelWithString: "Another app's window covering the screen")
        label.font = .systemFont(ofSize: 40, weight: .semibold)
        label.frame = NSRect(x: 60, y: frame.height / 2, width: frame.width - 120, height: 60)
        window.contentView?.addSubview(label)
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return false
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
