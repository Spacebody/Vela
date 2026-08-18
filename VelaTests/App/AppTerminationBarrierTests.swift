import Foundation
import Testing
@testable import Vela

@MainActor
@Suite("Application termination barriers")
struct AppTerminationBarrierTests {
    @Test("Cleanup completes before its deadline")
    func cleanupOperationWins() async {
        let probe = TerminationOperationProbe()

        let completed = await AppTerminationCleanupBarrier.wait(timeout: .seconds(1)) {
            await probe.run()
        }

        #expect(completed)
        #expect(await probe.snapshot() == .init(starts: 1, completions: 1))
    }

    @Test("Cleanup timeout wins once and ignores a late operation result")
    func cleanupTimeoutWinsOnce() async {
        let probe = TerminationOperationProbe(startsSuspended: true)

        async let completed = AppTerminationCleanupBarrier.wait(
            timeout: .milliseconds(100)
        ) {
            await probe.run()
        }
        await probe.waitUntilStarted()

        #expect(await completed == false)
        await probe.release()
        await probe.waitUntilCompleted()
        #expect(await probe.snapshot() == .init(starts: 1, completions: 1))
    }

    @Test("Preparation preserves the operation safety result", arguments: [true, false])
    func preparationOperationWins(safeToTerminate: Bool) async {
        let result = await AppTerminationPreparationBarrier.wait(timeout: .seconds(1)) {
            safeToTerminate
        }

        #expect(result == .completed(safeToTerminate: safeToTerminate))
    }

    @Test("Preparation timeout wins once and ignores a late operation result")
    func preparationTimeoutWinsOnce() async {
        let probe = TerminationOperationProbe(startsSuspended: true)

        async let result = AppTerminationPreparationBarrier.wait(
            timeout: .milliseconds(100)
        ) {
            await probe.run()
            return true
        }
        await probe.waitUntilStarted()

        #expect(await result == .timedOut)
        await probe.release()
        await probe.waitUntilCompleted()
        #expect(await probe.snapshot() == .init(starts: 1, completions: 1))
    }

    @Test("Termination resolution always replies and yields unsafe privileged cleanup")
    func terminationResolutionContract() {
        #expect(
            AppTerminationResolution.resolve(
                preparation: .completed(safeToTerminate: true),
                privilegedRuntimeMayBeActive: true
            ) == .init(
                shouldTerminate: true,
                shouldYieldPrivilegedRuntimeToLeaseCleanup: false
            )
        )
        #expect(
            AppTerminationResolution.resolve(
                preparation: .completed(safeToTerminate: false),
                privilegedRuntimeMayBeActive: true
            ) == .init(
                shouldTerminate: true,
                shouldYieldPrivilegedRuntimeToLeaseCleanup: true
            )
        )
        #expect(
            AppTerminationResolution.resolve(
                preparation: .timedOut,
                privilegedRuntimeMayBeActive: true
            ) == .init(
                shouldTerminate: true,
                shouldYieldPrivilegedRuntimeToLeaseCleanup: true
            )
        )
        #expect(
            AppTerminationResolution.resolve(
                preparation: .timedOut,
                privilegedRuntimeMayBeActive: false
            ) == .init(
                shouldTerminate: true,
                shouldYieldPrivilegedRuntimeToLeaseCleanup: false
            )
        )
    }
}

private actor TerminationOperationProbe {
    struct Snapshot: Equatable {
        let starts: Int
        let completions: Int
    }

    private let startsSuspended: Bool
    private var starts = 0
    private var completions = 0
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var completionContinuations: [CheckedContinuation<Void, Never>] = []

    init(startsSuspended: Bool = false) {
        self.startsSuspended = startsSuspended
    }

    func run() async {
        starts += 1
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()

        if startsSuspended {
            await withCheckedContinuation { continuation in
                operationContinuation = continuation
            }
        }

        completions += 1
        completionContinuations.forEach { $0.resume() }
        completionContinuations.removeAll()
    }

    func waitUntilStarted() async {
        guard starts == 0 else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        operationContinuation?.resume()
        operationContinuation = nil
    }

    func waitUntilCompleted() async {
        guard completions == 0 else { return }
        await withCheckedContinuation { continuation in
            completionContinuations.append(continuation)
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(starts: starts, completions: completions)
    }
}
