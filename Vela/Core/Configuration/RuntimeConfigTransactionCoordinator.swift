import CryptoKit
import Foundation
import OSLog

nonisolated struct RuntimeConfigTransactionCommitEvidence: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case profileRevision
        case configurationOverride
    }

    let kind: Kind
    let expectedContentSHA256: String
    let artifactPath: String?
    let previousProfileRevisionID: UUID?
    let profileRevisionID: UUID?
    let previousProfileRawPath: String?
    let cleanupPath: String?
    // Optional for decoding journals created before override rollback evidence
    // was introduced.
    let previousOverrideExisted: Bool?
    let previousOverrideBackupPath: String?
    let previousOverrideContentSHA256: String?

    static func profileRevision(
        rawData: Data,
        previousRevisionID: UUID?,
        revisionID: UUID? = nil,
        previousRawURL: URL? = nil
    ) -> Self {
        Self(
            kind: .profileRevision,
            expectedContentSHA256: sha256(rawData),
            artifactPath: nil,
            previousProfileRevisionID: previousRevisionID,
            profileRevisionID: revisionID,
            previousProfileRawPath: previousRawURL?.standardizedFileURL.path,
            cleanupPath: nil,
            previousOverrideExisted: nil,
            previousOverrideBackupPath: nil,
            previousOverrideContentSHA256: nil
        )
    }

    static func configurationOverride(
        data: Data,
        artifactURL: URL,
        cleanupURL: URL,
        previousData: Data?,
        backupURL: URL
    ) -> Self {
        Self(
            kind: .configurationOverride,
            expectedContentSHA256: sha256(data),
            artifactPath: artifactURL.standardizedFileURL.path,
            previousProfileRevisionID: nil,
            profileRevisionID: nil,
            previousProfileRawPath: nil,
            cleanupPath: cleanupURL.standardizedFileURL.path,
            previousOverrideExisted: previousData != nil,
            previousOverrideBackupPath: backupURL.standardizedFileURL.path,
            previousOverrideContentSHA256: previousData.map(sha256)
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

nonisolated struct RuntimeConfigTransactionJournal: Codable, Equatable, Sendable {
    enum Phase: String, Codable, CaseIterable, Sendable {
        case downloaded
        case built
        case validated
        case activeReplaced
        case controllerApplied
        case healthVerified
        case committed
        case rollingBack
    }

    let transactionID: UUID
    let profileID: UUID
    var phase: Phase
    let candidateRawPath: String
    let candidateRuntimePath: String
    let previousRuntimePath: String?
    let startedAt: Date
    var commitEvidence: RuntimeConfigTransactionCommitEvidence? = nil
}

nonisolated struct SelectorRestoreResult: Equatable, Sendable {
    let restored: [String: String]
    let skipped: [String: String]
}

nonisolated struct RuntimeConfigTransactionResult: Equatable, Sendable {
    let transactionID: UUID
    let revision: ProfileRevision?
    let configurationGeneration: ConfigurationGeneration
    let selectorRestore: SelectorRestoreResult
    let hotReloaded: Bool
}

nonisolated struct RuntimeConfigTransactionCommitAction: Sendable {
    let commit: @Sendable () throws -> Void
    let rollback: @Sendable () throws -> Void
    let evidence: RuntimeConfigTransactionCommitEvidence?

    init(
        commit: @escaping @Sendable () throws -> Void,
        rollback: @escaping @Sendable () throws -> Void,
        evidence: RuntimeConfigTransactionCommitEvidence? = nil
    ) {
        self.commit = commit
        self.rollback = rollback
        self.evidence = evidence
    }
}

nonisolated enum RuntimeConfigTransactionError: Error, Equatable, Sendable {
    case transactionAlreadyRunning
    case stagingFailed
    case runtimeBuildFailed
    case executableResolutionFailed
    case configurationValidationFailed(ConfigurationValidationResult)
    case activeReplacementFailed
    case hotReloadFailed
    case controllerDidNotRecover
    case healthVerificationFailed
    case revisionCommitFailed
    case rollbackFailed
    case journalCorrupt
    case recoveryFailed
}

actor RuntimeConfigTransactionCoordinator {
    private static let maximumQueuedTransactions = 32
    private nonisolated static let logger = Logger(
        subsystem: "dev.yilin.Vela",
        category: "RuntimeConfigTransaction"
    )

    private enum CommitChangesFailure: Error, Equatable, Sendable {
        case commitFailed
        case rollbackFailed
    }

    private struct TransactionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let directories: ApplicationDirectories
    private let fileSystem: any FileSystemProviding
    private let profileStore: ProfileStore
    private let runtimeParameters: RuntimeConfigParameters
    private let runtimeBuilder: RuntimeConfigBuilder
    private let overrideProcessor: ConfigurationOverrideProcessor
    private let configurationLayerStore: ConfigurationLayerStore?
    private let executableResolver: any MihomoExecutableResolving
    private let validator: any ConfigurationValidating
    private let apiClient: any MihomoAPIProviding
    private let processManager: any MihomoProcessManaging
    private let runtimeMutationGate: RuntimeMutationGate
    private let controllerRecoveryTimeout: Duration
    private let controllerPollInterval: Duration
    private let now: @Sendable () -> Date
    private var activeTransactionID: UUID?
    private var transactionSlotHolderID: UUID?
    private var transactionWaiters: [TransactionWaiter] = []

    init(
        directories: ApplicationDirectories,
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        profileStore: ProfileStore,
        runtimeParameters: RuntimeConfigParameters,
        runtimeBuilder: RuntimeConfigBuilder = RuntimeConfigBuilder(),
        overrideProcessor: ConfigurationOverrideProcessor = ConfigurationOverrideProcessor(),
        configurationLayerStore: ConfigurationLayerStore? = nil,
        executableResolver: any MihomoExecutableResolving,
        validator: any ConfigurationValidating,
        apiClient: any MihomoAPIProviding,
        processManager: any MihomoProcessManaging,
        runtimeMutationGate: RuntimeMutationGate = RuntimeMutationGate(),
        controllerRecoveryTimeout: Duration = .seconds(10),
        controllerPollInterval: Duration = .milliseconds(250),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.directories = directories
        self.fileSystem = fileSystem
        self.profileStore = profileStore
        self.runtimeParameters = runtimeParameters
        self.runtimeBuilder = runtimeBuilder
        self.overrideProcessor = overrideProcessor
        self.configurationLayerStore = configurationLayerStore
        self.executableResolver = executableResolver
        self.validator = validator
        self.apiClient = apiClient
        self.processManager = processManager
        self.runtimeMutationGate = runtimeMutationGate
        self.controllerRecoveryTimeout = controllerRecoveryTimeout
        self.controllerPollInterval = controllerPollInterval
        self.now = now
    }

    func apply(
        rawData: Data,
        profileID: UUID,
        sourceFileName: String,
        updatedRemoteMetadata: RemoteProfileMetadata? = nil,
        commitRawRevision: Bool = true,
        commitAction: RuntimeConfigTransactionCommitAction? = nil
    ) async throws -> RuntimeConfigTransactionResult {
        let lease = try await runtimeMutationGate.acquire(.configurationTransaction)
        do {
            let result = try await applyExclusively(
                rawData: rawData,
                profileID: profileID,
                sourceFileName: sourceFileName,
                updatedRemoteMetadata: updatedRemoteMetadata,
                commitRawRevision: commitRawRevision,
                commitAction: commitAction
            )
            await runtimeMutationGate.release(lease)
            return result
        } catch {
            await runtimeMutationGate.release(lease)
            throw error
        }
    }

    private func applyExclusively(
        rawData: Data,
        profileID: UUID,
        sourceFileName: String,
        updatedRemoteMetadata: RemoteProfileMetadata?,
        commitRawRevision: Bool,
        commitAction: RuntimeConfigTransactionCommitAction?
    ) async throws -> RuntimeConfigTransactionResult {
        try await acquireTransactionSlot()
        let transactionID = UUID()
        activeTransactionID = transactionID
        defer {
            activeTransactionID = nil
            releaseTransactionSlot()
        }
        try Task.checkCancellation()

        do {
            try directories.prepare(fileSystem: fileSystem)
            try await profileStore.prepareWorkingDirectories(for: profileID)
        } catch {
            throw RuntimeConfigTransactionError.stagingFailed
        }
        guard !fileSystem.fileExists(at: directories.runtimeTransactionJournal) else {
            // Never overwrite recovery evidence from an earlier interrupted or
            // failed transaction. Startup recovery must resolve it first.
            throw RuntimeConfigTransactionError.recoveryFailed
        }

        let rawURL = directories.profileStagingURL(transactionID: transactionID)
        let previousRawURL = directories.profileRollbackURL(transactionID: transactionID)
        let candidateURL = directories.runtimeCandidateURL(transactionID: transactionID)
        let selectedProfileID: UUID?
        let previousProfileRevisionID: UUID?
        let previousProfileRawData: Data?
        let profileRevisionID = commitRawRevision ? UUID() : nil
        do {
            selectedProfileID = try await profileStore.selectedProfileID()
            previousProfileRevisionID = commitRawRevision
                ? try await profileStore.profile(id: profileID)?.currentRevisionID
                : nil
            if commitRawRevision {
                let profileConfigurationURL = await profileStore.configurationURL(for: profileID)
                previousProfileRawData = fileSystem.fileExists(at: profileConfigurationURL)
                    ? try fileSystem.readData(at: profileConfigurationURL)
                    : nil
            } else {
                previousProfileRawData = nil
            }
        } catch {
            throw RuntimeConfigTransactionError.stagingFailed
        }
        try Task.checkCancellation()
        let isActiveProfile = selectedProfileID == profileID
        let engineRunning = await processManager.isRunning()
        let previousData: Data?
        if isActiveProfile, fileSystem.fileExists(at: directories.activeConfiguration) {
            do {
                previousData = try fileSystem.readData(at: directories.activeConfiguration)
            } catch {
                throw RuntimeConfigTransactionError.activeReplacementFailed
            }
        } else {
            previousData = nil
        }

        var journal = RuntimeConfigTransactionJournal(
            transactionID: transactionID,
            profileID: profileID,
            phase: .downloaded,
            candidateRawPath: rawURL.path,
            candidateRuntimePath: candidateURL.path,
            previousRuntimePath: previousData == nil ? nil : directories.previousConfiguration.path,
            startedAt: now(),
            commitEvidence: commitRawRevision
                ? .profileRevision(
                    rawData: rawData,
                    previousRevisionID: previousProfileRevisionID,
                    revisionID: profileRevisionID,
                    previousRawURL: previousProfileRawData == nil ? nil : previousRawURL
                )
                : commitAction?.evidence
        )
        do {
            try writePrivate(rawData, to: rawURL)
            if let previousProfileRawData {
                try writePrivate(previousProfileRawData, to: previousRawURL)
            }
            try saveJournal(journal)
        } catch {
            cleanup(journal)
            throw RuntimeConfigTransactionError.stagingFailed
        }

        let runtimeData: Data
        do {
            let runtimeSource = commitRawRevision
                ? try applyingPersistedOverrides(to: rawData, profileID: profileID)
                : rawData
            let layers = try await configurationLayerStore?.layers(
                profileID: profileID,
                sceneID: nil
            ) ?? []
            runtimeData = try runtimeBuilder.build(
                from: runtimeSource,
                parameters: runtimeParameters,
                context: ConfigurationCompilationContext(
                    profileID: profileID,
                    profileRevisionID: profileRevisionID ?? previousProfileRevisionID,
                    layers: layers
                )
            )
            try writePrivate(runtimeData, to: candidateURL)
            journal.phase = .built
            try saveJournal(journal)
        } catch is CancellationError {
            cleanup(journal)
            throw CancellationError()
        } catch {
            cleanup(journal)
            throw RuntimeConfigTransactionError.runtimeBuildFailed
        }

        let executable: ResolvedMihomoExecutable
        do {
            executable = try await executableResolver.resolve()
        } catch {
            cleanup(journal)
            throw RuntimeConfigTransactionError.executableResolutionFailed
        }
        let validation = await validator.validate(
            configurationURL: candidateURL,
            dataDirectoryURL: directories.mihomo,
            using: executable,
            timeout: .seconds(15)
        )
        if Task.isCancelled {
            cleanup(journal)
            throw CancellationError()
        }
        guard validation.isValid else {
            cleanup(journal)
            throw RuntimeConfigTransactionError.configurationValidationFailed(validation)
        }
        do {
            journal.phase = .validated
            try saveJournal(journal)
        } catch {
            cleanup(journal)
            throw RuntimeConfigTransactionError.stagingFailed
        }

        guard isActiveProfile else {
            if Task.isCancelled {
                cleanup(journal)
                throw CancellationError()
            }
            return try await commitInactive(
                journal: journal,
                rawData: rawData,
                sourceFileName: sourceFileName,
                remoteMetadata: updatedRemoteMetadata,
                commitRawRevision: commitRawRevision,
                commitAction: commitAction
            )
        }

        let selectorSnapshot = engineRunning ? await snapshotSelectors() : [:]
        if Task.isCancelled {
            cleanup(journal)
            throw CancellationError()
        }
        do {
            if let previousData {
                try writePrivate(previousData, to: directories.previousConfiguration)
            } else if fileSystem.fileExists(at: directories.previousConfiguration) {
                try fileSystem.removeItem(at: directories.previousConfiguration)
            }
            // Record the conservative recovery decision before replacing active.
            // If the app exits between these two operations, startup may restore
            // an unchanged previous file, which is safe and idempotent.
            journal.phase = .activeReplaced
            try saveJournal(journal)
            try writePrivate(runtimeData, to: directories.activeConfiguration)
        } catch {
            do {
                try restoreActive(previousData)
            } catch {
                // Preserve the latest journal and previous file when the old
                // active configuration cannot be restored.
                throw RuntimeConfigTransactionError.rollbackFailed
            }
            cleanup(journal)
            throw RuntimeConfigTransactionError.activeReplacementFailed
        }

        guard engineRunning else {
            do {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let revision = try await commitChanges(
                    rawData: rawData,
                    profileID: profileID,
                    sourceFileName: sourceFileName,
                    remoteMetadata: updatedRemoteMetadata,
                    commitRawRevision: commitRawRevision,
                    commitAction: commitAction,
                    profileRevisionID: journal.commitEvidence?.profileRevisionID
                )
                completeAndCleanup(&journal)
                return RuntimeConfigTransactionResult(
                    transactionID: transactionID,
                    revision: revision,
                    configurationGeneration: ConfigurationGeneration(),
                    selectorRestore: SelectorRestoreResult(restored: [:], skipped: [:]),
                    hotReloaded: false
                )
            } catch is CancellationError {
                do {
                    try rollbackStoppedTransaction(
                        journal: &journal,
                        previousData: previousData,
                        preserveJournal: false
                    )
                } catch {
                    throw RuntimeConfigTransactionError.rollbackFailed
                }
                throw CancellationError()
            } catch let failure as CommitChangesFailure {
                do {
                    try rollbackStoppedTransaction(
                        journal: &journal,
                        previousData: previousData,
                        preserveJournal: failure == .rollbackFailed
                    )
                } catch {
                    throw RuntimeConfigTransactionError.rollbackFailed
                }
                switch failure {
                case .commitFailed:
                    throw RuntimeConfigTransactionError.revisionCommitFailed
                case .rollbackFailed:
                    throw RuntimeConfigTransactionError.rollbackFailed
                }
            } catch {
                do {
                    try rollbackStoppedTransaction(
                        journal: &journal,
                        previousData: previousData,
                        preserveJournal: false
                    )
                } catch {
                    throw RuntimeConfigTransactionError.rollbackFailed
                }
                throw RuntimeConfigTransactionError.revisionCommitFailed
            }
        }

        do {
            try await apiClient.reloadConfiguration(
                at: directories.activeConfiguration,
                force: false
            )
            journal.phase = .controllerApplied
            try saveJournal(journal)
            try await waitForController()
            try await refreshControllerCatalogs()
            let selectorRestore = await restoreSelectors(selectorSnapshot)
            guard await processManager.isRunning() else {
                throw RuntimeConfigTransactionError.healthVerificationFailed
            }
            journal.phase = .healthVerified
            try saveJournal(journal)
            try Task.checkCancellation()
            let revision: ProfileRevision?
            do {
                revision = try await commitChanges(
                    rawData: rawData,
                    profileID: profileID,
                    sourceFileName: sourceFileName,
                    remoteMetadata: updatedRemoteMetadata,
                    commitRawRevision: commitRawRevision,
                    commitAction: commitAction,
                    profileRevisionID: journal.commitEvidence?.profileRevisionID
                )
            } catch let failure as CommitChangesFailure {
                switch failure {
                case .commitFailed:
                    throw RuntimeConfigTransactionError.revisionCommitFailed
                case .rollbackFailed:
                    throw RuntimeConfigTransactionError.rollbackFailed
                }
            }
            completeAndCleanup(&journal)
            return RuntimeConfigTransactionResult(
                transactionID: transactionID,
                revision: revision,
                configurationGeneration: ConfigurationGeneration(),
                selectorRestore: selectorRestore,
                hotReloaded: true
            )
        } catch is CancellationError {
            try await rollback(
                journal: &journal,
                previousData: previousData,
                preserveJournal: false
            )
            throw CancellationError()
        } catch let transactionError as RuntimeConfigTransactionError {
            try await rollback(
                journal: &journal,
                previousData: previousData,
                preserveJournal: transactionError == .rollbackFailed
            )
            throw transactionError
        } catch {
            try await rollback(
                journal: &journal,
                previousData: previousData,
                preserveJournal: false
            )
            throw RuntimeConfigTransactionError.hotReloadFailed
        }
    }

    func recoverIfNeeded() async throws {
        let lease = try await runtimeMutationGate.acquire(.configurationTransaction)
        do {
            try await recoverExclusively()
            await runtimeMutationGate.release(lease)
        } catch {
            await runtimeMutationGate.release(lease)
            throw error
        }
    }

    private func recoverExclusively() async throws {
        try await acquireTransactionSlot()
        defer {
            activeTransactionID = nil
            releaseTransactionSlot()
        }
        do {
            try directories.prepare(fileSystem: fileSystem)
        } catch {
            throw RuntimeConfigTransactionError.recoveryFailed
        }
        guard fileSystem.fileExists(at: directories.runtimeTransactionJournal) else {
            do {
                try cleanupStaleTransactionArtifactsWithoutJournal()
            } catch {
                throw RuntimeConfigTransactionError.recoveryFailed
            }
            return
        }
        activeTransactionID = UUID()
        try Task.checkCancellation()

        let journal: RuntimeConfigTransactionJournal
        do {
            let data = try fileSystem.readData(at: directories.runtimeTransactionJournal)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            journal = try decoder.decode(RuntimeConfigTransactionJournal.self, from: data)
            guard isValid(journal) else {
                throw RuntimeConfigTransactionError.journalCorrupt
            }
        } catch let transactionError as RuntimeConfigTransactionError {
            throw transactionError
        } catch {
            throw RuntimeConfigTransactionError.journalCorrupt
        }

        switch journal.phase {
        case .downloaded, .built, .committed:
            cleanup(journal)
        case .validated:
            if await hasDurableCommitEvidence(journal) {
                cleanup(journal)
                return
            }
            try await reconcileInterruptedCommitIfNeeded(journal)
            cleanup(journal)
        case .activeReplaced, .healthVerified:
            if await hasDurableCommitEvidence(journal) {
                cleanup(journal)
                return
            }
            try await reconcileInterruptedCommitIfNeeded(journal)
            try await recoverByRollingBack(journal)
        case .controllerApplied:
            try await reconcileInterruptedCommitIfNeeded(journal)
            try await recoverByRollingBack(journal)
        case .rollingBack:
            if journal.commitEvidence?.kind == .configurationOverride {
                // Rollback intent wins over a matching new artifact. A failed
                // chmod/compensating write can otherwise look indistinguishable
                // from a completed commit by content hash alone.
                try await reconcileInterruptedCommitIfNeeded(journal)
                try await recoverByRollingBack(journal)
                return
            }
            guard !(await hasDurableCommitEvidence(journal)) else {
                // A rollback-intent journal must never silently keep committed
                // storage while the runtime is being restored to the previous
                // configuration.
                throw RuntimeConfigTransactionError.recoveryFailed
            }
            try await reconcileInterruptedCommitIfNeeded(journal)
            try await recoverByRollingBack(journal)
        }
    }

    private func reconcileInterruptedCommitIfNeeded(
        _ journal: RuntimeConfigTransactionJournal
    ) async throws {
        guard let evidence = journal.commitEvidence else { return }
        switch evidence.kind {
        case .profileRevision:
            let profileExists: Bool
            do {
                profileExists = try await profileStore.profile(id: journal.profileID) != nil
            } catch {
                throw RuntimeConfigTransactionError.recoveryFailed
            }
            guard profileExists else {
                // The user may delete a failed remote profile after a rollback
                // journal was retained. Its raw configuration and revision
                // metadata were removed by that deletion, so there is no
                // profile commit left to reconcile. Runtime rollback and
                // journal cleanup still run after this method returns.
                return
            }
            guard let interruptedRevisionID = evidence.profileRevisionID else {
                // Older journals did not retain enough information to remove
                // the orphan revision safely. Keep the journal for diagnosis.
                throw RuntimeConfigTransactionError.recoveryFailed
            }
            let previousRawData: Data?
            if let previousRawPath = evidence.previousProfileRawPath {
                do {
                    previousRawData = try fileSystem.readData(
                        at: URL(fileURLWithPath: previousRawPath)
                    )
                } catch {
                    throw RuntimeConfigTransactionError.recoveryFailed
                }
            } else {
                previousRawData = nil
            }
            do {
                try await profileStore.rollbackInterruptedRevisionCommit(
                    for: journal.profileID,
                    previousRevisionID: evidence.previousProfileRevisionID,
                    interruptedRevisionID: interruptedRevisionID,
                    previousRawData: previousRawData
                )
            } catch {
                throw RuntimeConfigTransactionError.recoveryFailed
            }
        case .configurationOverride:
            do {
                try restorePreviousOverride(using: evidence, profileID: journal.profileID)
            } catch let error as RuntimeConfigTransactionError {
                throw error
            } catch {
                throw RuntimeConfigTransactionError.recoveryFailed
            }
        }
    }

    private func restorePreviousOverride(
        using evidence: RuntimeConfigTransactionCommitEvidence,
        profileID: UUID
    ) throws {
        guard let previousExisted = evidence.previousOverrideExisted,
            let backupPath = evidence.previousOverrideBackupPath
        else {
            // Legacy journals can be cleaned only when the official artifact
            // was never replaced. If it contains the candidate, the old value
            // is unknowable and the evidence must be retained for diagnosis.
            if let artifactPath = evidence.artifactPath {
                let artifactURL = URL(fileURLWithPath: artifactPath)
                if fileSystem.fileExists(at: artifactURL),
                    let data = try? fileSystem.readData(at: artifactURL),
                    RuntimeConfigTransactionCommitEvidence.sha256(data)
                        .caseInsensitiveCompare(evidence.expectedContentSHA256) == .orderedSame
                {
                    throw RuntimeConfigTransactionError.recoveryFailed
                }
            }
            return
        }

        let artifactURL = directories.overrideURL(for: profileID)
        let backupURL = URL(fileURLWithPath: backupPath)
        if previousExisted {
            guard let expectedSHA = evidence.previousOverrideContentSHA256,
                fileSystem.fileExists(at: backupURL)
            else {
                throw RuntimeConfigTransactionError.recoveryFailed
            }
            let backupData = try fileSystem.readData(at: backupURL)
            guard RuntimeConfigTransactionCommitEvidence.sha256(backupData)
                .caseInsensitiveCompare(expectedSHA) == .orderedSame
            else {
                throw RuntimeConfigTransactionError.recoveryFailed
            }
            try fileSystem.writeDataAtomically(backupData, to: artifactURL)
            try fileSystem.setPOSIXPermissions(0o600, at: artifactURL)
        } else if fileSystem.fileExists(at: artifactURL) {
            try fileSystem.removeItem(at: artifactURL)
        }
    }

    private func recoverByRollingBack(
        _ journal: RuntimeConfigTransactionJournal
    ) async throws {
            let previousData: Data?
            do {
                if let path = journal.previousRuntimePath {
                    let previousURL = URL(fileURLWithPath: path)
                    guard fileSystem.fileExists(at: previousURL) else {
                        throw RuntimeConfigTransactionError.recoveryFailed
                    }
                    previousData = try fileSystem.readData(at: previousURL)
                } else {
                    previousData = nil
                }
            } catch {
                throw RuntimeConfigTransactionError.recoveryFailed
            }

            var recoveringJournal = journal
            do {
                try await rollback(
                    journal: &recoveringJournal,
                    previousData: previousData,
                    preserveJournal: false
                )
            } catch {
                throw RuntimeConfigTransactionError.recoveryFailed
            }
    }

    private func commitInactive(
        journal: RuntimeConfigTransactionJournal,
        rawData: Data,
        sourceFileName: String,
        remoteMetadata: RemoteProfileMetadata?,
        commitRawRevision: Bool,
        commitAction: RuntimeConfigTransactionCommitAction?
    ) async throws -> RuntimeConfigTransactionResult {
        do {
            let revision = try await commitChanges(
                rawData: rawData,
                profileID: journal.profileID,
                sourceFileName: sourceFileName,
                remoteMetadata: remoteMetadata,
                commitRawRevision: commitRawRevision,
                commitAction: commitAction,
                profileRevisionID: journal.commitEvidence?.profileRevisionID
            )
            var committed = journal
            completeAndCleanup(&committed)
            return RuntimeConfigTransactionResult(
                transactionID: journal.transactionID,
                revision: revision,
                configurationGeneration: ConfigurationGeneration(),
                selectorRestore: SelectorRestoreResult(restored: [:], skipped: [:]),
                hotReloaded: false
            )
        } catch CommitChangesFailure.commitFailed {
            cleanup(journal)
            throw RuntimeConfigTransactionError.revisionCommitFailed
        } catch CommitChangesFailure.rollbackFailed {
            // The external commit may have changed before its rollback failed.
            // Persist rollback intent so content-hash evidence cannot mistake
            // the half-committed artifact for a successful inactive commit.
            if commitAction?.evidence?.kind == .configurationOverride {
                var rollingBack = journal
                rollingBack.phase = .rollingBack
                try? saveJournal(rollingBack)
            }
            throw RuntimeConfigTransactionError.rollbackFailed
        } catch {
            cleanup(journal)
            throw RuntimeConfigTransactionError.revisionCommitFailed
        }
    }

    private func rollback(
        journal: inout RuntimeConfigTransactionJournal,
        previousData: Data?,
        preserveJournal: Bool
    ) async throws {
        do {
            journal.phase = .rollingBack
            // Restoring the working configuration has priority over diagnostic
            // persistence. A failed journal update must never block rollback.
            try? saveJournal(journal)
            try restoreActive(previousData)
            if previousData != nil {
                if await processManager.isRunning() {
                    do {
                        try await apiClient.reloadConfiguration(
                            at: directories.activeConfiguration,
                            force: false
                        )
                        try await waitForController()
                    } catch {
                        _ = try await processManager.restart(
                            configurationURL: directories.activeConfiguration,
                            dataDirectoryURL: directories.mihomo,
                            additionalArguments: [],
                            validationTimeout: .seconds(15),
                            stopTimeout: .seconds(3)
                        )
                        try await waitForController()
                    }
                    guard await processManager.isRunning() else {
                        throw RuntimeConfigTransactionError.rollbackFailed
                    }
                }
            } else if await processManager.isRunning() {
                _ = try await processManager.stop(timeout: .seconds(3))
                guard !(await processManager.isRunning()) else {
                    throw RuntimeConfigTransactionError.rollbackFailed
                }
            }
            if !preserveJournal {
                cleanup(journal)
            }
        } catch {
            // Keep the journal and previous file so startup recovery and diagnostics
            // retain enough evidence to make one bounded recovery attempt.
            throw RuntimeConfigTransactionError.rollbackFailed
        }
    }

    private func rollbackStoppedTransaction(
        journal: inout RuntimeConfigTransactionJournal,
        previousData: Data?,
        preserveJournal: Bool
    ) throws {
        do {
            journal.phase = .rollingBack
            try? saveJournal(journal)
            try restoreActive(previousData)
            if !preserveJournal {
                cleanup(journal)
            }
        } catch {
            throw RuntimeConfigTransactionError.rollbackFailed
        }
    }

    private func commitChanges(
        rawData: Data,
        profileID: UUID,
        sourceFileName: String,
        remoteMetadata: RemoteProfileMetadata?,
        commitRawRevision: Bool,
        commitAction: RuntimeConfigTransactionCommitAction?,
        profileRevisionID: UUID?
    ) async throws -> ProfileRevision? {
        var actionCommitted = false
        if let commitAction {
            do {
                try commitAction.commit()
                actionCommitted = true
            } catch {
                do {
                    try commitAction.rollback()
                } catch {
                    throw CommitChangesFailure.rollbackFailed
                }
                throw CommitChangesFailure.commitFailed
            }
        }

        guard commitRawRevision else { return nil }
        guard let profileRevisionID else {
            throw CommitChangesFailure.commitFailed
        }
        do {
            return try await profileStore.commitRawRevision(
                rawData,
                for: profileID,
                sourceFileName: sourceFileName,
                revisionID: profileRevisionID,
                updatedRemoteMetadata: remoteMetadata
            )
        } catch let error as ProfileStoreError {
            if case .revisionCommitRollbackFailed = error {
                // Profile storage may already contain the new raw bytes while
                // its metadata still points at the previous revision. Keep the
                // transaction journal so startup recovery can reconcile both.
                throw CommitChangesFailure.rollbackFailed
            }
            if case .revisionCleanupFailed = error,
                let profile = try? await profileStore.profile(id: profileID),
                let currentRevisionID = profile.currentRevisionID,
                let committedRevision = profile.revisions.first(where: {
                    $0.id == currentRevisionID
                })
            {
                // ProfileStore reports pruning as an error even though raw,
                // revision metadata, and currentRevisionID are already durable.
                // Rolling active back here would split runtime from storage.
                return committedRevision
            }
            if actionCommitted, let commitAction {
                do {
                    try commitAction.rollback()
                } catch {
                    throw CommitChangesFailure.rollbackFailed
                }
            }
            throw CommitChangesFailure.commitFailed
        } catch {
            if actionCommitted, let commitAction {
                do {
                    try commitAction.rollback()
                } catch {
                    throw CommitChangesFailure.rollbackFailed
                }
            }
            throw CommitChangesFailure.commitFailed
        }
    }

    private func applyingPersistedOverrides(to rawData: Data, profileID: UUID) throws -> Data {
        let overrideURL = directories.overrideURL(for: profileID)
        guard fileSystem.fileExists(at: overrideURL) else { return rawData }
        let overrideData = try fileSystem.readData(at: overrideURL)
        let overrides = try JSONDecoder().decode(ProfileStructuredOverrides.self, from: overrideData)
        guard let upstreamYAML = String(data: rawData, encoding: .utf8) else {
            throw RuntimeConfigBuilderError.sourceIsNotUTF8
        }
        let result = try overrideProcessor.process(
            upstreamYAML: upstreamYAML,
            overrides: overrides
        )
        guard let data = result.finalYAML.data(using: .utf8) else {
            throw RuntimeConfigBuilderError.runtimeConfigurationEncodingFailed
        }
        return data
    }

    private func completeAndCleanup(_ journal: inout RuntimeConfigTransactionJournal) {
        journal.phase = .committed
        // The profile/override commit is the durable commit point. A later
        // journal write failure must not roll back already-committed data.
        try? saveJournal(journal)
        cleanup(journal)
    }

    private func isValid(_ journal: RuntimeConfigTransactionJournal) -> Bool {
        let expectedRawURLs = [
            directories.profileStagingURL(transactionID: journal.transactionID),
            directories.profileStagingDirectory(for: journal.profileID)
                .appendingPathComponent(
                    "\(journal.transactionID.uuidString).yaml",
                    isDirectory: false
                ),
        ]
        let candidateRawURL = URL(fileURLWithPath: journal.candidateRawPath).standardizedFileURL
        let candidateRuntimeURL = URL(
            fileURLWithPath: journal.candidateRuntimePath
        ).standardizedFileURL
        guard expectedRawURLs.map(\.standardizedFileURL).contains(candidateRawURL),
            candidateRuntimeURL
                == directories.runtimeCandidateURL(
                    transactionID: journal.transactionID
                ).standardizedFileURL
        else {
            return false
        }
        if let previousPath = journal.previousRuntimePath,
            URL(fileURLWithPath: previousPath).standardizedFileURL
                != directories.previousConfiguration.standardizedFileURL
        {
            return false
        }
        guard let evidence = journal.commitEvidence else { return true }
        guard evidence.expectedContentSHA256.count == 64,
            evidence.expectedContentSHA256.allSatisfy({ $0.isHexDigit })
        else {
            return false
        }
        switch evidence.kind {
        case .profileRevision:
            guard evidence.artifactPath == nil,
                evidence.cleanupPath == nil,
                evidence.previousOverrideExisted == nil,
                evidence.previousOverrideBackupPath == nil,
                evidence.previousOverrideContentSHA256 == nil
            else {
                return false
            }
            if let previousRawPath = evidence.previousProfileRawPath,
                URL(fileURLWithPath: previousRawPath).standardizedFileURL
                    != directories.profileRollbackURL(
                        transactionID: journal.transactionID
                    ).standardizedFileURL
            {
                return false
            }
            return true
        case .configurationOverride:
            guard let artifactPath = evidence.artifactPath,
                URL(fileURLWithPath: artifactPath).standardizedFileURL
                    == directories.overrideURL(for: journal.profileID).standardizedFileURL,
                evidence.previousProfileRevisionID == nil,
                evidence.profileRevisionID == nil,
                evidence.previousProfileRawPath == nil
            else {
                return false
            }
            guard let cleanupPath = evidence.cleanupPath else {
                return evidence.previousOverrideExisted == nil
                    && evidence.previousOverrideBackupPath == nil
                    && evidence.previousOverrideContentSHA256 == nil
            }
            let cleanupURL = URL(fileURLWithPath: cleanupPath).standardizedFileURL
            guard cleanupURL.deletingLastPathComponent()
                == directories.overrides.standardizedFileURL,
                let operationID = overrideOperationID(
                    from: cleanupURL,
                    profileID: journal.profileID,
                    suffix: ".staging.json"
                )
            else {
                return false
            }

            let hasNewRollbackEvidence = evidence.previousOverrideExisted != nil
                || evidence.previousOverrideBackupPath != nil
                || evidence.previousOverrideContentSHA256 != nil
            guard hasNewRollbackEvidence else { return true }
            guard let previousExisted = evidence.previousOverrideExisted,
                let backupPath = evidence.previousOverrideBackupPath,
                URL(fileURLWithPath: backupPath).standardizedFileURL
                    == directories.overrideRollbackURL(
                        for: journal.profileID,
                        operationID: operationID
                    ).standardizedFileURL
            else {
                return false
            }
            if previousExisted {
                guard let previousSHA = evidence.previousOverrideContentSHA256,
                    previousSHA.count == 64,
                    previousSHA.allSatisfy({ $0.isHexDigit })
                else {
                    return false
                }
            } else if evidence.previousOverrideContentSHA256 != nil {
                return false
            }
            return true
        }
    }

    private func overrideOperationID(
        from url: URL,
        profileID: UUID,
        suffix: String
    ) -> UUID? {
        let prefix = ".\(profileID.uuidString)."
        let name = url.lastPathComponent
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let value = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard Self.isCanonicalUUID(value) else { return nil }
        return UUID(uuidString: value)
    }

    private func hasDurableCommitEvidence(
        _ journal: RuntimeConfigTransactionJournal
    ) async -> Bool {
        guard let evidence = journal.commitEvidence else { return false }
        switch evidence.kind {
        case .profileRevision:
            guard let profile = try? await profileStore.profile(id: journal.profileID),
                let currentRevisionID = profile.currentRevisionID,
                currentRevisionID != evidence.previousProfileRevisionID,
                evidence.profileRevisionID.map({ $0 == currentRevisionID }) ?? true,
                let revision = profile.revisions.first(where: { $0.id == currentRevisionID }),
                revision.contentSHA256.caseInsensitiveCompare(evidence.expectedContentSHA256)
                    == .orderedSame,
                let rawData = try? await profileStore.readConfiguration(for: journal.profileID)
            else {
                return false
            }
            return RuntimeConfigTransactionCommitEvidence.sha256(rawData)
                .caseInsensitiveCompare(evidence.expectedContentSHA256) == .orderedSame

        case .configurationOverride:
            guard let artifactPath = evidence.artifactPath else { return false }
            let artifactURL = URL(fileURLWithPath: artifactPath)
            guard fileSystem.fileExists(at: artifactURL),
                let data = try? fileSystem.readData(at: artifactURL)
            else {
                return false
            }
            guard RuntimeConfigTransactionCommitEvidence.sha256(data)
                .caseInsensitiveCompare(evidence.expectedContentSHA256) == .orderedSame
            else {
                return false
            }
            // A crash between atomic replacement and chmod can still be
            // finalized safely when the candidate content is exact.
            do {
                try fileSystem.setPOSIXPermissions(0o600, at: artifactURL)
                return true
            } catch {
                return false
            }
        }
    }

    private func acquireTransactionSlot() async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if transactionSlotHolderID == nil {
                    transactionSlotHolderID = waiterID
                    continuation.resume()
                } else if transactionWaiters.count >= Self.maximumQueuedTransactions {
                    // This is an overload guard, not the normal concurrency path.
                    // Scheduler concurrency two always fits in the FIFO.
                    continuation.resume(
                        throwing: RuntimeConfigTransactionError.stagingFailed
                    )
                } else {
                    transactionWaiters.append(
                        TransactionWaiter(id: waiterID, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelTransactionWaiter(waiterID) }
        }

        do {
            try Task.checkCancellation()
        } catch {
            if transactionSlotHolderID == waiterID {
                releaseTransactionSlot()
            }
            throw error
        }
    }

    private func cancelTransactionWaiter(_ waiterID: UUID) {
        guard let index = transactionWaiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = transactionWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseTransactionSlot() {
        transactionSlotHolderID = nil
        guard !transactionWaiters.isEmpty else { return }
        let next = transactionWaiters.removeFirst()
        transactionSlotHolderID = next.id
        next.continuation.resume()
    }

    private func snapshotSelectors() async -> [String: String] {
        guard let response = try? await apiClient.proxies() else { return [:] }
        return response.proxies.reduce(into: [String: String]()) { result, entry in
            let proxy = entry.value
            if proxy.type.caseInsensitiveCompare("Selector") == .orderedSame,
                let selected = proxy.now
            {
                result[entry.key] = selected
            }
        }
    }

    private func restoreSelectors(_ snapshot: [String: String]) async -> SelectorRestoreResult {
        guard !snapshot.isEmpty, let response = try? await apiClient.proxies() else {
            return SelectorRestoreResult(restored: [:], skipped: snapshot)
        }
        var restored: [String: String] = [:]
        var skipped: [String: String] = [:]
        for group in snapshot.keys.sorted() {
            guard let target = snapshot[group],
                let current = response.proxies[group],
                current.type.caseInsensitiveCompare("Selector") == .orderedSame,
                current.all?.contains(target) == true
            else {
                skipped[group] = snapshot[group]
                continue
            }
            do {
                try await apiClient.selectProxy(group: group, proxy: target)
                restored[group] = target
            } catch {
                skipped[group] = target
            }
        }
        return SelectorRestoreResult(restored: restored, skipped: skipped)
    }

    private func refreshControllerCatalogs() async throws {
        async let proxies = apiClient.proxies()
        async let proxyProviders = apiClient.proxyProviders()
        async let ruleProviders = apiClient.ruleProviders()
        async let rules = apiClient.rules()
        _ = try await (proxies, proxyProviders, ruleProviders, rules)
    }

    private func waitForController() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: controllerRecoveryTimeout)
        while clock.now < deadline {
            do {
                _ = try await apiClient.version()
                _ = try await apiClient.configs()
                return
            } catch {
                try await Task.sleep(for: controllerPollInterval)
            }
        }
        throw RuntimeConfigTransactionError.controllerDidNotRecover
    }

    private func restoreActive(_ data: Data?) throws {
        if let data {
            try writePrivate(data, to: directories.activeConfiguration)
        } else if fileSystem.fileExists(at: directories.activeConfiguration) {
            try fileSystem.removeItem(at: directories.activeConfiguration)
        }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try fileSystem.createDirectory(at: url.deletingLastPathComponent())
        try fileSystem.setPOSIXPermissions(0o700, at: url.deletingLastPathComponent())
        try fileSystem.writeDataAtomically(data, to: url)
        try fileSystem.setPOSIXPermissions(0o600, at: url)
    }

    private func saveJournal(_ journal: RuntimeConfigTransactionJournal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(
            encoder.encode(journal),
            to: directories.runtimeTransactionJournal
        )
    }

    private func cleanup(_ journal: RuntimeConfigTransactionJournal) {
        var artifactURLs = [
            URL(fileURLWithPath: journal.candidateRawPath),
            URL(fileURLWithPath: journal.candidateRuntimePath),
            directories.runtimeTransactionJournal,
        ]
        if let cleanupPath = journal.commitEvidence?.cleanupPath {
            artifactURLs.append(URL(fileURLWithPath: cleanupPath))
        }
        if let previousRawPath = journal.commitEvidence?.previousProfileRawPath {
            artifactURLs.append(URL(fileURLWithPath: previousRawPath))
        }
        if let backupPath = journal.commitEvidence?.previousOverrideBackupPath {
            artifactURLs.append(URL(fileURLWithPath: backupPath))
        }

        var failureCount = 0
        for url in artifactURLs where fileSystem.fileExists(at: url) {
            do {
                try fileSystem.removeItem(at: url)
            } catch {
                failureCount += 1
            }
        }
        if failureCount > 0 {
            Self.logger.error(
                "Transaction cleanup left \(failureCount, privacy: .public) artifact(s) for startup retry."
            )
        }
    }

    /// Removes only transaction-shaped regular files after proving there is no
    /// recovery journal. A journal is the authority for every interrupted
    /// transaction, so its evidence is never mixed with opportunistic cleanup.
    private func cleanupStaleTransactionArtifactsWithoutJournal() throws {
        guard !fileSystem.fileExists(at: directories.runtimeTransactionJournal) else {
            return
        }

        let locations: [(directory: URL, matches: (String) -> Bool)] = [
            (directories.profileStaging, Self.isProfileTransactionArtifact),
            (directories.runtimeCandidates, Self.isRuntimeCandidateArtifact),
            (directories.overrides, Self.isOverrideStagingArtifact),
        ]

        for location in locations {
            let expectedParent = location.directory.standardizedFileURL
            for entry in try fileSystem.contentsOfDirectory(at: location.directory) {
                let candidate = entry.standardizedFileURL
                guard candidate.deletingLastPathComponent() == expectedParent,
                    location.matches(candidate.lastPathComponent),
                    fileSystem.isRegularFile(at: candidate)
                else {
                    continue
                }
                try fileSystem.removeItem(at: candidate)
            }
        }
    }

    private static func isProfileTransactionArtifact(_ name: String) -> Bool {
        hasCanonicalUUIDPrefix(name, suffix: ".yaml")
            || hasCanonicalUUIDPrefix(name, suffix: ".previous.yaml")
    }

    private static func isRuntimeCandidateArtifact(_ name: String) -> Bool {
        hasCanonicalUUIDPrefix(name, suffix: ".yaml")
    }

    private static func isOverrideStagingArtifact(_ name: String) -> Bool {
        for suffix in [".staging.json", ".previous.json"] where name.hasSuffix(suffix) {
            guard name.first == "." else { return false }
            let identifiers = name.dropFirst().dropLast(suffix.count).split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            return identifiers.count == 2
                && isCanonicalUUID(String(identifiers[0]))
                && isCanonicalUUID(String(identifiers[1]))
        }
        return false
    }

    private static func hasCanonicalUUIDPrefix(
        _ name: String,
        suffix: String
    ) -> Bool {
        guard name.hasSuffix(suffix) else { return false }
        return isCanonicalUUID(String(name.dropLast(suffix.count)))
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard value.count == 36, let identifier = UUID(uuidString: value) else {
            return false
        }
        return identifier.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }
}
