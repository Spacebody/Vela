#if DEBUG
import SwiftUI

nonisolated enum ConfigurationWorkbenchVisualScenario: String, CaseIterable, Sendable {
    case automatic
    case noSelection
    case emptyCatalog
    case clean
    case draft
    case validating
    case compiling
    case invalid
    case ready
    case rollingBack
    case editor
    case rules
    case diff
    case effective
}

nonisolated struct ConfigurationWorkbenchVisualSnapshot: Equatable, Sendable {
    let mode: ConfigurationWorkbenchMode
    let profileName: String?
    let profileOptions: [ConfigurationWorkbenchProfileOption]
    let status: ConfigurationWorkbenchStatus
    let preview: ConfigurationPreview?
    let banner: (kind: VelaStateBannerKind, title: String, detail: String)?
    let mutationAllowed: Bool

    static func == (
        lhs: ConfigurationWorkbenchVisualSnapshot,
        rhs: ConfigurationWorkbenchVisualSnapshot
    ) -> Bool {
        lhs.mode == rhs.mode
            && lhs.profileName == rhs.profileName
            && lhs.profileOptions == rhs.profileOptions
            && lhs.status == rhs.status
            && lhs.preview == rhs.preview
            && lhs.banner?.kind == rhs.banner?.kind
            && lhs.banner?.title == rhs.banner?.title
            && lhs.banner?.detail == rhs.banner?.detail
            && lhs.mutationAllowed == rhs.mutationAllowed
    }
}

nonisolated enum ConfigurationWorkbenchVisualFixtureFactory {
    static func snapshot(
        configuration: VisualUITestConfiguration,
        scenario: ConfigurationWorkbenchVisualScenario? = nil
    ) -> ConfigurationWorkbenchVisualSnapshot {
        let scenario = scenario ?? launchScenario()
        let state = configuration.state
        let mode = scenarioMode(scenario)
        let preview = state == .loading || state == .empty || state == .failure
            ? nil : preview(invalid: state == .partialFailure || scenario == .invalid)

        let status: ConfigurationWorkbenchStatus
        let profileName: String?
        let profileOptions: [ConfigurationWorkbenchProfileOption]
        let banner: (kind: VelaStateBannerKind, title: String, detail: String)?
        let mutationAllowed: Bool

        switch state {
        case .loading:
            status = .init(kind: .loading, changeCount: 0, issueCount: 0)
            profileName = "Daily Driver"
            profileOptions = Self.profileOptions
            banner = nil
            mutationAllowed = false
        case .empty:
            status = .init(kind: .noProfile, changeCount: 0, issueCount: 0)
            profileName = nil
            profileOptions = scenario == .noSelection
                ? Self.profileOptions : []
            banner = nil
            mutationAllowed = false
        case .pendingMutation, .transitioning:
            status = .init(kind: .applying, changeCount: 4, issueCount: 0)
            profileName = "Daily Driver"
            profileOptions = Self.profileOptions
            banner = (
                .info,
                "Applying Configuration",
                "Committed output remains active while the draft is validated and verified."
            )
            mutationAllowed = false
        case .partialFailure:
            status = .init(kind: .invalid, changeCount: 4, issueCount: 1)
            profileName = "Daily Driver"
            profileOptions = Self.profileOptions
            banner = (
                .warning,
                "Validation Needs Attention",
                "One DNS override is invalid. The committed configuration remains unchanged."
            )
            mutationAllowed = true
        case .failure:
            status = .init(kind: .recoveryRequired, changeCount: 0, issueCount: 1)
            profileName = "Daily Driver"
            profileOptions = Self.profileOptions
            banner = (
                .error,
                "Configuration Snapshot Unavailable",
                "The last committed runtime configuration remains active. Retry compilation to inspect a new snapshot."
            )
            mutationAllowed = false
        case .stale:
            status = .init(kind: .stale, changeCount: 4, issueCount: 0)
            profileName = "Daily Driver"
            profileOptions = Self.profileOptions
            banner = (
                .stale,
                "Snapshot Is Stale",
                "The selected profile generation changed. Refresh before applying this draft."
            )
            mutationAllowed = false
        case .rollbackFailed:
            status = .init(kind: .recoveryRequired, changeCount: 4, issueCount: 1)
            profileName = "Daily Driver"
            profileOptions = Self.profileOptions
            banner = (
                .recovery,
                "Rollback Needs Repair",
                "Committed generation 42 is preserved. Runtime verification did not confirm the requested rollback."
            )
            mutationAllowed = false
        default:
            status = scenarioStatus(scenario)
            profileName = scenario == .noSelection || scenario == .emptyCatalog
                ? nil : "Daily Driver"
            profileOptions = scenario == .emptyCatalog ? [] : Self.profileOptions
            banner = scenario == .rollingBack
                ? (.recovery, "Rolling Back", "The previous committed generation is being restored and verified.")
                : nil
            mutationAllowed = scenario != .compiling && scenario != .rollingBack
        }

        return ConfigurationWorkbenchVisualSnapshot(
            mode: mode,
            profileName: profileName,
            profileOptions: profileOptions,
            status: status,
            preview: preview,
            banner: banner,
            mutationAllowed: mutationAllowed
        )
    }

    private static func scenarioStatus(
        _ scenario: ConfigurationWorkbenchVisualScenario
    ) -> ConfigurationWorkbenchStatus {
        switch scenario {
        case .clean:
            .init(kind: .clean, changeCount: 0, issueCount: 0)
        case .draft:
            .init(kind: .draft, changeCount: 4, issueCount: 0)
        case .compiling, .validating:
            .init(kind: .compiling, changeCount: 4, issueCount: 0)
        case .invalid:
            .init(kind: .invalid, changeCount: 4, issueCount: 1)
        case .rollingBack:
            .init(kind: .applying, changeCount: 4, issueCount: 0)
        case .automatic, .noSelection, .emptyCatalog, .ready, .editor, .rules, .diff, .effective:
            .init(kind: .readyToApply, changeCount: 4, issueCount: 0)
        }
    }

    private static func scenarioMode(
        _ scenario: ConfigurationWorkbenchVisualScenario
    ) -> ConfigurationWorkbenchMode {
        switch scenario {
        case .rules: .rules
        case .diff: .diff
        case .effective: .effective
        default: .editor
        }
    }

    private static let profileOptions = [
        ConfigurationWorkbenchProfileOption(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            name: "Daily Driver"
        ),
        ConfigurationWorkbenchProfileOption(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            name: "Office"
        ),
    ]

    private static func preview(invalid: Bool) -> ConfigurationPreview {
        let raw = """
        mode: global
        mixed-port: 7890
        dns:
          enable: true
          enhanced-mode: fake-ip
        proxies:
          - name: Edge-A
            type: ss
        rules:
          - DOMAIN-SUFFIX,example.com,DIRECT
          - DOMAIN-KEYWORD,github,Select
          - GEOIP,LAN,DIRECT
          - MATCH,Select
        """
        let effective = """
        port: 7890
        socks-port: 7891
        mixed-port: 7892
        allow-lan: true
        mode: rule
        log-level: info
        ipv6: true

        external-controller: 127.0.0.1:9090
        secret: ""

        proxies:
          - name: Auto Select
            type: url-test
            url: http://www.gstatic.com/generate_204
            interval: 300
            proxies:
              - name: Tokyo · JP
                type: vless
                server: jp-tokyo-01.example.com
                port: 8388
                cipher: aes-256-gcm
                password: ********
                udp: true
              - name: Singapore · SG
                type: vless
                server: sg-01.example.com
                port: 443
                uuid: 55be8400-e29b-41d4-a716-446655440000
                tls: true
                servername: sg-01.example.com
        """
        let issues: [ConfigurationOverrideValidationIssue] = invalid ? [
            .init(
                severity: .error,
                code: .invalidEnhancedMode,
                path: "dns.enhanced-mode",
                message: "Enhanced mode must be fake-ip or redir-host."
            ),
        ] : []
        return ConfigurationPreview(
            rawYAML: raw,
            finalYAML: effective,
            semanticDiff: [
                .init(path: "/mode", operation: .change, source: .velaOverride, before: .string("global"), after: .string("rule")),
                .init(path: "/dns/respect-rules", operation: .add, source: .velaOverride, before: nil, after: .bool(true)),
                .init(path: "/external-controller", operation: .add, source: .velaForced, before: nil, after: .string("127.0.0.1:9090")),
                .init(path: "/secret", operation: .remove, source: .velaForced, before: .string("<redacted>"), after: nil),
            ],
            validation: ConfigurationOverrideValidationResult(issues: issues)
        )
    }

    private static func launchScenario() -> ConfigurationWorkbenchVisualScenario {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.lastIndex(of: "-VelaWorkbenchScenario") else {
            return .automatic
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return .automatic }
        return ConfigurationWorkbenchVisualScenario(rawValue: arguments[valueIndex]) ?? .automatic
    }
}

struct ConfigurationWorkbenchVisualFixtureView: View {
    let configuration: VisualUITestConfiguration
    private let snapshot: ConfigurationWorkbenchVisualSnapshot
    @State private var mode: ConfigurationWorkbenchMode

    init(configuration: VisualUITestConfiguration) {
        self.configuration = configuration
        let snapshot = ConfigurationWorkbenchVisualFixtureFactory.snapshot(configuration: configuration)
        self.snapshot = snapshot
        _mode = State(initialValue: snapshot.mode)
    }

    var body: some View {
        ConfigurationLiquidGlassWorkbenchView(
            snapshot: dashboardSnapshot,
            overrides: nil,
            mode: $mode,
            prefersInspector: configuration.inspector == .open,
            identifierNamespace: "configuration.fixture",
            action: { _ in }
        )
        .velaPageRoot()
        .navigationTitle(copy("Configuration Workbench", "配置工作台"))
        .overlay(alignment: .topLeading) {
            VisualReadyMarker(fixtureID: configuration.fixtureID)
            accessibilityMarkers
        }
        .environment(
            \.velaAccessibilityOverrides,
            VelaAccessibilityOverrides(
                reduceMotion: launchFlag("-VelaWorkbenchReduceMotion"),
                increasedContrast: launchFlag("-VelaWorkbenchIncreaseContrast")
            )
        )
    }

    private var dashboardSnapshot: ConfigurationWorkbenchSnapshot {
        ConfigurationWorkbenchSnapshot.fixture(
            activeProfileName: snapshot.profileName,
            profileOptions: snapshot.profileOptions,
            preview: snapshot.preview,
            status: snapshot.status,
            isLoading: configuration.state == .loading,
            errorMessage: configuration.state == .failure
                ? "Compilation failed (credential=<redacted>)." : nil,
            mutationAllowed: snapshot.mutationAllowed
        )
    }

    @ViewBuilder
    private var accessibilityMarkers: some View {
        if launchFlag("-VelaWorkbenchReduceMotion") == true {
            VisualSurfaceMarker(identifier: "configuration.accessibility.reduceMotion", label: "Workbench Reduce Motion")
        }
        if launchFlag("-VelaWorkbenchIncreaseContrast") == true {
            VisualSurfaceMarker(identifier: "configuration.accessibility.increasedContrast", label: "Workbench Increase Contrast")
        }
    }

    private func launchFlag(_ key: String) -> Bool? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.lastIndex(of: key) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return ["yes", "true", "1"].contains(arguments[valueIndex].lowercased())
    }

    private func copy(_ english: String, _ chinese: String) -> String {
        configuration.localeIdentifier == .simplifiedChinese ? chinese : english
    }
}
#endif
