import SwiftUI

private struct ScaledLayout: Layout {
    var scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(unscaled(proposal)) ?? .zero
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: unscaled(ProposedViewSize(bounds.size)))
    }

    private func unscaled(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })
    }
}

private struct ScoutScale: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.scaled(by: model.preferences.uiSize.scale)
    }
}

extension View {
    func scaledToUISize() -> some View {
        modifier(ScoutScale())
    }

    func scaled(by scale: CGFloat) -> some View {
        ScaledLayout(scale: scale) {
            scaleEffect(scale, anchor: .topLeading)
        }
    }
}
