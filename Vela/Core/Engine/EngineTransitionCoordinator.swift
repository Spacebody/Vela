import Foundation
import VelaIPC

nonisolated struct EngineTransitionPlan: Sendable {
    typealias Step = @Sendable () async throws -> Void
    typealias Rollback = @Sendable (EngineTransitionPhase) async -> EngineRollbackOutcome

    let source: EngineBackendKind
    let target: EngineBackendKind
    let prepareTarget: Step
    let disableSystemProxy: Step
    let stopSource: Step
    let startTarget: Step
    let verifyTarget: Step
    let commit: Step
    let rollback: Rollback

    init(
        source: EngineBackendKind,
        target: EngineBackendKind,
        prepareTarget: @escaping Step,
        disableSystemProxy: @escaping Step,
        stopSource: @escaping Step,
        startTarget: @escaping Step,
        verifyTarget: @escaping Step,
        commit: @escaping Step,
        rollback: @escaping Rollback
    ) {
        self.source = source
        self.target = target
        self.prepareTarget = prepareTarget
        self.disableSystemProxy = disableSystemProxy
        self.stopSource = stopSource
        self.startTarget = startTarget
        self.verifyTarget = verifyTarget
        self.commit = commit
        self.rollback = rollback
    }
}

actor EngineTransitionCoordinator {
    private struct ActiveTransition: Sendable {
        let id: UUID
        let source: EngineBackendKind
        let target: EngineBackendKind
        let task: Task<EngineTransitionResult, Error>
    }

    private let now: @Sendable () -> Date
    private var activeTransition: ActiveTransition?
    private var state: EngineTransitionState = .idle
    private var eventContinuations: [
        UUID: AsyncStream<EngineTransitionSnapshot>.Continuation
    ] = [:]

    init(now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
    }

    func transition(using plan: EngineTransitionPlan) async throws -> EngineTransitionResult {
        guard plan.source != plan.target else {
            throw EngineTransitionCoordinatorError.sameBackend(plan.source)
        }
        if let activeTransition {
            throw EngineTransitionCoordinatorError.transitionInProgress(activeTransition.id)
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.perform(plan, transitionID: id)
        }
        activeTransition = ActiveTransition(
            id: id,
            source: plan.source,
            target: plan.target,
            task: task
        )

        defer {
            if activeTransition?.id == id {
                activeTransition = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    func cancelCurrentTransition() -> Bool {
        guard let activeTransition else { return false }
        activeTransition.task.cancel()
        return true
    }

    /// Cancels the active transition and does not return until its bounded
    /// rollback path has completed. Termination uses this as a barrier before
    /// inspecting privileged state or issuing any cleanup RPC.
    @discardableResult
    func cancelCurrentTransitionAndWait() async -> Bool {
        guard let activeTransition else { return false }
        activeTransition.task.cancel()
        _ = try? await activeTransition.task.value
        return true
    }

    func snapshot() -> EngineTransitionSnapshot {
        if activeTransition == nil,
            case let .failed(failure) = state
        {
            return EngineTransitionSnapshot(
                transitionID: failure.transitionID,
                source: failure.source,
                target: failure.target,
                state: state
            )
        }
        return EngineTransitionSnapshot(
            transitionID: activeTransition?.id,
            source: activeTransition?.source,
            target: activeTransition?.target,
            state: state
        )
    }

    func events() -> AsyncStream<EngineTransitionSnapshot> {
        let id = UUID()
        let initial = snapshot()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            eventContinuations[id] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
        }
    }

    func resetFailure() {
        guard activeTransition == nil else { return }
        if case .failed = state {
            setState(.idle, transitionID: nil, source: nil, target: nil)
        }
    }

    private func perform(
        _ plan: EngineTransitionPlan,
        transitionID: UUID
    ) async throws -> EngineTransitionResult {
        var currentPhase = EngineTransitionPhase.preparingTarget
        do {
            try await run(
                .preparingTarget,
                transitionID: transitionID,
                plan: plan,
                operation: plan.prepareTarget
            )
            currentPhase = .disablingSystemProxy
            try await run(
                .disablingSystemProxy,
                transitionID: transitionID,
                plan: plan,
                operation: plan.disableSystemProxy
            )
            currentPhase = .stoppingSource
            try await run(
                .stoppingSource,
                transitionID: transitionID,
                plan: plan,
                operation: plan.stopSource
            )
            currentPhase = .startingTarget
            try await run(
                .startingTarget,
                transitionID: transitionID,
                plan: plan,
                operation: plan.startTarget
            )
            currentPhase = .verifyingTarget
            try await run(
                .verifyingTarget,
                transitionID: transitionID,
                plan: plan,
                operation: plan.verifyTarget
            )
            currentPhase = .committing
            try await run(
                .committing,
                transitionID: transitionID,
                plan: plan,
                operation: plan.commit
            )

            setState(
                .idle,
                transitionID: transitionID,
                source: plan.source,
                target: plan.target
            )
            return EngineTransitionResult(
                transitionID: transitionID,
                source: plan.source,
                target: plan.target,
                completedAt: now()
            )
        } catch {
            setState(
                .rollingBack,
                transitionID: transitionID,
                source: plan.source,
                target: plan.target
            )
            let rollback = await plan.rollback(currentPhase)
            let reason = error is CancellationError
                ? "The transition was cancelled."
                : error.localizedDescription
            let failure = EngineTransitionFailure(
                transitionID: transitionID,
                source: plan.source,
                target: plan.target,
                failedPhase: currentPhase,
                reason: reason,
                rollback: rollback
            )
            setState(
                .failed(failure),
                transitionID: transitionID,
                source: plan.source,
                target: plan.target
            )
            throw EngineTransitionCoordinatorError.transitionFailed(failure)
        }
    }

    private func run(
        _ phase: EngineTransitionPhase,
        transitionID: UUID,
        plan: EngineTransitionPlan,
        operation: EngineTransitionPlan.Step
    ) async throws {
        try Task.checkCancellation()
        setState(
            state(for: phase),
            transitionID: transitionID,
            source: plan.source,
            target: plan.target
        )
        try await operation()
        try Task.checkCancellation()
    }

    private func state(for phase: EngineTransitionPhase) -> EngineTransitionState {
        switch phase {
        case .preparingTarget:
            .preparingTarget
        case .disablingSystemProxy:
            .disablingSystemProxy
        case .stoppingSource:
            .stoppingSource
        case .startingTarget:
            .startingTarget
        case .verifyingTarget:
            .verifyingTarget
        case .committing:
            .committing
        case .rollingBack:
            .rollingBack
        }
    }

    private func setState(
        _ state: EngineTransitionState,
        transitionID: UUID?,
        source: EngineBackendKind?,
        target: EngineBackendKind?
    ) {
        self.state = state
        let snapshot = EngineTransitionSnapshot(
            transitionID: transitionID,
            source: source,
            target: target,
            state: state
        )
        for continuation in eventContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
