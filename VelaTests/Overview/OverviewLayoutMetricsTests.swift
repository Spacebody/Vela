import CoreGraphics
import Testing
@testable import Vela

@Suite("Overview design-pack layout metrics")
struct OverviewLayoutMetricsTests {
    @Test("Approved 1440 by 900 canvas maps to exact detail anchors")
    func approvedCanvasUsesExactAnchors() {
        let metrics = OverviewLayoutMetrics.resolve(
            availableSize: CGSize(width: 1_200, height: 900)
        )

        #expect(metrics.layoutClass == .regular)
        #expect(metrics.contentWidth == 1_100)
        #expect(metrics.horizontalPadding == 40)
        #expect(metrics.contentCenterOffsetX == 0)
        #expect(metrics.headerTop == 38)
        #expect(metrics.nodeTop == 38)
        #expect(metrics.nodeSize == CGSize(width: 380, height: 82))
        #expect(metrics.coreTop == 148)
        #expect(metrics.coreFrameSize == CGSize(width: 560, height: 236))
        #expect(metrics.corePanelSize == CGSize(width: 560, height: 236))
        #expect(metrics.routeTop == 408)
        #expect(metrics.routeSize == CGSize(width: 1_100, height: 220))
        #expect(metrics.endpointSize == CGSize(width: 176, height: 196))
        #expect(metrics.metricsTop == 650)
        #expect(metrics.metricsSize == CGSize(width: 1_100, height: 196))
    }

    @Test("Minimum window uses compact geometry without clipping")
    func minimumWindowUsesCompactGeometry() {
        let metrics = OverviewLayoutMetrics.resolve(
            availableSize: CGSize(width: 800, height: 628)
        )

        #expect(metrics.layoutClass == .compact)
        #expect(metrics.contentWidth == 752)
        #expect(metrics.horizontalPadding == 24)
        #expect(metrics.contentCenterOffsetX == 0)
        #expect(metrics.headerTop == 20)
        #expect(metrics.nodeTop == 18)
        #expect(metrics.nodeSize == CGSize(width: 330, height: 66))
        #expect(metrics.coreTop == 104)
        #expect(metrics.coreFrameSize == CGSize(width: 300, height: 160))
        #expect(metrics.routeTop == 282)
        #expect(metrics.routeSize == CGSize(width: 752, height: 160))
        #expect(metrics.metricsTop == 456)
        #expect(metrics.metricsSize == CGSize(width: 752, height: 144))
        #expect(metrics.metricsTop + metrics.metricsSize.height <= 628)
        #expect(metrics.routeSize.width <= metrics.contentWidth)
        #expect(metrics.nodeTop + metrics.nodeSize.height + 20 <= metrics.coreTop)
    }

    @Test("Larger windows preserve the approved dashboard maximum width")
    func largeWindowRemainsBounded() {
        let reference = OverviewLayoutMetrics.resolve(
            availableSize: CGSize(width: 1_200, height: 900)
        )
        let large = OverviewLayoutMetrics.resolve(
            availableSize: CGSize(width: 1_600, height: 1_080)
        )

        #expect(large.layoutClass == .regular)
        #expect(large.contentWidth == reference.contentWidth)
        #expect(large.coreFrameSize == CGSize(width: 560, height: 261))
        #expect(large.routeSize == CGSize(width: 1_100, height: 255))
        #expect(large.metricsSize == CGSize(width: 1_100, height: 211))
        #expect(large.nodeTop == reference.nodeTop + 10)
        #expect(large.coreTop == reference.coreTop + 20)
        #expect(large.routeTop == reference.routeTop + 63)
        #expect(large.metricsTop == reference.metricsTop + 114)
        #expect(large.metricsTop + large.metricsSize.height <= 1_080)
    }

    @Test("Compact geometry scales horizontally without horizontal scrolling")
    func compactGeometryScalesHorizontally() {
        let narrow = OverviewLayoutMetrics.resolve(
            availableSize: CGSize(width: 780, height: 628)
        )

        #expect(narrow.contentWidth == 732)
        #expect(narrow.nodeSize.width <= narrow.contentWidth)
        #expect(narrow.coreFrameSize.width <= narrow.contentWidth)
        #expect(narrow.routeSize.width <= narrow.contentWidth)
        #expect(narrow.metricsSize.width <= narrow.contentWidth)
    }

    @Test("MacBook window keeps the complete regular metrics strip visible")
    func macBookWindowKeepsMetricsVisible() {
        let metrics = OverviewLayoutMetrics.resolve(
            availableSize: CGSize(width: 1_040, height: 800)
        )

        #expect(metrics.layoutClass == .regular)
        #expect(metrics.metricsTop + metrics.metricsSize.height <= 800)
        #expect(metrics.routeTop + metrics.routeSize.height < metrics.metricsTop)
    }

    @Test("Geometry remains continuous across the former compact breakpoint")
    func geometryRemainsContinuousAcrossFormerBreakpoint() {
        let before = OverviewLayoutMetrics.resolve(
            availableSize: CGSize(width: 999.5, height: 759.5)
        )
        let after = OverviewLayoutMetrics.resolve(
            availableSize: CGSize(width: 1_000.5, height: 760.5)
        )

        #expect(before.layoutClass == .compact)
        #expect(after.layoutClass == .regular)
        #expect(abs(after.coreTop - before.coreTop) < 1)
        #expect(abs(after.coreFrameSize.width - before.coreFrameSize.width) < 2)
        #expect(abs(after.coreFrameSize.height - before.coreFrameSize.height) < 1)
        #expect(abs(after.routeTop - before.routeTop) < 2)
        #expect(abs(after.metricsTop - before.metricsTop) < 2)
    }

    @Test("Every responsive size preserves vertical safety gaps")
    func responsiveSizesPreserveVerticalSafetyGaps() {
        let sizes = [
            CGSize(width: 800, height: 628),
            CGSize(width: 900, height: 700),
            CGSize(width: 1_000, height: 760),
            CGSize(width: 1_040, height: 800),
            CGSize(width: 1_200, height: 900),
            CGSize(width: 1_600, height: 1_080),
        ]

        for size in sizes {
            let metrics = OverviewLayoutMetrics.resolve(availableSize: size)

            #expect(metrics.nodeTop + metrics.nodeSize.height + 20 <= metrics.coreTop)
            #expect(metrics.coreTop + metrics.coreFrameSize.height + 18 <= metrics.routeTop)
            #expect(metrics.routeTop + metrics.routeSize.height + 14 <= metrics.metricsTop)
            #expect(metrics.metricsTop + metrics.metricsSize.height <= size.height)
        }
    }
}
