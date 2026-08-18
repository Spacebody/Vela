import XCTest

/// UI coverage for the reconstructed Proxies Liquid Glass workspace.
///
/// The pre-reconstruction inspector/table assertions intentionally are not
/// retained: the V2 screen has a different information architecture and owns
/// its own deterministic visual contract.
final class VelaProxiesInspectorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
    }

    @MainActor
    func testLoadedLiquidGlassWorkspaceAtReferenceSize() throws {
        let session = try launch(
            state: "loaded",
            appearance: "light",
            locale: "en",
            window: "1440x900",
            inspector: "open"
        )
        defer { session.terminate() }

        XCTAssertTrue(
            session.app.descendants(matching: .any)["proxies.liquidGlass.page"]
                .firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            session.app.descendants(matching: .any)["proxies.testAll"]
                .firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            session.app.staticTexts["Node Details"]
                .firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            session.app.descendants(matching: .any)["proxies.routePreview"]
                .firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            session.app.descendants(matching: .any)["proxies.group.Auto Select"]
                .firstMatch.exists
        )
        XCTAssertTrue(
            session.app.descendants(matching: .any)["proxies.node.Tokyo · JP | 01"]
                .firstMatch.exists
        )

        session.window.hover()
        let attachment = XCTAttachment(screenshot: session.window.screenshot())
        attachment.name = "proxies__loaded__light__en__1440x900__open.png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testInspectorVisibilityFollowsFixtureAndCompactLayoutStaysReachable() throws {
        let session = try launch(
            state: "loaded",
            appearance: "light",
            locale: "zh-Hans",
            window: "1100x720",
            inspector: "closed"
        )
        defer { session.terminate() }

        XCTAssertTrue(
            session.app.descendants(matching: .any)["proxies.liquidGlass.page"]
                .firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            session.app.staticTexts["节点详情"].firstMatch.exists
        )
        XCTAssertTrue(
            session.app.descendants(matching: .any)["proxies.search"]
                .firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            session.app.descendants(matching: .any)["proxies.routePreview"]
                .firstMatch.waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            session.app.descendants(matching: .any)["proxies.checkRoute"]
                .firstMatch.waitForExistence(timeout: 2)
        )
    }

    @MainActor
    func testGroupFilterAndSortMenusMutateTheVisibleGroupList() throws {
        let session = try launch(
            state: "loaded",
            appearance: "light",
            locale: "en",
            window: "1440x900",
            inspector: "open"
        )
        defer { session.terminate() }

        let autoSelect = session.app.descendants(matching: .any)[
            "proxies.group.Auto Select"
        ].firstMatch
        XCTAssertTrue(autoSelect.waitForExistence(timeout: 5))

        let filter = session.app.menuButtons[
            "Filter Proxy Groups"
        ].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        filter.click()
        let needsAttention = session.app.descendants(matching: .any)[
            "Needs Attention"
        ].firstMatch
        XCTAssertTrue(needsAttention.waitForExistence(timeout: 2))
        needsAttention.click()
        XCTAssertTrue(autoSelect.waitForNonExistence(timeout: 2))

        filter.click()
        let allGroups = session.app.descendants(matching: .any)["All Groups"].firstMatch
        XCTAssertTrue(allGroups.waitForExistence(timeout: 2))
        allGroups.click()
        XCTAssertTrue(autoSelect.waitForExistence(timeout: 2))

        let sort = session.app.menuButtons[
            "Sort Proxy Groups"
        ].firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 2))
        sort.click()
        let nameSort = session.app.descendants(matching: .any)["Name"].firstMatch
        XCTAssertTrue(nameSort.waitForExistence(timeout: 2))
        nameSort.click()
        XCTAssertTrue(autoSelect.exists)
    }

    @MainActor
    private func launch(
        state: String,
        appearance: String,
        locale: String,
        window: String,
        inspector: String
    ) throws -> Session {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "proxies",
            state: state,
            appearance: appearance,
            locale: locale,
            window: window,
            inspector: inspector
        )
        app.launch()
        app.activate()

        let ready = app.descendants(matching: .any)[
            "visual.ready.proxies.\(state)"
        ].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 8))

        let windowElement = app.windows.allElementsBoundByIndex.first { candidate in
            let frame = candidate.frame
            return frame.width.isFinite
                && frame.height.isFinite
                && frame.width > 0
                && frame.height > 0
                && candidate.descendants(matching: .any)[
                    "visual.ready.proxies.\(state)"
                ].firstMatch.exists
        } ?? app.windows.firstMatch
        XCTAssertTrue(windowElement.exists)

        return Session(
            app: app,
            window: windowElement,
            preferencesDomain: preferencesDomain
        )
    }
}

@MainActor
private struct Session {
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
