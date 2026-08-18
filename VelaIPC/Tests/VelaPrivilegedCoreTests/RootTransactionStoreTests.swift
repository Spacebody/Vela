import Darwin
import Foundation
import Testing
import VelaIPC
@testable import VelaPrivilegedCore

@Suite("Root transaction and FileHandle staging")
struct RootTransactionStoreTests {
    @Test("Prepare journals the exact CoreID selected for the transaction")
    func preparePersistsCoreBinding() async throws {
        try await withStore { store, _ in
            let sessionID = UUID()
            let coreID = try #require(CoreID(rawValue: "v1.19.28-r7"))
            let config = Data("mode: rule\n".utf8)
            let prepared = try await store.prepare(
                request: PrepareStartRequest(
                    sessionID: sessionID,
                    configurationSize: config.count,
                    configurationSHA256: IntegrityValue.sha256Hex(of: config),
                    resources: [],
                    tunSettings: TunSettings(dnsHijack: false),
                    coreID: coreID
                ),
                ownerUID: UInt32(getuid())
            )

            #expect(prepared.coreID == coreID)
            let recovered = try await store.recoveredRecord(
                transactionID: prepared.transactionID
            )
            #expect(recovered.coreID == coreID)
        }
    }

    @Test("Stages configuration and a regular resource by size and SHA")
    func stagesPackage() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            let config = Data("dns:\n  enable: true\n  nameserver: [1.1.1.1]\n".utf8)
            let resource = Data("proxies: []\n".utf8)
            let descriptor = PrivilegedResourceDescriptor(
                logicalID: "local-proxies",
                relativeDestination: "providers/proxies.yaml",
                expectedSize: resource.count,
                expectedSHA256: IntegrityValue.sha256Hex(of: resource),
                kind: .proxyProvider
            )
            let prepared = try await store.prepare(
                request: PrepareStartRequest(
                    sessionID: sessionID,
                    configurationSize: config.count,
                    configurationSHA256: IntegrityValue.sha256Hex(of: config),
                    resources: [descriptor],
                    tunSettings: .defaults
                ),
                ownerUID: UInt32(getuid())
            )
            try await store.stageConfiguration(
                request: StageConfigurationRequest(
                    sessionID: sessionID,
                    transactionID: prepared.transactionID,
                    expectedSize: config.count,
                    expectedSHA256: IntegrityValue.sha256Hex(of: config)
                ),
                configuration: config
            )

            try await withTemporaryFile(resource) { handle in
                try await store.stageResource(
                    request: StageResourceRequest(
                        sessionID: sessionID,
                        transactionID: prepared.transactionID,
                        logicalID: descriptor.logicalID,
                        relativeDestination: descriptor.relativeDestination,
                        expectedSize: descriptor.expectedSize,
                        expectedSHA256: descriptor.expectedSHA256,
                        kind: descriptor.kind
                    ),
                    file: handle
                )
            }

            let current = try #require(await store.current())
            #expect(current.phase == .readyForSanitization)
            #expect(current.configurationStaged)
            #expect(current.resources.allSatisfy { $0.isStaged })
            let resources = try await store.sanitizerResources(
                transactionID: prepared.transactionID,
                sessionID: sessionID
            )
            #expect(resources.map(\.runtimeRelativePath.description) == [
                "resources/providers/proxies.yaml"
            ])
        }
    }

    @Test("Promotion moves sanitized config and resources into one UUID generation")
    func promotionMovesRuntimePackageAtomically() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            let config = Data("mode: rule\n".utf8)
            let resource = Data("payload: root-owned\n".utf8)
            let descriptor = PrivilegedResourceDescriptor(
                logicalID: "local-provider",
                relativeDestination: "providers/local.yaml",
                expectedSize: resource.count,
                expectedSHA256: IntegrityValue.sha256Hex(of: resource),
                kind: .proxyProvider
            )
            let prepared = try await store.prepare(
                request: PrepareStartRequest(
                    sessionID: sessionID,
                    configurationSize: config.count,
                    configurationSHA256: IntegrityValue.sha256Hex(of: config),
                    resources: [descriptor],
                    tunSettings: TunSettings(dnsHijack: false)
                ),
                ownerUID: UInt32(getuid())
            )
            try await store.stageConfiguration(
                request: StageConfigurationRequest(
                    sessionID: sessionID,
                    transactionID: prepared.transactionID,
                    expectedSize: config.count,
                    expectedSHA256: IntegrityValue.sha256Hex(of: config)
                ),
                configuration: config
            )
            try await withTemporaryFile(resource) { handle in
                try await store.stageResource(
                    request: StageResourceRequest(
                        sessionID: sessionID,
                        transactionID: prepared.transactionID,
                        logicalID: descriptor.logicalID,
                        relativeDestination: descriptor.relativeDestination,
                        expectedSize: descriptor.expectedSize,
                        expectedSHA256: descriptor.expectedSHA256,
                        kind: descriptor.kind
                    ),
                    file: handle
                )
            }
            let sanitized = Data("mode: rule\ntun:\n  enable: true\n".utf8)
            try await store.markSanitized(
                transactionID: prepared.transactionID,
                sessionID: sessionID,
                data: sanitized,
                sha256: IntegrityValue.sha256Hex(of: sanitized)
            )
            let package = try await store.promoteSanitized(
                transactionID: prepared.transactionID,
                sessionID: sessionID
            )

            #expect(package.rootRelativePath.description
                == "users/\(getuid())/runtime/generations/"
                    + prepared.transactionID.uuidString.lowercased())
            #expect(!FileManager.default.fileExists(
                atPath: runtimeStateURL(root: root, record: prepared).path
            ))
            #expect(try Data(contentsOf: root.appending(
                path: package.configurationRelativePath.description
            )) == sanitized)
            #expect(try Data(contentsOf: root.appending(
                path: package.rootRelativePath.description
                    + "/resources/providers/local.yaml"
            )) == resource)
            let promotedIdentity = try openFileSystem(root).verifiedDirectoryIdentity(
                at: package.rootRelativePath
            )
            let stagedIdentity = try #require(prepared.runtimeStateIdentity)
            #expect(promotedIdentity.device == stagedIdentity.device)
            #expect(promotedIdentity.inode == stagedIdentity.inode)
        }
    }

    @Test("A hash mismatch never marks the resource staged")
    func rejectsHashMismatch() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            let config = Data("mode: rule\n".utf8)
            let resource = Data("rules: []\n".utf8)
            let claimedHash = String(repeating: "0", count: 64)
            let descriptor = PrivilegedResourceDescriptor(
                logicalID: "local-rules",
                relativeDestination: "providers/rules.yaml",
                expectedSize: resource.count,
                expectedSHA256: claimedHash,
                kind: .ruleProvider
            )
            let prepared = try await store.prepare(
                request: PrepareStartRequest(
                    sessionID: sessionID,
                    configurationSize: config.count,
                    configurationSHA256: IntegrityValue.sha256Hex(of: config),
                    resources: [descriptor],
                    tunSettings: TunSettings(dnsHijack: false)
                ),
                ownerUID: UInt32(getuid())
            )

            try await withTemporaryFile(resource) { handle in
                await #expect(throws: RootTransactionError.hashMismatch) {
                    try await store.stageResource(
                        request: StageResourceRequest(
                            sessionID: sessionID,
                            transactionID: prepared.transactionID,
                            logicalID: descriptor.logicalID,
                            relativeDestination: descriptor.relativeDestination,
                            expectedSize: descriptor.expectedSize,
                            expectedSHA256: descriptor.expectedSHA256,
                            kind: descriptor.kind
                        ),
                        file: handle
                    )
                }
            }
            let current = try #require(await store.current())
            #expect(current.resources.first?.isStaged == false)
            try await store.abort(
                transactionID: prepared.transactionID,
                sessionID: sessionID
            )
            #expect(!FileManager.default.fileExists(
                atPath: root.appending(
                    path: "users/\(getuid())/staging/"
                        + prepared.transactionID.uuidString.lowercased()
                ).path
            ))
        }
    }

    @Test("Abort removes only the transaction manifest paths and is bounded")
    func abortCleansStagingAndJournal() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            let config = Data("mode: rule\n".utf8)
            let prepared = try await store.prepare(
                request: PrepareStartRequest(
                    sessionID: sessionID,
                    configurationSize: config.count,
                    configurationSHA256: IntegrityValue.sha256Hex(of: config),
                    resources: [],
                    tunSettings: TunSettings(dnsHijack: false)
                ),
                ownerUID: UInt32(getuid())
            )
            try await store.stageConfiguration(
                request: StageConfigurationRequest(
                    sessionID: sessionID,
                    transactionID: prepared.transactionID,
                    expectedSize: config.count,
                    expectedSHA256: IntegrityValue.sha256Hex(of: config)
                ),
                configuration: config
            )
            // Simulate a crash after sanitized-file rename but before the
            // transaction manifest recorded its hash.
            let transactionName = prepared.transactionID.uuidString.lowercased()
            let unjournaledSanitized = root.appending(
                path: "users/\(getuid())/staging/\(transactionName)"
                    + "/runtime-state/config.sanitized.yaml"
            )
            try Data("secret: root-only\n".utf8).write(to: unjournaledSanitized)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: unjournaledSanitized.path
            )
            try await store.abort(
                transactionID: prepared.transactionID,
                sessionID: sessionID
            )
            #expect(await store.current() == nil)
            #expect(!FileManager.default.fileExists(
                atPath: root.appending(path: "transactions/\(transactionName).json").path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: root.appending(
                    path: "users/\(getuid())/staging/\(transactionName)"
                ).path
            ))
        }
    }

    @Test("Startup removes a valid abandoned transaction without trusting a client")
    func startupCleansAbandonedTransaction() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            let config = Data("mode: rule\n".utf8)
            let prepared = try await store.prepare(
                request: PrepareStartRequest(
                    sessionID: sessionID,
                    configurationSize: config.count,
                    configurationSHA256: IntegrityValue.sha256Hex(of: config),
                    resources: [],
                    tunSettings: TunSettings(dnsHijack: false)
                ),
                ownerUID: UInt32(getuid())
            )
            try await store.stageConfiguration(
                request: StageConfigurationRequest(
                    sessionID: sessionID,
                    transactionID: prepared.transactionID,
                    expectedSize: config.count,
                    expectedSHA256: IntegrityValue.sha256Hex(of: config)
                ),
                configuration: config
            )

            let restartedFileSystem = try POSIXRootFileSystem.openExisting(
                at: root,
                policy: PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
            )
            let restartedStore = RootTransactionStore(fileSystem: restartedFileSystem)
            try await restartedStore.cleanupAbandonedAtStartup()

            let transactionName = prepared.transactionID.uuidString.lowercased()
            #expect(!FileManager.default.fileExists(
                atPath: root.appending(path: "transactions/\(transactionName).json").path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: root.appending(
                    path: "users/\(getuid())/staging/\(transactionName)"
                ).path
            ))
        }
    }

    @Test("A failed first journal save leaves staging that startup proves and removes")
    func startupCleansPreJournalStaging() async throws {
        try await withStore(
            beforeTransactionJournalSave: { throw RootTransactionRecoveryFault.injected }
        ) { store, root in
            let config = Data("mode: rule\n".utf8)
            await #expect(throws: RootTransactionRecoveryFault.injected) {
                try await store.prepare(
                    request: PrepareStartRequest(
                        sessionID: UUID(),
                        configurationSize: config.count,
                        configurationSHA256: IntegrityValue.sha256Hex(of: config),
                        resources: [],
                        tunSettings: TunSettings(dnsHijack: false)
                    ),
                    ownerUID: UInt32(getuid())
                )
            }

            let staging = root.appending(path: "users/\(getuid())/staging")
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).count == 1)
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: root.appending(path: "transactions").path
            ).isEmpty)

            let restarted = RootTransactionStore(fileSystem: try openFileSystem(root))
            try await restarted.cleanupAbandonedAtStartup()
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }

    @Test("Startup removes an exact bounded atomic transaction temp left before rename")
    func startupCleansAtomicTransactionTemp() async throws {
        try await withStore { _, root in
            let fileSystem = try openFileSystem(root)
            let transactions = try SafeRelativePath("transactions")
            try fileSystem.createDirectory(transactions)
            let name = ".vela-\(UUID().uuidString.lowercased()).tmp"
            let temp = root.appending(path: "transactions/\(name)")
            try Data("partial-journal".utf8).write(to: temp)
            guard chmod(temp.path, 0o600) == 0 else {
                throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
            }

            let restarted = RootTransactionStore(fileSystem: try openFileSystem(root))
            try await restarted.cleanupAbandonedAtStartup()
            #expect(!FileManager.default.fileExists(atPath: temp.path))
        }
    }

    @Test("Startup removes an exact bounded generation-index temp")
    func startupCleansAtomicGenerationIndexTemp() async throws {
        try await withStore { _, root in
            let fileSystem = try openFileSystem(root)
            let runtime = try SafeRelativePath("users/\(getuid())/runtime")
            try fileSystem.createDirectory(runtime)
            let name = ".vela-\(UUID().uuidString.lowercased()).tmp"
            let temp = root.appending(path: "users/\(getuid())/runtime/\(name)")
            try Data("partial-index".utf8).write(to: temp)
            guard chmod(temp.path, 0o600) == 0 else {
                throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
            }

            let restarted = RootTransactionStore(fileSystem: try openFileSystem(root))
            try await restarted.cleanupAbandonedAtStartup()
            #expect(!FileManager.default.fileExists(atPath: temp.path))
        }
    }

    @Test("Unjournaled staging with a symlink is never treated as a crash artifact")
    func startupRejectsUnsafeUnjournaledStaging() async throws {
        try await withStore { _, root in
            let transactionID = UUID().uuidString.lowercased()
            let resources = try SafeRelativePath(
                "users/\(getuid())/staging/\(transactionID)/runtime-state/resources"
            )
            try openFileSystem(root).createDirectory(resources)
            let link = root.appending(
                path: "users/\(getuid())/staging/\(transactionID)"
                    + "/runtime-state/resources/unknown-link"
            )
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: URL(fileURLWithPath: "/tmp")
            )

            let restarted = RootTransactionStore(fileSystem: try openFileSystem(root))
            await #expect(throws: POSIXRootFileSystemError.symlinkRejected) {
                try await restarted.cleanupAbandonedAtStartup()
            }
            #expect(FileManager.default.fileExists(atPath: link.path))
        }
    }

    @Test("Near-match and symlink temp artifacts fail closed without deletion")
    func startupRejectsUnprovenAtomicTemps() async throws {
        try await withStore { _, root in
            let fileSystem = try openFileSystem(root)
            try fileSystem.createDirectory(try SafeRelativePath("transactions"))
            let nearMatch = root.appending(path: "transactions/.vela-not-a-uuid.tmp")
            try Data("unknown".utf8).write(to: nearMatch)
            guard chmod(nearMatch.path, 0o600) == 0 else {
                throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
            }

            let firstRestart = RootTransactionStore(fileSystem: try openFileSystem(root))
            await #expect(throws: RootTransactionError.invalidState) {
                try await firstRestart.cleanupAbandonedAtStartup()
            }
            #expect(FileManager.default.fileExists(atPath: nearMatch.path))

            try FileManager.default.removeItem(at: nearMatch)
            let exactName = ".vela-\(UUID().uuidString.lowercased()).tmp"
            let symlink = root.appending(path: "transactions/\(exactName)")
            try FileManager.default.createSymbolicLink(
                at: symlink,
                withDestinationURL: URL(fileURLWithPath: "/tmp")
            )
            let secondRestart = RootTransactionStore(fileSystem: try openFileSystem(root))
            await #expect(throws: POSIXRootFileSystemError.symlinkRejected) {
                try await secondRestart.cleanupAbandonedAtStartup()
            }
            #expect(FileManager.default.fileExists(atPath: symlink.path))
        }
    }

    @Test("Startup fails closed on an unknown transaction entry")
    func startupRejectsUnknownTransactionEntry() async throws {
        try await withStore { _, root in
            let transactionDirectory = root.appending(path: "transactions")
            try FileManager.default.createDirectory(
                at: transactionDirectory,
                withIntermediateDirectories: false
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: transactionDirectory.path
            )
            let unknownEntry = transactionDirectory.appending(path: "unknown.json")
            try Data("{}".utf8).write(to: unknownEntry)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: unknownEntry.path
            )

            let restartedFileSystem = try POSIXRootFileSystem.openExisting(
                at: root,
                policy: PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
            )
            let restartedStore = RootTransactionStore(fileSystem: restartedFileSystem)
            await #expect(throws: RootTransactionError.invalidState) {
                try await restartedStore.cleanupAbandonedAtStartup()
            }
            #expect(FileManager.default.fileExists(atPath: unknownEntry.path))
        }
    }

    @Test("Aborting staging removes bounded Mihomo cache files")
    func cleanupRemovesMihomoCacheDatabase() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            let config = Data("mode: rule\n".utf8)
            let prepared = try await store.prepare(
                request: PrepareStartRequest(
                    sessionID: sessionID,
                    configurationSize: config.count,
                    configurationSHA256: IntegrityValue.sha256Hex(of: config),
                    resources: [],
                    tunSettings: TunSettings(dnsHijack: false)
                ),
                ownerUID: UInt32(getuid())
            )
            try await store.stageConfiguration(
                request: StageConfigurationRequest(
                    sessionID: sessionID,
                    transactionID: prepared.transactionID,
                    expectedSize: config.count,
                    expectedSHA256: IntegrityValue.sha256Hex(of: config)
                ),
                configuration: config
            )
            let runtime = runtimeStateURL(root: root, record: prepared)
            let cache = runtime.appending(path: "cache.db")
            try Data(repeating: 0x43, count: 64 * 1_024).write(to: cache)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: cache.path
            )

            try await store.abort(
                transactionID: prepared.transactionID,
                sessionID: sessionID
            )
            #expect(!FileManager.default.fileExists(atPath: runtime.path))
        }
    }

    @Test("Committed runtime generations retain exactly current and previous")
    func committedGenerationRetention() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            var committedRecords: [RootTransactionRecord] = []
            for generation in 1...3 {
                let config = Data("generation: \(generation)\n".utf8)
                let record = try await preparePromotedGeneration(
                    store: store,
                    sessionID: sessionID,
                    config: config
                )
                try await store.markCommitted(
                    transactionID: record.transactionID,
                    sessionID: sessionID
                )
                committedRecords.append(try await store.recoveredRecord(
                    transactionID: record.transactionID
                ))
            }

            let runtime = root.appending(path: "users/\(getuid())/runtime")
            let index = try #require(await store.retainedGenerations(
                ownerUID: UInt32(getuid())
            ))
            #expect(index.revision == 3)
            #expect(index.current.transactionID == committedRecords[2].transactionID)
            #expect(index.previous?.transactionID == committedRecords[1].transactionID)
            let current = try Data(contentsOf: root.appending(
                path: index.current.relativePath.description
                    + "/config.sanitized.yaml"
            ))
            let previousDescriptor = try #require(index.previous)
            let previous = try Data(contentsOf: root.appending(
                path: previousDescriptor.relativePath.description
                    + "/config.sanitized.yaml"
            ))
            #expect(String(decoding: current, as: UTF8.self) == "generation: 3\n")
            #expect(String(decoding: previous, as: UTF8.self) == "generation: 2\n")
            #expect(!FileManager.default.fileExists(
                atPath: root.appending(
                    path: "transactions/"
                        + committedRecords[0].transactionID.uuidString.lowercased()
                        + ".json"
                ).path
            ))
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: runtime.appending(path: "generations").path
            ).sorted() == [
                committedRecords[1].transactionID.uuidString.lowercased(),
                committedRecords[2].transactionID.uuidString.lowercased(),
            ].sorted())
        }
    }

    @Test("Aborting a promoted generation leaves current and previous unchanged")
    func promotedAbortPreservesRetainedGenerations() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            var committedRecords: [RootTransactionRecord] = []
            for generation in 1...2 {
                let record = try await preparePromotedGeneration(
                    store: store,
                    sessionID: sessionID,
                    config: Data("generation: \(generation)\n".utf8)
                )
                try await store.markCommitted(
                    transactionID: record.transactionID,
                    sessionID: sessionID
                )
                committedRecords.append(try await store.recoveredRecord(
                    transactionID: record.transactionID
                ))
            }

            let rejected = try await preparePromotedGeneration(
                store: store,
                sessionID: sessionID,
                config: Data("generation: rejected\n".utf8)
            )
            try await store.abort(
                transactionID: rejected.transactionID,
                sessionID: sessionID
            )

            let index = try #require(await store.retainedGenerations(
                ownerUID: UInt32(getuid())
            ))
            #expect(index.current.transactionID == committedRecords[1].transactionID)
            #expect(index.previous?.transactionID == committedRecords[0].transactionID)
            let current = try Data(contentsOf: root.appending(
                path: index.current.relativePath.description
                    + "/config.sanitized.yaml"
            ))
            let previous = try Data(contentsOf: root.appending(
                path: try #require(index.previous).relativePath.description
                    + "/config.sanitized.yaml"
            ))
            #expect(String(decoding: current, as: UTF8.self) == "generation: 2\n")
            #expect(String(decoding: previous, as: UTF8.self) == "generation: 1\n")
            #expect(!FileManager.default.fileExists(
                atPath: root.appending(
                    path: "users/\(getuid())/runtime/generations/"
                        + rejected.transactionID.uuidString.lowercased()
                ).path
            ))
        }
    }

    @Test("Startup removes a sanitized candidate before generation rename")
    func crashBeforeGenerationRenameCleansStaging() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            let config = Data("generation: before-rename\n".utf8)
            let record = try await prepareSanitizedGeneration(
                store: store,
                sessionID: sessionID,
                config: config
            )

            let restarted = RootTransactionStore(fileSystem: try openFileSystem(root))
            try await restarted.cleanupAbandonedAtStartup()
            #expect(!FileManager.default.fileExists(
                atPath: runtimeStateURL(root: root, record: record).path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: generationURL(root: root, record: record).path
            ))
        }
    }

    @Test("Startup removes a generation renamed before promoted journal update")
    func crashAfterGenerationRenameCleansCandidate() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            var record = try await preparePromotedGeneration(
                store: store,
                sessionID: sessionID,
                config: Data("generation: after-rename\n".utf8)
            )
            let expectedIdentity = try #require(record.runtimeStateIdentity)
            let promotedIdentity = try openFileSystem(root).verifiedDirectoryIdentity(
                at: try #require(record.generationRelativePath)
            )
            #expect(promotedIdentity.device == expectedIdentity.device)
            #expect(promotedIdentity.inode == expectedIdentity.inode)
            #expect(promotedIdentity.userID == expectedIdentity.userID)
            #expect(promotedIdentity.groupID == expectedIdentity.groupID)
            #expect(promotedIdentity.permissions == expectedIdentity.permissions)
            record.phase = .sanitized
            record.generationRelativePath = nil
            try overwriteJournal(record, root: root)

            let restarted = RootTransactionStore(fileSystem: try openFileSystem(root))
            try await restarted.cleanupAbandonedAtStartup()
            #expect(!FileManager.default.fileExists(
                atPath: generationURL(root: root, record: record).path
            ))
        }
    }

    @Test("Startup completes committed journal written before generation index")
    func crashAfterCommittedJournalCompletesIndex() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            var record = try await preparePromotedGeneration(
                store: store,
                sessionID: sessionID,
                config: Data("generation: journal-only\n".utf8)
            )
            record.phase = .committed
            record.generationRevision = 1
            record.committedAt = Date(timeIntervalSince1970: 1_700_000_000)
            try overwriteJournal(record, root: root)

            let restarted = RootTransactionStore(fileSystem: try openFileSystem(root))
            try await restarted.cleanupAbandonedAtStartup()
            let index = try #require(await restarted.retainedGenerations(
                ownerUID: UInt32(getuid())
            ))
            #expect(index.revision == 1)
            #expect(index.current.transactionID == record.transactionID)
            #expect(index.previous == nil)
            #expect(FileManager.default.fileExists(
                atPath: generationURL(root: root, record: record).path
            ))
        }
    }

    @Test("An index write failure never wedges the same Helper process")
    func indexWriteFailureReconcilesBeforeNextPrepare() async throws {
        let fault = FailOnceGenerationIndexSave()
        try await withStore(beforeGenerationIndexSave: fault.intercept) { store, _ in
            let sessionID = UUID()
            let first = try await preparePromotedGeneration(
                store: store,
                sessionID: sessionID,
                config: Data("generation: durable-journal\n".utf8)
            )
            await #expect(throws: GenerationIndexTestError.injected) {
                try await store.markCommitted(
                    transactionID: first.transactionID,
                    sessionID: sessionID
                )
            }
            #expect(await store.current() == nil)

            let secondConfig = Data("generation: next-prepare\n".utf8)
            let second = try await store.prepare(
                request: PrepareStartRequest(
                    sessionID: sessionID,
                    configurationSize: secondConfig.count,
                    configurationSHA256: IntegrityValue.sha256Hex(of: secondConfig),
                    resources: [],
                    tunSettings: TunSettings(dnsHijack: false)
                ),
                ownerUID: UInt32(getuid())
            )
            let index = try #require(await store.retainedGenerations(
                ownerUID: UInt32(getuid())
            ))
            #expect(index.revision == 1)
            #expect(index.current.transactionID == first.transactionID)
            try await store.abort(
                transactionID: second.transactionID,
                sessionID: sessionID
            )
        }
    }

    @Test("Startup finishes bounded retirement after index commit")
    func crashAfterIndexCommitFinishesRetirement() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            var records: [RootTransactionRecord] = []
            for generation in 1...2 {
                let record = try await preparePromotedGeneration(
                    store: store,
                    sessionID: sessionID,
                    config: Data("generation: \(generation)\n".utf8)
                )
                try await store.markCommitted(
                    transactionID: record.transactionID,
                    sessionID: sessionID
                )
                records.append(try await store.recoveredRecord(
                    transactionID: record.transactionID
                ))
            }
            let retiredRoot = generationURL(root: root, record: records[0])
            let cache = retiredRoot.appending(path: "cache.db")
            try Data(repeating: 0x43, count: 64 * 1_024).write(to: cache)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: cache.path
            )
            let blocker = retiredRoot.appending(path: "cleanup-blocker")
            try FileManager.default.createSymbolicLink(
                at: blocker,
                withDestinationURL: URL(fileURLWithPath: "/tmp")
            )

            let third = try await preparePromotedGeneration(
                store: store,
                sessionID: sessionID,
                config: Data("generation: 3\n".utf8)
            )
            try await store.markCommitted(
                transactionID: third.transactionID,
                sessionID: sessionID
            )
            #expect(FileManager.default.fileExists(atPath: retiredRoot.path))
            try FileManager.default.removeItem(at: blocker)

            let restarted = RootTransactionStore(fileSystem: try openFileSystem(root))
            try await restarted.cleanupAbandonedAtStartup()
            #expect(!FileManager.default.fileExists(atPath: retiredRoot.path))
            let index = try #require(await restarted.retainedGenerations(
                ownerUID: UInt32(getuid())
            ))
            #expect(index.current.transactionID == third.transactionID)
            #expect(index.previous?.transactionID == records[1].transactionID)
        }
    }

    @Test("Unknown generation fails closed and is never recursively deleted")
    func unknownGenerationFailsClosed() async throws {
        try await withStore { store, root in
            let unknownID = UUID()
            let path = try SafeRelativePath(
                "users/\(getuid())/runtime/generations/"
                    + unknownID.uuidString.lowercased()
            )
            try openFileSystem(root).createDirectory(path)

            await #expect(throws: RootTransactionError.invalidState) {
                try await store.cleanupAbandonedAtStartup()
            }
            #expect(FileManager.default.fileExists(
                atPath: root.appending(path: path.description).path
            ))
        }
    }

    @Test("Process recovery keeps the committed generation and runtime cache")
    func processRecoveryRetainsCommittedGeneration() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            let promoted = try await preparePromotedGeneration(
                store: store,
                sessionID: sessionID,
                config: Data("generation: active\n".utf8)
            )
            try await store.markCommitted(
                transactionID: promoted.transactionID,
                sessionID: sessionID
            )
            let committed = try await store.recoveredRecord(
                transactionID: promoted.transactionID
            )
            let generation = generationURL(root: root, record: committed)
            let cache = generation.appending(path: "cache.db")
            try Data(repeating: 0x43, count: 64 * 1_024).write(to: cache)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: cache.path
            )

            let restarted = RootTransactionStore(fileSystem: try openFileSystem(root))
            // LivePrivilegedRuntimeController calls this only after the exact
            // journal-owned process and its interface/routes are gone.
            try await restarted.cleanupRecovered(
                transactionID: committed.transactionID
            )
            #expect(FileManager.default.fileExists(atPath: generation.path))
            #expect(FileManager.default.fileExists(atPath: cache.path))
        }
    }

    @Test("Runtime cleanup never follows an unknown symlink")
    func cleanupRejectsRuntimeSymlink() async throws {
        try await withStore { store, root in
            let sessionID = UUID()
            let config = Data("mode: rule\n".utf8)
            let prepared = try await store.prepare(
                request: PrepareStartRequest(
                    sessionID: sessionID,
                    configurationSize: config.count,
                    configurationSHA256: IntegrityValue.sha256Hex(of: config),
                    resources: [],
                    tunSettings: TunSettings(dnsHijack: false)
                ),
                ownerUID: UInt32(getuid())
            )
            let runtime = runtimeStateURL(root: root, record: prepared)
            try FileManager.default.createSymbolicLink(
                at: runtime.appending(path: "unknown-link"),
                withDestinationURL: URL(fileURLWithPath: "/tmp")
            )

            await #expect(throws: POSIXRootFileSystemError.symlinkRejected) {
                try await store.abort(
                    transactionID: prepared.transactionID,
                    sessionID: sessionID
                )
            }
            #expect(FileManager.default.fileExists(atPath: runtime.path))
        }
    }

    private func withStore(
        beforeTransactionJournalSave: @escaping @Sendable () throws -> Void = {},
        beforeGenerationIndexSave: @escaping @Sendable () throws -> Void = {},
        _ operation: (RootTransactionStore, URL) async throws -> Void
    ) async throws {
        let root = URL.temporaryDirectory.appending(path: "VelaTx-\(UUID().uuidString)")
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
        try await operation(
            RootTransactionStore(
                fileSystem: fileSystem,
                beforeTransactionJournalSave: beforeTransactionJournalSave,
                beforeGenerationIndexSave: beforeGenerationIndexSave
            ),
            root
        )
    }

    private func preparePromotedGeneration(
        store: RootTransactionStore,
        sessionID: UUID,
        config: Data
    ) async throws -> RootTransactionRecord {
        let record = try await prepareSanitizedGeneration(
            store: store,
            sessionID: sessionID,
            config: config
        )
        return try await store.promoteSanitized(
            transactionID: record.transactionID,
            sessionID: sessionID
        ).transaction
    }

    private func prepareSanitizedGeneration(
        store: RootTransactionStore,
        sessionID: UUID,
        config: Data
    ) async throws -> RootTransactionRecord {
        let record = try await store.prepare(
            request: PrepareStartRequest(
                sessionID: sessionID,
                configurationSize: config.count,
                configurationSHA256: IntegrityValue.sha256Hex(of: config),
                resources: [],
                tunSettings: TunSettings(dnsHijack: false)
            ),
            ownerUID: UInt32(getuid())
        )
        try await store.stageConfiguration(
            request: StageConfigurationRequest(
                sessionID: sessionID,
                transactionID: record.transactionID,
                expectedSize: config.count,
                expectedSHA256: IntegrityValue.sha256Hex(of: config)
            ),
            configuration: config
        )
        try await store.markSanitized(
            transactionID: record.transactionID,
            sessionID: sessionID,
            data: config,
            sha256: IntegrityValue.sha256Hex(of: config)
        )
        return try #require(await store.current())
    }

    private func withTemporaryFile(
        _ data: Data,
        _ operation: (FileHandle) async throws -> Void
    ) async throws {
        let url = URL.temporaryDirectory.appending(path: "VelaResource-\(UUID().uuidString)")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try await operation(handle)
    }

    private func runtimeStateURL(root: URL, record: RootTransactionRecord) -> URL {
        root.appending(
            path: "users/\(record.ownerUID)/staging/"
                + record.transactionID.uuidString.lowercased()
                + "/runtime-state"
        )
    }

    private func generationURL(root: URL, record: RootTransactionRecord) -> URL {
        root.appending(
            path: "users/\(record.ownerUID)/runtime/generations/"
                + record.transactionID.uuidString.lowercased()
        )
    }

    private func openFileSystem(_ root: URL) throws -> POSIXRootFileSystem {
        try POSIXRootFileSystem.openExisting(
            at: root,
            policy: PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
        )
    }

    private func overwriteJournal(
        _ record: RootTransactionRecord,
        root: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try openFileSystem(root).writeDataAtomically(
            try encoder.encode(record),
            to: try SafeRelativePath(
                "transactions/\(record.transactionID.uuidString.lowercased()).json"
            ),
            replacingExisting: true
        )
    }
}

private enum RootTransactionRecoveryFault: Error, Equatable {
    case injected
}

private enum GenerationIndexTestError: Error, Equatable {
    case injected
}

private final class FailOnceGenerationIndexSave: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func intercept() throws {
        lock.lock()
        defer { lock.unlock() }
        if shouldFail {
            shouldFail = false
            throw GenerationIndexTestError.injected
        }
    }
}
