import Darwin
import Foundation
import Testing
import VelaIPC
@testable import VelaPrivilegedCore

@Suite("Privileged operation serialization")
struct PrivilegedCoordinatorSerializationTests {
    @Test("A legacy v1 handshake is a read-only probe and never claims a lease")
    func incompatibleHandshakeDoesNotClaimLease() async throws {
        let root = URL.temporaryDirectory
            .appending(path: "VelaHandshakeProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = try POSIXRootFileSystem.openExisting(
            at: root,
            policy: PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
        )
        let leases = OwnerLeaseCoordinator()
        let coordinator = PrivilegedHelperCoordinator(
            identity: PrivilegedHelperIdentity(
                signingIdentitySummary: "Team ID TEST",
                daemonUID: UInt32(geteuid())
            ),
            leases: leases,
            transactions: RootTransactionStore(fileSystem: fileSystem),
            engine: SuspendedStartRuntimeController(),
            portAllocator: FixedTestPortAllocator()
        )
        let request = HelperHandshakeRequest(
            clientProtocolMinimum: 1,
            clientProtocolMaximum: 1,
            clientVersion: "0.5.0",
            clientBuild: "1"
        )

        let response = try await coordinator.handshake(
            request,
            connection: AuthenticatedHelperConnection(effectiveUserID: UInt32(getuid()))
        )

        #expect(
            response.helperProtocolMaximum < request.clientProtocolMinimum
                || response.helperProtocolMinimum > request.clientProtocolMaximum
        )
        #expect(response.sessionID == nil)
        #expect(response.currentOwnerUID == nil)
        #expect(response.state == .stopped)
        #expect(response.processID == nil)
        #expect(await leases.current() == nil)
    }

    @Test("Stop waits for an in-flight start and returns only after stopping it")
    func stopCannotSucceedBeforeSuspendedStart() async throws {
        let root = URL.temporaryDirectory.appending(path: "VelaGate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = try POSIXRootFileSystem.openExisting(
            at: root,
            policy: PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
        )
        let transactions = RootTransactionStore(fileSystem: fileSystem)
        let runtime = SuspendedStartRuntimeController()
        let coordinator = PrivilegedHelperCoordinator(
            identity: PrivilegedHelperIdentity(
                signingIdentitySummary: "Team ID TEST",
                daemonUID: UInt32(geteuid())
            ),
            leases: OwnerLeaseCoordinator(),
            transactions: transactions,
            engine: runtime,
            portAllocator: FixedTestPortAllocator()
        )
        let connection = AuthenticatedHelperConnection(effectiveUserID: UInt32(getuid()))
        let handshake = try await coordinator.handshake(
            HelperHandshakeRequest(clientVersion: "test", clientBuild: "1"),
            connection: connection
        )
        let sessionID = try #require(handshake.sessionID)
        let configuration = Data(
            "mode: rule\nproxies: []\nproxy-groups: []\nrules: []\n".utf8
        )
        let hash = IntegrityValue.sha256Hex(of: configuration)
        let prepared = try await coordinator.prepareStart(
            PrepareStartRequest(
                sessionID: sessionID,
                configurationSize: configuration.count,
                configurationSHA256: hash,
                resources: [],
                tunSettings: TunSettings(dnsHijack: false)
            ),
            connectionID: connection.connectionID
        )
        _ = try await coordinator.stageConfiguration(
            StageConfigurationRequest(
                sessionID: sessionID,
                transactionID: prepared.transactionID,
                expectedSize: configuration.count,
                expectedSHA256: hash
            ),
            configuration: configuration,
            connectionID: connection.connectionID
        )

        let commitTask = Task {
            try await coordinator.commitStart(
                CommitStartRequest(
                    sessionID: sessionID,
                    transactionID: prepared.transactionID
                ),
                connectionID: connection.connectionID
            )
        }
        await runtime.waitUntilStartIsSuspended()
        let stopTask = Task {
            try await coordinator.stop(
                StopHelperRequest(
                    sessionID: sessionID,
                    instanceID: nil,
                    reason: .userRequested
                ),
                connectionID: connection.connectionID
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await runtime.stopCallCount() == 0)

        await runtime.resumeStart()
        _ = try await commitTask.value
        _ = try await stopTask.value
        #expect(await runtime.events() == ["start-enter", "start-return", "stop"])
    }

    @Test("A failed later prepare cannot substitute the Core committed by the active transaction")
    func failedPrepareCannotSubstitutePreparedCore() async throws {
        let root = URL.temporaryDirectory
            .appending(path: "VelaCoreBinding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = try POSIXRootFileSystem.openExisting(
            at: root,
            policy: PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
        )
        let runtime = CoreBindingRuntimeController()
        let coordinator = PrivilegedHelperCoordinator(
            identity: PrivilegedHelperIdentity(
                signingIdentitySummary: "Team ID TEST",
                daemonUID: UInt32(geteuid())
            ),
            leases: OwnerLeaseCoordinator(),
            transactions: RootTransactionStore(fileSystem: fileSystem),
            engine: runtime,
            portAllocator: FixedTestPortAllocator()
        )
        let connection = AuthenticatedHelperConnection(effectiveUserID: UInt32(getuid()))
        let handshake = try await coordinator.handshake(
            HelperHandshakeRequest(clientVersion: "test", clientBuild: "1"),
            connection: connection
        )
        let sessionID = try #require(handshake.sessionID)
        let coreA = try #require(CoreID(rawValue: "v1.19.28-r1"))
        let coreB = try #require(CoreID(rawValue: "v1.19.28-r2"))
        let configuration = Data(
            "mode: rule\nproxies: []\nproxy-groups: []\nrules: []\n".utf8
        )
        let hash = IntegrityValue.sha256Hex(of: configuration)
        let prepared = try await coordinator.prepareStart(
            PrepareStartRequest(
                sessionID: sessionID,
                configurationSize: configuration.count,
                configurationSHA256: hash,
                resources: [],
                tunSettings: TunSettings(dnsHijack: false),
                coreID: coreA
            ),
            connectionID: connection.connectionID
        )

        await #expect(throws: RootTransactionError.alreadyActive) {
            _ = try await coordinator.prepareStart(
                PrepareStartRequest(
                    sessionID: sessionID,
                    configurationSize: configuration.count,
                    configurationSHA256: hash,
                    resources: [],
                    tunSettings: TunSettings(dnsHijack: false),
                    coreID: coreB
                ),
                connectionID: connection.connectionID
            )
        }

        _ = try await coordinator.stageConfiguration(
            StageConfigurationRequest(
                sessionID: sessionID,
                transactionID: prepared.transactionID,
                expectedSize: configuration.count,
                expectedSHA256: hash
            ),
            configuration: configuration,
            connectionID: connection.connectionID
        )
        _ = try await coordinator.commitStart(
            CommitStartRequest(
                sessionID: sessionID,
                transactionID: prepared.transactionID
            ),
            connectionID: connection.connectionID
        )

        #expect(await runtime.startedCoreID() == coreA)
        #expect(await runtime.selectionHistory() == [coreA, coreA])
    }
}

private struct FixedTestPortAllocator: ControllerPortAllocating {
    func allocateLoopbackPort() throws -> UInt16 { 54_321 }
}

private actor SuspendedStartRuntimeController: PrivilegedRuntimeControlling {
    private let instanceID = UUID()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var eventLog: [String] = []

    func start(_: PrivilegedEngineStartContext) async throws -> PrivilegedEngineStartResult {
        eventLog.append("start-enter")
        await withCheckedContinuation { continuation in
            startContinuation = continuation
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        eventLog.append("start-return")
        return PrivilegedEngineStartResult(
            instanceID: instanceID,
            processID: 42,
            startedAt: .now,
            tunInterface: "utun-test"
        )
    }

    func waitUntilStartIsSuspended() async {
        if startContinuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func stop(instanceID _: UUID?, reason _: HelperStopReason) async throws {
        eventLog.append("stop")
    }

    func status() async -> PrivilegedEngineControllerStatus { .stopped }

    func readLogs(after _: UInt64, maximumEntries _: Int) async throws -> [HelperLogEntry] {
        []
    }

    func cleanup(mode _: PrivilegedCleanupMode, ownerUID _: UInt32) async throws {}

    func stopCallCount() -> Int { eventLog.filter { $0 == "stop" }.count }
    func events() -> [String] { eventLog }
}

private actor CoreBindingRuntimeController: PrivilegedRuntimeControlling,
    PrivilegedCoreRuntimeSelecting
{
    private var selectedCoreID: CoreID?
    private var selections: [CoreID] = []
    private var startedWithCoreID: CoreID?

    func selectCore(_ coreID: CoreID) {
        selectedCoreID = coreID
        selections.append(coreID)
    }

    func start(_ context: PrivilegedEngineStartContext) async throws
        -> PrivilegedEngineStartResult
    {
        // The transaction itself is independently bound to the same CoreID.
        guard selectedCoreID == context.transaction.coreID else {
            throw VelaHelperFailure(
                code: .invalidState,
                safeMessage: "The prepared Core binding was lost."
            )
        }
        startedWithCoreID = selectedCoreID
        return PrivilegedEngineStartResult(
            instanceID: UUID(),
            processID: 43,
            startedAt: .now,
            tunInterface: "utun-binding"
        )
    }

    func stop(instanceID _: UUID?, reason _: HelperStopReason) async throws {}
    func status() async -> PrivilegedEngineControllerStatus { .stopped }
    func readLogs(after _: UInt64, maximumEntries _: Int) async throws -> [HelperLogEntry] {
        []
    }
    func cleanup(mode _: PrivilegedCleanupMode, ownerUID _: UInt32) async throws {}

    func startedCoreID() -> CoreID? { startedWithCoreID }
    func selectionHistory() -> [CoreID] { selections }
}
