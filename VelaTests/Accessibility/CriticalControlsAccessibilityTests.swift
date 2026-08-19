import Foundation
import Testing

@Suite("Critical control accessibility contracts")
struct CriticalControlsAccessibilityTests {
    @Test("Overview network and route controls expose stateful semantics")
    func overviewControlsExposeStatefulSemantics() throws {
        let source = try source(at: "Vela/Features/Overview/OverviewDashboardView.swift")

        #expect(source.contains(".accessibilityIdentifier(\"overview.networkControls\")"))
        #expect(source.contains(".accessibilityLabel(title)"))
        #expect(source.contains(".accessibilityValue(isOn ? strings.on : strings.off)"))
        #expect(source.contains(".accessibilityIdentifier(\"overview.route.modeMenu\")"))
        #expect(source.contains(".accessibilityValue(snapshot.route.modeTitle)"))
    }

    @Test("Proxy node rows support pointer, assistive, and keyboard activation")
    func proxyNodeRowsSupportEveryActivationPath() throws {
        let source = try source(
            at: "Vela/Features/Proxies/ProxiesLiquidGlassDashboardView.swift"
        )

        #expect(source.contains(".accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)"))
        #expect(source.contains(".accessibilityAction {"))
        #expect(source.contains(".focusable()"))
        #expect(source.contains(".onKeyPress(.return)"))
        #expect(source.contains(".onKeyPress(.space)"))
    }

    @Test("Logs filters and configuration apply remain discoverable")
    func logsAndConfigurationControlsRemainDiscoverable() throws {
        let logs = try source(at: "Vela/Features/Logs/LogsView.swift")
        let configuration = try source(
            at: "Vela/Features/Configuration/ConfigurationLiquidGlassWorkbenchView.swift"
        )

        #expect(logs.contains(".accessibilityIdentifier(\"logs.filter.\\(identifier)\")"))
        #expect(configuration.contains(".accessibilityLabel(snapshot.isLoading ? strings.applying : strings.applyChanges)"))
        #expect(configuration.contains(".accessibilityIdentifier(applyIdentifier)"))
    }

    @Test("Motion-heavy daily-driver pages honor Reduce Motion")
    func dailyDriverPagesHonorReduceMotion() throws {
        for path in [
            "Vela/Features/Overview/OverviewDashboardView.swift",
            "Vela/Features/Proxies/ProxiesLiquidGlassDashboardView.swift",
            "Vela/Features/Connections/ConnectionsView.swift",
        ] {
            let source = try source(at: path)
            #expect(
                source.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"),
                "Missing Reduce Motion environment usage in \(path)"
            )
        }
    }

    private func source(at path: String) throws -> String {
        try String(contentsOf: Self.repositoryRoot.appending(path: path), encoding: .utf8)
    }

    private static var repositoryRoot: URL {
        if let staged = ProcessInfo.processInfo.environment["VELA_TEST_REPOSITORY_ROOT"],
           !staged.isEmpty
        {
            return URL(fileURLWithPath: staged, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
