import CoreGraphics

nonisolated enum ConnectionsFilterLayoutMetrics {
    static let minimumSegmentWidth: CGFloat = 64
    static let maximumPickerWidth: CGFloat = 390

    static func protocolPickerContentWidth(protocols: [String]) -> CGFloat {
        let protocolSegmentsWidth = protocols.reduce(CGFloat.zero) { width, protocolName in
            width + max(
                minimumSegmentWidth,
                CGFloat(protocolName.uppercased().count) * 8 + 28
            )
        }
        return minimumSegmentWidth + protocolSegmentsWidth
    }

    static func protocolPickerWidth(
        protocols: [String],
        maximumWidth: CGFloat = maximumPickerWidth
    ) -> CGFloat {
        min(maximumWidth, protocolPickerContentWidth(protocols: protocols))
    }

    static func usesOverflowMenu(
        protocols: [String],
        maximumWidth: CGFloat = maximumPickerWidth
    ) -> Bool {
        protocolPickerContentWidth(protocols: protocols) > maximumWidth
    }
}

nonisolated enum ConnectionsColumnSet: String, Equatable, Sendable {
    case compact
    case regular
    case spacious
}

nonisolated struct ConnectionsLayoutMetrics: Equatable, Sendable {
    static let inspectorMinimumWidth: CGFloat = 300
    static let inspectorMaximumWidth: CGFloat = 380
    static let targetRowHeight: CGFloat = VelaMetrics.tableRowHeight
    static let tableCellContentHeight: CGFloat = 26

    let columnSet: ConnectionsColumnSet
    let inspectorIdealWidth: CGFloat

    static func resolve(
        detailWidth: CGFloat,
        tableAvailableWidth: CGFloat
    ) -> ConnectionsLayoutMetrics {
        let inspectorProgress = max(0, min(1, (detailWidth - 700) / 580))
        let inspectorWidth = inspectorMinimumWidth
            + inspectorProgress * (inspectorMaximumWidth - inspectorMinimumWidth)
        let columnSet: ConnectionsColumnSet
        if tableAvailableWidth < 620 {
            columnSet = .compact
        } else if tableAvailableWidth < 660 {
            columnSet = .regular
        } else {
            columnSet = .spacious
        }
        return ConnectionsLayoutMetrics(
            columnSet: columnSet,
            inspectorIdealWidth: inspectorWidth
        )
    }
}
