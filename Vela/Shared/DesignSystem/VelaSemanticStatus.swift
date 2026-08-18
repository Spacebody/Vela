import SwiftUI

nonisolated enum VelaSemanticStatus: String, CaseIterable, Equatable, Hashable, Sendable {
    case neutral
    case info
    case success
    case warning
    case error
    case pending
    case stale
    case permission

    var systemImage: String {
        switch self {
        case .neutral:
            "circle"
        case .info:
            "info.circle.fill"
        case .success:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        case .pending:
            "clock.fill"
        case .stale:
            "clock.arrow.circlepath"
        case .permission:
            "person.badge.key.fill"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .neutral: VelaL10n.string("status.neutral", defaultValue: "Neutral")
        case .info: VelaL10n.string("status.information", defaultValue: "Information")
        case .success: VelaL10n.string("status.healthy", defaultValue: "Healthy")
        case .warning: VelaL10n.string("status.warning", defaultValue: "Warning")
        case .error: VelaL10n.string("status.failed", defaultValue: "Failed")
        case .pending: VelaL10n.string("status.inProgress", defaultValue: "In progress")
        case .stale: VelaL10n.string("status.stale", defaultValue: "Stale")
        case .permission: VelaL10n.string("status.permissionRequired", defaultValue: "Permission required")
        }
    }

    @MainActor
    var tint: Color {
        switch self {
        case .neutral, .stale:
            .secondary
        case .info:
            .accentColor
        case .success:
            .green
        case .warning:
            .orange
        case .error:
            .red
        case .pending, .permission:
            .blue
        }
    }
}
