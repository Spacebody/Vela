import XCTest

final class VelaDiagnosticsGroupedChecksInspectorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
    }

    @MainActor
    func testLoadedWorkspaceHasGroupedTableSummaryAndInspector() throws {
        let session = try launch(state: "loaded", inspector: "open")
        defer { session.terminate() }

        XCTAssertTrue(element("diagnostics.summary.completion", in: session.app).exists)
        XCTAssertTrue(element("diagnostics.hideInspector", in: session.app).exists)
        XCTAssertTrue(element("diagnostics.check.engine.controller", in: session.app).exists)
        XCTAssertTrue(element("diagnostics.check.engine.internet", in: session.app).exists)
    }

    @MainActor
    func testPermissionBlocksOnlyAffectedCheck() throws {
        let session = try launch(state: "permissionRequired", inspector: "open")
        defer { session.terminate() }

        let blocked = element("diagnostics.check.engine.systemProxy", in: session.app)
        let unaffected = element("diagnostics.check.engine.process", in: session.app)
        XCTAssertTrue(blocked.waitForExistence(timeout: 3))
        XCTAssertTrue(blocked.label.localizedCaseInsensitiveContains("blocked") || blocked.label.contains("受阻"))
        XCTAssertTrue(unaffected.label.localizedCaseInsensitiveContains("passed") || unaffected.label.contains("通过"))
    }

    @MainActor
    func testRunAndRepairProgressUseDistinctSurfaces() throws {
        let runSession = try launch(state: "refreshing", inspector: "open")
        XCTAssertTrue(element("diagnostics.cancelRun", in: runSession.app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("diagnostics.repairProgress", in: runSession.app).exists)
        runSession.terminate()

        let repairSession = try launch(state: "pendingMutation", inspector: "open")
        defer { repairSession.terminate() }
        XCTAssertTrue(element("diagnostics.repairProgress", in: repairSession.app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("diagnostics.cancelRun", in: repairSession.app).exists)
    }

    @MainActor
    func testRepairFailureAndStaleEvidenceRemainActionable() throws {
        let failed = try launch(state: "rollbackFailed", inspector: "open")
        XCTAssertTrue(element("diagnostics.repairFailed", in: failed.app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("diagnostics.check.engine.controller", in: failed.app).exists)
        failed.terminate()

        let stale = try launch(state: "stale", inspector: "open")
        defer { stale.terminate() }
        XCTAssertTrue(element("diagnostics.stale.runAll", in: stale.app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("diagnostics.check.engine.controller", in: stale.app).exists)
    }

    @MainActor
    func testMinimumWindowKeepsActionsAndTableWithinBounds() throws {
        let session = try launch(
            state: "loaded",
            appearance: "dark",
            locale: "zh-Hans",
            window: "1040x680",
            inspector: "open"
        )
        defer { session.terminate() }

        let table = element("diagnostics.check.engine.process", in: session.app)
        let runAll = element("diagnostics.runChecks", in: session.app)
        XCTAssertTrue(table.waitForExistence(timeout: 3))
        XCTAssertTrue(runAll.exists)
        XCTAssertLessThanOrEqual(table.frame.maxX, session.window.frame.maxX + 1)
        XCTAssertLessThanOrEqual(runAll.frame.maxX, session.window.frame.maxX + 1)
    }

    @MainActor
    func testRequiredNineStateVisualMatrix() throws {
        let states = [
            "loading", "loaded", "refreshing", "partialFailure", "failure",
            "pendingMutation", "stale", "permissionRequired", "rollbackFailed",
        ]
        for state in states {
            for inspector in ["closed", "open"] {
                try XCTContext.runActivity(named: "\(state)-\(inspector)") { _ in
                    let session = try launch(state: state, inspector: inspector)
                    defer { session.terminate() }
                    let attachment = XCTAttachment(screenshot: session.window.screenshot())
                    attachment.name = "diagnostics__\(state)__dark__en__1280x820__\(inspector).png"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
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
    ) throws -> DiagnosticsSession {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "diagnostics",
            state: state,
            appearance: appearance,
            locale: locale,
            window: window,
            inspector: inspector
        )
        app.launch()
        app.activate()

        XCTAssertTrue(
            element("visual.ready.diagnostics.\(state)", in: app).waitForExistence(timeout: 10),
            "Diagnostics fixture did not become ready: \(state)-\(window)-\(inspector)"
        )
        let firstWindow = app.windows.firstMatch
        XCTAssertTrue(firstWindow.waitForExistence(timeout: 4))
        let windowElement = app.windows.allElementsBoundByIndex.first { candidate in
            candidate.frame.width > 0
                && candidate.frame.height > 0
                && candidate.descendants(matching: .any)["visual.ready.diagnostics.\(state)"].firstMatch.exists
        } ?? firstWindow
        return DiagnosticsSession(app: app, window: windowElement, preferencesDomain: preferencesDomain)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}

@MainActor
private struct DiagnosticsSession {
    let app: XCUIApplication
    let window: XCUIElement
    let preferencesDomain: String

    func terminate() {
        VelaUITestIsolation.terminate(app, clearingPreferenceDomain: preferencesDomain)
    }
}
