//
//  VelaUITestsLaunchTests.swift
//  VelaUITests
//
//  Created by Jerry on 2026/7/11.
//

import XCTest

final class VelaUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
    }

    @MainActor
    func testLaunch() throws {
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

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }
}
