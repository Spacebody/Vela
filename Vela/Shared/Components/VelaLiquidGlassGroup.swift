import SwiftUI

/// Keeps nearby custom glass controls in one sampling group on macOS 26 while
/// preserving the existing layout on earlier supported systems.
struct VelaLiquidGlassGroup<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(
        spacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}
