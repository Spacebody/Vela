import Foundation
import Testing
import VelaIPC
@testable import Vela

@Suite("Engine transition coordinator")
struct EngineTransitionCoordinatorTests {
    @Test("A successful transition runs every phase in strict order")
    func successfulPhaseOrder() async throws {
        let recorder = EngineTransitionRecorder()
        let completedAt = Date(timeIntervalSince1970: 1_725_100_000)
        let coordinator = EngineTransitionCoordinator(now: { completedAt })
        let plan = makePlan(recorder: recorder)

        let result = try await coordinator.transition(using: plan)

        #expect(result.source == .userProcess)
        #expect(result.target == .privilegedDaemon)
        #expect(result.completedAt == completedAt)
        #expect(await recorder.entries() == [
            "prepare",
            "disable-system-proxy",
            "stop-source",
            "start-target",
            "verify-target",
            "commit",
        ])
        #expect((await coordinator.snapshot()).state == .idle)
    }

    @Test("A phase fault rolls back once and remains explicitly failed")
    func phaseFaultRollsBack() async throws {
        let recorder = EngineTransitionRecorder()
        let coordinator = EngineTransitionCoordinator()
        let plan = EngineTransitionPlan(
            source: .userProcess,
            target: .privilegedDaemon,
            prepareTarget: { await recorder.record("prepare") },
            disableSystemProxy: { await recorder.record("disable-system-proxy") },
            stopSource: {
                await recorder.record("stop-source")
                throw EngineTransitionTestError.injected
            },
            startTarget: { await recorder.record("start-target") },
            verifyTarget: { await recorder.record("verify-target") },
            commit: { await recorder.record("commit") },
            rollback: { phase in
                await recorder.record("rollback:\(phase.rawValue)")
                return .succeeded
            }
        )

        let failure: EngineTransitionFailure
        do {
            _ = try await coordinator.transition(using: plan)
            Issue.record("Expected the injected phase fault")
            return
        } catch let error as EngineTransitionCoordinatorError {
            guard case let .transitionFailed(value) = error else {
                Issue.record("Unexpected transition error: \(error)")
                return
            }
            failure = value
        }

        #expect(failure.failedPhase == .stoppingSource)
        #expect(failure.rollback == .succeeded)
        #expect(await recorder.entries() == [
            "prepare",
            "disable-system-proxy",
            "stop-source",
            "rollback:stoppingSource",
        ])
        #expect((await coordinator.snapshot()).state == .failed(failure))

        await coordinator.resetFailure()
        #expect((await coordinator.snapshot()).state == .idle)
    }

    @Test("Rollback failure is preserved as a double-fault result")
    func rollbackFailureIsExplicit() async {
        let coordinator = EngineTransitionCoordinator()
        let plan = EngineTransitionPlan(
            source: .privilegedDaemon,
            target: .userProcess,
            prepareTarget: {},
            disableSystemProxy: {},
            stopSource: {},
            startTarget: { throw EngineTransitionTestError.injected },
            verifyTarget: {},
            commit: {},
            rollback: { _ in .failed("source backend could not be restored") }
        )

        do {
            _ = try await coordinator.transition(using: plan)
            Issue.record("Expected transition and rollback failure")
        } catch let error as EngineTransitionCoordinatorError {
            guard case let .transitionFailed(failure) = error else {
                Issue.record("Unexpected transition error: \(error)")
                return
            }
            #expect(failure.failedPhase == .startingTarget)
            #expect(failure.rollback == .failed("source backend could not be restored"))
            #expect((await coordinator.snapshot()).state == .failed(failure))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A second transition cannot re-enter while the first is suspended")
    func transitionsAreSerialized() async throws {
        let coordinator = EngineTransitionCoordinator()
        let gate = EngineTransitionSuspensionGate()
        let recorder = EngineTransitionRecorder()
        let firstPlan = EngineTransitionPlan(
            source: .userProcess,
            target: .privilegedDaemon,
            prepareTarget: {
                await recorder.record("first-prepare-enter")
                await gate.suspend()
                await recorder.record("first-prepare-exit")
            },
            disableSystemProxy: {},
            stopSource: {},
            startTarget: {},
            verifyTarget: {},
            commit: {},
            rollback: { _ in .succeeded }
        )
        let first = Task {
            try await coordinator.transition(using: firstPlan)
        }
        await gate.waitUntilSuspended()

        do {
            _ = try await coordinator.transition(using: makePlan(recorder: recorder))
            Issue.record("Expected transition re-entry to be rejected")
        } catch let error as EngineTransitionCoordinatorError {
            guard case .transitionInProgress = error else {
                Issue.record("Unexpected transition error: \(error)")
                await gate.release()
                _ = try? await first.value
                return
            }
        }

        await gate.release()
        _ = try await first.value
        #expect(Array((await recorder.entries()).prefix(2)) == [
            "first-prepare-enter",
            "first-prepare-exit",
        ])
        #expect((await coordinator.snapshot()).state == .idle)
    }

    @Test("Cancellation rolls back the active phase and never starts the target")
    func cancellationRollsBack() async throws {
        let coordinator = EngineTransitionCoordinator()
        let gate = EngineTransitionSuspensionGate()
        let recorder = EngineTransitionRecorder()
        let plan = EngineTransitionPlan(
            source: .userProcess,
            target: .privilegedDaemon,
            prepareTarget: {
                await recorder.record("prepare")
                await gate.suspend()
            },
            disableSystemProxy: { await recorder.record("disable") },
            stopSource: { await recorder.record("stop") },
            startTarget: { await recorder.record("start") },
            verifyTarget: { await recorder.record("verify") },
            commit: { await recorder.record("commit") },
            rollback: { phase in
                await recorder.record("rollback:\(phase.rawValue)")
                return .succeeded
            }
        )
        let task = Task {
            try await coordinator.transition(using: plan)
        }
        await gate.waitUntilSuspended()
        #expect(await coordinator.cancelCurrentTransition())
        await gate.release()

        do {
            _ = try await task.value
            Issue.record("Expected the cancelled transition to fail after rollback")
        } catch let error as EngineTransitionCoordinatorError {
            guard case let .transitionFailed(failure) = error else {
                Issue.record("Unexpected transition error: \(error)")
                return
            }
            #expect(failure.failedPhase == .preparingTarget)
            #expect(failure.rollback == .succeeded)
            #expect(failure.reason == "The transition was cancelled.")
        }

        #expect(await recorder.entries() == [
            "prepare",
            "rollback:preparingTarget",
        ])
    }

    private func makePlan(
        recorder: EngineTransitionRecorder
    ) -> EngineTransitionPlan {
        EngineTransitionPlan(
            source: .userProcess,
            target: .privilegedDaemon,
            prepareTarget: { await recorder.record("prepare") },
            disableSystemProxy: { await recorder.record("disable-system-proxy") },
            stopSource: { await recorder.record("stop-source") },
            startTarget: { await recorder.record("start-target") },
            verifyTarget: { await recorder.record("verify-target") },
            commit: { await recorder.record("commit") },
            rollback: { phase in
                await recorder.record("rollback:\(phase.rawValue)")
                return .succeeded
            }
        )
    }
}

private enum EngineTransitionTestError: Error {
    case injected
}

private actor EngineTransitionRecorder {
    private var recorded: [String] = []

    func record(_ value: String) {
        recorded.append(value)
    }

    func entries() -> [String] {
        recorded
    }
}

private actor EngineTransitionSuspensionGate {
    private var isSuspended = false
    private var releaseRequested = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var suspensionObservers: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        if releaseRequested {
            releaseRequested = false
            return
        }
        isSuspended = true
        let observers = suspensionObservers
        suspensionObservers.removeAll()
        observers.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        isSuspended = false
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionObservers.append(continuation)
        }
    }

    func release() {
        if let releaseContinuation {
            self.releaseContinuation = nil
            releaseContinuation.resume()
        } else {
            releaseRequested = true
        }
    }
}
