import Foundation
import VelaIPC

nonisolated enum PrivilegedLeaseEvent: Equatable, Sendable {
    case started(sessionID: UUID, instanceID: UUID?)
    case renewed(Date)
    case renewalFailed(VelaHelperErrorCode)
    case suspendedForSleep
    case resumedAfterWake
    case stopped
}
actor PrivilegedLeaseCoordinator {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let client: any PrivilegedHelperClientProtocol
    private let renewalInterval: Duration
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private var renewalTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var instanceID: UUID?
    private var suspendedForSleep = false
    private var eventContinuations: [UUID: AsyncStream<PrivilegedLeaseEvent>.Continuation] = [:]

    init(
        client: any PrivilegedHelperClientProtocol,
        renewalInterval: Duration = .seconds(30),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.client = client
        self.renewalInterval = max(.milliseconds(100), renewalInterval)
        self.sleep = sleep
        self.now = now
    }

    func events() -> AsyncStream<PrivilegedLeaseEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func start(sessionID: UUID, instanceID: UUID?) async {
        await stop(emitEvent: false)
        self.sessionID = sessionID
        self.instanceID = instanceID
        suspendedForSleep = false
        emit(.started(sessionID: sessionID, instanceID: instanceID))
        startRenewalLoop()
    }

    func suspendForSystemSleep() async {
        guard sessionID != nil else { return }
        suspendedForSleep = true
        let task = renewalTask
        renewalTask = nil
        task?.cancel()
        await task?.value
        emit(.suspendedForSleep)
    }

    func resumeAfterSystemWake() async {
        guard let sessionID else { return }
        suspendedForSleep = false
        do {
            try await client.renewLease(
                RenewLeaseRequest(sessionID: sessionID, instanceID: instanceID)
            )
            emit(.resumedAfterWake)
            emit(.renewed(now()))
        } catch {
            emit(.renewalFailed(Self.errorCode(for: error)))
        }
        startRenewalLoop()
    }

    func stop() async {
        await stop(emitEvent: true)
    }

    private func stop(emitEvent shouldEmit: Bool) async {
        let task = renewalTask
        renewalTask = nil
        task?.cancel()
        await task?.value
        sessionID = nil
        instanceID = nil
        suspendedForSleep = false
        if shouldEmit { emit(.stopped) }
    }

    private func startRenewalLoop() {
        guard renewalTask == nil, !suspendedForSleep, sessionID != nil else { return }
        let interval = renewalInterval
        let sleep = self.sleep
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                    try Task.checkCancellation()
                    guard let self else { return }
                    await self.renewOnce()
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    await self.emit(.renewalFailed(Self.errorCode(for: error)))
                }
            }
        }
    }

    private func renewOnce() async {
        guard !suspendedForSleep, let sessionID else { return }
        do {
            try await client.renewLease(
                RenewLeaseRequest(sessionID: sessionID, instanceID: instanceID)
            )
            emit(.renewed(now()))
        } catch {
            emit(.renewalFailed(Self.errorCode(for: error)))
        }
    }

    private func emit(_ event: PrivilegedLeaseEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private nonisolated static func errorCode(for error: Error) -> VelaHelperErrorCode {
        (error as? VelaHelperFailure)?.code ?? .helperUnavailable
    }
}
