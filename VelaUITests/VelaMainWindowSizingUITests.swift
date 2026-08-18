import Foundation
import XCTest

final class VelaMainWindowSizingUITests: XCTestCase {
    @MainActor
    func testReferenceVisualMatrixMeasuresFrameAndContentLayout() throws {
        let bundleIdentifier = try VelaUITestIsolation.prepare()
        let app = XCUIApplication()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "overview",
            state: "loaded",
            appearance: "dark",
            locale: "zh-Hans",
            window: "1040x680",
            inspector: "na"
        )
        app.launch()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: bundleIdentifier
            )
        }

        let geometry = app.descendants(matching: .any)["main.window.root"].firstMatch
        XCTAssertTrue(
            geometry.waitForExistence(timeout: 8),
            "The main-window geometry marker did not appear."
        )
        let label = geometry.label
        print("VELA_WINDOW_GEOMETRY \(label)")
        XCTAssertTrue(label.contains("frame 1040.0x680.0"), label)
        XCTAssertTrue(label.contains("content 1040.0x648.0"), label)

        let window = try XCTUnwrap(
            app.windows.allElementsBoundByIndex.first(where: {
                $0.frame.width.isFinite
                    && $0.frame.height.isFinite
                    && $0.frame.width > 0
                    && $0.frame.height > 0
                    && $0.descendants(matching: .any)["main.window.root"].firstMatch.exists
            })
        )
        XCTAssertEqual(window.frame.width, 1_040, accuracy: 1)
        XCTAssertEqual(window.frame.height, 680, accuracy: 1)
    }

    @MainActor
    func testDefaultContentSizeUsesScenePolicy() throws {
        let session = try launchPolicyApp()
        defer { session.cleanup() }

        let geometry = try requireGeometry(in: session.app)
        XCTAssertEqual(geometry.content.width, 1_280, accuracy: 1)
        XCTAssertEqual(geometry.content.height, 788, accuracy: 1)
        XCTAssertEqual(geometry.frame.width, 1_280, accuracy: 1)
        XCTAssertEqual(geometry.frame.height, 820, accuracy: 1)
        assertShellMarkers(in: session.app)
        attachWindowScreenshot(session.app, name: "main-default-1280x820-content")
    }

    @MainActor
    func testMinimumClampRejectsLegacy600x400Content() throws {
        let session = try launchPolicyApp(requestedContentSize: "600x400")
        defer { session.cleanup() }

        let geometry = try requireGeometry(in: session.app)
        XCTAssertGreaterThanOrEqual(geometry.content.width, 1_040)
        XCTAssertGreaterThanOrEqual(geometry.content.height, 648)
        XCTAssertEqual(geometry.frame.width, 1_040, accuracy: 1)
        XCTAssertEqual(geometry.frame.height, 680, accuracy: 1)
        assertShellMarkers(in: session.app)
        XCTAssertTrue(session.app.descendants(matching: .any)["sidebar.overview"].firstMatch.isHittable)
        attachWindowScreenshot(session.app, name: "main-minimum-clamp")
    }

    @MainActor
    func testFreeEnlargementHasNoMaximumConstraint() throws {
        let session = try launchPolicyApp(requestedContentSize: "1600x1000")
        defer { session.cleanup() }

        let geometry = try requireGeometry(in: session.app)
        XCTAssertEqual(geometry.content.width, 1_600, accuracy: 1)
        XCTAssertGreaterThanOrEqual(geometry.content.height, 788)
        XCTAssertEqual(geometry.frame.width, 1_600, accuracy: 1)
        XCTAssertGreaterThanOrEqual(geometry.frame.height, 820)
        attachWindowScreenshot(session.app, name: "main-large-1600x1000-content")
    }

    @MainActor
    func testLargeWindowRestorationIsNotResetToDefault() throws {
        let bundleIdentifier = try VelaUITestIsolation.prepare()
        let sceneIdentifier = policySceneIdentifier()
        let first = XCUIApplication()
        first.launchArguments = restorationArguments(
            requestedContentSize: "1500x900",
            sceneIdentifier: sceneIdentifier
        )
        first.launch()
        let firstGeometry = try requireGeometry(in: first)
        XCTAssertEqual(firstGeometry.content.width, 1_500, accuracy: 1)
        XCTAssertGreaterThanOrEqual(firstGeometry.content.height, 788)
        first.terminate()
        XCTAssertTrue(first.wait(for: .notRunning, timeout: 5))

        let restored = XCUIApplication()
        restored.launchArguments = restorationArguments(
            requestedContentSize: nil,
            sceneIdentifier: sceneIdentifier
        )
        restored.launch()
        defer {
            VelaUITestIsolation.terminate(
                restored,
                clearingPreferenceDomain: bundleIdentifier
            )
        }

        let restoredGeometry = try requireGeometry(in: restored)
        XCTAssertEqual(restoredGeometry.content.width, 1_500, accuracy: 2)
        XCTAssertGreaterThanOrEqual(restoredGeometry.content.height, 788)
    }

    @MainActor
    func testRestoredTooSmallSizeClampsAtMinimum() throws {
        let bundleIdentifier = try VelaUITestIsolation.prepare()
        let sceneIdentifier = policySceneIdentifier()
        let first = XCUIApplication()
        first.launchArguments = restorationArguments(
            requestedContentSize: "600x400",
            sceneIdentifier: sceneIdentifier
        )
        first.launch()
        let clampedGeometry = try requireGeometry(in: first)
        XCTAssertEqual(clampedGeometry.content.width, 1_040, accuracy: 1)
        XCTAssertEqual(clampedGeometry.content.height, 648, accuracy: 1)
        first.terminate()
        XCTAssertTrue(first.wait(for: .notRunning, timeout: 5))

        let restored = XCUIApplication()
        restored.launchArguments = restorationArguments(
            requestedContentSize: nil,
            sceneIdentifier: sceneIdentifier
        )
        restored.launch()
        defer {
            VelaUITestIsolation.terminate(
                restored,
                clearingPreferenceDomain: bundleIdentifier
            )
        }

        let restoredGeometry = try requireGeometry(in: restored)
        XCTAssertEqual(restoredGeometry.content.width, 1_040, accuracy: 2)
        XCTAssertEqual(restoredGeometry.content.height, 648, accuracy: 2)
        assertShellMarkers(in: restored)
    }

    @MainActor
    func testZoomAndFullScreenAffordancesRemainAvailable() throws {
        let session = try launchPolicyApp()
        defer { session.cleanup() }

        let window = try requireMainWindow(in: session.app)
        XCTAssertGreaterThanOrEqual(window.buttons.count, 3)

        let windowMenu = session.app.menuBars.menuBarItems["Window"].firstMatch
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 3))
        windowMenu.click()
        XCTAssertTrue(session.app.menuItems["Zoom"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(
            session.app.menuItems["Enter Full Screen"].firstMatch.exists
                || session.app.menuItems["Exit Full Screen"].firstMatch.exists
        )
        session.app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testRequiredVisualEvidenceMatrix() throws {
        let cases: [WindowEvidenceCase] = [
            .init(
                name: "minimum-dark-zh-Hans-overview",
                page: "overview", inspector: "na", appearance: "dark",
                locale: "zh-Hans", requestedContentSize: "600x400"
            ),
            .init(
                name: "minimum-light-en-overview",
                page: "overview", inspector: "na", appearance: "light",
                locale: "en", requestedContentSize: "600x400"
            ),
            .init(
                name: "minimum-dark-en-connections",
                page: "connections", inspector: "closed", appearance: "dark",
                locale: "en", requestedContentSize: "600x400"
            ),
            .init(
                name: "minimum-dark-en-workbench",
                page: "workbench", inspector: "closed", appearance: "dark",
                locale: "en", requestedContentSize: "600x400"
            ),
            .init(
                name: "default-dark-zh-Hans-overview",
                page: "overview", inspector: "na", appearance: "dark",
                locale: "zh-Hans", requestedContentSize: nil
            ),
            .init(
                name: "large-dark-zh-Hans-overview",
                page: "overview", inspector: "na", appearance: "dark",
                locale: "zh-Hans", requestedContentSize: "1600x1000"
            ),
        ]

        for evidence in cases {
            let session = try launchPolicyApp(
                requestedContentSize: evidence.requestedContentSize,
                page: evidence.page,
                inspector: evidence.inspector,
                appearance: evidence.appearance,
                locale: evidence.locale
            )
            let geometry = try requireGeometry(in: session.app)
            XCTAssertGreaterThanOrEqual(geometry.content.width, 1_040, evidence.name)
            XCTAssertGreaterThanOrEqual(geometry.content.height, 648, evidence.name)
            XCTAssertTrue(
                session.app.descendants(matching: .any)["screen.\(evidence.page)"]
                    .firstMatch.waitForExistence(timeout: 4),
                evidence.name
            )
            attachWindowScreenshot(session.app, name: evidence.name)
            session.cleanup()
        }
    }

    @MainActor
    func testExactLargeReferenceFrameEvidence() throws {
        let bundleIdentifier = try VelaUITestIsolation.prepare()
        let app = XCUIApplication()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: "overview",
            state: "loaded",
            appearance: "dark",
            locale: "zh-Hans",
            window: "1600x1000",
            inspector: "na"
        )
        app.launch()
        defer {
            VelaUITestIsolation.terminate(
                app,
                clearingPreferenceDomain: bundleIdentifier
            )
        }

        let geometry = try requireGeometry(in: app)
        XCTAssertEqual(geometry.frame.width, 1_600, accuracy: 1)
        XCTAssertEqual(geometry.frame.height, 1_000, accuracy: 1)
        XCTAssertEqual(geometry.content.width, 1_600, accuracy: 1)
        XCTAssertEqual(geometry.content.height, 968, accuracy: 1)
        assertShellMarkers(in: app)
        attachWindowScreenshot(app, name: "large-exact-frame-1600x1000-dark-zh-Hans-overview")
    }

    @MainActor
    func testMinimumWindowSmokeAcrossAllMainDestinations() throws {
        let routes: [(page: String, inspector: String)] = [
            ("overview", "na"),
            ("proxies", "closed"),
            ("connections", "closed"),
            ("rules", "closed"),
            ("providers", "closed"),
            ("workbench", "closed"),
            ("diagnostics", "closed"),
            ("logs", "closed"),
        ]

        for route in routes {
            let session = try launchPolicyApp(
                requestedContentSize: "600x400",
                page: route.page,
                inspector: route.inspector
            )
            let geometry = try requireGeometry(in: session.app)
            XCTAssertGreaterThanOrEqual(geometry.content.width, 1_040, route.page)
            XCTAssertGreaterThanOrEqual(geometry.content.height, 648, route.page)
            XCTAssertTrue(
                session.app.descendants(matching: .any)["screen.\(route.page)"]
                    .firstMatch.waitForExistence(timeout: 4),
                route.page
            )
            assertShellMarkers(in: session.app, context: route.page)
            session.cleanup()
        }
    }

    @MainActor
    private func launchPolicyApp(
        requestedContentSize: String? = nil,
        page: String = "overview",
        inspector: String = "na",
        appearance: String = "dark",
        locale: String = "en"
    ) throws -> WindowTestSession {
        let bundleIdentifier = try VelaUITestIsolation.prepare()
        let app = XCUIApplication()
        app.launchArguments = velaIsolatedUITestLaunchArguments(
            page: page,
            state: "loaded",
            appearance: appearance,
            locale: locale,
            window: "1280x820",
            inspector: inspector,
            usesMainWindowPolicy: true,
            requestedContentSize: requestedContentSize
        )
        app.launch()
        return WindowTestSession(app: app, bundleIdentifier: bundleIdentifier)
    }

    private func restorationArguments(
        requestedContentSize: String?,
        sceneIdentifier: String
    ) -> [String] {
        var arguments = velaIsolatedUITestLaunchArguments(
            page: "overview",
            state: "loaded",
            appearance: "dark",
            locale: "en",
            window: "1280x820",
            inspector: "na",
            usesMainWindowPolicy: true,
            requestedContentSize: requestedContentSize,
            windowSceneIdentifier: sceneIdentifier
        )
        if let index = arguments.firstIndex(of: "-ApplePersistenceIgnoreState"),
            arguments.indices.contains(index + 1)
        {
            arguments[index + 1] = "NO"
        }
        return arguments
    }

    private func policySceneIdentifier() -> String {
        "main-window-policy-test-\(UUID().uuidString)"
    }

    @MainActor
    private func requireGeometry(in app: XCUIApplication) throws -> WindowGeometry {
        let marker = app.descendants(matching: .any)["main.window.root"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        let geometry = try WindowGeometry(label: marker.label)
        print(
            "VELA_WINDOW_GEOMETRY frame=\(geometry.frame.width)x\(geometry.frame.height) "
                + "content=\(geometry.content.width)x\(geometry.content.height)"
        )
        return geometry
    }

    @MainActor
    private func requireMainWindow(in app: XCUIApplication) throws -> XCUIElement {
        _ = try requireGeometry(in: app)
        return try XCTUnwrap(
            app.windows.allElementsBoundByIndex.first(where: {
                $0.frame.width.isFinite
                    && $0.frame.height.isFinite
                    && $0.frame.width > 0
                    && $0.frame.height > 0
                    && $0.descendants(matching: .any)["main.window.root"].firstMatch.exists
            })
        )
    }

    @MainActor
    private func assertShellMarkers(
        in app: XCUIApplication,
        context: String = "main window",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in ["main.sidebar", "main.detail", "main.toolbar"] {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].firstMatch
                    .waitForExistence(timeout: 3),
                "Missing \(identifier) in \(context)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func attachWindowScreenshot(_ app: XCUIApplication, name: String) {
        guard let window = try? requireMainWindow(in: app) else { return }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct WindowEvidenceCase {
    let name: String
    let page: String
    let inspector: String
    let appearance: String
    let locale: String
    let requestedContentSize: String?
}

private struct WindowGeometry {
    let frame: CGSize
    let content: CGSize

    init(label: String) throws {
        let expression = try NSRegularExpression(
            pattern: #"frame ([0-9.]+)x([0-9.]+); content ([0-9.]+)x([0-9.]+)"#
        )
        let range = NSRange(label.startIndex..<label.endIndex, in: label)
        guard let match = expression.firstMatch(in: label, range: range),
            match.numberOfRanges == 5,
            let frameWidth = Self.value(match.range(at: 1), in: label),
            let frameHeight = Self.value(match.range(at: 2), in: label),
            let contentWidth = Self.value(match.range(at: 3), in: label),
            let contentHeight = Self.value(match.range(at: 4), in: label)
        else {
            throw WindowGeometryError.invalidLabel(label)
        }
        frame = CGSize(width: frameWidth, height: frameHeight)
        content = CGSize(width: contentWidth, height: contentHeight)
    }

    private static func value(_ range: NSRange, in label: String) -> Double? {
        guard let range = Range(range, in: label) else { return nil }
        return Double(label[range])
    }
}

private enum WindowGeometryError: Error {
    case invalidLabel(String)
}

@MainActor
private struct WindowTestSession {
    let app: XCUIApplication
    let bundleIdentifier: String

    func cleanup() {
        VelaUITestIsolation.terminate(
            app,
            clearingPreferenceDomain: bundleIdentifier
        )
    }
}
