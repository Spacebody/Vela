import XCTest

final class VelaSettingsNativeFormsStateAuthorityUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
  }

  @MainActor
  func testLiquidGlassSettingsShellAndScopedGeneralState() throws {
    let session = try launch(
      SettingsScenario("loaded-general", category: "general", state: "loaded")
    )
    defer { session.terminate() }

    XCTAssertTrue(element("settings.detail.general", in: session.app).exists)
    XCTAssertTrue(element("settings.search", in: session.app).exists)
    XCTAssertTrue(element("settings.reset", in: session.app).exists)
    XCTAssertTrue(element("settings.detail.coreNetwork", in: session.app).exists)
  }

  @MainActor
  func testLaunchAtLoginFixtureRetainsAuthoritativeValueUntilInteraction() throws {
    let session = try launch(
      SettingsScenario("launch-on", category: "general", state: "loaded")
    )
    defer { session.terminate() }

    let toggle = element("settings.setting.launchAtLogin", in: session.app)
    XCTAssertTrue(toggle.exists)
    XCTAssertEqual(toggle.value as? NSNumber, NSNumber(value: true))
    toggle.click()
    XCTAssertEqual(toggle.value as? NSNumber, NSNumber(value: false))
  }

  @MainActor
  func testKeyboardContrastAndReduceMotionKeepAppearancePageReachable() throws {
    var scenario = SettingsScenario(
      "accessibility",
      category: "appearance",
      state: "loaded",
      appearance: "dark",
      locale: "zh-Hans"
    )
    scenario.additionalArguments = [
      "-NSIncreaseContrast", "YES",
      "-NSReduceMotion", "YES",
    ]
    let session = try launch(scenario)
    defer { session.terminate() }

    XCTAssertTrue(element("settings.detail.appearance", in: session.app).exists)
    XCTAssertTrue(element("settings.search", in: session.app).isEnabled)
    session.app.typeKey(.tab, modifierFlags: [])
    XCTAssertTrue(element("settings.window", in: session.app).exists)
  }

  @MainActor
  func testRequiredSettingsVisualStatesAndCategories() throws {
    for scenario in Self.visualScenarios {
      try XCTContext.runActivity(named: scenario.identifier) { _ in
        let session = try launch(scenario)
        defer { session.terminate() }

        if scenario.interaction == .disableLaunchAtLogin {
          element("settings.setting.launchAtLogin", in: session.app).click()
        }
        XCTAssertTrue(
          element("settings.detail.\(scenario.category)", in: session.app).exists
        )
        let attachment = XCTAttachment(screenshot: session.window.screenshot())
        attachment.name = "settings__\(scenario.identifier)__current.png"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }
  }

  @MainActor
  private func launch(_ scenario: SettingsScenario) throws -> SettingsSession {
    let app = XCUIApplication()
    let preferencesDomain = try VelaUITestIsolation.prepare()
    app.launchArguments =
      velaIsolatedUITestLaunchArguments(
        page: "settings",
        state: scenario.state,
        appearance: scenario.appearance,
        locale: scenario.locale,
        window: scenario.window,
        inspector: "na"
      ) + scenario.additionalArguments
    app.launch()
    app.activate()

    XCTAssertTrue(
      element("visual.ready.settings.\(scenario.state)", in: app)
        .waitForExistence(timeout: 10),
      "Settings fixture did not become ready for \(scenario.identifier)."
    )
    let settingsLink = element("sidebar.settings", in: app)
    if settingsLink.waitForExistence(timeout: 2) {
      settingsLink.click()
    } else if !element("settings.detail.general", in: app).exists {
      app.typeKey(",", modifierFlags: .command)
    }

    XCTAssertTrue(
      element("settings.detail.\(scenario.category)", in: app)
        .waitForExistence(timeout: 4)
    )

    let window =
      app.windows.allElementsBoundByIndex.first { candidate in
        candidate.frame.width > 0
          && candidate.frame.height > 0
          && candidate.descendants(matching: .any)["settings.detail.general"]
            .firstMatch.exists
      } ?? app.windows.firstMatch
    XCTAssertTrue(window.exists)
    return SettingsSession(
      app: app,
      window: window,
      preferencesDomain: preferencesDomain
    )
  }

  @MainActor
  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private static let visualScenarios: [SettingsScenario] = [
    .init("01-general-light-en", category: "general", state: "loaded"),
    .init("02-general-light-zh", category: "general", state: "loaded", locale: "zh-Hans"),
    .init("03-core-network", category: "coreNetwork", state: "loaded"),
    .init("04-profiles", category: "profiles", state: "loaded"),
    .init("05-appearance", category: "appearance", state: "loaded"),
    .init("06-diagnostics", category: "diagnostics", state: "loaded"),
    .init("07-permission-required", category: "general", state: "permissionRequired"),
    .init("08-pending-mutation", category: "general", state: "pendingMutation"),
    .init("09-partial-failure", category: "general", state: "partialFailure"),
    .init("10-failure", category: "general", state: "failure"),
    .init(
      "11-launch-toggle", category: "general", state: "loaded",
      interaction: .disableLaunchAtLogin),
  ]
}

private struct SettingsScenario {
  enum Interaction {
    case none
    case disableLaunchAtLogin
  }

  let identifier: String
  let category: String
  let state: String
  let appearance: String
  let locale: String
  let window: String
  let interaction: Interaction
  var additionalArguments: [String] = []

  init(
    _ identifier: String,
    category: String,
    state: String,
    appearance: String = "light",
    locale: String = "en",
    window: String = "1280x820",
    interaction: Interaction = .none
  ) {
    self.identifier = identifier
    self.category = category
    self.state = state
    self.appearance = appearance
    self.locale = locale
    self.window = window
    self.interaction = interaction
  }
}

@MainActor
private struct SettingsSession {
  let app: XCUIApplication
  let window: XCUIElement
  let preferencesDomain: String

  func terminate() {
    VelaUITestIsolation.terminate(app, clearingPreferenceDomain: preferencesDomain)
  }
}
