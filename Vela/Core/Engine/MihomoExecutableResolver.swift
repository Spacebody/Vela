import CryptoKit
import Foundation

nonisolated struct MihomoExecutableVerificationEvidence: Equatable, Sendable {
    let teamIdentifier: String?
    let signingIdentifier: String?
    let architecture: String
    let versionOutput: String
    let configurationPassed: Bool?
    let compatibilityReportSHA256: String?
    let controllerSmokePassed: Bool?
}

nonisolated struct ResolvedMihomoExecutable: Equatable, Sendable {
    let url: URL
    let version: String
    let sha256: String
    let preflight: MihomoCorePreflightResult?
    let verifiedFile: MihomoCoreFileSnapshot?
    let verificationEvidence: MihomoExecutableVerificationEvidence?

    init(
        url: URL,
        version: String,
        sha256: String,
        preflight: MihomoCorePreflightResult? = nil,
        verifiedFile: MihomoCoreFileSnapshot? = nil,
        verificationEvidence: MihomoExecutableVerificationEvidence? = nil
    ) {
        self.url = url
        self.version = version
        self.sha256 = sha256
        self.preflight = preflight
        self.verifiedFile = verifiedFile ?? preflight?.file
        self.verificationEvidence = verificationEvidence ?? preflight.map {
            MihomoExecutableVerificationEvidence(
                teamIdentifier: $0.signature.teamIdentifier,
                signingIdentifier: $0.signature.helper.signingIdentifier,
                architecture: $0.machO.architecture.rawValue,
                versionOutput: $0.version.rawOutput,
                configurationPassed: nil,
                compatibilityReportSHA256: nil,
                controllerSmokePassed: nil
            )
        }
    }

    var hasVerifiedIntegritySnapshot: Bool { verifiedFile != nil }
}

nonisolated enum MihomoExecutableResolverError: Error, Equatable, Sendable {
    case resourceMissing(name: String)
    case executableMissing(URL)
    case executableIsDirectory(URL)
    case executableNotRunnable(URL)
    case versionProbeFailed(exitCode: Int32?, stdout: String, stderr: String)
    case versionOutputMissing(stdout: String, stderr: String)
    case checksumFailed(URL, message: String)
    case preflightFailed(MihomoCorePreflightError)
}

extension MihomoExecutableResolverError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .resourceMissing(name):
            "Mihomo resource \"\(name)\" is missing from the app bundle."
        case let .executableMissing(url):
            "Mihomo executable does not exist at \(url.path)."
        case let .executableIsDirectory(url):
            "Expected a Mihomo executable but found a directory at \(url.path)."
        case let .executableNotRunnable(url):
            "Mihomo exists but is not executable at \(url.path)."
        case let .versionProbeFailed(exitCode, stdout, stderr):
            "Mihomo version probe failed with exit code \(exitCode.map(String.init) ?? "unknown"). "
                + "stdout: \(stdout) stderr: \(stderr)"
        case let .versionOutputMissing(stdout, stderr):
            "Mihomo version probe returned no version text. stdout: \(stdout) stderr: \(stderr)"
        case let .checksumFailed(url, message):
            "Could not calculate SHA256 for \(url.path): \(message)"
        case let .preflightFailed(error):
            error.localizedDescription
        }
    }
}

nonisolated protocol MihomoExecutableResolving: Sendable {
    func resolve() async throws -> ResolvedMihomoExecutable
}

nonisolated protocol MihomoExecutableInspecting: Sendable {
    func isDirectory(at url: URL) -> Bool
    func isExecutable(at url: URL) -> Bool
}

nonisolated struct LocalMihomoExecutableInspector: MihomoExecutableInspecting, Sendable {
    func isDirectory(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    func isExecutable(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

}

actor MihomoExecutableResolver: MihomoExecutableResolving {
    private enum Candidate: Sendable {
        case bundled(
            applicationBundleURL: URL,
            teamPolicy: CodeSignatureTeamPolicy,
            versionProbeCurrentDirectoryURL: URL?
        )
        case explicit(URL)
    }

    private let candidate: Candidate
    private let processExecutor: any ProcessExecuting
    private let fileSystem: any FileSystemProviding
    private let executableInspector: any MihomoExecutableInspecting
    private let preflight: any MihomoCorePreflighting
    private let versionArguments: [String]
    private let versionProbeTimeout: Duration

    init(
        bundle: Bundle = .main,
        processExecutor: any ProcessExecuting = ProcessExecutor(),
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        executableInspector: any MihomoExecutableInspecting = LocalMihomoExecutableInspector(),
        preflight: (any MihomoCorePreflighting)? = nil,
        teamPolicy: CodeSignatureTeamPolicy = MihomoExecutableResolver.liveTeamPolicy,
        versionProbeCurrentDirectoryURL: URL? = nil,
        versionArguments: [String] = ["-v"],
        versionProbeTimeout: Duration = .seconds(3)
    ) {
        candidate = .bundled(
            applicationBundleURL: bundle.bundleURL,
            teamPolicy: teamPolicy,
            versionProbeCurrentDirectoryURL: versionProbeCurrentDirectoryURL
        )
        self.processExecutor = processExecutor
        self.fileSystem = fileSystem
        self.executableInspector = executableInspector
        self.preflight = preflight ?? MihomoCorePreflight(
            descriptorLoader: JSONMihomoCoreDescriptorLoader(fileSystem: fileSystem),
            versionProbe: MihomoVersionProbe(
                processExecutor: processExecutor,
                timeout: versionProbeTimeout
            )
        )
        self.versionArguments = versionArguments
        self.versionProbeTimeout = versionProbeTimeout
    }

    init(
        executableURL: URL,
        processExecutor: any ProcessExecuting = ProcessExecutor(),
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        executableInspector: any MihomoExecutableInspecting = LocalMihomoExecutableInspector(),
        versionArguments: [String] = ["-v"],
        versionProbeTimeout: Duration = .seconds(3)
    ) {
        candidate = .explicit(executableURL)
        self.processExecutor = processExecutor
        self.fileSystem = fileSystem
        self.executableInspector = executableInspector
        preflight = MihomoCorePreflight()
        self.versionArguments = versionArguments
        self.versionProbeTimeout = versionProbeTimeout
    }

    func resolve() async throws -> ResolvedMihomoExecutable {
        let executableURL: URL
        switch candidate {
        case let .bundled(applicationBundleURL, teamPolicy, currentDirectoryURL):
            return try await resolveBundled(
                applicationBundleURL: applicationBundleURL,
                teamPolicy: teamPolicy,
                versionProbeCurrentDirectoryURL: currentDirectoryURL
            )
        case let .explicit(url):
            executableURL = url
        }

        try verifyFile(at: executableURL)

        let checksum: String
        do {
            checksum = try sha256(of: executableURL)
        } catch let error as MihomoExecutableResolverError {
            throw error
        } catch {
            throw MihomoExecutableResolverError.checksumFailed(
                executableURL,
                message: error.localizedDescription
            )
        }

        let versionResult: ProcessExecutionResult
        do {
            versionResult = try await processExecutor.execute(
                ProcessExecutionRequest(
                    executableURL: executableURL,
                    arguments: versionArguments,
                    environment: MihomoChildEnvironment.sanitized(),
                    currentDirectoryURL: executableURL.deletingLastPathComponent(),
                    timeout: versionProbeTimeout
                )
            )
        } catch {
            throw MihomoExecutableResolverError.versionProbeFailed(
                exitCode: nil,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        guard versionResult.succeeded else {
            throw MihomoExecutableResolverError.versionProbeFailed(
                exitCode: versionResult.terminationStatus,
                stdout: versionResult.stdout,
                stderr: versionResult.stderr
            )
        }

        let version = [versionResult.stdout, versionResult.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let version else {
            throw MihomoExecutableResolverError.versionOutputMissing(
                stdout: versionResult.stdout,
                stderr: versionResult.stderr
            )
        }

        return ResolvedMihomoExecutable(
            url: executableURL,
            version: version,
            sha256: checksum
        )
    }

    private func resolveBundled(
        applicationBundleURL: URL,
        teamPolicy: CodeSignatureTeamPolicy,
        versionProbeCurrentDirectoryURL: URL?
    ) async throws -> ResolvedMihomoExecutable {
        let result: MihomoCorePreflightResult
        do {
            result = try await preflight.run(
                MihomoCorePreflightRequest(
                    applicationBundleURL: applicationBundleURL,
                    signatureTeamPolicy: teamPolicy,
                    versionProbeCurrentDirectoryURL: versionProbeCurrentDirectoryURL
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MihomoCorePreflightError {
            throw MihomoExecutableResolverError.preflightFailed(error)
        } catch {
            throw MihomoExecutableResolverError.preflightFailed(
                .unexpected(stage: .manifest, message: error.localizedDescription)
            )
        }

        let checksum = try sha256(of: result.executableURL)
        let displayVersion = result.version.rawOutput
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? result.descriptor.version
        return ResolvedMihomoExecutable(
            url: result.executableURL,
            version: displayVersion,
            sha256: checksum,
            preflight: result
        )
    }

    private func verifyFile(at url: URL) throws {
        guard fileSystem.fileExists(at: url) else {
            throw MihomoExecutableResolverError.executableMissing(url)
        }
        guard !executableInspector.isDirectory(at: url) else {
            throw MihomoExecutableResolverError.executableIsDirectory(url)
        }
        guard executableInspector.isExecutable(at: url) else {
            throw MihomoExecutableResolverError.executableNotRunnable(url)
        }
    }

    private func sha256(of url: URL) throws -> String {
        do {
            return SHA256.hash(data: try fileSystem.readData(at: url))
                .map { String(format: "%02x", $0) }
                .joined()
        } catch {
            throw MihomoExecutableResolverError.checksumFailed(
                url,
                message: error.localizedDescription
            )
        }
    }

    #if DEBUG
    private nonisolated static let liveTeamPolicy: CodeSignatureTeamPolicy = .developmentAllowsAdHoc
    #else
    private nonisolated static let liveTeamPolicy: CodeSignatureTeamPolicy = .distribution
    #endif
}
