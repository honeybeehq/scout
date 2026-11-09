import SwiftUI

nonisolated enum Motion {
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let smooth = Animation.spring(response: 0.55, dampingFraction: 0.9)
    static let bouncy = Animation.spring(response: 0.45, dampingFraction: 0.62)
    static let step = Animation.spring(response: 0.6, dampingFraction: 0.88)
    static let iconSwap = Animation.spring(duration: 0.3, bounce: 0)
}

private struct IconSwapModifier: ViewModifier {
    var scale: CGFloat
    var opacity: Double
    var blur: CGFloat

    func body(content: Content) -> some View {
        content.scaleEffect(scale).opacity(opacity).blur(radius: blur)
    }
}

private struct StaggeredEntrance: ViewModifier {
    var index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillRender) private var still

    func body(content: Content) -> some View {
        content
            .opacity(shown || still ? 1 : 0)
            .offset(y: shown || reduceMotion || still ? 0 : 8)
            .onAppear {
                withAnimation(.spring(duration: 0.45, bounce: 0).delay(0.08 + Double(index) * 0.1)) { shown = true }
            }
    }
}

extension View {
    func staggeredEntrance(_ index: Int) -> some View {
        modifier(StaggeredEntrance(index: index))
    }
}

extension AnyTransition {
    static var stepForward: AnyTransition {
        .asymmetric(
            insertion: .offset(x: 36).combined(with: .opacity).combined(with: .scale(scale: 0.98)),
            removal: .offset(x: -12).combined(with: .opacity)
        )
    }

    static var stepBackward: AnyTransition {
        .asymmetric(
            insertion: .offset(x: -36).combined(with: .opacity).combined(with: .scale(scale: 0.98)),
            removal: .offset(x: 12).combined(with: .opacity)
        )
    }

    static var iconSwap: AnyTransition {
        .modifier(
            active: IconSwapModifier(scale: 0.25, opacity: 0, blur: 4),
            identity: IconSwapModifier(scale: 1, opacity: 1, blur: 0)
        )
    }

    static var rise: AnyTransition {
        .offset(y: 10).combined(with: .opacity)
    }
}
