import Foundation
import Testing
@testable import Vela

@Suite("Runtime mutation update barrier")
struct RuntimeMutationGateTests {
    @Test("Update rejects queued and new mutations, then owns the next lease")
    func updateBarrierDrainsCurrentHolderAndRejectsMutations() async throws {
        let gate = RuntimeMutationGate()
        let current = try await gate.acquire(.engineLifecycle)

        let queuedMutation = Task {
            do {
                let lease = try await gate.acquire(.profileMutation)
                await gate.release(lease)
                return Optional<RuntimeMutationGateError>.none
            } catch let error as RuntimeMutationGateError {
                return error
            } catch {
                Issue.record("Queued mutation failed with an unexpected error: \(error)")
                return nil
            }
        }
        // Give the queued mutation ample opportunities to install its
        // continuation behind the current holder before the update latch wins.
        for _ in 0..<100 { await Task.yield() }

        let update = Task {
            try await gate.beginUpdateBarrier(.updatePreparation)
        }
        await waitForUpdateLatch(gate)

        #expect(await queuedMutation.value == .updateInProgress)
        await #expect(throws: RuntimeMutationGateError.updateInProgress) {
            try await gate.acquire(.controllerMutation)
        }

        await gate.release(current)
        let updateLease = try await update.value
        try await gate.validateUpdateLease(updateLease)
        #expect(await gate.isUpdateInProgress())

        try await gate.releaseUpdateBarrier(updateLease)
        #expect(!(await gate.isUpdateInProgress()))

        let resumed = try await gate.acquire(.configurationTransaction)
        await gate.release(resumed)
    }

    @Test("Cancelling a waiting update clears the latch without stealing the holder")
    func cancelledUpdateRestoresNormalAcquisition() async throws {
        let gate = RuntimeMutationGate()
        let current = try await gate.acquire(.engineLifecycle)
        let update = Task {
            try await gate.beginUpdateBarrier(.updateRecovery)
        }
        await waitForUpdateLatch(gate)

        update.cancel()
        await #expect(throws: CancellationError.self) {
            try await update.value
        }
        #expect(!(await gate.isUpdateInProgress()))

        let next = Task {
            try await gate.acquire(.profileMutation)
        }
        await gate.release(current)
        let nextLease = try await next.value
        await gate.release(nextLease)
    }

    @Test("Only the active update holder validates as the update lease")
    func updateLeaseValidationFailsClosed() async throws {
        let gate = RuntimeMutationGate()
        let normal = try await gate.acquire(.engineLifecycle)

        await #expect(throws: RuntimeMutationGateError.invalidUpdateLease) {
            try await gate.validateUpdateLease(normal)
        }
        await #expect(throws: RuntimeMutationGateError.invalidUpdateActivity) {
            try await gate.beginUpdateBarrier(.engineLifecycle)
        }

        await gate.release(normal)
    }

    @Test("An App update is rejected while a Core activation transaction owns the gate")
    func updateDoesNotWaitThroughCoreProbation() async throws {
        let gate = RuntimeMutationGate()
        let activation = try await gate.acquire(.coreActivation)

        await #expect(throws: RuntimeMutationGateError.updateInProgress) {
            try await gate.beginUpdateBarrier(.updatePreparation)
        }
        #expect(!(await gate.isUpdateInProgress()))

        await gate.release(activation)
        let update = try await gate.beginUpdateBarrier(.updatePreparation)
        try await gate.releaseUpdateBarrier(update)
    }

    private func waitForUpdateLatch(_ gate: RuntimeMutationGate) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await gate.isUpdateInProgress() { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("The update barrier did not activate its latch")
    }
}
