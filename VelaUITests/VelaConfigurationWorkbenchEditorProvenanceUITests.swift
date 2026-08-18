import XCTest

final class VelaConfigurationWorkbenchEditorProvenanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
    }

    @MainActor
    func testNoProfileGatesApplyAndPreservesWorkspace() throws {
        let session = try launch(state: "empty", inspector: "closed")
        defer { session.terminate() }

        let emptyState = element("configuration.fixture.empty", in: session.app)
        XCTAssertTrue(emptyState.waitForExistence(timeout: 4))
        XCTAssertTrue(emptyState.label.contains("No Configuration Files"))
        XCTAssertTrue(element("configuration.fixture.add", in: session.app).isEnabled)
        XCTAssertFalse(element("configuration.fixture.profileMenu", in: session.app).exists)
        XCTAssertFalse(element("configuration.fixture.validation", in: session.app).exists)
        XCTAssertFalse(element("configuration.fixture.apply", in: session.app).exists)
        session.app.typeKey(.return, modifierFlags: [])
    }

    @MainActor
    func testExistingCatalogWithoutSelectionShowsOnlyChooseConfiguration() throws {
        let session = try launch(
            state: "empty",
            scenario: "noSelection",
            inspector: "closed"
        )
        defer { session.terminate() }

        let choose = element("configuration.fixture.choose", in: session.app)
        XCTAssertTrue(choose.waitForExistence(timeout: 4))
        XCTAssertTrue(choose.isEnabled)
        XCTAssertFalse(element("configuration.fixture.add", in: session.app).exists)
        XCTAssertFalse(element("configuration.fixture.validation", in: session.app).exists)
    }

    @MainActor
    func testLoadedWorkspaceExposesLayersModesAndProvenanceInspector() throws {
        let session = try launch(state: "loaded", scenario: "ready", inspector: "open")
        defer { session.terminate() }

        XCTAssertTrue(element("configuration.fixture.layers", in: session.app).waitForExistence(timeout: 4))
        for mode in ["YAML Editor", "Override Editor", "Structure"] {
            XCTAssertTrue(session.app.descendants(matching: .any)[mode].firstMatch.exists)
        }
        XCTAssertTrue(element("configuration.fixture.editor", in: session.app).exists)
        XCTAssertTrue(element("configuration.inspector", in: session.app).exists)
        XCTAssertTrue(
            element("configuration.fixture.profileMenu", in: session.app).label.contains("Daily Driver")
        )
        XCTAssertTrue(element("configuration.fixture.validation", in: session.app).label.contains("Validated"))
        XCTAssertTrue(element("configuration.fixture.apply", in: session.app).isEnabled)
    }

    @MainActor
    func testMinimumWindowCollapsesInspectorWithoutHorizontalOverflow() throws {
        let session = try launch(
            state: "loaded",
            appearance: "dark",
            locale: "zh-Hans",
            window: "1040x680",
            scenario: "editor",
            inspector: "closed"
        )
        defer { session.terminate() }

        let editor = element("configuration.fixture.editor", in: session.app)
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        let apply = element("configuration.fixture.apply", in: session.app)
        XCTAssertTrue(apply.waitForExistence(timeout: 2))
        XCTAssertLessThanOrEqual(apply.frame.maxX, session.window.frame.maxX + 1)
        XCTAssertFalse(element("configuration.inspector", in: session.app).exists)
    }

    @MainActor
    func testStaleFailureAndRollbackKeepCommittedEvidenceVisible() throws {
        for state in ["stale", "failure", "rollbackFailed"] {
            try XCTContext.runActivity(named: state) { _ in
                let session = try launch(state: state, scenario: "automatic", inspector: "open")
                defer { session.terminate() }
                XCTAssertTrue(element("configuration.fixture.validation", in: session.app).waitForExistence(timeout: 4))
                let apply = element("configuration.fixture.apply", in: session.app)
                if state == "stale" {
                    XCTAssertTrue(apply.waitForExistence(timeout: 2))
                    XCTAssertFalse(apply.isEnabled)
                } else {
                    XCTAssertFalse(apply.exists)
                }
            }
        }
    }

    @MainActor
    func testSelectedToolbarStateMatrix() throws {
        for scenario in ["clean", "draft", "validating", "invalid"] {
            try XCTContext.runActivity(named: scenario) { _ in
                let session = try launch(
                    state: "loaded",
                    scenario: scenario,
                    inspector: "closed"
                )
                defer { session.terminate() }
                XCTAssertTrue(element("configuration.fixture.profileMenu", in: session.app).waitForExistence(timeout: 4))
                XCTAssertTrue(element("configuration.fixture.validation", in: session.app).exists)
                if scenario == "clean" {
                    XCTAssertFalse(element("configuration.fixture.apply", in: session.app).exists)
                } else {
                    XCTAssertTrue(element("configuration.fixture.apply", in: session.app).exists)
                }
            }
        }
    }

    @MainActor
    func testIncreaseContrastAndReduceMotionMarkers() throws {
        let session = try launch(
            state: "loaded",
            scenario: "ready",
            inspector: "open",
            additionalArguments: [
                "-VelaWorkbenchIncreaseContrast", "YES",
                "-VelaWorkbenchReduceMotion", "YES",
            ]
        )
        defer { session.terminate() }

        XCTAssertTrue(element("configuration.accessibility.increasedContrast", in: session.app).waitForExistence(timeout: 4))
        XCTAssertTrue(element("configuration.accessibility.reduceMotion", in: session.app).exists)
    }

    @MainActor
    func testRequiredVisualMatrix() throws {
        let scenarios = [
            Scenario("loaded", "dark", "zh-Hans", "1040x680", "editor", "open"),
            Scenario("loaded", "dark", "en", "1040x680", "editor", "closed"),
            Scenario("loaded", "dark", "zh-Hans", "1280x820", "editor", "open"),
            Scenario("loaded", "light", "en", "1280x820", "rules", "open"),
            Scenario("loaded", "dark", "en", "1280x820", "diff", "open"),
            Scenario("loaded", "dark", "en", "1280x820", "effective", "open"),
            Scenario("loaded", "dark", "en", "1600x1000", "editor", "open"),
            Scenario("loaded", "dark", "en", "1600x1000", "effective", "closed"),
            Scenario("loading", "dark", "en", "1280x820", "automatic", "open"),
            Scenario("empty", "dark", "en", "1280x820", "automatic", "open"),
            Scenario("empty", "dark", "zh-Hans", "1040x680", "noSelection", "closed"),
            Scenario("empty", "light", "en", "1280x820", "emptyCatalog", "closed"),
            Scenario("loaded", "dark", "en", "1280x820", "clean", "open"),
            Scenario("loaded", "dark", "en", "1280x820", "draft", "open"),
            Scenario("loaded", "dark", "en", "1280x820", "validating", "open"),
            Scenario("loaded", "dark", "en", "1280x820", "compiling", "open"),
            Scenario("loaded", "dark", "en", "1280x820", "invalid", "open"),
            Scenario("loaded", "dark", "en", "1280x820", "ready", "open"),
            Scenario("partialFailure", "dark", "en", "1280x820", "automatic", "open"),
            Scenario("failure", "dark", "en", "1280x820", "automatic", "open"),
            Scenario("stale", "dark", "en", "1280x820", "automatic", "open"),
            Scenario("pendingMutation", "dark", "en", "1280x820", "automatic", "open"),
            Scenario("transitioning", "dark", "en", "1280x820", "rollingBack", "open"),
            Scenario("rollbackFailed", "dark", "en", "1280x820", "automatic", "open"),
        ]

        for scenario in scenarios {
            try XCTContext.runActivity(named: scenario.identifier) { _ in
                let session = try launch(
                    state: scenario.state,
                    appearance: scenario.appearance,
                    locale: scenario.locale,
                    window: scenario.window,
                    scenario: scenario.workbenchScenario,
                    inspector: scenario.inspector
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
        scenario: String = "automatic",
        inspector: String,
        additionalArguments: [String] = []
    ) throws -> WorkbenchSession {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "workbench",
            state: state,
            appearance: appearance,
            locale: locale,
            window: window,
            inspector: inspector
        ) + ["-VelaWorkbenchScenario", scenario] + additionalArguments
        app.launch()
        app.activate()

        XCTAssertTrue(
            element("visual.ready.workbench.\(state)", in: app).waitForExistence(timeout: 10),
            "Fixture did not become ready: \(state)-\(scenario)-\(window)-\(inspector)"
        )
        let firstWindow = app.windows.firstMatch
        XCTAssertTrue(firstWindow.waitForExistence(timeout: 4))
        let windowElement = app.windows.allElementsBoundByIndex.first { candidate in
            candidate.frame.width > 0
                && candidate.frame.height > 0
                && candidate.descendants(matching: .any)["visual.ready.workbench.\(state)"].firstMatch.exists
        } ?? firstWindow
        return WorkbenchSession(app: app, window: windowElement, preferencesDomain: preferencesDomain)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}

private struct Scenario {
    let state: String
    let appearance: String
    let locale: String
    let window: String
    let workbenchScenario: String
    let inspector: String

    init(_ state: String, _ appearance: String, _ locale: String, _ window: String, _ workbenchScenario: String, _ inspector: String) {
        self.state = state
        self.appearance = appearance
        self.locale = locale
        self.window = window
        self.workbenchScenario = workbenchScenario
        self.inspector = inspector
    }

    var identifier: String {
        "workbench__\(state)__\(workbenchScenario)__\(appearance)__\(locale)__\(window)__\(inspector)"
    }
}

@MainActor
private struct WorkbenchSession {
    let app: XCUIApplication
    let window: XCUIElement
    let preferencesDomain: String

    func terminate() {
        VelaUITestIsolation.terminate(app, clearingPreferenceDomain: preferencesDomain)
    }
}
