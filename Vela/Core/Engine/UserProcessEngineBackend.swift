import Foundation
import VelaIPC

nonisolated struct UserProcessEngineStartMaterial: EngineStartMaterial, Equatable, Sendable {
    let preparedLaunch: MihomoPreparedLaunch
    let controller: EngineControllerAccess
    let configurationSHA256: String

    init(
        preparedLaunch: MihomoPreparedLaunch,
        controller: EngineControllerAccess,
        configurationSHA256: String
    ) {
        self.preparedLaunch = preparedLaunch
        self.controller = controller
        self.configurationSHA256 = configurationSHA256
    }
}

nonisolated private struct PreparedUserProcessStart: EnginePreparedStartMaterial, Sendable {
    let input: UserProcessEngineStartMaterial
}

actor UserProcessEngineBackend: EngineBackend {
    nonisolated let kind: EngineBackendKind = .userProcess

    private let processManager: any MihomoProcessManaging
    private let now: @Sendable () -> Date

    private var preparedCandidate: EnginePreparedStart?
    private var activeRuntime: EngineRuntime?
    private var stopRequestedRuntimeID: UUID?
    private var lifecycle: EngineBackendLifecycleState = .stopped
    private var lastFailure: String?
    private var processEventTask: Task<Void, Never>?
    private var eventContinuations: [
        UUID: AsyncStream<EngineBackendEvent>.Continuation
    ] = [:]

    init(
        processManager: any MihomoProcessManaging,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.processManager = processManager
        self.now = now
    }

    func prepareStart(_ request: EngineStartRequest) async throws -> EnginePreparedStart {
        guard request.backend == kind else {
            throw EngineBackendError.requestBackendMismatch(
                expected: kind,
                actual: request.backend
            )
        }
        guard preparedCandidate == nil else {
            throw EngineBackendError.preparationInProgress
        }
        guard let material = request.material as? UserProcessEngineStartMaterial else {
            throw EngineBackendError.unsupportedStartMaterial(backend: kind)
        }
        guard material.preparedLaunch.validationResult.isValid else {
            throw MihomoProcessManagerError.configurationInvalid(
                material.preparedLaunch.validationResult
            )
        }

        await beginObservingProcessEventsIfNeeded()
        lifecycle = .preparing
        lastFailure = nil
        let candidate = EnginePreparedStart(
            requestID: request.requestID,
            backend: kind,
            material: PreparedUserProcessStart(input: material)
        )
        preparedCandidate = candidate
        emitStatusChanged(processRunning: activeRuntime != nil)
        return candidate
    }

    func commitStart(_ candidate: EnginePreparedStart) async throws -> EngineRuntime {
        guard candidate.backend == kind else {
            throw EngineBackendError.candidateBackendMismatch(
                expected: kind,
                actual: candidate.backend
            )
        }
        guard preparedCandidate?.id == candidate.id,
            let material = candidate.material as? PreparedUserProcessStart
        else {
            throw EngineBackendError.invalidPreparedCandidate
        }

        do {
            let snapshot = try await processManager.start(
                preparedLaunch: material.input.preparedLaunch
            )
            guard snapshot.isRunning else {
                throw EngineBackendError.processDidNotStart
            }

            if let activeRuntime,
                activeRuntime.processID == snapshot.pid
            {
                preparedCandidate = nil
                lifecycle = .running
                emitStatusChanged(processRunning: true)
                return activeRuntime
            }

            let runtime = EngineRuntime(
                instanceID: candidate.id,
                backend: kind,
                controller: material.input.controller,
                processID: snapshot.pid,
                startedAt: snapshot.startedAt ?? now(),
                configurationSHA256: material.input.configurationSHA256
            )
            preparedCandidate = nil
            activeRuntime = runtime
            lifecycle = .running
            lastFailure = nil
            emit(.started(runtime))
            emitStatusChanged(processRunning: true)
            return runtime
        } catch {
            lifecycle = activeRuntime == nil ? .failed : .running
            lastFailure = error.localizedDescription
            emitStatusChanged(processRunning: activeRuntime != nil)
            throw error
        }
    }

    func abortStart(_ candidate: EnginePreparedStart) async {
        guard preparedCandidate?.id == candidate.id else { return }
        preparedCandidate = nil
        lifecycle = activeRuntime == nil ? .stopped : .running
        emitStatusChanged(processRunning: activeRuntime != nil)
    }

    func stop(_ request: EngineStopRequest) async throws -> EngineStopReport {
        if let requestedInstanceID = request.instanceID,
            requestedInstanceID != activeRuntime?.instanceID
        {
            throw EngineBackendError.runtimeMismatch(
                expected: requestedInstanceID,
                actual: activeRuntime?.instanceID
            )
        }

        preparedCandidate = nil
        let runtime = activeRuntime
        stopRequestedRuntimeID = runtime?.instanceID
        lifecycle = .stopping
        emitStatusChanged(processRunning: runtime != nil)

        do {
            let termination = try await processManager.stop(timeout: request.timeout)
            let stillRunning = await processManager.isRunning()
            guard !stillRunning else {
                throw EngineBackendError.processDidNotStop
            }

            activeRuntime = nil
            stopRequestedRuntimeID = nil
            lifecycle = .stopped
            lastFailure = nil
            let report = EngineStopReport(
                backend: kind,
                instanceID: runtime?.instanceID,
                processID: termination?.pid ?? runtime?.processID,
                wasRunning: runtime != nil || termination != nil,
                stopped: true,
                forced: termination?.forced ?? false,
                exitCode: termination?.status
            )
            if let runtime {
                emit(.terminated(EngineBackendTermination(
                    backend: kind,
                    instanceID: runtime.instanceID,
                    processID: report.processID,
                    expected: true,
                    forced: report.forced,
                    exitCode: report.exitCode
                )))
            }
            emitStatusChanged(processRunning: false)
            return report
        } catch {
            let stillRunning = await processManager.isRunning()
            stopRequestedRuntimeID = nil
            lifecycle = stillRunning ? .running : .failed
            if !stillRunning {
                activeRuntime = nil
            }
            lastFailure = error.localizedDescription
            emitStatusChanged(processRunning: stillRunning)
            throw error
        }
    }

    func status() async throws -> EngineBackendStatus {
        let processRunning = await processManager.isRunning()
        if !processRunning, activeRuntime != nil, lifecycle != .stopping {
            activeRuntime = nil
            lifecycle = .failed
            lastFailure = "The user-process runtime is no longer running."
        } else if processRunning, activeRuntime != nil, lifecycle != .preparing {
            lifecycle = .running
        } else if !processRunning, activeRuntime == nil,
            lifecycle != .preparing, lifecycle != .failed
        {
            lifecycle = .stopped
        }
        return makeStatus(processRunning: processRunning)
    }

    func events() -> AsyncStream<EngineBackendEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1_024)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
        }
    }

    private func beginObservingProcessEventsIfNeeded() async {
        guard processEventTask == nil else { return }
        let stream = await processManager.events()
        processEventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.consumeProcessEvent(event)
            }
        }
    }

    private func consumeProcessEvent(_ event: MihomoProcessEvent) {
        switch event {
        case .started:
            // commitStart owns the runtime identity and emits the public start event.
            break
        case let .output(output):
            guard let activeRuntime else { return }
            emit(.output(instanceID: activeRuntime.instanceID, output))
        case let .terminated(termination):
            guard let activeRuntime,
                activeRuntime.processID == termination.pid
            else {
                return
            }
            if termination.expected,
                stopRequestedRuntimeID == activeRuntime.instanceID
            {
                // stop(_:) owns the final report and event for an explicit stop.
                return
            }
            self.activeRuntime = nil
            preparedCandidate = nil
            lifecycle = termination.expected ? .stopped : .failed
            lastFailure = termination.expected
                ? nil
                : "The user-process runtime exited unexpectedly with status \(termination.status)."
            emit(.terminated(EngineBackendTermination(
                backend: kind,
                instanceID: activeRuntime.instanceID,
                processID: termination.pid,
                expected: termination.expected,
                forced: termination.forced,
                exitCode: termination.status
            )))
            emitStatusChanged(processRunning: false)
        }
    }

    private func makeStatus(processRunning: Bool) -> EngineBackendStatus {
        EngineBackendStatus(
            backend: kind,
            lifecycle: lifecycle,
            runtime: activeRuntime,
            processRunning: processRunning,
            lastFailure: lastFailure
        )
    }

    private func emitStatusChanged(processRunning: Bool) {
        emit(.statusChanged(makeStatus(processRunning: processRunning)))
    }

    private func emit(_ event: EngineBackendEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
