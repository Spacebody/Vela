import CoreGraphics

nonisolated struct UpdatesCoreRecoveryLayoutMetrics: Equatable, Sendable {
    let listWidth: CGFloat
    let contentPadding: CGFloat
    let detailColumns: Int

    static func resolve(contentWidth: CGFloat) -> Self {
        let width = max(720, contentWidth)
        return UpdatesCoreRecoveryLayoutMetrics(
            listWidth: min(380, max(300, width * 0.31)),
            contentPadding: width < 900 ? VelaSpacing.medium : VelaSpacing.section,
            detailColumns: width >= 1_000 ? 2 : 1
        )
    }
}
