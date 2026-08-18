nonisolated enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview
    case proxies
    case connections
    case rules
    case providers
    case configuration
    case unlockTests
    case settings
    case diagnostics
    case logs

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: VelaL10n.string("navigation.overview", defaultValue: "Overview")
        case .proxies: VelaL10n.string("navigation.proxies", defaultValue: "Proxies")
        case .connections: VelaL10n.string("navigation.connections", defaultValue: "Connections")
        case .rules: VelaL10n.string("navigation.rules", defaultValue: "Rules")
        case .providers: VelaL10n.string("navigation.providers", defaultValue: "Providers")
        case .configuration: VelaL10n.string("navigation.configuration", defaultValue: "Configuration")
        case .unlockTests: UnlockTestStrings.title
        case .settings: VelaL10n.string("legacy.settings", defaultValue: "Settings")
        case .diagnostics: VelaL10n.string("navigation.diagnostics", defaultValue: "Diagnostics")
        case .logs: VelaL10n.string("navigation.logs", defaultValue: "Logs")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .proxies: "point.3.connected.trianglepath.dotted"
        case .connections: "network"
        case .rules: "list.bullet.rectangle"
        case .providers: "shippingbox"
        case .configuration: "slider.horizontal.3"
        case .unlockTests: "checkmark.shield"
        case .settings: "gearshape"
        case .diagnostics: "stethoscope"
        case .logs: "text.alignleft"
        }
    }

    var isImplemented: Bool {
        true
    }
}
