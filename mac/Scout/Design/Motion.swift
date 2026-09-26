import SwiftUI

enum Motion {
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let smooth = Animation.spring(response: 0.55, dampingFraction: 0.9)
    static let bouncy = Animation.spring(response: 0.45, dampingFraction: 0.62)
    static let step = Animation.spring(response: 0.6, dampingFraction: 0.88)
}

extension AnyTransition {
    static var stepForward: AnyTransition {
        .asymmetric(
            insertion: .offset(x: 36).combined(with: .opacity).combined(with: .scale(scale: 0.98)),
            removal: .offset(x: -24).combined(with: .opacity)
        )
    }

    static var stepBackward: AnyTransition {
        .asymmetric(
            insertion: .offset(x: -36).combined(with: .opacity).combined(with: .scale(scale: 0.98)),
            removal: .offset(x: 24).combined(with: .opacity)
        )
    }

    static var rise: AnyTransition {
        .offset(y: 10).combined(with: .opacity)
    }
}
