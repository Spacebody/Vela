import CryptoKit
import Foundation

actor ProfileStore {
    private static let privateDirectoryPermissions = 0o700
    private static let privateFilePermissions = 0o600

    private let directories: ApplicationDirectories
    private let fileSystem: any FileSystemProviding
    private let idGenerator: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    init(
        directories: ApplicationDirectories,
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        idGenerator: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.directories = directories
        self.fileSystem = fileSystem
        self.idGenerator = idGenerator
        self.now = now
    }

    func prepareStorage() throws {
        do {
            try directories.prepare(fileSystem: fileSystem)
        } catch let error as ApplicationDirectoriesError {
            throw ProfileStoreError.storagePreparationFailed(error)
        }

        try ensureMetadataIsCurrent()
    }

    @discardableResult
    func importProfile(from source: URL, name: String? = nil) throws -> Profile {
        try prepareStorage()

        let sourceData: Data
        do {
            sourceData = try fileSystem.readData(at: source)
        } catch {
            throw ProfileStoreError.sourceReadFailed(
                path: source.path,
                reason: String(describing: error)
            )
        }

        let importData: Data
        do {
            importData = try SubscriptionContentValidator.validate(
                sourceData,
                contentType: nil
            ).data
        } catch {
            throw ProfileStoreError.sourceReadFailed(
                path: source.path,
                reason: error.localizedDescription
            )
        }

        let id = idGenerator()
        let destination = configurationURL(for: id)
        guard !fileSystem.fileExists(at: destination) else {
            throw ProfileStoreError.identifierCollision(id)
        }

        let timestamp = now()
        let profile = Profile(
            id: id,
            name: resolvedName(explicitName: name, source: source),
            originalFileName: source.lastPathComponent,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        do {
            try fileSystem.writeDataAtomically(importData, to: destination)
            try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: destination)
        } catch {
            try? fileSystem.removeItem(at: destination)
            throw ProfileStoreError.configurationWriteFailed(
                path: destination.path,
                reason: String(describing: error)
            )
        }

        do {
            var index = try loadIndex()
            index.profiles.append(profile)
            try saveIndex(index)
        } catch {
            try? fileSystem.removeItem(at: destination)
            throw error
        }

        return profile
    }

    @discardableResult
    func createRemoteProfile(
        name: String,
        sourceFileName: String = "subscription.yaml",
        metadata: RemoteProfileMetadata
    ) throws -> Profile {
        try prepareStorage()
        try validateRemoteMetadata(metadata)

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ProfileStoreError.invalidProfileName
        }
        let trimmedFileName = sourceFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFileName.isEmpty else {
            throw ProfileStoreError.invalidSourceFileName
        }

        var index = try loadIndex()
        let id = idGenerator()
        guard !index.profiles.contains(where: { $0.id == id }),
            !fileSystem.fileExists(at: configurationURL(for: id))
        else {
            throw ProfileStoreError.identifierCollision(id)
        }

        let timestamp = now()
        let profile = Profile(
            id: id,
            name: trimmedName,
            originalFileName: trimmedFileName,
            createdAt: timestamp,
            updatedAt: timestamp,
            sourceKind: .remoteSubscription,
            remote: metadata
        )
        index.profiles.append(profile)
        try saveIndex(index)
        return profile
    }

    @discardableResult
    func updateRemoteMetadata(
        for profileID: UUID,
        metadata: RemoteProfileMetadata
    ) throws -> Profile {
        try prepareStorage()
        try validateRemoteMetadata(metadata)

        var index = try loadIndex()
        guard let profileIndex = index.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        guard index.profiles[profileIndex].sourceKind == .remoteSubscription else {
            throw ProfileStoreError.profileIsNotRemote(profileID)
        }

        index.profiles[profileIndex].remote = metadata
        index.profiles[profileIndex].updatedAt = now()
        try saveIndex(index)
        return index.profiles[profileIndex]
    }

    @discardableResult
    func updateRemoteSettings(
        for profileID: UUID,
        name: String,
        metadata: RemoteProfileMetadata
    ) throws -> Profile {
        try prepareStorage()
        try validateRemoteMetadata(metadata)

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ProfileStoreError.invalidProfileName
        }

        var index = try loadIndex()
        guard let profileIndex = index.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        guard index.profiles[profileIndex].sourceKind == .remoteSubscription else {
            throw ProfileStoreError.profileIsNotRemote(profileID)
        }

        index.profiles[profileIndex].name = trimmedName
        index.profiles[profileIndex].remote = metadata
        index.profiles[profileIndex].updatedAt = now()
        try saveIndex(index)
        return index.profiles[profileIndex]
    }

    @discardableResult
    func commitRawRevision(
        _ data: Data,
        for profileID: UUID,
        sourceFileName: String? = nil,
        revisionID: UUID = UUID(),
        createdAt: Date? = nil,
        updatedRemoteMetadata: RemoteProfileMetadata? = nil
    ) throws -> ProfileRevision {
        try prepareStorage()
        guard !data.isEmpty else {
            throw ProfileStoreError.revisionDataIsEmpty
        }
        if let updatedRemoteMetadata {
            try validateRemoteMetadata(updatedRemoteMetadata)
        }

        var index = try loadIndex()
        guard let profileIndex = index.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        var profile = index.profiles[profileIndex]
        if updatedRemoteMetadata != nil, profile.sourceKind != .remoteSubscription {
            throw ProfileStoreError.profileIsNotRemote(profileID)
        }
        guard !profile.revisions.contains(where: { $0.id == revisionID }) else {
            throw ProfileStoreError.revisionIdentifierCollision(revisionID)
        }

        let resolvedSourceFileName = (sourceFileName ?? profile.originalFileName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedSourceFileName.isEmpty else {
            throw ProfileStoreError.invalidSourceFileName
        }

        let revisionTimestamp = createdAt ?? now()
        let revision = ProfileRevision(
            id: revisionID,
            createdAt: revisionTimestamp,
            contentSHA256: Self.sha256(data),
            sourceFileName: resolvedSourceFileName,
            byteCount: data.count
        )

        try prepareWorkingDirectoriesWithoutReload(for: profileID)
        let revisionURL = directories.profileRevisionURL(
            profileID: profileID,
            revisionID: revisionID
        )
        guard !fileSystem.fileExists(at: revisionURL) else {
            throw ProfileStoreError.revisionIdentifierCollision(revisionID)
        }

        do {
            try fileSystem.writeDataAtomically(data, to: revisionURL)
            try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: revisionURL)
            guard try fileSystem.readData(at: revisionURL) == data else {
                throw ProfileStoreMigrationError.verificationMismatch
            }
        } catch {
            try? fileSystem.removeItem(at: revisionURL)
            throw ProfileStoreError.revisionWriteFailed(
                path: revisionURL.path,
                reason: String(describing: error)
            )
        }

        let configurationURL = configurationURL(for: profileID)
        let priorConfiguration: Data?
        do {
            priorConfiguration = fileSystem.fileExists(at: configurationURL)
                ? try fileSystem.readData(at: configurationURL)
                : nil
        } catch {
            try? fileSystem.removeItem(at: revisionURL)
            throw ProfileStoreError.configurationReadFailed(
                path: configurationURL.path,
                reason: String(describing: error)
            )
        }

        do {
            try fileSystem.writeDataAtomically(data, to: configurationURL)
            try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: configurationURL)
        } catch {
            let rollbackFailure = rollbackRevisionCommit(
                configurationURL: configurationURL,
                priorConfiguration: priorConfiguration,
                newRevisionURL: revisionURL
            )
            if let rollbackFailure {
                throw ProfileStoreError.revisionCommitRollbackFailed(
                    path: rollbackFailure.path,
                    originalReason: String(describing: error),
                    rollbackReason: rollbackFailure.reason
                )
            }
            throw ProfileStoreError.configurationWriteFailed(
                path: configurationURL.path,
                reason: String(describing: error)
            )
        }

        let priorRevisionIDs = [profile.currentRevisionID].compactMap { $0 }
            + profile.previousRevisionIDs
        let retainedPreviousIDs = Array(priorRevisionIDs.prefix(2))
        let retainedIDs = Set([revisionID] + retainedPreviousIDs)
        let prunedIDs = Set(priorRevisionIDs).subtracting(retainedIDs)

        profile.currentRevisionID = revisionID
        profile.previousRevisionIDs = retainedPreviousIDs
        profile.revisions = ([revision] + profile.revisions)
            .filter { retainedIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt > rhs.createdAt
            }
        profile.updatedAt = revisionTimestamp
        if let updatedRemoteMetadata {
            profile.remote = updatedRemoteMetadata
        }
        index.profiles[profileIndex] = profile

        do {
            try saveIndex(index)
        } catch {
            let rollbackFailure = rollbackRevisionCommit(
                configurationURL: configurationURL,
                priorConfiguration: priorConfiguration,
                newRevisionURL: revisionURL
            )
            if let rollbackFailure {
                throw ProfileStoreError.revisionCommitRollbackFailed(
                    path: rollbackFailure.path,
                    originalReason: String(describing: error),
                    rollbackReason: rollbackFailure.reason
                )
            }
            throw error
        }

        var firstCleanupFailure: (path: String, reason: String)?
        for prunedID in prunedIDs {
            let url = directories.profileRevisionURL(
                profileID: profileID,
                revisionID: prunedID
            )
            guard fileSystem.fileExists(at: url) else { continue }
            do {
                try fileSystem.removeItem(at: url)
            } catch {
                if firstCleanupFailure == nil {
                    firstCleanupFailure = (url.path, String(describing: error))
                }
            }
        }
        if let firstCleanupFailure {
            throw ProfileStoreError.revisionCleanupFailed(
                path: firstCleanupFailure.path,
                reason: firstCleanupFailure.reason
            )
        }

        return revision
    }

    /// Reconciles the file half of a revision commit that was interrupted
    /// before the metadata index reached its atomic commit point.
    ///
    /// The transaction journal owns the backup bytes and the pending revision
    /// identifier. This method refuses to overwrite a profile whose metadata
    /// has advanced beyond the journal's recorded predecessor.
    func rollbackInterruptedRevisionCommit(
        for profileID: UUID,
        previousRevisionID: UUID?,
        interruptedRevisionID: UUID,
        previousRawData: Data?
    ) throws {
        try prepareStorage()
        let index = try loadIndex()
        guard let profile = index.profiles.first(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        guard profile.currentRevisionID == previousRevisionID else {
            throw ProfileStoreError.interruptedRevisionRecoveryFailed(
                path: configurationURL(for: profileID).path,
                reason: "Profile metadata advanced beyond the interrupted transaction."
            )
        }

        if let previousRevisionID {
            guard let previousRevision = profile.revisions.first(where: {
                $0.id == previousRevisionID
            }) else {
                throw ProfileStoreError.interruptedRevisionRecoveryFailed(
                    path: configurationURL(for: profileID).path,
                    reason: "The previous revision metadata is unavailable."
                )
            }
            guard let previousRawData,
                Self.sha256(previousRawData)
                    .caseInsensitiveCompare(previousRevision.contentSHA256) == .orderedSame
            else {
                throw ProfileStoreError.interruptedRevisionRecoveryFailed(
                    path: configurationURL(for: profileID).path,
                    reason: "The previous profile backup does not match its revision metadata."
                )
            }
        }

        let configurationURL = configurationURL(for: profileID)
        let interruptedRevisionURL = directories.profileRevisionURL(
            profileID: profileID,
            revisionID: interruptedRevisionID
        )
        do {
            if let previousRawData {
                try fileSystem.writeDataAtomically(previousRawData, to: configurationURL)
                try fileSystem.setPOSIXPermissions(
                    Self.privateFilePermissions,
                    at: configurationURL
                )
            } else if fileSystem.fileExists(at: configurationURL) {
                try fileSystem.removeItem(at: configurationURL)
            }
            if fileSystem.fileExists(at: interruptedRevisionURL) {
                try fileSystem.removeItem(at: interruptedRevisionURL)
            }
        } catch {
            throw ProfileStoreError.interruptedRevisionRecoveryFailed(
                path: configurationURL.path,
                reason: String(describing: error)
            )
        }
    }

    func revisions(for profileID: UUID) throws -> [ProfileRevision] {
        try prepareStorage()
        guard let profile = try loadIndex().profiles.first(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        return profile.revisions.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func readRevision(profileID: UUID, revisionID: UUID) throws -> Data {
        let revisions = try revisions(for: profileID)
        guard revisions.contains(where: { $0.id == revisionID }) else {
            throw ProfileStoreError.revisionNotFound(revisionID)
        }
        let url = directories.profileRevisionURL(
            profileID: profileID,
            revisionID: revisionID
        )
        do {
            return try fileSystem.readData(at: url)
        } catch {
            throw ProfileStoreError.revisionReadFailed(
                path: url.path,
                reason: String(describing: error)
            )
        }
    }

    func profiles() throws -> [Profile] {
        try prepareStorage()
        return try loadIndex().profiles.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func profile(id: UUID) throws -> Profile? {
        try prepareStorage()
        return try loadIndex().profiles.first { $0.id == id }
    }

    func selectedProfileID() throws -> UUID? {
        try prepareStorage()
        return try loadIndex().selectedProfileID
    }

    func selectProfile(id: UUID) throws {
        try prepareStorage()
        var index = try loadIndex()
        guard index.profiles.contains(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        index.selectedProfileID = id
        try saveIndex(index)
    }

    func clearSelectedProfile() throws {
        try prepareStorage()
        var index = try loadIndex()
        index.selectedProfileID = nil
        try saveIndex(index)
    }

    func deleteProfile(id: UUID) throws {
        try prepareStorage()
        var index = try loadIndex()
        guard let profileIndex = index.profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound(id)
        }

        let originals = [
            configurationURL(for: id),
            directories.profileHistoryDirectory(for: id),
            directories.profileStagingDirectory(for: id),
            directories.overrideURL(for: id),
        ]
        let stagedArtifacts = try stageDeletion(of: originals)

        index.profiles.remove(at: profileIndex)
        if index.selectedProfileID == id {
            index.selectedProfileID = nil
        }

        do {
            try saveIndex(index)
        } catch {
            if let rollbackFailure = rollback(stagedArtifacts) {
                throw ProfileStoreError.configurationDeleteRollbackFailed(
                    path: rollbackFailure.original.path,
                    originalReason: String(describing: error),
                    rollbackReason: rollbackFailure.reason
                )
            }
            throw error
        }

        var firstCleanupFailure: (path: String, reason: String)?
        for artifact in stagedArtifacts {
            do {
                try fileSystem.removeItem(at: artifact.staged)
            } catch {
                if firstCleanupFailure == nil {
                    firstCleanupFailure = (
                        artifact.staged.path,
                        String(describing: error)
                    )
                }
            }
        }
        if let firstCleanupFailure {
            throw ProfileStoreError.configurationDeleteCleanupFailed(
                path: firstCleanupFailure.path,
                reason: firstCleanupFailure.reason
            )
        }
    }

    func configurationURL(for profileID: UUID) -> URL {
        directories.profiles.appendingPathComponent(
            "\(profileID.uuidString).yaml",
            isDirectory: false
        )
    }

    func historyDirectory(for profileID: UUID) -> URL {
        directories.profileHistoryDirectory(for: profileID)
    }

    func stagingDirectory(for profileID: UUID) -> URL {
        directories.profileStagingDirectory(for: profileID)
    }

    func revisionURL(for profileID: UUID, revisionID: UUID) -> URL {
        directories.profileRevisionURL(profileID: profileID, revisionID: revisionID)
    }

    func overrideURL(for profileID: UUID) -> URL {
        directories.overrideURL(for: profileID)
    }

    func prepareWorkingDirectories(for profileID: UUID) throws {
        try prepareStorage()
        guard try loadIndex().profiles.contains(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }

        try prepareWorkingDirectoriesWithoutReload(for: profileID)
    }

    private func prepareWorkingDirectoriesWithoutReload(for profileID: UUID) throws {
        for directory in [
            directories.profileHistoryDirectory(for: profileID),
            directories.profileStagingDirectory(for: profileID),
        ] {
            do {
                try fileSystem.createDirectory(at: directory)
                try fileSystem.setPOSIXPermissions(
                    Self.privateDirectoryPermissions,
                    at: directory
                )
            } catch {
                throw ProfileStoreError.profileWorkingDirectoryPreparationFailed(
                    path: directory.path,
                    reason: String(describing: error)
                )
            }
        }
    }

    func readConfiguration(for profileID: UUID) throws -> Data {
        try prepareStorage()
        let index = try loadIndex()
        guard index.profiles.contains(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }

        let configuration = configurationURL(for: profileID)
        do {
            return try fileSystem.readData(at: configuration)
        } catch {
            throw ProfileStoreError.configurationReadFailed(
                path: configuration.path,
                reason: String(describing: error)
            )
        }
    }

    @discardableResult
    func buildRuntimeConfiguration(
        for profileID: UUID,
        parameters: RuntimeConfigParameters,
        using builder: RuntimeConfigBuilder = RuntimeConfigBuilder()
    ) throws -> URL {
        try buildRuntimeConfiguration(
            for: profileID,
            parameters: parameters,
            using: builder,
            context: ConfigurationCompilationContext()
        )
    }

    @discardableResult
    func buildRuntimeConfiguration(
        for profileID: UUID,
        parameters: RuntimeConfigParameters,
        using builder: RuntimeConfigBuilder,
        context: ConfigurationCompilationContext
    ) throws -> URL {
        try prepareStorage()
        let index = try loadIndex()
        guard index.profiles.contains(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }

        return try builder.writeRuntimeConfiguration(
            from: configurationURL(for: profileID),
            to: directories.activeConfiguration,
            parameters: parameters,
            context: context,
            fileSystem: fileSystem
        )
    }

    private func resolvedName(explicitName: String?, source: URL) -> String {
        if let explicitName {
            let trimmed = explicitName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let sourceName = source.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceName.isEmpty ? "Untitled Profile" : sourceName
    }

    private func ensureMetadataIsCurrent() throws {
        let metadataURL = directories.profilesMetadata
        guard fileSystem.fileExists(at: metadataURL) else {
            removeMigrationCandidateIfPresent()
            return
        }

        let originalData = try readMetadata(at: metadataURL)
        let root = try metadataObject(from: originalData, path: metadataURL.path)

        if let encodedVersion = root["schemaVersion"] {
            let version = try integerValue(
                encodedVersion,
                field: "schemaVersion",
                path: metadataURL.path
            )
            guard version == ProfileDatabaseEnvelope.currentSchemaVersion else {
                throw ProfileStoreError.unsupportedSchemaVersion(version)
            }

            let envelope = try decodeCurrent(originalData, path: metadataURL.path)
            try validate(envelope, path: metadataURL.path)
            try enforcePrivatePermissions(for: envelope, metadataURL: metadataURL)
            removeMigrationCandidateIfPresent()
            return
        }

        let migrated = try decodeLegacy(root, path: metadataURL.path)
        try validate(migrated, path: metadataURL.path)
        try migrate(originalData: originalData, envelope: migrated)
    }

    private func migrate(
        originalData: Data,
        envelope: ProfileDatabaseEnvelope
    ) throws {
        let metadataURL = directories.profilesMetadata
        let backupURL = directories.profilesMetadataV1Backup
        let candidateURL = directories.profilesMetadataMigrationCandidate

        do {
            if !fileSystem.fileExists(at: backupURL) {
                try fileSystem.writeDataAtomically(originalData, to: backupURL)
            }
            try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: backupURL)

            let migratedData = try encoded(envelope)
            try fileSystem.writeDataAtomically(migratedData, to: candidateURL)
            try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: candidateURL)

            let verificationData = try fileSystem.readData(at: candidateURL)
            let verified = try decodeCurrent(verificationData, path: candidateURL.path)
            try validate(verified, path: candidateURL.path)
            guard try encoded(verified) == verificationData else {
                throw ProfileStoreMigrationError.verificationMismatch
            }

            try enforceProfileConfigurationPermissions(for: envelope)

            // The candidate has already been decoded and verified. Data.write(.atomic)
            // performs the final same-volume replacement without exposing a partial JSON file.
            try fileSystem.writeDataAtomically(verificationData, to: metadataURL)
            try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: metadataURL)
        } catch let error as ProfileStoreError {
            throw error
        } catch {
            throw ProfileStoreError.metadataMigrationFailed(
                path: metadataURL.path,
                reason: String(describing: error)
            )
        }

        removeMigrationCandidateIfPresent()
    }

    private func loadIndex() throws -> ProfileDatabaseEnvelope {
        let metadataURL = directories.profilesMetadata
        guard fileSystem.fileExists(at: metadataURL) else {
            return ProfileDatabaseEnvelope()
        }

        let data = try readMetadata(at: metadataURL)
        let envelope = try decodeCurrent(data, path: metadataURL.path)
        try validate(envelope, path: metadataURL.path)
        return envelope
    }

    private func saveIndex(_ index: ProfileDatabaseEnvelope) throws {
        guard index.schemaVersion == ProfileDatabaseEnvelope.currentSchemaVersion else {
            throw ProfileStoreError.unsupportedSchemaVersion(index.schemaVersion)
        }

        let data: Data
        do {
            data = try encoded(index)
            let roundTrip = try decodeCurrent(data, path: directories.profilesMetadata.path)
            guard try encoded(roundTrip) == data else {
                throw ProfileStoreMigrationError.verificationMismatch
            }
        } catch let error as ProfileStoreError {
            throw error
        } catch {
            throw ProfileStoreError.metadataEncodeFailed(reason: String(describing: error))
        }

        let metadataURL = directories.profilesMetadata
        do {
            try fileSystem.writeDataAtomically(data, to: metadataURL)
            try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: metadataURL)
        } catch {
            throw ProfileStoreError.metadataWriteFailed(
                path: metadataURL.path,
                reason: String(describing: error)
            )
        }
    }

    private func encoded(_ index: ProfileDatabaseEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(try Self.canonicalDateString(date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(index)
    }

    private func decodeCurrent(_ data: Data, path: String) throws -> ProfileDatabaseEnvelope {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                guard let date = Self.parseISO8601(value) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Expected an ISO-8601 date."
                    )
                }
                return date
            }
            let envelope = try decoder.decode(ProfileDatabaseEnvelope.self, from: data)
            guard envelope.schemaVersion == ProfileDatabaseEnvelope.currentSchemaVersion else {
                throw ProfileStoreError.unsupportedSchemaVersion(envelope.schemaVersion)
            }
            return envelope
        } catch let error as ProfileStoreError {
            throw error
        } catch {
            throw ProfileStoreError.metadataDecodeFailed(
                path: path,
                reason: String(describing: error)
            )
        }
    }

    private func decodeLegacy(
        _ root: [String: ProfileMetadataValue],
        path: String
    ) throws -> ProfileDatabaseEnvelope {
        do {
            guard case let .array(encodedProfiles)? = root["profiles"] else {
                throw ProfileStoreMigrationError.missingOrInvalidField("profiles")
            }

            let profiles = try encodedProfiles.enumerated().map { index, value in
                guard case let .object(profileObject) = value else {
                    throw ProfileStoreMigrationError.profileIsNotObject(index)
                }
                return try decodeLegacyProfile(profileObject, index: index)
            }

            let selectedProfileID: UUID?
            switch root["selectedProfileID"] {
            case nil, .null?:
                selectedProfileID = nil
            case let .string(value)?:
                guard let parsed = UUID(uuidString: value) else {
                    throw ProfileStoreMigrationError.invalidUUID(
                        field: "selectedProfileID",
                        value: value
                    )
                }
                selectedProfileID = parsed
            default:
                throw ProfileStoreMigrationError.missingOrInvalidField("selectedProfileID")
            }

            var additionalMetadata = root
            additionalMetadata.removeValue(forKey: "profiles")
            additionalMetadata.removeValue(forKey: "selectedProfileID")

            return ProfileDatabaseEnvelope(
                profiles: profiles,
                selectedProfileID: selectedProfileID,
                additionalMetadata: additionalMetadata
            )
        } catch {
            throw ProfileStoreError.metadataMigrationFailed(
                path: path,
                reason: String(describing: error)
            )
        }
    }

    private func decodeLegacyProfile(
        _ object: [String: ProfileMetadataValue],
        index: Int
    ) throws -> Profile {
        let idString = try requiredString("id", in: object, profileIndex: index)
        guard let id = UUID(uuidString: idString) else {
            throw ProfileStoreMigrationError.invalidUUID(field: "profiles[\(index)].id", value: idString)
        }

        let name = try requiredString(
            aliases: ["displayName", "name"],
            in: object,
            profileIndex: index
        )
        let sourceFileName = try requiredString(
            aliases: ["sourceFileName", "originalFileName"],
            in: object,
            profileIndex: index
        )
        let createdAt = try requiredDate("createdAt", in: object, profileIndex: index)
        let updatedAt = try requiredDate("updatedAt", in: object, profileIndex: index)

        let knownKeys: Set<String> = [
            "id",
            "displayName",
            "name",
            "sourceFileName",
            "originalFileName",
            "createdAt",
            "updatedAt",
        ]
        let additionalMetadata = object.filter { !knownKeys.contains($0.key) }

        return Profile(
            id: id,
            name: name,
            originalFileName: sourceFileName,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sourceKind: .localFile,
            additionalMetadata: additionalMetadata
        )
    }

    private func metadataObject(
        from data: Data,
        path: String
    ) throws -> [String: ProfileMetadataValue] {
        do {
            let value = try JSONDecoder().decode(ProfileMetadataValue.self, from: data)
            guard case let .object(object) = value else {
                throw ProfileStoreMigrationError.rootIsNotObject
            }
            return object
        } catch {
            throw ProfileStoreError.metadataDecodeFailed(
                path: path,
                reason: String(describing: error)
            )
        }
    }

    private func requiredString(
        _ key: String,
        in object: [String: ProfileMetadataValue],
        profileIndex: Int
    ) throws -> String {
        try requiredString(aliases: [key], in: object, profileIndex: profileIndex)
    }

    private func requiredString(
        aliases: [String],
        in object: [String: ProfileMetadataValue],
        profileIndex: Int
    ) throws -> String {
        for key in aliases {
            if case let .string(value)? = object[key], !value.isEmpty {
                return value
            }
        }
        throw ProfileStoreMigrationError.missingOrInvalidField(
            "profiles[\(profileIndex)].\(aliases.joined(separator: "/"))"
        )
    }

    private func requiredDate(
        _ key: String,
        in object: [String: ProfileMetadataValue],
        profileIndex: Int
    ) throws -> Date {
        let field = "profiles[\(profileIndex)].\(key)"
        switch object[key] {
        case let .integer(value)?:
            return Date(timeIntervalSince1970: TimeInterval(value))
        case let .floatingPoint(value)?:
            guard value.isFinite else {
                throw ProfileStoreMigrationError.invalidDate(field: field)
            }
            return Date(timeIntervalSince1970: value)
        case let .string(value)?:
            if let date = Self.parseISO8601(value) {
                return date
            }
            throw ProfileStoreMigrationError.invalidDate(field: field)
        default:
            throw ProfileStoreMigrationError.invalidDate(field: field)
        }
    }

    private func integerValue(
        _ value: ProfileMetadataValue,
        field: String,
        path: String
    ) throws -> Int {
        guard case let .integer(integer) = value, let result = Int(exactly: integer) else {
            throw ProfileStoreError.metadataDecodeFailed(
                path: path,
                reason: "\(field) must be an integer."
            )
        }
        return result
    }

    private func validate(_ envelope: ProfileDatabaseEnvelope, path: String) throws {
        guard envelope.schemaVersion == ProfileDatabaseEnvelope.currentSchemaVersion else {
            throw ProfileStoreError.unsupportedSchemaVersion(envelope.schemaVersion)
        }

        var profileIDs = Set<UUID>()
        for profile in envelope.profiles {
            guard profileIDs.insert(profile.id).inserted else {
                throw ProfileStoreError.metadataDecodeFailed(
                    path: path,
                    reason: "Duplicate profile identifier \(profile.id.uuidString)."
                )
            }
        }
        if let selectedProfileID = envelope.selectedProfileID,
            !profileIDs.contains(selectedProfileID)
        {
            throw ProfileStoreError.metadataDecodeFailed(
                path: path,
                reason: "The selected profile \(selectedProfileID.uuidString) is missing."
            )
        }
    }

    private func readMetadata(at url: URL) throws -> Data {
        do {
            return try fileSystem.readData(at: url)
        } catch {
            throw ProfileStoreError.metadataReadFailed(
                path: url.path,
                reason: String(describing: error)
            )
        }
    }

    private func enforcePrivatePermissions(
        for envelope: ProfileDatabaseEnvelope,
        metadataURL: URL
    ) throws {
        do {
            try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: metadataURL)
            if fileSystem.fileExists(at: directories.profilesMetadataV1Backup) {
                try fileSystem.setPOSIXPermissions(
                    Self.privateFilePermissions,
                    at: directories.profilesMetadataV1Backup
                )
            }
            try enforceProfileConfigurationPermissions(for: envelope)
        } catch {
            throw ProfileStoreError.metadataPermissionFailed(
                path: metadataURL.path,
                reason: String(describing: error)
            )
        }
    }

    private func enforceProfileConfigurationPermissions(
        for envelope: ProfileDatabaseEnvelope
    ) throws {
        for profile in envelope.profiles {
            let url = configurationURL(for: profile.id)
            if fileSystem.fileExists(at: url) {
                try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: url)
            }
        }
    }

    private func removeMigrationCandidateIfPresent() {
        let candidate = directories.profilesMetadataMigrationCandidate
        if fileSystem.fileExists(at: candidate) {
            try? fileSystem.removeItem(at: candidate)
        }
    }

    private func stageDeletion(of originals: [URL]) throws -> [StagedProfileArtifact] {
        var staged: [StagedProfileArtifact] = []
        for original in originals where fileSystem.fileExists(at: original) {
            let destination = original.deletingLastPathComponent().appendingPathComponent(
                ".\(original.lastPathComponent).deleting-\(UUID().uuidString)",
                isDirectory: false
            )
            do {
                try fileSystem.moveItem(at: original, to: destination)
                staged.append(StagedProfileArtifact(original: original, staged: destination))
            } catch {
                if let rollbackFailure = rollback(staged) {
                    throw ProfileStoreError.configurationDeleteRollbackFailed(
                        path: rollbackFailure.original.path,
                        originalReason: String(describing: error),
                        rollbackReason: rollbackFailure.reason
                    )
                }
                throw ProfileStoreError.configurationDeleteFailed(
                    path: original.path,
                    reason: String(describing: error)
                )
            }
        }
        return staged
    }

    private func rollback(
        _ artifacts: [StagedProfileArtifact]
    ) -> (original: URL, reason: String)? {
        var firstFailure: (original: URL, reason: String)?
        for artifact in artifacts.reversed() {
            do {
                try fileSystem.moveItem(at: artifact.staged, to: artifact.original)
            } catch {
                if firstFailure == nil {
                    firstFailure = (artifact.original, String(describing: error))
                }
            }
        }
        return firstFailure
    }

    private func rollbackRevisionCommit(
        configurationURL: URL,
        priorConfiguration: Data?,
        newRevisionURL: URL
    ) -> (path: String, reason: String)? {
        var firstFailure: (path: String, reason: String)?

        do {
            if let priorConfiguration {
                try fileSystem.writeDataAtomically(priorConfiguration, to: configurationURL)
                try fileSystem.setPOSIXPermissions(
                    Self.privateFilePermissions,
                    at: configurationURL
                )
            } else if fileSystem.fileExists(at: configurationURL) {
                try fileSystem.removeItem(at: configurationURL)
            }
        } catch {
            firstFailure = (configurationURL.path, String(describing: error))
        }

        if fileSystem.fileExists(at: newRevisionURL) {
            do {
                try fileSystem.removeItem(at: newRevisionURL)
            } catch {
                if firstFailure == nil {
                    firstFailure = (newRevisionURL.path, String(describing: error))
                }
            }
        }
        return firstFailure
    }

    private func validateRemoteMetadata(_ metadata: RemoteProfileMetadata) throws {
        guard let components = URLComponents(string: metadata.redactedURL),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            throw ProfileStoreError.remoteMetadataContainsSensitiveURLComponents
        }
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Foundation's built-in `.iso8601` strategy omits fractional seconds, which
    /// can make an encode/decode verification silently change a freshly created
    /// `Date`. Persist up to nanosecond precision while retaining the same
    /// standards-compatible UTC representation used by the pack fixtures.
    private nonisolated static func canonicalDateString(_ date: Date) throws -> String {
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite else {
            throw EncodingError.invalidValue(
                date,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Profile metadata dates must be finite."
                )
            )
        }

        var wholeSeconds = floor(timestamp)
        var nanoseconds = Int64(((timestamp - wholeSeconds) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            wholeSeconds += 1
            nanoseconds = 0
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let wholeDate = Date(timeIntervalSince1970: wholeSeconds)
        let base = formatter.string(from: wholeDate)
        guard nanoseconds != 0, base.last == "Z" else {
            return base
        }
        return String(base.dropLast()) + String(format: ".%09lldZ", nanoseconds)
    }

    private nonisolated static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        // Parse the fractional part ourselves. ISO8601DateFormatter accepts it,
        // but truncates beyond milliseconds on current Foundation releases.
        if let decimal = value.lastIndex(of: ".") {
            let fractionStart = value.index(after: decimal)
            let remainder = value[fractionStart...]
            guard let zoneStart = remainder.firstIndex(where: {
                $0 == "Z" || $0 == "+" || $0 == "-"
            }) else {
                return nil
            }

            let digits = value[fractionStart..<zoneStart]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
                return nil
            }
            let wholeValue = String(value[..<decimal]) + String(value[zoneStart...])
            guard let wholeDate = formatter.date(from: wholeValue) else {
                return nil
            }

            var fraction = 0.0
            var divisor = 10.0
            for digit in digits {
                guard let value = digit.wholeNumberValue else { return nil }
                fraction += Double(value) / divisor
                divisor *= 10
            }
            return wholeDate.addingTimeInterval(fraction)
        }

        return formatter.date(from: value)
    }
}

nonisolated private struct StagedProfileArtifact: Sendable {
    let original: URL
    let staged: URL
}

nonisolated private enum ProfileStoreMigrationError: Error, CustomStringConvertible, Sendable {
    case rootIsNotObject
    case missingOrInvalidField(String)
    case profileIsNotObject(Int)
    case invalidUUID(field: String, value: String)
    case invalidDate(field: String)
    case verificationMismatch

    var description: String {
        switch self {
        case .rootIsNotObject:
            "The profile metadata root is not an object."
        case let .missingOrInvalidField(field):
            "The legacy profile metadata field \(field) is missing or invalid."
        case let .profileIsNotObject(index):
            "The legacy profile at index \(index) is not an object."
        case let .invalidUUID(field, value):
            "The legacy profile metadata field \(field) is not a UUID: \(value)"
        case let .invalidDate(field):
            "The legacy profile metadata field \(field) is not a supported date."
        case .verificationMismatch:
            "The encoded profile database did not survive decode verification."
        }
    }
}

nonisolated enum ProfileStoreError: Error, Equatable, Sendable {
    case storagePreparationFailed(ApplicationDirectoriesError)
    case sourceReadFailed(path: String, reason: String)
    case identifierCollision(UUID)
    case invalidProfileName
    case invalidSourceFileName
    case profileIsNotRemote(UUID)
    case remoteMetadataContainsSensitiveURLComponents
    case configurationWriteFailed(path: String, reason: String)
    case configurationReadFailed(path: String, reason: String)
    case configurationDeleteFailed(path: String, reason: String)
    case configurationDeleteRollbackFailed(
        path: String,
        originalReason: String,
        rollbackReason: String
    )
    case configurationDeleteCleanupFailed(path: String, reason: String)
    case profileWorkingDirectoryPreparationFailed(path: String, reason: String)
    case metadataReadFailed(path: String, reason: String)
    case metadataDecodeFailed(path: String, reason: String)
    case metadataEncodeFailed(reason: String)
    case metadataWriteFailed(path: String, reason: String)
    case metadataMigrationFailed(path: String, reason: String)
    case metadataPermissionFailed(path: String, reason: String)
    case unsupportedSchemaVersion(Int)
    case revisionDataIsEmpty
    case revisionIdentifierCollision(UUID)
    case revisionNotFound(UUID)
    case revisionWriteFailed(path: String, reason: String)
    case revisionReadFailed(path: String, reason: String)
    case revisionCommitRollbackFailed(
        path: String,
        originalReason: String,
        rollbackReason: String
    )
    case interruptedRevisionRecoveryFailed(path: String, reason: String)
    case revisionCleanupFailed(path: String, reason: String)
    case profileNotFound(UUID)
}

extension ProfileStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .storagePreparationFailed(error):
            error.localizedDescription
        case let .sourceReadFailed(path, reason):
            "Could not read the profile at \(path): \(reason)"
        case let .identifierCollision(id):
            "A profile configuration already exists for identifier \(id.uuidString)."
        case .invalidProfileName:
            "The profile name cannot be empty."
        case .invalidSourceFileName:
            "The profile source filename cannot be empty."
        case let .profileIsNotRemote(id):
            "Profile \(id.uuidString) is not a remote subscription profile."
        case .remoteMetadataContainsSensitiveURLComponents:
            "Remote profile metadata must contain only a redacted URL without user info, query, or fragment."
        case let .configurationWriteFailed(path, reason):
            "Could not write the profile configuration at \(path): \(reason)"
        case let .configurationReadFailed(path, reason):
            "Could not read the profile configuration at \(path): \(reason)"
        case let .configurationDeleteFailed(path, reason):
            "Could not delete the profile artifact at \(path): \(reason)"
        case let .configurationDeleteRollbackFailed(path, originalReason, rollbackReason):
            "Could not restore the profile artifact at \(path) after \(originalReason): \(rollbackReason)"
        case let .configurationDeleteCleanupFailed(path, reason):
            "The profile was deleted, but its staged artifact at \(path) could not be removed: \(reason)"
        case let .profileWorkingDirectoryPreparationFailed(path, reason):
            "Could not prepare the profile working directory at \(path): \(reason)"
        case let .metadataReadFailed(path, reason):
            "Could not read profile metadata at \(path): \(reason)"
        case let .metadataDecodeFailed(path, reason):
            "Could not decode profile metadata at \(path): \(reason)"
        case let .metadataEncodeFailed(reason):
            "Could not encode profile metadata: \(reason)"
        case let .metadataWriteFailed(path, reason):
            "Could not write profile metadata at \(path): \(reason)"
        case let .metadataMigrationFailed(path, reason):
            "Could not migrate profile metadata at \(path): \(reason)"
        case let .metadataPermissionFailed(path, reason):
            "Could not secure profile metadata at \(path): \(reason)"
        case let .unsupportedSchemaVersion(version):
            "Profile metadata schema \(version) is not supported by this Vela build."
        case .revisionDataIsEmpty:
            "A profile revision cannot be empty."
        case let .revisionIdentifierCollision(id):
            "A profile revision already exists for identifier \(id.uuidString)."
        case let .revisionNotFound(id):
            "No profile revision exists for identifier \(id.uuidString)."
        case let .revisionWriteFailed(path, reason):
            "Could not write the profile revision at \(path): \(reason)"
        case let .revisionReadFailed(path, reason):
            "Could not read the profile revision at \(path): \(reason)"
        case let .revisionCommitRollbackFailed(path, originalReason, rollbackReason):
            "Could not restore \(path) after the revision commit failed with \(originalReason): \(rollbackReason)"
        case let .interruptedRevisionRecoveryFailed(path, reason):
            "Could not recover the interrupted profile revision at \(path): \(reason)"
        case let .revisionCleanupFailed(path, reason):
            "The revision was committed, but the pruned revision at \(path) could not be removed: \(reason)"
        case let .profileNotFound(id):
            "No profile exists for identifier \(id.uuidString)."
        }
    }
}
