import Foundation

nonisolated enum AppLaunchConfiguration: Equatable, Sendable {
    case production
#if DEBUG
    case uiTesting
#endif
    case startupSmoke(root: URL)

    static let startupSmokeArgument = "--vela-startup-smoke"
    static let startupSmokeRootEnvironmentKey = "VELA_STARTUP_SMOKE_ROOT"

    /// Hosted unit tests inherit XCTest's configuration environment but do not
    /// opt into Vela's UI-test or startup-smoke lifecycle. Keeping that process
    /// out of the production bootstrap prevents background recovery, onboarding,
    /// and menu-bar work from competing with the test runner.
    static func isHostedUnitTestProcess(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
#if DEBUG
        environment["XCTestConfigurationFilePath"] != nil
            && !VisualUITestConfiguration.isRequested(arguments: arguments)
            && !arguments.contains(startupSmokeArgument)
#else
        false
#endif
    }

    var usesLiveServices: Bool {
        switch self {
        case .production, .startupSmoke:
            true
#if DEBUG
        case .uiTesting:
            false
#endif
        }
    }

    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> AppLaunchConfiguration {
        let hasStartupSmokeArgument = arguments.contains(startupSmokeArgument)
        let startupSmokeRootValue = environment[startupSmokeRootEnvironmentKey]

        // Treat either half of the startup-smoke contract as an explicit request.
        // A malformed request must never fall through to production storage.
        if hasStartupSmokeArgument || startupSmokeRootValue != nil {
            guard hasStartupSmokeArgument else {
                throw AppLaunchConfigurationError.missingStartupSmokeArgument
            }
            guard let startupSmokeRootValue, !startupSmokeRootValue.isEmpty else {
                throw AppLaunchConfigurationError.missingStartupSmokeRoot
            }

            let root = try validateStartupSmokeRoot(
                startupSmokeRootValue,
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager
            )
            return .startupSmoke(root: root)
        }

#if DEBUG
        if VisualUITestConfiguration.isRequested(arguments: arguments)
            || environment["XCTestConfigurationFilePath"] != nil {
            return .uiTesting
        }
#endif

        return .production
    }

    private static func validateStartupSmokeRoot(
        _ path: String,
        temporaryDirectory: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard NSString(string: path).isAbsolutePath else {
            throw AppLaunchConfigurationError.startupSmokeRootMustBeAbsolute(path: path)
        }

        let requestedRoot = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: requestedRoot.path, isDirectory: &isDirectory) else {
            throw AppLaunchConfigurationError.startupSmokeRootDoesNotExist(
                path: requestedRoot.path
            )
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try requestedRoot.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            throw AppLaunchConfigurationError.couldNotInspectStartupSmokeRoot(
                path: requestedRoot.path,
                reason: error.localizedDescription
            )
        }

        guard resourceValues.isSymbolicLink != true else {
            throw AppLaunchConfigurationError.startupSmokeRootIsSymbolicLink(
                path: requestedRoot.path
            )
        }
        guard isDirectory.boolValue, resourceValues.isDirectory == true else {
            throw AppLaunchConfigurationError.startupSmokeRootIsNotDirectory(
                path: requestedRoot.path
            )
        }

        let canonicalRoot = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalTemporaryDirectory = temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isStrictlyContained(canonicalRoot, in: canonicalTemporaryDirectory) else {
            throw AppLaunchConfigurationError.startupSmokeRootOutsideTemporaryDirectory(
                path: canonicalRoot.path,
                temporaryDirectory: canonicalTemporaryDirectory.path
            )
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: requestedRoot.path)
        } catch {
            throw AppLaunchConfigurationError.couldNotInspectStartupSmokeRoot(
                path: requestedRoot.path,
                reason: error.localizedDescription
            )
        }
        guard let permissionNumber = attributes[.posixPermissions] as? NSNumber else {
            throw AppLaunchConfigurationError.couldNotInspectStartupSmokeRoot(
                path: requestedRoot.path,
                reason: "POSIX permissions are unavailable."
            )
        }

        let permissions = permissionNumber.intValue & 0o777
        guard permissions == 0o700 else {
            throw AppLaunchConfigurationError.startupSmokeRootHasUnsafePermissions(
                path: requestedRoot.path,
                actual: permissions
            )
        }

        return canonicalRoot
    }

    private static func isStrictlyContained(_ child: URL, in parent: URL) -> Bool {
        let childComponents = child.pathComponents
        let parentComponents = parent.pathComponents
        guard childComponents.count > parentComponents.count else { return false }
        return childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }
}

nonisolated enum AppLaunchConfigurationError: Error, Equatable, Sendable {
    case missingStartupSmokeArgument
    case missingStartupSmokeRoot
    case startupSmokeRootMustBeAbsolute(path: String)
    case startupSmokeRootDoesNotExist(path: String)
    case startupSmokeRootIsSymbolicLink(path: String)
    case startupSmokeRootIsNotDirectory(path: String)
    case startupSmokeRootOutsideTemporaryDirectory(path: String, temporaryDirectory: String)
    case startupSmokeRootHasUnsafePermissions(path: String, actual: Int)
    case couldNotInspectStartupSmokeRoot(path: String, reason: String)
}

extension AppLaunchConfigurationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingStartupSmokeArgument:
            "VELA_STARTUP_SMOKE_ROOT requires --vela-startup-smoke."
        case .missingStartupSmokeRoot:
            "--vela-startup-smoke requires VELA_STARTUP_SMOKE_ROOT."
        case let .startupSmokeRootMustBeAbsolute(path):
            "The startup smoke root must be an absolute path: \(path)"
        case let .startupSmokeRootDoesNotExist(path):
            "The startup smoke root does not exist: \(path)"
        case let .startupSmokeRootIsSymbolicLink(path):
            "The startup smoke root must not be a symbolic link: \(path)"
        case let .startupSmokeRootIsNotDirectory(path):
            "The startup smoke root is not a directory: \(path)"
        case let .startupSmokeRootOutsideTemporaryDirectory(path, temporaryDirectory):
            "The startup smoke root \(path) must be strictly contained in \(temporaryDirectory)."
        case let .startupSmokeRootHasUnsafePermissions(path, actual):
            "The startup smoke root \(path) must use mode 0700; found \(modeString(actual))."
        case let .couldNotInspectStartupSmokeRoot(path, reason):
            "The startup smoke root could not be inspected at \(path): \(reason)"
        }
    }

    private func modeString(_ permissions: Int) -> String {
        String(format: "%04o", permissions)
    }
}
