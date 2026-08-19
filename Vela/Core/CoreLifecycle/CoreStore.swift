import CryptoKit
import Darwin
import Foundation
import VelaIPC

nonisolated struct CoreDirectories: Equatable, Sendable {
    let root: URL

    var installed: URL { root.appending(path: "installed", directoryHint: .isDirectory) }
    var staging: URL { root.appending(path: "staging", directoryHint: .isDirectory) }
    var catalogs: URL { root.appending(path: "catalogs", directoryHint: .isDirectory) }
    var stateURL: URL { root.appending(path: "state.json", directoryHint: .notDirectory) }
    var preferencesURL: URL {
        root.appending(path: "preferences.json", directoryHint: .notDirectory)
    }
    var transactionURL: URL {
        root.appending(path: "transaction.json", directoryHint: .notDirectory)
    }
    var installJournalURL: URL {
        root.appending(path: "install-journal.json", directoryHint: .notDirectory)
    }

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    init(applicationDirectories: ApplicationDirectories) {
        self.init(root: applicationDirectories.root.appending(path: "Cores", directoryHint: .isDirectory))
    }

    static func live() throws -> CoreDirectories {
        CoreDirectories(applicationDirectories: try .live())
    }

    func installationDirectory(for coreID: CoreID) -> URL {
        installed.appending(path: storageComponent(for: coreID), directoryHint: .isDirectory)
    }

    func bundleURL(for coreID: CoreID) -> URL {
        installationDirectory(for: coreID)
            .appending(path: "VelaMihomoCore.bundle", directoryHint: .isDirectory)
    }

    func catalogEvidenceDirectory(sha256: String) -> URL {
        catalogs.appending(path: sha256, directoryHint: .isDirectory)
    }

    func storageComponent(for coreID: CoreID) -> String {
        // CoreID's grammar is already closed; replacing its only punctuation that
        // could be interpreted specially by a future URL implementation keeps it one component.
        coreID.rawValue.replacingOccurrences(of: ":", with: "_")
    }
}

actor CoreStore {
    static let privateDirectoryMode = 0o700
    static let privateFileMode = 0o600
    static let maximumStateBytes = 1 * 1_024 * 1_024
    static let maximumTransactionBytes = 64 * 1_024
    static let maximumInstallJournalBytes = 16 * 1_024
    static let maximumReconciliationEntries = 64
    static let maximumInstalledCores = 3

    nonisolated let directories: CoreDirectories

    private let fileManager: FileManager
    private let expectedOwner: uid_t
    /// Non-nil only in the process that created an installation journal. A new
    /// CoreStore actor after app restart has no such marker and may reconcile it.
    private var activeInstallTransactionID: UUID?

    init(
        directories: CoreDirectories,
        fileManager: FileManager = .default,
        expectedOwner: uid_t = getuid()
    ) {
        self.directories = directories
        self.fileManager = fileManager
        self.expectedOwner = expectedOwner
    }

    func loadState(factoryCoreID: CoreID = .factoryV11928) throws -> CoreStoreState {
        try prepare()
        return try readStateWithoutReconciliation(factoryCoreID: factoryCoreID)
    }

    private func readStateWithoutReconciliation(
        factoryCoreID: CoreID
    ) throws -> CoreStoreState {
        guard try metadata(at: directories.stateURL) != nil else {
            return CoreStoreState(activeCoreID: factoryCoreID)
        }
        let data = try readPrivateFile(
            at: directories.stateURL,
            maximumBytes: Self.maximumStateBytes
        )
        do {
            try CoreStrictJSON.validateObject(data, shape: Self.stateShape)
            let state = try CoreJSONCoding.decoder().decode(CoreStoreState.self, from: data)
            try state.validate()
            return state
        } catch let error as CoreStoreError {
            throw error
        } catch {
            throw CoreStoreError.invalidState
        }
    }

    func saveState(_ state: CoreStoreState) throws {
        try state.validate()
        try prepare()
        let data = try CoreJSONCoding.encoder().encode(state)
        try writePrivateFile(data, to: directories.stateURL, maximumBytes: Self.maximumStateBytes)
        try finalizeInstallJournalIfCommitted(by: state)
    }

    func loadPreferences() throws -> CoreSelectionPreferences {
        try prepare()
        guard try metadata(at: directories.preferencesURL) != nil else {
            return CoreSelectionPreferences()
        }
        let data = try readPrivateFile(
            at: directories.preferencesURL,
            maximumBytes: Self.maximumTransactionBytes
        )
        do {
            try CoreStrictJSON.validateObject(data, shape: Self.preferencesShape)
            let preferences = try CoreJSONCoding.decoder().decode(
                CoreSelectionPreferences.self,
                from: data
            )
            try preferences.validate()
            return preferences
        } catch {
            throw CoreStoreError.invalidPreferences
        }
    }

    func savePreferences(_ preferences: CoreSelectionPreferences) throws {
        try preferences.validate()
        try prepare()
        let data = try CoreJSONCoding.encoder().encode(preferences)
        try writePrivateFile(
            data,
            to: directories.preferencesURL,
            maximumBytes: Self.maximumTransactionBytes
        )
    }

    func loadTransaction() throws -> CoreActivationTransaction? {
        try prepare()
        guard try metadata(at: directories.transactionURL) != nil else { return nil }
        let data = try readPrivateFile(
            at: directories.transactionURL,
            maximumBytes: Self.maximumTransactionBytes
        )
        do {
            try CoreStrictJSON.validateObject(data, shape: Self.transactionShape)
            let transaction = try CoreJSONCoding.decoder().decode(
                CoreActivationTransaction.self,
                from: data
            )
            try transaction.validate()
            return transaction
        } catch {
            throw CoreStoreError.invalidTransaction
        }
    }

    /// Creates an activation journal only when none exists. A retained failed
    /// journal is a manual-repair latch and must never be overwritten by a new
    /// activation after a crash.
    func createTransaction(_ transaction: CoreActivationTransaction) throws {
        try transaction.validate()
        try prepare()
        let data = try CoreJSONCoding.encoder().encode(transaction)
        guard data.count <= Self.maximumTransactionBytes else {
            throw CoreStoreError.fileTooLarge
        }
        try withLockedRootDescriptor { rootDescriptor in
            let descriptor = Darwin.openat(
                rootDescriptor,
                "transaction.json",
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(Self.privateFileMode)
            )
            guard descriptor >= 0 else {
                if errno == EEXIST { throw CoreStoreError.transactionAlreadyExists }
                if errno == ELOOP { throw CoreStoreError.symbolicLinkRejected }
                throw CoreStoreError.fileInspectionFailed
            }
            var committed = false
            defer {
                Darwin.close(descriptor)
                if !committed {
                    _ = Darwin.unlinkat(rootDescriptor, "transaction.json", 0)
                }
            }
            try writePrivateData(data, descriptor: descriptor)
            try verifyPrivateFile(
                descriptor: descriptor,
                expectedData: data,
                maximumBytes: Self.maximumTransactionBytes
            )
            guard Darwin.fsync(rootDescriptor) == 0 else {
                throw CoreStoreError.directorySynchronizationFailed
            }
            committed = true
        }
    }

    /// Compare-and-swap update for the one durable activation journal.
    func updateTransaction(
        _ transaction: CoreActivationTransaction,
        expectedID: UUID
    ) throws {
        try transaction.validate()
        guard transaction.transactionID == expectedID else {
            throw CoreStoreError.transactionIdentifierMismatch
        }
        try prepare()
        let data = try CoreJSONCoding.encoder().encode(transaction)
        guard data.count <= Self.maximumTransactionBytes else {
            throw CoreStoreError.fileTooLarge
        }
        // CoreJSONCoding intentionally canonicalizes dates to whole seconds.
        // Compare the durable record with that canonical representation rather
        // than the higher-precision in-memory value that produced it.
        let expectedCommittedTransaction: CoreActivationTransaction
        do {
            expectedCommittedTransaction = try CoreJSONCoding.decoder().decode(
                CoreActivationTransaction.self,
                from: data
            )
            try expectedCommittedTransaction.validate()
        } catch {
            throw CoreStoreError.invalidTransaction
        }
        try withLockedRootDescriptor { rootDescriptor in
            let existing = try openAndDecodeTransaction(rootDescriptor: rootDescriptor)
            defer { Darwin.close(existing.descriptor) }
            guard existing.transaction.transactionID == expectedID else {
                throw CoreStoreError.transactionIdentifierMismatch
            }

            let temporaryName = "transaction-\(expectedID.uuidString.lowercased()).tmp"
            try retireTransactionTemporaryIfSafe(
                named: temporaryName,
                expectedID: expectedID,
                rootDescriptor: rootDescriptor
            )
            let temporary = Darwin.openat(
                rootDescriptor,
                temporaryName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(Self.privateFileMode)
            )
            guard temporary >= 0 else {
                if errno == ELOOP { throw CoreStoreError.symbolicLinkRejected }
                throw CoreStoreError.fileInspectionFailed
            }
            var renamed = false
            defer {
                Darwin.close(temporary)
                if !renamed {
                    _ = Darwin.unlinkat(rootDescriptor, temporaryName, 0)
                }
            }
            try writePrivateData(data, descriptor: temporary)
            try verifyPrivateFile(
                descriptor: temporary,
                expectedData: data,
                maximumBytes: Self.maximumTransactionBytes
            )

            let current = try openAndDecodeTransaction(rootDescriptor: rootDescriptor)
            defer { Darwin.close(current.descriptor) }
            guard current.transaction.transactionID == expectedID,
                current.status.st_dev == existing.status.st_dev,
                current.status.st_ino == existing.status.st_ino
            else { throw CoreStoreError.transactionIdentifierMismatch }
            guard Darwin.renameat(
                rootDescriptor,
                temporaryName,
                rootDescriptor,
                "transaction.json"
            ) == 0 else {
                throw CoreStoreError.writeVerificationFailed
            }
            renamed = true
            let committed = try openAndDecodeTransaction(rootDescriptor: rootDescriptor)
            defer { Darwin.close(committed.descriptor) }
            guard committed.transaction == expectedCommittedTransaction else {
                throw CoreStoreError.writeVerificationFailed
            }
            guard Darwin.fsync(rootDescriptor) == 0 else {
                throw CoreStoreError.directorySynchronizationFailed
            }
        }
    }

    func clearTransaction(expectedID: UUID? = nil) throws {
        try prepare()
        try withLockedRootDescriptor { rootDescriptor in
            let existing: OpenTransaction
            do {
                existing = try openAndDecodeTransaction(rootDescriptor: rootDescriptor)
            } catch CoreStoreError.itemMissing {
                return
            }
            defer { Darwin.close(existing.descriptor) }
            if let expectedID,
                existing.transaction.transactionID != expectedID
            {
                throw CoreStoreError.transactionIdentifierMismatch
            }
            guard Darwin.unlinkat(rootDescriptor, "transaction.json", 0) == 0 else {
                if errno == ENOENT { throw CoreStoreError.transactionIdentifierMismatch }
                throw CoreStoreError.fileInspectionFailed
            }
            guard Darwin.fsync(rootDescriptor) == 0 else {
                throw CoreStoreError.directorySynchronizationFailed
            }
        }
    }

    /// Reconciles a user-store install interrupted by process termination.
    ///
    /// The method never follows a persisted path. Journal components are first
    /// re-derived from transactionID/CoreID and all actual filesystem targets
    /// are selected through CoreDirectories. Call this once during bootstrap,
    /// before resolving an installed Core. `cleanOrphans: false` is used by a
    /// live installation to retire an older valid journal without touching the
    /// caller's current download workspace.
    @discardableResult
    func reconcileInterruptedInstallation(
        factoryCoreID: CoreID = .factoryV11928,
        cleanOrphans: Bool = true
    ) throws -> CoreInstallReconciliationResult {
        try prepare()
        if let activeInstallTransactionID {
            return .installationInProgress(activeInstallTransactionID)
        }
        let state = try readStateWithoutReconciliation(factoryCoreID: factoryCoreID)
        let journal: CoreInstallJournal?
        do {
            journal = try loadInstallJournalAfterPrepare()
        } catch CoreStoreError.invalidInstallJournal {
            try clearInstallJournalAfterPrepare()
            let cleaned = cleanOrphans
                ? try cleanupOrphanArtifacts(state: state)
                : (installations: 0, staging: 0)
            return .discardedUntrustedJournal(
                orphanInstallations: cleaned.installations,
                orphanStaging: cleaned.staging
            )
        }

        guard let journal else {
            guard cleanOrphans else { return .noWork }
            let cleaned = try cleanupOrphanArtifacts(state: state)
            if cleaned.installations == 0, cleaned.staging == 0 { return .noWork }
            return .cleanedOrphans(
                installations: cleaned.installations,
                staging: cleaned.staging
            )
        }

        let staging = directories.staging.appending(
            path: journal.stagingComponent,
            directoryHint: .isDirectory
        )
        let final = directories.installed.appending(
            path: journal.finalComponent,
            directoryHint: .isDirectory
        )
        if let record = state.record(for: journal.coreID) {
            guard journal.matches(record) else {
                // The durable state is authoritative. Retire the untrusted
                // journal without allowing it to select a deletion target.
                try clearInstallJournalAfterPrepare()
                let cleaned = cleanOrphans
                    ? try cleanupOrphanArtifacts(state: state)
                    : (installations: 0, staging: 0)
                return .discardedUntrustedJournal(
                    orphanInstallations: cleaned.installations,
                    orphanStaging: cleaned.staging
                )
            }
            try removePrivateDirectoryIfPresent(staging, coreID: nil)
            guard try metadata(at: final) != nil else {
                try clearInstallJournalAfterPrepare()
                return .committedBundleMissing(coreID: journal.coreID)
            }
            try validateInstallationDirectory(final, coreID: journal.coreID)
            try clearInstallJournalAfterPrepare()
            if cleanOrphans { _ = try cleanupOrphanArtifacts(state: state) }
            return .committed(coreID: journal.coreID)
        }

        // No state record may be synthesized from a mere filesystem move: code,
        // config and smoke preflight could have been interrupted. Remove only
        // the two fixed, re-derived targets so the next download is not wedged.
        try removePrivateDirectoryIfPresent(staging, coreID: nil)
        try removePrivateDirectoryIfPresent(final, coreID: journal.coreID)
        try clearInstallJournalAfterPrepare()
        if cleanOrphans { _ = try cleanupOrphanArtifacts(state: state) }
        return .discarded(coreID: journal.coreID, phase: journal.phase)
    }

    func discardUncommittedInstallation(coreID: CoreID) throws {
        guard !coreID.isFactory else { throw CoreStoreError.protectedCore(coreID) }
        let state = try loadState()
        let transaction = try loadTransaction()
        let installJournal = try loadInstallJournalAfterPrepare()
        let protected = Set(
            [state.activeCoreID, state.previousKnownGoodCoreID, state.pinnedCoreID]
                .compactMap { $0 }
        )
        guard state.record(for: coreID) == nil,
            !protected.contains(coreID),
            transaction?.coreID != coreID
        else {
            throw CoreStoreError.protectedCore(coreID)
        }
        let directory = directories.installationDirectory(for: coreID)
        if let metadata = try metadata(at: directory) {
            try validateRemovalTarget(metadata, coreID: coreID)
            try fileManager.removeItem(at: directory)
            try synchronizeDirectory(directories.installed)
        }
        if let installJournal, installJournal.coreID == coreID {
            let staging = directories.staging.appending(
                path: installJournal.stagingComponent,
                directoryHint: .isDirectory
            )
            try removePrivateDirectoryIfPresent(staging, coreID: nil)
            try clearInstallJournalAfterPrepare(expectedID: installJournal.transactionID)
            activeInstallTransactionID = nil
        }
    }

    func removeInstalledCore(
        coreID: CoreID,
        state: CoreStoreState
    ) throws -> CoreStoreState {
        guard !coreID.isFactory, state.record(for: coreID) != nil else {
            throw CoreStoreError.coreNotInstalled(coreID)
        }
        try state.validate()
        let transaction = try loadTransaction()
        let protected = Set(
            [state.activeCoreID, state.previousKnownGoodCoreID, state.pinnedCoreID]
                .compactMap { $0 }
        )
        guard !protected.contains(coreID), transaction?.coreID != coreID else {
            throw CoreStoreError.protectedCore(coreID)
        }
        let directory = directories.installationDirectory(for: coreID)
        if let metadata = try metadata(at: directory) {
            try validateRemovalTarget(metadata, coreID: coreID)
            try fileManager.removeItem(at: directory)
        }
        var updated = state
        updated.installed.removeAll { $0.coreID == coreID }
        try saveState(updated)
        return updated
    }

    func saveVerifiedCatalog(_ snapshot: CoreCatalogSnapshot) throws {
        guard snapshot.rawBytes.count <= CoreCatalogDecoder.maximumCatalogBytes,
            snapshot.rawSHA256 == CoreCatalogVerifier.sha256(snapshot.rawBytes),
            snapshot.envelope.catalogSHA256 == snapshot.rawSHA256,
            try CoreCatalogDecoder().decodeCatalog(snapshot.rawBytes) == snapshot.catalog
        else {
            throw CoreStoreError.invalidCatalogEvidence
        }
        let envelopeBytes = snapshot.rawEnvelopeBytes
        guard envelopeBytes.count <= CoreCatalogDecoder.maximumEnvelopeBytes else {
            throw CoreStoreError.invalidCatalogEvidence
        }
        try prepare()
        let destination = directories.catalogEvidenceDirectory(sha256: snapshot.rawSHA256)
        if try metadata(at: destination) != nil {
            let existing = try loadCatalogEvidence(sha256: snapshot.rawSHA256)
            guard existing.catalogBytes == snapshot.rawBytes else {
                throw CoreStoreError.catalogEvidenceSubstitution
            }
            if try CoreCatalogDecoder().decodeEnvelope(existing.envelopeBytes)
                != snapshot.envelope
            {
                try writePrivateFile(
                    envelopeBytes,
                    to: destination.appending(path: "core-catalog.signatures.json"),
                    maximumBytes: CoreCatalogDecoder.maximumEnvelopeBytes
                )
            }
            return
        }

        let staging = directories.catalogs.appending(
            path: ".\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try createPrivateDirectory(staging)
        var cleanup = true
        defer { if cleanup { try? fileManager.removeItem(at: staging) } }
        try writePrivateFile(
            snapshot.rawBytes,
            to: staging.appending(path: "core-catalog.json"),
            maximumBytes: CoreCatalogDecoder.maximumCatalogBytes
        )
        try writePrivateFile(
            envelopeBytes,
            to: staging.appending(path: "core-catalog.signatures.json"),
            maximumBytes: CoreCatalogDecoder.maximumEnvelopeBytes
        )
        try fileManager.moveItem(at: staging, to: destination)
        cleanup = false
    }

    func loadCatalogEvidence(sha256: String) throws -> CoreCatalogEvidence {
        guard Self.isSHA256(sha256) else { throw CoreStoreError.invalidCatalogEvidence }
        try prepare()
        let directory = directories.catalogEvidenceDirectory(sha256: sha256)
        let directoryMetadata = try requireMetadata(at: directory)
        guard directoryMetadata.kind == .directory,
            directoryMetadata.owner == expectedOwner,
            directoryMetadata.mode == Self.privateDirectoryMode
        else { throw CoreStoreError.invalidCatalogEvidence }
        let catalogBytes = try readPrivateFile(
            at: directory.appending(path: "core-catalog.json"),
            maximumBytes: CoreCatalogDecoder.maximumCatalogBytes
        )
        let envelopeBytes = try readPrivateFile(
            at: directory.appending(path: "core-catalog.signatures.json"),
            maximumBytes: CoreCatalogDecoder.maximumEnvelopeBytes
        )
        guard CoreCatalogVerifier.sha256(catalogBytes) == sha256 else {
            throw CoreStoreError.catalogEvidenceSubstitution
        }
        return CoreCatalogEvidence(
            sha256: sha256,
            catalogBytes: catalogBytes,
            envelopeBytes: envelopeBytes
        )
    }

    func catalogEntry(
        for record: InstalledCoreRecord,
        verifier: CoreCatalogVerifier
    ) throws -> CoreCatalogEntry {
        try record.validate()
        let evidence = try loadCatalogEvidence(sha256: record.catalogSHA256)
        let snapshot = try verifier.verifyInstalledEvidence(
            catalogBytes: evidence.catalogBytes,
            envelopeBytes: evidence.envelopeBytes,
            expectedSHA256: record.catalogSHA256
        )
        guard snapshot.catalog.sequence == record.catalogSequence,
            let entry = snapshot.catalog.entries.first(where: { $0.coreID == record.coreID }),
            entry.packageRevision == UInt64(record.packageRevision),
            entry.upstreamVersion == record.upstreamVersion
        else {
            throw CoreStoreError.catalogEvidenceRecordMismatch(record.coreID)
        }
        return entry
    }

    func snapshot(
        factoryDescriptor: CoreDescriptor,
        state suppliedState: CoreStoreState? = nil
    ) throws -> CoreStoreSnapshot {
        let state = try suppliedState ?? loadState(factoryCoreID: factoryDescriptor.coreID)
        func descriptor(_ coreID: CoreID?) throws -> CoreDescriptor? {
            guard let coreID else { return nil }
            if coreID.isFactory {
                guard coreID == factoryDescriptor.coreID else {
                    throw CoreStoreError.unavailableCore(coreID)
                }
                return factoryDescriptor
            }
            guard let record = state.record(for: coreID) else {
                throw CoreStoreError.unavailableCore(coreID)
            }
            let value = CoreDescriptor.installed(record: record, directories: directories)
            try verifyInstalledBundlePresence(value)
            return value
        }

        guard let active = try descriptor(state.activeCoreID) else {
            throw CoreStoreError.unavailableCore(state.activeCoreID)
        }
        return CoreStoreSnapshot(
            state: state,
            activeDescriptor: active,
            previousKnownGoodDescriptor: try descriptor(state.previousKnownGoodCoreID),
            pinnedDescriptor: try descriptor(state.pinnedCoreID)
        )
    }

    /// Builds only the seven fixed bundle paths. The caller still must run code-signing,
    /// architecture, version, configuration and smoke preflight before recording installation.
    func reconstructBundle(
        entry: CoreCatalogEntry,
        verifiedFiles: [CoreFileRole: URL],
        catalogIdentity suppliedCatalogIdentity: CoreInstallCatalogIdentity? = nil,
        transactionID: UUID = UUID()
    ) throws -> URL {
        try entry.validate()
        guard !entry.coreID.isFactory,
            Set(verifiedFiles.keys) == Set(CoreFileRole.allCases)
        else {
            throw CoreStoreError.incompleteVerifiedFiles
        }
        try prepare()
        _ = try reconcileInterruptedInstallation(cleanOrphans: false)
        let state = try readStateWithoutReconciliation(factoryCoreID: .factoryV11928)
        let catalogIdentity = try resolveInstallCatalogIdentity(
            suppliedCatalogIdentity,
            state: state
        )
        let finalDirectory = directories.installationDirectory(for: entry.coreID)
        if let finalMetadata = try metadata(at: finalDirectory) {
            if state.record(for: entry.coreID) != nil {
                throw CoreStoreError.installationAlreadyExists(entry.coreID)
            }
            // A missing/corrupt old journal must not permanently wedge this
            // exact CoreID. The fixed target is safe to discard only when no
            // durable state record references it.
            try validateRemovalTarget(finalMetadata, coreID: entry.coreID)
            try fileManager.removeItem(at: finalDirectory)
            try synchronizeDirectory(directories.installed)
        }

        let stagingDirectory = directories.staging
            .appending(path: transactionID.uuidString, directoryHint: .isDirectory)
        guard try metadata(at: stagingDirectory) == nil else {
            throw CoreStoreError.stagingCollision
        }
        guard let packageRevision = Int(exactly: entry.packageRevision) else {
            throw CoreStoreError.invalidInstallJournal
        }
        var journal = CoreInstallJournal(
            transactionID: transactionID,
            coreID: entry.coreID,
            upstreamVersion: entry.upstreamVersion,
            packageRevision: packageRevision,
            catalog: catalogIdentity
        )
        try writeInstallJournal(journal, expecting: nil)
        activeInstallTransactionID = transactionID

        do {
            try createPrivateDirectory(stagingDirectory)
            try synchronizeDirectory(directories.staging)

            let bundleURL = stagingDirectory
                .appending(path: "VelaMihomoCore.bundle", directoryHint: .isDirectory)
            let bundleDirectories = [
                bundleURL,
                bundleURL.appending(path: "Contents", directoryHint: .isDirectory),
                bundleURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory),
                bundleURL.appending(path: "Contents/_CodeSignature", directoryHint: .isDirectory),
                bundleURL.appending(path: "Contents/Resources", directoryHint: .isDirectory),
            ]
            for path in bundleDirectories {
                try createPrivateDirectory(path)
            }

            for descriptor in entry.files {
                guard let source = verifiedFiles[descriptor.role] else {
                    throw CoreStoreError.incompleteVerifiedFiles
                }
                let sourceMetadata = try requireMetadata(at: source)
                guard sourceMetadata.kind == .regular,
                    sourceMetadata.owner == expectedOwner,
                    sourceMetadata.size == descriptor.size,
                    sourceMetadata.mode & 0o022 == 0
                else {
                    throw CoreStoreError.unsafeSourceFile(descriptor.role)
                }
                let bytes = try Data(contentsOf: source, options: [.mappedIfSafe])
                guard UInt64(bytes.count) == descriptor.size,
                    CoreCatalogVerifier.sha256(bytes) == descriptor.sha256
                else {
                    throw CoreStoreError.sourceIntegrityMismatch(descriptor.role)
                }
                let destination = bundleURL.appending(path: descriptor.role.requiredRelativePath)
                try bytes.write(to: destination, options: [.atomic])
                try setMode(descriptor.role.requiredPOSIXMode, at: destination)
                try synchronize(destination)
                try synchronizeDirectory(destination.deletingLastPathComponent())
                let destinationMetadata = try requireMetadata(at: destination)
                guard destinationMetadata.kind == .regular,
                    destinationMetadata.owner == expectedOwner,
                    destinationMetadata.mode == descriptor.role.requiredPOSIXMode,
                    destinationMetadata.size == descriptor.size
                else {
                    throw CoreStoreError.reconstructionVerificationFailed(descriptor.role)
                }
            }

            for directory in bundleDirectories.reversed() {
                try synchronizeDirectory(directory)
            }
            try synchronizeDirectory(stagingDirectory)
            journal.phase = .bundleReady
            try writeInstallJournal(journal, expecting: .preparing)

            journal.phase = .moving
            try writeInstallJournal(journal, expecting: .bundleReady)
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            try synchronizeDirectory(directories.staging)
            try synchronizeDirectory(directories.installed)

            journal.phase = .moved
            try writeInstallJournal(journal, expecting: .moving)
            return finalDirectory.appending(
                path: "VelaMihomoCore.bundle",
                directoryHint: .isDirectory
            )
        } catch {
            try? removePrivateDirectoryIfPresent(stagingDirectory, coreID: nil)
            try? removePrivateDirectoryIfPresent(finalDirectory, coreID: entry.coreID)
            try? clearInstallJournalAfterPrepare(expectedID: transactionID)
            activeInstallTransactionID = nil
            throw error
        }
    }

    /// Applies the max-three policy without deleting active, previous, pinned or
    /// transaction-referenced cores. The returned state has already been persisted.
    func cleanup(
        state: CoreStoreState,
        transaction: CoreActivationTransaction? = nil
    ) throws -> CoreStoreState {
        try state.validate()
        try prepare()
        var protected = Set(
            [state.activeCoreID, state.previousKnownGoodCoreID, state.pinnedCoreID]
                .compactMap { $0 }
                .filter { !$0.isFactory }
        )
        if let coreID = transaction?.coreID, !coreID.isFactory { protected.insert(coreID) }

        let newest = state.installed.sorted { lhs, rhs in
            if lhs.lastUsedAt == rhs.lastUsedAt { return lhs.coreID.rawValue < rhs.coreID.rawValue }
            return lhs.lastUsedAt > rhs.lastUsedAt
        }
        var retained = protected
        for record in newest where retained.count < Self.maximumInstalledCores {
            retained.insert(record.coreID)
        }

        var updated = state
        updated.installed = state.installed.filter { retained.contains($0.coreID) }
        for removed in state.installed where !retained.contains(removed.coreID) {
            let directory = directories.installationDirectory(for: removed.coreID)
            if let metadata = try metadata(at: directory) {
                guard metadata.kind == .directory,
                    metadata.owner == expectedOwner,
                    metadata.mode == Self.privateDirectoryMode
                else {
                    throw CoreStoreError.unsafeCleanupTarget(removed.coreID)
                }
                try fileManager.removeItem(at: directory)
            }
        }
        try saveState(updated)
        return updated
    }

    /// Read-only compatibility probe for launch/update recovery. This function
    /// intentionally does not call `prepare()`: a newer schema must be detected
    /// before CoreStore creates directories, chmods paths, or rewrites bytes.
    func readOnlyStateSchemaVersion() throws -> Int? {
        let rootDescriptor = directories.root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if rootDescriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw CoreStoreError.symbolicLinkRejected }
            if errno == ENOTDIR { throw CoreStoreError.nonDirectoryRejected }
            throw CoreStoreError.fileInspectionFailed
        }
        defer { Darwin.close(rootDescriptor) }
        var rootStatus = stat()
        guard Darwin.fstat(rootDescriptor, &rootStatus) == 0 else {
            throw CoreStoreError.fileInspectionFailed
        }
        guard rootStatus.st_uid == expectedOwner else { throw CoreStoreError.ownerMismatch }
        guard Int(rootStatus.st_mode & 0o7777) == Self.privateDirectoryMode else {
            throw CoreStoreError.unsafePermissions
        }

        let stateDescriptor = Darwin.openat(
            rootDescriptor,
            "state.json",
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if stateDescriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw CoreStoreError.symbolicLinkRejected }
            throw CoreStoreError.fileInspectionFailed
        }
        defer { Darwin.close(stateDescriptor) }
        var before = stat()
        guard Darwin.fstat(stateDescriptor, &before) == 0 else {
            throw CoreStoreError.fileInspectionFailed
        }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw CoreStoreError.nonRegularFileRejected
        }
        guard before.st_uid == expectedOwner else { throw CoreStoreError.ownerMismatch }
        guard Int(before.st_mode & 0o7777) == Self.privateFileMode else {
            throw CoreStoreError.unsafePermissions
        }
        guard before.st_size >= 0,
            UInt64(before.st_size) <= UInt64(Self.maximumStateBytes)
        else {
            throw CoreStoreError.fileTooLarge
        }
        let data = try readBounded(
            descriptor: stateDescriptor,
            maximumBytes: Self.maximumStateBytes
        )
        var after = stat()
        guard Darwin.fstat(stateDescriptor, &after) == 0 else {
            throw CoreStoreError.fileInspectionFailed
        }
        guard before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            data.count == Int(after.st_size)
        else {
            throw CoreStoreError.fileChangedDuringRead
        }
        do {
            return try JSONDecoder().decode(StateSchemaVersionProbe.self, from: data).schemaVersion
        } catch {
            throw CoreStoreError.invalidState
        }
    }

    private func resolveInstallCatalogIdentity(
        _ supplied: CoreInstallCatalogIdentity?,
        state: CoreStoreState
    ) throws -> CoreInstallCatalogIdentity {
        let identity: CoreInstallCatalogIdentity
        if let supplied {
            identity = supplied
        } else {
            guard state.highestCatalogSequence > 0,
                let sha256 = state.lastCatalogSHA256
            else {
                throw CoreStoreError.missingInstallCatalogIdentity
            }
            identity = CoreInstallCatalogIdentity(
                sequence: state.highestCatalogSequence,
                sha256: sha256
            )
        }
        do {
            try identity.validate()
        } catch {
            throw CoreStoreError.invalidInstallJournal
        }
        if state.highestCatalogSequence > 0 {
            guard identity.sequence == state.highestCatalogSequence,
                identity.sha256 == state.lastCatalogSHA256
            else {
                throw CoreStoreError.installCatalogCheckpointMismatch
            }
        }
        return identity
    }

    private func loadInstallJournalAfterPrepare() throws -> CoreInstallJournal? {
        guard let journalMetadata = try metadata(at: directories.installJournalURL) else {
            return nil
        }
        guard journalMetadata.kind == .regular else {
            throw journalMetadata.kind == .symbolicLink
                ? CoreStoreError.symbolicLinkRejected
                : CoreStoreError.nonRegularFileRejected
        }
        guard journalMetadata.owner == expectedOwner else { throw CoreStoreError.ownerMismatch }
        guard journalMetadata.mode == Self.privateFileMode else {
            throw CoreStoreError.unsafePermissions
        }
        guard journalMetadata.size <= UInt64(Self.maximumInstallJournalBytes) else {
            throw CoreStoreError.invalidInstallJournal
        }
        let data = try readPrivateFile(
            at: directories.installJournalURL,
            maximumBytes: Self.maximumInstallJournalBytes
        )
        do {
            try CoreStrictJSON.validateObject(data, shape: Self.installJournalShape)
            let journal = try CoreJSONCoding.decoder().decode(CoreInstallJournal.self, from: data)
            try journal.validate()
            return journal
        } catch let error as CoreStoreError {
            throw error
        } catch {
            throw CoreStoreError.invalidInstallJournal
        }
    }

    private func writeInstallJournal(
        _ journal: CoreInstallJournal,
        expecting expectedPhase: CoreInstallJournalPhase?
    ) throws {
        do {
            try journal.validate()
        } catch {
            throw CoreStoreError.invalidInstallJournal
        }
        let existing = try loadInstallJournalAfterPrepare()
        if let expectedPhase {
            guard let existing,
                existing.transactionID == journal.transactionID,
                existing.coreID == journal.coreID,
                existing.upstreamVersion == journal.upstreamVersion,
                existing.packageRevision == journal.packageRevision,
                existing.catalog == journal.catalog,
                Int64(existing.startedAt.timeIntervalSince1970)
                    == Int64(journal.startedAt.timeIntervalSince1970),
                existing.stagingComponent == journal.stagingComponent,
                existing.finalComponent == journal.finalComponent,
                existing.phase == expectedPhase,
                existing.phase.canAdvance(to: journal.phase)
            else {
                throw CoreStoreError.installJournalTransitionRejected
            }
        } else if existing != nil {
            throw CoreStoreError.installJournalAlreadyExists
        }
        let data = try CoreJSONCoding.encoder().encode(journal)
        try writePrivateFile(
            data,
            to: directories.installJournalURL,
            maximumBytes: Self.maximumInstallJournalBytes
        )
    }

    private func finalizeInstallJournalIfCommitted(by state: CoreStoreState) throws {
        guard var journal = try loadInstallJournalAfterPrepare(),
            let record = state.record(for: journal.coreID)
        else { return }
        guard journal.matches(record), journal.phase == .moved || journal.phase == .stateCommitted else {
            throw CoreStoreError.installJournalStateMismatch(journal.coreID)
        }
        let final = directories.installationDirectory(for: journal.coreID)
        try validateInstallationDirectory(final, coreID: journal.coreID)
        if journal.phase == .moved {
            journal.phase = .stateCommitted
            try writeInstallJournal(journal, expecting: .moved)
        }
        try clearInstallJournalAfterPrepare(expectedID: journal.transactionID)
        if activeInstallTransactionID == journal.transactionID {
            activeInstallTransactionID = nil
        }
    }

    private func clearInstallJournalAfterPrepare(expectedID: UUID? = nil) throws {
        guard let journalMetadata = try metadata(at: directories.installJournalURL) else {
            return
        }
        guard journalMetadata.kind == .regular else {
            throw journalMetadata.kind == .symbolicLink
                ? CoreStoreError.symbolicLinkRejected
                : CoreStoreError.nonRegularFileRejected
        }
        guard journalMetadata.owner == expectedOwner else { throw CoreStoreError.ownerMismatch }
        guard journalMetadata.mode == Self.privateFileMode else {
            throw CoreStoreError.unsafePermissions
        }
        if let expectedID {
            guard try loadInstallJournalAfterPrepare()?.transactionID == expectedID else {
                throw CoreStoreError.installJournalIdentifierMismatch
            }
        }
        try fileManager.removeItem(at: directories.installJournalURL)
        try synchronizeDirectory(directories.root)
    }

    private func cleanupOrphanArtifacts(
        state: CoreStoreState
    ) throws -> (installations: Int, staging: Int) {
        let retained = Set(state.installed.map { directories.storageComponent(for: $0.coreID) })
        let installationEntries = try boundedDirectoryEntries(at: directories.installed)
        var removedInstallations = 0
        for component in installationEntries {
            let target = directories.installed.appending(
                path: component,
                directoryHint: .isDirectory
            )
            let targetMetadata = try requireMetadata(at: target)
            guard targetMetadata.kind == .directory else {
                throw targetMetadata.kind == .symbolicLink
                    ? CoreStoreError.symbolicLinkRejected
                    : CoreStoreError.unsafeInstallArtifact
            }
            guard targetMetadata.owner == expectedOwner,
                targetMetadata.mode == Self.privateDirectoryMode
            else {
                throw CoreStoreError.unsafePermissions
            }
            if !retained.contains(component) {
                try fileManager.removeItem(at: target)
                removedInstallations += 1
            }
        }
        if removedInstallations > 0 {
            try synchronizeDirectory(directories.installed)
        }

        let stagingEntries = try boundedDirectoryEntries(at: directories.staging)
        var removedStaging = 0
        for component in stagingEntries {
            let target = directories.staging.appending(
                path: component,
                directoryHint: .isDirectory
            )
            let targetMetadata = try requireMetadata(at: target)
            guard targetMetadata.kind == .directory else {
                throw targetMetadata.kind == .symbolicLink
                    ? CoreStoreError.symbolicLinkRejected
                    : CoreStoreError.unsafeInstallArtifact
            }
            guard targetMetadata.owner == expectedOwner,
                targetMetadata.mode == Self.privateDirectoryMode
            else {
                throw CoreStoreError.unsafePermissions
            }
            try fileManager.removeItem(at: target)
            removedStaging += 1
        }
        if removedStaging > 0 {
            try synchronizeDirectory(directories.staging)
        }
        return (removedInstallations, removedStaging)
    }

    private func boundedDirectoryEntries(at directory: URL) throws -> [String] {
        let entries = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
        guard entries.count <= Self.maximumReconciliationEntries else {
            throw CoreStoreError.tooManyInstallArtifacts
        }
        guard entries.allSatisfy(Self.isSafeArtifactComponent) else {
            throw CoreStoreError.unsafeInstallArtifact
        }
        return entries
    }

    private func removePrivateDirectoryIfPresent(
        _ directory: URL,
        coreID: CoreID?
    ) throws {
        guard let value = try metadata(at: directory) else { return }
        guard value.kind == .directory else {
            throw value.kind == .symbolicLink
                ? CoreStoreError.symbolicLinkRejected
                : coreID.map(CoreStoreError.unsafeCleanupTarget)
                    ?? CoreStoreError.unsafeInstallArtifact
        }
        guard value.owner == expectedOwner, value.mode == Self.privateDirectoryMode else {
            throw coreID.map(CoreStoreError.unsafeCleanupTarget)
                ?? CoreStoreError.unsafePermissions
        }
        try fileManager.removeItem(at: directory)
        try synchronizeDirectory(directory.deletingLastPathComponent())
    }

    private func validateInstallationDirectory(_ directory: URL, coreID: CoreID) throws {
        let value = try requireMetadata(at: directory)
        try validateRemovalTarget(value, coreID: coreID)
    }

    private func prepare() throws {
        for directory in [
            directories.root, directories.installed, directories.staging, directories.catalogs,
        ] {
            if let existing = try metadata(at: directory) {
                guard existing.kind == .directory else {
                    throw existing.kind == .symbolicLink
                        ? CoreStoreError.symbolicLinkRejected
                        : CoreStoreError.nonDirectoryRejected
                }
                guard existing.owner == expectedOwner else { throw CoreStoreError.ownerMismatch }
            } else {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            try setMode(Self.privateDirectoryMode, at: directory)
            let verified = try requireMetadata(at: directory)
            guard verified.kind == .directory,
                verified.owner == expectedOwner,
                verified.mode == Self.privateDirectoryMode
            else {
                throw CoreStoreError.unsafePermissions
            }
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        if let existing = try metadata(at: url) {
            guard existing.kind == .directory, existing.owner == expectedOwner else {
                throw CoreStoreError.nonDirectoryRejected
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
        try setMode(Self.privateDirectoryMode, at: url)
    }

    private struct OpenTransaction {
        let descriptor: Int32
        let status: stat
        let transaction: CoreActivationTransaction
    }

    private func withLockedRootDescriptor<T>(
        _ body: (Int32) throws -> T
    ) throws -> T {
        let rootDescriptor = directories.root.withUnsafeFileSystemRepresentation {
            path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else {
            if errno == ELOOP { throw CoreStoreError.symbolicLinkRejected }
            if errno == ENOTDIR { throw CoreStoreError.nonDirectoryRejected }
            throw CoreStoreError.fileInspectionFailed
        }
        defer { Darwin.close(rootDescriptor) }

        var anchored = stat()
        guard Darwin.fstat(rootDescriptor, &anchored) == 0,
            anchored.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            anchored.st_uid == expectedOwner,
            Int(anchored.st_mode & 0o7777) == Self.privateDirectoryMode
        else { throw CoreStoreError.unsafePermissions }
        guard flock(rootDescriptor, LOCK_EX) == 0 else {
            throw CoreStoreError.fileInspectionFailed
        }
        defer { _ = flock(rootDescriptor, LOCK_UN) }

        let result = try body(rootDescriptor)

        let currentDescriptor = directories.root.withUnsafeFileSystemRepresentation {
            path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard currentDescriptor >= 0 else {
            throw CoreStoreError.fileChangedDuringRead
        }
        defer { Darwin.close(currentDescriptor) }
        var current = stat()
        guard Darwin.fstat(currentDescriptor, &current) == 0,
            current.st_dev == anchored.st_dev,
            current.st_ino == anchored.st_ino
        else { throw CoreStoreError.fileChangedDuringRead }
        return result
    }

    private func openAndDecodeTransaction(
        named name: String = "transaction.json",
        rootDescriptor: Int32
    ) throws -> OpenTransaction {
        let descriptor = Darwin.openat(
            rootDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw CoreStoreError.itemMissing }
            if errno == ELOOP { throw CoreStoreError.symbolicLinkRejected }
            throw CoreStoreError.fileInspectionFailed
        }
        do {
            var before = stat()
            guard Darwin.fstat(descriptor, &before) == 0,
                before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                before.st_uid == expectedOwner,
                Int(before.st_mode & 0o7777) == Self.privateFileMode,
                before.st_size >= 0,
                UInt64(before.st_size) <= UInt64(Self.maximumTransactionBytes)
            else { throw CoreStoreError.unsafePermissions }
            guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
                throw CoreStoreError.fileInspectionFailed
            }
            let data = try readBounded(
                descriptor: descriptor,
                maximumBytes: Self.maximumTransactionBytes
            )
            var after = stat()
            guard Darwin.fstat(descriptor, &after) == 0,
                before.st_dev == after.st_dev,
                before.st_ino == after.st_ino,
                before.st_size == after.st_size,
                data.count == Int(after.st_size)
            else { throw CoreStoreError.fileChangedDuringRead }
            try CoreStrictJSON.validateObject(data, shape: Self.transactionShape)
            let transaction = try CoreJSONCoding.decoder().decode(
                CoreActivationTransaction.self,
                from: data
            )
            try transaction.validate()
            return OpenTransaction(
                descriptor: descriptor,
                status: after,
                transaction: transaction
            )
        } catch {
            Darwin.close(descriptor)
            if error is CoreStoreError { throw error }
            throw CoreStoreError.invalidTransaction
        }
    }

    private func retireTransactionTemporaryIfSafe(
        named name: String,
        expectedID: UUID,
        rootDescriptor: Int32
    ) throws {
        let existing: OpenTransaction
        do {
            existing = try openAndDecodeTransaction(
                named: name,
                rootDescriptor: rootDescriptor
            )
        } catch CoreStoreError.itemMissing {
            return
        }
        defer { Darwin.close(existing.descriptor) }
        guard existing.transaction.transactionID == expectedID else {
            throw CoreStoreError.transactionIdentifierMismatch
        }
        guard Darwin.unlinkat(rootDescriptor, name, 0) == 0 else {
            throw CoreStoreError.fileInspectionFailed
        }
        guard Darwin.fsync(rootDescriptor) == 0 else {
            throw CoreStoreError.directorySynchronizationFailed
        }
    }

    private func writePrivateData(_ data: Data, descriptor: Int32) throws {
        guard Darwin.fchmod(descriptor, mode_t(Self.privateFileMode)) == 0 else {
            throw CoreStoreError.unsafePermissions
        }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw CoreStoreError.writeVerificationFailed
            }
            guard count > 0 else { throw CoreStoreError.writeVerificationFailed }
            offset += count
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw CoreStoreError.writeVerificationFailed
        }
    }

    private func verifyPrivateFile(
        descriptor: Int32,
        expectedData: Data,
        maximumBytes: Int
    ) throws {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
            before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            before.st_uid == expectedOwner,
            Int(before.st_mode & 0o7777) == Self.privateFileMode,
            before.st_size == off_t(expectedData.count),
            before.st_size >= 0,
            UInt64(before.st_size) <= UInt64(maximumBytes),
            Darwin.lseek(descriptor, 0, SEEK_SET) >= 0
        else { throw CoreStoreError.writeVerificationFailed }
        let persisted = try readBounded(
            descriptor: descriptor,
            maximumBytes: maximumBytes
        )
        var after = stat()
        guard persisted == expectedData,
            Darwin.fstat(descriptor, &after) == 0,
            before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size
        else { throw CoreStoreError.writeVerificationFailed }
    }

    private func writePrivateFile(_ data: Data, to url: URL, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else { throw CoreStoreError.fileTooLarge }
        if let existing = try metadata(at: url) {
            guard existing.kind == .regular,
                existing.owner == expectedOwner,
                existing.mode == Self.privateFileMode
            else {
                throw existing.kind == .symbolicLink
                    ? CoreStoreError.symbolicLinkRejected
                    : CoreStoreError.unsafePermissions
            }
        }
        try data.write(to: url, options: [.atomic])
        try setMode(Self.privateFileMode, at: url)
        try synchronize(url)
        let verified = try requireMetadata(at: url)
        guard verified.kind == .regular,
            verified.owner == expectedOwner,
            verified.mode == Self.privateFileMode,
            verified.size == UInt64(data.count)
        else {
            throw CoreStoreError.writeVerificationFailed
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func readPrivateFile(at url: URL, maximumBytes: Int) throws -> Data {
        let before = try requireMetadata(at: url)
        guard before.kind == .regular else {
            throw before.kind == .symbolicLink
                ? CoreStoreError.symbolicLinkRejected
                : CoreStoreError.nonRegularFileRejected
        }
        guard before.owner == expectedOwner else { throw CoreStoreError.ownerMismatch }
        guard before.mode == Self.privateFileMode else { throw CoreStoreError.unsafePermissions }
        guard before.size <= UInt64(maximumBytes) else { throw CoreStoreError.fileTooLarge }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let after = try requireMetadata(at: url)
        guard before.device == after.device,
            before.inode == after.inode,
            before.size == after.size,
            data.count == Int(after.size)
        else {
            throw CoreStoreError.fileChangedDuringRead
        }
        return data
    }

    private func readBounded(descriptor: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
        while result.count <= maximumBytes {
            let capacity = min(buffer.count, maximumBytes + 1 - result.count)
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, capacity)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw CoreStoreError.fileInspectionFailed
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count <= maximumBytes else { throw CoreStoreError.fileTooLarge }
        return result
    }

    private func verifyInstalledBundlePresence(_ descriptor: CoreDescriptor) throws {
        let bundle = try requireMetadata(at: descriptor.bundleURL)
        let executable = try requireMetadata(at: descriptor.executableURL)
        guard bundle.kind == .directory,
            bundle.owner == expectedOwner,
            executable.kind == .regular,
            executable.owner == expectedOwner,
            executable.mode == CoreFileRole.executable.requiredPOSIXMode
        else {
            throw CoreStoreError.unavailableCore(descriptor.coreID)
        }
    }

    private func validateRemovalTarget(_ metadata: Metadata, coreID: CoreID) throws {
        guard metadata.kind == .directory,
            metadata.owner == expectedOwner,
            metadata.mode == Self.privateDirectoryMode
        else {
            if metadata.kind == .symbolicLink { throw CoreStoreError.symbolicLinkRejected }
            throw CoreStoreError.unsafeCleanupTarget(coreID)
        }
    }

    private func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CoreStoreError.directorySynchronizationFailed }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw CoreStoreError.directorySynchronizationFailed
        }
    }

    private func setMode(_ mode: Int, at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
    }

    private func requireMetadata(at url: URL) throws -> Metadata {
        guard let value = try metadata(at: url) else { throw CoreStoreError.itemMissing }
        return value
    }

    private func metadata(at url: URL) throws -> Metadata? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw CoreStoreError.fileInspectionFailed
        }
        let kind: Metadata.Kind = switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): .regular
        case mode_t(S_IFDIR): .directory
        case mode_t(S_IFLNK): .symbolicLink
        default: .other
        }
        return Metadata(
            kind: kind,
            owner: status.st_uid,
            mode: Int(status.st_mode & 0o7777),
            size: UInt64(max(status.st_size, 0)),
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }

    private struct Metadata {
        enum Kind { case regular, directory, symbolicLink, other }
        let kind: Kind
        let owner: uid_t
        let mode: Int
        let size: UInt64
        let device: UInt64
        let inode: UInt64
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    private static func isSafeArtifactComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.utf8.count <= 128,
            value != ".",
            value != ".."
        else { return false }
        return value.utf8.allSatisfy {
            (48 ... 57).contains($0)
                || (65 ... 90).contains($0)
                || (97 ... 122).contains($0)
                || $0 == 45
                || $0 == 46
                || $0 == 95
        }
    }

    private struct StateSchemaVersionProbe: Decodable {
        let schemaVersion: Int
    }

    private static let recordShape = CoreJSONShape(
        allowedKeys: [
            "coreID", "upstreamVersion", "packageRevision", "catalogSequence",
            "catalogSHA256", "installedAt", "lastUsedAt", "status", "validationFailures",
            "activationFailures", "unexpectedExits", "lastFailurePhase", "lastFailureAt",
        ]
    )
    private static let stateShape = CoreJSONShape(
        allowedKeys: [
            "schemaVersion", "activeCoreID", "previousKnownGoodCoreID", "pinnedCoreID",
            "installed", "highestCatalogSequence", "lastCatalogSHA256",
        ],
        arrays: ["installed": recordShape]
    )
    private static let preferencesShape = CoreJSONShape(
        allowedKeys: [
            "schemaVersion", "mode", "pinnedCoreID", "automaticallyCheckForUpdates",
            "automaticallyDownloadRecommended",
        ]
    )
    private static let transactionProxySelectionShape = CoreJSONShape(
        allowedKeys: ["groupID", "proxyID"]
    )
    private static let transactionSnapshotShape = CoreJSONShape(
        allowedKeys: [
            "previousCoreID", "backend", "profileID", "profileRevisionID", "sceneID",
            "mihomoMode", "proxySelections", "systemProxyDesired",
            "configurationGenerationID",
        ],
        arrays: ["proxySelections": transactionProxySelectionShape]
    )
    private static let transactionShape = CoreJSONShape(
        allowedKeys: [
            "schemaVersion", "transactionID", "coreID", "phase", "startedAt", "snapshot",
            "automaticRollbackAttempts",
        ],
        objects: ["snapshot": transactionSnapshotShape]
    )
    private static let installCatalogIdentityShape = CoreJSONShape(
        allowedKeys: ["sequence", "sha256"]
    )
    private static let installJournalShape = CoreJSONShape(
        allowedKeys: [
            "schemaVersion", "transactionID", "coreID", "upstreamVersion",
            "packageRevision", "catalog", "startedAt", "phase",
            "stagingComponent", "finalComponent",
        ],
        objects: ["catalog": installCatalogIdentityShape]
    )
}

nonisolated enum CoreStoreError: Error, Equatable, Sendable {
    case symbolicLinkRejected
    case nonDirectoryRejected
    case nonRegularFileRejected
    case ownerMismatch
    case unsafePermissions
    case fileTooLarge
    case fileChangedDuringRead
    case fileInspectionFailed
    case itemMissing
    case writeVerificationFailed
    case invalidState
    case invalidPreferences
    case invalidTransaction
    case transactionAlreadyExists
    case transactionIdentifierMismatch
    case unavailableCore(CoreID)
    case incompleteVerifiedFiles
    case installationAlreadyExists(CoreID)
    case stagingCollision
    case unsafeSourceFile(CoreFileRole)
    case sourceIntegrityMismatch(CoreFileRole)
    case reconstructionVerificationFailed(CoreFileRole)
    case unsafeCleanupTarget(CoreID)
    case invalidCatalogEvidence
    case catalogEvidenceSubstitution
    case catalogEvidenceRecordMismatch(CoreID)
    case protectedCore(CoreID)
    case coreNotInstalled(CoreID)
    case invalidInstallJournal
    case missingInstallCatalogIdentity
    case installCatalogCheckpointMismatch
    case installJournalAlreadyExists
    case installJournalTransitionRejected
    case installJournalIdentifierMismatch
    case installJournalStateMismatch(CoreID)
    case unsafeInstallArtifact
    case tooManyInstallArtifacts
    case directorySynchronizationFailed
}

nonisolated struct CoreCatalogEvidence: Equatable, Sendable {
    let sha256: String
    let catalogBytes: Data
    let envelopeBytes: Data
}
