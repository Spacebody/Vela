import Foundation
import Testing
@testable import Vela

@Suite("App launch configuration")
struct AppLaunchConfigurationTests {
    @Test("Production is the default launch configuration")
    func productionIsDefault() throws {
        let configuration = try AppLaunchConfiguration.resolve(
            arguments: ["Vela"],
            environment: [:]
        )

        #expect(configuration == .production)
        #expect(configuration.usesLiveServices)
    }

    @Test("UI testing is selected by either supported Debug XCTest signal")
    func uiTestingSignalsRemainSupported() throws {
        let argumentConfiguration = try AppLaunchConfiguration.resolve(
            arguments: visualTestArguments(),
            environment: [:]
        )
        let environmentConfiguration = try AppLaunchConfiguration.resolve(
            arguments: ["Vela"],
            environment: ["XCTestConfigurationFilePath": "/tmp/Vela.xctestconfiguration"]
        )

        #expect(argumentConfiguration == .uiTesting)
        #expect(environmentConfiguration == .uiTesting)
        #expect(!argumentConfiguration.usesLiveServices)
        #expect(!environmentConfiguration.usesLiveServices)
    }

    @Test("Hosted unit tests are distinguished from explicit app test launches")
    func hostedUnitTestDetection() {
        let xctestEnvironment = [
            "XCTestConfigurationFilePath": "/tmp/Vela.xctestconfiguration"
        ]

        #expect(
            AppLaunchConfiguration.isHostedUnitTestProcess(
                arguments: ["Vela"],
                environment: xctestEnvironment
            )
        )
        #expect(
            !AppLaunchConfiguration.isHostedUnitTestProcess(
                arguments: visualTestArguments(),
                environment: xctestEnvironment
            )
        )
        #expect(
            !AppLaunchConfiguration.isHostedUnitTestProcess(
                arguments: ["Vela", AppLaunchConfiguration.startupSmokeArgument],
                environment: xctestEnvironment
            )
        )
        #expect(
            !AppLaunchConfiguration.isHostedUnitTestProcess(
                arguments: ["Vela"],
                environment: [:]
            )
        )
    }

    @Test("A malformed visual request remains isolated from production")
    func malformedVisualRequestUsesIsolatedLaunchConfiguration() throws {
        let configuration = try AppLaunchConfiguration.resolve(
            arguments: [
                "Vela",
                VisualUITestConfiguration.modeKey, "NO",
            ],
            environment: [:]
        )

        #expect(configuration == .uiTesting)
        #expect(!configuration.usesLiveServices)
        #expect(
            !AppDelegate.allowsLifecycleBootstrap(arguments: [
                "Vela",
                VisualUITestConfiguration.modeKey, "NO",
            ])
        )
    }

    @Test("A valid startup smoke root takes precedence over XCTest")
    func validStartupSmokeRootUsesIsolatedRoot() throws {
        let sandbox = try LaunchConfigurationTestSandbox()
        defer { sandbox.remove() }
        let root = try sandbox.makeDirectory(named: "smoke", permissions: 0o700)

        let configuration = try AppLaunchConfiguration.resolve(
            arguments: ["Vela", AppLaunchConfiguration.startupSmokeArgument],
            environment: [
                AppLaunchConfiguration.startupSmokeRootEnvironmentKey: root.path,
                "XCTestConfigurationFilePath": "/tmp/Vela.xctestconfiguration",
            ],
            temporaryDirectory: sandbox.temporaryDirectory
        )

        #expect(
            configuration
                == .startupSmoke(root: root.resolvingSymlinksInPath().standardizedFileURL)
        )
        #expect(configuration.usesLiveServices)
    }

    @Test("Startup smoke argument without a root fails closed")
    func missingStartupSmokeRootFailsClosed() {
        expectError(
            .missingStartupSmokeRoot,
            arguments: ["Vela", AppLaunchConfiguration.startupSmokeArgument],
            environment: [:]
        )
    }

    @Test("Startup smoke root without the explicit argument fails closed")
    func missingStartupSmokeArgumentFailsClosed() {
        expectError(
            .missingStartupSmokeArgument,
            arguments: ["Vela"],
            environment: [AppLaunchConfiguration.startupSmokeRootEnvironmentKey: "/tmp/smoke"]
        )
    }

    @Test("A relative startup smoke root fails closed")
    func relativeStartupSmokeRootFailsClosed() throws {
        let sandbox = try LaunchConfigurationTestSandbox()
        defer { sandbox.remove() }
        let relativePath = "relative/smoke"

        expectError(
            .startupSmokeRootMustBeAbsolute(path: relativePath),
            arguments: ["Vela", AppLaunchConfiguration.startupSmokeArgument],
            environment: [AppLaunchConfiguration.startupSmokeRootEnvironmentKey: relativePath],
            temporaryDirectory: sandbox.temporaryDirectory
        )
    }

    @Test("A missing startup smoke directory fails closed")
    func nonexistentStartupSmokeRootFailsClosed() throws {
        let sandbox = try LaunchConfigurationTestSandbox()
        defer { sandbox.remove() }
        let missingRoot = sandbox.temporaryDirectory
            .appendingPathComponent("missing", isDirectory: true)
            .standardizedFileURL

        expectError(
            .startupSmokeRootDoesNotExist(path: missingRoot.path),
            arguments: ["Vela", AppLaunchConfiguration.startupSmokeArgument],
            environment: [AppLaunchConfiguration.startupSmokeRootEnvironmentKey: missingRoot.path],
            temporaryDirectory: sandbox.temporaryDirectory
        )
    }

    @Test("A startup smoke root outside the allowed temporary directory fails closed")
    func outsideStartupSmokeRootFailsClosed() throws {
        let sandbox = try LaunchConfigurationTestSandbox()
        defer { sandbox.remove() }
        let allowedTemporaryDirectory = try sandbox.makeDirectory(
            named: "allowed",
            permissions: 0o700
        )
        let outsideRoot = try sandbox.makeDirectory(named: "outside", permissions: 0o700)
        let canonicalRoot = outsideRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalTemporaryDirectory = allowedTemporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL

        expectError(
            .startupSmokeRootOutsideTemporaryDirectory(
                path: canonicalRoot.path,
                temporaryDirectory: canonicalTemporaryDirectory.path
            ),
            arguments: ["Vela", AppLaunchConfiguration.startupSmokeArgument],
            environment: [AppLaunchConfiguration.startupSmokeRootEnvironmentKey: outsideRoot.path],
            temporaryDirectory: allowedTemporaryDirectory
        )
    }

    @Test("A startup smoke root with permissions other than 0700 fails closed")
    func unsafeStartupSmokeRootPermissionsFailClosed() throws {
        let sandbox = try LaunchConfigurationTestSandbox()
        defer { sandbox.remove() }
        let root = try sandbox.makeDirectory(named: "smoke", permissions: 0o755)

        expectError(
            .startupSmokeRootHasUnsafePermissions(path: root.path, actual: 0o755),
            arguments: ["Vela", AppLaunchConfiguration.startupSmokeArgument],
            environment: [AppLaunchConfiguration.startupSmokeRootEnvironmentKey: root.path],
            temporaryDirectory: sandbox.temporaryDirectory
        )
    }

    @Test("A symbolic-link startup smoke root fails closed")
    func symbolicLinkStartupSmokeRootFailsClosed() throws {
        let sandbox = try LaunchConfigurationTestSandbox()
        defer { sandbox.remove() }
        let target = try sandbox.makeDirectory(named: "target", permissions: 0o700)
        let link = sandbox.temporaryDirectory.appendingPathComponent("smoke-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        expectError(
            .startupSmokeRootIsSymbolicLink(path: link.path),
            arguments: ["Vela", AppLaunchConfiguration.startupSmokeArgument],
            environment: [AppLaunchConfiguration.startupSmokeRootEnvironmentKey: link.path],
            temporaryDirectory: sandbox.temporaryDirectory
        )
    }

    @Test("A regular file cannot be used as the startup smoke root")
    func fileStartupSmokeRootFailsClosed() throws {
        let sandbox = try LaunchConfigurationTestSandbox()
        defer { sandbox.remove() }
        let file = sandbox.temporaryDirectory.appendingPathComponent("smoke-file")
        try Data().write(to: file, options: .atomic)

        expectError(
            .startupSmokeRootIsNotDirectory(path: file.path),
            arguments: ["Vela", AppLaunchConfiguration.startupSmokeArgument],
            environment: [AppLaunchConfiguration.startupSmokeRootEnvironmentKey: file.path],
            temporaryDirectory: sandbox.temporaryDirectory
        )
    }

    private func expectError(
        _ expectedError: AppLaunchConfigurationError,
        arguments: [String],
        environment: [String: String],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        do {
            _ = try AppLaunchConfiguration.resolve(
                arguments: arguments,
                environment: environment,
                temporaryDirectory: temporaryDirectory
            )
            Issue.record("Expected launch configuration resolution to fail")
        } catch let error as AppLaunchConfigurationError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func visualTestArguments() -> [String] {
        [
            "Vela",
            VisualUITestConfiguration.modeKey, "YES",
            VisualUITestConfiguration.fixtureKey, "overview.loadedHealthy",
            VisualUITestConfiguration.pageKey, "overview",
            VisualUITestConfiguration.stateKey, "loaded",
            VisualUITestConfiguration.appearanceKey, "light",
            VisualUITestConfiguration.localeKey, "en",
            VisualUITestConfiguration.windowKey, "1280x820",
            VisualUITestConfiguration.inspectorKey, "closed",
            VisualUITestConfiguration.fixedDateKey, "2026-07-14T09:41:00Z",
            VisualUITestConfiguration.uuidSeedKey, "20260714",
        ]
    }
}

private struct LaunchConfigurationTestSandbox {
    let temporaryDirectory: URL

    init() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VelaLaunchConfigurationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        try setPermissions(0o700, for: temporaryDirectory)
    }

    func makeDirectory(named name: String, permissions: Int) throws -> URL {
        let directory = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try setPermissions(permissions, for: directory)
        return directory.standardizedFileURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func setPermissions(_ permissions: Int, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }
}
