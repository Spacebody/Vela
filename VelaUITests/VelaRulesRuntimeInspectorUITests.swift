import XCTest

final class VelaRulesRuntimeInspectorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
    }

    @MainActor
    func testLoadedSelectionInspectorAndCloseReopenPersistence() throws {
        let session = try launch(state: "loaded", inspector: "open")
        defer { session.terminate() }

        let inspector = session.app.descendants(matching: .any)[
            "rules.inspector.selected"
        ].firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertTrue(session.app.staticTexts["#20 DOMAIN-SUFFIX"].exists)
        XCTAssertTrue(
            session.app.descendants(matching: .any)["rules.row.20"]
                .firstMatch.waitForExistence(timeout: 2)
        )
        assertNoHorizontalTableOverflow(in: session)

        let toggle = session.app.descendants(matching: .any)[
            "rules.inspector.toggle"
        ].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        toggle.click()
        XCTAssertFalse(inspector.waitForExistence(timeout: 1))
        toggle.click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 3))
        XCTAssertTrue(session.app.staticTexts["#20 DOMAIN-SUFFIX"].exists)
    }

    @MainActor
    func testRuleGroupFilterCanReturnToTheCompleteRuleList() throws {
        let session = try launch(state: "loaded", inspector: "closed")
        defer { session.terminate() }

        let geoIPGroup = session.app.buttons["rules.group.2"]
        XCTAssertTrue(geoIPGroup.waitForExistence(timeout: 4))
        geoIPGroup.click()

        XCTAssertTrue(
            session.app.descendants(matching: .any)["rules.row.88"]
                .firstMatch.waitForExistence(timeout: 3)
        )
        XCTAssertFalse(
            session.app.descendants(matching: .any)["rules.row.20"]
                .firstMatch.exists
        )

        let allRules = session.app.buttons["rules.group.all"]
        XCTAssertTrue(allRules.waitForExistence(timeout: 3))
        allRules.click()

        XCTAssertTrue(
            session.app.descendants(matching: .any)["rules.row.20"]
                .firstMatch.waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            session.app.descendants(matching: .any)["rules.row.88"]
                .firstMatch.exists
        )
    }

    @MainActor
    func testNoSnapshotStatesClearRowsSelectionAndInspector() throws {
        for state in ["loading", "empty", "failure"] {
            let session = try launch(state: state, inspector: "open")
            defer { session.terminate() }
            XCTAssertFalse(
                session.app.descendants(matching: .any)["rules.row.20"]
                    .firstMatch.exists,
                "Unexpected retained row in \(state)"
            )
            XCTAssertFalse(
                session.app.descendants(matching: .any)[
                    "rules.inspector.selected"
                ].firstMatch.exists,
                "Unexpected selected Inspector in \(state)"
            )
        }
    }

    @MainActor
    func testEmptyInspectorContentIsVerticallyCentered() throws {
        let session = try launch(state: "failure", inspector: "open")
        defer { session.terminate() }

        let pane = session.app.descendants(matching: .any)[
            "rules.inspector.pane"
        ].firstMatch
        let center = session.app.descendants(matching: .any)[
            "rules.inspector.empty.center"
        ].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 4))
        XCTAssertTrue(center.waitForExistence(timeout: 2))
        let recovery = session.app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "rules.empty.recovery."
                )
            )
            .firstMatch
        XCTAssertTrue(recovery.waitForExistence(timeout: 2))
        XCTAssertEqual(center.frame.midY, recovery.frame.midY, accuracy: 2)
    }

    @MainActor
    func testRecoveryReasonsUseTruthfulCanonicalActions() throws {
        let failures: [(reason: String, reloadEnabled: Bool)] = [
            ("mihomoStopped", false),
            ("controllerDisconnected", true),
            ("ruleFetchFailed", true),
        ]

        for failure in failures {
            let session = try launch(
                state: "failure",
                inspector: "closed",
                additionalArguments: [
                    "-VelaRulesRecoveryReason", failure.reason,
                ]
            )
            XCTAssertTrue(session.app.descendants(matching: .any)[
                "rules.empty.recovery.\(failure.reason)"
            ].firstMatch
                .waitForExistence(timeout: 4))
            let reload = session.app.buttons["rules.recovery.reload"]
            let diagnostics = session.app.buttons["rules.recovery.openDiagnostics"]
            XCTAssertTrue(reload.waitForExistence(timeout: 2))
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 2))
            XCTAssertEqual(reload.label, "Reload Rules")
            XCTAssertEqual(diagnostics.label, "Open Diagnostics")
            XCTAssertEqual(reload.isEnabled, failure.reloadEnabled)
            XCTAssertGreaterThanOrEqual(reload.frame.width, 120)
            XCTAssertGreaterThanOrEqual(reload.frame.height, 30)
            XCTAssertLessThanOrEqual(reload.frame.height, 32)
            XCTAssertEqual(reload.frame.midY, diagnostics.frame.midY, accuracy: 2)
            XCTAssertEqual(diagnostics.frame.minX - reload.frame.maxX, 12, accuracy: 2)
            XCTAssertFalse(session.app.buttons["rules.refresh"].exists)
            session.terminate()
        }

        let empty = try launch(
            state: "empty",
            inspector: "closed",
            additionalArguments: [
                "-VelaRulesRecoveryReason", "emptyConfiguration",
            ]
        )
        defer { empty.terminate() }
        XCTAssertTrue(empty.app.descendants(matching: .any)[
            "rules.empty.recovery.emptyConfiguration"
        ].firstMatch
            .waitForExistence(timeout: 4))
        XCTAssertTrue(empty.app.buttons["rules.recovery.openWorkbench"]
            .waitForExistence(timeout: 2))
        XCTAssertTrue(empty.app.buttons["rules.recovery.openWorkbench"].isEnabled)
        XCTAssertFalse(empty.app.buttons["rules.recovery.reload"].exists)
        XCTAssertFalse(empty.app.buttons["rules.refresh"].exists)
    }

    @MainActor
    func testReloadDefaultActionIsAccessibleAndDeduplicated() throws {
        let session = try launch(
            state: "failure",
            inspector: "closed",
            additionalArguments: [
                "-VelaRulesRecoveryReason", "ruleFetchFailed",
            ]
        )
        defer { session.terminate() }

        let reload = session.app.buttons["rules.recovery.reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 4))
        XCTAssertEqual(reload.label, "Reload Rules")
        XCTAssertTrue(reload.isEnabled)
        XCTAssertFalse(session.app.buttons["rules.refresh"].exists)

        session.window.typeKey(.return, modifierFlags: [])
        let pending = session.app.buttons["rules.recovery.reload"]
        XCTAssertTrue(pending.waitForExistence(timeout: 2))
        XCTAssertEqual(pending.label, "Reloading…")
        XCTAssertFalse(pending.isEnabled)
        XCTAssertEqual(pending.value as? String, "1")

        session.window.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(
            session.app.buttons["rules.recovery.reload"].value as? String,
            "1"
        )
    }

    @MainActor
    func testSearchEmptyStateClearsSelectionAndCanRecover() throws {
        let session = try launch(state: "loaded", inspector: "open")
        defer { session.terminate() }

        let search = session.app.descendants(matching: .any)["rules.search"]
            .firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.click()
        search.typeText("definitely-no-runtime-rule")
        XCTAssertTrue(
            session.app.descendants(matching: .any)["rules.empty.filtered"]
                .firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            session.app.descendants(matching: .any)["rules.inspector.selected"]
                .firstMatch.exists
        )
    }

    @MainActor
    func testPendingMutationAndConfigurationTransitionAreExact() throws {
        do {
            let session = try launch(state: "pendingMutation", inspector: "open")
            defer { session.terminate() }
            XCTAssertTrue(
                session.app.descendants(matching: .any)[
                    "rules.pending.21.applying"
                ].firstMatch.waitForExistence(timeout: 4)
            )
            XCTAssertTrue(session.app.staticTexts["#21 PROCESS-NAME"].exists)
            XCTAssertTrue(
                session.app.descendants(matching: .any)[
                    "rules.state.temporaryMutation"
                ].firstMatch.waitForExistence(timeout: 2)
            )
            XCTAssertFalse(
                session.app.descendants(matching: .any)[
                    "rules.inspector.toggleTemporary"
                ].firstMatch.isEnabled
            )
        }

        do {
            let session = try launch(state: "transitioning", inspector: "open")
            defer { session.terminate() }
            XCTAssertTrue(
                session.app.descendants(matching: .any)[
                    "rules.state.configurationApplying"
                ].firstMatch.waitForExistence(timeout: 4)
            )
            XCTAssertTrue(
                session.app.descendants(matching: .any)["rules.row.20"]
                    .firstMatch.exists
            )
        }
    }

    @MainActor
    func testCompactGeometryRowDensityAndKeyboardSelection() throws {
        let session = try launch(
            state: "loaded",
            appearance: "dark",
            locale: "zh-Hans",
            window: "1040x680",
            inspector: "open"
        )
        defer { session.terminate() }

        let inspector = session.app.descendants(matching: .any)[
            "rules.inspector.scroll"
        ].firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(inspector.frame.width, 290)
        XCTAssertLessThanOrEqual(inspector.frame.width, 390)
        XCTAssertTrue(
            session.app.descendants(matching: .any)["rules.columns.compact"]
                .firstMatch.waitForExistence(timeout: 2)
        )
        assertNoHorizontalTableOverflow(in: session)

        let first = session.app.descendants(matching: .any)["rules.row.20"]
            .firstMatch
        let second = session.app.descendants(matching: .any)["rules.row.21"]
            .firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 2))
        XCTAssertTrue(second.waitForExistence(timeout: 2))
        let rowHeight = second.frame.midY - first.frame.midY
        XCTAssertGreaterThanOrEqual(rowHeight, 30)
        XCTAssertLessThanOrEqual(rowHeight, 34)

        first.click()
        first.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(
            inspector.staticTexts["Mail"].waitForExistence(timeout: 3),
            "Keyboard navigation should update the inspector to the next rule."
        )

        let evidence = XCTAttachment(
            string: [
                "window=1040x680",
                "inspectorWidth=\(inspector.frame.width)",
                "tableRowHeight=\(rowHeight)",
                "columns=Index,Rule,Policy; Matches remains available in Inspector",
            ].joined(separator: "\n")
        )
        evidence.name = "rules-1040-geometry.txt"
        evidence.lifetime = .keepAlways
        add(evidence)

        let screenshot = XCTAttachment(screenshot: session.window.screenshot())
        screenshot.name = "rules-1040-layout.png"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testAccessibilityOverridesAndInspectorSemantics() throws {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "rules",
            state: "loaded",
            appearance: "dark",
            locale: "en",
            window: "1280x820",
            inspector: "open"
        ) + [
            "-VelaRulesIncreaseContrast", "YES",
            "-VelaRulesReduceMotion", "YES",
        ]
        app.launch()
        app.activate()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }

        XCTAssertTrue(
            app.descendants(matching: .any)[
                "rules.accessibility.increasedContrast"
            ].firstMatch.waitForExistence(timeout: 6)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["rules.accessibility.reduceMotion"]
                .firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["rules.table"]
                .firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["rules.inspector.copyRedacted"]
                .firstMatch.exists
        )
        let selectedInspector = app.descendants(matching: .any)[
            "rules.inspector.selected"
        ].firstMatch
        XCTAssertTrue(selectedInspector.exists)
        XCTAssertTrue(
            selectedInspector.label.localizedCaseInsensitiveContains("selected")
        )
    }

    @MainActor
    func testInspectorFiftyToggleTransitionsRetainStableSelection() throws {
        let session = try launch(state: "loaded", inspector: "open")
        defer { session.terminate() }
        let toggle = session.app.descendants(matching: .any)[
            "rules.inspector.toggle"
        ].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        for _ in 0..<50 {
            toggle.click()
        }
        XCTAssertTrue(
            session.app.descendants(matching: .any)["rules.inspector.selected"]
                .firstMatch.waitForExistence(timeout: 4)
        )
        XCTAssertTrue(session.app.staticTexts["#20 DOMAIN-SUFFIX"].exists)
    }

    @MainActor
    func testRequiredFifteenVisualCaptures() throws {
        let scenarios = [
            RulesScenario("loaded", "dark", "zh-Hans", "1040x680", "open"),
            RulesScenario("loaded", "dark", "zh-Hans", "1040x680", "closed"),
            RulesScenario("loaded", "dark", "zh-Hans", "1280x820", "open"),
            RulesScenario("loaded", "light", "en", "1280x820", "open"),
            RulesScenario("loaded", "dark", "en", "1600x1000", "open"),
            RulesScenario("loaded", "dark", "en", "1600x1000", "closed"),
            RulesScenario("empty", "dark", "en", "1280x820", "open"),
            RulesScenario("failure", "dark", "en", "1280x820", "open"),
            RulesScenario("partialFailure", "dark", "en", "1280x820", "open"),
            RulesScenario("refreshing", "dark", "en", "1280x820", "open"),
            RulesScenario("stale", "dark", "en", "1280x820", "open"),
            RulesScenario("pendingMutation", "dark", "en", "1280x820", "open"),
            RulesScenario("loading", "light", "zh-Hans", "1280x820", "open"),
            RulesScenario("transitioning", "dark", "en", "1280x820", "open"),
            RulesScenario("empty", "light", "zh-Hans", "1600x1000", "closed"),
        ]

        for scenario in scenarios {
            try XCTContext.runActivity(named: scenario.identifier) { _ in
                let session = try launch(
                    state: scenario.state,
                    appearance: scenario.appearance,
                    locale: scenario.locale,
                    window: scenario.window,
                    inspector: scenario.inspector
                )
                defer { session.terminate() }
                session.window.hover()
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
        additionalArguments: [String] = []
    ) throws -> RulesSession {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "rules",
            state: state,
            appearance: appearance,
            locale: locale,
            window: window,
            inspector: inspector
        ) + additionalArguments
        app.launch()
        app.activate()

        let ready = app.descendants(matching: .any)[
            "visual.ready.rules.\(state)"
        ].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 8))
        let windowElement = app.windows.allElementsBoundByIndex.first { candidate in
            let frame = candidate.frame
            return frame.width.isFinite
                && frame.height.isFinite
                && frame.width > 0
                && frame.height > 0
                && candidate.descendants(matching: .any)[
                    "visual.ready.rules.\(state)"
                ].firstMatch.exists
        } ?? app.windows.firstMatch
        XCTAssertTrue(windowElement.exists)
        return RulesSession(
            app: app,
            window: windowElement,
            preferencesDomain: preferencesDomain
        )
    }

    @MainActor
    private func assertNoHorizontalTableOverflow(
        in session: RulesSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let table = session.app.descendants(matching: .any)["rules.table"]
            .firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 3), file: file, line: line)
        session.window.hover()
        let tableFrame = table.frame
        let horizontalScrollBars = session.app.scrollBars.allElementsBoundByIndex
            .filter { scrollBar in
                let frame = scrollBar.frame
                return frame.width > frame.height * 2
                    && frame.intersects(tableFrame)
            }
        XCTAssertTrue(
            horizontalScrollBars.isEmpty,
            "Rules table must fit its responsive column set without horizontal scrolling.",
            file: file,
            line: line
        )
    }
}

private struct RulesScenario {
    let state: String
    let appearance: String
    let locale: String
    let window: String
    let inspector: String

    init(
        _ state: String,
        _ appearance: String,
        _ locale: String,
        _ window: String,
        _ inspector: String
    ) {
        self.state = state
        self.appearance = appearance
        self.locale = locale
        self.window = window
        self.inspector = inspector
    }

    var identifier: String {
        "rules__\(state)__\(appearance)__\(locale)__\(window)__\(inspector)"
    }
}

@MainActor
private struct RulesSession {
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
