import Darwin
import Foundation
import Testing
import VelaIPC
@testable import VelaPrivilegedCore

@Suite("Privileged Helper maintenance")
struct PrivilegedMaintenanceTests {
    @Test("Keep diagnostics removes every owner secret and retains only a clean journal")
    func keepDiagnosticsIsSecretFree() async throws {
        try await withCleanupFixture { fixture in
            try await fixture.engine.cleanup(
                mode: .keepDiagnosticMetadata,
                ownerUID: fixture.ownerUID
            )

            #expect(!FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "users/\(fixture.ownerUID)").path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "executables").path
            ))
            let journal = try #require(await fixture.journal.load())
            #expect(journal == RootRuntimeJournal())
            try expectNoSensitiveCleanupBytes(in: fixture.root)
        }
    }

    @Test("Remove runtime data removes owner secrets and diagnostic state")
    func removeRuntimeDataIsSecretFree() async throws {
        try await withCleanupFixture { fixture in
            try await fixture.engine.cleanup(
                mode: .removeRuntimeData,
                ownerUID: fixture.ownerUID
            )

            #expect(!FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "users/\(fixture.ownerUID)").path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "state").path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "executables").path
            ))
            #expect(try await fixture.journal.load() == nil)
            try expectNoSensitiveCleanupBytes(in: fixture.root)
        }
    }

    @Test("Owner cleanup preserves another UID and non-empty global containers")
    func cleanupIsOwnerScoped() async throws {
        try await withCleanupFixture(includeOtherOwner: true) { fixture in
            let otherOwnerUID = fixture.ownerUID + 1
            try await fixture.engine.cleanup(
                mode: .keepDiagnosticMetadata,
                ownerUID: fixture.ownerUID
            )

            #expect(!FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "users/\(fixture.ownerUID)").path
            ))
            let otherRoot = fixture.root.appending(path: "users/\(otherOwnerUID)")
            #expect(FileManager.default.fileExists(atPath: otherRoot.path))
            let otherBytes = try allRegularFileBytes(in: otherRoot)
            #expect(String(decoding: otherBytes, as: UTF8.self).contains(
                "other-user-secret-token"
            ))
            #expect(FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "transactions").path
            ))
            #expect(try await fixture.journal.load() == RootRuntimeJournal())
        }
    }

    @Test("Owner cleanup preflights every tree and never follows a symlink")
    func cleanupFailsClosedBeforeDeletingSecrets() async throws {
        try await withCleanupFixture { fixture in
            let generations = fixture.root.appending(
                path: "users/\(fixture.ownerUID)/runtime/generations"
            )
            let generation = try #require(
                FileManager.default.contentsOfDirectory(
                    at: generations,
                    includingPropertiesForKeys: nil
                ).first
            )
            try FileManager.default.createSymbolicLink(
                at: generation.appending(path: "malicious-link"),
                withDestinationURL: URL(fileURLWithPath: "/tmp")
            )

            await #expect(throws: POSIXRootFileSystemError.symlinkRejected) {
                try await fixture.engine.cleanup(
                    mode: .keepDiagnosticMetadata,
                    ownerUID: fixture.ownerUID
                )
            }
            let bytes = try allRegularFileBytes(
                in: fixture.root.appending(path: "users/\(fixture.ownerUID)")
            )
            #expect(String(decoding: bytes, as: UTF8.self).contains(
                "controller-secret"
            ))
            #expect(FileManager.default.fileExists(
                atPath: fixture.root.appending(path: "executables").path
            ))
        }
    }

    @Test("A dead owned Mihomo is cleaned even while its lease remains valid")
    func deadRuntimeDoesNotWaitForLeaseExpiry() async throws {
        let root = URL.temporaryDirectory
            .appending(path: "VelaMaintenance-\(UUID().uuidString)")
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
        let runtime = DeadAfterStartRuntimeController()
        let coordinator = PrivilegedHelperCoordinator(
            identity: PrivilegedHelperIdentity(
                signingIdentitySummary: "Team ID TEST",
                daemonUID: UInt32(geteuid())
            ),
            leases: OwnerLeaseCoordinator(),
            transactions: RootTransactionStore(fileSystem: fileSystem),
            engine: runtime,
            portAllocator: MaintenanceTestPortAllocator()
        )
        let connection = AuthenticatedHelperConnection(
            effectiveUserID: UInt32(getuid())
        )
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
        let started = try await coordinator.commitStart(
            CommitStartRequest(
                sessionID: sessionID,
                transactionID: prepared.transactionID
            ),
            connectionID: connection.connectionID
        )

        #expect(await coordinator.cleanupExpiredLeaseIfNeeded())
        #expect(await runtime.stoppedInstanceIDs() == [started.instanceID])
        #expect(await runtime.cleanupOwnerUIDs() == [UInt32(getuid())])

        let status = try await coordinator.status(
            HelperStatusRequest(sessionID: sessionID),
            connectionID: connection.connectionID
        )
        #expect(status.state == .stopped)
        #expect(status.processID == nil)
        #expect(!status.health.processRunning)
        #expect(status.lastStableErrorCode == .processStartFailed)
    }

    private func withCleanupFixture(
        includeOtherOwner: Bool = false,
        _ operation: (CleanupFixture) async throws -> Void
    ) async throws {
        let root = URL.temporaryDirectory
            .appending(path: "VelaCleanup-\(UUID().uuidString)")
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
        let ownerUID = UInt32(getuid())
        let journal = RootJournalStore(fileSystem: fileSystem)
        try await journal.prepare()
        try await journal.save(RootRuntimeJournal())
        let transactions = RootTransactionStore(fileSystem: fileSystem)
        try await commitCleanupGeneration(
            store: transactions,
            ownerUID: ownerUID,
            content: "controller-secret-current node-token-current"
        )
        try await commitCleanupGeneration(
            store: transactions,
            ownerUID: ownerUID,
            content: "controller-secret-previous node-token-previous"
        )
        if includeOtherOwner {
            try await commitCleanupGeneration(
                store: transactions,
                ownerUID: ownerUID + 1,
                content: "other-user-secret-token"
            )
        }

        // Leave a journal-backed staged input as a crash artifact. A fresh
        // actor has no in-memory active transaction, so uninstall cleanup must
        // remove both this staging tree and retained generations.
        let stagedSession = UUID()
        let stagedData = Data("controller-secret-staging node-token-staging".utf8)
        let staged = try await transactions.prepare(
            request: PrepareStartRequest(
                sessionID: stagedSession,
                configurationSize: stagedData.count,
                configurationSHA256: IntegrityValue.sha256Hex(of: stagedData),
                resources: [],
                tunSettings: TunSettings(dnsHijack: false)
            ),
            ownerUID: ownerUID
        )
        try await transactions.stageConfiguration(
            request: StageConfigurationRequest(
                sessionID: stagedSession,
                transactionID: staged.transactionID,
                expectedSize: stagedData.count,
                expectedSHA256: IntegrityValue.sha256Hex(of: stagedData)
            ),
            configuration: stagedData
        )

        let cleanupTransactions = RootTransactionStore(fileSystem: fileSystem)
        let executableStore = TrustedMihomoExecutableStore(fileSystem: fileSystem)
        let executable = try executableStore.installBundledExecutable(
            from: URL(fileURLWithPath: "/usr/bin/true")
        )
        let engine = LivePrivilegedRuntimeController(
            directories: PrivilegedDirectories(fileSystem: fileSystem),
            executableStore: executableStore,
            expectedHelperSignature: PrivilegedCodeSignature(
                signingIdentifier: VelaIPCConstants.helperIdentifier,
                teamIdentifier: "TESTTEAM01"
            ),
            journalStore: journal,
            transactionStore: cleanupTransactions,
            trustedExecutable: executable
        )
        try await operation(
            CleanupFixture(
                root: root,
                ownerUID: ownerUID,
                journal: journal,
                engine: engine
            )
        )
    }

    private func commitCleanupGeneration(
        store: RootTransactionStore,
        ownerUID: UInt32,
        content: String
    ) async throws {
        let sessionID = UUID()
        let data = Data(content.utf8)
        let record = try await store.prepare(
            request: PrepareStartRequest(
                sessionID: sessionID,
                configurationSize: data.count,
                configurationSHA256: IntegrityValue.sha256Hex(of: data),
                resources: [],
                tunSettings: TunSettings(dnsHijack: false)
            ),
            ownerUID: ownerUID
        )
        try await store.stageConfiguration(
            request: StageConfigurationRequest(
                sessionID: sessionID,
                transactionID: record.transactionID,
                expectedSize: data.count,
                expectedSHA256: IntegrityValue.sha256Hex(of: data)
            ),
            configuration: data
        )
        try await store.markSanitized(
            transactionID: record.transactionID,
            sessionID: sessionID,
            data: data,
            sha256: IntegrityValue.sha256Hex(of: data)
        )
        _ = try await store.promoteSanitized(
            transactionID: record.transactionID,
            sessionID: sessionID
        )
        try await store.markCommitted(
            transactionID: record.transactionID,
            sessionID: sessionID
        )
    }

    private func expectNoSensitiveCleanupBytes(in root: URL) throws {
        let text = String(decoding: try allRegularFileBytes(in: root), as: UTF8.self)
            .lowercased()
        #expect(!text.contains("controller-secret"))
        #expect(!text.contains("node-token"))
        #expect(!text.contains("credential"))
    }

    private func allRegularFileBytes(in root: URL) throws -> Data {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return Data()
        }
        var result = Data()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                result.append(try Data(contentsOf: url))
                result.append(0x0A)
            }
        }
        return result
    }
}

private struct CleanupFixture {
    let root: URL
    let ownerUID: UInt32
    let journal: RootJournalStore
    let engine: LivePrivilegedRuntimeController
}

private struct MaintenanceTestPortAllocator: ControllerPortAllocating {
    func allocateLoopbackPort() throws -> UInt16 { 54_322 }
}

private actor DeadAfterStartRuntimeController: PrivilegedRuntimeControlling {
    private var instanceID: UUID?
    private var stops: [UUID] = []
    private var cleanupUIDs: [UInt32] = []

    func start(
        _: PrivilegedEngineStartContext
    ) async throws -> PrivilegedEngineStartResult {
        let instanceID = UUID()
        self.instanceID = instanceID
        return PrivilegedEngineStartResult(
            instanceID: instanceID,
            processID: 42,
            startedAt: .now,
            tunInterface: "utun-test"
        )
    }

    func stop(instanceID: UUID?, reason _: HelperStopReason) async throws {
        if let instanceID { stops.append(instanceID) }
        self.instanceID = nil
    }

    func status() async -> PrivilegedEngineControllerStatus {
        guard let instanceID else { return .stopped }
        return PrivilegedEngineControllerStatus(
            state: .degraded,
            processID: 42,
            instanceID: instanceID,
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

    func readLogs(
        after _: UInt64,
        maximumEntries _: Int
    ) async throws -> [HelperLogEntry] {
        []
    }

    func cleanup(mode _: PrivilegedCleanupMode, ownerUID: UInt32) async throws {
        cleanupUIDs.append(ownerUID)
    }

    func stoppedInstanceIDs() -> [UUID] { stops }
    func cleanupOwnerUIDs() -> [UInt32] { cleanupUIDs }
}
