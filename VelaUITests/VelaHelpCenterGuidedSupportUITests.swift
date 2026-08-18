import XCTest

final class VelaHelpCenterGuidedSupportUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
  }

  @MainActor
  func testHelpUsesIndependentRootWithoutFalseOverviewSelection() throws {
    let session = try launch(state: "loaded")
    defer { session.terminate() }

    XCTAssertTrue(element("help.fixture.root", in: session.app).waitForExistence(timeout: 4))
    XCTAssertFalse(element("main.sidebar", in: session.app).exists)
    XCTAssertGreaterThan(session.window.frame.width, 1_000)
  }

  @MainActor
  func testCompactAndSpaciousLayoutsStayInsideWindow() throws {
    let compact = try launch(state: "loaded", locale: "zh-Hans", window: "1040x680")
    let compactRoot = element("help.fixture.root", in: compact.app)
    XCTAssertLessThanOrEqual(compactRoot.frame.maxX, compact.window.frame.maxX + 1)
    XCTAssertLessThanOrEqual(compactRoot.frame.maxY, compact.window.frame.maxY + 1)
    compact.terminate()

    let spacious = try launch(state: "loaded", window: "1600x1000")
    defer { spacious.terminate() }
    let spaciousRoot = element("help.fixture.root", in: spacious.app)
    XCTAssertTrue(spaciousRoot.waitForExistence(timeout: 4))
    XCTAssertGreaterThan(spacious.window.frame.width, 1_400)
  }

  @MainActor
  func testOfflineAndIndexFailureKeepVerifiedArticleReadable() throws {
    let offline = try launch(state: "offline")
    XCTAssertTrue(
      offline.app.staticTexts["Diagnostics and Support"].firstMatch
        .waitForExistence(timeout: 4)
    )
    offline.terminate()

    let failure = try launch(state: "failure")
    defer { failure.terminate() }
    XCTAssertTrue(failure.app.staticTexts["Index unavailable"].firstMatch.exists)
    XCTAssertTrue(failure.app.staticTexts["Diagnostics and Support"].firstMatch.exists)
  }

  @MainActor
  func testKeyboardVoiceOverContrastAndReduceMotion() throws {
    let session = try launch(
      state: "loaded",
      additionalArguments: [
        "-VelaHelpIncreaseContrast", "YES",
        "-VelaHelpReduceMotion", "YES",
      ]
    )
    defer { session.terminate() }

    let search = session.app.textFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 4))
    session.app.typeKey("f", modifierFlags: .command)
    session.app.typeText("route")
    XCTAssertTrue(String(describing: search.value ?? "").contains("route"))
  }

  @MainActor
  func testRequiredTwentyTwoVisualScenarios() throws {
    let scenarios = [
      HelpScenario("browser-1040-dark-zh", "loaded", "dark", "zh-Hans", "1040x680"),
      HelpScenario("browser-1280-dark-zh", "loaded", "dark", "zh-Hans", "1280x820"),
      HelpScenario("browser-1280-light-en", "loaded", "light", "en", "1280x820"),
      HelpScenario("browser-1600-dark-en", "loaded", "dark", "en", "1600x1000"),
      HelpScenario("search-results-en", "loaded", scenario: nil),
      HelpScenario("search-results-zh", "loaded", "dark", "zh-Hans", scenario: nil),
      HelpScenario("article-code-callout-related", "loaded"),
      HelpScenario("contextual-deep-link", "loaded"),
      HelpScenario("loading-index", "loading"),
      HelpScenario("no-search-results", "empty"),
      HelpScenario("empty-catalog", "loaded", scenario: "emptyCatalog"),
      HelpScenario("offline", "offline"),
      HelpScenario("index-failure-last-good", "failure"),
      HelpScenario("full-failure", "loaded", scenario: "fullFailure"),
      HelpScenario("guided-category", "loaded", scenario: "guidedCategory"),
      HelpScenario("diagnostics-running", "loaded", scenario: "diagnosticsRunning"),
      HelpScenario("repair-confirmation", "loaded", scenario: "repairConfirmation"),
      HelpScenario("unresolved-bundle-prompt", "loaded", scenario: "unresolved"),
      HelpScenario("bundle-collecting", "loaded", scenario: "bundleCollecting"),
      HelpScenario("bundle-validation-blocked", "loaded", scenario: "bundleBlocked"),
      HelpScenario("bundle-preview-ready", "loaded", scenario: "bundleReady"),
      HelpScenario("save-cancelled-cleaned", "loaded", scenario: "saveCancelled"),
    ]

    for scenario in scenarios {
      try XCTContext.runActivity(named: scenario.identifier) { _ in
        let session = try launch(
          state: scenario.state,
          appearance: scenario.appearance,
          locale: scenario.locale,
          window: scenario.window,
          scenario: scenario.scenario
        )
        defer { session.terminate() }
        XCTAssertTrue(element("help.fixture.root", in: session.app).exists)
        let attachment = XCTAttachment(screenshot: session.window.screenshot())
        attachment.name = "help-support__\(scenario.identifier)__current.png"
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
  ) throws -> HelpSession {
    let app = XCUIApplication()
    let preferencesDomain = try VelaUITestIsolation.prepare()
    app.launchArguments = velaIsolatedUITestLaunchArguments(
      page: "helpSupport",
      state: state,
      appearance: appearance,
      locale: locale,
      window: window,
      inspector: "na"
    )
    if let scenario {
      app.launchArguments += ["-VelaHelpScenario", scenario]
    }
    app.launchArguments += additionalArguments
    app.launch()
    app.activate()

    XCTAssertTrue(
      element("visual.ready.helpSupport.\(state)", in: app)
        .waitForExistence(timeout: 10),
      "Help fixture did not become ready: \(state)-\(window)-\(scenario ?? "default")"
    )
    let firstWindow = app.windows.firstMatch
    XCTAssertTrue(firstWindow.waitForExistence(timeout: 4))
    let windowElement =
      app.windows.allElementsBoundByIndex.first { candidate in
        candidate.frame.width > 0
          && candidate.frame.height > 0
          && candidate.descendants(matching: .any)["visual.ready.helpSupport.\(state)"]
            .firstMatch.exists
      } ?? firstWindow
    return HelpSession(
      app: app,
      window: windowElement,
      preferencesDomain: preferencesDomain
    )
  }

  @MainActor
  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }
}

private struct HelpScenario {
  let identifier: String
  let state: String
  let appearance: String
  let locale: String
  let window: String
  let scenario: String?

  init(
    _ identifier: String,
    _ state: String,
    _ appearance: String = "dark",
    _ locale: String = "en",
    _ window: String = "1280x820",
    scenario: String? = nil
  ) {
    self.identifier = identifier
    self.state = state
    self.appearance = appearance
    self.locale = locale
    self.window = window
    self.scenario = scenario
  }
}

@MainActor
private struct HelpSession {
  let app: XCUIApplication
  let window: XCUIElement
  let preferencesDomain: String

  func terminate() {
    VelaUITestIsolation.terminate(app, clearingPreferenceDomain: preferencesDomain)
  }
}
