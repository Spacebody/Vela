import Foundation

nonisolated enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case general
    case network
    case tun
    case core
    case automation
    case updates
    case betaDiagnostics
    case advanced
    case about

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .network: "network"
        case .tun: "shield.lefthalf.filled"
        case .core: "cpu"
        case .automation: "bolt"
        case .updates: "arrow.triangle.2.circlepath"
        case .betaDiagnostics: "waveform.path.ecg"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    var accessibilityIdentifier: String {
        "settings.category.\(rawValue)"
    }

    var title: String {
        switch self {
        case .general: VelaL10n.string("settings.category.general", defaultValue: "General")
        case .network: VelaL10n.string("settings.category.network", defaultValue: "Network")
        case .tun: "TUN"
        case .core: VelaL10n.string("settings.category.core", defaultValue: "Core")
        case .automation: VelaL10n.string("settings.category.automation", defaultValue: "Automation")
        case .updates: VelaL10n.string("settings.category.updates", defaultValue: "Updates")
        case .betaDiagnostics:
            VelaL10n.string(
                "settings.category.betaDiagnostics",
                defaultValue: "Beta & Diagnostics"
            )
        case .advanced: VelaL10n.string("settings.category.advanced", defaultValue: "Advanced")
        case .about: VelaL10n.string("settings.category.about", defaultValue: "About")
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            VelaL10n.string(
                "settings.category.general.subtitle",
                defaultValue: "Startup, menu bar and privacy"
            )
        case .network:
            VelaL10n.string(
                "settings.category.network.subtitle",
                defaultValue: "System Proxy and network data"
            )
        case .tun:
            VelaL10n.string(
                "settings.category.tun.subtitle",
                defaultValue: "Privileged routing and interface settings"
            )
        case .core:
            VelaL10n.string(
                "settings.category.core.subtitle",
                defaultValue: "Installed Mihomo cores and verification"
            )
        case .automation:
            VelaL10n.string(
                "settings.category.automation.subtitle",
                defaultValue: "Automatic Scenes and available integrations"
            )
        case .updates:
            VelaL10n.string(
                "settings.category.updates.subtitle",
                defaultValue: "Signed releases and update preferences"
            )
        case .betaDiagnostics:
            VelaL10n.string(
                "settings.category.betaDiagnostics.subtitle",
                defaultValue: "Local reliability evidence and self-tests"
            )
        case .advanced:
            VelaL10n.string(
                "settings.category.advanced.subtitle",
                defaultValue: "Privileged components and local data"
            )
        case .about:
            VelaL10n.string(
                "settings.category.about.subtitle",
                defaultValue: "Version, licenses and support"
            )
        }
    }
}
