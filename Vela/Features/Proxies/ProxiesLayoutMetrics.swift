import CoreGraphics

nonisolated struct ProxiesLayoutMetrics: Equatable, Sendable {
    static let inspectorMinimumWidth: CGFloat = 300
    static let inspectorIdealWidth: CGFloat = 340
    static let inspectorMaximumWidth: CGFloat = 380
    static let tableRowHeight: CGFloat = VelaMetrics.tableRowHeight
    static let tableCellContentHeight: CGFloat = 26
    static let compactColumnThreshold: CGFloat = 680

    let showsStrategyColumn: Bool
    let showsStatusColumn: Bool

    static func resolve(tableWidth: CGFloat) -> ProxiesLayoutMetrics {
        let showsSecondaryColumns = tableWidth >= compactColumnThreshold
        return ProxiesLayoutMetrics(
            showsStrategyColumn: showsSecondaryColumns,
            showsStatusColumn: showsSecondaryColumns
        )
    }
}
