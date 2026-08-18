import CoreGraphics

nonisolated enum RulesColumnSet: String, Equatable, Sendable {
    case compact
    case regular
    case spacious
}

nonisolated struct RulesLayoutMetrics: Equatable, Sendable {
    static let inspectorMinimumWidth: CGFloat = 300
    static let inspectorMaximumWidth: CGFloat = 380
    static let tableRowHeight: CGFloat = VelaMetrics.tableRowHeight
    static let tableCellContentHeight: CGFloat = 26

    let columnSet: RulesColumnSet
    let inspectorIdealWidth: CGFloat

    static func resolve(
        detailWidth: CGFloat,
        tableAvailableWidth: CGFloat
    ) -> RulesLayoutMetrics {
        let progress = max(0, min(1, (detailWidth - 700) / 580))
        let inspectorWidth = inspectorMinimumWidth
            + progress * (inspectorMaximumWidth - inspectorMinimumWidth)
        let columnSet: RulesColumnSet
        if tableAvailableWidth < 680 {
            columnSet = .compact
        } else if tableAvailableWidth < 950 {
            columnSet = .regular
        } else {
            columnSet = .spacious
        }
        return RulesLayoutMetrics(
            columnSet: columnSet,
            inspectorIdealWidth: inspectorWidth
        )
    }
}
