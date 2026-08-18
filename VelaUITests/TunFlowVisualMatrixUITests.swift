import XCTest

final class TunFlowVisualMatrixUITests: XCTestCase {
  private struct Scenario {
    let name: String
    let state: String
    let appearance: String
    let locale: String
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
    _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
  }

  @MainActor
  func testTUNSetupVisualMatrix() throws {
    try capture(
      scenarios: [
        .init(
          name: "notInstalledDarkChinese", state: "loading", appearance: "dark", locale: "zh-Hans"),
        .init(
          name: "notInstalledLightEnglish", state: "loading", appearance: "light", locale: "en"),
        .init(name: "registering", state: "pendingMutation", appearance: "dark", locale: "en"),
        .init(name: "needsApproval", state: "permissionRequired", appearance: "dark", locale: "en"),
        .init(
          name: "approvalDenied", state: "permissionRequired", appearance: "dark", locale: "en"),
        .init(
          name: "helperEnabledConnecting", state: "pendingMutation", appearance: "dark",
          locale: "en"),
        .init(name: "helperIncompatible", state: "failure", appearance: "dark", locale: "en"),
        .init(name: "helperDamaged", state: "failure", appearance: "dark", locale: "en"),
        .init(
          name: "profileRequired", state: "permissionRequired", appearance: "dark", locale: "en"),
        .init(name: "invalidConfiguration", state: "failure", appearance: "dark", locale: "en"),
        .init(name: "readyToStart", state: "permissionRequired", appearance: "dark", locale: "en"),
      ]
    )
  }

  @MainActor
  func testTUNTransitionVisualMatrix() throws {
    try capture(
      scenarios: [
        "preparingTarget", "disablingSystemProxy", "stoppingSource",
        "startingPrivilegedBackend", "connectingController", "waitingForInterface",
        "verifyingRoutes", "verifyingDNS", "committing",
      ].map {
        .init(name: $0, state: "transitioning", appearance: "dark", locale: "en")
      }
        + [
          .init(name: "runningSuccess", state: "transitioning", appearance: "dark", locale: "en")
        ]
    )
  }

  @MainActor
  func testTUNRecoveryVisualMatrix() throws {
    try capture(
      scenarios: [
        "startFailureRollbackSucceeded", "verificationFailureRollbackSucceeded",
        "rollbackFailed", "recoveryPreflight", "recoveryInProgress",
        "recoverySucceeded", "recoveryFailed",
      ].map {
        .init(name: $0, state: "rollbackFailed", appearance: "dark", locale: "en")
      }
    )
  }

  @MainActor
  func testTUNLayoutLocalizationAccessibilityMatrix() throws {
    try capture(
      scenarios: [
        .init(name: "minimum720Chinese", state: "loading", appearance: "dark", locale: "zh-Hans"),
        .init(name: "default780English", state: "loading", appearance: "light", locale: "en"),
        .init(name: "increaseContrast", state: "loading", appearance: "light", locale: "en"),
        .init(name: "reduceMotion", state: "loading", appearance: "dark", locale: "en"),
        .init(name: "pseudoLocale", state: "loading", appearance: "light", locale: "en"),
        .init(name: "doubleLength", state: "loading", appearance: "light", locale: "en"),
        .init(name: "voiceOverCurrentStep", state: "loading", appearance: "light", locale: "en"),
        .init(name: "keyboardStates", state: "loading", appearance: "light", locale: "en"),
      ]
    )
  }

  @MainActor
  private func capture(scenarios: [Scenario]) throws {
    for scenario in scenarios {
      try XCTContext.runActivity(named: scenario.name) { activity in
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        defer {
          VelaUITestIsolation.terminate(
            app,
            clearingPreferenceDomain: preferencesDomain
          )
        }
        app.launchArguments =
          velaIsolatedUITestLaunchArguments(
            page: "tunFlow",
            state: scenario.state,
            appearance: scenario.appearance,
            locale: scenario.locale,
            window: "1280x820",
            inspector: "na"
          ) + ["-VelaTunScenario", scenario.name]
        app.launch()
        app.activate()

        openSettings(in: app)
        let networkSettings =
          app.descendants(matching: .any)["settings.detail.coreNetwork"].firstMatch
        XCTAssertTrue(networkSettings.waitForExistence(timeout: 4))
        let tunAction = app.descendants(matching: .any)["settings.action.tun"].firstMatch
        XCTAssertTrue(tunAction.waitForExistence(timeout: 4))
        tunAction.click()

        let fixture = app.descendants(matching: .any)["tun.fixture.\(scenario.name)"].firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 4))
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 4))

        let attachment = XCTAttachment(screenshot: sheet.screenshot())
        attachment.name = "TUN-\(scenario.name)-current"
        attachment.lifetime = .keepAlways
        activity.add(attachment)

        if scenario.name == "keyboardStates" {
          XCTAssertTrue(
            app.descendants(matching: .any)["tun.dismissAction"].firstMatch.exists
          )
          XCTAssertTrue(
            app.descendants(matching: .any)["tun.primaryAction"].firstMatch.exists
          )
        }
        if scenario.name == "voiceOverCurrentStep" {
          XCTAssertTrue(app.descendants(matching: .any)["tun.setup.progress"].exists)
        }
      }
    }
  }

  @MainActor
  private func openSettings(in app: XCUIApplication) {
    let settingsLink = app.descendants(matching: .any)["sidebar.settings"].firstMatch
    if settingsLink.waitForExistence(timeout: 4) {
      settingsLink.click()
    } else {
      app.typeKey(",", modifierFlags: .command)
    }
  }
}
