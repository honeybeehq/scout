import CoreGraphics

nonisolated struct NotchGeometry: Equatable, Sendable {
    var frame: CGRect
    var safeAreaTop: CGFloat
    var auxiliaryTopLeft: CGRect?
    var auxiliaryTopRight: CGRect?

    var hasNotch: Bool { safeAreaTop > 0 && auxiliaryTopLeft != nil && auxiliaryTopRight != nil }

    var notch: CGRect? {
        guard hasNotch, let left = auxiliaryTopLeft, let right = auxiliaryTopRight else { return nil }
        return CGRect(x: left.maxX, y: frame.maxY - safeAreaTop, width: right.minX - left.maxX, height: safeAreaTop)
    }

    var notchBand: CGFloat { notch?.height ?? 0 }

    var barCenterX: CGFloat { notch?.midX ?? frame.midX }

    func barFrame(size: CGSize) -> CGRect {
        let width = min(size.width, frame.width)
        let height = (size.height + notchBand).rounded(.up)
        let x = min(max(barCenterX - width / 2, frame.minX), frame.maxX - width)
        return CGRect(x: x.rounded(), y: frame.maxY - height, width: width, height: height)
    }
}
