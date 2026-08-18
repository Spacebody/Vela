import CryptoKit
import Darwin
import Foundation
import VelaIPC

public enum RootCoreInstallPhase: String, Codable, Sendable {
    case staging
    case validated
    case promoted
}

public struct RootInstalledCoreRecord: Codable, Equatable, Sendable {
    public let descriptor: InstalledCoreDescriptor
    public let catalogSHA256: String
    public let rawCatalogData: Data
    public let signatureEnvelopeData: Data
    public let status: VerifiedCoreCatalogStatus
    public let blockReason: String?
    public let compatibility: VerifiedCoreCompatibilityConstraints
    public let files: [RootCoreFileRecord]
}

public struct RootCoreFileRecord: Codable, Equatable, Sendable {
    public let role: CoreFileRole
    public let expectedSize: Int
    public let expectedSHA256: String
    public var staged: Bool
}

public struct RootCoreStoreState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public let schemaVersion: Int
    public var activeCoreID: CoreID
    public var previousKnownGoodCoreID: CoreID?
    public var pinnedCoreID: CoreID?
    public var highestCatalogSequence: UInt64
    public var lastCatalogSHA256: String?
    public var installed: [RootInstalledCoreRecord]
}

public struct RootCoreInstallTransaction: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3
    public let schemaVersion: Int
    public let transactionID: UUID
    public let sessionID: UUID
    public let ownerUID: UInt32
    public let coreID: CoreID
    public let upstreamVersion: String
    public let packageRevision: Int
    public let catalogSequence: UInt64
    public let catalogSHA256: String
    public let rawCatalogData: Data
    public let signatureEnvelopeData: Data
    public let status: VerifiedCoreCatalogStatus
    public let blockReason: String?
    public let compatibility: VerifiedCoreCompatibilityConstraints
    public let createdAt: Date
    /// A bounded, fixed-ID cleanup reservation used only when the store is at
    /// capacity. It never names an App-provided path.
    public var evictionCoreID: CoreID?
    public var files: [RootCoreFileRecord]
    public var stagingIdentity: POSIXFileIdentity
    public var phase: RootCoreInstallPhase
}

public protocol RootCoreBundlePreflighting: Sendable {
    func validate(
        bundleRelativePath: SafeRelativePath,
        selection: VerifiedCoreCatalogSelection
    ) async throws
}

public struct RootCoreBundlePreflight: RootCoreBundlePreflighting, Sendable {
    private let fileSystem: POSIXRootFileSystem
    private let expectedTeamIdentifier: String
    private let signingInspector: any PrivilegedCodeSigningInspecting
    private let versionProbe: any FixedMihomoVersionProbing

    public init(
        fileSystem: POSIXRootFileSystem,
        expectedTeamIdentifier: String,
        signingInspector: any PrivilegedCodeSigningInspecting =
            SecurityPrivilegedCodeSigningInspector(),
        versionProbe: any FixedMihomoVersionProbing = FoundationFixedMihomoVersionProbe()
    ) {
        self.fileSystem = fileSystem
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.signingInspector = signingInspector
        self.versionProbe = versionProbe
    }

    public func validate(
        bundleRelativePath: SafeRelativePath,
        selection: VerifiedCoreCatalogSelection
    ) async throws {
        let infoPath = try bundleRelativePath.appending("Contents")
            .appending("Info.plist")
        let executablePath = try bundleRelativePath.appending("Contents")
            .appending("MacOS").appending("mihomo")
        let infoData = try fileSystem.readData(at: infoPath, maximumBytes: 8 * 1_024 * 1_024)
        let info = try PropertyListDecoder().decode(CoreBundleInfo.self, from: infoData)
        guard info.bundleIdentifier == VelaIPCConstants.expectedExternalCoreSigningIdentifier,
            info.bundleName == "Vela Mihomo Core",
            info.bundlePackageType == "BNDL",
            info.bundleExecutable == "mihomo",
            info.bundleShortVersion == String(selection.upstreamVersion.dropFirst()),
            info.bundleVersion == String(selection.packageRevision),
            info.minimumSystemVersion == "15.0",
            info.coreVersion == selection.upstreamVersion,
            info.corePackageRevision == selection.packageRevision,
            info.coreArchitecture == "arm64"
        else { throw RootCoreStoreError.preflightFailed }

        let executableIdentity = try fileSystem.trustedExecutableIdentity(at: executablePath)
        guard executableIdentity.size > 0,
            executableIdentity.size <= Int64(VelaIPCConstants.maximumMihomoExecutableBytes),
            try inspectThinARM64(at: executablePath)
        else { throw RootCoreStoreError.preflightFailed }

        let bundleURL = url(for: bundleRelativePath)
        let signatureRequirement: PrivilegedCodeSigningRequirement
        let signature: PrivilegedCodeSignature
        do {
            signatureRequirement = try .appleGeneric(
                identifier: VelaIPCConstants.expectedExternalCoreSigningIdentifier,
                teamIdentifier: expectedTeamIdentifier
            )
            signature = try signingInspector.inspect(
                at: bundleURL,
                validateNestedCode: true,
                requirement: signatureRequirement
            )
        } catch {
            throw RootCoreStoreError.preflightFailed
        }
        guard signature.signingIdentifier
                == VelaIPCConstants.expectedExternalCoreSigningIdentifier,
            signature.teamIdentifier == expectedTeamIdentifier
        else { throw RootCoreStoreError.preflightFailed }

        let probeRoot = url(for: bundleRelativePath)
        let result = try await versionProbe.probe(
            executableURL: url(for: executablePath),
            workingDirectoryURL: probeRoot
        )
        guard !result.timedOut,
            result.status == 0,
            result.output.split(whereSeparator: \.isNewline).contains(where: { line in
                let words = line.split(whereSeparator: \.isWhitespace)
                return words.count >= 5
                    && words[0] == "Mihomo"
                    && words[1] == "Meta"
                    && words[2] == Substring(selection.upstreamVersion)
                    && words[3] == "darwin"
                    && words[4] == "arm64"
            })
        else { throw RootCoreStoreError.preflightFailed }

        guard let executableDescriptor = selection.files.first(where: {
            $0.role == .executable
        }), let compatibilityDescriptor = selection.files.first(where: {
            $0.role == .compatibility
        }) else { throw RootCoreStoreError.preflightFailed }
        let executableData = try fileSystem.readTrustedExecutableData(
            at: executablePath,
            maximumBytes: CoreFileRole.executable.maximumBytes
        )
        let compatibilityPath = try bundleRelativePath.appending("Contents")
            .appending("Resources").appending("compatibility.json")
        let compatibilityData = try fileSystem.readData(
            at: compatibilityPath,
            maximumBytes: CoreFileRole.compatibility.maximumBytes
        )
        let executableSHA256 = IntegrityValue.sha256Hex(of: executableData)
        let compatibilitySHA256 = IntegrityValue.sha256Hex(of: compatibilityData)
        guard executableData.count == executableDescriptor.expectedSize,
            executableSHA256 == executableDescriptor.expectedSHA256,
            compatibilityData.count == compatibilityDescriptor.expectedSize,
            compatibilitySHA256 == compatibilityDescriptor.expectedSHA256,
            compatibilitySHA256
                == selection.compatibility.compatibilityReportSHA256
        else { throw RootCoreStoreError.preflightFailed }
        try RootCoreCompatibilityReportValidator.validate(
            compatibilityData,
            selection: selection,
            executableSHA256: executableSHA256
        )

        let finalSignature: PrivilegedCodeSignature
        do {
            finalSignature = try signingInspector.inspect(
                at: bundleURL,
                validateNestedCode: true,
                requirement: signatureRequirement
            )
        } catch {
            throw RootCoreStoreError.preflightFailed
        }
        guard finalSignature == signature,
            try fileSystem.trustedExecutableIdentity(at: executablePath) == executableIdentity
        else { throw RootCoreStoreError.preflightFailed }
    }

    private func inspectThinARM64(at path: SafeRelativePath) throws -> Bool {
        let data = try fileSystem.readTrustedExecutableData(at: path, maximumBytes: 8)
        guard data.count == 8 else { return false }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard magic == UInt32(MH_MAGIC_64) else { return false }
        let cpuType = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: Int32.self)
        }.littleEndian
        return cpuType == CPU_TYPE_ARM64
    }

    private func url(for path: SafeRelativePath) -> URL {
        path.components.reduce(fileSystem.rootURL) { $0.appending(path: $1) }
    }
}

/// Root-owned, no-follow Core Store. Every on-disk path comes from fixed role
/// tables or a canonical CoreID/UUID, never from an XPC path value.
public actor RootCoreStore {
    private let fileSystem: POSIXRootFileSystem
    private let verifier: any PrivilegedCoreCatalogVerifying
    private let preflight: any RootCoreBundlePreflighting
    private let factoryCoreID: CoreID
    private let now: @Sendable () -> Date
    private var state: RootCoreStoreState?
    private var transaction: RootCoreInstallTransaction?

    public init(
        fileSystem: POSIXRootFileSystem,
        verifier: any PrivilegedCoreCatalogVerifying,
        preflight: any RootCoreBundlePreflighting,
        factoryCoreID: CoreID = .factoryV11928,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileSystem = fileSystem
        self.verifier = verifier
        self.preflight = preflight
        self.factoryCoreID = factoryCoreID
        self.now = now
    }

    public func prepareAtStartup() async throws {
        try ensureContainers()
        try cleanupAtomicJournalArtifacts()
        state = try loadOrCreateState()
        try validateCoreRootLayout()
        try await recoverTransactionIfNeeded()
        try cleanupOrphanStaging()
        try validateInstalledDirectorySet()
        if let active = state?.activeCoreID, !active.isFactory {
            do {
                _ = try await validate(active, requestID: UUID())
            } catch RootCoreStoreError.policyRejected {
                // A newly signed blocked/incompatible status is advisory for an
                // already-active Core. Preserve the selection and let the App
                // show the incident; the next explicit start remains rejected.
            } catch {
                var recovered = try requiredState()
                recovered.activeCoreID = factoryCoreID
                recovered.previousKnownGoodCoreID = nil
                try saveState(recovered)
                state = recovered
            }
        }
    }

    public func prepareInstall(
        _ request: PrepareCoreInstallRequest,
        authenticatedOwnerUID: UInt32
    ) throws -> PrepareCoreInstallResponse {
        guard transaction == nil else { throw RootCoreStoreError.transactionActive }
        guard request.ownerUID == authenticatedOwnerUID,
            !request.selectedCoreID.isFactory
        else { throw RootCoreStoreError.ownerMismatch }
        let current = try requiredState()
        guard !current.installed.contains(where: { $0.descriptor.coreID == request.selectedCoreID })
        else { throw RootCoreStoreError.alreadyInstalled }
        let eviction = try lruEvictionCandidate(
            in: current,
            installing: request.selectedCoreID
        )
        let selection = try verifier.verify(
            rawCatalog: request.rawCatalogData,
            signatureEnvelope: request.signatureEnvelopeData,
            selectedCoreID: request.selectedCoreID,
            highestAcceptedSequence: current.highestCatalogSequence,
            highestAcceptedSHA256: current.lastCatalogSHA256
        )
        let staging = try stagingRoot(request.transactionID)
        try fileSystem.createDirectoryExclusively(staging)
        do {
            try createFixedBundleDirectories(in: staging)
            let identity = try fileSystem.verifiedDirectoryIdentity(at: staging)
            let record = RootCoreInstallTransaction(
                schemaVersion: RootCoreInstallTransaction.currentSchemaVersion,
                transactionID: request.transactionID,
                sessionID: request.sessionID,
                ownerUID: request.ownerUID,
                coreID: selection.coreID,
                upstreamVersion: selection.upstreamVersion,
                packageRevision: selection.packageRevision,
                catalogSequence: selection.sequence,
                catalogSHA256: selection.catalogSHA256,
                rawCatalogData: request.rawCatalogData,
                signatureEnvelopeData: request.signatureEnvelopeData,
                status: selection.status,
                blockReason: selection.blockReason,
                compatibility: selection.compatibility,
                createdAt: now(),
                evictionCoreID: eviction?.descriptor.coreID,
                files: selection.files.map {
                    RootCoreFileRecord(
                        role: $0.role,
                        expectedSize: $0.expectedSize,
                        expectedSHA256: $0.expectedSHA256,
                        staged: false
                    )
                },
                stagingIdentity: identity,
                phase: .staging
            )
            try saveTransaction(record, replacingExisting: false)
            transaction = record
            return PrepareCoreInstallResponse(
                requestID: request.requestID,
                transactionID: request.transactionID,
                coreID: selection.coreID,
                requiredRoles: CoreFileRole.allCases
            )
        } catch {
            try? removeStagingTree(transactionID: request.transactionID)
            throw error
        }
    }

    public func stageFile(_ request: StageCoreFileRequest, file: FileHandle) throws {
        var record = try requireTransaction(
            request.transactionID,
            sessionID: request.sessionID
        )
        guard record.phase == .staging,
            let index = record.files.firstIndex(where: { $0.role == request.role }),
            !record.files[index].staged,
            request.expectedSize == record.files[index].expectedSize,
            (try IntegrityValue.normalizedSHA256(request.expectedSHA256))
                == record.files[index].expectedSHA256
        else { throw RootCoreStoreError.descriptorMismatch }
        let destination = try filePath(transactionID: record.transactionID, role: request.role)
        try stream(
            file,
            to: destination,
            executable: request.role == .executable,
            expectedSize: request.expectedSize,
            expectedSHA256: request.expectedSHA256
        )
        record.files[index].staged = true
        try saveTransaction(record, replacingExisting: true)
        transaction = record
    }

    public func commitInstall(_ request: CommitCoreInstallRequest) async throws
        -> InstalledCoreDescriptor
    {
        var record = try requireTransaction(
            request.transactionID,
            sessionID: request.sessionID
        )
        guard record.phase == .staging,
            record.files.allSatisfy(\.staged)
        else { throw RootCoreStoreError.incomplete }
        let current = try requiredState()
        let selection = try verifiedInstallSelection(record, checkpoint: current)
        try validateExactBundle(transactionID: record.transactionID, files: record.files)
        try await preflight.validate(
            bundleRelativePath: try bundleRoot(record.transactionID),
            selection: selection
        )
        try validateFileHashes(transactionID: record.transactionID, files: record.files)
        let eviction = try lruEvictionCandidate(in: current, installing: record.coreID)
        if let eviction { try validateInstalledBundle(eviction) }
        record.evictionCoreID = eviction?.descriptor.coreID
        record.phase = .validated
        try saveTransaction(record, replacingExisting: true)
        transaction = record

        let destination = try installedRoot(record.coreID)
        try fileSystem.moveDirectory(
            try stagingRoot(record.transactionID),
            to: destination,
            expectedIdentity: record.stagingIdentity
        )
        record.phase = .promoted
        try saveTransaction(record, replacingExisting: true)
        transaction = record
        let descriptor = try completePromoted(record)
        return descriptor
    }

    public func abortInstall(_ request: AbortCoreInstallRequest) throws {
        let record = try requireTransaction(
            request.transactionID,
            sessionID: request.sessionID
        )
        guard record.phase != .promoted else { throw RootCoreStoreError.invalidState }
        try removeStagingTree(transactionID: record.transactionID)
        try removeTransactionJournal(record.transactionID)
        transaction = nil
    }

    public func list(requestID: UUID) throws -> ListInstalledCoresResponse {
        let current = try requiredState()
        return ListInstalledCoresResponse(
            requestID: requestID,
            cores: current.installed.map(\.descriptor).sorted {
                $0.coreID.rawValue < $1.coreID.rawValue
            },
            activeCoreID: current.activeCoreID,
            previousCoreID: current.previousKnownGoodCoreID,
            highestCatalogSequence: current.highestCatalogSequence
        )
    }

    public func refreshSignedPolicy(
        _ request: RefreshCoreCatalogRequest
    ) throws -> RefreshCoreCatalogResponse {
        var current = try requiredState()
        let update = try verifier.verifyPolicyRefresh(
            rawCatalog: request.rawCatalogData,
            signatureEnvelope: request.signatureEnvelopeData,
            installedCoreIDs: Set(current.installed.map(\.descriptor.coreID)),
            highestAcceptedSequence: current.highestCatalogSequence,
            highestAcceptedSHA256: current.lastCatalogSHA256
        )
        var updatedCoreIDs: [CoreID] = []
        for selection in update.selections {
            guard let index = current.installed.firstIndex(where: {
                $0.descriptor.coreID == selection.coreID
            }) else { continue }
            let installed = current.installed[index]
            guard immutableBundleIdentityMatches(selection, installed: installed) else {
                throw RootCoreStoreError.descriptorMismatch
            }
            current.installed[index] = RootInstalledCoreRecord(
                descriptor: InstalledCoreDescriptor(
                    coreID: installed.descriptor.coreID,
                    upstreamVersion: installed.descriptor.upstreamVersion,
                    packageRevision: installed.descriptor.packageRevision,
                    catalogSequence: update.sequence,
                    installedAt: installed.descriptor.installedAt,
                    lastValidatedAt: installed.descriptor.lastValidatedAt
                ),
                catalogSHA256: update.catalogSHA256,
                rawCatalogData: request.rawCatalogData,
                signatureEnvelopeData: request.signatureEnvelopeData,
                status: selection.status,
                blockReason: selection.blockReason,
                compatibility: selection.compatibility,
                files: installed.files
            )
            updatedCoreIDs.append(selection.coreID)
        }
        current.highestCatalogSequence = update.sequence
        current.lastCatalogSHA256 = update.catalogSHA256
        try saveState(current)
        state = current
        return RefreshCoreCatalogResponse(
            requestID: request.requestID,
            acceptedSequence: update.sequence,
            catalogSHA256: update.catalogSHA256,
            updatedCoreIDs: updatedCoreIDs.sorted { $0.rawValue < $1.rawValue }
        )
    }

    public func validate(_ coreID: CoreID, requestID: UUID) async throws
        -> ValidateCoreResponse
    {
        if coreID.isFactory {
            guard coreID == factoryCoreID else { throw RootCoreStoreError.notInstalled }
            return ValidateCoreResponse(
                requestID: requestID,
                coreID: coreID,
                valid: true,
                validatedAt: now()
            )
        }
        guard var current = state,
            let index = current.installed.firstIndex(where: { $0.descriptor.coreID == coreID })
        else { throw RootCoreStoreError.notInstalled }
        let installed = current.installed[index]
        let selection = try verifiedInstalledSelection(installed)
        guard selection.status != .blocked,
            PrivilegedCoreCompatibilityPolicy.isSatisfied(selection.compatibility)
        else { throw RootCoreStoreError.policyRejected }
        try validateInstalledBundle(installed)
        try await preflight.validate(
            bundleRelativePath: try installedBundleRoot(coreID),
            selection: selection
        )
        let instant = now()
        current.installed[index] = RootInstalledCoreRecord(
            descriptor: InstalledCoreDescriptor(
                coreID: installed.descriptor.coreID,
                upstreamVersion: installed.descriptor.upstreamVersion,
                packageRevision: installed.descriptor.packageRevision,
                catalogSequence: installed.descriptor.catalogSequence,
                installedAt: installed.descriptor.installedAt,
                lastValidatedAt: instant
            ),
            catalogSHA256: installed.catalogSHA256,
            rawCatalogData: installed.rawCatalogData,
            signatureEnvelopeData: installed.signatureEnvelopeData,
            status: installed.status,
            blockReason: installed.blockReason,
            compatibility: installed.compatibility,
            files: installed.files
        )
        try saveState(current)
        state = current
        return ValidateCoreResponse(
            requestID: requestID,
            coreID: coreID,
            valid: true,
            validatedAt: instant
        )
    }

    public func executableSourceURL(for coreID: CoreID) async throws -> URL? {
        guard !coreID.isFactory else {
            guard coreID == factoryCoreID else { throw RootCoreStoreError.notInstalled }
            return nil
        }
        _ = try await validate(coreID, requestID: UUID())
        return url(for: try installedBundleRoot(coreID)
            .appending("Contents").appending("MacOS").appending("mihomo"))
    }

    public func recordActivation(_ coreID: CoreID) throws {
        var current = try requiredState()
        var changed = false
        if !coreID.isFactory {
            guard let index = current.installed.firstIndex(where: {
                $0.descriptor.coreID == coreID
            }) else {
                throw RootCoreStoreError.notInstalled
            }
            // Resolving a Core always performs full validation before start, so
            // this root-owned validation timestamp is also the trustworthy LRU
            // clock (the App cannot provide or forge a last-used timestamp).
            let installed = current.installed[index]
            let usedAt = max(installed.descriptor.lastValidatedAt, now())
            current.installed[index] = RootInstalledCoreRecord(
                descriptor: InstalledCoreDescriptor(
                    coreID: installed.descriptor.coreID,
                    upstreamVersion: installed.descriptor.upstreamVersion,
                    packageRevision: installed.descriptor.packageRevision,
                    catalogSequence: installed.descriptor.catalogSequence,
                    installedAt: installed.descriptor.installedAt,
                    lastValidatedAt: usedAt
                ),
                catalogSHA256: installed.catalogSHA256,
                rawCatalogData: installed.rawCatalogData,
                signatureEnvelopeData: installed.signatureEnvelopeData,
                status: installed.status,
                blockReason: installed.blockReason,
                compatibility: installed.compatibility,
                files: installed.files
            )
            changed = true
        } else if coreID != factoryCoreID {
            throw RootCoreStoreError.notInstalled
        }
        if current.activeCoreID != coreID {
            if current.previousKnownGoodCoreID == coreID {
                // Rolling back to the recorded known-good Core must not promote
                // the failed outgoing candidate into the known-good slot.
                current.previousKnownGoodCoreID = nil
            } else {
                current.previousKnownGoodCoreID = current.activeCoreID
            }
            current.activeCoreID = coreID
            changed = true
        }
        if changed {
            try saveState(current)
            state = current
        }
    }

    public func remove(_ coreID: CoreID) throws {
        guard !coreID.isFactory else { throw RootCoreStoreError.protectedCore }
        var current = try requiredState()
        guard let index = current.installed.firstIndex(where: { $0.descriptor.coreID == coreID })
        else { throw RootCoreStoreError.notInstalled }
        guard current.activeCoreID != coreID,
            current.previousKnownGoodCoreID != coreID,
            current.pinnedCoreID != coreID,
            transaction?.coreID != coreID
        else { throw RootCoreStoreError.protectedCore }
        try validateInstalledBundle(current.installed[index])
        try removeFixedInstalledBundle(coreID)
        current.installed.remove(at: index)
        try saveState(current)
        state = current
    }

    private func completePromoted(_ record: RootCoreInstallTransaction) throws
        -> InstalledCoreDescriptor
    {
        var current = try requiredState()
        if let existing = current.installed.first(where: { $0.descriptor.coreID == record.coreID }) {
            guard existing.catalogSHA256 == record.catalogSHA256 else {
                throw RootCoreStoreError.invalidState
            }
            if let evictionCoreID = record.evictionCoreID {
                // Recovery after the atomic state swap may still need to finish
                // bounded deletion of the old directory. The state must no
                // longer reference that victim before cleanup is permitted.
                guard !current.installed.contains(where: {
                    $0.descriptor.coreID == evictionCoreID
                }) else { throw RootCoreStoreError.invalidState }
                try removeFixedInstalledBundleIfPresent(evictionCoreID)
            }
            try removeTransactionJournal(record.transactionID)
            transaction = nil
            return existing.descriptor
        }
        let eviction: RootInstalledCoreRecord?
        if current.installed.count == 3 {
            guard let evictionCoreID = record.evictionCoreID,
                let candidate = current.installed.first(where: {
                    $0.descriptor.coreID == evictionCoreID
                }),
                isEvictable(candidate.descriptor.coreID, in: current, installing: record.coreID)
            else { throw RootCoreStoreError.storeLimit }
            try validateInstalledBundle(candidate)
            eviction = candidate
        } else {
            guard current.installed.count < 3, record.evictionCoreID == nil else {
                throw RootCoreStoreError.invalidState
            }
            eviction = nil
        }
        let instant = now()
        let descriptor = InstalledCoreDescriptor(
            coreID: record.coreID,
            upstreamVersion: record.upstreamVersion,
            packageRevision: record.packageRevision,
            catalogSequence: record.catalogSequence,
            installedAt: instant,
            lastValidatedAt: instant
        )
        if let eviction {
            current.installed.removeAll {
                $0.descriptor.coreID == eviction.descriptor.coreID
            }
        }
        current.installed.append(
            RootInstalledCoreRecord(
                descriptor: descriptor,
                catalogSHA256: record.catalogSHA256,
                rawCatalogData: record.rawCatalogData,
                signatureEnvelopeData: record.signatureEnvelopeData,
                status: record.status,
                blockReason: record.blockReason,
                compatibility: record.compatibility,
                files: record.files
            )
        )
        current.highestCatalogSequence = max(
            current.highestCatalogSequence,
            record.catalogSequence
        )
        current.lastCatalogSHA256 = record.catalogSHA256
        try saveState(current)
        state = current
        if let eviction {
            // State is swapped first. If deletion is interrupted, the promoted
            // transaction journal retains the fixed victim CoreID and recovery
            // resumes this bounded, idempotent cleanup.
            try removeFixedInstalledBundleIfPresent(eviction.descriptor.coreID)
        }
        try removeTransactionJournal(record.transactionID)
        transaction = nil
        return descriptor
    }

    private func recoverTransactionIfNeeded() async throws {
        let entries = try entriesIfPresent(at: try SafeRelativePath("cores/transactions"))
        guard entries.count <= 1 else { throw RootCoreStoreError.invalidState }
        guard let entry = entries.first else { return }
        guard entry.isRegularFile,
            entry.name.hasSuffix(".json"),
            let id = UUID(uuidString: String(entry.name.dropLast(5)))
        else { throw RootCoreStoreError.invalidState }
        let record = try loadTransaction(id)
        transaction = record
        if (try? fileSystem.verifiedDirectoryIdentity(at: try stagingRoot(id))) != nil {
            try cleanupStagingAtomicFiles(id)
        }
        switch record.phase {
        case .staging:
            try removeStagingTree(transactionID: record.transactionID)
            try removeTransactionJournal(record.transactionID)
            transaction = nil
        case .validated:
            if (try? fileSystem.verifiedDirectoryIdentity(at: try installedRoot(record.coreID)))
                == record.stagingIdentity
            {
                try validatePromotedRecord(record)
                try await preflight.validate(
                    bundleRelativePath: try installedBundleRoot(record.coreID),
                    selection: try verifiedInstalledSelection(record)
                )
                recordAsPromoted(record)
                _ = try completePromoted(record)
            } else {
                try removeStagingTree(transactionID: record.transactionID)
                try removeTransactionJournal(record.transactionID)
                transaction = nil
            }
        case .promoted:
            try validatePromotedRecord(record)
            try await preflight.validate(
                bundleRelativePath: try installedBundleRoot(record.coreID),
                selection: try verifiedInstalledSelection(record)
            )
            _ = try completePromoted(record)
        }
    }

    private func recordAsPromoted(_ original: RootCoreInstallTransaction) {
        var promoted = original
        promoted.phase = .promoted
        transaction = promoted
    }

    private func loadOrCreateState() throws -> RootCoreStoreState {
        do {
            let data = try fileSystem.readData(
                at: try statePath(),
                maximumBytes: VelaIPCConstants.maximumCoreStoreStateBytes
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let value = try decoder.decode(RootCoreStoreState.self, from: data)
            let installedMaximumSequence = value.installed
                .map(\.descriptor.catalogSequence).max() ?? 0
            guard value.schemaVersion == RootCoreStoreState.currentSchemaVersion,
                value.activeCoreID == factoryCoreID
                    || value.installed.contains(where: { $0.descriptor.coreID == value.activeCoreID }),
                Set(value.installed.map(\.descriptor.coreID)).count == value.installed.count,
                value.installed.count <= 3,
                value.previousKnownGoodCoreID.map({ id in
                    id == factoryCoreID
                        || value.installed.contains(where: { $0.descriptor.coreID == id })
                }) ?? true,
                value.pinnedCoreID.map({ id in
                    id == factoryCoreID
                        || value.installed.contains(where: { $0.descriptor.coreID == id })
                }) ?? true,
                value.highestCatalogSequence >= installedMaximumSequence,
                try validCatalogCheckpoint(value),
                value.installed.allSatisfy(validInstalledRecord)
            else { throw RootCoreStoreError.invalidState }
            return value
        } catch let error as POSIXRootFileSystemError {
            guard case let .systemCall(_, code) = error, code == ENOENT else { throw error }
            let value = RootCoreStoreState(
                schemaVersion: RootCoreStoreState.currentSchemaVersion,
                activeCoreID: factoryCoreID,
                previousKnownGoodCoreID: nil,
                pinnedCoreID: nil,
                highestCatalogSequence: 0,
                lastCatalogSHA256: nil,
                installed: []
            )
            try saveState(value, replacingExisting: false)
            return value
        }
    }

    private func validCatalogCheckpoint(_ value: RootCoreStoreState) throws -> Bool {
        if value.highestCatalogSequence == 0 {
            return value.lastCatalogSHA256 == nil && value.installed.isEmpty
        }
        guard let hash = value.lastCatalogSHA256 else { return false }
        return try IntegrityValue.normalizedSHA256(hash) == hash
    }

    private func validInstalledRecord(_ record: RootInstalledCoreRecord) -> Bool {
        guard !record.descriptor.coreID.isFactory,
            record.descriptor.upstreamVersion == record.descriptor.coreID.upstreamVersion,
            record.descriptor.packageRevision == record.descriptor.coreID.packageRevision,
            record.descriptor.packageRevision > 0,
            record.descriptor.catalogSequence > 0,
            record.files.count == CoreFileRole.allCases.count,
            Set(record.files.map(\.role)) == Set(CoreFileRole.allCases),
            (try? IntegrityValue.normalizedSHA256(record.catalogSHA256))
                == record.catalogSHA256,
            !record.rawCatalogData.isEmpty,
            record.rawCatalogData.count <= VelaIPCConstants.maximumCoreCatalogBytes,
            !record.signatureEnvelopeData.isEmpty,
            record.signatureEnvelopeData.count
                <= VelaIPCConstants.maximumCoreSignatureEnvelopeBytes,
            IntegrityValue.sha256Hex(of: record.rawCatalogData) == record.catalogSHA256,
            record.status != .blocked || record.blockReason?.isEmpty == false,
            (try? IntegrityValue.normalizedSHA256(
                record.compatibility.compatibilityReportSHA256
            )) == record.compatibility.compatibilityReportSHA256
        else { return false }
        return record.files.allSatisfy { file in
            file.expectedSize > 0
                && file.expectedSize <= file.role.maximumBytes
                && (try? IntegrityValue.normalizedSHA256(file.expectedSHA256))
                    == file.expectedSHA256
                && file.staged
        }
    }

    private func validateInstalledDirectorySet() throws {
        let entries = try entriesIfPresent(at: try SafeRelativePath("cores/installed"))
        let expected = Set(try requiredState().installed.map { $0.descriptor.coreID.rawValue })
        guard Set(entries.map(\.name)) == expected,
            entries.allSatisfy(\.isDirectory)
        else { throw RootCoreStoreError.invalidState }
    }

    private func validateInstalledBundle(_ record: RootInstalledCoreRecord) throws {
        let root = try installedRoot(record.descriptor.coreID)
        _ = try fileSystem.verifiedDirectoryIdentity(at: root)
        try validateExactBundle(root: root, files: record.files)
        for file in record.files {
            let path = try installedFilePath(record.descriptor.coreID, role: file.role)
            let data = try file.role == .executable
                ? fileSystem.readTrustedExecutableData(at: path, maximumBytes: file.role.maximumBytes)
                : fileSystem.readData(at: path, maximumBytes: file.role.maximumBytes)
            guard data.count == file.expectedSize,
                IntegrityValue.sha256Hex(of: data) == file.expectedSHA256
            else { throw RootCoreStoreError.integrityMismatch }
        }
    }

    private func validatePromotedRecord(_ record: RootCoreInstallTransaction) throws {
        try validateExactBundle(root: try installedRoot(record.coreID), files: record.files)
        for file in record.files {
            let path = try installedFilePath(record.coreID, role: file.role)
            let data = try file.role == .executable
                ? fileSystem.readTrustedExecutableData(at: path, maximumBytes: file.role.maximumBytes)
                : fileSystem.readData(at: path, maximumBytes: file.role.maximumBytes)
            guard data.count == file.expectedSize,
                IntegrityValue.sha256Hex(of: data) == file.expectedSHA256
            else { throw RootCoreStoreError.integrityMismatch }
        }
    }

    private func validateExactBundle(transactionID: UUID, files: [RootCoreFileRecord]) throws {
        try validateExactBundle(root: try stagingRoot(transactionID), files: files)
    }

    private func validateExactBundle(root: SafeRelativePath, files _: [RootCoreFileRecord]) throws {
        func names(_ path: SafeRelativePath) throws -> Set<String> {
            Set(try fileSystem.directoryEntries(at: path, maximumCount: 16).map(\.name))
        }
        let bundle = try root.appending("VelaMihomoCore.bundle")
        guard try names(root) == ["VelaMihomoCore.bundle"],
            try names(bundle) == ["Contents"],
            try names(try bundle.appending("Contents"))
                == ["Info.plist", "MacOS", "_CodeSignature", "Resources"],
            try names(try bundle.appending("Contents").appending("MacOS")) == ["mihomo"],
            try names(try bundle.appending("Contents").appending("_CodeSignature"))
                == ["CodeResources"],
            try names(try bundle.appending("Contents").appending("Resources"))
                == ["LICENSE", "NOTICE.md", "source.json", "compatibility.json"]
        else { throw RootCoreStoreError.invalidLayout }
    }

    private func validateFileHashes(transactionID: UUID, files: [RootCoreFileRecord]) throws {
        for file in files {
            let path = try filePath(transactionID: transactionID, role: file.role)
            let data = try file.role == .executable
                ? fileSystem.readTrustedExecutableData(at: path, maximumBytes: file.role.maximumBytes)
                : fileSystem.readData(at: path, maximumBytes: file.role.maximumBytes)
            guard data.count == file.expectedSize,
                IntegrityValue.sha256Hex(of: data) == file.expectedSHA256
            else { throw RootCoreStoreError.integrityMismatch }
        }
    }

    private func stream(
        _ file: FileHandle,
        to destination: SafeRelativePath,
        executable: Bool,
        expectedSize: Int,
        expectedSHA256: String
    ) throws {
        guard expectedSize > 0,
            expectedSize <= (executable
                ? VelaIPCConstants.maximumMihomoExecutableBytes
                : VelaIPCConstants.maximumCoreFileBytes)
        else { throw RootCoreStoreError.sizeMismatch }
        let source = file.fileDescriptor
        var before = stat()
        guard fstat(source, &before) == 0,
            before.st_mode & S_IFMT == S_IFREG,
            before.st_size == Int64(expectedSize)
        else { throw RootCoreStoreError.sourceRejected }
        var hasher = SHA256()
        let writer: (@escaping (Int32) throws -> Void) throws -> Void = { body in
            if executable {
                try self.fileSystem.withAtomicTrustedExecutableOutput(to: destination, body)
            } else {
                try self.fileSystem.withAtomicOutput(to: destination, replacingExisting: false, body)
            }
        }
        try writer { output in
            var offset = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while offset < expectedSize {
                let count = pread(source, &buffer, min(buffer.count, expectedSize - offset), off_t(offset))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw RootCoreStoreError.sourceRejected
                }
                guard count > 0 else { throw RootCoreStoreError.sizeMismatch }
                var written = 0
                while written < count {
                    let result = buffer.withUnsafeBytes { bytes in
                        guard let baseAddress = bytes.baseAddress else { return -1 }
                        return Darwin.write(
                            output,
                            baseAddress.advanced(by: written),
                            count - written
                        )
                    }
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw RootCoreStoreError.sourceRejected
                    }
                    written += result
                }
                hasher.update(data: Data(buffer[0..<count]))
                offset += count
            }
            var extra: UInt8 = 0
            guard pread(source, &extra, 1, off_t(offset)) == 0 else {
                throw RootCoreStoreError.sizeMismatch
            }
        }
        var after = stat()
        guard fstat(source, &after) == 0,
            before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            before.st_mode == after.st_mode,
            before.st_uid == after.st_uid,
            before.st_gid == after.st_gid,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            hasher.finalize().map({ String(format: "%02x", $0) }).joined()
                == expectedSHA256
        else {
            try? (executable
                ? fileSystem.removeTrustedExecutable(destination)
                : fileSystem.removeFile(destination))
            throw RootCoreStoreError.integrityMismatch
        }
    }

    private func removeFixedInstalledBundle(_ coreID: CoreID) throws {
        for role in CoreFileRole.allCases {
            let path = try installedFilePath(coreID, role: role)
            if role == .executable { try fileSystem.removeTrustedExecutable(path) }
            else { try fileSystem.removeFile(path) }
        }
        let bundle = try installedBundleRoot(coreID)
        for path in [
            try bundle.appending("Contents").appending("MacOS"),
            try bundle.appending("Contents").appending("_CodeSignature"),
            try bundle.appending("Contents").appending("Resources"),
            try bundle.appending("Contents"), bundle,
        ] { try fileSystem.removeEmptyDirectory(path) }
        try fileSystem.removeEmptyDirectory(try installedRoot(coreID))
    }

    private func removeFixedInstalledBundleIfPresent(_ coreID: CoreID) throws {
        let root = try installedRoot(coreID)
        guard try identityIfPresent(root) != nil else { return }
        for role in CoreFileRole.allCases {
            let path = try installedFilePath(coreID, role: role)
            guard try identityIfPresent(path) != nil else { continue }
            if role == .executable {
                _ = try fileSystem.trustedExecutableIdentity(at: path)
                try fileSystem.removeTrustedExecutable(path)
            } else {
                _ = try fileSystem.verifiedRegularFileIdentity(
                    at: path,
                    maximumBytes: Int64(role.maximumBytes)
                )
                try fileSystem.removeFile(path)
            }
        }
        let bundle = try installedBundleRoot(coreID)
        for path in [
            try bundle.appending("Contents").appending("MacOS"),
            try bundle.appending("Contents").appending("_CodeSignature"),
            try bundle.appending("Contents").appending("Resources"),
            try bundle.appending("Contents"), bundle, root,
        ] where try identityIfPresent(path) != nil {
            try fileSystem.removeEmptyDirectory(path)
        }
    }

    private func identityIfPresent(_ path: SafeRelativePath) throws -> POSIXFileIdentity? {
        do { return try fileSystem.identity(of: path) }
        catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT { return nil }
            throw error
        }
    }

    private func removeStagingTree(transactionID: UUID) throws {
        let root = try stagingRoot(transactionID)
        guard (try? fileSystem.verifiedDirectoryIdentity(at: root)) != nil else { return }
        try validateIncompleteStagingLayout(root)
        for role in CoreFileRole.allCases {
            let path = try filePath(transactionID: transactionID, role: role)
            guard (try? fileSystem.identity(of: path)) != nil else { continue }
            if role == .executable { try fileSystem.removeTrustedExecutable(path) }
            else { try fileSystem.removeFile(path) }
        }
        let bundle = try bundleRoot(transactionID)
        for path in [
            try bundle.appending("Contents").appending("MacOS"),
            try bundle.appending("Contents").appending("_CodeSignature"),
            try bundle.appending("Contents").appending("Resources"),
            try bundle.appending("Contents"), bundle,
        ] { try fileSystem.removeEmptyDirectory(path) }
        try fileSystem.removeEmptyDirectory(root)
    }

    private func validateIncompleteStagingLayout(_ root: SafeRelativePath) throws {
        func entries(_ path: SafeRelativePath) throws -> [POSIXDirectoryEntry] {
            try fileSystem.directoryEntries(at: path, maximumCount: 16)
        }
        func isSubset(_ values: [POSIXDirectoryEntry], _ names: Set<String>) -> Bool {
            Set(values.map(\.name)).isSubset(of: names)
        }
        let bundle = try root.appending("VelaMihomoCore.bundle")
        let rootEntries = try entries(root)
        let contents = try entries(try bundle.appending("Contents"))
        let macOS = try entries(try bundle.appending("Contents").appending("MacOS"))
        let signature = try entries(
            try bundle.appending("Contents").appending("_CodeSignature")
        )
        let resources = try entries(try bundle.appending("Contents").appending("Resources"))
        guard rootEntries.count == 1,
            rootEntries[0].name == "VelaMihomoCore.bundle",
            rootEntries[0].isDirectory,
            isSubset(try entries(bundle), ["Contents"]),
            isSubset(contents, ["Info.plist", "MacOS", "_CodeSignature", "Resources"]),
            contents.allSatisfy({ entry in
                entry.name == "Info.plist" ? entry.isRegularFile : entry.isDirectory
            }),
            isSubset(macOS, ["mihomo"]), macOS.allSatisfy(\.isRegularFile),
            isSubset(signature, ["CodeResources"]), signature.allSatisfy(\.isRegularFile),
            isSubset(resources, ["LICENSE", "NOTICE.md", "source.json", "compatibility.json"]),
            resources.allSatisfy(\.isRegularFile)
        else { throw RootCoreStoreError.invalidLayout }
        let transactionID = try requireTransactionID(from: root)
        for role in CoreFileRole.allCases {
            let path = try filePath(transactionID: transactionID, role: role)
            guard (try? fileSystem.identity(of: path)) != nil else { continue }
            if role == .executable {
                _ = try fileSystem.trustedExecutableIdentity(at: path)
            } else {
                _ = try fileSystem.verifiedRegularFileIdentity(
                    at: path,
                    maximumBytes: Int64(role.maximumBytes)
                )
            }
        }
    }

    private func ensureContainers() throws {
        for path in ["cores", "cores/staging", "cores/installed", "cores/transactions"] {
            try fileSystem.createDirectory(try SafeRelativePath(path))
        }
    }

    private func cleanupAtomicJournalArtifacts() throws {
        try cleanupAtomicFiles(
            in: try SafeRelativePath("cores"),
            maximumBytes: Int64(VelaIPCConstants.maximumCoreStoreStateBytes)
        )
        try cleanupAtomicFiles(
            in: try SafeRelativePath("cores/transactions"),
            maximumBytes: Int64(VelaIPCConstants.maximumPayloadBytes)
        )
    }

    private func validateCoreRootLayout() throws {
        let entries = try fileSystem.directoryEntries(
            at: try SafeRelativePath("cores"),
            maximumCount: 8
        )
        guard Set(entries.map(\.name)) == [
            "state.json", "staging", "installed", "transactions",
        ], entries.allSatisfy({ entry in
            entry.name == "state.json" ? entry.isRegularFile : entry.isDirectory
        }) else { throw RootCoreStoreError.invalidState }
    }

    private func cleanupAtomicFiles(
        in directory: SafeRelativePath,
        maximumBytes: Int64
    ) throws {
        let entries = try fileSystem.directoryEntries(at: directory, maximumCount: 128)
        let temporary = try entries.compactMap { entry -> SafeRelativePath? in
            guard RootAtomicTemporaryArtifact.isExactName(entry.name) else { return nil }
            return try RootAtomicTemporaryArtifact.validate(
                entry,
                in: directory,
                fileSystem: fileSystem,
                maximumBytes: maximumBytes
            )
        }
        for path in temporary { try fileSystem.removeFile(path) }
    }

    private func cleanupOrphanStaging() throws {
        let root = try SafeRelativePath("cores/staging")
        let entries = try fileSystem.directoryEntries(at: root, maximumCount: 16)
        var orphanIDs: [UUID] = []
        for entry in entries {
            guard entry.isDirectory,
                let id = UUID(uuidString: entry.name),
                entry.name == id.uuidString.lowercased()
            else { throw RootCoreStoreError.invalidState }
            if id != transaction?.transactionID { orphanIDs.append(id) }
        }
        for id in orphanIDs {
            try cleanupStagingAtomicFiles(id)
            try validateIncompleteStagingLayout(try stagingRoot(id))
        }
        for id in orphanIDs { try removeStagingTree(transactionID: id) }
    }

    private func cleanupStagingAtomicFiles(_ id: UUID) throws {
        let bundle = try bundleRoot(id)
        for directory in [
            try bundle.appending("Contents"),
            try bundle.appending("Contents").appending("MacOS"),
            try bundle.appending("Contents").appending("_CodeSignature"),
            try bundle.appending("Contents").appending("Resources"),
        ] {
            try cleanupAtomicFiles(
                in: directory,
                maximumBytes: Int64(VelaIPCConstants.maximumCoreFileBytes)
            )
        }
    }

    private func requireTransactionID(from root: SafeRelativePath) throws -> UUID {
        guard root.components.count == 3,
            root.components[0] == "cores",
            root.components[1] == "staging",
            let id = UUID(uuidString: root.components[2]),
            root.components[2] == id.uuidString.lowercased()
        else { throw RootCoreStoreError.invalidState }
        return id
    }

    private func createFixedBundleDirectories(in root: SafeRelativePath) throws {
        let bundle = try root.appending("VelaMihomoCore.bundle")
        for path in [
            bundle,
            try bundle.appending("Contents"),
            try bundle.appending("Contents").appending("MacOS"),
            try bundle.appending("Contents").appending("_CodeSignature"),
            try bundle.appending("Contents").appending("Resources"),
        ] { try fileSystem.createDirectory(path) }
    }

    private func requiredState() throws -> RootCoreStoreState {
        guard let state else { throw RootCoreStoreError.notPrepared }
        return state
    }

    private func lruEvictionCandidate(
        in current: RootCoreStoreState,
        installing coreID: CoreID
    ) throws -> RootInstalledCoreRecord? {
        guard current.installed.count <= 3 else { throw RootCoreStoreError.invalidState }
        guard current.installed.count == 3 else { return nil }
        // `lastValidatedAt` is refreshed both by explicit validation and by a
        // successful activation, making it the Helper-owned LRU signal.
        guard let candidate = current.installed
            .filter({ isEvictable($0.descriptor.coreID, in: current, installing: coreID) })
            .min(by: { lhs, rhs in
                if lhs.descriptor.lastValidatedAt != rhs.descriptor.lastValidatedAt {
                    return lhs.descriptor.lastValidatedAt < rhs.descriptor.lastValidatedAt
                }
                if lhs.descriptor.installedAt != rhs.descriptor.installedAt {
                    return lhs.descriptor.installedAt < rhs.descriptor.installedAt
                }
                return lhs.descriptor.coreID.rawValue < rhs.descriptor.coreID.rawValue
            })
        else { throw RootCoreStoreError.storeLimit }
        return candidate
    }

    private func isEvictable(
        _ coreID: CoreID,
        in current: RootCoreStoreState,
        installing incomingCoreID: CoreID
    ) -> Bool {
        coreID != incomingCoreID
            && coreID != current.activeCoreID
            && coreID != current.previousKnownGoodCoreID
            && coreID != current.pinnedCoreID
            && coreID != transaction?.coreID
    }

    private func requireTransaction(_ id: UUID, sessionID: UUID) throws
        -> RootCoreInstallTransaction
    {
        guard let transaction,
            transaction.transactionID == id,
            transaction.sessionID == sessionID
        else { throw RootCoreStoreError.invalidTransaction }
        return transaction
    }

    private func selection(from record: RootCoreInstallTransaction)
        -> VerifiedCoreCatalogSelection
    {
        VerifiedCoreCatalogSelection(
            coreID: record.coreID,
            upstreamVersion: record.upstreamVersion,
            packageRevision: record.packageRevision,
            sequence: record.catalogSequence,
            catalogSHA256: record.catalogSHA256,
            status: record.status,
            blockReason: record.blockReason,
            compatibility: record.compatibility,
            files: record.files.map {
                VerifiedCoreFile(
                    role: $0.role,
                    expectedSize: $0.expectedSize,
                    expectedSHA256: $0.expectedSHA256
                )
            }
        )
    }

    private func selection(from record: RootInstalledCoreRecord)
        -> VerifiedCoreCatalogSelection
    {
        VerifiedCoreCatalogSelection(
            coreID: record.descriptor.coreID,
            upstreamVersion: record.descriptor.upstreamVersion,
            packageRevision: record.descriptor.packageRevision,
            sequence: record.descriptor.catalogSequence,
            catalogSHA256: record.catalogSHA256,
            status: record.status,
            blockReason: record.blockReason,
            compatibility: record.compatibility,
            files: record.files.map {
                VerifiedCoreFile(
                    role: $0.role,
                    expectedSize: $0.expectedSize,
                    expectedSHA256: $0.expectedSHA256
                )
            }
        )
    }

    private func verifiedInstallSelection(
        _ record: RootCoreInstallTransaction,
        checkpoint: RootCoreStoreState
    ) throws -> VerifiedCoreCatalogSelection {
        let verified = try verifier.verify(
            rawCatalog: record.rawCatalogData,
            signatureEnvelope: record.signatureEnvelopeData,
            selectedCoreID: record.coreID,
            highestAcceptedSequence: checkpoint.highestCatalogSequence,
            highestAcceptedSHA256: checkpoint.lastCatalogSHA256
        )
        guard evidenceIdentityMatches(verified, transaction: record) else {
            throw RootCoreStoreError.descriptorMismatch
        }
        return verified
    }

    private func verifiedInstalledSelection(
        _ record: RootInstalledCoreRecord
    ) throws -> VerifiedCoreCatalogSelection {
        let verified = try verifier.verifyInstalledEvidence(
            rawCatalog: record.rawCatalogData,
            signatureEnvelope: record.signatureEnvelopeData,
            selectedCoreID: record.descriptor.coreID,
            expectedSequence: record.descriptor.catalogSequence,
            expectedSHA256: record.catalogSHA256
        )
        guard evidenceIdentityMatches(verified, installed: record) else {
            throw RootCoreStoreError.descriptorMismatch
        }
        return verified
    }

    private func verifiedInstalledSelection(
        _ record: RootCoreInstallTransaction
    ) throws -> VerifiedCoreCatalogSelection {
        let verified = try verifier.verifyInstalledEvidence(
            rawCatalog: record.rawCatalogData,
            signatureEnvelope: record.signatureEnvelopeData,
            selectedCoreID: record.coreID,
            expectedSequence: record.catalogSequence,
            expectedSHA256: record.catalogSHA256
        )
        guard evidenceIdentityMatches(verified, transaction: record) else {
            throw RootCoreStoreError.descriptorMismatch
        }
        return verified
    }

    private func evidenceIdentityMatches(
        _ selection: VerifiedCoreCatalogSelection,
        transaction: RootCoreInstallTransaction
    ) -> Bool {
        selection.coreID == transaction.coreID
            && selection.upstreamVersion == transaction.upstreamVersion
            && selection.packageRevision == transaction.packageRevision
            && selection.sequence == transaction.catalogSequence
            && selection.catalogSHA256 == transaction.catalogSHA256
            && selection.status == transaction.status
            && selection.blockReason == transaction.blockReason
            && selection.compatibility == transaction.compatibility
            && fileIdentity(selection.files) == fileIdentity(transaction.files)
    }

    private func evidenceIdentityMatches(
        _ selection: VerifiedCoreCatalogSelection,
        installed: RootInstalledCoreRecord
    ) -> Bool {
        immutableBundleIdentityMatches(selection, installed: installed)
            && selection.sequence == installed.descriptor.catalogSequence
            && selection.catalogSHA256 == installed.catalogSHA256
            && selection.status == installed.status
            && selection.blockReason == installed.blockReason
            && selection.compatibility == installed.compatibility
    }

    private func immutableBundleIdentityMatches(
        _ selection: VerifiedCoreCatalogSelection,
        installed: RootInstalledCoreRecord
    ) -> Bool {
        selection.coreID == installed.descriptor.coreID
            && selection.upstreamVersion == installed.descriptor.upstreamVersion
            && selection.packageRevision == installed.descriptor.packageRevision
            && fileIdentity(selection.files) == fileIdentity(installed.files)
    }

    private func fileIdentity(_ files: [VerifiedCoreFile]) -> [CoreFileRole: String] {
        Dictionary(uniqueKeysWithValues: files.map {
            ($0.role, "\($0.expectedSize):\($0.expectedSHA256)")
        })
    }

    private func fileIdentity(_ files: [RootCoreFileRecord]) -> [CoreFileRole: String] {
        Dictionary(uniqueKeysWithValues: files.map {
            ($0.role, "\($0.expectedSize):\($0.expectedSHA256)")
        })
    }

    private func saveState(_ value: RootCoreStoreState, replacingExisting: Bool = true) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try fileSystem.writeDataAtomically(
            try encoder.encode(value),
            to: try statePath(),
            replacingExisting: replacingExisting
        )
    }

    private func saveTransaction(
        _ value: RootCoreInstallTransaction,
        replacingExisting: Bool
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try fileSystem.writeDataAtomically(
            try encoder.encode(value),
            to: try transactionPath(value.transactionID),
            replacingExisting: replacingExisting
        )
    }

    private func loadTransaction(_ id: UUID) throws -> RootCoreInstallTransaction {
        let data = try fileSystem.readData(
            at: try transactionPath(id),
            maximumBytes: VelaIPCConstants.maximumCoreInstallPayloadBytes
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(RootCoreInstallTransaction.self, from: data)
        guard value.schemaVersion == RootCoreInstallTransaction.currentSchemaVersion,
            value.transactionID == id,
            !value.coreID.isFactory,
            value.evictionCoreID.map({ !$0.isFactory && $0 != value.coreID }) ?? true,
            !value.rawCatalogData.isEmpty,
            value.rawCatalogData.count <= VelaIPCConstants.maximumCoreCatalogBytes,
            !value.signatureEnvelopeData.isEmpty,
            value.signatureEnvelopeData.count
                <= VelaIPCConstants.maximumCoreSignatureEnvelopeBytes,
            IntegrityValue.sha256Hex(of: value.rawCatalogData) == value.catalogSHA256,
            value.files.count == CoreFileRole.allCases.count,
            Set(value.files.map(\.role)) == Set(CoreFileRole.allCases)
        else { throw RootCoreStoreError.invalidState }
        return value
    }

    private func removeTransactionJournal(_ id: UUID) throws {
        try fileSystem.removeFile(try transactionPath(id))
    }

    private func entriesIfPresent(at path: SafeRelativePath) throws -> [POSIXDirectoryEntry] {
        do { return try fileSystem.directoryEntries(at: path, maximumCount: 128) }
        catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT { return [] }
            throw error
        }
    }

    private func statePath() throws -> SafeRelativePath { try SafeRelativePath("cores/state.json") }
    private func transactionPath(_ id: UUID) throws -> SafeRelativePath {
        try SafeRelativePath("cores/transactions/\(id.uuidString.lowercased()).json")
    }
    private func stagingRoot(_ id: UUID) throws -> SafeRelativePath {
        try SafeRelativePath("cores/staging/\(id.uuidString.lowercased())")
    }
    private func installedRoot(_ id: CoreID) throws -> SafeRelativePath {
        guard !id.isFactory else { throw RootCoreStoreError.invalidState }
        return try SafeRelativePath("cores/installed/\(id.rawValue)")
    }
    private func bundleRoot(_ id: UUID) throws -> SafeRelativePath {
        try stagingRoot(id).appending("VelaMihomoCore.bundle")
    }
    private func installedBundleRoot(_ id: CoreID) throws -> SafeRelativePath {
        try installedRoot(id).appending("VelaMihomoCore.bundle")
    }
    private func filePath(transactionID: UUID, role: CoreFileRole) throws -> SafeRelativePath {
        try role.requiredRelativePath.split(separator: "/").reduce(try bundleRoot(transactionID)) {
            try $0.appending(String($1))
        }
    }
    private func installedFilePath(_ id: CoreID, role: CoreFileRole) throws -> SafeRelativePath {
        try role.requiredRelativePath.split(separator: "/").reduce(try installedBundleRoot(id)) {
            try $0.appending(String($1))
        }
    }
    private func url(for path: SafeRelativePath) -> URL {
        path.components.reduce(fileSystem.rootURL) { $0.appending(path: $1) }
    }
}

private struct CoreBundleInfo: Decodable {
    let bundleIdentifier: String
    let bundleName: String
    let bundlePackageType: String
    let bundleExecutable: String
    let bundleShortVersion: String
    let bundleVersion: String
    let minimumSystemVersion: String
    let coreVersion: String
    let corePackageRevision: Int
    let coreArchitecture: String

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier = "CFBundleIdentifier"
        case bundleName = "CFBundleName"
        case bundlePackageType = "CFBundlePackageType"
        case bundleExecutable = "CFBundleExecutable"
        case bundleShortVersion = "CFBundleShortVersionString"
        case bundleVersion = "CFBundleVersion"
        case minimumSystemVersion = "LSMinimumSystemVersion"
        case coreVersion = "VelaCoreVersion"
        case corePackageRevision = "VelaCorePackageRevision"
        case coreArchitecture = "VelaCoreArchitecture"
    }
}

public enum RootCoreStoreError: Error, Equatable, Sendable {
    case notPrepared
    case transactionActive
    case ownerMismatch
    case alreadyInstalled
    case invalidTransaction
    case descriptorMismatch
    case incomplete
    case invalidState
    case invalidLayout
    case sourceRejected
    case sizeMismatch
    case integrityMismatch
    case preflightFailed
    case policyRejected
    case notInstalled
    case protectedCore
    case storeLimit
}
