import Darwin
import Foundation
import VelaIPC

public struct FixedPrivilegedBundleLayout: Equatable, Sendable {
    public let applicationURL: URL
    public let helperURL: URL
    public let mihomoURL: URL

    public init(applicationURL: URL) throws {
        let applicationURL = applicationURL.standardizedFileURL
        guard applicationURL.isFileURL,
            applicationURL.pathExtension == "app",
            applicationURL.path.hasPrefix("/")
        else {
            throw FixedMihomoPreflightError.invalidBundleLayout
        }
        self.applicationURL = applicationURL
        helperURL = applicationURL
            .appending(path: "Contents/Library/LaunchServices/VelaHelper")
        mihomoURL = applicationURL.appending(path: "Contents/Helpers/mihomo")
    }

    /// Derives the app from the Helper's own executable path. Callers must pass
    /// `_NSGetExecutablePath`/`CommandLine.arguments[0]`, never an XPC value.
    public static func derive(helperExecutableURL: URL) throws -> Self {
        let helper = helperExecutableURL.standardizedFileURL
        let suffix = "/Contents/Library/LaunchServices/VelaHelper"
        guard helper.path.hasSuffix(suffix) else {
            throw FixedMihomoPreflightError.invalidBundleLayout
        }
        let applicationPath = String(helper.path.dropLast(suffix.count))
        let layout = try FixedPrivilegedBundleLayout(
            applicationURL: URL(fileURLWithPath: applicationPath, isDirectory: true)
        )
        guard layout.helperURL.standardizedFileURL.path == helper.path else {
            throw FixedMihomoPreflightError.invalidBundleLayout
        }
        return layout
    }
}

public struct FixedMihomoPreflightResult: Equatable, Sendable {
    public let executable: TrustedMihomoExecutable
    public let helperSignature: PrivilegedCodeSignature
    public let mihomoSignature: PrivilegedCodeSignature
    public let executableIdentity: POSIXFileIdentity
    public let versionOutput: String
}

public struct MihomoVersionProbeResult: Equatable, Sendable {
    public let status: Int32
    public let output: String
    public let timedOut: Bool

    public init(status: Int32, output: String, timedOut: Bool) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
    }
}

public protocol FixedMihomoPreflighting: Sendable {
    func run(
        executable: TrustedMihomoExecutable,
        expectedHelperSignature: PrivilegedCodeSignature,
        workingDirectoryURL: URL
    ) async throws -> FixedMihomoPreflightResult
}

public protocol FixedMihomoVersionProbing: Sendable {
    func probe(executableURL: URL, workingDirectoryURL: URL) async throws
        -> MihomoVersionProbeResult
}

public actor FoundationFixedMihomoVersionProbe: FixedMihomoVersionProbing {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(3)) {
        self.timeout = timeout
    }

    public func probe(
        executableURL: URL,
        workingDirectoryURL: URL
    ) async throws -> MihomoVersionProbeResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-v"]
        process.currentDirectoryURL = workingDirectoryURL
        process.environment = [
            "HOME": workingDirectoryURL.path,
            "PATH": "/usr/bin:/bin",
            "TMPDIR": URL.temporaryDirectory.path,
        ]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let capturedOutput = BoundedCommandOutput(maximumBytes: 64 * 1_024)
        output.fileHandleForReading.readabilityHandler = { readable in
            let data = readable.availableData
            if !data.isEmpty { capturedOutput.append(data) }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            output.fileHandleForWriting.closeFile()
            try? output.fileHandleForReading.close()
            throw FixedMihomoPreflightError.versionProbeFailed
        }

        let termination = await BoundedProcessWaiter.wait(
            for: process,
            timeout: timeout
        )
        output.fileHandleForReading.readabilityHandler = nil
        output.fileHandleForWriting.closeFile()
        if termination.exited {
            capturedOutput.append(output.fileHandleForReading.readDataToEndOfFile())
        }
        try? output.fileHandleForReading.close()
        return MihomoVersionProbeResult(
            status: termination.exited ? process.terminationStatus : SIGKILL,
            output: String(decoding: capturedOutput.data(), as: UTF8.self),
            timedOut: termination.timedOut
        )
    }
}

public struct FixedMihomoPreflight: FixedMihomoPreflighting, Sendable {
    private let executableStore: TrustedMihomoExecutableStore
    private let signingInspector: any PrivilegedCodeSigningInspecting
    private let versionProbe: any FixedMihomoVersionProbing
    private let expectedVersion: String

    public init(
        executableStore: TrustedMihomoExecutableStore,
        signingInspector: any PrivilegedCodeSigningInspecting =
            SecurityPrivilegedCodeSigningInspector(),
        versionProbe: any FixedMihomoVersionProbing = FoundationFixedMihomoVersionProbe(),
        expectedVersion: String = VelaIPCConstants.expectedMihomoVersion
    ) {
        self.executableStore = executableStore
        self.signingInspector = signingInspector
        self.versionProbe = versionProbe
        self.expectedVersion = expectedVersion
    }

    public func run(
        executable: TrustedMihomoExecutable,
        expectedHelperSignature: PrivilegedCodeSignature,
        workingDirectoryURL: URL
    ) async throws -> FixedMihomoPreflightResult {
        guard expectedHelperSignature.signingIdentifier == VelaIPCConstants.helperIdentifier,
            !expectedHelperSignature.teamIdentifier.isEmpty
        else {
            throw FixedMihomoPreflightError.signingIdentifierMismatch
        }
        let before = try executableStore.revalidate(executable)
        guard before.identity == executable.identity else {
            throw FixedMihomoPreflightError.executableChanged
        }
        let architecture = try inspectArchitecture(at: before.url)
        guard architecture == .arm64 else {
            throw FixedMihomoPreflightError.architectureMismatch
        }

        let mihomo = try signingInspector.inspect(at: before.url, validateNestedCode: false)
        guard [
            VelaIPCConstants.expectedMihomoSigningIdentifier,
            VelaIPCConstants.expectedExternalCoreSigningIdentifier,
        ].contains(mihomo.signingIdentifier) else {
            throw FixedMihomoPreflightError.signingIdentifierMismatch
        }
        guard expectedHelperSignature.teamIdentifier == mihomo.teamIdentifier else {
            throw FixedMihomoPreflightError.teamIdentifierMismatch
        }

        let probe = try await versionProbe.probe(
            executableURL: before.url,
            workingDirectoryURL: workingDirectoryURL
        )
        guard !probe.timedOut else { throw FixedMihomoPreflightError.versionProbeTimedOut }
        guard probe.status == 0 else { throw FixedMihomoPreflightError.versionProbeFailed }
        guard isExpectedVersionOutput(probe.output) else {
            throw FixedMihomoPreflightError.versionMismatch
        }

        let after = try executableStore.revalidate(before)
        guard before.identity == after.identity else {
            throw FixedMihomoPreflightError.executableChanged
        }
        let finalMihomo = try signingInspector.inspect(
            at: after.url,
            validateNestedCode: false
        )
        guard finalMihomo == mihomo else {
            throw FixedMihomoPreflightError.executableChanged
        }

        return FixedMihomoPreflightResult(
            executable: after,
            helperSignature: expectedHelperSignature,
            mihomoSignature: finalMihomo,
            executableIdentity: after.identity,
            versionOutput: probe.output
        )
    }

    private func inspectArchitecture(at url: URL) throws -> MachOShape {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 8), data.count == 8 else {
            throw FixedMihomoPreflightError.invalidMachO
        }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        if magic == 0xcafebabe || magic == 0xbebafeca
            || magic == 0xcafebabf || magic == 0xbfbafeca
        {
            return .fat
        }
        guard magic == UInt32(MH_MAGIC_64) else {
            throw FixedMihomoPreflightError.invalidMachO
        }
        let cpuType = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: Int32.self)
        }.littleEndian
        return cpuType == CPU_TYPE_ARM64 ? .arm64 : .other
    }

    private func isExpectedVersionOutput(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let tokens = line.split(whereSeparator: \.isWhitespace)
            return tokens.count >= 5
                && tokens[0] == "Mihomo"
                && tokens[1] == "Meta"
                && tokens[2] == Substring(expectedVersion)
                && tokens[3] == "darwin"
                && tokens[4] == "arm64"
        }
    }
}

private enum MachOShape {
    case arm64
    case fat
    case other
}

public enum FixedMihomoPreflightError: Error, Equatable, Sendable {
    case invalidBundleLayout
    case executableMissing
    case executableIsSymlink
    case executableNotRegular
    case executableNotRunnable
    case invalidMachO
    case architectureMismatch
    case signingIdentifierMismatch
    case teamIdentifierMismatch
    case versionProbeTimedOut
    case versionProbeFailed
    case versionMismatch
    case executableChanged
}
