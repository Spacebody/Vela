import Foundation
import XCTest

/// Fail-closed boundary shared by every Vela UI test.
///
/// UI tests are allowed to launch only the Debug product carrying the dedicated
/// visual-test bundle identifier.  This keeps AppKit's process-owned defaults
/// and restoration state physically separate from the installed Vela app.
enum VelaUITestIsolation {
    static let dedicatedBundleIdentifier = "dev.yilin.Vela.VisualTests"

    static func requireDedicatedBundleIdentifier() throws -> String {
        let applicationURL = builtApplicationURL()
        let actual = Bundle(url: applicationURL)?.bundleIdentifier
        guard actual == dedicatedBundleIdentifier else {
            throw VelaUITestIsolationError.unexpectedBundleIdentifier(
                expected: dedicatedBundleIdentifier,
                actual: actual,
                applicationURL: applicationURL
            )
        }
        return dedicatedBundleIdentifier
    }

    static func prepare() throws -> String {
        let bundleIdentifier = try requireDedicatedBundleIdentifier()
        try clearPreferenceDomain(bundleIdentifier)
        try removeDedicatedSavedState(bundleIdentifier: bundleIdentifier)
        return bundleIdentifier
    }

    @MainActor
    static func terminate(
        _ app: XCUIApplication,
        clearingPreferenceDomain bundleIdentifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard bundleIdentifier == dedicatedBundleIdentifier else {
            XCTFail(
                "Refused to clear a non-test preference domain: \(bundleIdentifier)",
                file: file,
                line: line
            )
            return
        }

        if app.state != .notRunning {
            app.terminate()
        }
        guard app.wait(for: .notRunning, timeout: 5) else {
            XCTFail(
                "Vela did not terminate before UI-test preference cleanup.",
                file: file,
                line: line
            )
            return
        }

        do {
            try clearPreferenceDomain(bundleIdentifier)
            try removeDedicatedSavedState(bundleIdentifier: bundleIdentifier)
        } catch {
            XCTFail(error.localizedDescription, file: file, line: line)
        }
    }

    static func builtApplicationURL() -> URL {
        var builtProductsURL = Bundle(for: VelaUITestBundleAnchor.self).bundleURL
        for _ in 0..<4 {
            builtProductsURL.deleteLastPathComponent()
        }
        return canonicalFileURL(
            builtProductsURL.appendingPathComponent(
                "Vela.app",
                isDirectory: true
            )
        )
    }

    private static func clearPreferenceDomain(_ bundleIdentifier: String) throws {
        guard bundleIdentifier == dedicatedBundleIdentifier else {
            throw VelaUITestIsolationError.unsafePreferenceDomain(bundleIdentifier)
        }
        // NSWindow frame autosave is owned by the launched app process. A
        // UserDefaults suite in the UI-test runner has a distinct cache and
        // cannot reliably evict those cross-process records. Use the system
        // defaults client against the one hard-coded disposable bundle ID,
        // then verify that no persistent domain remains.
        _ = try runDefaults(["delete", bundleIdentifier])
        guard try runDefaults(["read", bundleIdentifier]) != 0 else {
            throw VelaUITestIsolationError.cleanupFailed(bundleIdentifier)
        }
        guard let defaults = UserDefaults(suiteName: bundleIdentifier) else {
            throw VelaUITestIsolationError.defaultsUnavailable(bundleIdentifier)
        }
        defaults.removePersistentDomain(forName: bundleIdentifier)
        defaults.synchronize()
        guard defaults.persistentDomain(forName: bundleIdentifier) == nil else {
            throw VelaUITestIsolationError.cleanupFailed(bundleIdentifier)
        }
    }

    private static func runDefaults(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func removeDedicatedSavedState(
        bundleIdentifier: String
    ) throws {
        guard bundleIdentifier == dedicatedBundleIdentifier else {
            throw VelaUITestIsolationError.unsafePreferenceDomain(bundleIdentifier)
        }
        let fileManager = FileManager.default
        let temporaryRoot = canonicalFileURL(fileManager.temporaryDirectory)
        let savedStateURL = temporaryRoot.appendingPathComponent(
            "\(bundleIdentifier).savedState",
            isDirectory: true
        ).standardizedFileURL
        guard savedStateURL.deletingLastPathComponent() == temporaryRoot else {
            throw VelaUITestIsolationError.unsafeSavedStatePath(savedStateURL)
        }
        guard fileManager.fileExists(atPath: savedStateURL.path) else { return }
        let values = try savedStateURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VelaUITestIsolationError.unsafeSavedStatePath(savedStateURL)
        }
        try fileManager.removeItem(at: savedStateURL)
    }

    private static func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private final class VelaUITestBundleAnchor: NSObject {}

private enum VelaUITestIsolationError: LocalizedError {
    case unexpectedBundleIdentifier(
        expected: String,
        actual: String?,
        applicationURL: URL
    )
    case unsafePreferenceDomain(String)
    case defaultsUnavailable(String)
    case cleanupFailed(String)
    case unsafeSavedStatePath(URL)

    var errorDescription: String? {
        switch self {
        case let .unexpectedBundleIdentifier(expected, actual, applicationURL):
            "Vela UI tests refuse to launch \(actual ?? "<missing>") from "
                + "\(applicationURL.path). Build with "
                + "VELA_APP_BUNDLE_IDENTIFIER=\(expected) and "
                + "VELA_VISUAL_TEST_BUILD=YES so AppKit cannot read or write "
                + "the production preference domain."
        case let .unsafePreferenceDomain(bundleIdentifier):
            "Refused to clear a non-test preference domain: \(bundleIdentifier)"
        case let .defaultsUnavailable(bundleIdentifier):
            "Could not create the disposable UI-test preference domain "
                + bundleIdentifier
        case let .cleanupFailed(bundleIdentifier):
            "Could not clear the disposable UI-test preference domain "
                + bundleIdentifier
        case let .unsafeSavedStatePath(url):
            "Refused to remove an unsafe UI-test saved-state path: " + url.path
        }
    }
}

/// Launches the Debug app through the strict visual-test contract so UI tests
/// never fall through to production network, Keychain, helper, TUN, or proxy
/// dependencies.
nonisolated func velaIsolatedUITestLaunchArguments(
    page: String = "overview",
    state: String = "offline",
    appearance: String = "light",
    locale: String = "en",
    window: String = "1280x820",
    inspector: String = "na",
    usesMainWindowPolicy: Bool = false,
    requestedContentSize: String? = nil,
    windowSceneIdentifier: String? = nil
) -> [String] {
    let appleLocale = locale == "zh-Hans" ? "zh_CN" : "en_US"
    let fixtureID: String
    switch (page, state) {
    case ("overview", "loaded"):
        fixtureID = "overview.loadedHealthy"
    case ("overview", "offline"):
        fixtureID = "overview.offlineNoConfiguration"
    default:
        fixtureID = "\(page).\(state)"
    }
    var arguments = [
        "-ApplePersistenceIgnoreState", "YES",
        // Set AppKit's process-wide appearance before SwiftUI creates the
        // native NSMenu owned by MenuBarExtra. A later preferredColorScheme
        // only affects SwiftUI content and cannot recolor that menu reliably.
        "-AppleInterfaceStyle", appearance == "dark" ? "Dark" : "Light",
        "-AppleLanguages", "(\(locale))",
        "-AppleLocale", appleLocale,
        "-VelaVisualTestMode", "YES",
        "-VelaFixture", fixtureID,
        "-VelaPage", page,
        "-VelaState", state,
        "-VelaAppearance", appearance,
        "-VelaLocale", locale,
        "-VelaWindow", window,
        "-VelaInspector", inspector,
        "-VelaFixedDate", "2026-07-14T09:41:00Z",
        "-VelaUUIDSeed", "20260714",
    ]
    if usesMainWindowPolicy {
        arguments += [
            VelaWindowTestArgument.modeKey, "YES",
            VelaWindowTestArgument.sceneIdentifierKey,
            windowSceneIdentifier
                ?? "main-window-policy-test-\(UUID().uuidString)",
        ]
        if let requestedContentSize {
            arguments += [
                VelaWindowTestArgument.requestedContentSizeKey,
                requestedContentSize,
            ]
        }
    }
    return arguments
}

private enum VelaWindowTestArgument {
    static let modeKey = "-VelaMainWindowPolicyTest"
    static let requestedContentSizeKey = "-VelaRequestedContentSize"
    static let sceneIdentifierKey = "-VelaPolicySceneIdentifier"
}
