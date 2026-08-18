import CryptoKit
import Darwin
import Foundation
import VelaIPC

nonisolated struct PrivilegedResourceInput: Equatable, Sendable {
    let descriptor: PrivilegedResourceDescriptor
    let sourceURL: URL
}

nonisolated struct PrivilegedEngineStartMaterial: EngineStartMaterial, Equatable, Sendable {
    let sessionID: UUID
    let configuration: Data
    let configurationSHA256: String
    let resources: [PrivilegedResourceInput]
    let tunSettings: TunSettings

    init(
        sessionID: UUID,
        configuration: Data,
        configurationSHA256: String,
        resources: [PrivilegedResourceInput],
        tunSettings: TunSettings
    ) {
        self.sessionID = sessionID
        self.configuration = configuration
        self.configurationSHA256 = configurationSHA256
        self.resources = resources
        self.tunSettings = tunSettings
    }
}

nonisolated private struct PreparedPrivilegedStart: EnginePreparedStartMaterial, Sendable {
    let sessionID: UUID
    let transactionID: UUID
    let configurationSHA256: String
}

actor PrivilegedMihomoBackend: EngineBackend {
    nonisolated let kind: EngineBackendKind = .privilegedDaemon

    private let client: any PrivilegedHelperClientProtocol
    private var preparedCandidate: EnginePreparedStart?
    private var activeRuntime: EngineRuntime?
    private var activeSessionID: UUID?
    private var lifecycle: EngineBackendLifecycleState = .stopped
    private var lastFailure: String?
    private var eventContinuations: [UUID: AsyncStream<EngineBackendEvent>.Continuation] = [:]

    init(client: any PrivilegedHelperClientProtocol) {
        self.client = client
    }

    func prepareStart(_ request: EngineStartRequest) async throws -> EnginePreparedStart {
        guard request.backend == kind else {
            throw EngineBackendError.requestBackendMismatch(expected: kind, actual: request.backend)
        }
        guard preparedCandidate == nil else {
            throw EngineBackendError.preparationInProgress
        }
        guard let material = request.material as? PrivilegedEngineStartMaterial else {
            throw EngineBackendError.unsupportedStartMaterial(backend: kind)
        }
        guard material.configuration.count <= VelaIPCConstants.maximumConfigurationBytes,
            material.resources.count <= VelaIPCConstants.maximumResourceCount
        else {
            throw VelaHelperFailure(
                code: .resourceLimitExceeded,
                requestID: request.requestID,
                safeMessage: "The privileged runtime package exceeds its limits."
            )
        }
        let totalResourceBytes = try material.resources.reduce(0) { partial, resource in
            guard resource.descriptor.expectedSize >= 0 else {
                throw VelaHelperFailure(
                    code: .resourceLimitExceeded,
                    requestID: request.requestID,
                    safeMessage: "The privileged runtime package contains an invalid resource size."
                )
            }
            let (sum, overflow) = partial.addingReportingOverflow(resource.descriptor.expectedSize)
            guard !overflow else {
                throw VelaHelperFailure(
                    code: .resourceLimitExceeded,
                    requestID: request.requestID,
                    safeMessage: "The privileged runtime package exceeds its limits."
                )
            }
            return sum
        }
        guard totalResourceBytes <= VelaIPCConstants.maximumResourceTotalBytes else {
            throw VelaHelperFailure(
                code: .resourceLimitExceeded,
                requestID: request.requestID,
                safeMessage: "The privileged resources exceed their total size limit."
            )
        }
        guard Self.sha256(material.configuration) == material.configurationSHA256.lowercased() else {
            throw VelaHelperFailure(
                code: .resourceIntegrityMismatch,
                requestID: request.requestID,
                safeMessage: "The privileged configuration integrity check failed."
            )
        }
        let validatedTunSettings = try material.tunSettings.validated()

        lifecycle = .preparing
        lastFailure = nil
        emitStatusChanged(processRunning: activeRuntime != nil)
        var remoteTransactionID: UUID?
        do {
            let response = try await client.prepareStart(
                PrepareStartRequest(
                    requestID: request.requestID,
                    sessionID: material.sessionID,
                    configurationSize: material.configuration.count,
                    configurationSHA256: material.configurationSHA256,
                    resources: material.resources.map(\.descriptor),
                    tunSettings: validatedTunSettings,
                    coreID: request.coreID
                )
            )
            remoteTransactionID = response.transactionID
            try await client.stageConfiguration(
                StageConfigurationRequest(
                    sessionID: material.sessionID,
                    transactionID: response.transactionID,
                    expectedSize: material.configuration.count,
                    expectedSHA256: material.configurationSHA256
                ),
                data: material.configuration
            )
            for resource in material.resources {
                try Task.checkCancellation()
                try await stage(
                    resource,
                    sessionID: material.sessionID,
                    transactionID: response.transactionID
                )
            }

            let candidate = EnginePreparedStart(
                requestID: request.requestID,
                backend: kind,
                material: PreparedPrivilegedStart(
                    sessionID: material.sessionID,
                    transactionID: response.transactionID,
                    configurationSHA256: material.configurationSHA256
                )
            )
            preparedCandidate = candidate
            return candidate
        } catch {
            // Once prepareStart succeeds, any later staging/open/cancellation
            // failure must not leave the Helper's single transaction occupied.
            // This is best-effort because an indeterminate XPC timeout may have
            // already invalidated the owning connection; the Helper lease path
            // remains the final bounded cleanup authority in that case.
            if let remoteTransactionID {
                let cleanup = Task { [client] in
                    try? await client.abortStart(
                        AbortStartRequest(
                            requestID: request.requestID,
                            sessionID: material.sessionID,
                            transactionID: remoteTransactionID
                        )
                    )
                }
                await cleanup.value
            }
            lifecycle = activeRuntime == nil ? .failed : .running
            lastFailure = Self.safeFailureDescription(error)
            emitStatusChanged(processRunning: activeRuntime != nil)
            throw error
        }
    }

    func commitStart(_ candidate: EnginePreparedStart) async throws -> EngineRuntime {
        guard candidate.backend == kind else {
            throw EngineBackendError.candidateBackendMismatch(expected: kind, actual: candidate.backend)
        }
        guard preparedCandidate?.id == candidate.id,
            let material = candidate.material as? PreparedPrivilegedStart
        else {
            throw EngineBackendError.invalidPreparedCandidate
        }

        do {
            let response = try await client.commitStart(
                CommitStartRequest(
                    requestID: candidate.requestID,
                    sessionID: material.sessionID,
                    transactionID: material.transactionID
                )
            )
            guard response.configurationSHA256 == material.configurationSHA256,
                response.controllerHost == "127.0.0.1",
                response.controllerPort >= 1_024,
                !response.controllerSecret.isEmpty,
                let endpoint = URL(
                    string: "http://127.0.0.1:\(response.controllerPort)"
                )
            else {
                throw VelaHelperFailure(
                    code: .unsafeConfiguration,
                    requestID: candidate.requestID,
                    safeMessage: "The privileged runtime returned an unsafe Controller binding."
                )
            }

            let runtime = EngineRuntime(
                instanceID: response.instanceID,
                backend: kind,
                controller: EngineControllerAccess(
                    endpoint: endpoint,
                    secret: SecretValue(response.controllerSecret)
                ),
                processID: response.processID,
                startedAt: response.startedAt,
                configurationSHA256: response.configurationSHA256
            )
            preparedCandidate = nil
            activeRuntime = runtime
            activeSessionID = material.sessionID
            lifecycle = .running
            lastFailure = nil
            emit(.started(runtime))
            emitStatusChanged(processRunning: true)
            return runtime
        } catch {
            lifecycle = activeRuntime == nil ? .failed : .running
            lastFailure = Self.safeFailureDescription(error)
            emitStatusChanged(processRunning: activeRuntime != nil)
            throw error
        }
    }

    func abortStart(_ candidate: EnginePreparedStart) async {
        guard preparedCandidate?.id == candidate.id,
            let material = candidate.material as? PreparedPrivilegedStart
        else { return }
        do {
            try await client.abortStart(
                AbortStartRequest(
                    requestID: candidate.requestID,
                    sessionID: material.sessionID,
                    transactionID: material.transactionID
                )
            )
        } catch {
            lastFailure = Self.safeFailureDescription(error)
        }
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
        guard let runtime = activeRuntime else {
            return EngineStopReport(
                backend: kind,
                instanceID: nil,
                processID: nil,
                wasRunning: false,
                stopped: true,
                forced: false,
                exitCode: nil
            )
        }
        guard let sessionID = activeSessionID else {
            throw VelaHelperFailure(
                code: .invalidSession,
                requestID: request.requestID,
                safeMessage: "The privileged helper session is unavailable."
            )
        }

        lifecycle = .stopping
        emitStatusChanged(processRunning: true)
        do {
            try await client.stop(
                StopHelperRequest(
                    requestID: request.requestID,
                    sessionID: sessionID,
                    instanceID: runtime.instanceID,
                    reason: Self.helperReason(request.reason)
                )
            )
            activeRuntime = nil
            activeSessionID = nil
            lifecycle = .stopped
            lastFailure = nil
            let report = EngineStopReport(
                backend: kind,
                instanceID: runtime.instanceID,
                processID: runtime.processID,
                wasRunning: true,
                stopped: true,
                forced: false,
                exitCode: nil
            )
            emit(.terminated(EngineBackendTermination(
                backend: kind,
                instanceID: runtime.instanceID,
                processID: runtime.processID,
                expected: true,
                forced: false,
                exitCode: nil
            )))
            emitStatusChanged(processRunning: false)
            return report
        } catch {
            lifecycle = .failed
            lastFailure = Self.safeFailureDescription(error)
            emitStatusChanged(processRunning: true)
            throw error
        }
    }

    func status() async throws -> EngineBackendStatus {
        let response = try await client.status()
        let processRunning = response.health.processRunning
        if !processRunning {
            activeRuntime = nil
            activeSessionID = nil
        }
        lifecycle = switch response.state {
        case .stopped: .stopped
        case .preparing: .preparing
        case .running: .running
        case .stopping: .stopping
        case .degraded, .manualRepairRequired: .failed
        }
        return makeStatus(processRunning: processRunning)
    }

    func events() -> AsyncStream<EngineBackendEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1_024)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func stage(
        _ resource: PrivilegedResourceInput,
        sessionID: UUID,
        transactionID: UUID
    ) async throws {
        let file = try Self.openStableRegularFile(
            resource.sourceURL,
            expectedSize: resource.descriptor.expectedSize
        )
        defer { try? file.close() }
        try await client.stageResource(
            StageResourceRequest(
                sessionID: sessionID,
                transactionID: transactionID,
                logicalID: resource.descriptor.logicalID,
                relativeDestination: resource.descriptor.relativeDestination,
                expectedSize: resource.descriptor.expectedSize,
                expectedSHA256: resource.descriptor.expectedSHA256,
                kind: resource.descriptor.kind
            ),
            file: file
        )
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

    private func removeContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private nonisolated static func helperReason(_ reason: EngineStopReason) -> HelperStopReason {
        switch reason {
        case .userRequested: .userRequested
        case .backendTransition: .backendTransition
        case .applicationQuit: .applicationQuit
        case .pause: .pause
        case .recovery: .recovery
        }
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func safeFailureDescription(_ error: Error) -> String {
        if let failure = error as? VelaHelperFailure {
            return "Helper error \(failure.code.rawValue)."
        }
        return "The privileged backend operation failed."
    }

    private nonisolated static func openStableRegularFile(
        _ url: URL,
        expectedSize: Int
    ) throws -> FileHandle {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw VelaHelperFailure(
                code: .unsafePath,
                safeMessage: "A local resource could not be opened safely."
            )
        }
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0,
            pathStatus.st_mode & S_IFMT == S_IFREG,
            pathStatus.st_size == expectedSize
        else {
            throw VelaHelperFailure(
                code: .unsafePath,
                safeMessage: "A local resource could not be opened safely."
            )
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw VelaHelperFailure(
                code: .unsafePath,
                safeMessage: "A local resource could not be opened safely."
            )
        }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            openedStatus.st_mode & S_IFMT == S_IFREG,
            openedStatus.st_dev == pathStatus.st_dev,
            openedStatus.st_ino == pathStatus.st_ino,
            openedStatus.st_size == expectedSize
        else {
            Darwin.close(descriptor)
            throw VelaHelperFailure(
                code: .unsafePath,
                safeMessage: "A local resource changed while it was being staged."
            )
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
