import XCTest

final class VelaProvidersTableInspectorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
    }

    @MainActor
    func testLoadedSelectionAndInspectorUseSameOpaqueProvider() throws {
        let session = try launch(state: "loaded", inspector: "open", scenario: "proxySelected")
        defer { session.terminate() }

        XCTAssertTrue(
            session.app.descendants(matching: .any)["providers.inspector.loaded"]
                .firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(session.app.staticTexts["Edge Nodes"].exists)
        XCTAssertFalse(session.app.staticTexts["边缘节点"].exists)
    }

    @MainActor
    func testNoSnapshotStatesClearSelectionAndConcreteInspector() throws {
        for state in ["loading", "empty", "failure"] {
            let session = try launch(state: state, inspector: "open", scenario: "automatic")
            defer { session.terminate() }
            XCTAssertFalse(
                session.app.descendants(matching: .any)["providers.inspector.loaded"]
                    .firstMatch.exists,
                "Concrete provider Inspector leaked into \(state)"
            )
            XCTAssertTrue(
                session.app.descendants(matching: .any)["providers.inspector.placeholder"]
                    .firstMatch.waitForExistence(timeout: 3)
            )
        }
    }

    @MainActor
    func testUpdateAllAvailabilityAndPartialFailureEvidence() throws {
        do {
            let session = try launch(state: "empty", inspector: "open", scenario: "automatic")
            defer { session.terminate() }
            let updateAll = session.app.buttons["Update All"]
            XCTAssertFalse(updateAll.waitForExistence(timeout: 1))
        }
        do {
            let session = try launch(
                state: "partialFailure",
                inspector: "open",
                scenario: "partialFailureSelected"
            )
            defer { session.terminate() }
            XCTAssertTrue(session.app.staticTexts["Media Rules"].waitForExistence(timeout: 4))
            XCTAssertTrue(session.app.staticTexts["Last Update Failed"].exists)
        }
    }

    @MainActor
    func testAccessibilityEnvironmentOverridesAreApplied() throws {
        let session = try launch(
            state: "loaded",
            inspector: "open",
            scenario: "proxySelected",
            additionalArguments: [
                "-VelaProvidersReduceMotion", "true",
                "-VelaProvidersIncreaseContrast", "true",
            ]
        )
        defer { session.terminate() }

        XCTAssertTrue(
            session.app.descendants(matching: .any)["providers.accessibility.reduceMotion"]
                .firstMatch.waitForExistence(timeout: 4)
        )
        XCTAssertTrue(
            session.app.descendants(matching: .any)["providers.accessibility.increasedContrast"]
                .firstMatch.exists
        )
    }

    @MainActor
    func testCompactTableHasNoHorizontalOverflowAndKeepsInspectorUsable() throws {
        let session = try launch(
            state: "loaded",
            appearance: "dark",
            locale: "zh-Hans",
            window: "1040x680",
            inspector: "open",
            scenario: "proxySelected"
        )
        defer { session.terminate() }

        let surface = session.app.descendants(matching: .any)["providers.tableInspector"]
            .firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(surface.frame.maxX, session.window.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(surface.frame.minX, session.window.frame.minX - 1)
        XCTAssertTrue(session.app.staticTexts["Edge Nodes"].exists)
    }

    @MainActor
    func testRequiredProvidersVisualMatrix() throws {
        let scenarios = [
            ProvidersScenario("loaded", "dark", "zh-Hans", "1040x680", "open", "proxySelected"),
            ProvidersScenario("loaded", "dark", "zh-Hans", "1040x680", "closed", "proxySelected"),
            ProvidersScenario("loaded", "dark", "zh-Hans", "1280x820", "open", "proxySelected"),
            ProvidersScenario("loaded", "light", "en", "1280x820", "open", "proxySelected"),
            ProvidersScenario("loaded", "dark", "en", "1600x1000", "open", "proxySelected"),
            ProvidersScenario("loaded", "dark", "en", "1600x1000", "closed", "proxySelected"),
            ProvidersScenario("loading", "light", "zh-Hans", "1280x820", "open", "automatic"),
            ProvidersScenario("empty", "dark", "en", "1280x820", "open", "automatic"),
            ProvidersScenario("refreshing", "dark", "en", "1280x820", "open", "refreshingSelected"),
            ProvidersScenario("refreshing", "dark", "en", "1280x820", "open", "refreshingAll"),
            ProvidersScenario("partialFailure", "dark", "en", "1280x820", "open", "partialFailureSelected"),
            ProvidersScenario("failure", "dark", "en", "1280x820", "open", "automatic"),
            ProvidersScenario("pendingMutation", "dark", "en", "1280x820", "open", "automatic"),
            ProvidersScenario("partialFailure", "dark", "en", "1280x820", "open", "updateAllPartialResult"),
            ProvidersScenario("loaded", "dark", "en", "1280x820", "open", "proxySelected"),
            ProvidersScenario("loaded", "dark", "en", "1280x820", "open", "ruleSelected"),
        ]

        for scenario in scenarios {
            try XCTContext.runActivity(named: scenario.identifier) { _ in
                let session = try launch(
                    state: scenario.state,
                    appearance: scenario.appearance,
                    locale: scenario.locale,
                    window: scenario.window,
                    inspector: scenario.inspector,
                    scenario: scenario.providerScenario
                )
                defer { session.terminate() }
                let attachment = XCTAttachment(screenshot: session.window.screenshot())
                attachment.name = scenario.identifier + ".png"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    private func launch(
        state: String,
        appearance: String = "dark",
        locale: String = "en",
        window: String = "1280x820",
        inspector: String,
        scenario: String,
        additionalArguments: [String] = []
    ) throws -> ProvidersSession {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        _ = addUIInterruptionMonitor(
            withDescription: "Visual host Documents access"
        ) { alert in
            for label in ["不允许", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label].firstMatch
                if button.exists {
                    button.click()
                    return true
                }
            }
            return false
        }
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "providers",
            state: state,
            appearance: appearance,
            locale: locale,
            window: window,
            inspector: inspector
        ) + ["-VelaProvidersScenario", scenario] + additionalArguments
        app.launch()
        app.activate()

        let ready = app.descendants(matching: .any)["visual.ready.providers.\(state)"]
            .firstMatch
        XCTAssertTrue(
            ready.waitForExistence(timeout: 10),
            "Fixture did not become ready: \(state)-\(scenario)-\(window)"
        )
        let interruptionTarget = app.windows.firstMatch
        XCTAssertTrue(interruptionTarget.waitForExistence(timeout: 4))
        // Trigger XCTest's system-interruption monitor only after the fixture
        // is ready, when a host Files & Folders prompt would already exist.
        interruptionTarget.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)
        ).click()
        // Dismissing a system sheet invalidates the prior XCUI window proxy.
        // Re-query before measuring or taking screenshots.
        let firstWindow = app.windows.firstMatch
        XCTAssertTrue(firstWindow.waitForExistence(timeout: 4))
        let windowElement = app.windows.allElementsBoundByIndex.first { candidate in
            candidate.frame.width > 0
                && candidate.frame.height > 0
                && candidate.descendants(matching: .any)["visual.ready.providers.\(state)"]
                    .firstMatch.exists
        } ?? firstWindow
        return ProvidersSession(
            app: app,
            window: windowElement,
            preferencesDomain: preferencesDomain
        )
    }
}

private struct ProvidersScenario {
    let state: String
    let appearance: String
    let locale: String
    let window: String
    let inspector: String
    let providerScenario: String

    init(
        _ state: String,
        _ appearance: String,
        _ locale: String,
        _ window: String,
        _ inspector: String,
        _ providerScenario: String
    ) {
        self.state = state
        self.appearance = appearance
        self.locale = locale
        self.window = window
        self.inspector = inspector
        self.providerScenario = providerScenario
    }

    var identifier: String {
        "providers__\(state)__\(providerScenario)__\(appearance)__\(locale)__\(window)__\(inspector)"
    }
}

@MainActor
private struct ProvidersSession {
    let app: XCUIApplication
    let window: XCUIElement
    let preferencesDomain: String

    func terminate() {
        VelaUITestIsolation.terminate(
            app,
            clearingPreferenceDomain: preferencesDomain
        )
    }
}
