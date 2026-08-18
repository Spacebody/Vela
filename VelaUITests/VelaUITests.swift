//
//  VelaUITests.swift
//  VelaUITests
//
//  Created by Jerry on 2026/7/11.
//

import XCTest

final class VelaUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testNavigatesToLogsAndShowsControls() throws {
        let preferencesDomain = try VelaUITestIsolation.prepare()
        let app = XCUIApplication()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "logs",
            state: "offline",
            inspector: "closed"
        )
        app.launch()

        let logsScreen = app.descendants(matching: .any)["screen.logs"].firstMatch
        guard logsScreen.waitForExistence(timeout: 5) else {
            let bootstrapFailure = app.descendants(matching: .any)["app.bootstrap.failure"]
                .firstMatch
            let details = bootstrapFailure.exists
                ? "\(bootstrapFailure.label): \(bootstrapFailure.value)"
                : "No bootstrap failure details were exposed."
            XCTFail("Logs did not load. \(details)")
            return
        }

        XCTAssertTrue(
            app.descendants(matching: .any)["logs.empty.session"]
                .firstMatch
                .waitForExistence(timeout: 3),
            "The offline Logs fixture did not expose its stable empty-session state."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["logs.table"]
                .firstMatch
                .waitForExistence(timeout: 3),
            "The Logs table disappeared while the session was empty."
        )
    }

    @MainActor
    func testProxiesShowsControllerDisconnectedState() throws {
        let preferencesDomain = try VelaUITestIsolation.prepare()
        let app = XCUIApplication()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "proxies",
            state: "offline",
            inspector: "closed"
        )
        app.launch()

        let proxiesNavigationItem = app.descendants(matching: .any)["sidebar.proxies"].firstMatch
        XCTAssertTrue(proxiesNavigationItem.waitForExistence(timeout: 5))

        XCTAssertTrue(
            app.descendants(matching: .any)["screen.proxies"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )

        // Regression guard for VR21-SHELL-002. The selected source-list row
        // must remain below the unified titlebar/traffic-light region after
        // navigation; an AX-triggered selection must not scroll it behind the
        // window chrome.
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 2))
        XCTAssertTrue(proxiesNavigationItem.waitForExistence(timeout: 2))
        let titlebarExclusionHeight: CGFloat = 38
        XCTAssertGreaterThanOrEqual(
            proxiesNavigationItem.frame.minY,
            mainWindow.frame.minY + titlebarExclusionHeight,
            "The selected Proxies row scrolled under the window traffic lights."
        )
        XCTAssertLessThanOrEqual(
            proxiesNavigationItem.frame.maxY,
            mainWindow.frame.maxY,
            "The selected Proxies row scrolled outside the visible sidebar."
        )
        let testAllButton = app.descendants(matching: .any)["proxies.testAll"]
            .firstMatch
        XCTAssertTrue(testAllButton.waitForExistence(timeout: 3))
        XCTAssertFalse(testAllButton.isEnabled)
        XCTAssertTrue(
            app.buttons["Open Diagnostics"]
                .firstMatch
                .waitForExistence(timeout: 3),
            "The disconnected Proxies state did not expose its recovery action."
        )

        let screenshot = XCTAttachment(
            screenshot: app.windows.firstMatch.screenshot()
        )
        screenshot.name = "Proxies disconnected state"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSidebarGeometryDoesNotJumpAcrossScrollableDestinations() throws {
        let preferencesDomain = try VelaUITestIsolation.prepare()
        let app = XCUIApplication()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "proxies",
            state: "offline",
            inspector: "closed"
        ) + ["-VelaProductionFeatureViews", "YES"]
        app.launch()

        let proxiesScreen = app.descendants(matching: .any)["screen.proxies"]
            .firstMatch
        XCTAssertTrue(proxiesScreen.waitForExistence(timeout: 5))
        let initialFrame = try requireSidebarNavigationFrame(in: app)
        assertSidebarContentRemainsVisible(in: app)

        let overviewItem = app.descendants(matching: .any)["sidebar.overview"]
            .firstMatch
        XCTAssertTrue(overviewItem.waitForExistence(timeout: 3))
        overviewItem.click()
        XCTAssertTrue(overviewItem.isSelected)
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.overview"]
                .firstMatch
                .waitForExistence(timeout: 3),
            "The selected Overview row did not route away from the initial Proxies destination."
        )
        assertSidebarNavigationFrame(
            try requireSidebarNavigationFrame(in: app),
            equals: initialFrame,
            context: "Proxies to Overview"
        )

        let settingsItem = app.descendants(matching: .any)["sidebar.settings"]
            .firstMatch
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 3))
        settingsItem.click()
        XCTAssertTrue(settingsItem.isSelected)
        assertSidebarNavigationFrame(
            try requireSidebarNavigationFrame(in: app),
            equals: initialFrame,
            context: "Overview to Settings"
        )
        assertSidebarContentRemainsVisible(in: app)
        let settingsScreenshot = XCTAttachment(
            screenshot: app.windows.firstMatch.screenshot()
        )
        settingsScreenshot.name = "Settings destination after navigation"
        settingsScreenshot.lifetime = .keepAlways
        add(settingsScreenshot)
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.settings"]
                .firstMatch
                .waitForExistence(timeout: 3),
            "The selected Settings row did not route to the Settings destination."
        )
        let settingsCategories = app.descendants(matching: .any)["settings.detail.general"]
            .firstMatch
        XCTAssertTrue(
            settingsCategories.waitForExistence(timeout: 3),
            "The Settings general section disappeared after navigation."
        )
        XCTAssertTrue(
            app.windows.firstMatch.frame.intersects(settingsCategories.frame),
            "The Settings general section exists but is clipped outside the window."
        )

        overviewItem.click()
        XCTAssertTrue(overviewItem.isSelected)
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.overview"]
                .firstMatch
                .waitForExistence(timeout: 3),
            "The selected Overview row did not route away from Settings."
        )
        assertSidebarNavigationFrame(
            try requireSidebarNavigationFrame(in: app),
            equals: initialFrame,
            context: "Settings to Overview"
        )
    }

    @MainActor
    func testConnectionsUsesLiveTableScreen() throws {
        let preferencesDomain = try VelaUITestIsolation.prepare()
        let app = XCUIApplication()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "connections",
            state: "offline",
            inspector: "closed"
        )
        app.launch()

        let connectionsNavigationItem = app.descendants(matching: .any)[
            "sidebar.connections"
        ].firstMatch
        XCTAssertTrue(connectionsNavigationItem.waitForExistence(timeout: 5))

        XCTAssertTrue(
            app.descendants(matching: .any)["screen.connections"]
                .firstMatch
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.staticTexts["Connections is planned for V0.2."].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["Disconnected"]
                .firstMatch
                .waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testOverviewShowsReadOnlySystemProxyStateWhileMihomoIsStopped() throws {
        let preferencesDomain = try VelaUITestIsolation.prepare()
        let app = XCUIApplication()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = velaIsolatedUITestLaunchArguments()
        app.launch()

        let overviewWindow = app.windows.firstMatch
        XCTAssertTrue(overviewWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.overview"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(overviewWindow.staticTexts["System Proxy"].waitForExistence(timeout: 3))

        let systemProxyControl = overviewWindow.buttons["System Proxy"].firstMatch
        XCTAssertTrue(systemProxyControl.waitForExistence(timeout: 3))
        XCTAssertFalse(systemProxyControl.isEnabled)
        XCTAssertEqual(systemProxyControl.value as? String, "Off")

        let screenshot = XCTAttachment(screenshot: overviewWindow.screenshot())
        screenshot.name = "Overview system proxy stopped state"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testDiagnosticsAndSettingsExposeBundledMihomoMetadata() throws {
        let preferencesDomain = try VelaUITestIsolation.prepare()
        let app = XCUIApplication()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "settings",
            state: "loaded",
            inspector: "na"
        )
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["visual.ready.settings.loaded"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        let settingsSearch = app.textFields["settings.search"].firstMatch
        XCTAssertTrue(settingsSearch.waitForExistence(timeout: 3))
        settingsSearch.click()
        settingsSearch.typeText("Version")
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.detail.diagnostics"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        for title in ["Version", "Update Channel", "Mihomo Core"] {
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(
                        NSPredicate(
                            format: "identifier == %@ AND label == %@",
                            "settings.detail.diagnostics",
                            title
                        )
                    )
                    .firstMatch
                    .waitForExistence(timeout: 3),
                "The loaded Settings metadata omitted \(title)."
            )
        }
    }

    @MainActor
    func testDailyDriverSidebarScreensAreAvailable() throws {
        let preferencesDomain = try VelaUITestIsolation.prepare()
        let app = XCUIApplication()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "proxies",
            state: "offline",
            inspector: "closed"
        )
            + ["-VelaProductionFeatureViews", "YES"]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["screen.proxies"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        for (sidebarID, screenID) in [
            ("sidebar.overview", "screen.overview"),
            ("sidebar.connections", "screen.connections"),
            ("sidebar.rules", "screen.rules"),
            ("sidebar.configuration", "screen.configuration"),
            ("sidebar.settings", "screen.settings"),
            ("sidebar.configuration", "screen.configuration"),
        ] {
            let item = app.descendants(matching: .any)[sidebarID].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Missing \(sidebarID)")
            item.click()
            XCTAssertTrue(
                app.descendants(matching: .any)[screenID].firstMatch
                    .waitForExistence(timeout: 3),
                "Missing \(screenID)"
            )
        }

        let workbench = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ OR identifier == %@",
                "configuration.editor",
                "configuration.empty"
            )
        ).firstMatch
        XCTAssertTrue(
            workbench.waitForExistence(timeout: 3),
            "Configuration workbench did not become interactive after returning from Settings"
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        let preferencesDomain = try VelaUITestIsolation.prepare()
        let app = XCUIApplication()
        app.launchArguments = velaIsolatedUITestLaunchArguments()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }

    @MainActor
    private func assertAccessibilitySummary(
        in app: XCUIApplication,
        label: String,
        valueContains expectedValue: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let summary = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "(label == %@ AND value CONTAINS %@) OR (label CONTAINS %@ AND label CONTAINS %@)",
                    label,
                    expectedValue,
                    label,
                    expectedValue
                )
            )
            .firstMatch
        XCTAssertTrue(
            summary.waitForExistence(timeout: 3),
            "Missing accessibility summary: \(label) / \(expectedValue)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func requireSidebarNavigationFrame(in app: XCUIApplication) throws -> CGRect {
        let navigation = app.descendants(matching: .any)["sidebar.navigation"]
            .firstMatch
        XCTAssertTrue(
            navigation.waitForExistence(timeout: 3),
            "The shared sidebar navigation container did not appear."
        )
        return navigation.frame
    }

    private func assertSidebarNavigationFrame(
        _ actual: CGRect,
        equals expected: CGRect,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, context, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, context, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, context, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, context, file: file, line: line)
    }

    @MainActor
    private func assertSidebarContentRemainsVisible(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mainWindow = app.windows.firstMatch
        let firstRow = app.descendants(matching: .any)["sidebar.overview"].firstMatch
        let lastRow = app.descendants(matching: .any)["sidebar.settings"].firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 2), file: file, line: line)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 2), file: file, line: line)
        XCTAssertTrue(lastRow.waitForExistence(timeout: 2), file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            firstRow.frame.minY,
            mainWindow.frame.minY + 38,
            "The first sidebar row moved behind the window traffic lights.",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            lastRow.frame.maxY,
            mainWindow.frame.maxY,
            "The last sidebar row moved outside the visible navigation column.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            mainWindow.frame.intersects(firstRow.frame),
            "The first sidebar row exists but is clipped outside the window.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            mainWindow.frame.intersects(lastRow.frame),
            "The last sidebar row exists but is clipped outside the window.",
            file: file,
            line: line
        )
    }
}
