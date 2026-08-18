import XCTest

final class OverviewRecoveryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
    }

    @MainActor
    func testConnectedConsoleExposesKeyboardAndVoiceOverControls() throws {
        try withOverview(state: "loaded", readyFixtureID: "overview.loadedHealthy") { app in
            let labeledControlIdentifiers: Set<String> = [
                "overview.connectionCore",
                "overview.route.nodeMenu",
                "overview.route.modeMenu",
                "overview.metrics.connections",
            ]
            for identifier in [
                "overview.root",
                "overview.controlPanel",
                "overview.networkControls",
                "overview.connectionCore",
                "overview.route",
                "overview.route.nodeMenu",
                "overview.route.modeMenu",
                "overview.metrics",
                "overview.metrics.connections",
            ] {
                let element = app.descendants(matching: .any)
                    .matching(identifier: identifier)
                    .firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: 4), "Missing \(identifier)")
                if labeledControlIdentifiers.contains(identifier) {
                    XCTAssertFalse(
                        element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "Missing accessibility label for \(identifier); element=\(element.debugDescription)"
                    )
                }
            }

            XCTAssertTrue(app.buttons["overview.connectionCore"].isEnabled)
            let modeMenu = app.descendants(matching: .any)
                .matching(identifier: "overview.route.modeMenu")
                .firstMatch
            XCTAssertTrue(modeMenu.exists)
            XCTAssertTrue(modeMenu.isEnabled)
            app.typeKey(.tab, modifierFlags: [])
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(identifier: "overview.root")
                    .firstMatch
                    .exists
            )
        }
    }

    @MainActor
    func testNodeAndGroupSelectorsStayOnOverview() throws {
        try withOverview(state: "loaded", readyFixtureID: "overview.loadedHealthy") { app in
            let modeMenu = app.descendants(matching: .any)
                .matching(identifier: "overview.route.modeMenu")
                .firstMatch
            XCTAssertTrue(modeMenu.waitForExistence(timeout: 4))
            modeMenu.click()

            XCTAssertTrue(app.menuItems["Global"].waitForExistence(timeout: 2))
            app.typeKey(.escape, modifierFlags: [])

            let nodeMenu = app.descendants(matching: .any)
                .matching(identifier: "overview.route.nodeMenu")
                .firstMatch
            XCTAssertTrue(nodeMenu.waitForExistence(timeout: 2))
            nodeMenu.click()

            let nodePicker = app.descendants(matching: .any)
                .matching(identifier: "overview.nodePicker")
                .firstMatch
            XCTAssertTrue(nodePicker.waitForExistence(timeout: 2))
            XCTAssertLessThan(nodePicker.frame.height, 520)

            let manualNode = app.descendants(matching: .any)
                .matching(identifier: "overview.nodeOption.overview.node.1")
                .firstMatch
            XCTAssertTrue(manualNode.waitForExistence(timeout: 2))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(identifier: "overview.root")
                    .firstMatch
                    .exists
            )
        }
    }

    @MainActor
    func testNoConfigurationHasOneSafeRecoveryPath() throws {
        try withOverview(state: "empty", readyFixtureID: "overview.empty") { app in
            let core = app.buttons["overview.connectionCore"]
            let recovery = app.descendants(matching: .any)
                .matching(identifier: "overview.recovery")
                .firstMatch

            XCTAssertTrue(core.waitForExistence(timeout: 4))
            XCTAssertTrue(core.isEnabled)
            XCTAssertFalse(recovery.exists)
            XCTAssertTrue(
                app.descendants(matching: .any)["overview.route"].firstMatch.exists
            )
            XCTAssertTrue(
                app.descendants(matching: .any)["overview.networkControls"].firstMatch.exists
            )
            XCTAssertFalse(
                app.descendants(matching: .any)["overview.route.modeMenu"].firstMatch.isEnabled
            )
            XCTAssertFalse(
                app.descendants(matching: .any)["overview.route.nodeMenu"].firstMatch.isEnabled
            )
            XCTAssertTrue(core.label.localizedCaseInsensitiveContains("configuration"))
        }
    }

    @MainActor
    func testEveryRequiredDesignStateRendersWithoutLegacyCards() throws {
        for state in ["loaded", "loading", "offline", "empty", "failure", "stale"] {
            try withOverview(
                state: state,
                readyFixtureID: state == "loaded" ? "overview.loadedHealthy" :
                    (state == "offline" ? "overview.offlineNoConfiguration" : "overview.\(state)")
            ) { app in
                XCTAssertTrue(
                    app.descendants(matching: .any)
                        .matching(identifier: "overview.connectionCore")
                        .firstMatch
                        .waitForExistence(timeout: 4)
                )
                XCTAssertTrue(
                    app.descendants(matching: .any)
                        .matching(identifier: "overview.metrics")
                        .firstMatch
                        .exists
                )
                XCTAssertFalse(
                    app.descendants(matching: .any)
                        .matching(identifier: "overview.quickActions")
                        .firstMatch
                        .exists
                )
                XCTAssertFalse(
                    app.descendants(matching: .any)
                        .matching(identifier: "overview.metric.backend")
                        .firstMatch
                        .exists
                )
            }
        }
    }

    @MainActor
    func testResponsiveGeometryStaysInsideTheWindow() throws {
        for windowSize in ["1040x680", "1280x820", "1600x1000"] {
            try withOverview(
                state: "loaded",
                readyFixtureID: "overview.loadedHealthy",
                appearance: "dark",
                locale: "zh-Hans",
                window: windowSize
            ) { app in
                let window = app.windows.firstMatch
                XCTAssertTrue(window.waitForExistence(timeout: 4))

                let identifiers = [
                    "overview.root",
                    "overview.controlPanel",
                    "overview.networkControls",
                    "overview.connectionCore",
                    "overview.route",
                    "overview.metrics",
                ]
                var frames: [String: CGRect] = [:]
                for identifier in identifiers {
                    let element = app.descendants(matching: .any)
                        .matching(identifier: identifier)
                        .firstMatch
                    XCTAssertTrue(element.waitForExistence(timeout: 4), "Missing \(identifier) at \(windowSize)")
                    frames[identifier] = element.frame
                    XCTAssertGreaterThanOrEqual(
                        element.frame.minX,
                        window.frame.minX,
                        "\(identifier) escaped left at \(windowSize); element=\(element.frame), window=\(window.frame)"
                    )
                    XCTAssertLessThanOrEqual(
                        element.frame.maxX,
                        window.frame.maxX,
                        "\(identifier) escaped right at \(windowSize); element=\(element.frame), window=\(window.frame)"
                    )
                    XCTAssertGreaterThanOrEqual(
                        element.frame.minY,
                        window.frame.minY,
                        "\(identifier) escaped top at \(windowSize); element=\(element.frame), window=\(window.frame)"
                    )
                    if [
                        "overview.root",
                        "overview.controlPanel",
                        "overview.networkControls",
                        "overview.connectionCore",
                    ].contains(identifier) {
                        XCTAssertLessThanOrEqual(
                            element.frame.maxY,
                            window.frame.maxY,
                            "\(identifier) escaped bottom at \(windowSize); element=\(element.frame), window=\(window.frame)"
                        )
                    }
                }

                guard let root = frames["overview.root"],
                      let panel = frames["overview.controlPanel"],
                      let networkControls = frames["overview.networkControls"],
                      let core = frames["overview.connectionCore"],
                      let route = frames["overview.route"],
                      let metrics = frames["overview.metrics"]
                else {
                    XCTFail("Missing Overview layout frames at \(windowSize)")
                    return
                }

                XCTAssertTrue(root.contains(panel), "Control panel escaped Overview at \(windowSize): \(frames)")
                XCTAssertTrue(panel.contains(core), "Connection core escaped its panel at \(windowSize): \(frames)")
                XCTAssertTrue(
                    panel.contains(networkControls),
                    "Network controls escaped their panel at \(windowSize): \(frames)"
                )
                XCTAssertLessThanOrEqual(
                    panel.maxY,
                    route.minY,
                    "Control panel overlaps the route at \(windowSize): \(frames)"
                )
                XCTAssertLessThanOrEqual(
                    route.maxY,
                    metrics.minY,
                    "Route overlaps the metric strip at \(windowSize): \(frames)"
                )
            }
        }
    }

    @MainActor
    func testIncreaseContrastAndReduceMotionReachOverview() throws {
        try withOverview(
            state: "loaded",
            readyFixtureID: "overview.loadedHealthy",
            additionalArguments: [
                "-VelaOverviewIncreaseContrast", "YES",
                "-VelaOverviewReduceMotion", "YES",
            ]
        ) { app in
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(identifier: "overview.accessibility.increasedContrast")
                    .firstMatch
                    .waitForExistence(timeout: 4)
            )
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(identifier: "overview.accessibility.reduceMotion")
                    .firstMatch
                    .exists
            )
        }
    }

    @MainActor
    private func withOverview(
        state: String,
        readyFixtureID: String,
        appearance: String = "light",
        locale: String = "en",
        window: String = "1040x680",
        additionalArguments: [String] = [],
        verify: (XCUIApplication) throws -> Void
    ) throws {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        defer {
            VelaUITestIsolation.terminate(app, clearingPreferenceDomain: preferencesDomain)
        }
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "overview",
            state: state,
            appearance: appearance,
            locale: locale,
            window: window,
            inspector: "na"
        ) + additionalArguments
        app.launch()
        app.activate()

        let ready = app.descendants(matching: .any)
            .matching(identifier: "visual.ready.\(readyFixtureID)")
            .firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 6))
        try verify(app)
    }
}
