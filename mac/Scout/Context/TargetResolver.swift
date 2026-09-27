import AppKit
import ScoutCore

nonisolated enum TargetResolver {
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXComboBox", "AXMenuButton", "AXMenuItem", "AXSlider", "AXTab", "AXDisclosureTriangle", "AXCell", "AXImage",
    ]
    private static let containerRoles: Set<String> = ["AXGroup", "AXStaticText", "AXUnknown"]
    private static let anonymousRoles: Set<String> = ["AXGroup", "AXUnknown", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXList", "AXOutline", "AXTable", "AXWebArea", "AXToolbar"]
    private static let ownProcessID = ProcessInfo.processInfo.processIdentifier

    static func target(at point: CGPoint) -> Target? {
        guard var element = element(at: point), let pid = element.processID else { return nil }

        for _ in 0..<3 {
            guard let role = element.role, containerRoles.contains(role) || element.label == nil,
                  let parent = element.parent, let parentRole = parent.role,
                  interactiveRoles.contains(parentRole)
            else { break }
            element = parent
        }

        let role = element.role ?? "AXUnknown"
        guard role != "AXWindow", role != "AXApplication", role != "AXScrollArea" else { return nil }
        let frame = element.frame
        let label = element.label
        guard label != nil || element.identifier != nil || !anonymousRoles.contains(role) else { return nil }
        let identifier = element.identifier
        let frameKey = frame.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height))" } ?? "-"
        return Target(
            id: "\(pid):\(role):\(label ?? ""):\(identifier ?? ""):\(frameKey)",
            provider: .accessibility,
            role: readableRole(role, description: element.roleDescription),
            label: label,
            identifier: identifier,
            frame: frame.map { Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) },
            ancestry: ancestry(of: element)
        )
    }

    private static func element(at point: CGPoint) -> AXElement? {
        if let hit = AXElement.systemWide.element(at: point), let pid = hit.processID, pid != ownProcessID {
            return hit
        }
        guard let pid = windowOwner(at: point) else { return nil }
        return AXElement.application(pid).element(at: point)
    }

    private static func windowOwner(at point: CGPoint) -> pid_t? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownProcessID,
                  (window[kCGWindowLayer as String] as? Int ?? 0) < 25,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(point)
            else { continue }
            return pid
        }
        return nil
    }

    private static func ancestry(of element: AXElement) -> [String] {
        var names: [String] = []
        var current = element.parent
        while let node = current, names.count < 4 {
            let role = node.role ?? "?"
            if role == "AXApplication" { break }
            if role != "AXGroup" || node.label != nil {
                names.append([readableRole(role, description: node.roleDescription), node.label.map { "“\($0)”" }].compactMap { $0 }.joined(separator: " "))
            }
            current = node.parent
        }
        return names
    }

    static func readableRole(_ role: String, description: String?) -> String {
        if let description, !description.isEmpty { return description.prefix(1).uppercased() + description.dropFirst() }
        return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }
}
