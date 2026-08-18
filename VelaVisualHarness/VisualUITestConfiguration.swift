#if DEBUG
import CoreGraphics
import Foundation
import SwiftUI

/// Strict, Debug-only launch contract for deterministic visual evidence.
///
/// The file lives in a separate synchronized source root and is excluded from
/// Release builds. Merely requesting visual mode is enough to select the
/// isolated app dependency assembly; malformed controls then fail closed
/// instead of falling through to a live production launch.
nonisolated struct VisualUITestConfiguration: Equatable, Sendable {
    enum Page: String, CaseIterable, Equatable, Sendable {
        case overview
        case proxies
        case connections
        case rules
        case providers
        case workbench
        case diagnostics
        case logs
        case settings
        case tunFlow
        case menuBar
        case updateCoreRecovery
        case helpSupport

        @MainActor
        var appSection: AppSection? {
            switch self {
            case .overview: .overview
            case .proxies: .proxies
            case .connections: .connections
            case .rules: .rules
            case .providers: .providers
            case .workbench: .configuration
            case .diagnostics: .diagnostics
            case .logs: .logs
            case .settings, .tunFlow, .menuBar, .updateCoreRecovery, .helpSupport:
                nil
            }
        }

        var registeredStates: Set<State> {
            Set(VisualFixtureRouteCatalog.states(for: self))
        }
    }

    enum State: String, CaseIterable, Equatable, Hashable, Sendable {
        case loading
        case loaded
        case empty
        case refreshing
        case pendingMutation
        case partialFailure
        case failure
        case offline
        case stale
        case permissionRequired
        case transitioning
        case rollbackFailed
    }

    enum Appearance: String, CaseIterable, Equatable, Sendable {
        case light
        case dark
    }

    enum LocaleIdentifier: String, CaseIterable, Equatable, Sendable {
        case english = "en"
        case simplifiedChinese = "zh-Hans"
    }

    enum WindowSize: String, CaseIterable, Equatable, Sendable {
        case minimum = "1040x680"
        case overviewCompact = "1100x720"
        case overviewMedium = "1280x800"
        case defaultSize = "1280x820"
        case overviewBaseline = "1440x900"
        case large = "1600x1000"

        var size: CGSize {
            switch self {
            case .minimum: VelaMetrics.minimumWindow
            case .overviewCompact: CGSize(width: 1_100, height: 720)
            case .overviewMedium: CGSize(width: 1_280, height: 800)
            case .defaultSize: VelaMetrics.defaultWindow
            case .overviewBaseline: CGSize(width: 1_440, height: 900)
            case .large: VelaMetrics.largeReferenceWindow
            }
        }
    }

    enum Inspector: String, CaseIterable, Equatable, Sendable {
        case open
        case closed
        case notApplicable = "na"
    }

    static let modeKey = "-VelaVisualTestMode"
    static let fixtureKey = "-VelaFixture"
    static let pageKey = "-VelaPage"
    static let stateKey = "-VelaState"
    static let appearanceKey = "-VelaAppearance"
    static let localeKey = "-VelaLocale"
    static let windowKey = "-VelaWindow"
    static let inspectorKey = "-VelaInspector"
    static let fixedDateKey = "-VelaFixedDate"
    static let uuidSeedKey = "-VelaUUIDSeed"
    static let showOnboardingKey = "-VelaShowOnboarding"
    static let productionFeatureViewsKey = "-VelaProductionFeatureViews"

    let fixtureID: String
    let page: Page
    let state: State
    let appearance: Appearance
    let localeIdentifier: LocaleIdentifier
    let windowSize: WindowSize
    let inspector: Inspector
    let fixedDate: Date
    let uuidSeed: UInt64
    let usesProductionFeatureViews: Bool

    var locale: Locale {
        Locale(identifier: localeIdentifier.rawValue)
    }

    var colorScheme: ColorScheme {
        switch appearance {
        case .light: .light
        case .dark: .dark
        }
    }

    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        // The presence of the Debug-only mode marker is itself an explicit
        // request. Treat malformed or incomplete values as requested so the
        // app cannot fall through to production dependencies before `resolve`
        // rejects the contract.
        arguments.contains(modeKey)
            || arguments.contains(productionFeatureViewsKey)
            || arguments.contains(VelaWindowTestRequest.modeKey)
    }

    static func forcesOnboarding(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        value(for: showOnboardingKey, in: arguments)?.caseInsensitiveCompare("YES") == .orderedSame
    }

    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws -> VisualUITestConfiguration? {
        guard isRequested(arguments: arguments) else { return nil }
        let modeValue = try requiredValue(modeKey, arguments: arguments)
        guard modeValue.caseInsensitiveCompare("YES") == .orderedSame else {
            throw VisualUITestConfigurationError.invalidValue(
                key: modeKey,
                value: modeValue
            )
        }
        guard !arguments.contains(AppLaunchConfiguration.startupSmokeArgument) else {
            throw VisualUITestConfigurationError.conflictingStartupSmoke
        }

        let fixtureID = try requiredValue(fixtureKey, arguments: arguments)
        let page = try enumValue(Page.self, key: pageKey, arguments: arguments)
        let state = try enumValue(State.self, key: stateKey, arguments: arguments)
        let appearance = try enumValue(
            Appearance.self,
            key: appearanceKey,
            arguments: arguments
        )
        let localeIdentifier = try enumValue(
            LocaleIdentifier.self,
            key: localeKey,
            arguments: arguments
        )
        let windowSize = try enumValue(
            WindowSize.self,
            key: windowKey,
            arguments: arguments
        )
        let inspector = try enumValue(
            Inspector.self,
            key: inspectorKey,
            arguments: arguments
        )
        let fixedDateValue = try requiredValue(fixedDateKey, arguments: arguments)
        guard let fixedDate = ISO8601DateFormatter().date(from: fixedDateValue) else {
            throw VisualUITestConfigurationError.invalidValue(
                key: fixedDateKey,
                value: fixedDateValue
            )
        }
        let seedValue = try requiredValue(uuidSeedKey, arguments: arguments)
        guard let uuidSeed = UInt64(seedValue) else {
            throw VisualUITestConfigurationError.invalidValue(
                key: uuidSeedKey,
                value: seedValue
            )
        }
        let usesProductionFeatureViews: Bool
        if arguments.contains(productionFeatureViewsKey) {
            let value = try requiredValue(
                productionFeatureViewsKey,
                arguments: arguments
            )
            guard value.caseInsensitiveCompare("YES") == .orderedSame else {
                throw VisualUITestConfigurationError.invalidValue(
                    key: productionFeatureViewsKey,
                    value: value
                )
            }
            usesProductionFeatureViews = true
        } else {
            usesProductionFeatureViews = false
        }

        guard let route = VisualFixtureRouteCatalog.route(page: page, state: state) else {
            throw VisualUITestConfigurationError.unregisteredFixture(fixtureID)
        }
        let expectedFixtureID = route.fixtureID
        guard fixtureID == expectedFixtureID else {
            throw VisualUITestConfigurationError.fixtureMismatch(
                expected: expectedFixtureID,
                actual: fixtureID
            )
        }
        guard route.supports(inspector: inspector) else {
            throw VisualUITestConfigurationError.unsupportedInspector(
                fixtureID: fixtureID,
                inspector: inspector.rawValue
            )
        }
        if usesProductionFeatureViews,
            !supportsProductionFeatureView(page: page, state: state)
        {
            throw VisualUITestConfigurationError.unsupportedProductionFeatureView(
                fixtureID
            )
        }

        return VisualUITestConfiguration(
            fixtureID: fixtureID,
            page: page,
            state: state,
            appearance: appearance,
            localeIdentifier: localeIdentifier,
            windowSize: windowSize,
            inspector: inspector,
            fixedDate: fixedDate,
            uuidSeed: uuidSeed,
            usesProductionFeatureViews: usesProductionFeatureViews
        )
    }

    private static func requiredValue(
        _ key: String,
        arguments: [String]
    ) throws -> String {
        guard let value = value(for: key, in: arguments), !value.isEmpty else {
            throw VisualUITestConfigurationError.missingValue(key: key)
        }
        return value
    }

    private static func enumValue<Value: RawRepresentable>(
        _ type: Value.Type,
        key: String,
        arguments: [String]
    ) throws -> Value where Value.RawValue == String {
        let rawValue = try requiredValue(key, arguments: arguments)
        guard let value = Value(rawValue: rawValue) else {
            throw VisualUITestConfigurationError.invalidValue(
                key: key,
                value: rawValue
            )
        }
        return value
    }

    private static func value(for key: String, in arguments: [String]) -> String? {
        guard let keyIndex = arguments.lastIndex(of: key) else { return nil }
        let valueIndex = arguments.index(after: keyIndex)
        guard valueIndex < arguments.endIndex else { return nil }
        let value = arguments[valueIndex]
        guard !value.hasPrefix("-") else { return nil }
        return value
    }

    private static func supportsProductionFeatureView(
        page: Page,
        state: State
    ) -> Bool {
        switch (page, state) {
        case (.proxies, .offline), (.rules, .empty), (.providers, .empty):
            true
        default:
            false
        }
    }
}

nonisolated enum VisualUITestConfigurationError: Error, Equatable, Sendable {
    case missingValue(key: String)
    case invalidValue(key: String, value: String)
    case fixtureMismatch(expected: String, actual: String)
    case unregisteredFixture(String)
    case unsupportedInspector(fixtureID: String, inspector: String)
    case unsupportedProductionFeatureView(String)
    case conflictingStartupSmoke
}

extension VisualUITestConfigurationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .missingValue(key):
            "Visual fixture mode requires a value for \(key)."
        case let .invalidValue(key, value):
            "Visual fixture mode received an invalid value for \(key): \(value)."
        case let .fixtureMismatch(expected, actual):
            "Visual fixture ID \(actual) does not match the requested page and state; expected \(expected)."
        case let .unregisteredFixture(fixtureID):
            "Visual fixture ID \(fixtureID) is not registered by the page contract."
        case let .unsupportedInspector(fixtureID, inspector):
            "Visual fixture ID \(fixtureID) does not support inspector value \(inspector)."
        case let .unsupportedProductionFeatureView(fixtureID):
            "Visual fixture ID \(fixtureID) is not registered for production feature-view verification."
        case .conflictingStartupSmoke:
            "Visual fixture mode cannot be combined with startup-smoke mode."
        }
    }
}

private struct VisualUITestConfigurationKey: EnvironmentKey {
    static let defaultValue: VisualUITestConfiguration? = nil
}

extension EnvironmentValues {
    var visualUITestConfiguration: VisualUITestConfiguration? {
        get { self[VisualUITestConfigurationKey.self] }
        set { self[VisualUITestConfigurationKey.self] = newValue }
    }
}

struct VisualReadyMarker: View {
    @Environment(\.visualUITestConfiguration) private var configuration

    let fixtureID: String

    @ViewBuilder
    var body: some View {
        // A marker is embedded by the concrete presentation branch that owns
        // the state. Checking the active launch contract here prevents a
        // visible empty/offline branch from certifying a differently requested
        // fixture.
        if configuration?.fixtureID == fixtureID {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Visual fixture ready: \(fixtureID)")
                .accessibilityIdentifier("visual.ready.\(fixtureID)")
                .allowsHitTesting(false)
        }
    }
}

/// Distinguishes real feature-view evidence from the synthetic fixture host.
struct VisualProductionFeatureViewMarker: View {
    let fixtureID: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Production feature view ready: \(fixtureID)")
            .accessibilityIdentifier(
                "visual.production-feature-view.ready.\(fixtureID)"
            )
            .allowsHitTesting(false)
    }
}

/// A dedicated Debug-only accessibility node for page navigation assertions.
///
/// Applying an identifier to a large SwiftUI container can propagate that
/// identifier through its accessibility subtree on macOS, overwriting the
/// identifiers of real controls. Keeping the screen marker on its own node
/// preserves both the page-level test contract and every child control ID.
struct VisualScreenMarker: View {
    let page: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Vela screen: \(page)")
            .accessibilityIdentifier("screen.\(page)")
            .allowsHitTesting(false)
    }
}

struct VisualSurfaceMarker: View {
    let identifier: String
    let label: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
            .allowsHitTesting(false)
    }
}
#endif
