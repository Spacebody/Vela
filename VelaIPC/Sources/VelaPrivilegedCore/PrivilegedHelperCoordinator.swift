import Darwin
import Foundation
import VelaIPC

public struct AuthenticatedHelperConnection: Equatable, Sendable {
    public let connectionID: UUID
    public let effectiveUserID: UInt32

    public init(connectionID: UUID = UUID(), effectiveUserID: UInt32) {
        self.connectionID = connectionID
        self.effectiveUserID = effectiveUserID
    }
}

public struct PrivilegedHelperIdentity: Equatable, Sendable {
    public let signingIdentitySummary: String
    public let daemonUID: UInt32
    public let mihomoVersion: String
    public let mihomoPlatform: String
    public let mihomoArchitecture: String

    public init(
        signingIdentitySummary: String,
        daemonUID: UInt32,
        mihomoVersion: String = VelaIPCConstants.expectedMihomoVersion,
        mihomoPlatform: String = "darwin",
        mihomoArchitecture: String = "arm64"
    ) {
        self.signingIdentitySummary = signingIdentitySummary
        self.daemonUID = daemonUID
        self.mihomoVersion = mihomoVersion
        self.mihomoPlatform = mihomoPlatform
        self.mihomoArchitecture = mihomoArchitecture
    }
}

public struct PrivilegedEngineStartContext: Sendable {
    public let transaction: RootTransactionRecord
    public let sanitizedConfiguration: SanitizedRuntimeConfiguration

    public init(
        transaction: RootTransactionRecord,
        sanitizedConfiguration: SanitizedRuntimeConfiguration
    ) {
        self.transaction = transaction
        self.sanitizedConfiguration = sanitizedConfiguration
    }
}

public struct PrivilegedEngineStartResult: Equatable, Sendable {
    public let instanceID: UUID
    public let processID: Int32
    public let startedAt: Date
    public let tunInterface: String?

    public init(
        instanceID: UUID,
        processID: Int32,
        startedAt: Date,
        tunInterface: String?
    ) {
        self.instanceID = instanceID
        self.processID = processID
        self.startedAt = startedAt
        self.tunInterface = tunInterface
    }
}

public struct PrivilegedEngineControllerStatus: Equatable, Sendable {
    public let state: HelperProcessState
    public let processID: Int32?
    public let instanceID: UUID?
    public let configurationSHA256: String?
    public let health: PrivilegedRuntimeHealth

    public init(
        state: HelperProcessState,
        processID: Int32?,
        instanceID: UUID?,
        configurationSHA256: String?,
        health: PrivilegedRuntimeHealth
    ) {
        self.state = state
        self.processID = processID
        self.instanceID = instanceID
        self.configurationSHA256 = configurationSHA256
        self.health = health
    }

    public static var stopped: Self {
        Self(
            state: .stopped,
            processID: nil,
            instanceID: nil,
            configurationSHA256: nil,
            health: PrivilegedRuntimeHealth(
                helperReachable: true,
                helperVersionCompatible: true,
                processRunning: false,
                controllerReachable: false,
                configurationHashMatches: false,
                tunEnabledInController: false,
                tunInterfacePresent: false,
                routeApplied: false,
                dnsReady: false,
                ownerLeaseValid: false,
                tunInterface: nil,
                lastCheckedAt: .now
            )
        )
    }
}

public protocol PrivilegedRuntimeControlling: Sendable {
    func start(_ context: PrivilegedEngineStartContext) async throws
        -> PrivilegedEngineStartResult
    func stop(instanceID: UUID?, reason: HelperStopReason) async throws
    func status() async -> PrivilegedEngineControllerStatus
    func readLogs(after sequence: UInt64, maximumEntries: Int) async throws
        -> [HelperLogEntry]
    func cleanup(mode: PrivilegedCleanupMode, ownerUID: UInt32) async throws
}

public struct DisabledPrivilegedRuntimeController: PrivilegedRuntimeControlling {
    public init() {}

    public func start(_: PrivilegedEngineStartContext) async throws
        -> PrivilegedEngineStartResult
    {
        throw VelaHelperFailure(
            code: .helperUnavailable,
            safeMessage: "The privileged engine is not available."
        )
    }

    public func stop(instanceID _: UUID?, reason _: HelperStopReason) async throws {}
    public func status() async -> PrivilegedEngineControllerStatus { .stopped }
    public func readLogs(after _: UInt64, maximumEntries _: Int) async throws
        -> [HelperLogEntry]
    {
        []
    }
    public func cleanup(mode _: PrivilegedCleanupMode, ownerUID _: UInt32) async throws {}
}

public protocol ControllerPortAllocating: Sendable {
    func allocateLoopbackPort() throws -> UInt16
}

public struct LoopbackControllerPortAllocator: ControllerPortAllocating {
    public init() {}

    public func allocateLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControllerPortAllocationError.unavailable }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ControllerPortAllocationError.unavailable }

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw ControllerPortAllocationError.unavailable }
        let port = UInt16(bigEndian: resolved.sin_port)
        guard port >= 1_024 else { throw ControllerPortAllocationError.unavailable }
        return port
    }
}

public enum ControllerPortAllocationError: Error, Equatable, Sendable {
    case unavailable
}

/// High-level, typed façade used by the XPC exported object. The exported object
/// owns decoding/reply-once mechanics; all mutable privileged state lives here.
public actor PrivilegedHelperCoordinator {
    private let identity: PrivilegedHelperIdentity
    private let leases: OwnerLeaseCoordinator
    private let transactions: RootTransactionStore
    private let sanitizer: PrivilegedConfigSanitizer
    private let engine: any PrivilegedRuntimeControlling
    private let portAllocator: any ControllerPortAllocating
    private let coreStore: RootCoreStore?
    private let operationGate = AsyncExclusiveOperationGate()
    private var activeRuntime: PrivilegedEngineRuntime?
    private var lastStableErrorCode: VelaHelperErrorCode?

    public init(
        identity: PrivilegedHelperIdentity,
        leases: OwnerLeaseCoordinator,
        transactions: RootTransactionStore,
        sanitizer: PrivilegedConfigSanitizer = PrivilegedConfigSanitizer(),
        engine: any PrivilegedRuntimeControlling = DisabledPrivilegedRuntimeController(),
        portAllocator: any ControllerPortAllocating = LoopbackControllerPortAllocator(),
        coreStore: RootCoreStore? = nil
    ) {
        self.identity = identity
        self.leases = leases
        self.transactions = transactions
        self.sanitizer = sanitizer
        self.engine = engine
        self.portAllocator = portAllocator
        self.coreStore = coreStore
    }

    public func handshake(
        _ request: HelperHandshakeRequest,
        connection: AuthenticatedHelperConnection
    ) async throws -> HelperHandshakeResponse {
        let status = await engine.status()
        let hasCompatibleProtocol =
            request.clientProtocolMinimum <= VelaIPCConstants.protocolMaximum
                && request.clientProtocolMaximum >= VelaIPCConstants.protocolMinimum
        guard hasCompatibleProtocol else {
            // This deliberately version-neutral response is the only operation
            // available across a protocol mismatch. It does not claim or
            // mutate an owner lease and exposes only enough state for a newer
            // signed App to prove that replacing this Helper is safe.
            let lease = await leases.currentValid()
            return HelperHandshakeResponse(
                requestID: request.requestID,
                signingIdentitySummary: identity.signingIdentitySummary,
                daemonUID: identity.daemonUID,
                currentOwnerUID: lease?.ownerUID,
                sessionID: nil,
                mihomoVersion: identity.mihomoVersion,
                mihomoPlatform: identity.mihomoPlatform,
                mihomoArchitecture: identity.mihomoArchitecture,
                state: status.state,
                processID: status.processID
            )
        }
        let lease = try await leases.claim(
            ownerUID: connection.effectiveUserID,
            connectionID: connection.connectionID,
            requestedSessionID: request.requestedSessionID
        )
        return HelperHandshakeResponse(
            requestID: request.requestID,
            signingIdentitySummary: identity.signingIdentitySummary,
            daemonUID: identity.daemonUID,
            currentOwnerUID: lease.ownerUID,
            sessionID: lease.sessionID,
            mihomoVersion: identity.mihomoVersion,
            mihomoPlatform: identity.mihomoPlatform,
            mihomoArchitecture: identity.mihomoArchitecture,
            state: status.state,
            processID: status.processID
        )
    }

    public func status(
        _ request: HelperStatusRequest,
        connectionID: UUID
    ) async throws -> HelperStatusResponse {
        let lease = await leases.currentValid()
        if let sessionID = request.sessionID {
            try require(lease: lease, sessionID: sessionID, connectionID: connectionID)
        }
        var engineStatus = await engine.status()
        if lease != nil {
            engineStatus = PrivilegedEngineControllerStatus(
                state: engineStatus.state,
                processID: engineStatus.processID,
                instanceID: engineStatus.instanceID,
                configurationSHA256: engineStatus.configurationSHA256,
                health: replacingLeaseHealth(engineStatus.health, isValid: true)
            )
        }
        return HelperStatusResponse(
            requestID: request.requestID,
            state: engineStatus.state,
            currentOwnerUID: lease?.ownerUID,
            processID: engineStatus.processID,
            instanceID: engineStatus.instanceID,
            configurationSHA256: engineStatus.configurationSHA256,
            health: engineStatus.health,
            lastStableErrorCode: lastStableErrorCode
        )
    }

    public func prepareStart(
        _ request: PrepareStartRequest,
        connectionID: UUID
    ) async throws -> PrepareStartResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        let lease = await leases.currentValid()
        try require(lease: lease, sessionID: request.sessionID, connectionID: connectionID)
        let ownerUID = try requiredLease(lease).ownerUID
        // Persist the CoreID before mutating the runtime controller's selected
        // executable. In particular, a second prepare must fail with
        // `alreadyActive` without first changing the Core selected for the
        // existing transaction.
        let record = try await transactions.prepare(request: request, ownerUID: ownerUID)
        do {
            try await selectCore(record.coreID, requestID: request.requestID)
        } catch {
            try? await transactions.abort(
                transactionID: record.transactionID,
                sessionID: record.sessionID
            )
            throw error
        }
        let total = request.resources.reduce(0) { $0 + $1.expectedSize }
        return PrepareStartResponse(
            requestID: request.requestID,
            transactionID: record.transactionID,
            expiresAt: record.expiresAt,
            maximumResourceBytesRemaining: VelaIPCConstants.maximumResourceTotalBytes - total
        )
    }

    public func stageConfiguration(
        _ request: StageConfigurationRequest,
        configuration: Data,
        connectionID: UUID
    ) async throws -> EmptyHelperResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        guard configuration.count <= VelaIPCConstants.maximumConfigurationBytes else {
            throw VelaHelperFailure(
                code: .payloadTooLarge,
                requestID: request.requestID,
                safeMessage: "The privileged configuration exceeds its size limit."
            )
        }
        try await transactions.stageConfiguration(
            request: request,
            configuration: configuration
        )
        return EmptyHelperResponse(requestID: request.requestID)
    }

    public func stageResource(
        _ request: StageResourceRequest,
        file: FileHandle,
        connectionID: UUID
    ) async throws -> EmptyHelperResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        try await transactions.stageResource(request: request, file: file)
        return EmptyHelperResponse(requestID: request.requestID)
    }

    public func commitStart(
        _ request: CommitStartRequest,
        connectionID: UUID
    ) async throws -> PrivilegedEngineRuntime {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        let record = try requiredTransaction(
            await transactions.current(),
            transactionID: request.transactionID,
            sessionID: request.sessionID
        )
        let input = try await transactions.configurationData(
            transactionID: request.transactionID,
            sessionID: request.sessionID
        )
        let resources = try await transactions.sanitizerResources(
            transactionID: request.transactionID,
            sessionID: request.sessionID
        )
        let port = try portAllocator.allocateLoopbackPort()
        let sanitized = try sanitizer.sanitize(
            configuration: input,
            tunSettings: record.tunSettings,
            resources: resources,
            controllerPort: port
        )
        try await transactions.markSanitized(
            transactionID: request.transactionID,
            sessionID: request.sessionID,
            data: sanitized.data,
            sha256: sanitized.sha256
        )
        let runtimePackage = try await transactions.promoteSanitized(
            transactionID: request.transactionID,
            sessionID: request.sessionID
        )

        var started: PrivilegedEngineStartResult?
        do {
            // Re-select from the durable transaction immediately before start.
            // This is a defense-in-depth binding: commit never trusts a global
            // Core selection left behind by an earlier or failed prepare.
            try await selectCore(
                runtimePackage.transaction.coreID,
                requestID: request.requestID
            )
            let startResult = try await engine.start(
                PrivilegedEngineStartContext(
                    transaction: runtimePackage.transaction,
                    sanitizedConfiguration: sanitized
                )
            )
            started = startResult
            let runtime = sanitized.controllerSecret.withValue { secret in
                PrivilegedEngineRuntime(
                    requestID: request.requestID,
                    instanceID: startResult.instanceID,
                    controllerHost: "127.0.0.1",
                    controllerPort: sanitized.controllerPort,
                    controllerSecret: secret,
                    processID: startResult.processID,
                    startedAt: startResult.startedAt,
                    configurationSHA256: sanitized.sha256,
                    tunInterface: startResult.tunInterface
                )
            }
            try await transactions.markCommitted(
                transactionID: request.transactionID,
                sessionID: request.sessionID
            )
            if let coreStore {
                try await coreStore.recordActivation(runtimePackage.transaction.coreID)
            }
            activeRuntime = runtime
            lastStableErrorCode = nil
            return runtime
        } catch {
            if let started {
                do {
                    try await engine.stop(instanceID: started.instanceID, reason: .recovery)
                } catch {
                    // Do not delete the config/resources while a proven-owned root
                    // process may still be using them. A later identity-verified
                    // repair must resolve this state.
                    lastStableErrorCode = .manualRepairRequired
                    throw VelaHelperFailure(
                        code: .manualRepairRequired,
                        requestID: request.requestID,
                        safeMessage: "The privileged engine requires manual repair."
                    )
                }
            }
            try? await transactions.abort(
                transactionID: request.transactionID,
                sessionID: request.sessionID
            )
            lastStableErrorCode = VelaHelperFailure.from(error).code
            throw error
        }
    }

    public func abortStart(
        _ request: AbortStartRequest,
        connectionID: UUID
    ) async throws -> EmptyHelperResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        try await transactions.abort(
            transactionID: request.transactionID,
            sessionID: request.sessionID
        )
        return EmptyHelperResponse(requestID: request.requestID)
    }

    public func stop(
        _ request: StopHelperRequest,
        connectionID: UUID
    ) async throws -> EmptyHelperResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        if let requested = request.instanceID,
            let current = activeRuntime?.instanceID,
            requested != current
        {
            throw VelaHelperFailure(
                code: .invalidState,
                requestID: request.requestID,
                safeMessage: "The privileged engine instance no longer matches."
            )
        }
        try await engine.stop(instanceID: request.instanceID, reason: request.reason)
        activeRuntime = nil
        try await abortPendingTransactionIfPresent()
        return EmptyHelperResponse(requestID: request.requestID)
    }

    public func renewLease(
        _ request: RenewLeaseRequest,
        connectionID: UUID
    ) async throws -> EmptyHelperResponse {
        if let instanceID = request.instanceID,
            let current = activeRuntime?.instanceID,
            instanceID != current
        {
            throw VelaHelperFailure(
                code: .invalidState,
                requestID: request.requestID,
                safeMessage: "The privileged engine instance no longer matches."
            )
        }
        _ = try await leases.renew(
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        return EmptyHelperResponse(requestID: request.requestID)
    }

    public func readLogs(
        _ request: ReadLogBatchRequest,
        connectionID: UUID
    ) async throws -> ReadLogBatchResponse {
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        let count = min(max(request.maximumEntries, 0), VelaIPCConstants.maximumLogEntryCount)
        let entries = try await engine.readLogs(
            after: request.afterSequence,
            maximumEntries: count
        )
        return ReadLogBatchResponse(requestID: request.requestID, entries: entries)
    }

    public func cleanup(
        _ request: CleanupHelperRequest,
        connectionID: UUID
    ) async throws -> EmptyHelperResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        let lease = await leases.currentValid()
        try require(lease: lease, sessionID: request.sessionID, connectionID: connectionID)
        let ownerUID = try requiredLease(lease).ownerUID
        if activeRuntime != nil {
            try await engine.stop(instanceID: activeRuntime?.instanceID, reason: .uninstall)
            activeRuntime = nil
        }
        try await abortPendingTransactionIfPresent()
        try await engine.cleanup(mode: request.mode, ownerUID: ownerUID)
        return EmptyHelperResponse(requestID: request.requestID)
    }

    public func prepareCoreInstall(
        _ request: PrepareCoreInstallRequest,
        connectionID: UUID
    ) async throws -> PrepareCoreInstallResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        guard let coreStore else { throw coreStoreUnavailable(request.requestID) }
        let ownerUID = try requiredLease(await leases.currentValid()).ownerUID
        return try await coreStore.prepareInstall(
            request,
            authenticatedOwnerUID: ownerUID
        )
    }

    public func stageCoreFile(
        _ request: StageCoreFileRequest,
        file: FileHandle,
        connectionID: UUID
    ) async throws -> EmptyHelperResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        guard let coreStore else { throw coreStoreUnavailable(request.requestID) }
        try await coreStore.stageFile(request, file: file)
        return EmptyHelperResponse(requestID: request.requestID)
    }

    public func commitCoreInstall(
        _ request: CommitCoreInstallRequest,
        connectionID: UUID
    ) async throws -> EmptyHelperResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        guard let coreStore else { throw coreStoreUnavailable(request.requestID) }
        _ = try await coreStore.commitInstall(request)
        return EmptyHelperResponse(requestID: request.requestID)
    }

    public func abortCoreInstall(
        _ request: AbortCoreInstallRequest,
        connectionID: UUID
    ) async throws -> EmptyHelperResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        guard let coreStore else { throw coreStoreUnavailable(request.requestID) }
        try await coreStore.abortInstall(request)
        return EmptyHelperResponse(requestID: request.requestID)
    }

    public func listInstalledCores(
        _ request: ListInstalledCoresRequest,
        connectionID: UUID
    ) async throws -> ListInstalledCoresResponse {
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        guard let coreStore else { throw coreStoreUnavailable(request.requestID) }
        return try await coreStore.list(requestID: request.requestID)
    }

    public func refreshCoreCatalog(
        _ request: RefreshCoreCatalogRequest,
        connectionID: UUID
    ) async throws -> RefreshCoreCatalogResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        guard let coreStore else { throw coreStoreUnavailable(request.requestID) }
        return try await coreStore.refreshSignedPolicy(request)
    }

    public func removeCore(
        _ request: RemoveCoreRequest,
        connectionID: UUID
    ) async throws -> EmptyHelperResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        guard let coreStore else { throw coreStoreUnavailable(request.requestID) }
        try await coreStore.remove(request.coreID)
        return EmptyHelperResponse(requestID: request.requestID)
    }

    public func validateCore(
        _ request: ValidateCoreRequest,
        connectionID: UUID
    ) async throws -> ValidateCoreResponse {
        await operationGate.acquire()
        defer { operationGate.release() }
        try require(
            lease: await leases.currentValid(),
            sessionID: request.sessionID,
            connectionID: connectionID
        )
        guard let coreStore else { throw coreStoreUnavailable(request.requestID) }
        return try await coreStore.validate(request.coreID, requestID: request.requestID)
    }

    public func connectionInvalidated(connectionID: UUID) async {
        await leases.disconnected(connectionID: connectionID)
    }

    /// Trusted Helper power-observer hooks. These are intentionally not part of
    /// `VelaHelperProtocol`; an XPC client cannot suspend its own lease expiry.
    public func systemWillSleep() async {
        await leases.willSleep()
    }

    public func systemDidWake() async {
        await leases.didWake()
    }

    /// Called by a bounded Helper timer. Besides expired-owner cleanup, it
    /// reconciles an owned runtime whose Mihomo child has already exited. This
    /// prevents a healthy XPC lease from keeping a dead managed generation and
    /// dirty journal forever. It never discovers or signals a process by name,
    /// and it performs at most one identity-safe stop/cleanup attempt per call.
    @discardableResult
    public func cleanupExpiredLeaseIfNeeded() async -> Bool {
        await operationGate.acquire()
        defer { operationGate.release() }

        if let runtime = activeRuntime {
            let status = await engine.status()
            if !status.health.processRunning {
                let ownerUID = await leases.current()?.ownerUID
                do {
                    try await engine.stop(
                        instanceID: runtime.instanceID,
                        reason: .recovery
                    )
                    activeRuntime = nil
                    try await abortPendingTransactionIfPresent()
                    if let ownerUID {
                        try await engine.cleanup(
                            mode: .runtimeOnly,
                            ownerUID: ownerUID
                        )
                    }
                    lastStableErrorCode = .processStartFailed
                } catch {
                    lastStableErrorCode = .cleanupFailed
                }
                return true
            }
        }

        guard let expired = await leases.expiredOwner() else { return false }
        do {
            try await engine.stop(instanceID: activeRuntime?.instanceID, reason: .leaseExpired)
            activeRuntime = nil
            try await abortPendingTransactionIfPresent()
            try await engine.cleanup(mode: .runtimeOnly, ownerUID: expired.ownerUID)
            lastStableErrorCode = nil
        } catch {
            lastStableErrorCode = .cleanupFailed
        }
        return true
    }

    private func require(
        lease: OwnerLeaseSnapshot?,
        sessionID: UUID,
        connectionID: UUID
    ) throws {
        let lease = try requiredLease(lease)
        guard lease.sessionID == sessionID else {
            throw VelaHelperFailure(
                code: .invalidSession,
                safeMessage: "The privileged owner session is invalid."
            )
        }
        guard lease.connectionID == connectionID, lease.isConnected else {
            throw VelaHelperFailure(
                code: .invalidSession,
                safeMessage: "The privileged connection is no longer the owner."
            )
        }
    }

    private func requiredLease(_ lease: OwnerLeaseSnapshot?) throws -> OwnerLeaseSnapshot {
        guard let lease else {
            throw VelaHelperFailure(
                code: .invalidSession,
                safeMessage: "No privileged owner session is active."
            )
        }
        return lease
    }

    private func requiredTransaction(
        _ transaction: RootTransactionRecord?,
        transactionID: UUID,
        sessionID: UUID
    ) throws -> RootTransactionRecord {
        guard let transaction,
            transaction.transactionID == transactionID,
            transaction.sessionID == sessionID
        else {
            throw VelaHelperFailure(
                code: .invalidTransaction,
                safeMessage: "The privileged start transaction is invalid."
            )
        }
        return transaction
    }

    private func abortPendingTransactionIfPresent() async throws {
        guard let transaction = await transactions.current() else { return }
        try await transactions.abort(
            transactionID: transaction.transactionID,
            sessionID: transaction.sessionID
        )
    }

    private func selectCore(_ coreID: CoreID, requestID: UUID) async throws {
        if let selecting = engine as? any PrivilegedCoreRuntimeSelecting {
            try await selecting.selectCore(coreID)
        } else if coreID != .factoryV11928 {
            throw VelaHelperFailure(
                code: .coreNotInstalled,
                requestID: requestID,
                safeMessage: "The selected privileged core is unavailable."
            )
        }
    }

    private func coreStoreUnavailable(_ requestID: UUID) -> VelaHelperFailure {
        VelaHelperFailure(
            code: .helperUnavailable,
            requestID: requestID,
            safeMessage: "The privileged core store is unavailable."
        )
    }

    private func replacingLeaseHealth(
        _ health: PrivilegedRuntimeHealth,
        isValid: Bool
    ) -> PrivilegedRuntimeHealth {
        PrivilegedRuntimeHealth(
            helperReachable: health.helperReachable,
            helperVersionCompatible: health.helperVersionCompatible,
            processRunning: health.processRunning,
            controllerReachable: health.controllerReachable,
            configurationHashMatches: health.configurationHashMatches,
            tunEnabledInController: health.tunEnabledInController,
            tunInterfacePresent: health.tunInterfacePresent,
            routeApplied: health.routeApplied,
            dnsReady: health.dnsReady,
            ownerLeaseValid: isValid,
            tunInterface: health.tunInterface,
            lastCheckedAt: health.lastCheckedAt
        )
    }
}
