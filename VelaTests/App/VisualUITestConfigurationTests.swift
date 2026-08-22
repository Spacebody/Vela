import CoreGraphics
import Foundation
import Testing
@testable import Vela

@Suite("Visual UI test configuration")
struct VisualUITestConfigurationTests {
    @Test("Visual controls are ignored unless the Debug-only mode is explicitly enabled")
    func productionIgnoresVisualArguments() throws {
        let configuration = try VisualUITestConfiguration.resolve(
            arguments: [
                "Vela",
                VisualUITestConfiguration.pageKey, "overview",
                VisualUITestConfiguration.appearanceKey, "dark",
            ]
        )

        #expect(configuration == nil)
    }

    @Test("A complete visual contract resolves deterministically")
    func resolvesCompleteContract() throws {
        let configuration = try #require(
            try VisualUITestConfiguration.resolve(arguments: validArguments())
        )

        #expect(configuration.fixtureID == "overview.loadedHealthy")
        #expect(configuration.page == .overview)
        #expect(configuration.state == .loaded)
        #expect(configuration.appearance == .dark)
        #expect(configuration.localeIdentifier == .simplifiedChinese)
        #expect(configuration.windowSize.size == CGSize(width: 1_280, height: 820))
        #expect(configuration.inspector == .notApplicable)
        #expect(configuration.fixedDate == ISO8601DateFormatter().date(from: "2026-07-14T09:41:00Z"))
        #expect(configuration.uuidSeed == 20_260_714)
        #expect(!configuration.usesProductionFeatureViews)
    }

    @Test("Production feature-view verification is explicit and remains isolated")
    func productionFeatureViewsRequireExplicitYes() throws {
        var supportedArguments = validArguments()
        Self.replaceValue(
            after: VisualUITestConfiguration.fixtureKey,
            with: "rules.empty",
            in: &supportedArguments
        )
        Self.replaceValue(
            after: VisualUITestConfiguration.pageKey,
            with: "rules",
            in: &supportedArguments
        )
        Self.replaceValue(
            after: VisualUITestConfiguration.stateKey,
            with: "empty",
            in: &supportedArguments
        )
        Self.replaceValue(
            after: VisualUITestConfiguration.inspectorKey,
            with: "closed",
            in: &supportedArguments
        )
        let enabled = try #require(
            try VisualUITestConfiguration.resolve(
                arguments: supportedArguments + [
                    VisualUITestConfiguration.productionFeatureViewsKey,
                    "YES",
                ]
            )
        )
        #expect(enabled.usesProductionFeatureViews)

        #expect(throws: VisualUITestConfigurationError.invalidValue(
            key: VisualUITestConfiguration.productionFeatureViewsKey,
            value: "NO"
        )) {
            try VisualUITestConfiguration.resolve(
                arguments: validArguments() + [
                    VisualUITestConfiguration.productionFeatureViewsKey,
                    "NO",
                ]
            )
        }
    }

    @Test("A production feature-view marker alone fails closed")
    func productionFeatureViewMarkerAloneFailsClosed() throws {
        let arguments = [
            "Vela",
            VisualUITestConfiguration.productionFeatureViewsKey, "YES",
        ]

        #expect(VisualUITestConfiguration.isRequested(arguments: arguments))
        #expect(throws: VisualUITestConfigurationError.missingValue(
            key: VisualUITestConfiguration.modeKey
        )) {
            try VisualUITestConfiguration.resolve(arguments: arguments)
        }
        #expect(
            try AppLaunchConfiguration.resolve(
                arguments: arguments,
                environment: [:]
            ) == .uiTesting
        )
        #expect(!AppDelegate.allowsLifecycleBootstrap(arguments: arguments))
    }

    @Test("Production feature-view verification only accepts proven routes")
    func productionFeatureViewRouteMustBeAllowlisted() throws {
        let supportedConfiguration = try VisualUITestConfiguration.resolve(
            arguments: validArguments() + [
                VisualUITestConfiguration.productionFeatureViewsKey,
                "YES",
            ]
        )
        #expect(supportedConfiguration?.usesProductionFeatureViews == true)

        #expect(throws: VisualUITestConfigurationError.unsupportedProductionFeatureView(
            "overview.loading"
        )) {
            try VisualUITestConfiguration.resolve(
                arguments: validArguments() + [
                    VisualUITestConfiguration.fixtureKey,
                    "overview.loading",
                    VisualUITestConfiguration.stateKey,
                    "loading",
                    VisualUITestConfiguration.productionFeatureViewsKey,
                    "YES",
                ]
            )
        }
    }

    @Test("Missing controls fail closed after mode is requested")
    func missingValueFailsClosed() {
        #expect(throws: VisualUITestConfigurationError.missingValue(
            key: VisualUITestConfiguration.fixtureKey
        )) {
            try VisualUITestConfiguration.resolve(arguments: [
                "Vela",
                VisualUITestConfiguration.modeKey, "YES",
            ])
        }
    }

    @Test("A malformed visual mode marker fails closed")
    func malformedModeFailsClosed() {
        #expect(VisualUITestConfiguration.isRequested(arguments: [
            "Vela",
            VisualUITestConfiguration.modeKey, "NO",
        ]))
        #expect(throws: VisualUITestConfigurationError.invalidValue(
            key: VisualUITestConfiguration.modeKey,
            value: "NO"
        )) {
            try VisualUITestConfiguration.resolve(arguments: [
                "Vela",
                VisualUITestConfiguration.modeKey, "NO",
            ])
        }
    }

    @Test("A visual mode marker without a value fails closed")
    func missingModeValueFailsClosed() {
        #expect(VisualUITestConfiguration.isRequested(arguments: [
            "Vela",
            VisualUITestConfiguration.modeKey,
        ]))
        #expect(throws: VisualUITestConfigurationError.missingValue(
            key: VisualUITestConfiguration.modeKey
        )) {
            try VisualUITestConfiguration.resolve(arguments: [
                "Vela",
                VisualUITestConfiguration.modeKey,
            ])
        }
    }

    @Test("Fixture ID must bind the requested page and state")
    func fixtureMismatchFailsClosed() {
        var arguments = validArguments()
        let fixtureValueIndex = arguments.firstIndex(
            of: VisualUITestConfiguration.fixtureKey
        ).map { arguments.index(after: $0) }
        if let fixtureValueIndex {
            arguments[fixtureValueIndex] = "connections.loaded"
        }

        #expect(throws: VisualUITestConfigurationError.fixtureMismatch(
            expected: "overview.loadedHealthy",
            actual: "connections.loaded"
        )) {
            try VisualUITestConfiguration.resolve(arguments: arguments)
        }
    }

    @Test("A page-state pair must be registered by the page contract")
    func unregisteredPageStateFailsClosed() {
        var arguments = validArguments()
        let fixtureValueIndex = arguments.firstIndex(
            of: VisualUITestConfiguration.fixtureKey
        ).map { arguments.index(after: $0) }
        let stateValueIndex = arguments.firstIndex(
            of: VisualUITestConfiguration.stateKey
        ).map { arguments.index(after: $0) }
        if let fixtureValueIndex, let stateValueIndex {
            arguments[fixtureValueIndex] = "overview.rollbackFailed"
            arguments[stateValueIndex] = "rollbackFailed"
        }

        #expect(throws: VisualUITestConfigurationError.unregisteredFixture(
            "overview.rollbackFailed"
        )) {
            try VisualUITestConfiguration.resolve(arguments: arguments)
        }
    }

    @Test("Startup smoke and visual fixture modes cannot be combined")
    func startupSmokeConflictFailsClosed() {
        let arguments = validArguments() + [AppLaunchConfiguration.startupSmokeArgument]

        #expect(throws: VisualUITestConfigurationError.conflictingStartupSmoke) {
            try VisualUITestConfiguration.resolve(arguments: arguments)
        }
    }

    @Test("Inspector values are constrained by the typed fixture route")
    func unsupportedInspectorFailsClosed() {
        var arguments = validArguments()
        let inspectorValueIndex = arguments.firstIndex(
            of: VisualUITestConfiguration.inspectorKey
        ).map { arguments.index(after: $0) }
        if let inspectorValueIndex {
            arguments[inspectorValueIndex] = "open"
        }

        #expect(throws: VisualUITestConfigurationError.unsupportedInspector(
            fixtureID: "overview.loadedHealthy",
            inspector: "open"
        )) {
            try VisualUITestConfiguration.resolve(arguments: arguments)
        }
    }

    @Test("Inspector-capable routes accept open and closed captures")
    func inspectorRouteAcceptsBothStates() throws {
        for inspector in ["closed", "open"] {
            var arguments = validArguments()
            Self.replaceValue(
                after: VisualUITestConfiguration.fixtureKey,
                with: "connections.loaded",
                in: &arguments
            )
            Self.replaceValue(
                after: VisualUITestConfiguration.pageKey,
                with: "connections",
                in: &arguments
            )
            Self.replaceValue(
                after: VisualUITestConfiguration.inspectorKey,
                with: inspector,
                in: &arguments
            )

            let configuration = try #require(
                try VisualUITestConfiguration.resolve(arguments: arguments)
            )
            #expect(configuration.inspector.rawValue == inspector)
        }
    }

    private func validArguments() -> [String] {
        [
            "Vela",
            VisualUITestConfiguration.modeKey, "YES",
            VisualUITestConfiguration.fixtureKey, "overview.loadedHealthy",
            VisualUITestConfiguration.pageKey, "overview",
            VisualUITestConfiguration.stateKey, "loaded",
            VisualUITestConfiguration.appearanceKey, "dark",
            VisualUITestConfiguration.localeKey, "zh-Hans",
            VisualUITestConfiguration.windowKey, "1280x820",
            VisualUITestConfiguration.inspectorKey, "na",
            VisualUITestConfiguration.fixedDateKey, "2026-07-14T09:41:00Z",
            VisualUITestConfiguration.uuidSeedKey, "20260714",
        ]
    }

    private static func replaceValue(
        after key: String,
        with value: String,
        in arguments: inout [String]
    ) {
        guard let keyIndex = arguments.firstIndex(of: key) else { return }
        arguments[arguments.index(after: keyIndex)] = value
    }
}
