import Foundation
import VelaIPC

nonisolated protocol EngineStartMaterial: Sendable {}

nonisolated protocol EnginePreparedStartMaterial: Sendable {}

nonisolated struct EngineControllerAccess: Equatable, Sendable {
    let endpoint: URL
    let secret: SecretValue

    init(endpoint: URL, secret: SecretValue) {
        self.endpoint = endpoint
        self.secret = secret
    }
}

nonisolated struct EngineRuntime: Equatable, Sendable {
    let instanceID: UUID
    let backend: EngineBackendKind
    let controller: EngineControllerAccess
    let processID: Int32?
    let startedAt: Date
    let configurationSHA256: String

    init(
        instanceID: UUID,
        backend: EngineBackendKind,
        controller: EngineControllerAccess,
        processID: Int32?,
        startedAt: Date,
        configurationSHA256: String
    ) {
        self.instanceID = instanceID
        self.backend = backend
        self.controller = controller
        self.processID = processID
        self.startedAt = startedAt
        self.configurationSHA256 = configurationSHA256
    }
}

nonisolated struct EngineStartRequest: Sendable {
    let requestID: UUID
    let backend: EngineBackendKind
    let coreID: CoreID
    let material: any EngineStartMaterial

    init(
        requestID: UUID = UUID(),
        backend: EngineBackendKind,
        coreID: CoreID = .factoryV11928,
        material: any EngineStartMaterial
    ) {
        self.requestID = requestID
        self.backend = backend
        self.coreID = coreID
        self.material = material
    }
}

nonisolated struct EnginePreparedStart: Sendable {
    let id: UUID
    let requestID: UUID
    let backend: EngineBackendKind
    let material: any EnginePreparedStartMaterial

    init(
        id: UUID = UUID(),
        requestID: UUID,
        backend: EngineBackendKind,
        material: any EnginePreparedStartMaterial
    ) {
        self.id = id
        self.requestID = requestID
        self.backend = backend
        self.material = material
    }
}

nonisolated enum EngineStopReason: String, Equatable, Sendable {
    case userRequested
    case backendTransition
    case applicationQuit
    case pause
    case recovery
}

nonisolated struct EngineStopRequest: Equatable, Sendable {
    let requestID: UUID
    let instanceID: UUID?
    let reason: EngineStopReason
    let timeout: Duration

    init(
        requestID: UUID = UUID(),
        instanceID: UUID? = nil,
        reason: EngineStopReason,
        timeout: Duration = .seconds(3)
    ) {
        self.requestID = requestID
        self.instanceID = instanceID
        self.reason = reason
        self.timeout = timeout
    }
}

nonisolated struct EngineStopReport: Equatable, Sendable {
    let backend: EngineBackendKind
    let instanceID: UUID?
    let processID: Int32?
    let wasRunning: Bool
    let stopped: Bool
    let forced: Bool
    let exitCode: Int32?

    init(
        backend: EngineBackendKind,
        instanceID: UUID?,
        processID: Int32?,
        wasRunning: Bool,
        stopped: Bool,
        forced: Bool,
        exitCode: Int32?
    ) {
        self.backend = backend
        self.instanceID = instanceID
        self.processID = processID
        self.wasRunning = wasRunning
        self.stopped = stopped
        self.forced = forced
        self.exitCode = exitCode
    }
}

nonisolated enum EngineBackendLifecycleState: String, Equatable, Sendable {
    case stopped
    case preparing
    case running
    case stopping
    case failed
}

nonisolated struct EngineBackendStatus: Equatable, Sendable {
    let backend: EngineBackendKind
    let lifecycle: EngineBackendLifecycleState
    let runtime: EngineRuntime?
    let processRunning: Bool
    let lastFailure: String?

    init(
        backend: EngineBackendKind,
        lifecycle: EngineBackendLifecycleState,
        runtime: EngineRuntime?,
        processRunning: Bool,
        lastFailure: String? = nil
    ) {
        self.backend = backend
        self.lifecycle = lifecycle
        self.runtime = runtime
        self.processRunning = processRunning
        self.lastFailure = lastFailure
    }
}

nonisolated struct EngineBackendTermination: Equatable, Sendable {
    let backend: EngineBackendKind
    let instanceID: UUID
    let processID: Int32?
    let expected: Bool
    let forced: Bool
    let exitCode: Int32?

    init(
        backend: EngineBackendKind,
        instanceID: UUID,
        processID: Int32?,
        expected: Bool,
        forced: Bool,
        exitCode: Int32?
    ) {
        self.backend = backend
        self.instanceID = instanceID
        self.processID = processID
        self.expected = expected
        self.forced = forced
        self.exitCode = exitCode
    }
}

nonisolated enum EngineBackendEvent: Equatable, Sendable {
    case started(EngineRuntime)
    case output(instanceID: UUID, MihomoProcessOutput)
    case terminated(EngineBackendTermination)
    case statusChanged(EngineBackendStatus)
}

nonisolated enum EngineBackendError: Error, Equatable, Sendable {
    case requestBackendMismatch(expected: EngineBackendKind, actual: EngineBackendKind)
    case unsupportedStartMaterial(backend: EngineBackendKind)
    case candidateBackendMismatch(expected: EngineBackendKind, actual: EngineBackendKind)
    case invalidPreparedCandidate
    case preparationInProgress
    case processDidNotStart
    case processDidNotStop
    case runtimeMismatch(expected: UUID, actual: UUID?)
}

extension EngineBackendError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .requestBackendMismatch(expected, actual):
            "The engine request targets \(actual.rawValue), not \(expected.rawValue)."
        case let .unsupportedStartMaterial(backend):
            "The start request does not contain material supported by \(backend.rawValue)."
        case let .candidateBackendMismatch(expected, actual):
            "The prepared candidate belongs to \(actual.rawValue), not \(expected.rawValue)."
        case .invalidPreparedCandidate:
            "The prepared engine candidate is no longer valid."
        case .preparationInProgress:
            "Another engine start candidate is already being prepared."
        case .processDidNotStart:
            "The engine backend did not report a running process."
        case .processDidNotStop:
            "The engine backend still reports a running process after Stop."
        case let .runtimeMismatch(expected, actual):
            "The stop request targets runtime \(expected), but the active runtime is \(actual?.uuidString ?? "none")."
        }
    }
}

nonisolated protocol EngineBackend: Actor {
    nonisolated var kind: EngineBackendKind { get }

    func start(_ request: EngineStartRequest) async throws -> EngineRuntime
    func prepareStart(_ request: EngineStartRequest) async throws -> EnginePreparedStart
    func commitStart(_ candidate: EnginePreparedStart) async throws -> EngineRuntime
    func abortStart(_ candidate: EnginePreparedStart) async
    func stop(_ request: EngineStopRequest) async throws -> EngineStopReport
    func status() async throws -> EngineBackendStatus
    func events() -> AsyncStream<EngineBackendEvent>
}

extension EngineBackend {
    func start(_ request: EngineStartRequest) async throws -> EngineRuntime {
        let candidate = try await prepareStart(request)
        do {
            return try await commitStart(candidate)
        } catch {
            await abortStart(candidate)
            throw error
        }
    }
}
