#if DEBUG
import Foundation

/// Typed capture routing for every registered visual page/state fixture.
///
/// This catalog deliberately describes presentation routes only. It does not
/// mutate a production store or claim that a page has rendered the requested
/// state. A concrete page must still publish `VisualReadyMarker` from the
/// matching presentation branch before a capture can count as evidence.
nonisolated struct VisualFixtureRouteDescriptor: Equatable, Hashable, Sendable {
    enum CaptureBoundary: String, Equatable, Hashable, Sendable {
        case mainWindow
        case menu
        case sheet
    }

    enum InspectorPolicy: Equatable, Hashable, Sendable {
        case notApplicable
        case toggleable

        var captureValues: [VisualUITestConfiguration.Inspector] {
            switch self {
            case .notApplicable:
                [.notApplicable]
            case .toggleable:
                [.closed, .open]
            }
        }
    }

    let page: VisualUITestConfiguration.Page
    let state: VisualUITestConfiguration.State
    let captureBoundary: CaptureBoundary
    let inspectorPolicy: InspectorPolicy

    var fixtureID: String {
        switch (page, state) {
        case (.overview, .loaded):
            "overview.loadedHealthy"
        case (.overview, .offline):
            "overview.offlineNoConfiguration"
        default:
            "\(page.rawValue).\(state.rawValue)"
        }
    }

    var captureInspectors: [VisualUITestConfiguration.Inspector] {
        inspectorPolicy.captureValues
    }

    var isMainWindow: Bool {
        captureBoundary == .mainWindow
    }

    var captureWindowSizes: [VisualUITestConfiguration.WindowSize] {
        guard isMainWindow else {
            return [.defaultSize]
        }
        if page == .overview {
            return [.overviewCompact, .overviewMedium, .overviewBaseline, .large]
        }
        return [.minimum, .defaultSize, .large]
    }

    func supports(inspector: VisualUITestConfiguration.Inspector) -> Bool {
        captureInspectors.contains(inspector)
    }
}

nonisolated enum VisualFixtureRouteCatalog {
    typealias Page = VisualUITestConfiguration.Page
    typealias State = VisualUITestConfiguration.State

    /// Stable fixture ordering mirrors `VisualRecovery/Fixtures/fixture-registry.json`.
    /// The determinism test rejects any drift between this Debug-only typed
    /// catalog, the JSON registry, and the page contracts.
    static let all: [VisualFixtureRouteDescriptor] = Page.allCases.flatMap { page in
        states(for: page).map { state in
            VisualFixtureRouteDescriptor(
                page: page,
                state: state,
                captureBoundary: captureBoundary(for: page),
                inspectorPolicy: inspectorPolicy(for: page)
            )
        }
    }

    static func route(
        page: Page,
        state: State
    ) -> VisualFixtureRouteDescriptor? {
        all.first { $0.page == page && $0.state == state }
    }

    static func states(for page: Page) -> [State] {
        switch page {
        case .overview:
            [.loading, .loaded, .empty, .refreshing, .pendingMutation,
             .partialFailure, .failure, .offline, .stale,
             .permissionRequired, .transitioning]
        case .proxies, .connections:
            [.loading, .loaded, .empty, .refreshing, .pendingMutation,
             .partialFailure, .failure, .offline, .stale]
        case .rules:
            [.loading, .loaded, .empty, .refreshing, .pendingMutation,
             .partialFailure, .failure, .stale, .transitioning]
        case .providers:
            [.loading, .loaded, .empty, .refreshing, .pendingMutation,
             .partialFailure, .failure]
        case .workbench:
            [.loading, .loaded, .empty, .pendingMutation, .partialFailure,
             .failure, .stale, .transitioning, .rollbackFailed]
        case .diagnostics:
            [.loading, .loaded, .refreshing, .partialFailure, .failure,
             .pendingMutation, .stale, .permissionRequired, .rollbackFailed]
        case .logs:
            [.loading, .loaded, .empty, .refreshing, .pendingMutation,
             .partialFailure, .failure, .offline, .stale, .permissionRequired,
             .transitioning, .rollbackFailed]
        case .settings:
            [.loaded, .pendingMutation, .partialFailure, .failure,
             .permissionRequired]
        case .tunFlow:
            [.loading, .pendingMutation, .failure, .permissionRequired,
             .transitioning, .rollbackFailed]
        case .menuBar:
            [.loaded, .pendingMutation, .partialFailure, .failure, .stale]
        case .updateCoreRecovery:
            [.loaded, .pendingMutation, .partialFailure, .failure,
             .permissionRequired, .transitioning, .rollbackFailed]
        case .helpSupport:
            [.loading, .loaded, .empty, .failure, .offline]
        }
    }

    private static func captureBoundary(
        for page: Page
    ) -> VisualFixtureRouteDescriptor.CaptureBoundary {
        switch page {
        case .tunFlow:
            .sheet
        case .menuBar:
            .menu
        case .overview, .proxies, .connections, .rules, .providers, .settings,
             .workbench, .diagnostics, .logs, .updateCoreRecovery,
             .helpSupport:
            .mainWindow
        }
    }

    private static func inspectorPolicy(
        for page: Page
    ) -> VisualFixtureRouteDescriptor.InspectorPolicy {
        switch page {
        case .proxies, .connections, .rules, .providers, .workbench, .diagnostics,
             .logs:
            .toggleable
        case .overview, .settings,
             .tunFlow, .menuBar, .updateCoreRecovery, .helpSupport:
            .notApplicable
        }
    }
}
#endif
