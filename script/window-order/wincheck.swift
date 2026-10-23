import AppKit
import CoreGraphics

let args = CommandLine.arguments
if args.count > 2, args[1] == "post" {
    DistributedNotificationCenter.default().postNotificationName(.init("com.trmdy.scout.simulate-open-settings"), object: args[2], userInfo: nil, deliverImmediately: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    exit(0)
}
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let normal = info.filter { ($0[kCGWindowLayer as String] as? Int) == 0 && (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 100 }
let order = normal.prefix(4).map { w in
    ["owner": w[kCGWindowOwnerName as String] as? String ?? "", "pid": w[kCGWindowOwnerPID as String] as? Int ?? 0, "id": w[kCGWindowNumber as String] as? Int ?? 0, "name": w[kCGWindowName as String] as? String ?? ""] as [String: Any]
}
let front = NSWorkspace.shared.frontmostApplication
let result: [String: Any] = ["frontmostApp": front?.localizedName ?? "", "frontmostBundle": front?.bundleIdentifier ?? "", "windowsFrontToBack": order]
let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
