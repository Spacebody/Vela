import AppKit
import ApplicationServices
import XCTest

final class VelaVisualSystemUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = try VelaUITestIsolation.requireDedicatedBundleIdentifier()
    }

    @MainActor
    func testVisualHarnessSmoke() throws {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = visualLaunchArguments(
            page: "overview",
            state: "offline",
            appearance: "light",
            locale: "en",
            window: "1280x820",
            inspector: "na"
        )
        app.launch()
        app.activate()

        _ = requireOverviewWindow(in: app, context: "Visual harness smoke")
    }

    @MainActor
    func testLightAndDarkWindowSizeMatrix() throws {
        let destinations = try registeredFixtureRoutes()
            .filter { $0.captureBoundary == .mainWindow }
            .flatMap(\.captureDestinations)
        let sizes = [
            VisualWindowScenario.SizePreset(
                argument: "1040x680",
                expected: CGSize(width: 1_040, height: 680)
            ),
            VisualWindowScenario.SizePreset(
                argument: "1280x820",
                expected: CGSize(width: 1_280, height: 820)
            ),
            VisualWindowScenario.SizePreset(
                argument: "1600x1000",
                expected: CGSize(width: 1_600, height: 1_000)
            ),
        ]

        for locale in ["en", "zh-Hans"] {
            for appearance in ["light", "dark"] {
                for size in sizes {
                    let scenario = VisualWindowScenario(
                        appearance: appearance,
                        locale: locale,
                        size: size
                    )
                    try XCTContext.runActivity(named: scenario.name) { _ in
                        try verify(scenario, destinations: destinations)
                    }
                }
            }
        }
    }

    @MainActor
    func testMenuBarBaselineEnglishLight() throws {
        try captureMenuBarBaseline(appearance: "light", locale: "en")
    }

    @MainActor
    func testNativeMenuBarQuickControlMatrix() throws {
        XCTAssertEqual(
            NativeMenuBarScenario.all.count,
            42,
            "The native menu-bar recovery matrix must retain all 42 approved states."
        )
        XCTAssertEqual(
            Set(NativeMenuBarScenario.all.map(\.name)).count,
            42,
            "Menu-bar visual scenario names must be unique."
        )

        for scenario in NativeMenuBarScenario.all {
            try XCTContext.runActivity(named: scenario.name) { _ in
                try captureNativeMenuBarScenario(scenario)
            }
        }
    }

    @MainActor
    func testSettingsBaselineEnglishLight() throws {
        try captureSettingsBaseline(appearance: "light", locale: "en")
    }

    @MainActor
    func testTunFlowBaselineEnglishLight() throws {
        try captureTunFlowBaseline(appearance: "light", locale: "en")
    }

    @MainActor
    func testRemainingLocalizedAndDarkMenuBarBaselines() throws {
        try captureRemainingSurfaceScenarios(.menuBar)
    }

    @MainActor
    func testRemainingLocalizedAndDarkSettingsBaselines() throws {
        try captureRemainingSurfaceScenarios(.settings)
    }

    @MainActor
    func testRemainingLocalizedAndDarkTunFlowBaselines() throws {
        try captureRemainingSurfaceScenarios(.tunFlow)
    }

    @MainActor
    private func captureRemainingSurfaceScenarios(_ surface: VisualSurface) throws {
        for (locale, appearance) in [
            ("en", "dark"),
            ("zh-Hans", "light"),
            ("zh-Hans", "dark"),
        ] {
            try XCTContext.runActivity(
                named: "Surface baseline · \(locale) · \(appearance)"
            ) { _ in
                switch surface {
                case .menuBar:
                    try captureMenuBarBaseline(appearance: appearance, locale: locale)
                case .settings:
                    try captureSettingsBaseline(appearance: appearance, locale: locale)
                case .tunFlow:
                    try captureTunFlowBaseline(appearance: appearance, locale: locale)
                }
            }
        }
    }

    @MainActor
    private func verify(
        _ scenario: VisualWindowScenario,
        destinations: [VisualDestination]
    ) throws {
        try captureMainSurfaceMatrix(
            scenario: scenario,
            destinations: destinations
        )
    }

    private func registeredFixtureRoutes(
        file: StaticString = #filePath
    ) throws -> [VisualFixtureRoute] {
        try VisualFixtureRegistry.load(relativeTo: file).routes
    }

    private func destinations(
        for boundary: VisualCaptureBoundary,
        file: StaticString = #filePath
    ) throws -> [VisualDestination] {
        try registeredFixtureRoutes(file: file)
            .filter { $0.captureBoundary == boundary }
            .flatMap(\.captureDestinations)
    }

    @MainActor
    private func captureMenuBarBaseline(appearance: String, locale: String) throws {
        for destination in try destinations(for: .menu) {
            try XCTContext.runActivity(
                named: "\(destination.fixtureID) · \(locale) · \(appearance)"
            ) { _ in
                try captureMenuBarFixture(
                    destination,
                    appearance: appearance,
                    locale: locale
                )
            }
        }
    }

    @MainActor
    private func captureNativeMenuBarScenario(
        _ scenario: NativeMenuBarScenario
    ) throws {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = visualLaunchArguments(
            page: "menuBar",
            state: "loaded",
            appearance: scenario.appearance,
            locale: scenario.locale,
            window: "1280x820",
            inspector: "na"
        ) + ["-VelaMenuBarScenario", scenario.name]
        if scenario.name == "increaseContrastStatus" {
            app.launchArguments += ["-NSAccessibilityEnhancedContrastEnabled", "YES"]
        }
        app.launch()
        app.activate()

        let menuBarItem = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ AND title BEGINSWITH[c] %@",
                "menubar.open",
                "Vela"
            )
        ).firstMatch
        XCTAssertTrue(
            menuBarItem.waitForExistence(timeout: 4),
            "The StatusItem did not expose a Vela VoiceOver label for \(scenario.name)."
        )
        if scenario.name == "voiceOverStatus" {
            let dynamicStatusItem = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier == %@ AND title BEGINSWITH[c] %@ AND title != %@",
                    "menubar.open",
                    "Vela",
                    "Vela"
                )
            ).firstMatch
            XCTAssertTrue(
                dynamicStatusItem.exists,
                "VoiceOver must announce the dynamic runtime state, not only the app name."
            )
        }
        let statusAttachment = XCTAttachment(screenshot: menuBarItem.screenshot())
        statusAttachment.name = "menuBar__\(scenario.name)__statusItem.png"
        statusAttachment.lifetime = .keepAlways
        add(statusAttachment)

        let menu = menuBarItem.menus.firstMatch
        menuBarItem.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
        if !waitForNonEmptyFrame(menu, timeout: 2) {
            let diagnostic = inspectVelaMenuBarStatusItemUsingAccessibility(
                for: app,
                performPress: true
            )
            attachMenuBarAXDiagnostic(diagnostic.report, state: scenario.name)
            XCTAssertTrue(diagnostic.succeeded, diagnostic.report)
        }
        XCTAssertTrue(
            waitForNonEmptyFrame(menu, timeout: 3),
            "The native menu remained closed for \(scenario.name)."
        )
        let settingsPrefix = scenario.locale == "zh-Hans" ? "设置" : "Settings"
        XCTAssertTrue(
            menu.menuItems.matching(
                NSPredicate(format: "title BEGINSWITH %@", settingsPrefix)
            ).firstMatch.waitForExistence(timeout: 2),
            "Settings was missing from the native menu for \(scenario.name)."
        )
        let tunItem = if scenario.name == "keyboardDisabled" {
            menu.menuItems.matching(
                NSPredicate(format: "title == %@", "TUN — Switching…")
            ).firstMatch
        } else {
            menu.menuItems.matching(
                NSPredicate(format: "title CONTAINS %@", "TUN")
            ).firstMatch
        }
        XCTAssertTrue(
            tunItem.waitForExistence(timeout: 2),
            "The capability-aware TUN row was missing for \(scenario.name)."
        )
        if scenario.name == "keyboardDisabled" {
            XCTAssertFalse(
                tunItem.isEnabled,
                "Conflicting backend controls must remain disabled during a transition."
            )
        }

        let attachment = XCTAttachment(screenshot: menu.screenshot())
        attachment.name = "menuBar__\(scenario.name)__\(scenario.appearance)__\(scenario.locale).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func captureMenuBarFixture(
        _ destination: VisualDestination,
        appearance: String,
        locale: String
    ) throws {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = visualLaunchArguments(
            page: destination.page,
            state: destination.state,
            appearance: appearance,
            locale: locale,
            window: "1280x820",
            inspector: destination.inspector
        )
        app.launch()
        app.activate()

        let menuBarItem = app.descendants(matching: .any)["menubar.open"].firstMatch
        XCTAssertTrue(menuBarItem.waitForExistence(timeout: 4))

        // SwiftUI's MenuBarExtra exposes its dormant AXMenu even while it has
        // a zero-sized frame. Click the StatusItem itself and wait for the
        // menu to receive a real frame before taking a screenshot. On some
        // macOS hosts XCTest's synthesized click is dropped while focus moves
        // from the app window to the menu bar, so the UI-test-only fallback
        // invokes the StatusItem's public AXPress action.
        let menuBarMenu = menuBarItem.menus.firstMatch
        menuBarItem.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
        let openedByXCUI = waitForNonEmptyFrame(menuBarMenu, timeout: 2)
        if !openedByXCUI {
            let diagnostic = inspectVelaMenuBarStatusItemUsingAccessibility(
                for: app,
                performPress: true
            )
            attachMenuBarAXDiagnostic(
                diagnostic.report,
                state: destination.state
            )
            XCTAssertTrue(
                diagnostic.succeeded,
                "Could not invoke the Vela menu-bar StatusItem AXPress action.\n"
                    + diagnostic.report
            )
            XCTAssertTrue(
                waitForNonEmptyFrame(menuBarMenu, timeout: 3),
                "The Vela menu-bar menu did not become visible after AXPress."
            )
        }

        // AppKit recreates SwiftUI MenuBarExtra rows as native NSMenuItems.
        // Their SwiftUI accessibility identifiers do not survive that bridge,
        // so assert the native role and localized title exposed by AX instead.
        let settingsTitle = locale == "zh-Hans" ? "设置" : "Settings"
        let settingsItem = menuBarMenu.menuItems.matching(
            NSPredicate(format: "title BEGINSWITH %@", settingsTitle)
        ).firstMatch
        XCTAssertTrue(
            settingsItem.waitForExistence(timeout: 2),
            "The visible Vela menu did not expose its localized Settings command."
        )

        let tunItem = menuBarMenu.menuItems.matching(
            NSPredicate(format: "title CONTAINS %@", "TUN")
        ).firstMatch
        XCTAssertTrue(
            tunItem.waitForExistence(timeout: 2),
            "The visible Vela menu did not expose its TUN control."
        )

        // Capture immediately after the single successful visibility wait.
        // A second wait can move XCTest's focus back to the app and dismiss
        // the system menu even though it was already visibly open.
        attach(
            menuBarMenu.screenshot(),
            page: destination.page,
            state: destination.state,
            appearance: appearance,
            locale: locale,
            inspector: destination.inspector
        )

        // Preserve a staged, read-only AX audit even when XCUI's click worked.
        // Do not AXPress here: pressing the same status item would close the
        // menu before the screenshot boundary can be inspected.
        if openedByXCUI {
            let diagnostic = inspectVelaMenuBarStatusItemUsingAccessibility(
                for: app,
                performPress: false
            )
            attachMenuBarAXDiagnostic(
                diagnostic.report,
                state: destination.state
            )
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func captureSettingsBaseline(appearance: String, locale: String) throws {
        let settingsDestinations = try destinations(for: .mainWindow)
            .filter { $0.page == "settings" }
        for destination in settingsDestinations {
            try XCTContext.runActivity(
                named: "\(destination.fixtureID) · \(locale) · \(appearance)"
            ) { _ in
                try captureSettingsFixture(
                    destination,
                    appearance: appearance,
                    locale: locale
                )
            }
        }
    }

    @MainActor
    private func captureSettingsFixture(
        _ destination: VisualDestination,
        appearance: String,
        locale: String
    ) throws {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = visualLaunchArguments(
            page: destination.page,
            state: destination.state,
            appearance: appearance,
            locale: locale,
            window: "1280x820",
            inspector: destination.inspector
        )
        app.launch()
        app.activate()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 4))
        XCTAssertTrue(
            mainWindow.descendants(matching: .any)[destination.readyIdentifier]
                .firstMatch
                .waitForExistence(timeout: 4),
            "\(destination.readyIdentifier) did not appear inside the main window."
        )
        attach(
            mainWindow.screenshot(),
            page: destination.page,
            state: destination.state,
            appearance: appearance,
            locale: locale,
            inspector: destination.inspector
        )
    }

    @MainActor
    private func captureTunFlowBaseline(appearance: String, locale: String) throws {
        for destination in try destinations(for: .sheet) {
            try XCTContext.runActivity(
                named: "\(destination.fixtureID) · \(locale) · \(appearance)"
            ) { _ in
                try captureTunFlowFixture(
                    destination,
                    appearance: appearance,
                    locale: locale
                )
            }
        }
    }

    @MainActor
    private func captureTunFlowFixture(
        _ destination: VisualDestination,
        appearance: String,
        locale: String
    ) throws {
        let app = XCUIApplication()
        let preferencesDomain = try VelaUITestIsolation.prepare()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: preferencesDomain
            )
        }
        app.launchArguments = visualLaunchArguments(
            page: destination.page,
            state: destination.state,
            appearance: appearance,
            locale: locale,
            window: "1280x820",
            inspector: destination.inspector
        )
        app.launch()
        app.activate()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 4))
        let settingsLink = app.descendants(matching: .any)["sidebar.settings"].firstMatch
        if settingsLink.waitForExistence(timeout: 4) {
            settingsLink.click()
        } else {
            app.typeKey(",", modifierFlags: .command)
        }

        _ = requireSettingsWindowOrSurface(
            in: app,
            context: "TUN flow · \(locale) · \(appearance)"
        )

        let networkSettings = app.descendants(matching: .any)[
            "settings.detail.coreNetwork"
        ].firstMatch
        XCTAssertTrue(networkSettings.waitForExistence(timeout: 3))
        let openTunSetup = app.descendants(matching: .any)[
            "settings.action.tun"
        ].firstMatch
        XCTAssertTrue(
            openTunSetup.waitForExistence(timeout: 3),
            "The TUN setup action did not appear in the current Settings page."
        )
        app.activate()
        openTunSetup.click()

        let onboarding = app.descendants(matching: .any)["tun.onboarding"].firstMatch
        XCTAssertTrue(onboarding.waitForExistence(timeout: 4))
        let onboardingSheet = app.sheets.firstMatch
        XCTAssertTrue(
            waitForNonEmptyFrame(onboardingSheet, timeout: 3),
            "The TUN onboarding sheet did not expose a visible screenshot boundary."
        )
        XCTAssertTrue(
            onboardingSheet.descendants(matching: .any)[
                destination.readyIdentifier
            ].firstMatch.waitForExistence(timeout: 4),
            "\(destination.readyIdentifier) did not appear inside the TUN sheet boundary."
        )
        attach(
            onboardingSheet.screenshot(),
            page: destination.page,
            state: destination.state,
            appearance: appearance,
            locale: locale,
            inspector: destination.inspector
        )
    }

    @MainActor
    private func captureMainSurfaceMatrix(
        scenario: VisualWindowScenario,
        destinations: [VisualDestination]
    ) throws {
        let expected = scenario.size.expected
        let frameAccuracy: CGFloat = 1

        for destination in destinations {
            try XCTContext.runActivity(
                named: "\(scenario.name) · \(destination.fixtureID) · \(destination.inspector)"
            ) { _ in
                let app = XCUIApplication()
                let preferencesDomain = try VelaUITestIsolation.prepare()
                defer {
                    VelaUITestIsolation.terminate(
                        app,
                        clearingPreferenceDomain: preferencesDomain
                    )
                }
                app.launchArguments = visualLaunchArguments(
                    page: destination.page,
                    state: destination.state,
                    appearance: scenario.appearance,
                    locale: scenario.locale,
                    window: scenario.size.argument,
                    inspector: destination.inspector
                )
                app.launch()
                app.activate()

                let mainWindow = requireFixtureWindow(
                    in: app,
                    destination: destination,
                    context: scenario.name
                )
                let frameDidSettle = waitForStableWindowFrame(
                    mainWindow,
                    expected: expected,
                    accuracy: frameAccuracy
                )
                XCTAssertTrue(
                    frameDidSettle,
                    "The \(destination.page) window did not settle at the requested size for \(scenario.name); last frame=\(mainWindow.frame)."
                )
                let frame = mainWindow.frame
                XCTAssertEqual(
                    frame.width,
                    expected.width,
                    accuracy: frameAccuracy,
                    "Unexpected \(destination.page) width for \(scenario.name)."
                )
                XCTAssertEqual(
                    frame.height,
                    expected.height,
                    accuracy: frameAccuracy,
                    "Unexpected \(destination.page) height for \(scenario.name)."
                )
                let screenshot = mainWindow.screenshot()
                assertScreenshot(
                    screenshot,
                    matchesWindowFrame: frame,
                    context: "\(destination.page) in \(scenario.name)"
                )
                attach(
                    screenshot,
                    page: destination.page,
                    state: destination.state,
                    appearance: scenario.appearance,
                    locale: scenario.locale,
                    inspector: destination.inspector
                )
            }
        }
    }

    @MainActor
    private func requireFixtureWindow(
        in app: XCUIApplication,
        destination: VisualDestination,
        context: String
    ) -> XCUIElement {
        let firstWindow = app.windows.firstMatch
        XCTAssertTrue(
            firstWindow.waitForExistence(timeout: 4),
            "The main window did not appear for \(destination.fixtureID) in \(context)."
        )
        let readyMarker = app.descendants(matching: .any)[
            destination.readyIdentifier
        ].firstMatch
        XCTAssertTrue(
            readyMarker.waitForExistence(timeout: 5),
            "\(destination.readyIdentifier) did not appear for \(context)."
        )

        // MenuBarExtra and other SwiftUI scenes can contribute additional
        // AXWindow nodes whose ordering changes with the detail hierarchy.
        // Capture the finite window that owns the fixture marker instead of
        // relying on whichever scene happens to sort first.
        if let fixtureWindow = app.windows.allElementsBoundByIndex.first(
            where: { window in
                hasNonEmptyFiniteFrame(window)
                    && window.descendants(matching: .any)[
                        destination.readyIdentifier
                    ].firstMatch.exists
            }
        ) {
            return fixtureWindow
        }

        XCTAssertTrue(
            false,
            "No finite AXWindow contained \(destination.readyIdentifier) for \(context)."
        )
        return firstWindow
    }

    @MainActor
    private func waitForStableWindowFrame(
        _ window: XCUIElement,
        expected: CGSize,
        accuracy: CGFloat,
        timeout: TimeInterval = 3,
        stableDuration: TimeInterval = 0.35
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var stableSince: Date?

        while Date() < deadline {
            let frame = window.frame
            let matches = abs(frame.width - expected.width) <= accuracy
                && abs(frame.height - expected.height) <= accuracy
            if matches {
                stableSince = stableSince ?? Date()
                if let stableSince,
                    Date().timeIntervalSince(stableSince) >= stableDuration
                {
                    return true
                }
            } else {
                stableSince = nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    @MainActor
    private func assertScreenshot(
        _ screenshot: XCUIScreenshot,
        matchesWindowFrame frame: CGRect,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pixels = screenshotPixelSize(screenshot)
        guard frame.width > 0, frame.height > 0 else {
            XCTFail("The window frame was empty for \(context).", file: file, line: line)
            return
        }

        // macOS can expose fractional backing scales when a window spans
        // displays or the host uses scaled display modes. The boundary is
        // valid when both axes use the same finite backing scale; requiring
        // exactly 1x or 2x rejects otherwise-correct element screenshots.
        let horizontalScale = pixels.width / frame.width
        let verticalScale = pixels.height / frame.height
        let scaleIsFinite = horizontalScale.isFinite && verticalScale.isFinite
        let scaleIsPlausible = (0.5 ... 3).contains(horizontalScale)
            && (0.5 ... 3).contains(verticalScale)
        let axesAgree = abs(horizontalScale - verticalScale) <= 0.03
        XCTAssertTrue(
            scaleIsFinite && scaleIsPlausible && axesAgree,
            "Screenshot boundary \(pixels.width)x\(pixels.height) did not match "
                + "window frame \(frame.width)x\(frame.height) at one consistent backing scale "
                + "(x=\(horizontalScale), y=\(verticalScale)) for \(context).",
            file: file,
            line: line
        )
    }

    @MainActor
    private func requireOverviewWindow(
        in app: XCUIApplication,
        context: String
    ) -> XCUIElement {
        let firstWindow = app.windows.firstMatch
        if !firstWindow.waitForExistence(timeout: 4) {
            app.activate()
            app.typeKey("o", modifierFlags: .command)
        }
        XCTAssertTrue(
            firstWindow.waitForExistence(timeout: 4),
            "The main window did not appear for \(context)."
        )

        let overviewScreen = app.descendants(matching: .any)["screen.overview"].firstMatch
        if !overviewScreen.exists {
            app.activate()
            let overviewItem = app.descendants(matching: .any)[
                "sidebar.overview"
            ].firstMatch
            if overviewItem.waitForExistence(timeout: 2) {
                overviewItem.click()
            }
        }
        XCTAssertTrue(
            overviewScreen.waitForExistence(timeout: 4),
            "screen.overview did not appear for \(context)."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["visual.ready.overview.offlineNoConfiguration"]
                .firstMatch
                .waitForExistence(timeout: 4),
            "The deterministic Overview fixture was not ready for \(context)."
        )
        return firstWindow
    }

    @MainActor
    private func requireSettingsWindowOrSurface(
        in app: XCUIApplication,
        context: String
    ) -> XCUIElement {
        let settingsSurface = app.descendants(matching: .any)["settings.window"]
            .firstMatch
        let headerAnchor = app.descendants(matching: .any)["settings.categoryHeader"]
            .firstMatch
        let networkAnchor = app.descendants(matching: .any)["settings.detail.coreNetwork"]
            .firstMatch
        XCTAssertTrue(
            settingsSurface.waitForExistence(timeout: 2)
                || headerAnchor.waitForExistence(timeout: 1)
                || networkAnchor.waitForExistence(timeout: 1),
            "The Settings surface did not appear for \(context)."
        )

        // `settings.window` identifies the Settings destination inside Vela's
        // main window. SwiftUI can flatten that root into AX with a zero or
        // infinite frame, so use it only as a containment hint and return the
        // finite application window that owns it.
        let containingWindow = app.windows.allElementsBoundByIndex.first { window in
            guard hasNonEmptyFiniteFrame(window) else { return false }
            return window.descendants(matching: .any)["settings.window"]
                    .firstMatch.exists
                || window.descendants(matching: .any)["settings.categoryHeader"]
                    .firstMatch.exists
                || window.descendants(matching: .any)["settings.detail.coreNetwork"]
                    .firstMatch.exists
        }
        if let containingWindow {
            return containingWindow
        }

        XCTAssertTrue(
            false,
            "No finite Settings AXWindow was available for \(context); "
                + "settings.window frame=\(settingsSurface.frame)."
        )
        return app.windows.firstMatch
    }

    @MainActor
    private func waitForNonEmptyFrame(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement, element.exists else {
                    return false
                }
                return self.hasNonEmptyFiniteFrame(element)
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func hasNonEmptyFiniteFrame(_ element: XCUIElement) -> Bool {
        let frame = element.frame
        return frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    /// UI-test-only fallback for macOS hosts that drop XCUI's first click on
    /// a SwiftUI MenuBarExtra. This uses only public Accessibility APIs and
    /// targets the launched Vela process's extras menu bar by identifier.
    @MainActor
    private func inspectVelaMenuBarStatusItemUsingAccessibility(
        for app: XCUIApplication,
        performPress: Bool
    ) -> MenuBarAXDiagnostic {
        var trace = [
            "stage=begin",
            "mode=\(performPress ? "press" : "readOnlyAudit")",
            "xcuiState=\(app.state.rawValue)",
        ]
        let processMatch = exactBuiltProductProcessMatch(for: app)
        trace.append(contentsOf: processMatch.trace)
        guard let processIdentifier = processMatch.processIdentifier else {
            trace.append("stage=processMatch failed")
            return MenuBarAXDiagnostic(succeeded: false, report: trace.joined(separator: "\n"))
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        var extrasValue: CFTypeRef?
        let extrasResult = AXUIElementCopyAttributeValue(
            application,
            kAXExtrasMenuBarAttribute as CFString,
            &extrasValue
        )
        trace.append("stage=extrasMenuBar result=\(extrasResult.rawValue)")
        guard extrasResult == .success,
            let extrasValue,
            CFGetTypeID(extrasValue) == AXUIElementGetTypeID()
        else {
            trace.append("stage=extrasMenuBar failed")
            return MenuBarAXDiagnostic(succeeded: false, report: trace.joined(separator: "\n"))
        }
        let extrasMenuBar = unsafeDowncast(extrasValue, to: AXUIElement.self)

        let menuBarDescendants = axDescendants(of: extrasMenuBar, maximumDepth: 3)
        trace.append("stage=descendants count=\(menuBarDescendants.count)")
        if menuBarDescendants.isEmpty {
            trace.append("descendants=<empty>")
        } else {
            for (index, child) in menuBarDescendants.prefix(20).enumerated() {
                trace.append("descendant[\(index)]=\(axAuditSummary(child))")
            }
        }
        let statusItem = menuBarDescendants.first(where: { child in
            axString(
                attribute: kAXIdentifierAttribute as CFString,
                from: child
            ) == "menubar.open"
        }) ?? menuBarDescendants.first(where: { child in
            // SwiftUI's StatusItem identifier is visible through XCUI, but
            // some macOS releases omit kAXIdentifier from the raw AX node.
            // This fallback is still scoped to the exact launched process's
            // extras menu bar, and accepts only a pressable menu-bar item.
            axString(
                attribute: kAXRoleAttribute as CFString,
                from: child
            ) == (kAXMenuBarItemRole as String)
                && axSupportsPress(child)
        })
        guard let statusItem else {
            trace.append("stage=statusItem failed")
            return MenuBarAXDiagnostic(succeeded: false, report: trace.joined(separator: "\n"))
        }

        trace.append("stage=statusItem selected=\(axAuditSummary(statusItem))")
        guard performPress else {
            trace.append("stage=axPress skipped")
            return MenuBarAXDiagnostic(
                succeeded: true,
                report: trace.joined(separator: "\n")
            )
        }
        let pressResult = AXUIElementPerformAction(
            statusItem,
            kAXPressAction as CFString
        )
        trace.append("stage=axPress result=\(pressResult.rawValue)")
        return MenuBarAXDiagnostic(
            succeeded: pressResult == .success,
            report: trace.joined(separator: "\n")
        )
    }

    /// Accept only the process whose canonical bundle URL is the Vela.app next
    /// to this UI test runner in Built Products/Debug. An installed or
    /// independently running Vela with the same bundle identifier cannot be
    /// selected by this fallback.
    @MainActor
    private func exactBuiltProductProcessMatch(
        for app: XCUIApplication
    ) -> BuiltProductProcessMatch {
        var trace = ["stage=processMatch"]
        guard app.state != .notRunning else {
            trace.append("processState=notRunning")
            return BuiltProductProcessMatch(processIdentifier: nil, trace: trace)
        }

        let expectedBundleURL = VelaUITestIsolation.builtApplicationURL()
        trace.append("expectedBundleURL=\(expectedBundleURL.path)")
        guard let bundleIdentifier = Bundle(url: expectedBundleURL)?.bundleIdentifier
        else {
            trace.append("bundleIdentifier=<unavailable>")
            return BuiltProductProcessMatch(processIdentifier: nil, trace: trace)
        }
        trace.append("bundleIdentifier=\(bundleIdentifier)")

        let sameIdentifierProcesses = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        let exactMatches = sameIdentifierProcesses.filter { runningApplication in
            guard let bundleURL = runningApplication.bundleURL else { return false }
            return canonicalFileURL(bundleURL) == expectedBundleURL
        }
        let exactPIDs = exactMatches.map(\.processIdentifier).sorted()
        trace.append("sameBundleIdentifierCount=\(sameIdentifierProcesses.count)")
        trace.append("exactCanonicalBundleURLCount=\(exactMatches.count)")
        trace.append("exactPIDs=\(exactPIDs.map(String.init).joined(separator: ","))")
        guard exactMatches.count == 1 else {
            return BuiltProductProcessMatch(processIdentifier: nil, trace: trace)
        }
        return BuiltProductProcessMatch(
            processIdentifier: exactMatches[0].processIdentifier,
            trace: trace
        )
    }

    private func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
            let children = value as? [AXUIElement]
        else {
            return []
        }
        return children
    }

    private func axDescendants(
        of root: AXUIElement,
        maximumDepth: Int
    ) -> [AXUIElement] {
        guard maximumDepth > 0 else { return [] }
        let children = axChildren(of: root)
        return children + children.flatMap { child in
            axDescendants(of: child, maximumDepth: maximumDepth - 1)
        }
    }

    private func axSupportsPress(_ element: AXUIElement) -> Bool {
        axActionNames(element).contains(kAXPressAction as String)
    }

    private func axActionNames(_ element: AXUIElement) -> [String] {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
            let actionNames = actions as? [String]
        else {
            return []
        }
        return actionNames
    }

    private func axAuditSummary(_ element: AXUIElement) -> String {
        let role = axString(
            attribute: kAXRoleAttribute as CFString,
            from: element
        ) ?? "<nil>"
        let identifier = axString(
            attribute: kAXIdentifierAttribute as CFString,
            from: element
        ) ?? "<nil>"
        let title = axString(
            attribute: kAXTitleAttribute as CFString,
            from: element
        ) ?? "<nil>"
        let description = axString(
            attribute: kAXDescriptionAttribute as CFString,
            from: element
        ) ?? "<nil>"
        let help = axString(
            attribute: kAXHelpAttribute as CFString,
            from: element
        ) ?? "<nil>"
        let value = axString(
            attribute: kAXValueAttribute as CFString,
            from: element
        ) ?? "<nil>"
        let actions = axActionNames(element)
        return "role=\(role) identifier=\(identifier) title=\(title) description=\(description) help=\(help) value=\(value) actions=[\(actions.joined(separator: ","))]"
    }

    private func axString(
        attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success
        else {
            return nil
        }
        return value as? String
    }

    private func attachMenuBarAXDiagnostic(_ report: String, state: String) {
        let attachment = XCTAttachment(string: report)
        attachment.name = "menuBar__\(state)__ax-diagnostic.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attach(
        _ screenshot: XCUIScreenshot,
        page: String,
        state: String,
        appearance: String,
        locale: String,
        inspector: String
    ) {
        let attachment = XCTAttachment(screenshot: screenshot)
        let pixels = screenshotPixelSize(screenshot)
        let width = Int(pixels.width)
        let height = Int(pixels.height)
        attachment.name = "\(page)__\(state)__\(appearance)__\(locale)__\(width)x\(height)__\(inspector).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func screenshotPixelSize(_ screenshot: XCUIScreenshot) -> CGSize {
        let representation = screenshot.image.representations.max { left, right in
            left.pixelsWide * left.pixelsHigh < right.pixelsWide * right.pixelsHigh
        }
        let width = representation?.pixelsWide ?? Int(screenshot.image.size.width)
        let height = representation?.pixelsHigh ?? Int(screenshot.image.size.height)
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private func visualLaunchArguments(
        page: String,
        state: String,
        appearance: String,
        locale: String,
        window: String,
        inspector: String
    ) -> [String] {
        velaIsolatedUITestLaunchArguments(
            page: page,
            state: state,
            appearance: appearance,
            locale: locale,
            window: window,
            inspector: inspector
        )
    }

}

private struct NativeMenuBarScenario: Sendable {
    let name: String
    let appearance: String
    let locale: String

    static let all: [Self] = [
        .init("connectedSystemProxyLight", appearance: "light"),
        .init("connectedSystemProxyDark"),
        .init("connectedTUNStatus"),
        .init("transitioningStatus"),
        .init("needsAttentionStatus"),
        .init("offStatus"),
        .init("recoveryStatus"),
        .init("increaseContrastStatus"),
        .init("voiceOverStatus"),
        .init("loadedSystemProxyDarkEnglish"),
        .init("loadedSystemProxyLightChinese", appearance: "light", locale: "zh-Hans"),
        .init("loadedTUNDarkEnglish"),
        .init("engineOnlyDarkChinese", locale: "zh-Hans"),
        .init("noProfile"),
        .init("paused"),
        .init("longNames"),
        .init("trafficSummary"),
        .init("tunNotInstalled"),
        .init("tunNeedsApproval"),
        .init("helperConnecting"),
        .init("helperIncompatible"),
        .init("tunRecoveryRequired"),
        .init("switchSystemProxyToTUN"),
        .init("switchTUNToSystemProxy"),
        .init("partialFailure"),
        .init("stale"),
        .init("runtimeFailure"),
        .init("controllerOfflineLastGood"),
        .init("cleanupFailure"),
        .init("quitPending"),
        .init("diagnosticsAction"),
        .init("sceneSubmenu"),
        .init("proxySubmenu"),
        .init("pauseSubmenu"),
        .init("settingsSingleWindow"),
        .init("mainWindowReopen"),
        .init("englishMaxLabel"),
        .init("chineseMaxLabel", locale: "zh-Hans"),
        .init("pseudo"),
        .init("doubleLength"),
        .init("menuWidthAX"),
        .init("keyboardDisabled"),
    ]

    private init(
        _ name: String,
        appearance: String = "dark",
        locale: String = "en"
    ) {
        self.name = name
        self.appearance = appearance
        self.locale = locale
    }
}

private struct VisualWindowScenario {
    struct SizePreset {
        let argument: String
        let expected: CGSize
    }

    let appearance: String
    let locale: String
    let size: SizePreset

    var name: String {
        "Visual \(locale) · \(appearance) · \(size.argument) · \(dimensionText(size.expected))"
    }

    private func dimensionText(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }
}

private struct VisualDestination {
    let fixtureID: String
    let page: String
    let state: String
    let inspector: String

    var readyIdentifier: String {
        "visual.ready.\(fixtureID)"
    }
}

private struct VisualFixtureRoute {
    let fixtureID: String
    let page: String
    let state: String
    let captureBoundary: VisualCaptureBoundary
    let inspectorPolicy: VisualInspectorPolicy

    var captureDestinations: [VisualDestination] {
        inspectorPolicy.values.map { inspector in
            VisualDestination(
                fixtureID: fixtureID,
                page: page,
                state: state,
                inspector: inspector
            )
        }
    }
}

private enum VisualCaptureBoundary: String {
    case mainWindow
    case menu
    case sheet
}

private enum VisualInspectorPolicy {
    case notApplicable
    case toggleable

    var values: [String] {
        switch self {
        case .notApplicable:
            ["na"]
        case .toggleable:
            ["closed", "open"]
        }
    }
}

private struct VisualFixtureRegistry {
    private struct Document: Decodable {
        let schemaVersion: Int
        let fixtures: [Entry]
    }

    private struct Entry: Decodable {
        let id: String
        let page: String
        let state: String
        let sensitiveData: Bool
        let dataSource: String
        let liveServicesAllowed: Bool
    }

    let routes: [VisualFixtureRoute]

    static func load(relativeTo sourceFile: StaticString) throws -> Self {
        let registryURL = try locateRegistry(relativeTo: sourceFile)
        let data: Data
        do {
            data = try Data(contentsOf: registryURL)
        } catch {
            throw VisualFixtureRegistryError.unreadable(
                path: registryURL.path,
                underlying: error.localizedDescription
            )
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw VisualFixtureRegistryError.invalidJSON(
                path: registryURL.path,
                underlying: error.localizedDescription
            )
        }

        guard document.schemaVersion == 1 else {
            throw VisualFixtureRegistryError.unsupportedSchema(
                document.schemaVersion
            )
        }
        guard document.fixtures.count == 103 else {
            throw VisualFixtureRegistryError.unexpectedFixtureCount(
                document.fixtures.count
            )
        }

        var seenFixtureIDs = Set<String>()
        let routes = try document.fixtures.map { entry in
            guard seenFixtureIDs.insert(entry.id).inserted else {
                throw VisualFixtureRegistryError.duplicateFixtureID(entry.id)
            }
            guard !entry.id.isEmpty, !entry.page.isEmpty, !entry.state.isEmpty else {
                throw VisualFixtureRegistryError.emptyRoute(entry.id)
            }
            guard !entry.sensitiveData,
                entry.dataSource == "deterministicInMemory",
                !entry.liveServicesAllowed
            else {
                throw VisualFixtureRegistryError.unsafeFixture(entry.id)
            }

            let contract = try routeContract(for: entry.page)
            return VisualFixtureRoute(
                fixtureID: entry.id,
                page: entry.page,
                state: entry.state,
                captureBoundary: contract.boundary,
                inspectorPolicy: contract.inspectorPolicy
            )
        }

        let expectedPages: Set<String> = [
            "overview", "proxies", "connections", "rules",
            "providers", "workbench", "diagnostics", "logs",
            "settings", "tunFlow", "menuBar", "updateCoreRecovery",
            "helpSupport",
        ]
        let actualPages = Set(routes.map(\.page))
        guard actualPages == expectedPages else {
            throw VisualFixtureRegistryError.pageCoverageMismatch(
                expected: expectedPages.sorted(),
                actual: actualPages.sorted()
            )
        }

        return Self(routes: routes)
    }

    private static func locateRegistry(
        relativeTo _: StaticString
    ) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let configuredRoot = environment["VELA_TEST_REPOSITORY_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredRoot.isEmpty
        else {
            throw VisualFixtureRegistryError.missing([
                "VELA_TEST_REPOSITORY_ROOT must point to a staged, read-only fixture tree."
            ])
        }

        let registryURL = URL(
            fileURLWithPath: configuredRoot,
            isDirectory: true
        )
        .standardizedFileURL
        .appendingPathComponent(
            "VisualRecovery/Fixtures/fixture-registry.json"
        )
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            throw VisualFixtureRegistryError.missing([registryURL.path])
        }
        return registryURL
    }

    private static func routeContract(
        for page: String
    ) throws -> (
        boundary: VisualCaptureBoundary,
        inspectorPolicy: VisualInspectorPolicy
    ) {
        switch page {
        case "proxies", "connections", "rules", "providers", "workbench",
             "diagnostics", "logs":
            (.mainWindow, .toggleable)
        case "overview", "updateCoreRecovery", "helpSupport":
            (.mainWindow, .notApplicable)
        case "settings":
            (.mainWindow, .notApplicable)
        case "menuBar":
            (.menu, .notApplicable)
        case "tunFlow":
            (.sheet, .notApplicable)
        default:
            throw VisualFixtureRegistryError.unknownPage(page)
        }
    }
}

private enum VisualFixtureRegistryError: LocalizedError {
    case missing([String])
    case unreadable(path: String, underlying: String)
    case invalidJSON(path: String, underlying: String)
    case unsupportedSchema(Int)
    case unexpectedFixtureCount(Int)
    case duplicateFixtureID(String)
    case emptyRoute(String)
    case unsafeFixture(String)
    case unknownPage(String)
    case pageCoverageMismatch(expected: [String], actual: [String])

    var errorDescription: String? {
        switch self {
        case let .missing(paths):
            "fixture-registry.json was not found. Searched: "
                + paths.joined(separator: ", ")
        case let .unreadable(path, underlying):
            "Could not read visual fixture registry at \(path): \(underlying)"
        case let .invalidJSON(path, underlying):
            "Could not decode visual fixture registry at \(path): \(underlying)"
        case let .unsupportedSchema(version):
            "Unsupported visual fixture registry schema version: \(version)."
        case let .unexpectedFixtureCount(actual):
            "Expected all 103 visual fixtures, but fixture-registry.json contains \(actual)."
        case let .duplicateFixtureID(fixtureID):
            "Duplicate visual fixture ID: \(fixtureID)."
        case let .emptyRoute(fixtureID):
            "Visual fixture \(fixtureID) has an empty page or state."
        case let .unsafeFixture(fixtureID):
            "Visual fixture \(fixtureID) is not deterministic, isolated, and non-sensitive."
        case let .unknownPage(page):
            "Visual fixture registry contains an unknown capture page: \(page)."
        case let .pageCoverageMismatch(expected, actual):
            "Visual fixture page coverage mismatch; expected \(expected), found \(actual)."
        }
    }
}

private struct MenuBarAXDiagnostic {
    let succeeded: Bool
    let report: String
}

private struct BuiltProductProcessMatch {
    let processIdentifier: pid_t?
    let trace: [String]
}

private enum VisualSurface {
    case menuBar
    case settings
    case tunFlow
}
