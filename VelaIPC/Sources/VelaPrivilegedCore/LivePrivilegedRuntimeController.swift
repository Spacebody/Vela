import Darwin
import Foundation
import VelaIPC

public actor LivePrivilegedRuntimeController: PrivilegedRuntimeControlling {
    private struct ManagedProcess {
        let process: Process
        let identity: RootProcessIdentity
        let instanceID: UUID
        let configurationSHA256: String
        let controllerPort: UInt16
        let controllerSecret: SecretValue
        let tunInterface: String
        let routeProbeAddress: String
        let preexistingTunInterfaces: Set<String>
        let stdout: Pipe
        let stderr: Pipe
        let logSessionID: UUID
        let startedAt: Date
        let transaction: RootTransactionRecord
    }

    private let directories: PrivilegedDirectories
    private let executableStore: TrustedMihomoExecutableStore
    private let expectedHelperSignature: PrivilegedCodeSignature
    private let journalStore: RootJournalStore
    private let transactionStore: RootTransactionStore
    private var preflight: any FixedMihomoPreflighting
    private let usesDynamicCorePreflight: Bool
    private let commandRunner: any FixedMihomoCommandRunning
    private let processInspector: any LiveProcessInspecting
    private let routeProber: any PrivilegedRouteProbing
    private let tunInterfaceLister: any PrivilegedTunInterfaceListing
    private let effectiveUserID: @Sendable () -> uid_t
    private let identityVerifier: ProcessIdentityVerifier
    private let factoryExecutableURL: URL?
    private let coreStore: RootCoreStore?
    private let logs = PrivilegedStartupLogRing()
    private let operationGate = AsyncExclusiveOperationGate()
    private var trustedExecutable: TrustedMihomoExecutable?
    private var selectedCoreID: CoreID = .factoryV11928
    private var managed: ManagedProcess?
    private var lastConfigurationSHA256: String?
    private var lastHealth: PrivilegedRuntimeHealth = .stoppedHelper

    public init(
        directories: PrivilegedDirectories,
        executableStore: TrustedMihomoExecutableStore,
        expectedHelperSignature: PrivilegedCodeSignature,
        journalStore: RootJournalStore,
        transactionStore: RootTransactionStore,
        trustedExecutable: TrustedMihomoExecutable? = nil,
        preflight: (any FixedMihomoPreflighting)? = nil,
        commandRunner: any FixedMihomoCommandRunning = FoundationFixedMihomoCommandRunner(),
        processInspector: any LiveProcessInspecting = DarwinLiveProcessInspector(),
        routeProber: any PrivilegedRouteProbing = FoundationPrivilegedRouteProber(),
        tunInterfaceLister: any PrivilegedTunInterfaceListing = FoundationPrivilegedTunInterfaceLister(),
        effectiveUserID: @escaping @Sendable () -> uid_t = { geteuid() },
        factoryExecutableURL: URL? = nil,
        coreStore: RootCoreStore? = nil
    ) {
        self.directories = directories
        self.executableStore = executableStore
        self.expectedHelperSignature = expectedHelperSignature
        self.journalStore = journalStore
        self.transactionStore = transactionStore
        self.trustedExecutable = trustedExecutable
        self.preflight = preflight ?? FixedMihomoPreflight(executableStore: executableStore)
        usesDynamicCorePreflight = preflight == nil
        self.commandRunner = commandRunner
        self.processInspector = processInspector
        self.routeProber = routeProber
        self.tunInterfaceLister = tunInterfaceLister
        self.effectiveUserID = effectiveUserID
        self.factoryExecutableURL = factoryExecutableURL
        self.coreStore = coreStore
        identityVerifier = ProcessIdentityVerifier(inspector: processInspector)
    }

    /// Reconciles the dirty journal before the listener is exposed. No process
    /// is found or signalled by name; a PID must match every recorded identity
    /// field before TERM/KILL is permitted.
    public func recoverAtStartup() async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard managed == nil else { throw LivePrivilegedRuntimeError.alreadyRunning }
        guard let journal = try await journalStore.load(), !journal.lastCleanShutdown else {
            return
        }
        guard let identity = journal.processIdentity else {
            throw LivePrivilegedRuntimeError.manualRepairRequired
        }

        let recoveredExecutable = try executableStore.resolve(
            relativePath: identity.executableRelativePath
        )
        if Self.processExists(identity.processID) {
            _ = try identityVerifier.verify(
                journalIdentity: identity,
                expectedExecutableURL: recoveredExecutable.url
            )
            try await terminateVerifiedProcess(identity, executable: recoveredExecutable)
        }
        if let interface = journal.tunInterface,
            !(await waitForTunRemoval(interface, timeout: .seconds(3)))
        {
            throw LivePrivilegedRuntimeError.cleanupIncomplete
        }
        if let interface = journal.tunInterface {
            guard let probeAddress = journal.routeProbeAddress,
                await waitForRouteRemoval(
                    interface,
                    probeAddress: probeAddress,
                    timeout: .seconds(3)
                )
            else {
                throw LivePrivilegedRuntimeError.cleanupIncomplete
            }
        } else {
            guard let baseline = journal.preexistingTunInterfaces,
                await PrivilegedTunBaselineCleanupVerifier(
                    interfaceLister: tunInterfaceLister
                ).waitForNoAdditions(
                    since: Set(baseline),
                    timeout: .seconds(3)
                )
            else {
                throw LivePrivilegedRuntimeError.cleanupIncomplete
            }
        }
        if let transactionID = journal.activeTransactionID {
            try await transactionStore.cleanupRecovered(transactionID: transactionID)
        }
        try executableStore.removeGeneration(containing: identity.executableRelativePath)
        try await journalStore.save(RootRuntimeJournal())
    }

    public func configureTrustedExecutable(
        _ executable: TrustedMihomoExecutable
    ) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard managed == nil, trustedExecutable == nil else {
            throw LivePrivilegedRuntimeError.alreadyRunning
        }
        if let journal = try await journalStore.load(), !journal.lastCleanShutdown {
            throw LivePrivilegedRuntimeError.manualRepairRequired
        }
        trustedExecutable = try executableStore.revalidate(executable)
        selectedCoreID = .factoryV11928
    }

    public func selectCore(_ coreID: CoreID) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard managed == nil else { throw LivePrivilegedRuntimeError.alreadyRunning }
        if let journal = try await journalStore.load(), !journal.lastCleanShutdown {
            throw LivePrivilegedRuntimeError.manualRepairRequired
        }

        let sourceURL: URL
        if coreID.isFactory {
            guard coreID == .factoryV11928, let factoryExecutableURL else {
                throw LivePrivilegedRuntimeError.coreUnavailable
            }
            sourceURL = factoryExecutableURL
        } else {
            guard let coreStore,
                let installed = try await coreStore.executableSourceURL(for: coreID)
            else { throw LivePrivilegedRuntimeError.coreUnavailable }
            sourceURL = installed
        }

        if selectedCoreID == coreID, let trustedExecutable {
            _ = try executableStore.revalidate(trustedExecutable)
            return
        }
        try executableStore.removeAllGenerations()
        trustedExecutable = nil
        let imported = try executableStore.installBundledExecutable(from: sourceURL)
        do {
            let candidatePreflight: any FixedMihomoPreflighting = usesDynamicCorePreflight
                ? FixedMihomoPreflight(
                    executableStore: executableStore,
                    expectedVersion: coreID.upstreamVersion
                )
                : preflight
            _ = try await candidatePreflight.run(
                executable: imported,
                expectedHelperSignature: expectedHelperSignature,
                workingDirectoryURL: directories.fileSystem.rootURL
            )
            preflight = candidatePreflight
            trustedExecutable = imported
            selectedCoreID = coreID
        } catch {
            try? executableStore.removeGeneration(containing: imported.relativePath)
            throw error
        }
    }

    public func start(
        _ context: PrivilegedEngineStartContext
    ) async throws -> PrivilegedEngineStartResult {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard effectiveUserID() == 0 else { throw LivePrivilegedRuntimeError.daemonNotRoot }
        guard managed == nil else { throw LivePrivilegedRuntimeError.alreadyRunning }
        guard let trustedExecutable else {
            throw LivePrivilegedRuntimeError.manualRepairRequired
        }
        if let journal = try await journalStore.load(), !journal.lastCleanShutdown {
            throw LivePrivilegedRuntimeError.manualRepairRequired
        }

        let transaction = context.transaction
        let canonicalGeneration = try directories.generationRoot(
            ownerUID: transaction.ownerUID,
            transactionID: transaction.transactionID
        )
        guard transaction.phase == .promoted,
            transaction.generationRelativePath == canonicalGeneration,
            transaction.sanitizedConfigurationSHA256
                == context.sanitizedConfiguration.sha256
        else {
            throw LivePrivilegedRuntimeError.configurationValidationFailed
        }
        let dataDirectory = directories.url(for: canonicalGeneration)
        let configurationURL = directories.url(
            for: try canonicalGeneration.appending("config.sanitized.yaml")
        )

        let preflightResult = try await preflight.run(
            executable: trustedExecutable,
            expectedHelperSignature: expectedHelperSignature,
            workingDirectoryURL: dataDirectory
        )
        let validation = try await commandRunner.validateConfiguration(
            executableURL: preflightResult.executable.url,
            dataDirectoryURL: dataDirectory,
            configurationURL: configurationURL
        )
        guard !validation.timedOut, validation.status == 0 else {
            throw LivePrivilegedRuntimeError.configurationValidationFailed
        }
        guard let routeProbeAddress = PrivilegedRouteProbeSelector.select(
            excluding: transaction.tunSettings.routeExcludeCIDRs
        ) else {
            throw LivePrivilegedRuntimeError.configurationValidationFailed
        }

        guard let beforeInterfaces = tunInterfaceLister.currentInterfaces() else {
            throw LivePrivilegedRuntimeError.configurationValidationFailed
        }
        let preexistingTunInterfaces = beforeInterfaces.sorted()
        guard PrivilegedTunInterfaceValidator.isValidJournalBaseline(
            preexistingTunInterfaces
        ) else {
            throw LivePrivilegedRuntimeError.configurationValidationFailed
        }
        let instanceID = UUID()
        var journal = RootRuntimeJournal(
            desiredState: .running,
            instanceID: instanceID,
            configurationSHA256: context.sanitizedConfiguration.sha256,
            routeProbeAddress: routeProbeAddress,
            preexistingTunInterfaces: preexistingTunInterfaces,
            ownerUID: transaction.ownerUID,
            activeTransactionID: transaction.transactionID,
            lastCleanShutdown: false
        )
        try await journalStore.save(journal)

        let process = Process()
        process.executableURL = preflightResult.executable.url
        process.arguments = ["-d", dataDirectory.path, "-f", configurationURL.path]
        process.currentDirectoryURL = dataDirectory
        process.environment = FoundationFixedMihomoCommandRunner.minimumEnvironment(
            home: dataDirectory
        )
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let secret = context.sanitizedConfiguration.controllerSecret
        let logSessionID = await logs.beginSession(secret: secret)
        let stdoutLogIngress = installLogHandler(
            stdout.fileHandleForReading,
            channel: "stdout",
            sessionID: logSessionID
        )
        let stderrLogIngress = installLogHandler(
            stderr.fileHandleForReading,
            channel: "stderr",
            sessionID: logSessionID
        )

        do {
            try process.run()
        } catch {
            clearLogHandlers(stdout: stdout, stderr: stderr)
            await logs.endSession(logSessionID)
            try? await journalStore.save(RootRuntimeJournal())
            throw LivePrivilegedRuntimeError.launchFailed
        }

        do {
            let snapshot = try processInspector.inspect(
                processID: process.processIdentifier,
                expectedExecutableURL: preflightResult.executable.url
            )
            guard snapshot.effectiveUserID == 0,
                snapshot.executableIdentity.device
                    == preflightResult.executable.identity.device,
                snapshot.executableIdentity.inode
                    == preflightResult.executable.identity.inode,
                snapshot.codeSignature.signingIdentifier
                    == preflightResult.mihomoSignature.signingIdentifier,
                snapshot.codeSignature.teamIdentifier
                    == preflightResult.mihomoSignature.teamIdentifier
            else {
                throw LivePrivilegedRuntimeError.processIdentityMismatch
            }
            let rootIdentity = RootProcessIdentity(
                processID: snapshot.processID,
                startTimeSeconds: snapshot.startTimeSeconds,
                startTimeMicroseconds: snapshot.startTimeMicroseconds,
                executableDevice: snapshot.executableIdentity.device,
                executableInode: snapshot.executableIdentity.inode,
                executableRelativePath: preflightResult.executable.relativePath,
                signingIdentifier: snapshot.codeSignature.signingIdentifier,
                teamIdentifier: snapshot.codeSignature.teamIdentifier
            )
            journal.processIdentity = rootIdentity
            try await journalStore.save(journal)

            let temporary = ManagedProcess(
                process: process,
                identity: rootIdentity,
                instanceID: instanceID,
                configurationSHA256: context.sanitizedConfiguration.sha256,
                controllerPort: context.sanitizedConfiguration.controllerPort,
                controllerSecret: secret,
                tunInterface: "",
                routeProbeAddress: routeProbeAddress,
                preexistingTunInterfaces: beforeInterfaces,
                stdout: stdout,
                stderr: stderr,
                logSessionID: logSessionID,
                startedAt: .now,
                transaction: transaction
            )
            managed = temporary

            guard await waitForController(temporary, timeout: .seconds(10)) else {
                throw LivePrivilegedRuntimeError.controllerUnavailable
            }
            await stdoutLogIngress.flush()
            await stderrLogIngress.flush()
            await logs.seal(sessionID: logSessionID)
            guard let tunInterface = await waitForNewTunInterface(
                excluding: beforeInterfaces,
                timeout: .seconds(10)
            ) else {
                throw LivePrivilegedRuntimeError.tunInterfaceUnavailable
            }
            let running = ManagedProcess(
                process: process,
                identity: rootIdentity,
                instanceID: instanceID,
                configurationSHA256: context.sanitizedConfiguration.sha256,
                controllerPort: context.sanitizedConfiguration.controllerPort,
                controllerSecret: secret,
                tunInterface: tunInterface,
                routeProbeAddress: routeProbeAddress,
                preexistingTunInterfaces: beforeInterfaces,
                stdout: stdout,
                stderr: stderr,
                logSessionID: logSessionID,
                startedAt: temporary.startedAt,
                transaction: transaction
            )
            managed = running
            journal.tunInterface = tunInterface
            journal.routeProbeAddress = routeProbeAddress
            try await journalStore.save(journal)
            lastConfigurationSHA256 = running.configurationSHA256
            let controllerHealth = await controllerConfigHealth(running)
            lastHealth = makeHealth(
                processRunning: true,
                controllerHealth: controllerHealth,
                tunInterface: tunInterface,
                configurationMatches: true,
                routeApplied: await routeProber.probe(
                    address: routeProbeAddress,
                    ownedInterface: tunInterface
                )
                    == .usesOwnedInterface,
                dnsRequired: running.transaction.tunSettings.dnsHijack
            )
            return PrivilegedEngineStartResult(
                instanceID: instanceID,
                processID: process.processIdentifier,
                startedAt: running.startedAt,
                tunInterface: tunInterface
            )
        } catch {
            if managed != nil {
                do {
                    try await stopLocked(instanceID: instanceID, reason: .recovery)
                } catch {
                    throw LivePrivilegedRuntimeError.manualRepairRequired
                }
            } else {
                let termination: BoundedProcessTerminationResult
                if process.isRunning {
                    // This is the exact Process object just spawned by this
                    // start attempt, not a PID discovered by name or journal.
                    termination = await BoundedProcessWaiter.wait(
                        for: process,
                        timeout: .zero,
                        terminateGrace: .milliseconds(500),
                        killGrace: .milliseconds(500)
                    )
                } else {
                    process.waitUntilExit()
                    termination = BoundedProcessTerminationResult(
                        timedOut: false,
                        exited: true
                    )
                }
                clearLogHandlers(stdout: stdout, stderr: stderr)
                await logs.endSession(logSessionID)
                guard termination.exited,
                    await waitForNoTunAdditions(
                        since: beforeInterfaces,
                        timeout: .seconds(3)
                    )
                else {
                    throw LivePrivilegedRuntimeError.manualRepairRequired
                }
                try await journalStore.save(RootRuntimeJournal())
            }
            throw error
        }
    }

    public func stop(instanceID: UUID?, reason: HelperStopReason) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        try await stopLocked(instanceID: instanceID, reason: reason)
    }

    private func stopLocked(instanceID: UUID?, reason _: HelperStopReason) async throws {
        guard let current = managed else {
            try await stopVerifiedJournalProcessIfPresent()
            return
        }
        if let instanceID, instanceID != current.instanceID {
            throw LivePrivilegedRuntimeError.instanceMismatch
        }
        let executable = try executableStore.resolve(
            relativePath: current.identity.executableRelativePath
        )
        if current.process.isRunning {
            _ = try identityVerifier.verify(
                journalIdentity: current.identity,
                expectedExecutableURL: executable.url
            )
            guard Darwin.kill(current.identity.processID, SIGTERM) == 0 else {
                throw LivePrivilegedRuntimeError.stopFailed
            }
        }
        if !(await waitForExit(current.process, timeout: .seconds(5))) {
            _ = try identityVerifier.verify(
                journalIdentity: current.identity,
                expectedExecutableURL: executable.url
            )
            guard Darwin.kill(current.identity.processID, SIGKILL) == 0 else {
                throw LivePrivilegedRuntimeError.stopFailed
            }
            guard await waitForExit(current.process, timeout: .seconds(3)) else {
                throw LivePrivilegedRuntimeError.stopFailed
            }
        }

        clearLogHandlers(stdout: current.stdout, stderr: current.stderr)
        await logs.endSession(current.logSessionID)
        if !current.tunInterface.isEmpty {
            let removed = await waitForTunRemoval(
                current.tunInterface,
                timeout: .seconds(3)
            )
            if !removed { throw LivePrivilegedRuntimeError.cleanupIncomplete }
            let routeRemoved = await waitForRouteRemoval(
                current.tunInterface,
                probeAddress: current.routeProbeAddress,
                timeout: .seconds(3)
            )
            if !routeRemoved { throw LivePrivilegedRuntimeError.cleanupIncomplete }
        } else if !(await waitForNoTunAdditions(
            since: current.preexistingTunInterfaces,
            timeout: .seconds(3)
        )) {
            throw LivePrivilegedRuntimeError.cleanupIncomplete
        }
        try await journalStore.save(RootRuntimeJournal())
        managed = nil
        lastHealth = .stoppedHelper
    }

    public func status() async -> PrivilegedEngineControllerStatus {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard let current = managed else {
            return PrivilegedEngineControllerStatus(
                state: .stopped,
                processID: nil,
                instanceID: nil,
                configurationSHA256: lastConfigurationSHA256,
                health: lastHealth
            )
        }
        let processRunning = current.process.isRunning
        let controllerHealth: ControllerConfigHealth
        if processRunning {
            controllerHealth = await controllerConfigHealth(current)
        } else {
            controllerHealth = .unreachable
        }
        let interfacePresent = tunInterfaceLister.currentInterfaces()?.contains(
            current.tunInterface
        ) == true
        let routeApplied: Bool
        if interfacePresent {
            routeApplied = await routeProber.probe(
                address: current.routeProbeAddress,
                ownedInterface: current.tunInterface
            )
                == .usesOwnedInterface
        } else {
            routeApplied = false
        }
        let configurationMatches = configurationHashMatches(current)
        let health = makeHealth(
            processRunning: processRunning,
            controllerHealth: controllerHealth,
            tunInterface: interfacePresent ? current.tunInterface : nil,
            configurationMatches: configurationMatches,
            routeApplied: routeApplied,
            dnsRequired: current.transaction.tunSettings.dnsHijack
        )
        lastHealth = health
        let healthy = processRunning
            && controllerHealth.reachable
            && controllerHealth.tunEnabled
            && (!current.transaction.tunSettings.dnsHijack || controllerHealth.dnsEnabled)
            && interfacePresent
            && routeApplied
        return PrivilegedEngineControllerStatus(
            state: healthy ? .running : .degraded,
            processID: current.identity.processID,
            instanceID: current.instanceID,
            configurationSHA256: current.configurationSHA256,
            health: health
        )
    }

    public func readLogs(
        after sequence: UInt64,
        maximumEntries: Int
    ) async throws -> [HelperLogEntry] {
        await logs.read(after: sequence, maximumEntries: maximumEntries)
    }

    public func cleanup(mode: PrivilegedCleanupMode, ownerUID: UInt32) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard managed == nil else { throw LivePrivilegedRuntimeError.alreadyRunning }
        switch mode {
        case .runtimeOnly:
            try await journalStore.save(RootRuntimeJournal())
        case .keepDiagnosticMetadata, .removeRuntimeData:
            // The retained diagnostic journal is useful only after all
            // owner-scoped configurations, credentials, transaction manifests,
            // and the imported executable generation are gone. `prepare`
            // validates the entire state directory before either mode mutates
            // it, and each store performs its own complete no-follow preflight
            // before unlinking a bounded tree.
            try await journalStore.prepare()
            try await transactionStore.removeRetainedGenerations(ownerUID: ownerUID)
            try executableStore.removeAllGenerations()
            trustedExecutable = nil

            if mode == .keepDiagnosticMetadata {
                try await journalStore.save(RootRuntimeJournal())
            } else {
                try await journalStore.clear()
            }
            try removeGlobalCleanupContainers(
                includingDiagnosticState: mode == .removeRuntimeData
            )
        }
    }

    /// Removes only empty global containers. A different UID's journals or
    /// runtime tree make a container non-empty and are intentionally preserved;
    /// one caller's uninstall must neither traverse nor delete that data.
    private func removeGlobalCleanupContainers(
        includingDiagnosticState: Bool
    ) throws {
        var paths = [
            "transactions",
            "executables/generations",
            "executables",
            "users",
        ]
        if includingDiagnosticState {
            paths.insert("state", at: 0)
        }
        for rawPath in paths {
            do {
                try directories.fileSystem.removeEmptyDirectory(
                    try SafeRelativePath(rawPath)
                )
            } catch let error as POSIXRootFileSystemError {
                if case let .systemCall(_, code) = error,
                    code == ENOENT || code == ENOTEMPTY
                {
                    continue
                }
                throw error
            }
        }
    }

    private func stopVerifiedJournalProcessIfPresent() async throws {
        guard let journal = try await journalStore.load(),
            !journal.lastCleanShutdown,
            let identity = journal.processIdentity
        else {
            return
        }
        let executable = try executableStore.resolve(
            relativePath: identity.executableRelativePath
        )
        if Self.processExists(identity.processID) {
            _ = try identityVerifier.verify(
                journalIdentity: identity,
                expectedExecutableURL: executable.url
            )
            try await terminateVerifiedProcess(identity, executable: executable)
        }
        if let interface = journal.tunInterface,
            !(await waitForTunRemoval(interface, timeout: .seconds(3)))
        {
            throw LivePrivilegedRuntimeError.cleanupIncomplete
        }
        if let interface = journal.tunInterface {
            guard let probeAddress = journal.routeProbeAddress,
                await waitForRouteRemoval(
                    interface,
                    probeAddress: probeAddress,
                    timeout: .seconds(3)
                )
            else {
                throw LivePrivilegedRuntimeError.cleanupIncomplete
            }
        } else {
            guard let baseline = journal.preexistingTunInterfaces,
                await PrivilegedTunBaselineCleanupVerifier(
                    interfaceLister: tunInterfaceLister
                ).waitForNoAdditions(
                    since: Set(baseline),
                    timeout: .seconds(3)
                )
            else {
                throw LivePrivilegedRuntimeError.cleanupIncomplete
            }
        }
        if let transactionID = journal.activeTransactionID {
            try await transactionStore.cleanupRecovered(transactionID: transactionID)
        }
        try executableStore.removeGeneration(containing: identity.executableRelativePath)
        try await journalStore.save(RootRuntimeJournal())
    }

    private func terminateVerifiedProcess(
        _ identity: RootProcessIdentity,
        executable: TrustedMihomoExecutable
    ) async throws {
        guard Self.processExists(identity.processID) else { return }
        guard Darwin.kill(identity.processID, SIGTERM) == 0 else {
            if errno == ESRCH { return }
            throw LivePrivilegedRuntimeError.stopFailed
        }
        let termDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < termDeadline {
            if !Self.processExists(identity.processID) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }

        _ = try identityVerifier.verify(
            journalIdentity: identity,
            expectedExecutableURL: executable.url
        )
        guard Darwin.kill(identity.processID, SIGKILL) == 0 else {
            if errno == ESRCH { return }
            throw LivePrivilegedRuntimeError.stopFailed
        }
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < killDeadline {
            if !Self.processExists(identity.processID) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw LivePrivilegedRuntimeError.stopFailed
    }

    private func installLogHandler(
        _ handle: FileHandle,
        channel: String,
        sessionID: UUID
    ) -> PrivilegedStartupLogIngress {
        let ingress = PrivilegedStartupLogIngress(
            logs: logs,
            channel: channel,
            sessionID: sessionID
        )
        handle.readabilityHandler = { [ingress] readable in
            let data = readable.availableData
            guard !data.isEmpty else { return }
            ingress.append(data)
        }
        return ingress
    }

    private func clearLogHandlers(stdout: Pipe, stderr: Pipe) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
    }

    private func waitForController(
        _ process: ManagedProcess,
        timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, process.process.isRunning {
            if await controllerIsReachable(process) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func controllerIsReachable(_ process: ManagedProcess) async -> Bool {
        guard let url = URL(
            string: "http://127.0.0.1:\(process.controllerPort)/version"
        ) else {
            return false
        }
        var request = URLRequest(url: url)
        process.controllerSecret.withValue {
            request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 1
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func controllerConfigHealth(
        _ process: ManagedProcess
    ) async -> ControllerConfigHealth {
        guard let url = URL(
            string: "http://127.0.0.1:\(process.controllerPort)/configs"
        ) else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        process.controllerSecret.withValue {
            request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 1
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return .unreachable
            }
            let tunEnabled = (root["tun"] as? [String: Any])?["enable"] as? Bool ?? false
            let dnsEnabled = (root["dns"] as? [String: Any])?["enable"] as? Bool ?? false
            return ControllerConfigHealth(
                reachable: true,
                tunEnabled: tunEnabled,
                dnsEnabled: dnsEnabled
            )
        } catch {
            return .unreachable
        }
    }

    private func waitForNewTunInterface(
        excluding previous: Set<String>,
        timeout: Duration
    ) async -> String? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let interfaces = tunInterfaceLister.currentInterfaces() {
                let candidates = interfaces.subtracting(previous)
                if candidates.count == 1 { return candidates.first }
                if candidates.count > 1 { return nil }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func waitForTunRemoval(_ name: String, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let interfaces = tunInterfaceLister.currentInterfaces(),
                !interfaces.contains(name)
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let interfaces = tunInterfaceLister.currentInterfaces() else { return false }
        return !interfaces.contains(name)
    }

    private func waitForNoTunAdditions(
        since baseline: Set<String>,
        timeout: Duration
    ) async -> Bool {
        await PrivilegedTunBaselineCleanupVerifier(
            interfaceLister: tunInterfaceLister
        ).waitForNoAdditions(since: baseline, timeout: timeout)
    }

    private func waitForRouteRemoval(
        _ interface: String,
        probeAddress: String,
        timeout: Duration
    ) async -> Bool {
        await PrivilegedRouteCleanupVerifier(prober: routeProber).waitForRemoval(
            address: probeAddress,
            interface: interface,
            timeout: timeout
        )
    }

    private func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }

    private func makeHealth(
        processRunning: Bool,
        controllerHealth: ControllerConfigHealth,
        tunInterface: String?,
        configurationMatches: Bool,
        routeApplied: Bool,
        dnsRequired: Bool
    ) -> PrivilegedRuntimeHealth {
        PrivilegedRuntimeHealth(
            helperReachable: true,
            helperVersionCompatible: true,
            processRunning: processRunning,
            controllerReachable: controllerHealth.reachable,
            configurationHashMatches: configurationMatches,
            tunEnabledInController: controllerHealth.tunEnabled,
            tunInterfacePresent: tunInterface != nil,
            routeApplied: routeApplied,
            dnsReady: !dnsRequired || controllerHealth.dnsEnabled,
            ownerLeaseValid: false,
            tunInterface: tunInterface,
            lastCheckedAt: .now
        )
    }

    private func configurationHashMatches(_ current: ManagedProcess) -> Bool {
        do {
            guard let generation = current.transaction.generationRelativePath else {
                return false
            }
            let path = try generation.appending("config.sanitized.yaml")
            let data = try directories.fileSystem.readData(
                at: path,
                maximumBytes: VelaIPCConstants.maximumConfigurationBytes
            )
            return IntegrityValue.sha256Hex(of: data) == current.configurationSHA256
        } catch {
            return false
        }
    }

    private static func processExists(_ processID: Int32) -> Bool {
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }
}

private struct ControllerConfigHealth: Sendable {
    let reachable: Bool
    let tunEnabled: Bool
    let dnsEnabled: Bool

    static let unreachable = ControllerConfigHealth(
        reachable: false,
        tunEnabled: false,
        dnsEnabled: false
    )
}

actor PrivilegedStartupLogRing {
    private static let maximumInputBytesPerAppend = 1 * 1_024 * 1_024
    private static let maximumPendingLineBytes = 64 * 1_024
    private static let maximumMessageBytes = 4_096

    private var entries: [HelperLogEntry] = []
    private var byteCount = 0
    private var nextSequence: UInt64 = 1
    private var isSealed = false
    private var activeSessionID: UUID?
    private var activeSecret: SecretValue?
    private var pendingLines: [String: Data] = [:]
    private var droppingOversizedLineChannels = Set<String>()

    func beginSession(secret: SecretValue) -> UUID {
        let sessionID = UUID()
        entries.removeAll(keepingCapacity: false)
        byteCount = 0
        nextSequence = 1
        isSealed = false
        activeSessionID = sessionID
        activeSecret = secret
        pendingLines.removeAll(keepingCapacity: false)
        droppingOversizedLineChannels.removeAll(keepingCapacity: false)
        return sessionID
    }

    func append(
        _ data: Data,
        channel: String,
        sessionID: UUID
    ) {
        guard activeSessionID == sessionID, !isSealed, let activeSecret else { return }
        var pending = pendingLines[channel] ?? Data()
        var droppingOversized = droppingOversizedLineChannels.contains(channel)
        let bounded = data.prefix(Self.maximumInputBytesPerAppend)

        for byte in bounded {
            if byte == 0x0A || byte == 0x0D {
                if !droppingOversized, !pending.isEmpty {
                    appendLine(pending, channel: channel, secret: activeSecret)
                }
                pending.removeAll(keepingCapacity: true)
                droppingOversized = false
                continue
            }
            if droppingOversized { continue }
            guard pending.count < Self.maximumPendingLineBytes else {
                pending.removeAll(keepingCapacity: true)
                droppingOversized = true
                appendEntry(
                    "Mihomo startup log line was redacted because it exceeded the privacy limit.",
                    channel: channel
                )
                continue
            }
            pending.append(byte)
        }

        // If one callback itself exceeded the input budget, the discarded tail
        // may contain an unknown line boundary. Stay in drop mode until a later
        // observed newline rather than accidentally joining two fragments.
        if data.count > Self.maximumInputBytesPerAppend {
            pending.removeAll(keepingCapacity: true)
            if !droppingOversized {
                appendEntry(
                    "Mihomo startup log input was redacted because it exceeded the privacy limit.",
                    channel: channel
                )
            }
            droppingOversized = true
        }

        pendingLines[channel] = pending
        if droppingOversized {
            droppingOversizedLineChannels.insert(channel)
        } else {
            droppingOversizedLineChannels.remove(channel)
        }
        trimToLimits()
    }

    private func appendLine(_ data: Data, channel: String, secret: SecretValue) {
        var text = String(decoding: data, as: UTF8.self)
        secret.withValue { value in
            guard !value.isEmpty else { return }
            text = text.replacingOccurrences(of: value, with: "<redacted>")
        }
        appendEntry(String(text.prefix(Self.maximumMessageBytes)), channel: channel)
    }

    private func appendEntry(_ message: String, channel: String) {
        guard !message.isEmpty else { return }
        let entry = HelperLogEntry(
            sequence: nextSequence,
            timestamp: .now,
            channel: channel,
            message: message
        )
        nextSequence &+= 1
        entries.append(entry)
        byteCount += message.utf8.count
    }

    private func trimToLimits() {
        while entries.count > VelaIPCConstants.maximumLogEntryCount
            || byteCount > VelaIPCConstants.maximumLogBatchBytes
        {
            guard !entries.isEmpty else { break }
            byteCount -= entries.removeFirst().message.utf8.count
        }
    }

    func read(after sequence: UInt64, maximumEntries: Int) -> [HelperLogEntry] {
        Array(entries.lazy.filter { $0.sequence > sequence }.prefix(maximumEntries))
    }

    func seal(sessionID: UUID) {
        guard activeSessionID == sessionID, let activeSecret else { return }
        for channel in pendingLines.keys.sorted() {
            guard !droppingOversizedLineChannels.contains(channel),
                let pending = pendingLines[channel],
                !pending.isEmpty
            else {
                continue
            }
            appendLine(pending, channel: channel, secret: activeSecret)
        }
        trimToLimits()
        pendingLines.removeAll(keepingCapacity: false)
        droppingOversizedLineChannels.removeAll(keepingCapacity: false)
        isSealed = true
    }

    func endSession(_ sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        entries.removeAll(keepingCapacity: false)
        byteCount = 0
        nextSequence = 1
        isSealed = true
        activeSessionID = nil
        activeSecret = nil
        pendingLines.removeAll(keepingCapacity: false)
        droppingOversizedLineChannels.removeAll(keepingCapacity: false)
    }
}

/// `FileHandle.readabilityHandler` may invoke callbacks again before a prior
/// callback's actor hop runs. Chain those hops so byte chunks from one pipe
/// reach the line-buffering actor in their original order.
private final class PrivilegedStartupLogIngress: @unchecked Sendable {
    private let lock = NSLock()
    private let logs: PrivilegedStartupLogRing
    private let channel: String
    private let sessionID: UUID
    private var tail: Task<Void, Never>?

    init(logs: PrivilegedStartupLogRing, channel: String, sessionID: UUID) {
        self.logs = logs
        self.channel = channel
        self.sessionID = sessionID
    }

    func append(_ data: Data) {
        lock.lock()
        let previous = tail
        let logs = self.logs
        let channel = self.channel
        let sessionID = self.sessionID
        let task = Task {
            await previous?.value
            await logs.append(data, channel: channel, sessionID: sessionID)
        }
        tail = task
        lock.unlock()
    }

    func flush() async {
        await snapshotTail()?.value
    }

    private func snapshotTail() -> Task<Void, Never>? {
        lock.lock()
        let task = tail
        lock.unlock()
        return task
    }
}

private extension PrivilegedRuntimeHealth {
    static var stoppedHelper: PrivilegedRuntimeHealth {
        PrivilegedRuntimeHealth(
            helperReachable: true,
            helperVersionCompatible: true,
            processRunning: false,
            controllerReachable: false,
            configurationHashMatches: false,
            tunEnabledInController: false,
            tunInterfacePresent: false,
            routeApplied: false,
            dnsReady: false,
            ownerLeaseValid: false,
            tunInterface: nil,
            lastCheckedAt: .now
        )
    }
}

public enum LivePrivilegedRuntimeError: Error, Equatable, Sendable {
    case daemonNotRoot
    case alreadyRunning
    case configurationValidationFailed
    case launchFailed
    case processIdentityMismatch
    case controllerUnavailable
    case tunInterfaceUnavailable
    case instanceMismatch
    case stopFailed
    case cleanupIncomplete
    case manualRepairRequired
    case coreUnavailable
}

public protocol PrivilegedCoreRuntimeSelecting: Sendable {
    func selectCore(_ coreID: CoreID) async throws
}

extension LivePrivilegedRuntimeController: PrivilegedCoreRuntimeSelecting {}

public enum PrivilegedHelperProductionFactory {
    public static func makeCoordinator(
        helperExecutableURL: URL,
        helperCodeSignature: PrivilegedCodeSignature,
        signingIdentitySummary: String
    ) async throws -> PrivilegedHelperCoordinator {
        guard geteuid() == 0 else { throw LivePrivilegedRuntimeError.daemonNotRoot }
        let layout = try FixedPrivilegedBundleLayout.derive(
            helperExecutableURL: helperExecutableURL
        )
        let directories = try PrivilegedDirectories.live()
        let journal = RootJournalStore(fileSystem: directories.fileSystem)
        try await journal.prepare()
        let transactions = RootTransactionStore(fileSystem: directories.fileSystem)
        let executableStore = TrustedMihomoExecutableStore(
            fileSystem: directories.fileSystem
        )
        let coreStore = RootCoreStore(
            fileSystem: directories.fileSystem,
            verifier: PrivilegedCoreCatalogVerifier(),
            preflight: RootCoreBundlePreflight(
                fileSystem: directories.fileSystem,
                expectedTeamIdentifier: helperCodeSignature.teamIdentifier
            )
        )
        let engine = LivePrivilegedRuntimeController(
            directories: directories,
            executableStore: executableStore,
            expectedHelperSignature: helperCodeSignature,
            journalStore: journal,
            transactionStore: transactions,
            factoryExecutableURL: layout.mihomoURL,
            coreStore: coreStore
        )
        // Runtime journal recovery identity-verifies/stops the old process and
        // proves TUN/route cleanup before transaction recovery may complete a
        // committed generation-index revision or delete an abandoned candidate.
        try await engine.recoverAtStartup()
        try await transactions.cleanupAbandonedAtStartup()
        try await coreStore.prepareAtStartup()
        // Recovery must finish against the old journal-recorded generation
        // before any new executable is imported or an old generation removed.
        try executableStore.removeAllGenerations()
        let executable = try executableStore.installBundledExecutable(from: layout.mihomoURL)
        do {
            _ = try await FixedMihomoPreflight(executableStore: executableStore).run(
                executable: executable,
                expectedHelperSignature: helperCodeSignature,
                workingDirectoryURL: directories.fileSystem.rootURL
            )
        } catch {
            try? executableStore.removeGeneration(containing: executable.relativePath)
            throw error
        }
        try await engine.configureTrustedExecutable(executable)
        return PrivilegedHelperCoordinator(
            identity: PrivilegedHelperIdentity(
                signingIdentitySummary: signingIdentitySummary,
                daemonUID: UInt32(geteuid())
            ),
            leases: OwnerLeaseCoordinator(),
            transactions: transactions,
            engine: engine,
            coreStore: coreStore
        )
    }
}
