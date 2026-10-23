import AppKit
import CoreGraphics

let args = CommandLine.arguments
if args.count > 2, args[1] == "post" {
    DistributedNotificationCenter.default().postNotificationName(.init("com.trmdy.scout.simulate-open-settings"), object: args[2], userInfo: nil, deliverImmediately: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    exit(0)
}
if args.count > 2, args[1] == "click" {
    guard let scout = NSRunningApplication.runningApplications(withBundleIdentifier: "com.trmdy.scout").first else { print("Scout is not running"); exit(1) }
    let app = AXUIElementCreateApplication(scout.processIdentifier)
    func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    func center(_ element: AXUIElement) -> CGPoint? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
    }
    func button(_ element: AXUIElement, _ label: String, depth: Int = 0) -> AXUIElement? {
        if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
           [attribute(element, kAXTitleAttribute) as? String, attribute(element, kAXDescriptionAttribute) as? String].contains(where: { $0.map(label.split(separator: "|").map(String.init).contains) ?? false }) { return element }
        guard depth < 30 else { return nil }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = button(child, label, depth: depth + 1) { return found }
        }
        return nil
    }
    let source = CGEventSource(stateID: .hidSystemState)
    func click(_ point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    let pointer = CGEvent(source: nil)?.location ?? .zero
    guard let bar = attribute(app, "AXExtrasMenuBar"), let item = (attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first else { print("no Scout menu bar item"); exit(1) }
    let panelButton = { (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).lazy.compactMap { button($0, args[2]) }.first }
    var target = panelButton()
    if target == nil { AXUIElementPerformAction(item, kAXPressAction as CFString) }
    for _ in 0..<30 where target == nil {
        usleep(100_000)
        target = panelButton()
    }
    guard let target, let targetCenter = center(target) else { print("no \(args[2]) button in the menu bar panel"); exit(1) }
    print("clicking \(args[2]) at \(Int(targetCenter.x)),\(Int(targetCenter.y))")
    click(targetCenter)
    usleep(100_000)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: pointer, mouseButton: .left)?.post(tap: .cghidEventTap)
    exit(0)
}
if args.count > 2, args[1] == "shots" {
    let report = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
    let windows = report["windowsFrontToBack"] as? [[String: Any]] ?? []
    let top = windows.prefix(1).filter { ["Scout", "Cover"].contains($0["owner"] as? String) }
    let scout = windows.filter { $0["owner"] as? String == "Scout" }.prefix(1)
    var seen = Set<Int>()
    for w in top + scout where seen.insert(w["id"] as? Int ?? 0).inserted { print("\(w["owner"]!):\(w["id"]!)") }
    exit(0)
}
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let normal = info.filter { ($0[kCGWindowLayer as String] as? Int) == 0 && (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 100 }
let order = normal.prefix(4).map { w in
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let ours = ["Scout", "Cover"].contains(owner)
    return ["owner": ours ? owner : "other app", "pid": w[kCGWindowOwnerPID as String] as? Int ?? 0, "id": w[kCGWindowNumber as String] as? Int ?? 0, "name": ours ? w[kCGWindowName as String] as? String ?? "" : ""] as [String: Any]
}
let front = NSWorkspace.shared.frontmostApplication
let result: [String: Any] = ["frontmostApp": front?.localizedName ?? "", "frontmostBundle": front?.bundleIdentifier ?? "", "windowsFrontToBack": order]
let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
