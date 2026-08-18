import CryptoKit
import Darwin
import Foundation
import VelaIPC

public enum RootTransactionPhase: String, Codable, Sendable {
    case prepared
    case staging
    case readyForSanitization
    case sanitized
    case promoted
    case committed
    case aborted
}

public struct RootTransactionResource: Codable, Equatable, Sendable {
    public let logicalID: String
    public let destination: SafeRelativePath
    public let expectedSize: Int
    public let expectedSHA256: String
    public let kind: PrivilegedResourceKind
    public var isStaged: Bool

    public var runtimeRelativePath: SafeRelativePath {
        get throws {
            try SafeRelativePath(components: ["resources"] + destination.components)
        }
    }
}

public struct RootTransactionRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4

    public let schemaVersion: Int
    public let transactionID: UUID
    public let sessionID: UUID
    public let ownerUID: UInt32
    /// The exact signed Core selected by the client for this start transaction.
    /// This is persisted in the root journal so commit/recovery never relies on
    /// mutable process-wide Core selection state.
    public let coreID: CoreID
    public let createdAt: Date
    public let expiresAt: Date
    public let expectedConfigurationSize: Int
    public let expectedConfigurationSHA256: String
    public var configurationStaged: Bool
    public var sanitizedConfigurationSHA256: String?
    public var resources: [RootTransactionResource]
    public let tunSettings: TunSettings
    public var runtimeStateIdentity: POSIXFileIdentity?
    public var generationRelativePath: SafeRelativePath?
    public var generationRevision: UInt64?
    public var committedAt: Date?
    public var phase: RootTransactionPhase
}

public struct RootRuntimeGeneration: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let ownerUID: UInt32
    public let relativePath: SafeRelativePath
    public let rootIdentity: POSIXFileIdentity
    public let configurationSHA256: String
    public let revision: UInt64
    public let committedAt: Date
}

public struct RootRuntimeGenerationIndex: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let ownerUID: UInt32
    public let revision: UInt64
    public let current: RootRuntimeGeneration
    public let previous: RootRuntimeGeneration?
}

public struct RootRuntimePackage: Equatable, Sendable {
    public let transaction: RootTransactionRecord
    public let rootRelativePath: SafeRelativePath
    public let configurationRelativePath: SafeRelativePath
}

public enum RootTransactionError: Error, Equatable, Sendable {
    case alreadyActive
    case notFound
    case wrongSession
    case invalidState
    case expired
    case invalidConfigurationSize
    case invalidResourceCount
    case invalidResourceSize
    case totalResourceSizeExceeded
    case duplicateLogicalID
    case duplicateDestination
    case descriptorMismatch
    case sourceNotRegularFile
    case sourceChanged
    case sizeMismatch
    case hashMismatch
    case resourcesIncomplete
    case generationRevisionOverflow
}

public actor RootTransactionStore {
    private struct OrphanStagingDirectory {
        let path: SafeRelativePath
        let identity: POSIXFileIdentity
    }

    private struct StartupCleanupPlan {
        var temporaryFiles: [SafeRelativePath] = []
        var orphanStagingDirectories: [OrphanStagingDirectory] = []
    }

    private struct OwnerCleanupPlan {
        var temporaryFiles: [SafeRelativePath] = []
        var trees: [OrphanStagingDirectory] = []
    }

    private static let maximumOrphanStagingDirectories = 16

    private let fileSystem: POSIXRootFileSystem
    private let now: @Sendable () -> Date
    private let beforeTransactionJournalSave: @Sendable () throws -> Void
    private let beforeGenerationIndexSave: @Sendable () throws -> Void
    private var active: RootTransactionRecord?

    public init(
        fileSystem: POSIXRootFileSystem,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileSystem = fileSystem
        self.now = now
        beforeTransactionJournalSave = {}
        beforeGenerationIndexSave = {}
    }

    init(
        fileSystem: POSIXRootFileSystem,
        now: @escaping @Sendable () -> Date = { .now },
        beforeTransactionJournalSave: @escaping @Sendable () throws -> Void = {},
        beforeGenerationIndexSave: @escaping @Sendable () throws -> Void
    ) {
        self.fileSystem = fileSystem
        self.now = now
        self.beforeTransactionJournalSave = beforeTransactionJournalSave
        self.beforeGenerationIndexSave = beforeGenerationIndexSave
    }

    public func prepare(
        request: PrepareStartRequest,
        ownerUID: UInt32,
        lifetime: TimeInterval = 300
    ) throws -> RootTransactionRecord {
        guard active == nil else { throw RootTransactionError.alreadyActive }
        try cleanupAbandonedState()
        guard request.configurationSize >= 0,
            request.configurationSize <= VelaIPCConstants.maximumConfigurationBytes
        else {
            throw RootTransactionError.invalidConfigurationSize
        }
        guard request.resources.count <= VelaIPCConstants.maximumResourceCount else {
            throw RootTransactionError.invalidResourceCount
        }
        let expectedConfigurationHash = try IntegrityValue.normalizedSHA256(
            request.configurationSHA256
        )
        let validatedSettings = try request.tunSettings.validated()

        var totalSize = 0
        var logicalIDs = Set<String>()
        var destinations = Set<SafeRelativePath>()
        var resources: [RootTransactionResource] = []
        resources.reserveCapacity(request.resources.count)
        for descriptor in request.resources {
            guard descriptor.expectedSize >= 0,
                descriptor.expectedSize <= VelaIPCConstants.maximumResourceBytes
            else {
                throw RootTransactionError.invalidResourceSize
            }
            let addition = totalSize.addingReportingOverflow(descriptor.expectedSize)
            guard !addition.overflow,
                addition.partialValue <= VelaIPCConstants.maximumResourceTotalBytes
            else {
                throw RootTransactionError.totalResourceSizeExceeded
            }
            totalSize = addition.partialValue
            guard !descriptor.logicalID.isEmpty,
                descriptor.logicalID.utf8.count <= 256,
                logicalIDs.insert(descriptor.logicalID).inserted
            else {
                throw RootTransactionError.duplicateLogicalID
            }
            let destination = try SafeRelativePath(descriptor.relativeDestination)
            guard destinations.insert(destination).inserted else {
                throw RootTransactionError.duplicateDestination
            }
            resources.append(
                RootTransactionResource(
                    logicalID: descriptor.logicalID,
                    destination: destination,
                    expectedSize: descriptor.expectedSize,
                    expectedSHA256: try IntegrityValue.normalizedSHA256(
                        descriptor.expectedSHA256
                    ),
                    kind: descriptor.kind,
                    isStaged: false
                )
            )
        }

        let transactionID = UUID()
        let createdAt = now()
        var record = RootTransactionRecord(
            schemaVersion: RootTransactionRecord.currentSchemaVersion,
            transactionID: transactionID,
            sessionID: request.sessionID,
            ownerUID: ownerUID,
            coreID: request.coreID,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(lifetime),
            expectedConfigurationSize: request.configurationSize,
            expectedConfigurationSHA256: expectedConfigurationHash,
            configurationStaged: false,
            sanitizedConfigurationSHA256: nil,
            resources: resources,
            tunSettings: validatedSettings,
            runtimeStateIdentity: nil,
            generationRelativePath: nil,
            generationRevision: nil,
            committedAt: nil,
            phase: .prepared
        )

        try prepareDirectories(for: record)
        record.runtimeStateIdentity = try fileSystem.identity(of: runtimeStateRoot(record))
        try save(record, replacingExisting: false)
        record.phase = .staging
        try save(record, replacingExisting: true)
        active = record
        return record
    }

    public func current() -> RootTransactionRecord? {
        active
    }

    public func recoveredRecord(transactionID: UUID) throws -> RootTransactionRecord {
        let data = try fileSystem.readData(
            at: try transactionJournalPath(transactionID),
            maximumBytes: VelaIPCConstants.maximumPayloadBytes
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(RootTransactionRecord.self, from: data)
        guard record.schemaVersion == RootTransactionRecord.currentSchemaVersion,
            record.transactionID == transactionID,
            try recordHasCanonicalGenerationPath(record)
        else {
            throw RootTransactionError.invalidState
        }
        return record
    }

    /// The live controller calls this only after identity-verifying and stopping
    /// the journal-owned process, then proving its interface and routes are gone.
    /// A committed revision may therefore finish its interrupted index swap;
    /// a non-committed candidate can be safely retired.
    public func cleanupRecovered(transactionID: UUID) throws {
        let record = try recoveredRecord(transactionID: transactionID)
        if record.phase == .committed {
            try reconcileCommittedRecord(record)
            try cleanupCommittedStaging(record)
        } else {
            try cleanupManifestPaths(record)
        }
        if active?.transactionID == transactionID { active = nil }
    }

    /// Replays the crash journal without inferring state from mutable path
    /// names. A committed record whose revision is exactly the next index
    /// revision completes the interrupted index swap. Older unreferenced
    /// records are retired; non-committed candidates are boundedly removed.
    public func cleanupAbandonedAtStartup() throws {
        try cleanupAbandonedState()
    }

    private func cleanupAbandonedState() throws {
        let (records, plan) = try startupRecoverySnapshot()

        // The snapshot preflights every recognized temp file and every complete
        // orphan tree before the first unlink. Each removal API repeats its
        // anchored no-follow ownership/type checks at mutation time.
        for path in plan.temporaryFiles {
            try fileSystem.removeFile(path)
        }
        for orphan in plan.orphanStagingDirectories {
            try fileSystem.removeBoundedTreeContents(
                at: orphan.path,
                expectedRootIdentity: orphan.identity
            )
            try fileSystem.removeEmptyDirectory(orphan.path)
        }

        for record in records where record.phase != .committed {
            try cleanupManifestPaths(record)
        }
        for record in records
            .filter({ $0.phase == .committed })
            .sorted(by: committedRevisionOrder)
        {
            try reconcileCommittedRecord(record)
            try cleanupCommittedStaging(record)
        }
        try verifyRetainedGenerationTrees(
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.transactionID, $0) })
        )
        active = nil
    }

    public func stageConfiguration(
        request: StageConfigurationRequest,
        configuration: Data
    ) throws {
        var record = try requireActive(
            transactionID: request.transactionID,
            sessionID: request.sessionID
        )
        guard record.phase == .staging else { throw RootTransactionError.invalidState }
        guard request.expectedSize == record.expectedConfigurationSize,
            try IntegrityValue.normalizedSHA256(request.expectedSHA256)
                == record.expectedConfigurationSHA256
        else {
            throw RootTransactionError.descriptorMismatch
        }
        guard configuration.count == record.expectedConfigurationSize else {
            throw RootTransactionError.sizeMismatch
        }
        guard IntegrityValue.sha256Hex(of: configuration) == record.expectedConfigurationSHA256 else {
            throw RootTransactionError.hashMismatch
        }

        try fileSystem.writeDataAtomically(
            configuration,
            to: try configurationInputPath(record),
            replacingExisting: false
        )
        record.configurationStaged = true
        if record.resources.allSatisfy(\.isStaged) {
            record.phase = .readyForSanitization
        }
        try save(record, replacingExisting: true)
        active = record
    }

    public func stageResource(
        request: StageResourceRequest,
        file: FileHandle
    ) throws {
        var record = try requireActive(
            transactionID: request.transactionID,
            sessionID: request.sessionID
        )
        guard record.phase == .staging || record.phase == .readyForSanitization else {
            throw RootTransactionError.invalidState
        }
        guard let index = record.resources.firstIndex(where: { $0.logicalID == request.logicalID }) else {
            throw RootTransactionError.descriptorMismatch
        }
        let expected = record.resources[index]
        guard expected.kind == request.kind,
            expected.destination.description == request.relativeDestination,
            expected.expectedSize == request.expectedSize,
            expected.expectedSHA256 == (try IntegrityValue.normalizedSHA256(request.expectedSHA256)),
            !expected.isStaged
        else {
            throw RootTransactionError.descriptorMismatch
        }

        let destination = try resourceStagingPath(record, resource: expected)
        if let parent = destination.deletingLastComponent {
            try fileSystem.createDirectory(parent)
        }
        try streamResource(file, expected: expected, destination: destination)

        record.resources[index].isStaged = true
        if record.configurationStaged, record.resources.allSatisfy(\.isStaged) {
            record.phase = .readyForSanitization
        }
        try save(record, replacingExisting: true)
        active = record
    }

    public func markSanitized(
        transactionID: UUID,
        sessionID: UUID,
        data: Data,
        sha256: String
    ) throws {
        var record = try requireActive(transactionID: transactionID, sessionID: sessionID)
        guard record.phase == .readyForSanitization else {
            throw RootTransactionError.resourcesIncomplete
        }
        let normalizedHash = try IntegrityValue.normalizedSHA256(sha256)
        guard IntegrityValue.sha256Hex(of: data) == normalizedHash else {
            throw RootTransactionError.hashMismatch
        }
        try fileSystem.writeDataAtomically(
            data,
            to: try sanitizedConfigurationPath(record),
            replacingExisting: false
        )
        record.sanitizedConfigurationSHA256 = normalizedHash
        record.phase = .sanitized
        try save(record, replacingExisting: true)
        active = record
    }

    /// Moves the candidate runtime into its immutable-name generation. The
    /// directory inode is preserved by one anchored, exclusive rename. The
    /// current/previous index is intentionally unchanged until Mihomo has
    /// passed validation and reached its initial healthy state.
    public func promoteSanitized(
        transactionID: UUID,
        sessionID: UUID
    ) throws -> RootRuntimePackage {
        var record = try requireActive(
            transactionID: transactionID,
            sessionID: sessionID
        )
        guard record.phase == .sanitized || record.phase == .promoted,
            let runtimeStateIdentity = record.runtimeStateIdentity
        else {
            throw RootTransactionError.invalidState
        }

        let generation = try generationRoot(record.ownerUID, record.transactionID)
        try fileSystem.createDirectory(try generationsRoot(record.ownerUID))
        let staged = try runtimeStateRoot(record)
        let stagedIdentity = try verifiedDirectoryIdentityIfPresent(staged)
        let generationIdentity = try verifiedDirectoryIdentityIfPresent(generation)
        switch (stagedIdentity, generationIdentity) {
        case let (.some(source), nil):
            guard sameFile(source, runtimeStateIdentity) else {
                throw RootTransactionError.invalidState
            }
            try fileSystem.moveDirectory(
                staged,
                to: generation,
                expectedIdentity: runtimeStateIdentity
            )
        case let (nil, .some(destination)):
            // Idempotent recovery for a crash after rename but before the
            // transaction journal recorded `.promoted`.
            guard sameFile(destination, runtimeStateIdentity) else {
                throw RootTransactionError.invalidState
            }
        default:
            throw RootTransactionError.invalidState
        }

        let configuration = try generation.appending("config.sanitized.yaml")
        guard let expectedHash = record.sanitizedConfigurationSHA256 else {
            throw RootTransactionError.invalidState
        }
        let bytes = try fileSystem.readData(
            at: configuration,
            maximumBytes: VelaIPCConstants.maximumConfigurationBytes
        )
        guard IntegrityValue.sha256Hex(of: bytes) == expectedHash else {
            throw RootTransactionError.hashMismatch
        }
        record.generationRelativePath = generation
        record.phase = .promoted
        try save(record, replacingExisting: true)
        active = record
        return RootRuntimePackage(
            transaction: record,
            rootRelativePath: generation,
            configurationRelativePath: configuration
        )
    }

    public func markCommitted(transactionID: UUID, sessionID: UUID) throws {
        var record: RootTransactionRecord
        if let active,
            active.transactionID == transactionID,
            active.sessionID == sessionID
        {
            record = active
        } else {
            record = try recoveredRecord(transactionID: transactionID)
            guard record.sessionID == sessionID else {
                throw RootTransactionError.wrongSession
            }
            if record.phase == .committed {
                try reconcileCommittedRecord(record)
                return
            }
        }
        guard record.phase == .promoted,
            let generation = record.generationRelativePath,
            let expectedIdentity = record.runtimeStateIdentity,
            let hash = record.sanitizedConfigurationSHA256,
            sameFile(
                try fileSystem.verifiedDirectoryIdentity(at: generation),
                expectedIdentity
            )
        else { throw RootTransactionError.invalidState }

        let prior = try loadGenerationIndex(ownerUID: record.ownerUID)
        let increment = (prior?.revision ?? 0).addingReportingOverflow(1)
        guard !increment.overflow else {
            throw RootTransactionError.generationRevisionOverflow
        }
        let revision = increment.partialValue
        let committedAt = now()
        record.phase = .committed
        record.generationRevision = revision
        record.committedAt = committedAt
        // The committed transaction record is the write-ahead journal for the
        // index swap. Startup completes revision N when the index is still N-1.
        try save(record, replacingExisting: true)
        // From this point the durable record, not actor memory, is authoritative.
        // Clear the active slot before the fallible index write so an in-process
        // retry/next prepare can replay revision N instead of remaining stuck in
        // `alreadyActive` until launchd restarts the Helper.
        active = nil

        let current = RootRuntimeGeneration(
            transactionID: record.transactionID,
            ownerUID: record.ownerUID,
            relativePath: generation,
            rootIdentity: expectedIdentity,
            configurationSHA256: hash,
            revision: revision,
            committedAt: committedAt
        )
        let retired = prior?.previous
        try saveGenerationIndex(
            RootRuntimeGenerationIndex(
                schemaVersion: RootRuntimeGenerationIndex.currentSchemaVersion,
                ownerUID: record.ownerUID,
                revision: revision,
                current: current,
                previous: prior?.current
            )
        )
        // The commit point is already durable. A bounded cleanup failure must
        // not turn a healthy running process into an ambiguous failed commit;
        // the retained journal makes the cleanup retryable at next prepare or
        // Helper startup.
        try? cleanupCommittedStaging(record)
        if let retired { try? removeRetiredGeneration(retired) }
    }

    /// Removes only paths declared by this transaction's manifest. It never
    /// recursively deletes an unknown tree and is safe to retry after a crash.
    public func abort(transactionID: UUID, sessionID: UUID) throws {
        var record: RootTransactionRecord
        if let current = active,
            current.transactionID == transactionID,
            current.sessionID == sessionID
        {
            record = current
        } else {
            throw RootTransactionError.notFound
        }
        guard record.phase != .committed else { throw RootTransactionError.invalidState }

        record.phase = .aborted
        try save(record, replacingExisting: true)
        active = record
        try cleanupManifestPaths(record)
        active = nil
    }

    public func retainedGenerations(
        ownerUID: UInt32
    ) throws -> RootRuntimeGenerationIndex? {
        try loadGenerationIndex(ownerUID: ownerUID)
    }

    /// Removes only generations backed by valid transaction journals for this
    /// owner. Unknown directory entries fail closed instead of being recursively
    /// deleted by an uninstall request.
    public func removeRetainedGenerations(ownerUID: UInt32) throws {
        guard active?.ownerUID != ownerUID else { throw RootTransactionError.alreadyActive }
        let allRecords = try allTransactionRecords()
        let records = allRecords.filter { $0.ownerUID == ownerUID }
        let byID = Dictionary(uniqueKeysWithValues: allRecords.map {
            ($0.transactionID, $0)
        })
        var cleanup = OwnerCleanupPlan()

        // Validate the complete owner-scoped tree before the first unlink. The
        // actual bounded removal repeats ownership, type, no-follow, device,
        // entry-count, depth, and byte-budget checks.
        var ownerPlan = StartupCleanupPlan()
        try preflightOwnerRoot(ownerUID: ownerUID, plan: &ownerPlan)
        cleanup.temporaryFiles = ownerPlan.temporaryFiles
        _ = try loadGenerationIndex(ownerUID: ownerUID)

        if let entries = try directoryEntriesIfPresent(try generationsRoot(ownerUID)) {
            for entry in entries {
                guard entry.isDirectory,
                    let transactionID = canonicalUUID(entry.name),
                    let record = byID[transactionID],
                    record.ownerUID == ownerUID,
                    let identity = record.runtimeStateIdentity,
                    record.generationRelativePath
                        == (try generationRoot(ownerUID, transactionID))
                else {
                    throw RootTransactionError.invalidState
                }
                let path = try generationRoot(ownerUID, transactionID)
                let actual = try fileSystem.verifiedDirectoryIdentity(at: path)
                guard sameFile(actual, identity) else {
                    throw RootTransactionError.invalidState
                }
                try fileSystem.validateBoundedTreeContents(
                    at: path,
                    expectedRootIdentity: identity
                )
                cleanup.trees.append(
                    OrphanStagingDirectory(path: path, identity: identity)
                )
            }
        }

        if let entries = try directoryEntriesIfPresent(
            try SafeRelativePath("users/\(ownerUID)/staging")
        ) {
            for entry in entries {
                guard entry.isDirectory,
                    let transactionID = canonicalUUID(entry.name)
                else {
                    throw RootTransactionError.invalidState
                }
                let path = try SafeRelativePath(
                    "users/\(ownerUID)/staging/\(entry.name)"
                )
                if let record = byID[transactionID] {
                    guard record.ownerUID == ownerUID else {
                        throw RootTransactionError.invalidState
                    }
                    if let expected = record.runtimeStateIdentity,
                        let actual = try verifiedDirectoryIdentityIfPresent(
                            try path.appending("runtime-state")
                        ),
                        !sameFile(actual, expected)
                    {
                        throw RootTransactionError.invalidState
                    }
                } else {
                    try validateUnmanifestStagingLayout(path)
                }
                let identity = try fileSystem.verifiedDirectoryIdentity(at: path)
                try fileSystem.validateBoundedTreeContents(
                    at: path,
                    expectedRootIdentity: identity
                )
                cleanup.trees.append(
                    OrphanStagingDirectory(path: path, identity: identity)
                )
            }
        }

        for tree in cleanup.trees {
            try fileSystem.removeBoundedTreeContents(
                at: tree.path,
                expectedRootIdentity: tree.identity
            )
            try fileSystem.removeEmptyDirectory(tree.path)
        }
        for path in cleanup.temporaryFiles {
            try fileSystem.removeFile(path)
        }
        for record in records {
            try removeFileIfPresent(try transactionJournalPath(record.transactionID))
        }
        try removeFileIfPresent(try generationIndexPath(ownerUID))
        try removeDirectoryIfPresent(try generationsRoot(ownerUID))
        try removeDirectoryIfPresent(try ownerRuntimeRoot(ownerUID))
        try removeDirectoryIfPresent(try SafeRelativePath("users/\(ownerUID)/staging"))
        try removeDirectoryIfPresent(try SafeRelativePath("users/\(ownerUID)"))
    }

    private func cleanupManifestPaths(_ record: RootTransactionRecord) throws {
        try removeFileIfPresent(try configurationInputPath(record))
        guard let runtimeStateIdentity = record.runtimeStateIdentity else {
            throw RootTransactionError.invalidState
        }

        if let retained = try loadGenerationIndex(ownerUID: record.ownerUID),
            retained.current.transactionID == record.transactionID
                || retained.previous?.transactionID == record.transactionID
        {
            throw RootTransactionError.invalidState
        }
        let staged = try runtimeStateRoot(record)
        let generation = try generationRoot(record.ownerUID, record.transactionID)
        let present = try [staged, generation].compactMap { path -> SafeRelativePath? in
            guard let identity = try verifiedDirectoryIdentityIfPresent(path) else { return nil }
            guard sameFile(identity, runtimeStateIdentity) else {
                throw RootTransactionError.invalidState
            }
            return path
        }
        guard present.count <= 1 else { throw RootTransactionError.invalidState }
        if let runtime = present.first {
            try fileSystem.removeBoundedTreeContents(
                at: runtime,
                expectedRootIdentity: runtimeStateIdentity
            )
            try fileSystem.removeEmptyDirectory(runtime)
        }
        try removeDirectoryIfPresent(try stagingRoot(record))
        try removeFileIfPresent(try transactionJournalPath(record.transactionID))
    }

    private func cleanupCommittedStaging(_ record: RootTransactionRecord) throws {
        guard record.phase == .committed else { throw RootTransactionError.invalidState }
        try removeFileIfPresent(try configurationInputPath(record))
        // A committed generation has already moved the runtime directory. If
        // the old location exists again, do not guess whether it is ours.
        if try verifiedDirectoryIdentityIfPresent(try runtimeStateRoot(record)) != nil {
            throw RootTransactionError.invalidState
        }
        try removeDirectoryIfPresent(try stagingRoot(record))
    }

    public func configurationData(
        transactionID: UUID,
        sessionID: UUID
    ) throws -> Data {
        let record = try requireActive(transactionID: transactionID, sessionID: sessionID)
        guard record.configurationStaged else { throw RootTransactionError.invalidState }
        return try fileSystem.readData(
            at: try configurationInputPath(record),
            maximumBytes: VelaIPCConstants.maximumConfigurationBytes
        )
    }

    public func sanitizerResources(
        transactionID: UUID,
        sessionID: UUID
    ) throws -> [SanitizerResource] {
        let record = try requireActive(transactionID: transactionID, sessionID: sessionID)
        guard record.resources.allSatisfy(\.isStaged) else {
            throw RootTransactionError.resourcesIncomplete
        }
        return try record.resources.map {
            SanitizerResource(
                logicalID: $0.logicalID,
                kind: $0.kind,
                runtimeRelativePath: try $0.runtimeRelativePath
            )
        }
    }

    private func requireActive(
        transactionID: UUID,
        sessionID: UUID
    ) throws -> RootTransactionRecord {
        guard let active else { throw RootTransactionError.notFound }
        guard active.transactionID == transactionID else { throw RootTransactionError.notFound }
        guard active.sessionID == sessionID else { throw RootTransactionError.wrongSession }
        guard now() <= active.expiresAt else { throw RootTransactionError.expired }
        return active
    }

    private func prepareDirectories(for record: RootTransactionRecord) throws {
        for path in [
            try SafeRelativePath("transactions"),
            try SafeRelativePath("users"),
            try SafeRelativePath("users/\(record.ownerUID)"),
            try SafeRelativePath("users/\(record.ownerUID)/staging"),
            try stagingRoot(record),
            try runtimeStateRoot(record),
            try runtimeStateRoot(record).appending("resources"),
        ] {
            try fileSystem.createDirectory(path)
        }
    }

    private func save(_ record: RootTransactionRecord, replacingExisting: Bool) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try beforeTransactionJournalSave()
        try fileSystem.writeDataAtomically(
            data,
            to: try transactionJournalPath(record.transactionID),
            replacingExisting: replacingExisting
        )
    }

    private func streamResource(
        _ file: FileHandle,
        expected: RootTransactionResource,
        destination: SafeRelativePath
    ) throws {
        let source = file.fileDescriptor
        var before = stat()
        guard fstat(source, &before) == 0 else {
            throw POSIXRootFileSystemError.systemCall(operation: "fstat", code: errno)
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw RootTransactionError.sourceNotRegularFile
        }
        guard before.st_size == Int64(expected.expectedSize) else {
            throw RootTransactionError.sizeMismatch
        }

        try fileSystem.withAtomicOutput(
            to: destination,
            replacingExisting: false
        ) { output in
            var hasher = SHA256()
            var offset: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while offset < Int64(expected.expectedSize) {
                let requested = min(buffer.count, expected.expectedSize - Int(offset))
                let count = pread(source, &buffer, requested, off_t(offset))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXRootFileSystemError.systemCall(operation: "pread", code: errno)
                }
                guard count > 0 else { throw RootTransactionError.sizeMismatch }
                try buffer.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else { return }
                    var written = 0
                    while written < count {
                        let result = Darwin.write(
                            output,
                            base.advanced(by: written),
                            count - written
                        )
                        if result < 0 {
                            if errno == EINTR { continue }
                            throw POSIXRootFileSystemError.systemCall(
                                operation: "write",
                                code: errno
                            )
                        }
                        written += result
                    }
                }
                hasher.update(data: Data(buffer[0..<count]))
                offset += Int64(count)
            }
            var extra: UInt8 = 0
            var extraCount: Int
            repeat {
                extraCount = pread(source, &extra, 1, off_t(offset))
            } while extraCount < 0 && errno == EINTR
            guard extraCount == 0 else { throw RootTransactionError.sizeMismatch }

            var after = stat()
            guard fstat(source, &after) == 0 else {
                throw POSIXRootFileSystemError.systemCall(operation: "fstat", code: errno)
            }
            guard before.st_dev == after.st_dev,
                before.st_ino == after.st_ino,
                before.st_size == after.st_size,
                before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            else {
                throw RootTransactionError.sourceChanged
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expected.expectedSHA256 else {
                throw RootTransactionError.hashMismatch
            }
        }
    }

    private func reconcileCommittedRecord(_ record: RootTransactionRecord) throws {
        guard record.phase == .committed,
            let revision = record.generationRevision,
            let committedAt = record.committedAt,
            let generation = record.generationRelativePath,
            let identity = record.runtimeStateIdentity,
            let hash = record.sanitizedConfigurationSHA256,
            generation == (try generationRoot(record.ownerUID, record.transactionID))
        else {
            throw RootTransactionError.invalidState
        }
        let descriptor = RootRuntimeGeneration(
            transactionID: record.transactionID,
            ownerUID: record.ownerUID,
            relativePath: generation,
            rootIdentity: identity,
            configurationSHA256: hash,
            revision: revision,
            committedAt: committedAt
        )
        let state = try loadGenerationIndex(ownerUID: record.ownerUID)
        if let state,
            state.current.transactionID == record.transactionID
                || state.previous?.transactionID == record.transactionID
        {
            let indexed = state.current.transactionID == record.transactionID
                ? state.current : state.previous
            guard indexed == descriptor,
                sameFile(
                    try fileSystem.verifiedDirectoryIdentity(at: generation),
                    identity
                )
            else { throw RootTransactionError.invalidState }
            return
        }

        if let state {
            let increment = state.revision.addingReportingOverflow(1)
            if !increment.overflow, revision == increment.partialValue {
                try validateGeneration(descriptor, ownerUID: record.ownerUID)
                try saveGenerationIndex(
                    RootRuntimeGenerationIndex(
                        schemaVersion: RootRuntimeGenerationIndex.currentSchemaVersion,
                        ownerUID: record.ownerUID,
                        revision: revision,
                        current: descriptor,
                        previous: state.current
                    )
                )
                if let retired = state.previous { try? removeRetiredGeneration(retired) }
            } else if revision <= state.revision {
                try removeRetiredGeneration(descriptor)
            } else {
                throw RootTransactionError.invalidState
            }
        } else {
            guard revision == 1 else { throw RootTransactionError.invalidState }
            try validateGeneration(descriptor, ownerUID: record.ownerUID)
            try saveGenerationIndex(
                RootRuntimeGenerationIndex(
                    schemaVersion: RootRuntimeGenerationIndex.currentSchemaVersion,
                    ownerUID: record.ownerUID,
                    revision: revision,
                    current: descriptor,
                    previous: nil
                )
            )
        }
    }

    private func loadGenerationIndex(
        ownerUID: UInt32
    ) throws -> RootRuntimeGenerationIndex? {
        let data: Data
        do {
            data = try fileSystem.readData(
                at: try generationIndexPath(ownerUID),
                maximumBytes: VelaIPCConstants.maximumPayloadBytes
            )
        } catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT { return nil }
            throw error
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(RootRuntimeGenerationIndex.self, from: data)
        guard state.schemaVersion == RootRuntimeGenerationIndex.currentSchemaVersion,
            state.ownerUID == ownerUID,
            state.revision > 0,
            state.current.revision == state.revision,
            state.previous?.revision ?? 0 < state.current.revision
        else {
            throw RootTransactionError.invalidState
        }
        try validateGeneration(state.current, ownerUID: ownerUID)
        if let previous = state.previous {
            guard previous.transactionID != state.current.transactionID else {
                throw RootTransactionError.invalidState
            }
            try validateGeneration(previous, ownerUID: ownerUID)
        }
        return state
    }

    private func saveGenerationIndex(_ state: RootRuntimeGenerationIndex) throws {
        guard state.schemaVersion == RootRuntimeGenerationIndex.currentSchemaVersion,
            state.revision > 0,
            state.current.ownerUID == state.ownerUID,
            state.current.revision == state.revision,
            state.previous?.ownerUID ?? state.ownerUID == state.ownerUID,
            state.previous?.revision ?? 0 < state.current.revision,
            state.previous?.transactionID != state.current.transactionID
        else {
            throw RootTransactionError.invalidState
        }
        try validateGeneration(state.current, ownerUID: state.ownerUID)
        if let previous = state.previous {
            try validateGeneration(previous, ownerUID: state.ownerUID)
        }
        try fileSystem.createDirectory(try ownerRuntimeRoot(state.ownerUID))
        let path = try generationIndexPath(state.ownerUID)
        let exists = try identityIfPresent(path) != nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try beforeGenerationIndexSave()
        try fileSystem.writeDataAtomically(
            try encoder.encode(state),
            to: path,
            replacingExisting: exists
        )
    }

    private func validateGeneration(
        _ generation: RootRuntimeGeneration,
        ownerUID: UInt32
    ) throws {
        guard generation.ownerUID == ownerUID,
            generation.revision > 0,
            generation.relativePath
                == (try generationRoot(ownerUID, generation.transactionID)),
            sameFile(
                try fileSystem.verifiedDirectoryIdentity(at: generation.relativePath),
                generation.rootIdentity
            ),
            try IntegrityValue.normalizedSHA256(generation.configurationSHA256)
                == generation.configurationSHA256
        else {
            throw RootTransactionError.invalidState
        }
        let configuration = try fileSystem.readData(
            at: try generation.relativePath.appending("config.sanitized.yaml"),
            maximumBytes: VelaIPCConstants.maximumConfigurationBytes
        )
        guard IntegrityValue.sha256Hex(of: configuration)
            == generation.configurationSHA256
        else {
            throw RootTransactionError.hashMismatch
        }
    }

    private func removeRetiredGeneration(
        _ generation: RootRuntimeGeneration
    ) throws {
        let record = try recoveredRecord(transactionID: generation.transactionID)
        guard record.phase == .committed,
            record.generationRevision == generation.revision,
            record.generationRelativePath == generation.relativePath,
            record.runtimeStateIdentity == generation.rootIdentity,
            record.sanitizedConfigurationSHA256 == generation.configurationSHA256,
            record.committedAt == generation.committedAt,
            generation.relativePath
                == (try generationRoot(generation.ownerUID, generation.transactionID))
        else {
            throw RootTransactionError.invalidState
        }
        try cleanupCommittedStaging(record)
        if let actual = try verifiedDirectoryIdentityIfPresent(generation.relativePath) {
            guard sameFile(actual, generation.rootIdentity) else {
                throw RootTransactionError.invalidState
            }
            try fileSystem.removeBoundedTreeContents(
                at: generation.relativePath,
                expectedRootIdentity: generation.rootIdentity
            )
            try fileSystem.removeEmptyDirectory(generation.relativePath)
        }
        try removeFileIfPresent(try transactionJournalPath(generation.transactionID))
    }

    private func startupRecoverySnapshot() throws -> (
        records: [RootTransactionRecord],
        plan: StartupCleanupPlan
    ) {
        var plan = StartupCleanupPlan()
        let records = try startupTransactionRecords(plan: &plan)
        let recordsByID = Dictionary(
            uniqueKeysWithValues: records.map { ($0.transactionID, $0) }
        )
        var owners = Set(records.map(\.ownerUID))
        owners.formUnion(try knownOwnerUIDs())

        for ownerUID in owners.sorted() {
            try preflightOwnerRoot(ownerUID: ownerUID, plan: &plan)
            guard let stagingEntries = try directoryEntriesIfPresent(
                try SafeRelativePath("users/\(ownerUID)/staging")
            ) else {
                continue
            }
            for entry in stagingEntries {
                guard entry.isDirectory,
                    let transactionID = canonicalUUID(entry.name)
                else {
                    throw RootTransactionError.invalidState
                }
                if let record = recordsByID[transactionID] {
                    guard record.ownerUID == ownerUID else {
                        throw RootTransactionError.invalidState
                    }
                    continue
                }

                guard plan.orphanStagingDirectories.count
                    < Self.maximumOrphanStagingDirectories
                else {
                    throw POSIXRootFileSystemError.treeLimitExceeded
                }
                let path = try SafeRelativePath(
                    "users/\(ownerUID)/staging/\(entry.name)"
                )
                try validateUnmanifestStagingLayout(path)
                let identity = try fileSystem.verifiedDirectoryIdentity(at: path)
                try fileSystem.validateBoundedTreeContents(
                    at: path,
                    expectedRootIdentity: identity
                )
                plan.orphanStagingDirectories.append(
                    OrphanStagingDirectory(path: path, identity: identity)
                )
            }
        }
        return (records, plan)
    }

    private func startupTransactionRecords(
        plan: inout StartupCleanupPlan
    ) throws -> [RootTransactionRecord] {
        let directory = try SafeRelativePath("transactions")
        guard let entries = try directoryEntriesIfPresent(directory) else { return [] }
        var records: [RootTransactionRecord] = []
        records.reserveCapacity(entries.count)
        for entry in entries {
            if RootAtomicTemporaryArtifact.isExactName(entry.name) {
                plan.temporaryFiles.append(try RootAtomicTemporaryArtifact.validate(
                    entry,
                    in: directory,
                    fileSystem: fileSystem,
                    maximumBytes: Int64(VelaIPCConstants.maximumPayloadBytes)
                ))
                continue
            }
            guard entry.isRegularFile,
                entry.name.hasSuffix(".json")
            else {
                throw RootTransactionError.invalidState
            }
            let stem = String(entry.name.dropLast(".json".count))
            guard let transactionID = canonicalUUID(stem) else {
                throw RootTransactionError.invalidState
            }
            records.append(try recoveredRecord(transactionID: transactionID))
        }
        return records
    }

    private func preflightOwnerRoot(
        ownerUID: UInt32,
        plan: inout StartupCleanupPlan
    ) throws {
        let ownerRoot = try SafeRelativePath("users/\(ownerUID)")
        if let entries = try directoryEntriesIfPresent(ownerRoot) {
            for entry in entries {
                guard (entry.name == "staging" || entry.name == "runtime"),
                    entry.isDirectory
                else {
                    throw RootTransactionError.invalidState
                }
            }
        }

        let runtime = try ownerRuntimeRoot(ownerUID)
        guard let runtimeEntries = try directoryEntriesIfPresent(runtime) else { return }
        for entry in runtimeEntries {
            switch entry.name {
            case "generations":
                guard entry.isDirectory else { throw RootTransactionError.invalidState }
            case "generation-index.json":
                guard entry.isRegularFile else { throw RootTransactionError.invalidState }
                _ = try fileSystem.verifiedRegularFileIdentity(
                    at: try runtime.appending(entry.name),
                    maximumBytes: Int64(VelaIPCConstants.maximumPayloadBytes)
                )
            default:
                guard RootAtomicTemporaryArtifact.isExactName(entry.name) else {
                    throw RootTransactionError.invalidState
                }
                plan.temporaryFiles.append(try RootAtomicTemporaryArtifact.validate(
                    entry,
                    in: runtime,
                    fileSystem: fileSystem,
                    maximumBytes: Int64(VelaIPCConstants.maximumPayloadBytes)
                ))
            }
        }
    }

    /// A staging UUID without a matching journal can only be created before the
    /// first transaction save. At that point `prepareDirectories` may have made
    /// a prefix of this empty directory skeleton, but no configuration or
    /// resource file can legitimately exist yet.
    private func validateUnmanifestStagingLayout(_ path: SafeRelativePath) throws {
        let stagingEntries = try fileSystem.directoryEntries(at: path, maximumCount: 2)
        guard stagingEntries.isEmpty
            || (stagingEntries.count == 1
                && stagingEntries[0].name == "runtime-state"
                && stagingEntries[0].isDirectory)
        else {
            throw RootTransactionError.invalidState
        }
        guard !stagingEntries.isEmpty else { return }

        let runtime = try path.appending("runtime-state")
        let runtimeEntries = try fileSystem.directoryEntries(at: runtime, maximumCount: 2)
        guard runtimeEntries.isEmpty
            || (runtimeEntries.count == 1
                && runtimeEntries[0].name == "resources"
                && runtimeEntries[0].isDirectory)
        else {
            throw RootTransactionError.invalidState
        }
        guard !runtimeEntries.isEmpty else { return }

        let resources = try runtime.appending("resources")
        guard try fileSystem.directoryEntries(at: resources, maximumCount: 1).isEmpty else {
            throw RootTransactionError.invalidState
        }
    }

    private func canonicalUUID(_ value: String) -> UUID? {
        guard let uuid = UUID(uuidString: value),
            value == uuid.uuidString.lowercased()
        else {
            return nil
        }
        return uuid
    }

    private func allTransactionRecords() throws -> [RootTransactionRecord] {
        var plan = StartupCleanupPlan()
        // Atomic transaction temps cannot be attributed to an owner until
        // their rename commits. Validate them, but never delete them as a side
        // effect of one user's uninstall cleanup.
        return try startupTransactionRecords(plan: &plan)
    }

    private func verifyRetainedGenerationTrees(
        records: [UUID: RootTransactionRecord]
    ) throws {
        var owners = Set(records.values.map(\.ownerUID))
        owners.formUnion(try knownOwnerUIDs())
        for ownerUID in owners {
            let state = try loadGenerationIndex(ownerUID: ownerUID)
            let retained = Set([
                state?.current.transactionID,
                state?.previous?.transactionID,
            ].compactMap { $0 })
            for transactionID in retained {
                guard let record = records[transactionID], record.phase == .committed else {
                    throw RootTransactionError.invalidState
                }
            }
            guard let entries = try directoryEntriesIfPresent(try generationsRoot(ownerUID))
            else {
                if !retained.isEmpty { throw RootTransactionError.invalidState }
                continue
            }
            for entry in entries {
                guard entry.isDirectory,
                    let transactionID = UUID(uuidString: entry.name)
                else {
                    throw RootTransactionError.invalidState
                }
                if retained.contains(transactionID) { continue }
                guard let record = records[transactionID],
                    record.phase == .committed,
                    let revision = record.generationRevision,
                    revision <= (state?.revision ?? 0),
                    let committedAt = record.committedAt,
                    let path = record.generationRelativePath,
                    let identity = record.runtimeStateIdentity,
                    let hash = record.sanitizedConfigurationSHA256
                else {
                    throw RootTransactionError.invalidState
                }
                try removeRetiredGeneration(
                    RootRuntimeGeneration(
                        transactionID: transactionID,
                        ownerUID: ownerUID,
                        relativePath: path,
                        rootIdentity: identity,
                        configurationSHA256: hash,
                        revision: revision,
                        committedAt: committedAt
                    )
                )
            }
        }
    }

    private func knownOwnerUIDs() throws -> Set<UInt32> {
        guard let entries = try directoryEntriesIfPresent(try SafeRelativePath("users"))
        else { return [] }
        var owners = Set<UInt32>()
        for entry in entries {
            guard entry.isDirectory,
                let owner = UInt32(entry.name),
                entry.name == String(owner)
            else {
                throw RootTransactionError.invalidState
            }
            owners.insert(owner)
        }
        return owners
    }

    private func recordHasCanonicalGenerationPath(
        _ record: RootTransactionRecord
    ) throws -> Bool {
        if let hash = record.sanitizedConfigurationSHA256 {
            guard try IntegrityValue.normalizedSHA256(hash) == hash else { return false }
        }
        let expected = try generationRoot(record.ownerUID, record.transactionID)
        switch record.phase {
        case .prepared, .staging, .readyForSanitization, .sanitized:
            return record.generationRelativePath == nil
                && record.generationRevision == nil
                && record.committedAt == nil
        case .promoted:
            return record.generationRelativePath == expected
                && record.generationRevision == nil
                && record.committedAt == nil
        case .committed:
            return record.generationRelativePath == expected
                && (record.generationRevision ?? 0) > 0
                && record.committedAt != nil
        case .aborted:
            return (record.generationRelativePath == nil
                || record.generationRelativePath == expected)
                && record.generationRevision == nil
                && record.committedAt == nil
        }
    }

    private func committedRevisionOrder(
        _ lhs: RootTransactionRecord,
        _ rhs: RootTransactionRecord
    ) -> Bool {
        let left = lhs.generationRevision ?? UInt64.max
        let right = rhs.generationRevision ?? UInt64.max
        if left != right { return left < right }
        return lhs.transactionID.uuidString < rhs.transactionID.uuidString
    }

    private func removeBoundedDirectoryIfPresent(
        _ path: SafeRelativePath,
        expectedIdentity: POSIXFileIdentity? = nil
    ) throws {
        guard let identity = try verifiedDirectoryIdentityIfPresent(path) else { return }
        if let expectedIdentity, !sameFile(identity, expectedIdentity) {
            throw RootTransactionError.invalidState
        }
        try fileSystem.removeBoundedTreeContents(
            at: path,
            expectedRootIdentity: identity
        )
        try fileSystem.removeEmptyDirectory(path)
    }

    private func identityIfPresent(
        _ path: SafeRelativePath
    ) throws -> POSIXFileIdentity? {
        do {
            return try fileSystem.identity(of: path)
        } catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT { return nil }
            throw error
        }
    }

    private func verifiedDirectoryIdentityIfPresent(
        _ path: SafeRelativePath
    ) throws -> POSIXFileIdentity? {
        do {
            return try fileSystem.verifiedDirectoryIdentity(at: path)
        } catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT { return nil }
            throw error
        }
    }

    private func directoryEntriesIfPresent(
        _ path: SafeRelativePath
    ) throws -> [POSIXDirectoryEntry]? {
        do {
            return try fileSystem.directoryEntries(
                at: path,
                maximumCount: VelaIPCConstants.maximumResourceCount + 16
            )
        } catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT { return nil }
            throw error
        }
    }

    private func sameFile(
        _ lhs: POSIXFileIdentity,
        _ rhs: POSIXFileIdentity
    ) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.userID == rhs.userID
            && lhs.groupID == rhs.groupID
            && lhs.permissions == rhs.permissions
    }

    private func ownerRuntimeRoot(_ ownerUID: UInt32) throws -> SafeRelativePath {
        try SafeRelativePath("users/\(ownerUID)/runtime")
    }

    private func generationsRoot(_ ownerUID: UInt32) throws -> SafeRelativePath {
        try ownerRuntimeRoot(ownerUID).appending("generations")
    }

    private func generationRoot(
        _ ownerUID: UInt32,
        _ transactionID: UUID
    ) throws -> SafeRelativePath {
        try generationsRoot(ownerUID).appending(transactionID.uuidString.lowercased())
    }

    private func generationIndexPath(_ ownerUID: UInt32) throws -> SafeRelativePath {
        try ownerRuntimeRoot(ownerUID).appending("generation-index.json")
    }

    private func stagingRoot(_ record: RootTransactionRecord) throws -> SafeRelativePath {
        try SafeRelativePath(
            "users/\(record.ownerUID)/staging/\(record.transactionID.uuidString.lowercased())"
        )
    }

    private func configurationInputPath(
        _ record: RootTransactionRecord
    ) throws -> SafeRelativePath {
        try stagingRoot(record).appending("config.input.yaml")
    }

    private func sanitizedConfigurationPath(
        _ record: RootTransactionRecord
    ) throws -> SafeRelativePath {
        try runtimeStateRoot(record).appending("config.sanitized.yaml")
    }

    private func resourceStagingPath(
        _ record: RootTransactionRecord,
        resource: RootTransactionResource
    ) throws -> SafeRelativePath {
        try SafeRelativePath(
            components: runtimeStateRoot(record).components
                + ["resources"]
                + resource.destination.components
        )
    }

    private func runtimeStateRoot(_ record: RootTransactionRecord) throws -> SafeRelativePath {
        try stagingRoot(record).appending("runtime-state")
    }

    private func transactionJournalPath(_ transactionID: UUID) throws -> SafeRelativePath {
        try SafeRelativePath("transactions/\(transactionID.uuidString.lowercased()).json")
    }

    private func removeFileIfPresent(_ path: SafeRelativePath) throws {
        do {
            try fileSystem.removeFile(path)
        } catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT { return }
            throw error
        }
    }

    private func removeDirectoryIfPresent(_ path: SafeRelativePath) throws {
        do {
            try fileSystem.removeEmptyDirectory(path)
        } catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT { return }
            throw error
        }
    }
}

public struct SanitizerResource: Equatable, Sendable {
    public let logicalID: String
    public let kind: PrivilegedResourceKind
    public let runtimeRelativePath: SafeRelativePath

    public init(
        logicalID: String,
        kind: PrivilegedResourceKind,
        runtimeRelativePath: SafeRelativePath
    ) {
        self.logicalID = logicalID
        self.kind = kind
        self.runtimeRelativePath = runtimeRelativePath
    }
}
