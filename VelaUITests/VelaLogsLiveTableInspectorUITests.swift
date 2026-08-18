import XCTest

final class VelaLogsLiveTableInspectorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
    }

    @MainActor
    func testLoadedTableFiltersSearchAndInspectorAreAvailable() throws {
        let session = try launch(state: "loaded", inspector: "open")
        defer { session.terminate() }

        XCTAssertTrue(element("logs.table", in: session.app).exists)
        XCTAssertTrue(element("logs.filter.levels", in: session.app).exists)
        XCTAssertTrue(element("logs.filter.sources", in: session.app).exists)
        XCTAssertTrue(element("logs.search", in: session.app).exists)
        XCTAssertTrue(element("logs.inspector", in: session.app).exists)
        XCTAssertTrue(element("logs.pause", in: session.app).exists)
        element("logs.inspector.hide", in: session.app).click()
        XCTAssertTrue(element("logs.inspector", in: session.app).waitForNonExistence(timeout: 2))
        element("logs.more", in: session.app).click()
        let export = element("logs.exportRedacted", in: session.app)
        XCTAssertTrue(export.waitForExistence(timeout: 2))
        XCTAssertTrue(export.isEnabled)
    }

    @MainActor
    func testNoFilterResultsHasOneRecoveryAndClearsSelection() throws {
        let session = try launch(state: "transitioning", inspector: "closed")
        defer { session.terminate() }

        let clear = element("logs.clearFilters", in: session.app)
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        clear.click()
        XCTAssertFalse(clear.exists)
    }

    @MainActor
    func testPauseStaleFailuresAndTruncationKeepTruthfulControls() throws {
        let paused = try launch(state: "pendingMutation", inspector: "closed")
        XCTAssertTrue(element("logs.state.paused", in: paused.app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("logs.resume", in: paused.app).exists)
        paused.terminate()

        let retainedFailure = try launch(state: "partialFailure", inspector: "closed")
        XCTAssertTrue(element("logs.state.failureWithBuffer", in: retainedFailure.app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("logs.retrySource", in: retainedFailure.app).exists)
        element("logs.more", in: retainedFailure.app).click()
        let retainedExport = element("logs.exportRedacted", in: retainedFailure.app)
        XCTAssertTrue(retainedExport.waitForExistence(timeout: 2))
        XCTAssertTrue(retainedExport.isEnabled)
        retainedFailure.terminate()

        let fullFailure = try launch(state: "failure", inspector: "closed")
        XCTAssertTrue(element("logs.empty.retrySource", in: fullFailure.app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("logs.state.failure", in: fullFailure.app).exists)
        element("logs.more", in: fullFailure.app).click()
        let unavailableExport = element("logs.exportRedacted", in: fullFailure.app)
        XCTAssertTrue(unavailableExport.waitForExistence(timeout: 2))
        XCTAssertFalse(unavailableExport.isEnabled)
        fullFailure.terminate()

        let truncated = try launch(state: "rollbackFailed", inspector: "closed")
        defer { truncated.terminate() }
        XCTAssertTrue(element("logs.buffer.truncated", in: truncated.app).waitForExistence(timeout: 3))
    }

    @MainActor
    func testMinimumWindowKeepsTableAndPersistentControlsInBounds() throws {
        let session = try launch(
            state: "loaded",
            appearance: "dark",
            locale: "zh-Hans",
            window: "1100x720",
            inspector: "open"
        )
        defer { session.terminate() }

        let table = element("logs.table", in: session.app)
        let search = element("logs.search", in: session.app)
        XCTAssertTrue(table.waitForExistence(timeout: 3))
        XCTAssertTrue(search.exists)
        XCTAssertLessThanOrEqual(table.frame.maxX, session.window.frame.maxX + 1)
        XCTAssertLessThanOrEqual(search.frame.maxX, session.window.frame.maxX + 1)
        XCTAssertGreaterThan(table.frame.height, 320)
    }

    @MainActor
    func testKeyboardVoiceOverAndAccessibilityOverrides() throws {
        let session = try launch(
            state: "loaded",
            inspector: "open",
            additionalArguments: [
                "-VelaLogsIncreaseContrast", "YES",
                "-VelaLogsReduceMotion", "YES",
            ]
        )
        defer { session.terminate() }

        XCTAssertTrue(
            element("logs.accessibility.increasedContrast", in: session.app)
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            element("logs.accessibility.reduceMotion", in: session.app).exists
        )

        let row = session.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "logs.row."))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let spokenContent = [row.label, row.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(spokenContent.isEmpty)
        XCTAssertFalse(element("logs.inspector.hide", in: session.app).label.isEmpty)

        session.app.typeKey("f", modifierFlags: .command)
        let search = element("logs.search", in: session.app)
        search.typeText("timeout")
        XCTAssertTrue(String(describing: search.value).localizedCaseInsensitiveContains("timeout"))
        XCTAssertTrue(element("logs.inspector.empty", in: session.app).exists)
        element("logs.inspector.hide", in: session.app).click()
        XCTAssertTrue(element("logs.inspector", in: session.app).waitForNonExistence(timeout: 2))
        element("logs.more", in: session.app).click()
        let export = element("logs.exportRedacted", in: session.app)
        XCTAssertTrue(export.waitForExistence(timeout: 2))
        XCTAssertFalse(export.label.isEmpty)
    }

    @MainActor
    func testRequiredEighteenKeyScreenshots() throws {
        let loaded: [(String, String, String, String)] = [
            ("dark", "zh-Hans", "1100x720", "closed"),
            ("light", "en", "1100x720", "open"),
            ("dark", "en", "1280x800", "closed"),
            ("light", "zh-Hans", "1440x900", "open"),
            ("dark", "en", "1600x1000", "closed"),
            ("light", "zh-Hans", "1600x1000", "open"),
        ]
        for values in loaded {
            try capture(
                state: "loaded",
                appearance: values.0,
                locale: values.1,
                window: values.2,
                inspector: values.3,
                suffix: "loaded"
            )
        }

        let states: [(String, String)] = [
            ("loading", "loading-source"),
            ("empty", "empty-session"),
            ("transitioning", "no-filter-results"),
            ("refreshing", "catching-up"),
            ("pendingMutation", "paused-new"),
            ("stale", "stale"),
            ("partialFailure", "failure-with-buffer"),
            ("failure", "full-failure"),
            ("rollbackFailed", "buffer-truncated"),
            ("permissionRequired", "selected-warning-error"),
            ("offline", "export-disabled-empty"),
        ]
        for value in states {
            try capture(
                state: value.0,
                appearance: "dark",
                locale: "en",
                window: "1280x800",
                inspector: value.0 == "permissionRequired" ? "open" : "closed",
                suffix: value.1
            )
        }

        let filtered = try launch(state: "loaded", inspector: "closed")
        let search = element("logs.search", in: filtered.app)
        search.click()
        search.typeText("timeout")
        attach(filtered, name: "logs__export-filtered-result__dark__en__1280x800__closed.png")
        filtered.terminate()
    }

    @MainActor
    private func capture(
        state: String,
        appearance: String,
        locale: String,
        window: String,
        inspector: String,
        suffix: String
    ) throws {
        let session = try launch(
            state: state,
            appearance: appearance,
            locale: locale,
            window: window,
            inspector: inspector
        )
        defer { session.terminate() }
        attach(
            session,
            name: "logs__\(suffix)__\(appearance)__\(locale)__\(window)__\(inspector).png"
        )
    }

    @MainActor
    private func attach(_ session: LogsSession, name: String) {
        let attachment = XCTAttachment(screenshot: session.window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launch(
        state: String,
        appearance: String = "dark",
        locale: String = "en",
        window: String = "1280x800",
        inspector: String,
        additionalArguments: [String] = []
    ) throws -> LogsSession {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "logs",
            state: state,
            appearance: appearance,
            locale: locale,
            window: window,
            inspector: inspector
        ) + additionalArguments
        app.launch()
        app.activate()
        XCTAssertTrue(
            element("visual.ready.logs.\(state)", in: app).waitForExistence(timeout: 10),
            "Logs fixture did not become ready: \(state)-\(window)-\(inspector)"
        )
        let firstWindow = app.windows.firstMatch
        XCTAssertTrue(firstWindow.waitForExistence(timeout: 4))
        let windowElement = app.windows.allElementsBoundByIndex.first { candidate in
            candidate.frame.width > 0
                && candidate.frame.height > 0
                && candidate.descendants(matching: .any)["visual.ready.logs.\(state)"].firstMatch.exists
        } ?? firstWindow
        return LogsSession(app: app, window: windowElement, preferencesDomain: preferencesDomain)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}

@MainActor
private struct LogsSession {
    let app: XCUIApplication
    let window: XCUIElement
    let preferencesDomain: String

    func terminate() {
        VelaUITestIsolation.terminate(app, clearingPreferenceDomain: preferencesDomain)
    }
}
