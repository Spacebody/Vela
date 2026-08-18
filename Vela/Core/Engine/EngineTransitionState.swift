import Foundation
import VelaIPC

nonisolated enum EngineTransitionPhase: String, Equatable, Sendable {
    case preparingTarget
    case disablingSystemProxy
    case stoppingSource
    case startingTarget
    case verifyingTarget
    case committing
    case rollingBack
}

nonisolated enum EngineRollbackOutcome: Equatable, Sendable {
    case notRequired
    case succeeded
    case failed(String)
}

nonisolated struct EngineTransitionFailure: Equatable, Sendable {
    let transitionID: UUID
    let source: EngineBackendKind
    let target: EngineBackendKind
    let failedPhase: EngineTransitionPhase
    let reason: String
    let rollback: EngineRollbackOutcome
}

nonisolated enum EngineTransitionState: Equatable, Sendable {
    case idle
    case preparingTarget
    case disablingSystemProxy
    case stoppingSource
    case startingTarget
    case verifyingTarget
    case committing
    case rollingBack
    case failed(EngineTransitionFailure)

    var phase: EngineTransitionPhase? {
        switch self {
        case .idle, .failed:
            nil
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
}

nonisolated struct EngineTransitionSnapshot: Equatable, Sendable {
    let transitionID: UUID?
    let source: EngineBackendKind?
    let target: EngineBackendKind?
    let state: EngineTransitionState
}

nonisolated struct EngineTransitionResult: Equatable, Sendable {
    let transitionID: UUID
    let source: EngineBackendKind
    let target: EngineBackendKind
    let completedAt: Date
}

nonisolated enum EngineTransitionCoordinatorError: Error, Equatable, Sendable {
    case sameBackend(EngineBackendKind)
    case transitionInProgress(UUID)
    case transitionFailed(EngineTransitionFailure)
}

extension EngineTransitionCoordinatorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .sameBackend(backend):
            "The engine is already using \(backend.rawValue)."
        case let .transitionInProgress(id):
            "Engine transition \(id) is already in progress."
        case let .transitionFailed(failure):
            "The engine transition failed during \(failure.failedPhase.rawValue): \(failure.reason)"
        }
    }
}
