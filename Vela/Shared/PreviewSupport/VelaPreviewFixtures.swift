#if DEBUG
import Foundation

nonisolated enum VelaPreviewScenario: String, CaseIterable, Equatable, Hashable, Sendable {
    case healthy
    case stopped
    case degraded
    case loading
    case empty
    case permissionRequired
    case transitioning
    case rollbackFailed
    case largeData
}

nonisolated struct VelaPreviewEnvironmentFixture: Equatable, Sendable {
    let localeIdentifier: String
    let calendarIdentifier: String
    let timeZoneIdentifier: String
    let referenceDate: Date
    let byteValues: [Int64]
    let nodeNames: [String]
    let identifiers: [String]
    let chartSamples: [Double]
    let animationsEnabled: Bool
}

nonisolated struct VelaPreviewScenarioFixture: Identifiable, Equatable, Sendable {
    let id: String
    let scenario: VelaPreviewScenario
    let status: VelaSemanticStatus
    let title: String
    let detail: String
    let itemCount: Int
    let isBusy: Bool
}

nonisolated struct VelaStatusPillPreviewFixture: Identifiable, Equatable, Sendable {
    let id: String
    let status: VelaSemanticStatus
    let label: String
    let detail: String?
}

nonisolated struct VelaMetricCardPreviewFixture: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let value: String
    let secondaryText: String
    let status: VelaSemanticStatus
    let statusLabel: String
    let density: VelaMetricCardDensity
    let actionTitle: String?
}

nonisolated struct VelaStateBannerPreviewFixture: Identifiable, Equatable, Sendable {
    let id: String
    let kind: VelaStateBannerKind
    let title: String
    let detail: String
    let primaryActionTitle: String
    let secondaryActionTitle: String?
}

nonisolated struct VelaEmptyStatePreviewFixture: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let systemImage: String
    let actionTitle: String?
}

nonisolated struct VelaInspectorValuePreviewFixture: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
}

nonisolated enum VelaPreviewFixtures {
    static let environment = VelaPreviewEnvironmentFixture(
        localeIdentifier: "en_US_POSIX",
        calendarIdentifier: "gregorian",
        timeZoneIdentifier: "UTC",
        referenceDate: Date(timeIntervalSince1970: 1_767_225_600),
        byteValues: [0, 1_024, 12_345_678, 2_400_000_000],
        nodeNames: ["Primary", "Fallback", "Direct"],
        identifiers: [
            "fixture.profile.primary",
            "fixture.provider.edge",
            "fixture.connection.browser",
        ],
        chartSamples: [0, 4, 8, 6, 12, 10, 18, 15, 22, 16, 24, 20],
        animationsEnabled: false
    )

    static func fixture(for scenario: VelaPreviewScenario) -> VelaPreviewScenarioFixture {
        switch scenario {
        case .healthy:
            scenarioFixture(scenario, .success, "Healthy", "All required checks passed.", 128)
        case .stopped:
            scenarioFixture(scenario, .neutral, "Stopped", "No runtime is active.", 0)
        case .degraded:
            scenarioFixture(scenario, .warning, "Degraded", "One health check failed.", 127)
        case .loading:
            scenarioFixture(scenario, .pending, "Loading", "Reading the latest snapshot.", 0, true)
        case .empty:
            scenarioFixture(scenario, .neutral, "Empty", "No items are available.", 0)
        case .permissionRequired:
            scenarioFixture(
                scenario,
                .permission,
                "Permission Required",
                "Approval is required before this action can continue.",
                0
            )
        case .transitioning:
            scenarioFixture(
                scenario,
                .pending,
                "Transitioning",
                "Applying and verifying the requested state.",
                128,
                true
            )
        case .rollbackFailed:
            scenarioFixture(
                scenario,
                .error,
                "Rollback Failed",
                "Manual recovery is required.",
                128
            )
        case .largeData:
            scenarioFixture(
                scenario,
                .info,
                "Large Data",
                "A deterministic 50,000-row presentation sample.",
                50_000
            )
        }
    }

    private static func scenarioFixture(
        _ scenario: VelaPreviewScenario,
        _ status: VelaSemanticStatus,
        _ title: String,
        _ detail: String,
        _ itemCount: Int,
        _ isBusy: Bool = false
    ) -> VelaPreviewScenarioFixture {
        VelaPreviewScenarioFixture(
            id: scenario.rawValue,
            scenario: scenario,
            status: status,
            title: title,
            detail: detail,
            itemCount: itemCount,
            isBusy: isBusy
        )
    }

    static let statusPills: [VelaStatusPillPreviewFixture] = [
        VelaStatusPillPreviewFixture(
            id: "connected",
            status: .success,
            label: "Connected",
            detail: "Verified now"
        ),
        VelaStatusPillPreviewFixture(
            id: "degraded",
            status: .warning,
            label: "Degraded",
            detail: "One check failed"
        ),
        VelaStatusPillPreviewFixture(
            id: "pending",
            status: .pending,
            label: "Applying",
            detail: "Validating"
        ),
        VelaStatusPillPreviewFixture(
            id: "failed",
            status: .error,
            label: "Failed",
            detail: "Recovery available"
        ),
        VelaStatusPillPreviewFixture(
            id: "permission",
            status: .permission,
            label: "Needs Approval",
            detail: "Login Items"
        ),
        VelaStatusPillPreviewFixture(
            id: "stale",
            status: .stale,
            label: "Stale",
            detail: "Last known value"
        ),
        VelaStatusPillPreviewFixture(
            id: "information",
            status: .info,
            label: "Information",
            detail: nil
        ),
        VelaStatusPillPreviewFixture(
            id: "neutral",
            status: .neutral,
            label: "Stopped",
            detail: nil
        ),
    ]

    static let metricCards: [VelaMetricCardPreviewFixture] = [
        VelaMetricCardPreviewFixture(
            id: "health",
            title: "Runtime Health",
            value: "Healthy",
            secondaryText: "All required checks passed",
            status: .success,
            statusLabel: "Healthy",
            density: .regular,
            actionTitle: "Details"
        ),
        VelaMetricCardPreviewFixture(
            id: "download",
            title: "Download",
            value: "12.3 MB/s",
            secondaryText: "2.4 GB this session",
            status: .info,
            statusLabel: "Live",
            density: .regular,
            actionTitle: nil
        ),
        VelaMetricCardPreviewFixture(
            id: "connections",
            title: "Connections",
            value: "128",
            secondaryText: "7 active processes",
            status: .neutral,
            statusLabel: "Current",
            density: .compact,
            actionTitle: "Open"
        ),
        VelaMetricCardPreviewFixture(
            id: "transition",
            title: "Backend",
            value: "Switching",
            secondaryText: "Verifying route and DNS",
            status: .pending,
            statusLabel: "Pending",
            density: .compact,
            actionTitle: nil
        ),
    ]

    static let stateBanners: [VelaStateBannerPreviewFixture] = [
        VelaStateBannerPreviewFixture(
            id: "info",
            kind: .info,
            title: "Runtime information",
            detail: "This state is informational and does not imply success.",
            primaryActionTitle: "Learn More",
            secondaryActionTitle: nil
        ),
        VelaStateBannerPreviewFixture(
            id: "warning",
            kind: .warning,
            title: "Controller is unavailable",
            detail: "The last confirmed runtime state remains visible while Vela reconnects.",
            primaryActionTitle: "Retry",
            secondaryActionTitle: "Diagnostics"
        ),
        VelaStateBannerPreviewFixture(
            id: "error",
            kind: .error,
            title: "Configuration could not be applied",
            detail: "The previous verified runtime remains active.",
            primaryActionTitle: "Review",
            secondaryActionTitle: nil
        ),
        VelaStateBannerPreviewFixture(
            id: "recovery",
            kind: .recovery,
            title: "Recovery is available",
            detail: "Restore the last known-good configuration before trying again.",
            primaryActionTitle: "Restore",
            secondaryActionTitle: "Cancel"
        ),
        VelaStateBannerPreviewFixture(
            id: "stale",
            kind: .stale,
            title: "Showing cached information",
            detail: "Values may have changed since the Controller disconnected.",
            primaryActionTitle: "Refresh",
            secondaryActionTitle: nil
        ),
        VelaStateBannerPreviewFixture(
            id: "permission",
            kind: .permission,
            title: "Approval is required",
            detail: "Allow the privileged component in Login Items before enabling TUN.",
            primaryActionTitle: "Open Settings",
            secondaryActionTitle: "Check Again"
        ),
    ]

    static let emptyStates: [VelaEmptyStatePreviewFixture] = [
        VelaEmptyStatePreviewFixture(
            id: "profiles",
            title: "No Profiles",
            description: "Import a local profile or add a subscription to get started.",
            systemImage: "doc.badge.plus",
            actionTitle: "Add Profile"
        ),
        VelaEmptyStatePreviewFixture(
            id: "providers",
            title: "No Providers",
            description: "The active configuration does not expose any providers.",
            systemImage: "shippingbox",
            actionTitle: nil
        ),
        VelaEmptyStatePreviewFixture(
            id: "connections",
            title: "No Active Connections",
            description: "Connections will appear here as applications use the network.",
            systemImage: "network",
            actionTitle: nil
        ),
        VelaEmptyStatePreviewFixture(
            id: "search",
            title: "No Matching Results",
            description: "Adjust the search text or clear the active filters.",
            systemImage: "magnifyingglass",
            actionTitle: "Clear Filters"
        ),
        VelaEmptyStatePreviewFixture(
            id: "stopped",
            title: "Mihomo Is Stopped",
            description: "Select a valid profile before starting the runtime.",
            systemImage: "stop.circle",
            actionTitle: "Start Mihomo"
        ),
        VelaEmptyStatePreviewFixture(
            id: "controller",
            title: "Controller Unavailable",
            description: "Reconnect to inspect live runtime information.",
            systemImage: "network.slash",
            actionTitle: "Run Diagnostics"
        ),
    ]

    static let inspectorValues: [VelaInspectorValuePreviewFixture] = [
        VelaInspectorValuePreviewFixture(
            id: "source",
            label: "Source",
            value: "127.0.0.1:55124"
        ),
        VelaInspectorValuePreviewFixture(
            id: "destination",
            label: "Destination",
            value: "example.test:443"
        ),
        VelaInspectorValuePreviewFixture(
            id: "route",
            label: "Route",
            value: "Rule → Primary"
        ),
    ]
}
#endif
