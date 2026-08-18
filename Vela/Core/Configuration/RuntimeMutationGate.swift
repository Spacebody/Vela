import Foundation

nonisolated enum RuntimeMutationActivity: String, Sendable {
    case configurationTransaction
    case engineLifecycle
    case profileMutation
    case runtimeValidation
    case controllerMutation
    case coreActivation
    case sceneActivation
    case updatePreparation
    case updateRecovery

    var isUpdateBarrier: Bool {
        switch self {
        case .updatePreparation, .updateRecovery:
            true
        case .configurationTransaction, .engineLifecycle, .profileMutation,
            .runtimeValidation, .controllerMutation, .coreActivation,
            .sceneActivation:
            false
        }
    }
}

nonisolated enum RuntimeMutationGateError: Error, Equatable, Sendable {
    /// A secure update owns, or is waiting to own, the global mutation barrier.
    /// Keep this case stable because UI, CLI, and App Intent adapters map it to
    /// the public `updateInProgress` error code.
    case updateInProgress
    case invalidUpdateActivity
    case invalidUpdateLease
}

nonisolated struct RuntimeMutationLease: Equatable, Sendable {
    fileprivate let id: UUID
    let activity: RuntimeMutationActivity
}

/// Serializes operations that can change the selected profile, the active
/// runtime configuration, or the Mihomo process state.
///
/// The gate is deliberately independent from `EngineStore` and the runtime
/// transaction coordinator so neither side needs to call into the other while
/// holding a lease. That keeps the dependency graph acyclic and makes a lease
/// safe to hold across suspending validation and Controller calls.
actor RuntimeMutationGate {
    private struct Waiter {
        let lease: RuntimeMutationLease
        let continuation: CheckedContinuation<RuntimeMutationLease, any Error>
    }

    private var holder: RuntimeMutationLease?
    private var waiters: [Waiter] = []
    /// Set as soon as an update requests the barrier, before the current holder
    /// drains. This closes the race where another state mutation could queue
    /// behind the current operation and overtake update preparation.
    private var updateBarrier: RuntimeMutationLease?

    func acquire(_ activity: RuntimeMutationActivity) async throws -> RuntimeMutationLease {
        if activity.isUpdateBarrier {
            return try await beginUpdateBarrier(activity)
        }

        try Task.checkCancellation()
        guard updateBarrier == nil else {
            throw RuntimeMutationGateError.updateInProgress
        }
        let lease = RuntimeMutationLease(id: UUID(), activity: activity)

        let acquired: RuntimeMutationLease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RuntimeMutationLease, any Error>) in
                // The actor can be re-entered between the initial check and
                // continuation installation. Re-check the latch so a mutation
                // never queues after update preparation has begun.
                if updateBarrier != nil {
                    continuation.resume(
                        throwing: RuntimeMutationGateError.updateInProgress
                    )
                } else if holder == nil {
                    holder = lease
                    continuation.resume(returning: lease)
                } else {
                    waiters.append(Waiter(lease: lease, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(lease.id) }
        }

        do {
            try Task.checkCancellation()
            return acquired
        } catch {
            if holder?.id == acquired.id {
                release(acquired)
            }
            throw error
        }
    }

    /// Activates the update latch immediately, rejects every queued non-update
    /// waiter, then drains the current holder before granting the exclusive
    /// update lease. Only one update preparation or recovery barrier may exist.
    func beginUpdateBarrier(
        _ activity: RuntimeMutationActivity
    ) async throws -> RuntimeMutationLease {
        guard activity.isUpdateBarrier else {
            throw RuntimeMutationGateError.invalidUpdateActivity
        }
        try Task.checkCancellation()
        guard updateBarrier == nil else {
            throw RuntimeMutationGateError.updateInProgress
        }
        // A Core activation owns a durable transaction through probation. An
        // App update must be retried after that transaction commits or rolls
        // back; waiting here could otherwise leave update preparation hanging
        // for the full probation window.
        guard holder?.activity != .coreActivation else {
            throw RuntimeMutationGateError.updateInProgress
        }

        let lease = RuntimeMutationLease(id: UUID(), activity: activity)
        updateBarrier = lease
        rejectQueuedMutationsForUpdate()

        let acquired: RuntimeMutationLease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RuntimeMutationLease, any Error>) in
                if holder == nil {
                    holder = lease
                    continuation.resume(returning: lease)
                } else {
                    // The update must be the very next holder after the current
                    // operation completes. All earlier queued mutations were
                    // rejected above and later mutations fail at the latch.
                    waiters.insert(
                        Waiter(lease: lease, continuation: continuation),
                        at: 0
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(lease.id) }
        }

        do {
            try Task.checkCancellation()
            return acquired
        } catch {
            if holder?.id == acquired.id {
                release(acquired)
            }
            throw error
        }
    }

    func validateUpdateLease(_ lease: RuntimeMutationLease) throws {
        guard lease.activity.isUpdateBarrier,
            updateBarrier?.id == lease.id,
            holder?.id == lease.id
        else {
            throw RuntimeMutationGateError.invalidUpdateLease
        }
    }

    func releaseUpdateBarrier(_ lease: RuntimeMutationLease) throws {
        try validateUpdateLease(lease)
        release(lease)
    }

    func isUpdateInProgress() -> Bool {
        updateBarrier != nil
    }

    func release(_ lease: RuntimeMutationLease) {
        guard holder?.id == lease.id else { return }
        holder = nil
        if updateBarrier?.id == lease.id {
            updateBarrier = nil
        }
        resumeNextWaiterIfPossible()
    }

    private func resumeNextWaiterIfPossible() {
        guard holder == nil, !waiters.isEmpty else { return }

        let next = waiters.removeFirst()
        holder = next.lease
        next.continuation.resume(returning: next.lease)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.lease.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        if updateBarrier?.id == waiter.lease.id {
            updateBarrier = nil
        }
        waiter.continuation.resume(throwing: CancellationError())
        resumeNextWaiterIfPossible()
    }

    private func rejectQueuedMutationsForUpdate() {
        let rejected = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in rejected {
            waiter.continuation.resume(
                throwing: RuntimeMutationGateError.updateInProgress
            )
        }
    }
}
