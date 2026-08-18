import Foundation
import Observation

nonisolated struct SceneRuntimeTransitionToken: Equatable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

nonisolated enum SceneTransitionPhase: String, Equatable, Sendable {
    case idle
    case preparing
    case applying
    case verifying
    case committing
    case rollingBack
    case completed
    case failed
    case manualRepairRequired
}

nonisolated enum SceneActivationOutcome: Equatable, Sendable {
    case activated(sceneID: UUID)
    case rejected(sceneID: UUID, reason: String)
    case rolledBack(sceneID: UUID, reason: String)
    case manualRepairRequired(sceneID: UUID, originalReason: String, rollbackReason: String)

    var succeeded: Bool {
        if case .activated = self { return true }
        return false
    }
}

/// A runtime implementation owns the global mutation lease from `prepare`
/// through `commit` or `rollback`. Splitting the phases keeps orchestration
/// testable while guaranteeing that no profile, backend, update, or Controller
/// mutation can interleave with a Scene activation.
@MainActor
protocol SceneRuntimeTransitioning: AnyObject {
    func prepareSceneTransition(
        _ scene: VelaScene,
        activeSceneID: UUID?
    ) async throws -> SceneRuntimeTransitionToken
    func applySceneTransition(
        _ scene: VelaScene,
        token: SceneRuntimeTransitionToken
    ) async throws
    func verifySceneTransition(
        _ scene: VelaScene,
        token: SceneRuntimeTransitionToken
    ) async throws
    func commitSceneTransition(
        _ scene: VelaScene,
        token: SceneRuntimeTransitionToken
    ) async throws
    func rollbackSceneTransition(
        token: SceneRuntimeTransitionToken
    ) async throws
}

@MainActor
@Observable
final class SceneTransitionCoordinator {
    private(set) var phase: SceneTransitionPhase = .idle
    private(set) var activeSceneID: UUID?
    private(set) var lastOutcome: SceneActivationOutcome?

    @ObservationIgnored private let runtime: any SceneRuntimeTransitioning

    init(runtime: any SceneRuntimeTransitioning) {
        self.runtime = runtime
    }

    func activate(
        _ scene: VelaScene,
        replacing activeSceneID: UUID?
    ) async -> SceneActivationOutcome {
        guard phase == .idle || phase == .completed || phase == .failed else {
            let outcome = SceneActivationOutcome.rejected(
                sceneID: scene.id,
                reason: "Another Scene transition is already in progress."
            )
            lastOutcome = outcome
            return outcome
        }

        self.activeSceneID = scene.id
        phase = .preparing
        let token: SceneRuntimeTransitionToken
        do {
            token = try await runtime.prepareSceneTransition(
                scene,
                activeSceneID: activeSceneID
            )
        } catch {
            return finish(
                .rejected(sceneID: scene.id, reason: redactedReason(error)),
                phase: .failed
            )
        }

        do {
            phase = .applying
            try await runtime.applySceneTransition(scene, token: token)
            phase = .verifying
            try await runtime.verifySceneTransition(scene, token: token)
            phase = .committing
            try await runtime.commitSceneTransition(scene, token: token)
            return finish(.activated(sceneID: scene.id), phase: .completed)
        } catch {
            let originalReason = redactedReason(error)
            phase = .rollingBack
            do {
                try await runtime.rollbackSceneTransition(token: token)
                return finish(
                    .rolledBack(sceneID: scene.id, reason: originalReason),
                    phase: .failed
                )
            } catch {
                return finish(
                    .manualRepairRequired(
                        sceneID: scene.id,
                        originalReason: originalReason,
                        rollbackReason: redactedReason(error)
                    ),
                    phase: .manualRepairRequired
                )
            }
        }
    }

    func resetPresentation() {
        guard phase != .preparing,
            phase != .applying,
            phase != .verifying,
            phase != .committing,
            phase != .rollingBack
        else { return }
        phase = .idle
        activeSceneID = nil
    }

    private func finish(
        _ outcome: SceneActivationOutcome,
        phase: SceneTransitionPhase
    ) -> SceneActivationOutcome {
        self.phase = phase
        activeSceneID = nil
        lastOutcome = outcome
        return outcome
    }

    private func redactedReason(_ error: any Error) -> String {
        DiagnosticTextSanitizer.redact(error.localizedDescription)
    }
}
