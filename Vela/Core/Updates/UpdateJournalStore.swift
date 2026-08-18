import Darwin
import Foundation

nonisolated enum UpdateJournalFileKind: Equatable, Sendable {
    case regular
    case directory
    case symbolicLink
    case other
}

nonisolated struct UpdateJournalFileMetadata: Equatable, Sendable {
    let kind: UpdateJournalFileKind
    let permissions: Int
    let ownerUserID: UInt32
    let size: Int64
    let device: UInt64
    let inode: UInt64
}

nonisolated protocol UpdateJournalFileInspecting: Sendable {
    func metadata(at url: URL) throws -> UpdateJournalFileMetadata?
}

nonisolated struct LiveUpdateJournalFileInspector: UpdateJournalFileInspecting, Sendable {
    func metadata(at url: URL) throws -> UpdateJournalFileMetadata? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw UpdateJournalStoreError.fileInspectionFailed
        }

        let kind: UpdateJournalFileKind = switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): .regular
        case mode_t(S_IFDIR): .directory
        case mode_t(S_IFLNK): .symbolicLink
        default: .other
        }
        return UpdateJournalFileMetadata(
            kind: kind,
            permissions: Int(status.st_mode & 0o7777),
            ownerUserID: status.st_uid,
            size: Int64(status.st_size),
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }
}

actor UpdateJournalStore {
    static let privateDirectoryPermissions = 0o700
    static let privateFilePermissions = 0o600

    nonisolated let directoryURL: URL
    nonisolated let journalURL: URL

    private let rootURL: URL
    private let directories: ApplicationDirectories
    private let fileSystem: any FileSystemProviding
    private let inspector: any UpdateJournalFileInspecting
    private let maximumBytes: Int
    private let expectedOwnerUserID: UInt32

    init(
        directories: ApplicationDirectories,
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        inspector: any UpdateJournalFileInspecting = LiveUpdateJournalFileInspector(),
        maximumBytes: Int = UpdateJournal.maximumEncodedBytes,
        expectedOwnerUserID: UInt32 = getuid()
    ) {
        self.directories = directories
        self.fileSystem = fileSystem
        self.inspector = inspector
        self.maximumBytes = max(1, maximumBytes)
        self.expectedOwnerUserID = expectedOwnerUserID
        rootURL = directories.root
        directoryURL = directories.root.appendingPathComponent(
            "updates",
            isDirectory: true
        )
        journalURL = directoryURL.appendingPathComponent(
            "update-journal.json",
            isDirectory: false
        )
    }

    func load() throws -> UpdateJournal? {
        try prepareStorage()
        return try loadPrepared()
    }

    func save(_ journal: UpdateJournal) throws {
        do {
            try journal.validate()
        } catch let error as UpdateJournalValidationError {
            throw UpdateJournalStoreError.invalidJournal(error)
        }

        try prepareStorage()
        if let existing = try loadPrepared() {
            if existing.isActive, existing.updateID != journal.updateID {
                throw UpdateJournalStoreError.activeJournalExists(existing.updateID)
            }
            if existing.updateID == journal.updateID {
                guard existing.startedAt == journal.startedAt,
                    journal.lastUpdatedAt >= existing.lastUpdatedAt
                else {
                    throw UpdateJournalStoreError.staleJournalWrite
                }
            }
        }

        let data: Data
        do {
            data = try UpdateJSONCoding.encoder().encode(journal)
        } catch {
            throw UpdateJournalStoreError.encodeFailed
        }
        guard data.count <= maximumBytes else {
            throw UpdateJournalStoreError.fileTooLarge(
                actual: data.count,
                maximum: maximumBytes
            )
        }

        do {
            try fileSystem.writeDataAtomically(data, to: journalURL)
            try fileSystem.setPOSIXPermissions(
                Self.privateFilePermissions,
                at: journalURL
            )
        } catch {
            throw UpdateJournalStoreError.writeFailed
        }

        let metadata = try requiredJournalMetadata()
        try validateJournalMetadata(metadata)
        let verifiedData = try readVerifiedData(metadata: metadata)
        let verified: UpdateJournal
        do {
            try StrictJSONValidator.validateObject(
                verifiedData,
                shape: Self.journalShape
            )
            verified = try UpdateJSONCoding.decoder().decode(
                UpdateJournal.self,
                from: verifiedData
            )
            try verified.validate()
            guard try UpdateJSONCoding.encoder().encode(verified) == data else {
                throw UpdateJournalStoreError.verificationFailed
            }
        } catch let error as UpdateJournalStoreError {
            throw error
        } catch {
            throw UpdateJournalStoreError.verificationFailed
        }
    }

    func clear(expectedUpdateID: UUID? = nil) throws {
        try prepareStorage()
        guard let metadata = try inspector.metadata(at: journalURL) else { return }
        try validateJournalMetadata(metadata)
        if let expectedUpdateID {
            guard try loadPrepared()?.updateID == expectedUpdateID else {
                throw UpdateJournalStoreError.updateIdentifierMismatch
            }
        }
        do {
            try fileSystem.removeItem(at: journalURL)
        } catch {
            throw UpdateJournalStoreError.clearFailed
        }
    }

    func diagnosticSummary() throws -> UpdateJournalDiagnosticSummary? {
        try load()?.diagnosticSummary
    }

    private func prepareStorage() throws {
        do {
            if let rootMetadata = try inspector.metadata(at: rootURL) {
                switch rootMetadata.kind {
                case .symbolicLink:
                    throw UpdateJournalStoreError.symbolicLinkRejected
                case .directory:
                    guard rootMetadata.ownerUserID == expectedOwnerUserID else {
                        throw UpdateJournalStoreError.ownerMismatch
                    }
                case .regular, .other:
                    throw UpdateJournalStoreError.nonDirectoryRejected
                }
            }
            try directories.prepare(fileSystem: fileSystem)
            try validatePrivateDirectory(at: rootURL)
            if let existing = try inspector.metadata(at: directoryURL) {
                try validateDirectoryMetadata(existing)
            } else {
                try fileSystem.createDirectory(at: directoryURL)
            }
            try fileSystem.setPOSIXPermissions(
                Self.privateDirectoryPermissions,
                at: directoryURL
            )
            try validatePrivateDirectory(at: directoryURL)
        } catch let error as UpdateJournalStoreError {
            throw error
        } catch {
            throw UpdateJournalStoreError.storagePreparationFailed
        }
    }

    private func validatePrivateDirectory(at url: URL) throws {
        guard let metadata = try inspector.metadata(at: url) else {
            throw UpdateJournalStoreError.storagePreparationFailed
        }
        try validateDirectoryMetadata(metadata)
    }

    private func validateDirectoryMetadata(
        _ metadata: UpdateJournalFileMetadata
    ) throws {
        switch metadata.kind {
        case .symbolicLink:
            throw UpdateJournalStoreError.symbolicLinkRejected
        case .directory:
            break
        case .regular, .other:
            throw UpdateJournalStoreError.nonDirectoryRejected
        }
        guard metadata.ownerUserID == expectedOwnerUserID else {
            throw UpdateJournalStoreError.ownerMismatch
        }
        guard metadata.permissions == Self.privateDirectoryPermissions else {
            throw UpdateJournalStoreError.unsafePermissions(
                expected: Self.privateDirectoryPermissions,
                actual: metadata.permissions
            )
        }
    }

    private func loadPrepared() throws -> UpdateJournal? {
        guard let metadata = try inspector.metadata(at: journalURL) else { return nil }
        try validateJournalMetadata(metadata)
        let data = try readVerifiedData(metadata: metadata)
        do {
            try StrictJSONValidator.validateObject(data, shape: Self.journalShape)
        } catch let error as StrictJSONValidationError {
            throw UpdateJournalStoreError.invalidStructure(error)
        } catch {
            throw UpdateJournalStoreError.invalidStructure(.invalidJSON)
        }

        let journal: UpdateJournal
        do {
            journal = try UpdateJSONCoding.decoder().decode(UpdateJournal.self, from: data)
        } catch {
            throw UpdateJournalStoreError.decodeFailed
        }
        do {
            try journal.validate()
        } catch let error as UpdateJournalValidationError {
            throw UpdateJournalStoreError.invalidJournal(error)
        }
        return journal
    }

    private func requiredJournalMetadata() throws -> UpdateJournalFileMetadata {
        guard let metadata = try inspector.metadata(at: journalURL) else {
            throw UpdateJournalStoreError.verificationFailed
        }
        return metadata
    }

    private func validateJournalMetadata(
        _ metadata: UpdateJournalFileMetadata
    ) throws {
        switch metadata.kind {
        case .symbolicLink:
            throw UpdateJournalStoreError.symbolicLinkRejected
        case .regular:
            break
        case .directory, .other:
            throw UpdateJournalStoreError.nonRegularFileRejected
        }
        guard metadata.ownerUserID == expectedOwnerUserID else {
            throw UpdateJournalStoreError.ownerMismatch
        }
        guard metadata.permissions == Self.privateFilePermissions else {
            throw UpdateJournalStoreError.unsafePermissions(
                expected: Self.privateFilePermissions,
                actual: metadata.permissions
            )
        }
        guard metadata.size >= 0, metadata.size <= Int64(maximumBytes) else {
            throw UpdateJournalStoreError.fileTooLarge(
                actual: Int(clamping: metadata.size),
                maximum: maximumBytes
            )
        }
    }

    private func readVerifiedData(
        metadata before: UpdateJournalFileMetadata
    ) throws -> Data {
        let data: Data
        do {
            data = try fileSystem.readData(at: journalURL)
        } catch {
            throw UpdateJournalStoreError.readFailed
        }
        guard data.count <= maximumBytes else {
            throw UpdateJournalStoreError.fileTooLarge(
                actual: data.count,
                maximum: maximumBytes
            )
        }
        guard let after = try inspector.metadata(at: journalURL) else {
            throw UpdateJournalStoreError.fileChangedDuringRead
        }
        try validateJournalMetadata(after)
        guard before.device == after.device,
            before.inode == after.inode,
            before.size == after.size,
            Int64(data.count) == after.size
        else {
            throw UpdateJournalStoreError.fileChangedDuringRead
        }
        return data
    }

    private static let journalShape = StrictJSONShape(
        allowedKeys: [
            "schemaVersion", "updateID", "source", "target", "phase", "snapshot",
            "startedAt", "lastUpdatedAt", "failure", "recoveryAttempts",
        ],
        objects: [
            "source": StrictJSONShape(allowedKeys: ["version", "build"]),
            "target": StrictJSONShape(allowedKeys: ["version", "build"]),
            "snapshot": StrictJSONShape(
                allowedKeys: [
                    "profileID", "profileRevisionID", "sceneID", "backend",
                    "systemProxyDesired", "mihomoMode", "automaticScenesEnabled",
                    "helperVersion", "helperProtocol", "configurationGenerationID",
                    "proxySelections", "activeCoreID", "previousKnownGoodCoreID",
                    "coreSelectionMode", "highestCatalogSequence",
                    "coreTrustRootSetVersion",
                ],
                arrays: [
                    "proxySelections": StrictJSONShape(
                        allowedKeys: ["groupID", "proxyID"]
                    ),
                ]
            ),
            "failure": StrictJSONShape(allowedKeys: ["code", "phase", "summary"]),
        ]
    )
}

nonisolated enum UpdateJournalStoreError: Error, Equatable, Sendable {
    case storagePreparationFailed
    case fileInspectionFailed
    case symbolicLinkRejected
    case nonDirectoryRejected
    case nonRegularFileRejected
    case ownerMismatch
    case unsafePermissions(expected: Int, actual: Int)
    case fileTooLarge(actual: Int, maximum: Int)
    case readFailed
    case invalidStructure(StrictJSONValidationError)
    case decodeFailed
    case invalidJournal(UpdateJournalValidationError)
    case activeJournalExists(UUID)
    case staleJournalWrite
    case encodeFailed
    case writeFailed
    case verificationFailed
    case fileChangedDuringRead
    case updateIdentifierMismatch
    case clearFailed
}

extension UpdateJournalStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .storagePreparationFailed, .nonDirectoryRejected:
            "The private update storage directory could not be prepared."
        case .fileInspectionFailed, .fileChangedDuringRead:
            "The update journal changed while it was being inspected."
        case .symbolicLinkRejected, .nonRegularFileRejected:
            "The update journal path is not a safe regular file."
        case .ownerMismatch, .unsafePermissions:
            "The update journal has unsafe ownership or permissions."
        case .fileTooLarge:
            "The update journal exceeds its size limit."
        case .readFailed, .decodeFailed, .invalidStructure, .invalidJournal:
            "The update journal is damaged or unsupported."
        case .activeJournalExists:
            "Another update journal is still active."
        case .staleJournalWrite:
            "A stale update journal write was rejected."
        case .encodeFailed, .writeFailed, .verificationFailed:
            "The update journal could not be saved safely."
        case .updateIdentifierMismatch:
            "The update journal belongs to another update."
        case .clearFailed:
            "The update journal could not be cleared."
        }
    }
}
