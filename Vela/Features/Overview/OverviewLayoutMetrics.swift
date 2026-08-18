import CoreGraphics

/// View-only geometry measured from the approved Liquid Glass Overview artwork.
///
/// The values are intentionally contained in the presentation layer. They do
/// not influence the runtime engine, persisted settings, or window policy.
nonisolated struct OverviewLayoutMetrics: Equatable, Sendable {
    enum LayoutClass: Equatable, Sendable { case compact, regular }

    let layoutClass: LayoutClass
    let contentWidth: CGFloat
    let horizontalPadding: CGFloat
    let contentCenterOffsetX: CGFloat
    let headerTop: CGFloat
    let headerHeight: CGFloat
    let nodeTop: CGFloat
    let nodeSize: CGSize
    let coreTop: CGFloat
    let coreFrameSize: CGSize
    let corePanelSize: CGSize
    let routeTop: CGFloat
    let routeSize: CGSize
    let endpointSize: CGSize
    let metricsTop: CGFloat
    let metricsSize: CGSize

    static func resolve(availableSize: CGSize) -> Self {
        let compact = availableSize.width < 1_000 || availableSize.height < 760
        let widthProgress = normalizedProgress(
            availableSize.width,
            lowerBound: 800,
            upperBound: 1_200
        )
        let heightProgress = normalizedProgress(
            availableSize.height,
            lowerBound: 628,
            upperBound: 900
        )
        let layoutProgress = min(widthProgress, heightProgress)
        let largeHeightProgress = normalizedProgress(
            availableSize.height,
            lowerBound: 900,
            upperBound: 1_080
        )
        let largeLayoutProgress = min(widthProgress, largeHeightProgress)
        let narrowWidthScale = interpolate(
            from: 0.72,
            to: 1,
            progress: normalizedProgress(
                availableSize.width,
                lowerBound: 560,
                upperBound: 800
            )
        )
        let narrowHeightScale = interpolate(
            from: 0.76,
            to: 1,
            progress: normalizedProgress(
                availableSize.height,
                lowerBound: 500,
                upperBound: 628
            )
        )
        let narrowScale = min(narrowWidthScale, narrowHeightScale)
        let horizontalPadding = interpolate(
            from: 24,
            to: 40,
            progress: widthProgress
        )
        let maximumContentWidth: CGFloat = 1_100
        let contentWidth = min(
            maximumContentWidth,
            max(0, availableSize.width - horizontalPadding * 2)
        )
        let coreWidth = min(
            contentWidth,
            interpolate(from: 300, to: 560, progress: layoutProgress)
                * narrowScale
        )
        let nodeTop =
            interpolate(from: 18, to: 38, progress: layoutProgress)
                * narrowScale
            + 10 * largeLayoutProgress
        let nodeHeight =
            interpolate(from: 66, to: 82, progress: layoutProgress)
            * narrowScale
        let coreTop =
            nodeTop
            + nodeHeight
            + interpolate(from: 20, to: 28, progress: layoutProgress) * narrowScale
            + 10 * largeLayoutProgress
        let coreHeight =
            interpolate(from: 160, to: 236, progress: layoutProgress)
                * narrowScale
            + 25 * largeLayoutProgress
        let routeTop =
            coreTop
            + coreHeight
            + interpolate(from: 18, to: 24, progress: layoutProgress) * narrowScale
            + 18 * largeLayoutProgress
        let routeHeight =
            interpolate(from: 160, to: 220, progress: layoutProgress)
                * narrowScale
            + 35 * largeLayoutProgress
        let metricsTop =
            routeTop
            + routeHeight
            + interpolate(from: 14, to: 22, progress: layoutProgress) * narrowScale
            + 16 * largeLayoutProgress
        let metricsHeight =
            interpolate(from: 144, to: 196, progress: layoutProgress)
                * narrowScale
            + 15 * largeLayoutProgress

        return Self(
            layoutClass: compact ? .compact : .regular,
            contentWidth: contentWidth,
            horizontalPadding: horizontalPadding,
            contentCenterOffsetX: 0,
            headerTop:
                interpolate(from: 20, to: 38, progress: layoutProgress)
                    * narrowScale
                + 8 * largeLayoutProgress,
            headerHeight:
                interpolate(from: 52, to: 56, progress: layoutProgress)
                * narrowScale,
            nodeTop: nodeTop,
            nodeSize: CGSize(
                width: min(
                    contentWidth,
                    interpolate(from: 330, to: 380, progress: layoutProgress)
                        * narrowScale
                ),
                height: nodeHeight
            ),
            coreTop: coreTop,
            coreFrameSize: CGSize(width: coreWidth, height: coreHeight),
            corePanelSize: CGSize(width: coreWidth, height: coreHeight),
            routeTop: routeTop,
            routeSize: CGSize(width: contentWidth, height: routeHeight),
            endpointSize: CGSize(
                width:
                    interpolate(from: 126, to: 176, progress: layoutProgress)
                    * narrowScale,
                height:
                    interpolate(from: 142, to: 196, progress: layoutProgress)
                    * narrowScale
            ),
            metricsTop: metricsTop,
            metricsSize: CGSize(width: contentWidth, height: metricsHeight)
        )
    }

    private static func normalizedProgress(
        _ value: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat
    ) -> CGFloat {
        guard upperBound > lowerBound else { return 0 }
        return min(1, max(0, (value - lowerBound) / (upperBound - lowerBound)))
    }

    private static func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * progress
    }
}
