@preconcurrency import Foundation
import VelaIPC

nonisolated protocol PrivilegedHelperClientProtocol: Sendable {
    func handshake(
        clientVersion: String,
        clientBuild: String,
        requestedSessionID: UUID?
    ) async throws -> HelperHandshakeResponse
    func status() async throws -> HelperStatusResponse
    func prepareStart(_ request: PrepareStartRequest) async throws -> PrepareStartResponse
    func stageConfiguration(_ request: StageConfigurationRequest, data: Data) async throws
    func stageResource(_ request: StageResourceRequest, file: FileHandle) async throws
    func commitStart(_ request: CommitStartRequest) async throws -> PrivilegedEngineRuntime
    func abortStart(_ request: AbortStartRequest) async throws
    func stop(_ request: StopHelperRequest) async throws
    func renewLease(_ request: RenewLeaseRequest) async throws
    func readLogBatch(_ request: ReadLogBatchRequest) async throws -> ReadLogBatchResponse
    func cleanup(_ request: CleanupHelperRequest) async throws
    func prepareCoreInstall(
        _ request: PrepareCoreInstallRequest
    ) async throws -> PrepareCoreInstallResponse
    func stageCoreFile(_ request: StageCoreFileRequest, file: FileHandle) async throws
    func commitCoreInstall(_ request: CommitCoreInstallRequest) async throws
    func abortCoreInstall(_ request: AbortCoreInstallRequest) async throws
    func listInstalledCores(
        _ request: ListInstalledCoresRequest
    ) async throws -> ListInstalledCoresResponse
    func refreshCoreCatalog(
        _ request: RefreshCoreCatalogRequest
    ) async throws -> RefreshCoreCatalogResponse
    func removeCore(_ request: RemoveCoreRequest) async throws
    func validateCore(_ request: ValidateCoreRequest) async throws -> ValidateCoreResponse
    func invalidate() async
}

extension PrivilegedHelperClientProtocol {
    func prepareCoreInstall(
        _ request: PrepareCoreInstallRequest
    ) async throws -> PrepareCoreInstallResponse {
        throw VelaHelperFailure(
            code: .unsupportedOperation,
            requestID: request.requestID,
            safeMessage: "This privileged component does not support signed Core installation."
        )
    }

    func stageCoreFile(_ request: StageCoreFileRequest, file _: FileHandle) async throws {
        throw VelaHelperFailure(
            code: .unsupportedOperation,
            requestID: request.requestID,
            safeMessage: "This privileged component does not support signed Core installation."
        )
    }

    func commitCoreInstall(_ request: CommitCoreInstallRequest) async throws {
        throw VelaHelperFailure(
            code: .unsupportedOperation,
            requestID: request.requestID,
            safeMessage: "Signed Core installation is unavailable."
        )
    }

    func abortCoreInstall(_ request: AbortCoreInstallRequest) async throws {
        throw VelaHelperFailure(
            code: .unsupportedOperation,
            requestID: request.requestID,
            safeMessage: "Signed Core installation is unavailable."
        )
    }

    func listInstalledCores(
        _ request: ListInstalledCoresRequest
    ) async throws -> ListInstalledCoresResponse {
        throw VelaHelperFailure(
            code: .unsupportedOperation,
            requestID: request.requestID,
            safeMessage: "Signed Core inventory is unavailable."
        )
    }

    func removeCore(_ request: RemoveCoreRequest) async throws {
        throw VelaHelperFailure(
            code: .unsupportedOperation,
            requestID: request.requestID,
            safeMessage: "Signed Core removal is unavailable."
        )
    }

    func refreshCoreCatalog(
        _ request: RefreshCoreCatalogRequest
    ) async throws -> RefreshCoreCatalogResponse {
        throw VelaHelperFailure(
            code: .unsupportedOperation,
            requestID: request.requestID,
            safeMessage: "Signed Core policy refresh is unavailable."
        )
    }

    func validateCore(_ request: ValidateCoreRequest) async throws -> ValidateCoreResponse {
        throw VelaHelperFailure(
            code: .unsupportedOperation,
            requestID: request.requestID,
            safeMessage: "Signed Core verification is unavailable."
        )
    }
}

nonisolated struct PrivilegedHelperRPCTimeouts: Equatable, Sendable {
    let handshake: Duration
    let status: Duration
    let prepareStart: Duration
    let commitStart: Duration
    let abortStart: Duration
    let stop: Duration
    let renewLease: Duration
    let readLogBatch: Duration
    let cleanup: Duration

    private let fixedStagingTimeout: Duration?
    private let stagingMinimumSeconds: Int
    private let stagingMaximumSeconds: Int
    private let stagingBytesPerSecond: Int

    static let standard = PrivilegedHelperRPCTimeouts(
        handshake: .seconds(5),
        status: .seconds(5),
        prepareStart: .seconds(10),
        commitStart: .seconds(45),
        abortStart: .seconds(20),
        stop: .seconds(20),
        renewLease: .seconds(5),
        readLogBatch: .seconds(10),
        cleanup: .seconds(20),
        fixedStagingTimeout: nil,
        stagingMinimumSeconds: 10,
        stagingMaximumSeconds: 30,
        stagingBytesPerSecond: 2 * 1_024 * 1_024
    )

    static func uniform(_ timeout: Duration) -> Self {
        Self(
            handshake: timeout,
            status: timeout,
            prepareStart: timeout,
            commitStart: timeout,
            abortStart: timeout,
            stop: timeout,
            renewLease: timeout,
            readLogBatch: timeout,
            cleanup: timeout,
            fixedStagingTimeout: timeout,
            stagingMinimumSeconds: 0,
            stagingMaximumSeconds: 0,
            stagingBytesPerSecond: 1
        )
    }

    func stagingTimeout(byteCount: Int) -> Duration {
        if let fixedStagingTimeout { return fixedStagingTimeout }
        let boundedByteCount = max(0, byteCount)
        let transferSeconds = boundedByteCount == 0
            ? 0
            : (boundedByteCount + stagingBytesPerSecond - 1) / stagingBytesPerSecond
        return .seconds(min(
            stagingMaximumSeconds,
            stagingMinimumSeconds + transferSeconds
        ))
    }
}

actor PrivilegedHelperClient: PrivilegedHelperClientProtocol {
    private let machServiceName: String
    private let timeouts: PrivilegedHelperRPCTimeouts
    private var connection: NSXPCConnection?
    private var connectionGeneration: UUID?
    private var sessionID: UUID?

    init(
        machServiceName: String = VelaIPCConstants.machServiceName,
        timeouts: PrivilegedHelperRPCTimeouts = .standard
    ) {
        self.machServiceName = machServiceName
        self.timeouts = timeouts
    }

    init(
        machServiceName: String = VelaIPCConstants.machServiceName,
        requestTimeout: Duration
    ) {
        self.init(
            machServiceName: machServiceName,
            timeouts: .uniform(requestTimeout)
        )
    }

    func handshake(
        clientVersion: String,
        clientBuild: String,
        requestedSessionID: UUID?
    ) async throws -> HelperHandshakeResponse {
        let request = HelperHandshakeRequest(
            clientVersion: clientVersion,
            clientBuild: clientBuild,
            requestedSessionID: requestedSessionID
        )
        let response: HelperHandshakeResponse = try await perform(
            request,
            timeout: timeouts.handshake
        ) {
            proxy, data, reply in
            proxy.handshake(data, withReply: reply)
        }
        // A protocol-mismatch response is a read-only replacement probe. It
        // must never leave a previously authenticated session usable.
        sessionID = response.hasCompatibleProtocol ? response.sessionID : nil
        return response
    }

    func status() async throws -> HelperStatusResponse {
        let request = HelperStatusRequest(sessionID: sessionID)
        return try await perform(request, timeout: timeouts.status) { proxy, data, reply in
            proxy.status(data, withReply: reply)
        }
    }

    func prepareStart(_ request: PrepareStartRequest) async throws -> PrepareStartResponse {
        try requireSession(request.sessionID)
        return try await perform(request, timeout: timeouts.prepareStart) { proxy, data, reply in
            proxy.prepareStart(data, withReply: reply)
        }
    }

    func stageConfiguration(_ request: StageConfigurationRequest, data: Data) async throws {
        try requireSession(request.sessionID)
        guard data.count <= VelaIPCConstants.maximumConfigurationBytes else {
            throw VelaHelperFailure(
                code: .payloadTooLarge,
                requestID: request.requestID,
                safeMessage: "The privileged configuration exceeds its size limit."
            )
        }
        let _: EmptyHelperResponse = try await perform(
            request,
            timeout: timeouts.stagingTimeout(byteCount: data.count)
        ) { proxy, metadata, reply in
            proxy.stageConfiguration(metadata, configuration: data, withReply: reply)
        }
    }

    func stageResource(_ request: StageResourceRequest, file: FileHandle) async throws {
        try requireSession(request.sessionID)
        let _: EmptyHelperResponse = try await perform(
            request,
            timeout: timeouts.stagingTimeout(byteCount: request.expectedSize)
        ) { proxy, metadata, reply in
            proxy.stageResource(metadata, file: file, withReply: reply)
        }
    }

    func commitStart(_ request: CommitStartRequest) async throws -> PrivilegedEngineRuntime {
        try requireSession(request.sessionID)
        return try await perform(request, timeout: timeouts.commitStart) { proxy, data, reply in
            proxy.commitStart(data, withReply: reply)
        }
    }

    func abortStart(_ request: AbortStartRequest) async throws {
        try requireSession(request.sessionID)
        let _: EmptyHelperResponse = try await perform(
            request,
            timeout: timeouts.abortStart
        ) { proxy, data, reply in
            proxy.abortStart(data, withReply: reply)
        }
    }

    func stop(_ request: StopHelperRequest) async throws {
        try requireSession(request.sessionID)
        let _: EmptyHelperResponse = try await perform(request, timeout: timeouts.stop) {
            proxy, data, reply in
            proxy.stop(data, withReply: reply)
        }
    }

    func renewLease(_ request: RenewLeaseRequest) async throws {
        try requireSession(request.sessionID)
        let _: EmptyHelperResponse = try await perform(
            request,
            timeout: timeouts.renewLease
        ) { proxy, data, reply in
            proxy.renewLease(data, withReply: reply)
        }
    }

    func readLogBatch(_ request: ReadLogBatchRequest) async throws -> ReadLogBatchResponse {
        try requireSession(request.sessionID)
        return try await perform(
            request,
            timeout: timeouts.readLogBatch,
            maximumResponseBytes: VelaIPCConstants.maximumLogBatchBytes
        ) { proxy, data, reply in
            proxy.readLogBatch(data, withReply: reply)
        }
    }

    func cleanup(_ request: CleanupHelperRequest) async throws {
        try requireSession(request.sessionID)
        let _: EmptyHelperResponse = try await perform(request, timeout: timeouts.cleanup) {
            proxy, data, reply in
            proxy.cleanup(data, withReply: reply)
        }
    }

    func prepareCoreInstall(
        _ request: PrepareCoreInstallRequest
    ) async throws -> PrepareCoreInstallResponse {
        try requireSession(request.sessionID)
        return try await perform(
            request,
            timeout: timeouts.prepareStart,
            maximumRequestBytes: VelaIPCConstants.maximumCoreInstallPayloadBytes
        ) {
            proxy, data, reply in
            proxy.prepareCoreInstall(data, withReply: reply)
        }
    }

    func stageCoreFile(_ request: StageCoreFileRequest, file: FileHandle) async throws {
        try requireSession(request.sessionID)
        let _: EmptyHelperResponse = try await perform(
            request,
            timeout: timeouts.stagingTimeout(byteCount: request.expectedSize)
        ) { proxy, metadata, reply in
            proxy.stageCoreFile(metadata, file: file, withReply: reply)
        }
    }

    func commitCoreInstall(_ request: CommitCoreInstallRequest) async throws {
        try requireSession(request.sessionID)
        let _: EmptyHelperResponse = try await perform(
            request,
            timeout: timeouts.commitStart
        ) { proxy, data, reply in
            proxy.commitCoreInstall(data, withReply: reply)
        }
    }

    func abortCoreInstall(_ request: AbortCoreInstallRequest) async throws {
        try requireSession(request.sessionID)
        let _: EmptyHelperResponse = try await perform(
            request,
            timeout: timeouts.abortStart
        ) { proxy, data, reply in
            proxy.abortCoreInstall(data, withReply: reply)
        }
    }

    func listInstalledCores(
        _ request: ListInstalledCoresRequest
    ) async throws -> ListInstalledCoresResponse {
        try requireSession(request.sessionID)
        return try await perform(request, timeout: timeouts.status) {
            proxy, data, reply in
            proxy.listInstalledCores(data, withReply: reply)
        }
    }

    func refreshCoreCatalog(
        _ request: RefreshCoreCatalogRequest
    ) async throws -> RefreshCoreCatalogResponse {
        try requireSession(request.sessionID)
        return try await perform(
            request,
            timeout: timeouts.prepareStart,
            maximumRequestBytes: VelaIPCConstants.maximumCoreInstallPayloadBytes
        ) { proxy, data, reply in
            proxy.refreshCoreCatalog(data, withReply: reply)
        }
    }

    func removeCore(_ request: RemoveCoreRequest) async throws {
        try requireSession(request.sessionID)
        let _: EmptyHelperResponse = try await perform(request, timeout: timeouts.cleanup) {
            proxy, data, reply in
            proxy.removeCore(data, withReply: reply)
        }
    }

    func validateCore(_ request: ValidateCoreRequest) async throws -> ValidateCoreResponse {
        try requireSession(request.sessionID)
        return try await perform(request, timeout: timeouts.status) {
            proxy, data, reply in
            proxy.validateCore(data, withReply: reply)
        }
    }

    func invalidate() {
        invalidateTransport(preserveSession: false)
    }

    private func requireSession(_ requested: UUID) throws {
        guard sessionID == requested else {
            throw VelaHelperFailure(
                code: .invalidSession,
                safeMessage: "The privileged helper session is no longer valid."
            )
        }
    }

    private func perform<Request: HelperPayload, Response: HelperPayload>(
        _ request: Request,
        timeout: Duration,
        maximumRequestBytes: Int = VelaIPCConstants.maximumPayloadBytes,
        maximumResponseBytes: Int = VelaIPCConstants.maximumPayloadBytes,
        invocation: @escaping @Sendable (
            any VelaHelperProtocol,
            Data,
            @escaping @Sendable (Data?, NSError?) -> Void
        ) -> Void
    ) async throws -> Response {
        let requestData = try HelperPayloadCodec.encode(
            request,
            maximumBytes: maximumRequestBytes
        )
        let activeConnection = ensureConnection()
        let gate = XPCReplyGate<Response>()

        do {
            let response: Response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gate.install(continuation)
                    gate.scheduleTimeout(after: timeout, requestID: request.requestID)

                    guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ _ in
                        gate.fail(
                            VelaHelperFailure(
                                code: .helperUnavailable,
                                requestID: request.requestID,
                                safeMessage: "The privileged component connection failed."
                            )
                        )
                    }) as? any VelaHelperProtocol else {
                        gate.fail(
                            VelaHelperFailure(
                                code: .helperUnavailable,
                                requestID: request.requestID,
                                safeMessage: "The privileged component proxy is unavailable."
                            )
                        )
                        return
                    }

                    invocation(proxy, requestData) { data, error in
                        if let error {
                            gate.fail(Self.mapRemoteError(error, requestID: request.requestID))
                            return
                        }
                        guard let data else {
                            gate.fail(
                                VelaHelperFailure(
                                    code: .invalidPayload,
                                    requestID: request.requestID,
                                    safeMessage: "The privileged component returned an empty response."
                                )
                            )
                            return
                        }
                        do {
                            let response = try HelperPayloadCodec.decode(
                                Response.self,
                                from: data,
                                maximumBytes: maximumResponseBytes
                            )
                            guard response.requestID == request.requestID else {
                                throw VelaHelperFailure(
                                    code: .invalidPayload,
                                    requestID: request.requestID,
                                    safeMessage: "The privileged response does not match its request."
                                )
                            }
                            gate.succeed(response)
                        } catch {
                            gate.fail(error)
                        }
                    }
                }
            } onCancel: {
                gate.fail(CancellationError())
            }
            try Task.checkCancellation()
            return response
        } catch {
            if Self.requiresConnectionInvalidation(error) {
                invalidateTransport(preserveSession: true)
            }
            throw error
        }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let connection { return connection }

        let connection = NSXPCConnection(
            machServiceName: machServiceName,
            options: .privileged
        )
        let generation = UUID()
        connection.remoteObjectInterface = VelaHelperXPCInterface.make()
        connection.interruptionHandler = { [weak self] in
            Task { await self?.connectionWasInterrupted(generation: generation) }
        }
        connection.invalidationHandler = { [weak self] in
            Task { await self?.connectionWasInvalidated(generation: generation) }
        }
        connection.activate()
        self.connection = connection
        connectionGeneration = generation
        return connection
    }

    private func connectionWasInterrupted(generation: UUID) {
        guard connectionGeneration == generation else { return }
        invalidateTransport(preserveSession: true)
        // Keep the opaque session ID. `PrivilegedComponentManager.refresh()`
        // presents it in the next authenticated handshake during the bounded
        // reconnect grace.
    }

    private func connectionWasInvalidated(generation: UUID) {
        guard connectionGeneration == generation else { return }
        connection = nil
        connectionGeneration = nil
    }

    private func invalidateTransport(preserveSession: Bool) {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        connectionGeneration = nil
        if !preserveSession {
            sessionID = nil
        }
    }

    private nonisolated static func requiresConnectionInvalidation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let failure = error as? VelaHelperFailure else { return false }
        return failure.code == .requestTimedOut || failure.code == .helperUnavailable
    }

    private nonisolated static func mapRemoteError(
        _ error: NSError,
        requestID: UUID
    ) -> VelaHelperFailure {
        if error.domain == VelaHelperErrorDomain,
            let code = VelaHelperErrorCode(rawValue: error.code)
        {
            return VelaHelperFailure(
                code: code,
                requestID: requestID,
                safeMessage: error.localizedDescription
            )
        }
        return VelaHelperFailure(
            code: .helperUnavailable,
            requestID: requestID,
            safeMessage: "The privileged component is unavailable."
        )
    }
}

nonisolated final class XPCReplyGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isFinished = false
    private var timeoutTimer: DispatchSourceTimer?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            isFinished = true
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func scheduleTimeout(after duration: Duration, requestID: UUID) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + duration.timeInterval)
        timer.setEventHandler { [weak self] in
            self?.fail(
                VelaHelperFailure(
                    code: .requestTimedOut,
                    requestID: requestID,
                    safeMessage: "The privileged component did not reply in time."
                )
            )
        }
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            timer.cancel()
            return
        }
        timeoutTimer = timer
        lock.unlock()
        timer.activate()
    }

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        if let continuation {
            isFinished = true
            self.continuation = nil
            let timer = timeoutTimer
            timeoutTimer = nil
            lock.unlock()
            timer?.cancel()
            continuation.resume(with: result)
        } else {
            isFinished = true
            pendingResult = result
            lock.unlock()
        }
    }
}

nonisolated private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
