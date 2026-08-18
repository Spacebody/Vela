import XCTest

final class VelaUpdatesCoreRecoveryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
    }

    @MainActor
    func testComponentSelectionKeepsTrustAndAvailabilityDistinct() throws {
        let session = try launch(state: "loaded")
        defer { session.terminate() }

        let application = element("updatesCore.component.application", in: session.app)
        XCTAssertTrue(application.waitForExistence(timeout: 4))
        XCTAssertTrue(application.label.localizedCaseInsensitiveContains("verified"))
        XCTAssertTrue(application.label.localizedCaseInsensitiveContains("current"))
        XCTAssertTrue(verifyAllButton(in: session.app).isEnabled)

        let activeCore = element("updatesCore.component.activeCore", in: session.app)
        activeCore.click()
        XCTAssertTrue(
            element("updatesCore.dimension.runtime", in: session.app)
                .waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testPendingPermissionAndRecoveryExposeScopedActions() throws {
        let pending = try launch(state: "pendingMutation")
        XCTAssertTrue(element("updatesCore.pipeline", in: pending.app).waitForExistence(timeout: 4))
        let pendingVerifyAll = verifyAllButton(in: pending.app)
        XCTAssertFalse(pendingVerifyAll.exists && pendingVerifyAll.isEnabled)
        pending.terminate()

        let permission = try launch(state: "permissionRequired")
        XCTAssertTrue(
            element("updatesCore.permission.installerAuthorization", in: permission.app)
                .waitForExistence(timeout: 4)
        )
        permission.terminate()

        let recovery = try launch(state: "rollbackFailed")
        defer { recovery.terminate() }
        let openRecovery = recovery.app.buttons["Open Recovery"].firstMatch
        XCTAssertTrue(openRecovery.waitForExistence(timeout: 4))
        XCTAssertEqual(recovery.app.buttons.matching(NSPredicate(format: "label == %@", "Open Recovery")).count, 1)
        XCTAssertFalse(recovery.app.buttons["Rollback Core"].firstMatch.exists)
    }

    @MainActor
    func testMinimumWindowKeepsMasterDetailAndHeaderInBounds() throws {
        let session = try launch(
            state: "loaded",
            appearance: "dark",
            locale: "zh-Hans",
            window: "1040x680"
        )
        defer { session.terminate() }

        let application = element("updatesCore.component.application", in: session.app)
        let detailHeader = element("updatesCore.detailHeader", in: session.app)
        let verify = verifyAllButton(in: session.app)
        XCTAssertTrue(application.waitForExistence(timeout: 4))
        XCTAssertTrue(detailHeader.exists)
        XCTAssertTrue(verify.exists)
        XCTAssertLessThan(application.frame.maxX, detailHeader.frame.minX)
        XCTAssertLessThanOrEqual(detailHeader.frame.maxX, session.window.frame.maxX + 1)
        XCTAssertLessThanOrEqual(verify.frame.maxX, session.window.frame.maxX + 1)
    }

    @MainActor
    func testKeyboardVoiceOverContrastAndReduceMotion() throws {
        let session = try launch(
            state: "loaded",
            additionalArguments: [
                "-VelaUpdatesCoreIncreaseContrast", "YES",
                "-VelaUpdatesCoreReduceMotion", "YES",
            ]
        )
        defer { session.terminate() }

        let application = element("updatesCore.component.application", in: session.app)
        XCTAssertTrue(application.waitForExistence(timeout: 4))
        XCTAssertFalse(application.label.isEmpty)
        XCTAssertTrue(session.app.staticTexts["Overall status"].firstMatch.exists)
        XCTAssertTrue(session.app.staticTexts["Last verified"].firstMatch.exists)
        XCTAssertFalse(verifyAllButton(in: session.app).label.isEmpty)

        let activeCore = element("updatesCore.component.activeCore", in: session.app)
        XCTAssertTrue(activeCore.isHittable)
        activeCore.click()
        XCTAssertTrue(
            element("updatesCore.dimension.runtime", in: session.app)
                .waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testRequiredTwentyKeyScreenshots() throws {
        let loaded = [
            Scenario("loaded-1040-dark-zh", "loaded", "dark", "zh-Hans", "1040x680"),
            Scenario("loaded-1280-dark-zh", "loaded", "dark", "zh-Hans", "1280x820"),
            Scenario("loaded-1280-light-en", "loaded", "light", "en", "1280x820"),
            Scenario("loaded-1600-dark-en", "loaded", "dark", "en", "1600x1000"),
        ]

        let details = [
            Scenario("application-current", "loaded", component: "application"),
            Scenario("application-update-available", "loaded", scenario: "applicationUpdateAvailable", component: "application"),
            Scenario("active-core-healthy", "loaded", component: "activeCore"),
            Scenario("core-update-available", "loaded", scenario: "coreUpdateAvailable", component: "coreCatalog"),
            Scenario("recovery-point-verified", "loaded", component: "recoveryPoint"),
            Scenario("catalog-invalid", "loaded", scenario: "catalogInvalid", component: "coreCatalog"),
        ]

        let states = [
            Scenario("partial-failure", "partialFailure"),
            Scenario("full-failure", "failure"),
            Scenario("checking", "loaded", scenario: "checking"),
            Scenario("app-updating", "loaded", scenario: "appUpdating"),
            Scenario("core-downloading-staging", "pendingMutation"),
            Scenario("core-activating", "transitioning"),
            Scenario("authorization-required", "permissionRequired"),
            Scenario("recovery-required", "loaded", scenario: "recoveryRequired"),
            Scenario("recovering", "loaded", scenario: "recovering"),
            Scenario("recovery-failed", "rollbackFailed"),
        ]

        for scenario in loaded + details + states {
            try XCTContext.runActivity(named: scenario.identifier) { _ in
                let session = try launch(
                    state: scenario.state,
                    appearance: scenario.appearance,
                    locale: scenario.locale,
                    window: scenario.window,
                    scenario: scenario.scenario
                )
                defer { session.terminate() }
                if let component = scenario.component {
                    let row = element("updatesCore.component.\(component)", in: session.app)
                    XCTAssertTrue(row.waitForExistence(timeout: 3))
                    row.click()
                    XCTAssertTrue(element("updatesCore.detailHeader", in: session.app).exists)
                }
                let attachment = XCTAttachment(screenshot: session.window.screenshot())
                attachment.name = "updates-core__\(scenario.identifier)__current.png"
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
        scenario: String? = nil,
        additionalArguments: [String] = []
    ) throws -> UpdatesCoreSession {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "updateCoreRecovery",
            state: state,
            appearance: appearance,
            locale: locale,
            window: window,
            inspector: "na"
        )
        if let scenario {
            app.launchArguments += ["-VelaUpdatesCoreScenario", scenario]
        }
        app.launchArguments += additionalArguments
        app.launch()
        app.activate()

        XCTAssertTrue(
            element("visual.ready.updateCoreRecovery.\(state)", in: app)
                .waitForExistence(timeout: 10),
            "Updates/Core fixture did not become ready: \(state)-\(window)-\(scenario ?? "default")"
        )
        let firstWindow = app.windows.firstMatch
        XCTAssertTrue(firstWindow.waitForExistence(timeout: 4))
        let windowElement = app.windows.allElementsBoundByIndex.first { candidate in
            candidate.frame.width > 0
                && candidate.frame.height > 0
                && candidate.descendants(matching: .any)["visual.ready.updateCoreRecovery.\(state)"].firstMatch.exists
        } ?? firstWindow
        return UpdatesCoreSession(
            app: app,
            window: windowElement,
            preferencesDomain: preferencesDomain
        )
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func verifyAllButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Verify All", "全部验证"])
        ).firstMatch
    }
}

private struct Scenario {
    let identifier: String
    let state: String
    let appearance: String
    let locale: String
    let window: String
    let scenario: String?
    let component: String?

    init(
        _ identifier: String,
        _ state: String,
        _ appearance: String = "dark",
        _ locale: String = "en",
        _ window: String = "1280x820",
        scenario: String? = nil,
        component: String? = nil
    ) {
        self.identifier = identifier
        self.state = state
        self.appearance = appearance
        self.locale = locale
        self.window = window
        self.scenario = scenario
        self.component = component
    }
}

@MainActor
private struct UpdatesCoreSession {
    let app: XCUIApplication
    let window: XCUIElement
    let preferencesDomain: String

    func terminate() {
        VelaUITestIsolation.terminate(app, clearingPreferenceDomain: preferencesDomain)
    }
}
