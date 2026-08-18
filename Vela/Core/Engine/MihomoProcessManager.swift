import Darwin
import CryptoKit
import Foundation
import LightweightCodeRequirements
import OSLog
import Security
import Synchronization
import VelaIPC

nonisolated enum MihomoProcessOutputChannel: String, Equatable, Sendable {
    case stdout
    case stderr
}

nonisolated struct MihomoProcessOutput: Equatable, Sendable {
    let id: UUID
    let channel: MihomoProcessOutputChannel
    let text: String
    let timestamp: Date
}

nonisolated struct MihomoProcessSnapshot: Equatable, Sendable {
    let pid: Int32?
    let isRunning: Bool
    let executable: ResolvedMihomoExecutable?
    let configurationURL: URL?
    let startedAt: Date?

    static let stopped = MihomoProcessSnapshot(
        pid: nil,
        isRunning: false,
        executable: nil,
        configurationURL: nil,
        startedAt: nil
    )
}

nonisolated struct MihomoPreparedLaunch: Equatable, Sendable {
    let executable: ResolvedMihomoExecutable
    let configurationURL: URL
    let dataDirectoryURL: URL
    let additionalArguments: [String]
    let validationTimeout: Duration
    let validationResult: ConfigurationValidationResult

    init(
        executable: ResolvedMihomoExecutable,
        configurationURL: URL,
        dataDirectoryURL: URL,
        additionalArguments: [String] = [],
        validationTimeout: Duration = .seconds(10),
        validationResult: ConfigurationValidationResult
    ) {
        self.executable = executable
        self.configurationURL = configurationURL.standardizedFileURL
        self.dataDirectoryURL = dataDirectoryURL.standardizedFileURL
        self.additionalArguments = additionalArguments
        self.validationTimeout = validationTimeout
        self.validationResult = validationResult
    }
}

nonisolated struct MihomoProcessTermination: Equatable, Sendable {
    let pid: Int32
    let status: Int32
    let reason: ProcessTerminationReason
    let expected: Bool
    let forced: Bool
    let stdout: String
    let stderr: String
    let startedAt: Date
    let endedAt: Date
}

nonisolated enum MihomoProcessEvent: Equatable, Sendable {
    case started(MihomoProcessSnapshot)
    case output(MihomoProcessOutput)
    case terminated(MihomoProcessTermination)
}

nonisolated enum MihomoProcessManagerError: Error, Equatable, Sendable {
    case executableResolutionFailed(message: String)
    case configurationInvalid(ConfigurationValidationResult)
    case launchPreparationInProgress
    case alreadyRunningWithDifferentConfiguration
    case stopInProgress
    case unsafeAdditionalArguments([String])
    case coreIntegrityChanged(path: String, message: String)
    case launchFailed(executableURL: URL, message: String)
    case stopFailed(pid: Int32, message: String)
}

extension MihomoProcessManagerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .executableResolutionFailed(message):
            "Could not resolve the Mihomo executable: \(message)"
        case let .configurationInvalid(result):
            "Mihomo configuration validation failed: \(result.copyableError)"
        case .launchPreparationInProgress:
            "Mihomo is already preparing a different launch request."
        case .alreadyRunningWithDifferentConfiguration:
            "Mihomo is already running with a different configuration."
        case .stopInProgress:
            "Mihomo is currently stopping."
        case let .unsafeAdditionalArguments(arguments):
            "Mihomo launch arguments cannot override Vela-managed flags: \(arguments.joined(separator: " "))."
        case let .coreIntegrityChanged(path, message):
            "The bundled Mihomo core changed after preflight at \(path): \(message)"
        case let .launchFailed(executableURL, message):
            "Could not launch Mihomo at \(executableURL.path): \(message)"
        case let .stopFailed(pid, message):
            "Could not stop the managed Mihomo process \(pid): \(message)"
        }
    }
}

protocol MihomoProcessManaging: Sendable {
    func start(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration
    ) async throws -> MihomoProcessSnapshot

    func start(preparedLaunch: MihomoPreparedLaunch) async throws -> MihomoProcessSnapshot

    func stop(timeout: Duration) async throws -> MihomoProcessTermination?

    func restart(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration,
        stopTimeout: Duration
    ) async throws -> MihomoProcessSnapshot

    func isRunning() async -> Bool
    func snapshot() async -> MihomoProcessSnapshot
    func events() async -> AsyncStream<MihomoProcessEvent>
}

extension MihomoProcessManaging {
    func start(preparedLaunch: MihomoPreparedLaunch) async throws -> MihomoProcessSnapshot {
        try await start(
            configurationURL: preparedLaunch.configurationURL,
            dataDirectoryURL: preparedLaunch.dataDirectoryURL,
            additionalArguments: preparedLaunch.additionalArguments,
            validationTimeout: preparedLaunch.validationTimeout
        )
    }
}

actor MihomoProcessManager: MihomoProcessManaging {
    private let resolver: any MihomoExecutableResolving
    private let validator: any ConfigurationValidating
    private let environment: [String: String]
    private let beforeAtomicProcessRun: @Sendable () -> Void

    private var managedProcess: ManagedMihomoProcess?
    private var preparation: LaunchPreparationTask?
    private var lastTermination: MihomoProcessTermination?
    private var eventContinuations: [UUID: AsyncStream<MihomoProcessEvent>.Continuation] = [:]
    private var isStopping = false

    init(
        resolver: any MihomoExecutableResolving = MihomoExecutableResolver(),
        validator: any ConfigurationValidating = ConfigurationValidator(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        beforeAtomicProcessRun: @escaping @Sendable () -> Void = {}
    ) {
        self.resolver = resolver
        self.validator = validator
        self.environment = environment
        self.beforeAtomicProcessRun = beforeAtomicProcessRun
    }

    func start(
        configurationURL: URL,
        dataDirectoryURL: URL? = nil,
        additionalArguments: [String] = [],
        validationTimeout: Duration = .seconds(10)
    ) async throws -> MihomoProcessSnapshot {
        guard !isStopping else {
            throw MihomoProcessManagerError.stopInProgress
        }

        guard additionalArguments.isEmpty else {
            throw MihomoProcessManagerError.unsafeAdditionalArguments(additionalArguments)
        }

        let launchRequest = MihomoLaunchRequest(
            configurationURL: configurationURL.standardizedFileURL,
            dataDirectoryURL: (
                dataDirectoryURL ?? configurationURL.deletingLastPathComponent()
            ).standardizedFileURL,
            additionalArguments: additionalArguments,
            validationTimeout: validationTimeout
        )

        if let managedProcess, managedProcess.process.isRunning {
            guard managedProcess.launchRequest.runtimeEquivalent(to: launchRequest) else {
                throw MihomoProcessManagerError.alreadyRunningWithDifferentConfiguration
            }
            return makeSnapshot(for: managedProcess)
        }

        if let managedProcess {
            _ = finishTermination(
                runID: managedProcess.runID,
                status: managedProcess.process.terminationStatus,
                reason: processTerminationReason(managedProcess.process.terminationReason)
            )
        }

        let preparationTask: LaunchPreparationTask
        if let preparation {
            guard preparation.request == launchRequest else {
                throw MihomoProcessManagerError.launchPreparationInProgress
            }
            preparationTask = preparation
        } else {
            let id = UUID()
            let resolver = self.resolver
            let validator = self.validator
            let task = Task<MihomoPreparedLaunch, Error> {
                let executable: ResolvedMihomoExecutable
                do {
                    executable = try await resolver.resolve()
                } catch {
                    throw MihomoProcessManagerError.executableResolutionFailed(
                        message: error.localizedDescription
                    )
                }

                let validation = await validator.validate(
                    configurationURL: launchRequest.configurationURL,
                    dataDirectoryURL: launchRequest.dataDirectoryURL,
                    using: executable,
                    timeout: launchRequest.validationTimeout
                )
                try Task.checkCancellation()
                guard validation.isValid else {
                    throw MihomoProcessManagerError.configurationInvalid(validation)
                }

                return MihomoPreparedLaunch(
                    executable: executable,
                    configurationURL: launchRequest.configurationURL,
                    dataDirectoryURL: launchRequest.dataDirectoryURL,
                    additionalArguments: launchRequest.additionalArguments,
                    validationTimeout: launchRequest.validationTimeout,
                    validationResult: validation
                )
            }
            let created = LaunchPreparationTask(
                id: id,
                request: launchRequest,
                task: task
            )
            preparation = created
            preparationTask = created
        }

        let preparedLaunch: MihomoPreparedLaunch
        do {
            preparedLaunch = try await preparationTask.task.value
        } catch {
            if preparation?.id == preparationTask.id {
                preparation = nil
            }
            throw error
        }

        if preparation?.id == preparationTask.id {
            preparation = nil
        }

        // Another reentrant start may have completed the shared preparation first.
        if let managedProcess, managedProcess.process.isRunning {
            return makeSnapshot(for: managedProcess)
        }

        return try launch(preparedLaunch)
    }

    func start(preparedLaunch: MihomoPreparedLaunch) async throws -> MihomoProcessSnapshot {
        guard !isStopping else {
            throw MihomoProcessManagerError.stopInProgress
        }
        guard preparedLaunch.validationResult.isValid else {
            throw MihomoProcessManagerError.configurationInvalid(
                preparedLaunch.validationResult
            )
        }
        guard preparedLaunch.additionalArguments.isEmpty else {
            throw MihomoProcessManagerError.unsafeAdditionalArguments(
                preparedLaunch.additionalArguments
            )
        }

        let launchRequest = MihomoLaunchRequest(preparedLaunch: preparedLaunch)
        if let managedProcess, managedProcess.process.isRunning {
            guard managedProcess.launchRequest.runtimeEquivalent(to: launchRequest) else {
                throw MihomoProcessManagerError.alreadyRunningWithDifferentConfiguration
            }
            return makeSnapshot(for: managedProcess)
        }
        guard preparation == nil else {
            throw MihomoProcessManagerError.launchPreparationInProgress
        }

        return try launch(preparedLaunch)
    }

    func stop(timeout: Duration = .seconds(3)) async throws -> MihomoProcessTermination? {
        guard !isStopping else { return nil }
        isStopping = true
        defer { isStopping = false }

        if let preparation {
            self.preparation = nil
            preparation.task.cancel()
            _ = try? await preparation.task.value
        }

        guard let managedProcess else {
            return nil
        }

        let process = managedProcess.process
        let ownedPID = managedProcess.pid
        managedProcess.stopRequested = true

        if process.isRunning {
            process.terminate()
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                // Stopping an owned child remains mandatory when the caller is cancelled.
            }
        }

        if process.isRunning, process.processIdentifier == ownedPID {
            managedProcess.forceKilled = true
            _ = Darwin.kill(ownedPID, SIGKILL)
        }

        let forcedDeadline = clock.now.advanced(by: .seconds(1))
        while process.isRunning, clock.now < forcedDeadline {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                // Continue bounded cleanup.
            }
        }

        guard !process.isRunning else {
            throw MihomoProcessManagerError.stopFailed(
                pid: ownedPID,
                message: "The process remained alive after SIGTERM and SIGKILL."
            )
        }

        if let termination = finishTermination(
            runID: managedProcess.runID,
            status: process.terminationStatus,
            reason: processTerminationReason(process.terminationReason)
        ) {
            return termination
        }

        return lastTermination?.pid == ownedPID ? lastTermination : nil
    }

    func restart(
        configurationURL: URL,
        dataDirectoryURL: URL? = nil,
        additionalArguments: [String] = [],
        validationTimeout: Duration = .seconds(10),
        stopTimeout: Duration = .seconds(3)
    ) async throws -> MihomoProcessSnapshot {
        _ = try await stop(timeout: stopTimeout)
        return try await start(
            configurationURL: configurationURL,
            dataDirectoryURL: dataDirectoryURL,
            additionalArguments: additionalArguments,
            validationTimeout: validationTimeout
        )
    }

    func isRunning() async -> Bool {
        managedProcess?.process.isRunning == true
    }

    func snapshot() async -> MihomoProcessSnapshot {
        guard let managedProcess else { return .stopped }
        return makeSnapshot(for: managedProcess)
    }

    func events() async -> AsyncStream<MihomoProcessEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1_000)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
        }
    }

    private func launch(_ prepared: MihomoPreparedLaunch) throws -> MihomoProcessSnapshot {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let outputBuffer = ProcessOutputBuffer()
        let runID = UUID()

        var arguments = [
            "-d", prepared.dataDirectoryURL.path,
            "-f", prepared.configurationURL.path,
        ]
        arguments.append(contentsOf: prepared.additionalArguments)

        process.executableURL = prepared.executable.url
        process.arguments = arguments
        process.environment = MihomoChildEnvironment.sanitized(environment)
        process.currentDirectoryURL = prepared.dataDirectoryURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        configureOutputHandler(
            for: stdoutPipe.fileHandleForReading,
            runID: runID,
            channel: .stdout,
            outputBuffer: outputBuffer
        )
        configureOutputHandler(
            for: stderrPipe.fileHandleForReading,
            runID: runID,
            channel: .stderr,
            outputBuffer: outputBuffer
        )

        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            let reason = terminatedProcess.terminationReason == .exit
                ? ProcessTerminationReason.exit
                : ProcessTerminationReason.uncaughtSignal
            Task {
                await self?.processDidTerminate(runID: runID, status: status, reason: reason)
            }
        }

        let startedAt = Date()
        let managed = ManagedMihomoProcess(
            runID: runID,
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            outputBuffer: outputBuffer,
            executable: prepared.executable,
            launchRequest: MihomoLaunchRequest(preparedLaunch: prepared),
            startedAt: startedAt
        )

        Logger(subsystem: "dev.yilin.Vela", category: "MihomoProcessManager").info(
            "Launching verified Mihomo version=\(prepared.executable.version, privacy: .public) sha256=\(prepared.executable.sha256, privacy: .public)"
        )

        do {
            // Capture the exact code identity before the final pathname check.
            // If an attacker swaps the path before this point, verifyUnchanged
            // below rejects it. If they swap it after verification, the kernel
            // launch requirement rejects the different Code Directory hash.
            let launchBinding = try MihomoAtomicLaunchBinding.prepare(
                for: prepared.executable
            )
            process.launchRequirement = launchBinding?.launchRequirement
            try MihomoVerifiedExecutableGuard.verifyUnchanged(prepared.executable)
            beforeAtomicProcessRun()
            do {
                try process.run()
            } catch {
                // A launch-requirement denial is surfaced by Foundation as a
                // generic Process launch error. Re-inspect the path so an
                // observable post-preflight replacement is reported as an
                // integrity failure, while ordinary launch failures retain
                // their existing error classification.
                try MihomoVerifiedExecutableGuard.verifyUnchanged(prepared.executable)
                throw error
            }
            if let launchBinding {
                do {
                    try launchBinding.verifyRunningProcess(
                        pid: process.processIdentifier,
                        expectedFile: prepared.executable.verifiedFile
                    )
                } catch {
                    Self.killAndReapRejectedProcess(process)
                    throw error
                }
            }
        } catch let error as MihomoAtomicLaunchBindingError {
            managed.closeHandles()
            throw MihomoProcessManagerError.coreIntegrityChanged(
                path: prepared.executable.url.path,
                message: error.localizedDescription
            )
        } catch let error as MihomoVerifiedExecutableGuardError {
            managed.closeHandles()
            throw MihomoProcessManagerError.coreIntegrityChanged(
                path: prepared.executable.url.path,
                message: error.localizedDescription
            )
        } catch {
            managed.closeHandles()
            throw MihomoProcessManagerError.launchFailed(
                executableURL: prepared.executable.url,
                message: error.localizedDescription
            )
        }

        managedProcess = managed
        lastTermination = nil
        let snapshot = makeSnapshot(for: managed)
        emit(.started(snapshot))
        return snapshot
    }

    private nonisolated static func killAndReapRejectedProcess(_ process: Process) {
        let pid = process.processIdentifier
        if pid > 0, process.isRunning {
            _ = Darwin.kill(pid, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func configureOutputHandler(
        for handle: FileHandle,
        runID: UUID,
        channel: MihomoProcessOutputChannel,
        outputBuffer: ProcessOutputBuffer
    ) {
        handle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            guard !data.isEmpty else {
                readableHandle.readabilityHandler = nil
                return
            }

            outputBuffer.append(data, to: channel)
            let output = MihomoProcessOutput(
                id: UUID(),
                channel: channel,
                text: String(decoding: data, as: UTF8.self),
                timestamp: Date()
            )
            Task { await self?.receive(output: output, runID: runID) }
        }
    }

    private func receive(output: MihomoProcessOutput, runID: UUID) {
        guard managedProcess?.runID == runID else { return }
        emit(.output(output))
    }

    private func processDidTerminate(
        runID: UUID,
        status: Int32,
        reason: ProcessTerminationReason
    ) {
        _ = finishTermination(runID: runID, status: status, reason: reason)
    }

    @discardableResult
    private func finishTermination(
        runID: UUID,
        status: Int32,
        reason: ProcessTerminationReason
    ) -> MihomoProcessTermination? {
        guard let managedProcess, managedProcess.runID == runID else { return nil }

        managedProcess.drainRemainingOutput()
        managedProcess.closeHandles()
        let capturedOutput = managedProcess.outputBuffer.snapshot()
        let termination = MihomoProcessTermination(
            pid: managedProcess.pid,
            status: status,
            reason: reason,
            expected: managedProcess.stopRequested,
            forced: managedProcess.forceKilled,
            stdout: String(decoding: capturedOutput.stdout, as: UTF8.self),
            stderr: String(decoding: capturedOutput.stderr, as: UTF8.self),
            startedAt: managedProcess.startedAt,
            endedAt: Date()
        )

        self.managedProcess = nil
        lastTermination = termination
        emit(.terminated(termination))
        return termination
    }

    private func makeSnapshot(for managedProcess: ManagedMihomoProcess) -> MihomoProcessSnapshot {
        MihomoProcessSnapshot(
            pid: managedProcess.pid,
            isRunning: managedProcess.process.isRunning,
            executable: managedProcess.executable,
            configurationURL: managedProcess.launchRequest.configurationURL,
            startedAt: managedProcess.startedAt
        )
    }

    private func processTerminationReason(
        _ reason: Process.TerminationReason
    ) -> ProcessTerminationReason {
        reason == .exit ? .exit : .uncaughtSignal
    }

    private func emit(_ event: MihomoProcessEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations[id] = nil
    }
}

/// A kernel-enforced launch constraint plus the post-spawn identity needed to
/// prove that the child which will become visible to EngineStore is the exact
/// code image whose bytes were preflighted.
nonisolated private struct MihomoAtomicLaunchBinding {
    let launchRequirement: LaunchCodeRequirement
    let runningRequirement: ProcessCodeRequirement?

    static func prepare(
        for executable: ResolvedMihomoExecutable
    ) throws -> MihomoAtomicLaunchBinding? {
        #if DEBUG
        // Unit tests intentionally use tiny shell fixtures. Real Factory and
        // User Core artifacts are Mach-O files and never take this branch.
        if isTestScript(at: executable.url) {
            return nil
        }
        #endif

        // Never derive the kernel launch requirement from whatever happens to
        // occupy the pathname at this instant. A same-user attacker could
        // otherwise alternate an untrusted signed image with the preflighted
        // image around the separate pathname checks and make us bind the
        // requirement to the attacker's Code Directory. Parse the CDHashes
        // from one in-memory byte sequence whose full SHA-256 is already bound
        // to the preflight result instead.
        let expectedCodeDirectoryHashes = try MihomoExpectedCodeIdentity.load(
            executable: executable
        )
        let externalUserCore = isExternalUserCoreExecutable(executable.url)
        let signingIdentifier = externalUserCore
            ? VelaIPCConstants.expectedExternalCoreSigningIdentifier
            : executable.preflight?.signature.helper.signingIdentifier
        let teamIdentifier = externalUserCore
            ? try currentProcessTeamIdentifier()
            : executable.preflight?.signature.teamIdentifier

        let launchRequirement: LaunchCodeRequirement
        do {
            launchRequirement = try LaunchCodeRequirement.allOf {
                CodeDirectoryHash.in(expectedCodeDirectoryHashes)
                if let signingIdentifier {
                    SigningIdentifier(signingIdentifier)
                }
                if let teamIdentifier {
                    TeamIdentifier(teamIdentifier)
                }
                if externalUserCore {
                    // Development and Developer ID are both Apple trust
                    // categories. Ad-hoc remains Factory/DEBUG-only.
                    ValidationCategory.in(.development, .developerID)
                }
            }
        } catch {
            throw MihomoAtomicLaunchBindingError.requirementConstructionFailed(
                reason: error.localizedDescription
            )
        }

        let runningRequirement: ProcessCodeRequirement?
        if externalUserCore {
            do {
                runningRequirement = try ProcessCodeRequirement(launchRequirement)
            } catch {
                throw MihomoAtomicLaunchBindingError.requirementConstructionFailed(
                    reason: error.localizedDescription
                )
            }
            var staticCode: SecStaticCode?
            let creationStatus = SecStaticCodeCreateWithPath(
                executable.url as CFURL,
                SecCSFlags(),
                &staticCode
            )
            guard creationStatus == errSecSuccess, let staticCode else {
                throw MihomoAtomicLaunchBindingError.staticCodeCreationFailed(
                    status: creationStatus
                )
            }
            do {
                let onDiskRequirement = try OnDiskCodeRequirement(launchRequirement)
                let validation = SecStaticCodeCheckValidityWithOnDiskRequirement(
                    code: staticCode,
                    flags: SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)),
                    requirement: onDiskRequirement
                )
                guard validation.signatureIsValid, validation.requirementMatched else {
                    throw MihomoAtomicLaunchBindingError.onDiskRequirementRejected(
                        status: validation.failureReason
                    )
                }
            } catch let error as MihomoAtomicLaunchBindingError {
                throw error
            } catch {
                throw MihomoAtomicLaunchBindingError.requirementConstructionFailed(
                    reason: error.localizedDescription
                )
            }
        } else {
            runningRequirement = nil
        }

        return MihomoAtomicLaunchBinding(
            launchRequirement: launchRequirement,
            runningRequirement: runningRequirement
        )
    }

    func verifyRunningProcess(
        pid: Int32,
        expectedFile: MihomoCoreFileSnapshot?
    ) throws {
        guard let expectedFile else {
            throw MihomoAtomicLaunchBindingError.verifiedFileMissing
        }
        let runningFile = try MihomoRunningExecutableVnodeInspector.inspect(pid: pid)
        guard runningFile.deviceID == expectedFile.deviceID,
            runningFile.inode == expectedFile.inode
        else {
            throw MihomoAtomicLaunchBindingError.runningExecutableChanged
        }

        guard let runningRequirement else { return }
        var runningCode: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        let guestStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &runningCode
        )
        guard guestStatus == errSecSuccess, let runningCode else {
            throw MihomoAtomicLaunchBindingError.runningCodeUnavailable(
                status: guestStatus
            )
        }
        let validation = SecCodeCheckValidityWithProcessRequirement(
            code: runningCode,
            flags: SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)),
            requirement: runningRequirement
        )
        guard validation.signatureIsValid, validation.requirementMatched else {
            throw MihomoAtomicLaunchBindingError.runningRequirementRejected(
                status: validation.failureReason
            )
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func currentProcessTeamIdentifier() throws -> String {
        var currentCode: SecCode?
        let selfStatus = SecCodeCopySelf(SecCSFlags(), &currentCode)
        guard selfStatus == errSecSuccess, let currentCode else {
            throw MihomoAtomicLaunchBindingError.currentProcessCodeUnavailable(
                status: selfStatus
            )
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(
            currentCode,
            SecCSFlags(),
            &staticCode
        )
        guard staticStatus == errSecSuccess, let staticCode else {
            throw MihomoAtomicLaunchBindingError.currentProcessCodeUnavailable(
                status: staticStatus
            )
        }
        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &information
        )
        guard informationStatus == errSecSuccess, let information else {
            throw MihomoAtomicLaunchBindingError.signingInformationUnavailable(
                status: informationStatus
            )
        }
        let values = information as NSDictionary
        guard let teamIdentifier = normalized(
            values[kSecCodeInfoTeamIdentifier] as? String
        ) else {
            throw MihomoAtomicLaunchBindingError.teamIdentifierMissing
        }
        return teamIdentifier
    }

    private static func isExternalUserCoreExecutable(_ url: URL) -> Bool {
        let macOSDirectory = url.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        let bundleDirectory = contentsDirectory.deletingLastPathComponent()
        return url.lastPathComponent == "mihomo"
            && macOSDirectory.lastPathComponent == "MacOS"
            && contentsDirectory.lastPathComponent == "Contents"
            && bundleDirectory.lastPathComponent == "VelaMihomoCore.bundle"
    }

    #if DEBUG
    private static func isTestScript(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 2) else { return false }
        return prefix == Data([0x23, 0x21])
    }
    #endif
}

/// Extracts the kernel CDHashes from the exact byte sequence already pinned by
/// the resolver's SHA-256. This closes the gap that remains if a launch
/// requirement is assembled from a second pathname lookup.
nonisolated private enum MihomoExpectedCodeIdentity {
    static func load(executable: ResolvedMihomoExecutable) throws -> [Data] {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: executable.url)
        } catch {
            throw MihomoAtomicLaunchBindingError.executableReadFailed(
                reason: error.localizedDescription
            )
        }
        guard !bytes.isEmpty,
            bytes.count <= VelaIPCConstants.maximumMihomoExecutableBytes
        else {
            throw MihomoAtomicLaunchBindingError.executableSizeInvalid
        }

        let actualSHA256 = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualSHA256 == executable.sha256.lowercased() else {
            throw MihomoAtomicLaunchBindingError.expectedChecksumMismatch
        }

        do {
            let hashes = try MachOCodeDirectoryHashParser.parse(bytes)
            guard !hashes.isEmpty else {
                throw MihomoAtomicLaunchBindingError.codeDirectoryHashMissing
            }
            return hashes
        } catch let error as MihomoAtomicLaunchBindingError {
            throw error
        } catch {
            throw MihomoAtomicLaunchBindingError.malformedCodeSignature(
                reason: error.localizedDescription
            )
        }
    }
}

nonisolated private enum MachOCodeDirectoryHashParser {
    private static let maximumArchitectures = 32
    private static let maximumLoadCommands = 4_096
    private static let maximumSignatureBlobs = 64
    private static let cpuTypeARM64: UInt32 = 0x0100_000c
    private static let loadCommandCodeSignature: UInt32 = 0x1d
    private static let embeddedSignatureMagic: UInt32 = 0xfade_0cc0
    private static let codeDirectoryMagic: UInt32 = 0xfade_0c02

    private enum ByteOrder {
        case littleEndian
        case bigEndian
    }

    private struct Slice {
        let offset: Int
        let size: Int
    }

    private enum ParseError: LocalizedError {
        case malformed(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case let .malformed(reason):
                "Malformed Mach-O code signature: \(reason)."
            case let .unsupported(reason):
                "Unsupported Mach-O code signature: \(reason)."
            }
        }
    }

    static func parse(_ data: Data) throws -> [Data] {
        let slices = try slices(in: data)
        var seen: Set<Data> = []
        for slice in slices {
            for hash in try codeDirectoryHashes(in: slice, data: data) {
                seen.insert(hash)
            }
        }
        return seen.sorted { lhs, rhs in
            lhs.lexicographicallyPrecedes(rhs)
        }
    }

    private static func slices(in data: Data) throws -> [Slice] {
        let magic = try uint32(data, at: 0, order: .bigEndian)
        switch magic {
        case 0xcafe_babe, 0xcafe_babf:
            return try fatSlices(
                in: data,
                order: .bigEndian,
                is64Bit: magic == 0xcafe_babf
            )
        case 0xbeba_feca, 0xbfba_feca:
            return try fatSlices(
                in: data,
                order: .littleEndian,
                is64Bit: magic == 0xbfba_feca
            )
        default:
            return [Slice(offset: 0, size: data.count)]
        }
    }

    private static func fatSlices(
        in data: Data,
        order: ByteOrder,
        is64Bit: Bool
    ) throws -> [Slice] {
        let count = Int(try uint32(data, at: 4, order: order))
        guard (1 ... maximumArchitectures).contains(count) else {
            throw ParseError.malformed("invalid architecture count")
        }
        let entrySize = is64Bit ? 32 : 20
        try requireRange(offset: 8, length: count * entrySize, in: data.count)

        var arm64Slices: [Slice] = []
        for index in 0 ..< count {
            let entry = 8 + index * entrySize
            let cpuType = try uint32(data, at: entry, order: order)
            guard cpuType == cpuTypeARM64 else { continue }
            let offset: UInt64
            let size: UInt64
            if is64Bit {
                offset = try uint64(data, at: entry + 8, order: order)
                size = try uint64(data, at: entry + 16, order: order)
            } else {
                offset = UInt64(try uint32(data, at: entry + 8, order: order))
                size = UInt64(try uint32(data, at: entry + 12, order: order))
            }
            guard let sliceOffset = Int(exactly: offset),
                let sliceSize = Int(exactly: size),
                sliceSize > 0
            else {
                throw ParseError.malformed("invalid architecture bounds")
            }
            try requireRange(offset: sliceOffset, length: sliceSize, in: data.count)
            arm64Slices.append(Slice(offset: sliceOffset, size: sliceSize))
        }
        guard !arm64Slices.isEmpty else {
            throw ParseError.unsupported("no arm64 slice")
        }
        return arm64Slices
    }

    private static func codeDirectoryHashes(
        in slice: Slice,
        data: Data
    ) throws -> [Data] {
        let rawMagic = try uint32(data, at: slice.offset, order: .bigEndian)
        let order: ByteOrder
        let headerSize: Int
        switch rawMagic {
        case 0xcffa_edfe:
            order = .littleEndian
            headerSize = 32
        case 0xfeed_facf:
            order = .bigEndian
            headerSize = 32
        case 0xcefa_edfe:
            order = .littleEndian
            headerSize = 28
        case 0xfeed_face:
            order = .bigEndian
            headerSize = 28
        default:
            throw ParseError.malformed("invalid Mach-O magic")
        }
        try requireRange(offset: slice.offset, length: headerSize, in: data.count)
        let commandCount = Int(try uint32(data, at: slice.offset + 16, order: order))
        let commandBytes = Int(try uint32(data, at: slice.offset + 20, order: order))
        guard commandCount <= maximumLoadCommands else {
            throw ParseError.malformed("too many load commands")
        }
        let commandStart = slice.offset + headerSize
        guard commandBytes <= slice.size - headerSize else {
            throw ParseError.malformed("load commands exceed slice")
        }
        try requireRange(offset: commandStart, length: commandBytes, in: data.count)

        var cursor = commandStart
        let commandEnd = commandStart + commandBytes
        var signatureRanges: [Range<Int>] = []
        for _ in 0 ..< commandCount {
            try requireRange(offset: cursor, length: 8, in: commandEnd)
            let command = try uint32(data, at: cursor, order: order)
            let commandSize = Int(try uint32(data, at: cursor + 4, order: order))
            guard commandSize >= 8, commandSize <= commandEnd - cursor else {
                throw ParseError.malformed("invalid load command size")
            }
            if command == loadCommandCodeSignature {
                guard commandSize >= 16 else {
                    throw ParseError.malformed("short code signature command")
                }
                let relativeOffset = Int(
                    try uint32(data, at: cursor + 8, order: order)
                )
                let length = Int(try uint32(data, at: cursor + 12, order: order))
                guard relativeOffset <= slice.size,
                    length > 0,
                    length <= slice.size - relativeOffset
                else {
                    throw ParseError.malformed("code signature exceeds slice")
                }
                let start = slice.offset + relativeOffset
                signatureRanges.append(start ..< start + length)
            }
            cursor += commandSize
        }
        guard cursor <= commandEnd, !signatureRanges.isEmpty else {
            throw ParseError.malformed("missing embedded code signature")
        }

        var collectedHashes: [Data] = []
        for range in signatureRanges {
            collectedHashes.append(
                contentsOf: try hashes(inEmbeddedSignature: range, data: data)
            )
        }
        guard !collectedHashes.isEmpty else {
            throw ParseError.unsupported("no supported Code Directory")
        }
        return collectedHashes
    }

    private static func hashes(
        inEmbeddedSignature signatureRange: Range<Int>,
        data: Data
    ) throws -> [Data] {
        try requireRange(
            offset: signatureRange.lowerBound,
            length: 12,
            in: signatureRange.upperBound
        )
        guard try uint32(
            data,
            at: signatureRange.lowerBound,
            order: .bigEndian
        ) == embeddedSignatureMagic else {
            throw ParseError.malformed("invalid embedded signature magic")
        }
        let declaredLength = Int(try uint32(
            data,
            at: signatureRange.lowerBound + 4,
            order: .bigEndian
        ))
        let count = Int(try uint32(
            data,
            at: signatureRange.lowerBound + 8,
            order: .bigEndian
        ))
        guard declaredLength >= 12,
            declaredLength <= signatureRange.count,
            count <= maximumSignatureBlobs,
            count <= (declaredLength - 12) / 8
        else {
            throw ParseError.malformed("invalid embedded signature header")
        }

        let superblobEnd = signatureRange.lowerBound + declaredLength
        var hashes: [Data] = []
        for index in 0 ..< count {
            let entry = signatureRange.lowerBound + 12 + index * 8
            let slot = try uint32(data, at: entry, order: .bigEndian)
            guard slot == 0 || (0x1000 ... 0x1005).contains(slot) else { continue }
            let relativeOffset = Int(try uint32(
                data,
                at: entry + 4,
                order: .bigEndian
            ))
            guard relativeOffset <= declaredLength - 8 else {
                throw ParseError.malformed("invalid Code Directory offset")
            }
            let codeDirectoryStart = signatureRange.lowerBound + relativeOffset
            try requireRange(offset: codeDirectoryStart, length: 38, in: superblobEnd)
            guard try uint32(
                data,
                at: codeDirectoryStart,
                order: .bigEndian
            ) == codeDirectoryMagic else {
                throw ParseError.malformed("invalid Code Directory magic")
            }
            let length = Int(try uint32(
                data,
                at: codeDirectoryStart + 4,
                order: .bigEndian
            ))
            guard length >= 38, length <= superblobEnd - codeDirectoryStart else {
                throw ParseError.malformed("invalid Code Directory length")
            }
            let hashType = try byte(data, at: codeDirectoryStart + 37)
            let codeDirectory = data.subdata(
                in: codeDirectoryStart ..< codeDirectoryStart + length
            )
            guard let hash = cdHash(of: codeDirectory, hashType: hashType) else {
                continue
            }
            hashes.append(hash)
        }
        return hashes
    }

    private static func cdHash(of codeDirectory: Data, hashType: UInt8) -> Data? {
        let fullHash: Data
        switch hashType {
        case 1:
            fullHash = Data(Insecure.SHA1.hash(data: codeDirectory))
        case 2, 3:
            fullHash = Data(SHA256.hash(data: codeDirectory))
        case 4:
            fullHash = Data(SHA384.hash(data: codeDirectory))
        case 5:
            fullHash = Data(SHA512.hash(data: codeDirectory))
        default:
            return nil
        }
        return Data(fullHash.prefix(20))
    }

    private static func byte(_ data: Data, at offset: Int) throws -> UInt8 {
        try requireRange(offset: offset, length: 1, in: data.count)
        return data[data.startIndex + offset]
    }

    private static func uint32(
        _ data: Data,
        at offset: Int,
        order: ByteOrder
    ) throws -> UInt32 {
        let bytes = try (0 ..< 4).map { index in
            try byte(data, at: offset + index)
        }
        switch order {
        case .bigEndian:
            return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
        case .littleEndian:
            return bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
    }

    private static func uint64(
        _ data: Data,
        at offset: Int,
        order: ByteOrder
    ) throws -> UInt64 {
        let bytes = try (0 ..< 8).map { index in
            try byte(data, at: offset + index)
        }
        switch order {
        case .bigEndian:
            return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
        case .littleEndian:
            return bytes.reversed().reduce(0) { ($0 << 8) | UInt64($1) }
        }
    }

    private static func requireRange(
        offset: Int,
        length: Int,
        in upperBound: Int
    ) throws {
        guard offset >= 0,
            length >= 0,
            offset <= upperBound,
            length <= upperBound - offset
        else {
            throw ParseError.malformed("out-of-bounds data")
        }
    }
}

nonisolated private struct MihomoRunningExecutableVnode {
    let deviceID: UInt64
    let inode: UInt64
}

nonisolated private enum MihomoRunningExecutableVnodeInspector {
    private static let maximumRegionCount = 4_096
    private static let maximumAttempts = 20

    static func inspect(pid: Int32) throws -> MihomoRunningExecutableVnode {
        for attempt in 0 ..< maximumAttempts {
            if let identity = try inspectOnce(pid: pid) {
                return identity
            }
            guard Darwin.kill(pid, 0) == 0 else {
                throw MihomoAtomicLaunchBindingError.processExitedBeforeIdentityCheck
            }
            if attempt + 1 < maximumAttempts {
                usleep(1_000)
            }
        }
        throw MihomoAtomicLaunchBindingError.runningExecutableUnavailable
    }

    private static func inspectOnce(pid: Int32) throws -> MihomoRunningExecutableVnode? {
        var processPathBuffer = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN) * 4
        )
        let pathLength = proc_pidpath(
            pid,
            &processPathBuffer,
            UInt32(processPathBuffer.count)
        )
        guard pathLength > 0 else { return nil }
        let processPath = String(
            decoding: processPathBuffer.prefix(Int(pathLength)).map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )

        var address: UInt64 = 0
        for _ in 0 ..< maximumRegionCount {
            var region = proc_regionwithpathinfo()
            let count = proc_pidinfo(
                pid,
                PROC_PIDREGIONPATHINFO,
                address,
                &region,
                Int32(MemoryLayout<proc_regionwithpathinfo>.size)
            )
            guard count == MemoryLayout<proc_regionwithpathinfo>.size else {
                return nil
            }

            let regionPath = withUnsafePointer(to: &region.prp_vip.vip_path) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXPATHLEN)
                ) {
                    String(cString: $0)
                }
            }
            let stats = region.prp_vip.vip_vi.vi_stat
            if regionPath == processPath,
                region.prp_prinfo.pri_protection & UInt32(VM_PROT_EXECUTE) != 0,
                stats.vst_ino != 0
            {
                return MihomoRunningExecutableVnode(
                    deviceID: UInt64(stats.vst_dev),
                    inode: stats.vst_ino
                )
            }

            let nextAddress = region.prp_prinfo.pri_address
                &+ region.prp_prinfo.pri_size
            guard nextAddress > address else { return nil }
            address = nextAddress
        }
        throw MihomoAtomicLaunchBindingError.runningExecutableUnavailable
    }
}

nonisolated private enum MihomoAtomicLaunchBindingError: Error {
    case staticCodeCreationFailed(status: OSStatus)
    case currentProcessCodeUnavailable(status: OSStatus)
    case signingInformationUnavailable(status: OSStatus)
    case executableReadFailed(reason: String)
    case executableSizeInvalid
    case expectedChecksumMismatch
    case malformedCodeSignature(reason: String)
    case codeDirectoryHashMissing
    case signingIdentifierMissing
    case signingIdentifierMismatch(expected: String, actual: String)
    case teamIdentifierMissing
    case requirementConstructionFailed(reason: String)
    case onDiskRequirementRejected(status: OSStatus)
    case verifiedFileMissing
    case runningExecutableUnavailable
    case runningExecutableChanged
    case processExitedBeforeIdentityCheck
    case runningCodeUnavailable(status: OSStatus)
    case runningRequirementRejected(status: OSStatus)
}

extension MihomoAtomicLaunchBindingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .staticCodeCreationFailed(status):
            "Could not capture the Core code identity (\(Self.message(for: status)))."
        case let .currentProcessCodeUnavailable(status):
            "The current Vela code identity is unavailable (\(Self.message(for: status)))."
        case let .signingInformationUnavailable(status):
            "Core signing information is unavailable (\(Self.message(for: status)))."
        case let .executableReadFailed(reason):
            "The preflighted Core bytes could not be read for atomic launch binding: \(reason)"
        case .executableSizeInvalid:
            "The preflighted Core size is invalid for atomic launch binding."
        case .expectedChecksumMismatch:
            "The Core bytes no longer match the preflighted SHA-256."
        case let .malformedCodeSignature(reason):
            "The Core Code Directory could not be parsed for atomic launch binding: \(reason)"
        case .codeDirectoryHashMissing:
            "The Core has no Code Directory hash for atomic launch binding."
        case .signingIdentifierMissing:
            "The Core has no signing identifier for atomic launch binding."
        case let .signingIdentifierMismatch(expected, actual):
            "The User Core signing identifier must be \(expected); got \(actual)."
        case .teamIdentifierMissing:
            "The User Core has no Developer Team identifier."
        case let .requirementConstructionFailed(reason):
            "Could not construct the atomic Core launch requirement: \(reason)"
        case let .onDiskRequirementRejected(status):
            "The User Core no longer satisfies its Apple signing requirement (\(Self.message(for: status)))."
        case .verifiedFileMissing:
            "The Core has no verified vnode identity."
        case .runningExecutableUnavailable:
            "The launched Core executable vnode could not be identified."
        case .runningExecutableChanged:
            "The launched Core executable vnode differs from the preflight snapshot."
        case .processExitedBeforeIdentityCheck:
            "The Core exited before its executable identity could be verified."
        case let .runningCodeUnavailable(status):
            "The running User Core code identity is unavailable (\(Self.message(for: status)))."
        case let .runningRequirementRejected(status):
            "The running User Core failed its exact signing requirement (\(Self.message(for: status)))."
        }
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}

nonisolated private struct MihomoLaunchRequest: Equatable, Sendable {
    let configurationURL: URL
    let dataDirectoryURL: URL
    let additionalArguments: [String]
    let validationTimeout: Duration

    init(
        configurationURL: URL,
        dataDirectoryURL: URL,
        additionalArguments: [String],
        validationTimeout: Duration
    ) {
        self.configurationURL = configurationURL
        self.dataDirectoryURL = dataDirectoryURL
        self.additionalArguments = additionalArguments
        self.validationTimeout = validationTimeout
    }

    init(preparedLaunch: MihomoPreparedLaunch) {
        self.init(
            configurationURL: preparedLaunch.configurationURL,
            dataDirectoryURL: preparedLaunch.dataDirectoryURL,
            additionalArguments: preparedLaunch.additionalArguments,
            validationTimeout: preparedLaunch.validationTimeout
        )
    }

    func runtimeEquivalent(to other: Self) -> Bool {
        configurationURL == other.configurationURL
            && dataDirectoryURL == other.dataDirectoryURL
            && additionalArguments == other.additionalArguments
    }
}

nonisolated private struct LaunchPreparationTask: Sendable {
    let id: UUID
    let request: MihomoLaunchRequest
    let task: Task<MihomoPreparedLaunch, Error>
}

nonisolated private final class ManagedMihomoProcess {
    let runID: UUID
    let process: Process
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    let outputBuffer: ProcessOutputBuffer
    let executable: ResolvedMihomoExecutable
    let launchRequest: MihomoLaunchRequest
    let startedAt: Date
    var pid: Int32 { process.processIdentifier }

    var stopRequested = false
    var forceKilled = false

    init(
        runID: UUID,
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        outputBuffer: ProcessOutputBuffer,
        executable: ResolvedMihomoExecutable,
        launchRequest: MihomoLaunchRequest,
        startedAt: Date
    ) {
        self.runID = runID
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.outputBuffer = outputBuffer
        self.executable = executable
        self.launchRequest = launchRequest
        self.startedAt = startedAt
    }

    func drainRemainingOutput() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        outputBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile(), to: .stdout)
        outputBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile(), to: .stderr)
    }

    func closeHandles() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForWriting.close()
        process.terminationHandler = nil
    }
}

nonisolated private final class ProcessOutputBuffer: Sendable {
    private static let maximumBytesPerStream = 1_048_576

    nonisolated struct Storage: Sendable {
        var stdout = Data()
        var stderr = Data()
    }

    private let storage = Mutex(Storage())

    func append(_ data: Data, to channel: MihomoProcessOutputChannel) {
        guard !data.isEmpty else { return }
        storage.withLock { storage in
            switch channel {
            case .stdout:
                storage.stdout.append(data)
                Self.trim(&storage.stdout)
            case .stderr:
                storage.stderr.append(data)
                Self.trim(&storage.stderr)
            }
        }
    }

    func snapshot() -> Storage {
        storage.withLock { $0 }
    }

    private static func trim(_ data: inout Data) {
        let overflow = data.count - maximumBytesPerStream
        if overflow > 0 {
            data.removeFirst(overflow)
        }
    }
}
