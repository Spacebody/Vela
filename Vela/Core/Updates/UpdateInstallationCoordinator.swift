import Foundation
import OSLog
import VelaIPC

@MainActor
protocol UpdateEnginePreparing: AnyObject {
    var selectedProfile: Profile? { get }
    var isRunning: Bool { get }
    var activeBackendKind: EngineBackendKind { get }
    var isSystemProxyApplied: Bool { get }
    var runtimeMode: MihomoMode? { get }
    var privilegedComponentManager: PrivilegedComponentManager? { get }
    var networkPathSnapshot: NetworkPathSnapshot { get }
    var proxyCatalog: ProxyCatalog { get }

    func prepareForUpdateInstallation(
        configurationGenerationID: UUID?
    ) async throws -> EngineUpdateInstallationPreparationResult
    func cancelPreparedUpdateInstallation() async
}

extension EngineStore: UpdateEnginePreparing {}

@MainActor
protocol UpdateDailyDriverSuspending: AnyObject {
    var configurationGeneration: ConfigurationGeneration { get }

    func suspendForUpdate() async
    func resumeAfterCancelledUpdate(
        networkAvailable: Bool,
        engineRunning: Bool
    )
}

extension DailyDriverFeatureHub: UpdateDailyDriverSuspending {}

@MainActor
final class UpdateInstallationCoordinator: UpdateInstallationCoordinating {
    private let engineStore: any UpdateEnginePreparing
    private let dailyDriver: any UpdateDailyDriverSuspending
    private let journalStore: UpdateJournalStore
    private let sourceIdentity: ReleaseBuildIdentity
    private let lifecycleSink: @MainActor @Sendable (UpdateLifecycleStatus) -> Void
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    private var preparationTask: Task<Void, Never>?
    private var installHandlerWasInvoked = false

    init(
        engineStore: any UpdateEnginePreparing,
        dailyDriver: any UpdateDailyDriverSuspending,
        journalStore: UpdateJournalStore,
        sourceIdentity: ReleaseBuildIdentity,
        timeout: Duration = .seconds(30),
        lifecycleSink: @escaping @MainActor @Sendable (UpdateLifecycleStatus) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.engineStore = engineStore
        self.dailyDriver = dailyDriver
        self.journalStore = journalStore
        self.sourceIdentity = sourceIdentity
        self.timeout = timeout
        self.lifecycleSink = lifecycleSink
        self.sleep = sleep
        self.now = now
    }

    func prepareForInstallation(
        target: UpdateInstallTarget,
        installHandler: @escaping @MainActor () -> Void
    ) {
        guard preparationTask == nil, !installHandlerWasInvoked else { return }
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPreparation(
                target: target,
                installHandler: installHandler
            )
            self.preparationTask = nil
        }
    }

    private func performPreparation(
        target: UpdateInstallTarget,
        installHandler: @escaping @MainActor () -> Void
    ) async {
        guard let targetBuild = Int(target.build), targetBuild > sourceIdentity.build else {
            lifecycleSink(
                .failed(
                    code: "invalid_update_target",
                    message: "The selected update does not have a newer monotonic build number."
                )
            )
            return
        }

        let targetIdentity = ReleaseBuildIdentity(
            version: target.version,
            build: targetBuild
        )
        let startedAt = now()
        let updateID = UUID()
        var journal = UpdateJournal(
            updateID: updateID,
            source: sourceIdentity,
            target: targetIdentity,
            phase: .preparing,
            snapshot: makeBestEffortSnapshot(),
            startedAt: startedAt
        )
        var lastDurableJournal = journal
        var engineWasPrepared = false
        var dailyDriverWasSuspended = false

        do {
            UpdateLog.preparation.info("Update preparation started; targetBuild=\(targetBuild, privacy: .public)")
            try await journalStore.save(journal)
            lastDurableJournal = journal
            lifecycleSink(.preparing)

            journal.phase = .quiescing
            journal.lastUpdatedAt = now()
            try await journalStore.save(journal)
            lastDurableJournal = journal

            let preparation = try await withTimeout(timeout) {
                [engineStore, generationID = dailyDriver.configurationGeneration.id] in
                try await engineStore.prepareForUpdateInstallation(
                    configurationGenerationID: generationID
                )
            }
            guard preparation.proof.isSafeForInstaller else {
                throw EngineUpdatePreparationError.shutdownProofFailed
            }
            engineWasPrepared = true

            journal = UpdateJournal(
                updateID: updateID,
                source: sourceIdentity,
                target: targetIdentity,
                phase: .quiescing,
                snapshot: preparation.snapshot,
                startedAt: startedAt,
                lastUpdatedAt: now()
            )
            try await journalStore.save(journal)
            lastDurableJournal = journal

            await dailyDriver.suspendForUpdate()
            dailyDriverWasSuspended = true

            journal.phase = .readyForInstaller
            journal.lastUpdatedAt = now()
            try await journalStore.save(journal)
            lastDurableJournal = journal
            lifecycleSink(.readyForInstaller)

            // Mark the durable boundary before entering Sparkle. If the
            // process terminates immediately, the next launch can distinguish
            // an installer handoff from an interrupted preparation.
            journal.phase = .installerStarted
            journal.lastUpdatedAt = now()
            try await journalStore.save(journal)
            lastDurableJournal = journal

            guard !installHandlerWasInvoked else { return }
            installHandlerWasInvoked = true
            UpdateLog.preparation.info("Update preparation reached installer handoff")
            installHandler()
        } catch {
            if engineWasPrepared {
                await engineStore.cancelPreparedUpdateInstallation()
            }
            if dailyDriverWasSuspended {
                dailyDriver.resumeAfterCancelledUpdate(
                    networkAvailable:
                        engineStore.networkPathSnapshot.networkReachable,
                    engineRunning: engineStore.isRunning
                )
            }
            let failedPhase = journal.phase
            var failedJournal = lastDurableJournal
            failedJournal.phase = .failed
            failedJournal.lastUpdatedAt = now()
            failedJournal.failure = UpdateFailureSummary(
                code: Self.failureCode(for: error),
                phase: failedPhase,
                summary: DiagnosticTextSanitizer.redact(error.localizedDescription)
            )
            do {
                try await journalStore.save(failedJournal)
            } catch {
                UpdateLog.preparation.error(
                    "Failed to persist the update-preparation failure journal; code=\(Self.failureCode(for: error), privacy: .public)"
                )
            }
            UpdateLog.preparation.error("Update preparation failed; code=\(Self.failureCode(for: error), privacy: .public)")
            lifecycleSink(
                .failed(
                    code: Self.failureCode(for: error),
                    message: DiagnosticTextSanitizer.redact(error.localizedDescription)
                )
            )
        }
    }

    private func makeBestEffortSnapshot() -> UpdateRuntimeSnapshot {
        let profile = engineStore.selectedProfile
        let backend: UpdateJournalBackend? = if engineStore.isRunning {
            engineStore.activeBackendKind == .privilegedDaemon ? .tun : .userProcess
        } else {
            nil
        }
        let handshake = engineStore.privilegedComponentManager?.lastHandshake
        let helperProtocol = handshake.flatMap { response in
            ProtocolCompatibilityRange(
                min: response.helperProtocolMinimum,
                max: response.helperProtocolMaximum
            ).negotiatedVersion(
                with: ProtocolCompatibilityRange(
                    min: VelaIPCConstants.protocolMinimum,
                    max: VelaIPCConstants.protocolMaximum
                )
            )
        }

        return UpdateRuntimeSnapshot(
            profileID: profile?.id,
            profileRevisionID: profile?.currentRevisionID,
            sceneID: nil,
            backend: backend,
            systemProxyDesired: engineStore.isSystemProxyApplied,
            mihomoMode: engineStore.runtimeMode,
            automaticScenesEnabled: false,
            helperVersion: handshake?.helperVersion,
            helperProtocol: helperProtocol,
            configurationGenerationID: dailyDriver.configurationGeneration.id,
            proxySelections: currentProxySelections()
        )
    }

    private func currentProxySelections() -> [UpdateProxySelection] {
        engineStore.proxyCatalog.groups.compactMap { group in
            let current = group.nodes.filter(\.isCurrent)
            guard current.count == 1, let node = current.first else { return nil }
            let proxyID = switch node.origin {
            case .runtime:
                "runtime:\(node.name)"
            case let .provider(name):
                "provider:\(name):\(node.name)"
            }
            return UpdateProxySelection(
                groupID: "runtime:\(group.name)",
                proxyID: proxyID
            )
        }
    }

    private func withTimeout<Value: Sendable>(
        _ duration: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask { [sleep] in
                try await sleep(duration)
                throw UpdateInstallationCoordinatorError.timedOut
            }
            guard let value = try await group.next() else {
                throw UpdateInstallationCoordinatorError.cancelled
            }
            group.cancelAll()
            return value
        }
    }

    private static func failureCode(for error: any Error) -> String {
        if let error = error as? UpdateInstallationCoordinatorError {
            return error.rawValue
        }
        if let error = error as? EngineUpdatePreparationError {
            return switch error {
            case .snapshotFailed: "snapshot_failed"
            case .runtimeCleanupFailed: "runtime_cleanup_failed"
            case .shutdownProofFailed: "shutdown_proof_failed"
            }
        }
        if error is UpdateJournalStoreError {
            return "update_journal_failed"
        }
        if error is RuntimeMutationGateError {
            return "mutation_gate_failed"
        }
        return "update_preparation_failed"
    }
}

nonisolated enum UpdateInstallationCoordinatorError: String, Error, Equatable, Sendable {
    case timedOut = "update_preparation_timed_out"
    case cancelled = "update_preparation_cancelled"
}
