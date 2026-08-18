import CoreGraphics
import Foundation
import Testing
@testable import Vela

@Suite("Vela visual system contracts")
struct VelaDesignSystemContractTests {
    @Test("Spacing, radius, and window metrics match the visual source of truth")
    func tokensMatchVisualSourceOfTruth() {
        #expect([
            VelaSpacing.micro,
            VelaSpacing.xSmall,
            VelaSpacing.small,
            VelaSpacing.medium,
            VelaSpacing.standard,
            VelaSpacing.section,
            VelaSpacing.large,
            VelaSpacing.xLarge,
        ] == [2, 4, 8, 12, 16, 20, 24, 32])

        #expect([
            VelaRadius.small,
            VelaRadius.panel,
            VelaRadius.onboarding,
        ] == [8, 12, 16])

        #expect(VelaMetrics.minimumWindow == CGSize(width: 1_040, height: 680))
        #expect(VelaMetrics.defaultWindow == CGSize(width: 1_280, height: 820))
        #expect(VelaMetrics.largeReferenceWindow == CGSize(width: 1_600, height: 1_000))
        #expect(VelaMetrics.applicationSidebarWidth == 240)
        #expect(VelaMetrics.sidebarMinimumWidth == 208)
        #expect(VelaMetrics.sidebarIdealWidth == 232)
        #expect(VelaMetrics.sidebarMaximumWidth == 260)
        #expect(VelaMetrics.sidebarRowHeight == 36)
        #expect(VelaMetrics.sidebarIconSize == 16)
        #expect(VelaMetrics.sidebarIconWidth == 20)
        #expect(VelaMetrics.inspectorIdealWidth == 320)
        #expect(VelaMetrics.inspectorMaximumWidth == 380)
        #expect(VelaMetrics.tableRowHeight == 36)
        #expect(VelaMetrics.compactControlHeight == 30)
        #expect(VelaMetrics.regularControlHeight == 32)
        #expect(VelaMetrics.primaryControlHeight == 36)
        #expect(VelaMetrics.compactMetricCardMinimumHeight >= 82)
        #expect(VelaMetrics.regularMetricCardMinimumHeight >= VelaMetrics.compactMetricCardMinimumHeight)
    }

    @Test("Alternating table rows are reserved for loaded content")
    func alternatingRowsDoNotImitateLoadingSkeletons() {
        #expect(VelaTableContentState.loaded.usesAlternatingRows)
        #expect(!VelaTableContentState.loading.usesAlternatingRows)
        #expect(!VelaTableContentState.empty.usesAlternatingRows)
        #expect(!VelaTableContentState.filteredEmpty.usesAlternatingRows)
        #expect(!VelaTableContentState.offline.usesAlternatingRows)
        #expect(!VelaTableContentState.failure.usesAlternatingRows)

        #expect(ConnectionsTablePresentation.contentState(
            visibleCount: 0,
            totalCount: 0,
            isStreaming: false,
            hasActiveFilters: false,
            hasQuery: false,
            hasError: false
        ) == .offline)
        #expect(ConnectionsTablePresentation.contentState(
            visibleCount: 0,
            totalCount: 4,
            isStreaming: true,
            hasActiveFilters: true,
            hasQuery: false,
            hasError: false
        ) == .filteredEmpty)
        #expect(!RulesWorkspacePhase.loading.preservesCommittedRows)
        #expect(RulesWorkspacePhase.loaded.preservesCommittedRows)
        #expect(!RulesWorkspacePhase.failure.preservesCommittedRows)
    }

    @Test("Providers presentation distinguishes every empty and operational state")
    func providersPresentationStateMatrix() {
        #expect(ProvidersPresentation.contentState(
            visibleCount: 0,
            selectedKindCount: 0,
            totalCount: 0,
            isLoading: false,
            hasError: false
        ) == .globalEmpty)
        #expect(ProvidersPresentation.contentState(
            visibleCount: 0,
            selectedKindCount: 0,
            totalCount: 3,
            isLoading: false,
            hasError: false
        ) == .kindEmpty)
        #expect(ProvidersPresentation.contentState(
            visibleCount: 0,
            selectedKindCount: 2,
            totalCount: 3,
            isLoading: false,
            hasError: false
        ) == .filteredEmpty)
        #expect(ProvidersPresentation.contentState(
            visibleCount: 2,
            selectedKindCount: 2,
            totalCount: 3,
            isLoading: false,
            hasError: false
        ) == .loaded)
        #expect(ProvidersPresentation.contentState(
            visibleCount: 0,
            selectedKindCount: 0,
            totalCount: 0,
            isLoading: true,
            hasError: false
        ) == .loading)
        #expect(ProvidersPresentation.contentState(
            visibleCount: 0,
            selectedKindCount: 0,
            totalCount: 0,
            isLoading: false,
            hasError: true
        ) == .failure)
    }

    @Test("Providers controls follow actionable snapshots")
    func providersControlsFollowActionableContent() {
        #expect(ProvidersPresentation.contentState(
            visibleCount: 2,
            selectedKindCount: 2,
            totalCount: 2,
            isLoading: false,
            hasError: false
        ) == .loaded)
        #expect(ProvidersPresentation.contentState(
            visibleCount: 0,
            selectedKindCount: 0,
            totalCount: 0,
            isLoading: false,
            hasError: true
        ) == .failure)
    }

    @Test("Recovery and empty-state actions use regular desktop controls")
    func recoveryActionsUseRegularControlDensity() {
        #expect(VelaMetrics.regularControlHeight == 32)
        #expect(PageRecoveryActionMetrics.compactContentMinimumWidth == 96)
        #expect(PageRecoveryActionMetrics.contentHeight == 22)
    }

    @Test("Typography and motion use the comfortable desktop scale")
    func typographyAndMotionMatchVisualSourceOfTruth() {
        #expect(VelaTypeSize.mainPageTitle == 28)
        #expect(VelaTypeSize.pageTitle == 22)
        #expect(VelaTypeSize.sectionTitle == 15)
        #expect(VelaTypeSize.body == 14)
        #expect(VelaTypeSize.table == 13)
        #expect(VelaTypeSize.caption == 12)
        #expect(VelaTypeSize.metric == 20)
        #expect(VelaTypeSize.code == 13)

        #expect(VelaMotion.fastSeconds == 0.12)
        #expect(VelaMotion.standardSeconds == 0.18)
        #expect(VelaMotion.slowSeconds == 0.24)
        #expect(VelaMotion.resolvedDuration(VelaMotion.standardSeconds, reduceMotion: false) == 0.18)
        #expect(VelaMotion.resolvedDuration(VelaMotion.standardSeconds, reduceMotion: true) == 0)
    }

    @Test("Every semantic status has icon and spoken state")
    func semanticStatusesAreColorIndependent() {
        #expect(VelaSemanticStatus.allCases.count == 8)
        #expect(VelaSemanticStatus.allCases.allSatisfy { !$0.systemImage.isEmpty })
        #expect(VelaSemanticStatus.allCases.allSatisfy { !$0.accessibilityValue.isEmpty })
        #expect(Set(VelaSemanticStatus.allCases.map(\.accessibilityValue)).count == 8)
    }

    @Test("Banner kinds resolve only through semantic status")
    func bannerKindsUseSemanticStatus() {
        #expect(VelaStateBannerKind.info.semanticStatus == .info)
        #expect(VelaStateBannerKind.warning.semanticStatus == .warning)
        #expect(VelaStateBannerKind.error.semanticStatus == .error)
        #expect(VelaStateBannerKind.recovery.semanticStatus == .info)
        #expect(VelaStateBannerKind.stale.semanticStatus == .stale)
        #expect(VelaStateBannerKind.permission.semanticStatus == .permission)
        #expect(VelaStateBannerKind.allCases.count == 6)
    }

    @Test("Metric card density never drops below the pack minimum")
    func metricCardDensityUsesTokenMinimums() {
        #expect(VelaMetricCardDensity.allCases == [.compact, .regular])
        #expect(VelaMetricCardDensity.compact.minimumHeight == 82)
        #expect(VelaMetricCardDensity.regular.minimumHeight == 96)
    }

    @Test("Latency presentation delegates thresholds to callers")
    func latencyStatesUseSemanticStatus() {
        #expect(VelaLatencyState.allCases == [.unknown, .testing, .good, .medium, .slow, .failed])
        #expect(VelaLatencyState.unknown.status == .neutral)
        #expect(VelaLatencyState.testing.status == .pending)
        #expect(VelaLatencyState.good.status == .success)
        #expect(VelaLatencyState.medium.status == .warning)
        #expect(VelaLatencyState.slow.status == .error)
        #expect(VelaLatencyState.failed.status == .error)
        #expect(VelaLatencyState.allCases.allSatisfy { !$0.label.isEmpty })
        #expect(Set(VelaLatencyState.allCases.map(\.label)).count == 6)
        #expect(VelaLatencyState.allCases.allSatisfy {
            $0.accessibilityLabel.contains($0.label)
                && !$0.status.systemImage.isEmpty
        })
    }

    @Test("Traffic sparklines retain only the newest bounded sample window")
    func trafficSparklineBoundsPresentationSamples() {
        let samples = Array(0 ... 180).map(Double.init)
        let bounded = Array(VelaTrafficSparkline.bounded(samples))

        #expect(VelaTrafficSparkline.maximumPointCount == 120)
        #expect(bounded.count == 120)
        #expect(bounded.first == 61)
        #expect(bounded.last == 180)
    }

    @Test("Result summaries treat warnings and errors as needing attention")
    func resultSummaryAttentionIsNotColorDerivedAtTheCallSite() {
        let statuses = VelaSemanticStatus.allCases.map { status in
            VelaResultItem(
                id: status.rawValue,
                title: status.rawValue,
                detail: nil,
                status: status
            )
        }

        #expect(statuses.first { $0.status == .warning }?.needsAttention == true)
        #expect(statuses.first { $0.status == .error }?.needsAttention == true)
        #expect(statuses.first { $0.status == .success }?.needsAttention == false)
        #expect(statuses.first { $0.status == .stale }?.needsAttention == false)
    }

}
