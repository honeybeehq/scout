import ApplicationServices
import AppKit

nonisolated struct AXElement: @unchecked Sendable {
    let element: AXUIElement

    static let systemWide: AXElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.15)
        return AXElement(element: element)
    }()

    static func application(_ pid: pid_t) -> AXElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        return AXElement(element: element)
    }

    func element(at point: CGPoint) -> AXElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(element, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        return AXElement(element: hit)
    }

    func attribute<Value>(_ name: String, as type: Value.Type = Value.self) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Value
    }

    func child(_ name: String) -> AXElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return AXElement(element: value as! AXUIElement)
    }

    var children: [AXElement] {
        (attribute(kAXChildrenAttribute, as: [AXUIElement].self) ?? []).map(AXElement.init)
    }

    var role: String? { attribute(kAXRoleAttribute) }
    var subrole: String? { attribute(kAXSubroleAttribute) }
    var roleDescription: String? { attribute(kAXRoleDescriptionAttribute) }
    var title: String? { attribute(kAXTitleAttribute) }
    var descriptionText: String? { attribute(kAXDescriptionAttribute) }
    var identifier: String? { attribute(kAXIdentifierAttribute) }
    var parent: AXElement? { child(kAXParentAttribute) }

    var stringValue: String? {
        guard let value: String = attribute(kAXValueAttribute) else { return nil }
        return value.count > 120 ? String(value.prefix(120)) + "…" : value
    }

    var label: String? {
        [title, descriptionText, attribute(kAXPlaceholderValueAttribute), stringValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var frame: CGRect? {
        guard let positionValue = attribute(kAXPositionAttribute, as: AXValue.self),
              let sizeValue = attribute(kAXSizeAttribute, as: AXValue.self)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    var processID: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    func setBool(_ name: String, _ value: Bool) {
        AXUIElementSetAttributeValue(element, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    func firstDescendant(maxDepth: Int, maxVisited: Int = 400, where predicate: (AXElement) -> Bool) -> AXElement? {
        var queue: [(AXElement, Int)] = [(self, 0)]
        var visited = 0
        while !queue.isEmpty, visited < maxVisited {
            let (current, depth) = queue.removeFirst()
            visited += 1
            if predicate(current) { return current }
            guard depth < maxDepth else { continue }
            queue.append(contentsOf: current.children.map { ($0, depth + 1) })
        }
        return nil
    }
}
