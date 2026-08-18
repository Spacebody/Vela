import Darwin
import Foundation

actor ReliabilityEvidenceStore {
    static let privateDirectoryPermissions = 0o700
    static let privateFilePermissions = 0o600
    static let defaultMaximumLedgerBytes = 8 * 1_024 * 1_024

    nonisolated let directoryURL: URL
    nonisolated let ledgerURL: URL
    nonisolated let quarantineDirectoryURL: URL
    nonisolated let sessionID: UUID

    private let identity: ReliabilityBuildIdentity
    private let retention: ReliabilityRetentionPolicy
    private let fileSystem: any ReliabilityFileSystemProviding
    private let clock: any ReliabilityClockProviding
    private let identifiers: any ReliabilityIdentifierProviding
    private let maximumLedgerBytes: Int
    private let expectedOwnerUserID: UInt32

    private var cachedLedger: ReliabilityEvidenceLedger?
    private var isLoaded = false

    init(
        rootDirectory: URL,
        identity: ReliabilityBuildIdentity,
        retention: ReliabilityRetentionPolicy = .default,
        fileSystem: any ReliabilityFileSystemProviding = LiveReliabilityFileSystem(),
        clock: any ReliabilityClockProviding = LiveReliabilityClock(),
        identifiers: any ReliabilityIdentifierProviding = LiveReliabilityIdentifierProvider(),
        maximumLedgerBytes: Int = ReliabilityEvidenceStore.defaultMaximumLedgerBytes,
        expectedOwnerUserID: UInt32 = getuid()
    ) {
        let directory = rootDirectory.standardizedFileURL.appendingPathComponent(
            "reliability-evidence",
            isDirectory: true
        )
        directoryURL = directory
        ledgerURL = directory.appendingPathComponent("ledger.json", isDirectory: false)
        quarantineDirectoryURL = directory.appendingPathComponent(
            "quarantine",
            isDirectory: true
        )
        sessionID = identifiers.makeIdentifier()
        self.identity = identity
        self.retention = retention
        self.fileSystem = fileSystem
        self.clock = clock
        self.identifiers = identifiers
        self.maximumLedgerBytes = max(1_024, maximumLedgerBytes)
        self.expectedOwnerUserID = expectedOwnerUserID
    }

    @discardableResult
    func record(_ draft: ReliabilityEventDraft) throws -> ReliabilityEvidence {
        try ensureLoaded()
        let now = clock.now()
        let event = ReliabilityEvidence(
            id: identifiers.makeIdentifier(),
            occurredAt: now,
            identity: identity,
            sessionID: sessionID,
            draft: draft
        )
        try event.validate(referenceDate: now)

        var candidate = cachedLedger ?? ReliabilityEvidenceLedger(
            retention: retention,
            events: []
        )
        candidate.events.append(event)
        candidate = pruned(candidate, at: now)
        try persist(candidate)
        cachedLedger = candidate
        return event
    }

    func events() throws -> [ReliabilityEvidence] {
        try ensureLoaded()
        return cachedLedger?.events ?? []
    }

    func aggregate() throws -> ReliabilityEvidenceAggregate {
        ReliabilityEvidenceExportBuilder.aggregate(try events())
    }

    func export(maximumRecentFailures: Int = 25) throws -> ReliabilityEvidenceExport {
        ReliabilityEvidenceExportBuilder.make(
            events: try events(),
            generatedAt: clock.now(),
            maximumRecentFailures: maximumRecentFailures
        )
    }

    func canonicalExportJSONData(maximumRecentFailures: Int = 25) throws -> Data {
        try export(maximumRecentFailures: maximumRecentFailures).canonicalJSONData()
    }

    func canonicalExportJSONString(maximumRecentFailures: Int = 25) throws -> String {
        try export(maximumRecentFailures: maximumRecentFailures).canonicalJSONString()
    }

    /// Removes both the active ledger and any quarantined corrupt payloads.
    func clear() throws {
        if let metadata = try inspect(directoryURL) {
            try validateDirectoryMetadata(metadata)
            do {
                try fileSystem.removeItem(at: directoryURL)
            } catch {
                throw ReliabilityEvidenceStoreError.clearFailed
            }
        }
        cachedLedger = ReliabilityEvidenceLedger(retention: retention, events: [])
        isLoaded = true
    }

    private func ensureLoaded() throws {
        guard !isLoaded else { return }
        try prepareDirectory(at: directoryURL)
        guard let metadata = try inspect(ledgerURL) else {
            cachedLedger = ReliabilityEvidenceLedger(retention: retention, events: [])
            isLoaded = true
            return
        }
        try validateLedgerMetadata(metadata)

        let data = try readVerifiedLedgerData(metadata: metadata)

        let decoded: ReliabilityEvidenceLedger
        do {
            try StrictJSONValidator.validateObject(data, shape: Self.ledgerShape)
            decoded = try ReliabilityEvidenceCoding.decoder().decode(
                ReliabilityEvidenceLedger.self,
                from: data
            )
            try decoded.validate(referenceDate: clock.now())
        } catch {
            try quarantineCorruptLedger()
            throw ReliabilityEvidenceStoreError.corruptLedgerQuarantined
        }

        let normalized = pruned(decoded, at: clock.now())
        if normalized != decoded || decoded.retention != retention {
            let currentPolicyLedger = ReliabilityEvidenceLedger(
                retention: retention,
                events: normalized.events
            )
            try persist(currentPolicyLedger)
            cachedLedger = currentPolicyLedger
        } else {
            cachedLedger = normalized
        }
        isLoaded = true
    }

    private func persist(_ ledger: ReliabilityEvidenceLedger) throws {
        let now = clock.now()
        try ledger.validate(referenceDate: now)
        try prepareDirectory(at: directoryURL)

        let data: Data
        do {
            data = try ReliabilityEvidenceCoding.encoder().encode(ledger)
        } catch {
            throw ReliabilityEvidenceStoreError.encodeFailed
        }
        guard data.count <= maximumLedgerBytes else {
            throw ReliabilityEvidenceStoreError.fileTooLarge
        }

        do {
            try fileSystem.writeDataAtomically(data, to: ledgerURL)
            try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: ledgerURL)
        } catch {
            throw ReliabilityEvidenceStoreError.writeFailed
        }

        guard let metadata = try inspect(ledgerURL) else {
            throw ReliabilityEvidenceStoreError.verificationFailed
        }
        try validateLedgerMetadata(metadata)
        let verified = try readVerifiedLedgerData(metadata: metadata)
        guard verified == data else {
            throw ReliabilityEvidenceStoreError.verificationFailed
        }
    }

    private func pruned(
        _ ledger: ReliabilityEvidenceLedger,
        at now: Date
    ) -> ReliabilityEvidenceLedger {
        let cutoff = now.addingTimeInterval(-Double(retention.maximumDays) * 86_400)
        let retainedByDate = ledger.events
            .filter { $0.occurredAt >= cutoff }
            .sorted(by: Self.oldestFirst)
        let retained = retainedByDate.count <= retention.maximumEvents
            ? retainedByDate
            : Array(retainedByDate.suffix(retention.maximumEvents))
        return ReliabilityEvidenceLedger(retention: retention, events: retained)
    }

    private func prepareDirectory(at url: URL) throws {
        do {
            if let existing = try inspect(url) {
                try validateDirectoryTypeAndOwner(existing)
            } else {
                try fileSystem.createDirectory(at: url)
            }
            try fileSystem.setPOSIXPermissions(Self.privateDirectoryPermissions, at: url)
            guard let prepared = try inspect(url) else {
                throw ReliabilityEvidenceStoreError.storagePreparationFailed
            }
            try validateDirectoryMetadata(prepared)
        } catch let error as ReliabilityEvidenceStoreError {
            throw error
        } catch {
            throw ReliabilityEvidenceStoreError.storagePreparationFailed
        }
    }

    private func quarantineCorruptLedger() throws {
        do {
            try prepareDirectory(at: quarantineDirectoryURL)
            let destination = quarantineDirectoryURL.appendingPathComponent(
                "ledger.corrupt.\(identifiers.makeIdentifier().uuidString.lowercased()).json",
                isDirectory: false
            )
            try fileSystem.moveItem(at: ledgerURL, to: destination)
            try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: destination)
            guard let metadata = try inspect(destination) else {
                throw ReliabilityEvidenceStoreError.quarantineFailed
            }
            try validateLedgerMetadata(metadata)
            cachedLedger = nil
            isLoaded = false
        } catch {
            throw ReliabilityEvidenceStoreError.quarantineFailed
        }
    }

    private func inspect(_ url: URL) throws -> ReliabilityFileMetadata? {
        do {
            return try fileSystem.metadata(at: url)
        } catch let error as ReliabilityEvidenceStoreError {
            throw error
        } catch {
            throw ReliabilityEvidenceStoreError.storageInspectionFailed
        }
    }

    private func validateDirectoryTypeAndOwner(
        _ metadata: ReliabilityFileMetadata
    ) throws {
        switch metadata.kind {
        case .directory:
            break
        case .symbolicLink:
            throw ReliabilityEvidenceStoreError.symbolicLinkRejected
        case .regular, .other:
            throw ReliabilityEvidenceStoreError.nonDirectoryRejected
        }
        guard metadata.ownerUserID == expectedOwnerUserID else {
            throw ReliabilityEvidenceStoreError.ownerMismatch
        }
    }

    private func validateDirectoryMetadata(_ metadata: ReliabilityFileMetadata) throws {
        try validateDirectoryTypeAndOwner(metadata)
        guard metadata.permissions == Self.privateDirectoryPermissions else {
            throw ReliabilityEvidenceStoreError.unsafePermissions
        }
    }

    private func validateLedgerMetadata(_ metadata: ReliabilityFileMetadata) throws {
        switch metadata.kind {
        case .regular:
            break
        case .symbolicLink:
            throw ReliabilityEvidenceStoreError.symbolicLinkRejected
        case .directory, .other:
            throw ReliabilityEvidenceStoreError.nonRegularFileRejected
        }
        guard metadata.ownerUserID == expectedOwnerUserID else {
            throw ReliabilityEvidenceStoreError.ownerMismatch
        }
        guard metadata.permissions == Self.privateFilePermissions else {
            throw ReliabilityEvidenceStoreError.unsafePermissions
        }
        guard metadata.size >= 0, metadata.size <= maximumLedgerBytes else {
            throw ReliabilityEvidenceStoreError.fileTooLarge
        }
    }

    private func readVerifiedLedgerData(
        metadata before: ReliabilityFileMetadata
    ) throws -> Data {
        let data: Data
        do {
            data = try fileSystem.readData(at: ledgerURL)
        } catch {
            throw ReliabilityEvidenceStoreError.readFailed
        }
        guard data.count <= maximumLedgerBytes else {
            throw ReliabilityEvidenceStoreError.fileTooLarge
        }
        guard let after = try inspect(ledgerURL) else {
            throw ReliabilityEvidenceStoreError.fileChangedDuringRead
        }
        try validateLedgerMetadata(after)
        guard before.device == after.device,
              before.inode == after.inode,
              before.size == after.size,
              Int64(data.count) == after.size
        else {
            throw ReliabilityEvidenceStoreError.fileChangedDuringRead
        }
        return data
    }

    private static func oldestFirst(
        _ lhs: ReliabilityEvidence,
        _ rhs: ReliabilityEvidence
    ) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static let ledgerShape = StrictJSONShape(
        allowedKeys: ["schemaVersion", "retention", "events"],
        objects: [
            "retention": StrictJSONShape(
                allowedKeys: ["maximumDays", "maximumEvents"]
            )
        ],
        arrays: [
            "events": StrictJSONShape(
                allowedKeys: Set(ReliabilityEvidence.CodingKeys.allCases.map(\.stringValue)),
                objects: [
                    "identity": StrictJSONShape(
                        allowedKeys: ["version", "build", "channel"]
                    ),
                    "resourceSummary": StrictJSONShape(
                        allowedKeys: [
                            "residentMemoryMiB", "openFileDescriptorCount", "threadCount",
                            "activeTaskCount", "socketCount",
                        ]
                    ),
                ]
            )
        ]
    )
}

nonisolated enum ReliabilityEvidenceStoreError: Error, Equatable, Sendable {
    case storageInspectionFailed
    case storagePreparationFailed
    case symbolicLinkRejected
    case nonDirectoryRejected
    case nonRegularFileRejected
    case ownerMismatch
    case unsafePermissions
    case fileTooLarge
    case readFailed
    case fileChangedDuringRead
    case corruptLedgerQuarantined
    case quarantineFailed
    case encodeFailed
    case writeFailed
    case verificationFailed
    case clearFailed
}

extension ReliabilityEvidenceStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .storageInspectionFailed: "Reliability storage could not be inspected."
        case .storagePreparationFailed: "Reliability storage could not be prepared."
        case .symbolicLinkRejected: "A reliability storage symbolic link was rejected."
        case .nonDirectoryRejected: "The reliability storage directory is invalid."
        case .nonRegularFileRejected: "The reliability evidence file is invalid."
        case .ownerMismatch: "Reliability storage has an unexpected owner."
        case .unsafePermissions: "Reliability storage permissions are unsafe."
        case .fileTooLarge: "The reliability evidence file exceeds its size limit."
        case .readFailed: "Reliability evidence could not be read."
        case .fileChangedDuringRead: "Reliability evidence changed while it was being read."
        case .corruptLedgerQuarantined: "Corrupt reliability evidence was quarantined."
        case .quarantineFailed: "Corrupt reliability evidence could not be quarantined."
        case .encodeFailed: "Reliability evidence could not be encoded."
        case .writeFailed: "Reliability evidence could not be saved."
        case .verificationFailed: "Saved reliability evidence could not be verified."
        case .clearFailed: "Reliability evidence could not be cleared."
        }
    }
}
