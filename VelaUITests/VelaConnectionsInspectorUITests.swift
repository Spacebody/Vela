import XCTest

final class VelaConnectionsInspectorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
    }

    @MainActor
    func testLoadedSelectionInspectorAndCloseReopenPersistence() throws {
        let session = try launch(state: "loaded", inspector: "open")
        defer { session.terminate() }

        let inspector = session.app.descendants(matching: .any)[
            "connections.inspector.scroll"
        ].firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertTrue(session.app.staticTexts["Safari"].exists)
        XCTAssertTrue(session.app.staticTexts["dashboard.example.invalid"].exists)
        XCTAssertTrue(
            session.app.descendants(matching: .any)[
                "connections.inspector.selected"
            ].firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            session.app.descendants(matching: .any)[
                "connections.inspector.disconnect"
            ].firstMatch.isEnabled
        )
        let referenceAttachment = XCTAttachment(screenshot: session.window.screenshot())
        referenceAttachment.name = "connections-audit-reference-1280x820.png"
        referenceAttachment.lifetime = .keepAlways
        add(referenceAttachment)

        let toggle = session.app.descendants(matching: .any)[
            "connections.inspector.toggle"
        ].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        toggle.click()
        XCTAssertFalse(inspector.waitForExistence(timeout: 1))
        toggle.click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 3))
        XCTAssertTrue(session.app.staticTexts["Safari"].exists)
        XCTAssertTrue(session.app.staticTexts["dashboard.example.invalid"].exists)
    }

    @MainActor
    func testNoSnapshotStatesClearRowsSelectionAndInspector() throws {
        for state in ["loading", "empty", "failure"] {
            let session = try launch(state: state, inspector: "open")
            defer { session.terminate() }
            XCTAssertFalse(
                session.app.descendants(matching: .any)[
                    "connections.inspector.selected"
                ].firstMatch.exists,
                "Unexpected Inspector in \(state)"
            )
            XCTAssertFalse(
                session.app.descendants(matching: .any)[
                    "connections.row.connection-browser"
                ].firstMatch.exists,
                "Unexpected retained row in \(state)"
            )
        }
    }

    @MainActor
    func testOfflineSnapshotPolicyAndPendingMutationTarget() throws {
        do {
            let session = try launch(state: "offline", inspector: "open")
            defer { session.terminate() }
            XCTAssertTrue(
                session.app.descendants(matching: .any)[
                    "connections.inspector.selected"
                ].firstMatch.waitForExistence(timeout: 4)
            )
            XCTAssertTrue(
                session.app.descendants(matching: .any)[
                    "connections.row.connection-browser"
                ].firstMatch.exists
            )
            XCTAssertFalse(
                session.app.descendants(matching: .any)[
                    "connections.reconnect"
                ].firstMatch.exists
            )
            XCTAssertFalse(
                session.app.descendants(matching: .any)[
                    "connections.inspector.disconnect"
                ].firstMatch.isEnabled
            )
        }

        do {
            let session = try launch(state: "offline", inspector: "closed")
            defer { session.terminate() }
            XCTAssertTrue(
                session.app.descendants(matching: .any)[
                    "connections.reconnect"
                ].firstMatch.waitForExistence(timeout: 4)
            )
            XCTAssertFalse(
                session.app.descendants(matching: .any)[
                    "connections.row.connection-browser"
                ].firstMatch.exists
            )
        }

        do {
            let session = try launch(state: "pendingMutation", inspector: "open")
            defer { session.terminate() }
            XCTAssertTrue(
                session.app.staticTexts["Updating connection-browser"]
                    .waitForExistence(timeout: 4)
            )
            XCTAssertTrue(
                session.app.descendants(matching: .any)[
                    "connections.row.connection-browser"
                ].firstMatch.exists
            )
            XCTAssertFalse(
                session.app.descendants(matching: .any)[
                    "connections.inspector.disconnect"
                ].firstMatch.isEnabled
            )
        }
    }

    @MainActor
    func testDisconnectedRecoveryActionIsCanonicalAccessibleAndDeduplicated() throws {
        let session = try launch(state: "offline", inspector: "closed")
        defer { session.terminate() }

        let reconnect = session.app.descendants(matching: .any)[
            "connections.reconnect"
        ].firstMatch
        let diagnostics = session.app.descendants(matching: .any)[
            "connections.openDiagnostics"
        ].firstMatch
        XCTAssertTrue(reconnect.waitForExistence(timeout: 4))
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 2))
        XCTAssertEqual(reconnect.label, "Reconnect")
        XCTAssertEqual(diagnostics.label, "Open Diagnostics")
        XCTAssertGreaterThanOrEqual(reconnect.frame.width, 112)
        XCTAssertGreaterThanOrEqual(reconnect.frame.height, 30)
        XCTAssertLessThanOrEqual(reconnect.frame.height, 32)
        XCTAssertEqual(reconnect.frame.midY, diagnostics.frame.midY, accuracy: 2)
        XCTAssertEqual(
            diagnostics.frame.minX - reconnect.frame.maxX,
            12,
            accuracy: 2
        )

        XCTAssertFalse(
            session.app.descendants(matching: .any)[
                "connections.refresh"
            ].firstMatch.exists
        )
        XCTAssertFalse(
            session.app.descendants(matching: .any)[
                "connections.pause"
            ].firstMatch.isEnabled
        )
        XCTAssertFalse(
            session.app.descendants(matching: .any)[
                "connections.closeAll"
            ].firstMatch.isEnabled
        )

        session.app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(reconnect.isEnabled)
        XCTAssertTrue(
            session.app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Reconnecting…"))
                .firstMatch.exists
        )
        XCTAssertEqual(reconnect.value as? String, "1")
        session.app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(reconnect.value as? String, "1")
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
            "connections.inspector.scroll"
        ].firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(inspector.frame.width, 298)
        XCTAssertLessThanOrEqual(inspector.frame.width, 305)
        XCTAssertTrue(
            session.app.descendants(matching: .any)["connections.columns.compact"]
                .firstMatch.waitForExistence(timeout: 2)
        )

        let xcode = session.app.descendants(matching: .any)[
            "connections.row.connection-xcode"
        ].firstMatch
        let calendar = session.app.descendants(matching: .any)[
            "connections.row.connection-calendar"
        ].firstMatch
        XCTAssertTrue(xcode.waitForExistence(timeout: 2))
        XCTAssertTrue(calendar.waitForExistence(timeout: 2))
        let rowHeight = calendar.frame.midY - xcode.frame.midY
        XCTAssertGreaterThanOrEqual(rowHeight, 54)
        XCTAssertLessThanOrEqual(rowHeight, 58)

        xcode.click()
        xcode.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(session.app.staticTexts["Calendar"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            session.app.descendants(matching: .any)["connections.inspector.selected"]
                .firstMatch.exists
        )
        let compactAttachment = XCTAttachment(screenshot: session.window.screenshot())
        compactAttachment.name = "connections-audit-compact-1040x680.png"
        compactAttachment.lifetime = .keepAlways
        add(compactAttachment)

        let evidence = XCTAttachment(
            string: [
                "window=1040x680",
                "inspectorWidth=\(inspector.frame.width)",
                "tableRowHeight=\(rowHeight)",
                "columns=Process,Destination,Destination IP,Proxy,Protocol,Down,Up,Duration,Status",
            ].joined(separator: "\n")
        )
        evidence.name = "connections-1040-geometry.txt"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    func testAccessibilityOverridesAndInspectorSemantics() throws {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "connections",
            state: "loaded",
            appearance: "dark",
            locale: "en",
            window: "1280x820",
            inspector: "open"
        ) + [
            "-VelaConnectionsIncreaseContrast", "YES",
            "-VelaConnectionsReduceMotion", "YES",
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
                "connections.accessibility.increasedContrast"
            ].firstMatch.waitForExistence(timeout: 6)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "connections.accessibility.reduceMotion"
            ].firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["connections.table"]
                .firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "connections.inspector.copyRedacted"
            ].firstMatch.exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Confidence Unavailable"))
                .firstMatch.exists
        )
    }

    @MainActor
    func testInspectorFiftyToggleTransitionsRetainStableSelection() throws {
        let session = try launch(state: "loaded", inspector: "open")
        defer { session.terminate() }
        let toggle = session.app.descendants(matching: .any)[
            "connections.inspector.toggle"
        ].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        for _ in 0..<50 {
            toggle.click()
        }
        XCTAssertTrue(
            session.app.descendants(matching: .any)[
                "connections.inspector.selected"
            ].firstMatch.waitForExistence(timeout: 4)
        )
        XCTAssertTrue(session.app.staticTexts["Safari"].exists)
        XCTAssertTrue(session.app.staticTexts["dashboard.example.invalid"].exists)
    }

    @MainActor
    func testRequiredFifteenVisualCaptures() throws {
        let scenarios = [
            ConnectionsScenario("loaded", "dark", "zh-Hans", "1040x680", "open"),
            ConnectionsScenario("loaded", "dark", "zh-Hans", "1040x680", "closed"),
            ConnectionsScenario("loaded", "dark", "zh-Hans", "1280x820", "open"),
            ConnectionsScenario("loaded", "light", "en", "1280x820", "open"),
            ConnectionsScenario("loaded", "dark", "en", "1600x1000", "open"),
            ConnectionsScenario("loaded", "dark", "en", "1600x1000", "closed"),
            ConnectionsScenario("empty", "dark", "en", "1280x820", "open"),
            ConnectionsScenario("failure", "dark", "en", "1280x820", "open"),
            ConnectionsScenario("partialFailure", "dark", "en", "1280x820", "open"),
            ConnectionsScenario("refreshing", "dark", "en", "1280x820", "open"),
            ConnectionsScenario("stale", "dark", "en", "1280x820", "open"),
            ConnectionsScenario("pendingMutation", "dark", "en", "1280x820", "open"),
            ConnectionsScenario("loading", "light", "zh-Hans", "1280x820", "open"),
            ConnectionsScenario("offline", "dark", "en", "1280x820", "open"),
            ConnectionsScenario("offline", "dark", "en", "1280x820", "closed"),
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
        inspector: String
    ) throws -> ConnectionsSession {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "connections",
            state: state,
            appearance: appearance,
            locale: locale,
            window: window,
            inspector: inspector
        )
        app.launch()
        app.activate()

        let ready = app.descendants(matching: .any)[
            "visual.ready.connections.\(state)"
        ].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 8))
        let windowElement = app.windows.allElementsBoundByIndex.first { candidate in
            let frame = candidate.frame
            return frame.width.isFinite
                && frame.height.isFinite
                && frame.width > 0
                && frame.height > 0
                && candidate.descendants(matching: .any)[
                    "visual.ready.connections.\(state)"
                ].firstMatch.exists
        } ?? app.windows.firstMatch
        XCTAssertTrue(windowElement.exists)
        return ConnectionsSession(
            app: app,
            window: windowElement,
            preferencesDomain: preferencesDomain
        )
    }
}

private struct ConnectionsScenario {
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
        "connections__\(state)__\(appearance)__\(locale)__\(window)__\(inspector)"
    }
}

@MainActor
private struct ConnectionsSession {
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
