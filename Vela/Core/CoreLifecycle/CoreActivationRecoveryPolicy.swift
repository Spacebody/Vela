import Foundation
import VelaIPC

/// Deterministic decisions for a durable Core activation journal found during
/// bootstrap. The policy is intentionally side-effect free: the controller is
/// responsible for applying the selected Core, the quarantine mutation and the
/// compare-and-swap journal update in that order.
nonisolated enum CoreActivationRecoveryPolicy {
    struct Plan: Equatable, Sendable {
        enum JournalAction: Equatable, Sendable {
            case none
            case clearCommitted
            case markFailed(automaticRollbackAttempts: Int)
            case retainForRepair
        }

        let selectedCoreID: CoreID
        let quarantineCandidate: Bool
        let manualRepairRequired: Bool
        let journalAction: JournalAction
    }

    /// A previous Core is a rollback target only while its local record remains
    /// usable. A withdrawn Known Good Core may continue to run, but a blocked or
    /// quarantined Core must never be selected as an automatic rollback target.
    static func plan(
        transaction: CoreActivationTransaction?,
        state: CoreStoreState,
        factoryCoreID: CoreID
    ) -> Plan {
        guard let transaction else {
            return Plan(
                selectedCoreID: state.activeCoreID,
                quarantineCandidate: false,
                manualRepairRequired: false,
                journalAction: .none
            )
        }

        if transaction.phase == .committed {
            return Plan(
                selectedCoreID: state.activeCoreID,
                quarantineCandidate: false,
                manualRepairRequired: false,
                journalAction: .clearCommitted
            )
        }

        // An attempt already recorded, or a crash while the journal says it is
        // rolling back, can never open a second automatic rollback loop.
        if transaction.automaticRollbackAttempts >= 1
            || transaction.phase == .rollingBack
        {
            return Plan(
                selectedCoreID: factoryCoreID,
                quarantineCandidate: !transaction.coreID.isFactory,
                manualRepairRequired: true,
                journalAction: transaction.automaticRollbackAttempts >= 1
                    ? .retainForRepair
                    : .markFailed(automaticRollbackAttempts: 1)
            )
        }

        let previous = transaction.snapshot?.previousCoreID
        let rollbackTarget: CoreID
        if let previous, isEligibleRollbackTarget(
            previous,
            state: state,
            factoryCoreID: factoryCoreID
        ) {
            rollbackTarget = previous
        } else {
            rollbackTarget = factoryCoreID
        }

        return Plan(
            selectedCoreID: rollbackTarget,
            quarantineCandidate: !transaction.coreID.isFactory,
            manualRepairRequired: true,
            journalAction: .markFailed(automaticRollbackAttempts: 1)
        )
    }

    private static func isEligibleRollbackTarget(
        _ coreID: CoreID,
        state: CoreStoreState,
        factoryCoreID: CoreID
    ) -> Bool {
        if coreID.isFactory { return coreID == factoryCoreID }
        guard let record = state.record(for: coreID) else { return false }
        return record.status != .blocked && record.status != .quarantined
    }
}

/// Cancellation is harmless until the durable activation journal exists. Once
/// it exists, stop/start may already have happened and cancellation must finish
/// at the rollback safe point instead of merely returning to idle.
nonisolated enum CoreActivationCancellationPolicy {
    enum Plan: Equatable, Sendable {
        case returnIdleWithoutQuarantine
        case rollbackSafelyAndQuarantineCandidate
    }

    static func plan(hasDurableTransaction: Bool) -> Plan {
        hasDurableTransaction
            ? .rollbackSafelyAndQuarantineCandidate
            : .returnIdleWithoutQuarantine
    }
}

/// User-visible consequence of a verified Catalog status applied to the Core
/// that is already active. V0.6 deliberately does not allow a Catalog response
/// to become a remote stop or Core-switch command.
nonisolated enum CoreActiveIncidentPolicy {
    enum Presentation: Equatable, Sendable {
        case none
        case criticalBlocked(reason: String?)
    }

    struct Plan: Equatable, Sendable {
        let activeCoreID: CoreID
        let presentation: Presentation
        let shouldStopOrSwitchAutomatically: Bool
        let offersRollback: Bool
        let offersFactory: Bool
    }

    static func plan(
        activeCoreID: CoreID,
        activeRecord: InstalledCoreRecord?,
        blockReason: String?
    ) -> Plan {
        guard activeRecord?.coreID == activeCoreID,
            activeRecord?.status == .blocked
        else {
            return Plan(
                activeCoreID: activeCoreID,
                presentation: .none,
                shouldStopOrSwitchAutomatically: false,
                offersRollback: false,
                offersFactory: false
            )
        }
        let normalizedReason = blockReason?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return Plan(
            activeCoreID: activeCoreID,
            presentation: .criticalBlocked(
                reason: normalizedReason?.isEmpty == false ? normalizedReason : nil
            ),
            shouldStopOrSwitchAutomatically: false,
            offersRollback: true,
            offersFactory: true
        )
    }
}

/// Time and failure classification for the ten-minute continuous Core
/// probation window. Connectivity is not Core health: an ordinary Internet or
/// node outage keeps the window advancing when process/API/backend health is
/// otherwise intact.
nonisolated struct CoreProbationPolicy: Equatable, Sendable {
    static let requiredContinuousRuntime: TimeInterval = 10 * 60
    static let maximumPollInterval: TimeInterval = 5

    enum Observation: Equatable, Sendable {
        case healthy
        case ordinaryNetworkOutage
        case runtimeUnavailable
        case unexpectedExit
        case criticalAPIContractFailure
        case backendHealthFailure
    }

    enum Decision: Equatable, Sendable {
        case continueProbation(nextCheckAfter: TimeInterval)
        case waitForRuntime
        case commitKnownGood
        case rollbackOnceAndQuarantine
        case retainForManualRepair
    }

    private(set) var healthySince: Date?

    init(healthySince: Date? = nil) {
        self.healthySince = healthySince
    }

    mutating func observe(
        _ observation: Observation,
        at now: Date,
        automaticRollbackAttempts: Int
    ) -> Decision {
        switch observation {
        case .runtimeUnavailable:
            healthySince = nil
            return .waitForRuntime

        case .unexpectedExit, .criticalAPIContractFailure, .backendHealthFailure:
            return automaticRollbackAttempts == 0
                ? .rollbackOnceAndQuarantine
                : .retainForManualRepair

        case .healthy, .ordinaryNetworkOutage:
            let start = healthySince ?? now
            healthySince = start
            let elapsed = max(0, now.timeIntervalSince(start))
            guard elapsed < Self.requiredContinuousRuntime else {
                return .commitKnownGood
            }
            return .continueProbation(
                nextCheckAfter: min(
                    Self.maximumPollInterval,
                    Self.requiredContinuousRuntime - elapsed
                )
            )
        }
    }
}

/// A Core that cannot launch gets one bounded retry while the previous runtime
/// is already quiesced. Two consecutive launch failures inside five minutes
/// trigger the transaction's single automatic rollback. A successful launch
/// resets the sequence.
nonisolated struct CoreCandidateLaunchFailureWindow: Equatable, Sendable {
    static let duration: TimeInterval = 5 * 60

    enum Decision: Equatable, Sendable {
        case retryCandidate
        case rollbackOnceAndQuarantine
    }

    private(set) var firstFailureAt: Date?
    private(set) var consecutiveFailures = 0

    mutating func recordFailure(at date: Date) -> Decision {
        if let firstFailureAt,
            date >= firstFailureAt,
            date.timeIntervalSince(firstFailureAt) <= Self.duration
        {
            consecutiveFailures += 1
        } else {
            firstFailureAt = date
            consecutiveFailures = 1
        }
        return consecutiveFailures >= 2
            ? .rollbackOnceAndQuarantine
            : .retryCandidate
    }

    mutating func recordSuccess() {
        firstFailureAt = nil
        consecutiveFailures = 0
    }
}
