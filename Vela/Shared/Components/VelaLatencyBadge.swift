import SwiftUI

nonisolated enum VelaLatencyState: String, CaseIterable, Sendable {
    case unknown
    case testing
    case good
    case medium
    case slow
    case failed

    var status: VelaSemanticStatus {
        switch self {
        case .unknown: .neutral
        case .testing: .pending
        case .good: .success
        case .medium: .warning
        case .slow, .failed: .error
        }
    }

    var label: String {
        switch self {
        case .unknown:
            VelaL10n.string("latency.state.unknown", defaultValue: "Unknown")
        case .testing:
            VelaL10n.string("latency.state.testing", defaultValue: "Testing…")
        case .good:
            VelaL10n.string("latency.state.good", defaultValue: "Good")
        case .medium:
            VelaL10n.string("latency.state.medium", defaultValue: "Medium")
        case .slow:
            VelaL10n.string("latency.state.slow", defaultValue: "Slow")
        case .failed:
            VelaL10n.string("latency.state.failed", defaultValue: "Failed")
        }
    }

    var accessibilityLabel: String {
        VelaL10n.string(
            "latency.accessibility.stateFormat",
            defaultValue: "Latency, %@",
            arguments: label
        )
    }
}

struct VelaLatencyBadge: View {
    let state: VelaLatencyState
    var milliseconds: Int?

    var body: some View {
        VelaStatusPill(
            status: state.status,
            label: state.label,
            detail: measurementText,
            accessibilityText: state.accessibilityLabel
        )
        .monospacedDigit()
    }

    private var measurementText: String? {
        switch state {
        case .good, .medium, .slow:
            milliseconds.map {
                VelaL10n.string(
                    "latency.measurement.millisecondsFormat",
                    defaultValue: "%lld ms",
                    arguments: Int64($0)
                )
            }
        case .unknown, .testing, .failed:
            nil
        }
    }
}
