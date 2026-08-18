import Foundation
import VelaIPC

nonisolated enum CoreSelectionMode: String, Codable, CaseIterable, Sendable {
    case followRecommended
    case pinned
    case factoryOnly
}

nonisolated struct CoreSelectionPreferences: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    var mode: CoreSelectionMode
    var pinnedCoreID: CoreID?
    var automaticallyCheckForUpdates: Bool
    var automaticallyDownloadRecommended: Bool

    init(
        schemaVersion: Int = supportedSchemaVersion,
        mode: CoreSelectionMode = .followRecommended,
        pinnedCoreID: CoreID? = nil,
        automaticallyCheckForUpdates: Bool = true,
        automaticallyDownloadRecommended: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.pinnedCoreID = pinnedCoreID
        self.automaticallyCheckForUpdates = automaticallyCheckForUpdates
        self.automaticallyDownloadRecommended = automaticallyDownloadRecommended
    }

    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw CoreStoreModelError.unsupportedSchemaVersion(schemaVersion)
        }
        switch mode {
        case .pinned:
            guard let pinnedCoreID, !pinnedCoreID.isFactory else {
                throw CoreStoreModelError.invalidSelectionPreferences
            }
        case .followRecommended, .factoryOnly:
            guard pinnedCoreID == nil else {
                throw CoreStoreModelError.invalidSelectionPreferences
            }
        }
    }
}

nonisolated enum InstalledCoreStatus: String, Codable, CaseIterable, Sendable {
    case ready
    case knownGood
    case quarantined
    case blocked
    case withdrawn
}

nonisolated struct InstalledCoreRecord: Codable, Equatable, Identifiable, Sendable {
    var id: CoreID { coreID }

    let coreID: CoreID
    let upstreamVersion: String
    let packageRevision: Int
    let catalogSequence: UInt64
    let catalogSHA256: String
    let installedAt: Date
    var lastUsedAt: Date
    var status: InstalledCoreStatus
    var validationFailures: Int
    var activationFailures: Int
    var unexpectedExits: Int
    var lastFailurePhase: CoreActivationPhase?
    var lastFailureAt: Date?

    init(
        coreID: CoreID,
        upstreamVersion: String,
        packageRevision: Int,
        catalogSequence: UInt64,
        catalogSHA256: String,
        installedAt: Date,
        lastUsedAt: Date,
        status: InstalledCoreStatus = .ready,
        validationFailures: Int = 0,
        activationFailures: Int = 0,
        unexpectedExits: Int = 0,
        lastFailurePhase: CoreActivationPhase? = nil,
        lastFailureAt: Date? = nil
    ) {
        self.coreID = coreID
        self.upstreamVersion = upstreamVersion
        self.packageRevision = packageRevision
        self.catalogSequence = catalogSequence
        self.catalogSHA256 = catalogSHA256
        self.installedAt = installedAt
        self.lastUsedAt = lastUsedAt
        self.status = status
        self.validationFailures = validationFailures
        self.activationFailures = activationFailures
        self.unexpectedExits = unexpectedExits
        self.lastFailurePhase = lastFailurePhase
        self.lastFailureAt = lastFailureAt
    }

    func validate() throws {
        guard !coreID.isFactory,
            coreID.upstreamVersion == upstreamVersion,
            coreID.packageRevision == packageRevision,
            packageRevision > 0,
            catalogSequence > 0,
            catalogSHA256.utf8.count == 64,
            catalogSHA256.utf8.allSatisfy({
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            }),
            lastUsedAt >= installedAt,
            validationFailures >= 0,
            activationFailures >= 0,
            unexpectedExits >= 0,
            (lastFailurePhase == nil) == (lastFailureAt == nil)
        else {
            throw CoreStoreModelError.invalidInstalledRecord(coreID)
        }
    }
}

nonisolated struct CoreStoreState: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    var activeCoreID: CoreID
    var previousKnownGoodCoreID: CoreID?
    var pinnedCoreID: CoreID?
    var installed: [InstalledCoreRecord]
    var highestCatalogSequence: UInt64
    var lastCatalogSHA256: String?

    init(
        schemaVersion: Int = supportedSchemaVersion,
        activeCoreID: CoreID = .factoryV11928,
        previousKnownGoodCoreID: CoreID? = nil,
        pinnedCoreID: CoreID? = nil,
        installed: [InstalledCoreRecord] = [],
        highestCatalogSequence: UInt64 = 0,
        lastCatalogSHA256: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.activeCoreID = activeCoreID
        self.previousKnownGoodCoreID = previousKnownGoodCoreID
        self.pinnedCoreID = pinnedCoreID
        self.installed = installed
        self.highestCatalogSequence = highestCatalogSequence
        self.lastCatalogSHA256 = lastCatalogSHA256
    }

    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw CoreStoreModelError.unsupportedSchemaVersion(schemaVersion)
        }
        guard Set(installed.map(\.coreID)).count == installed.count else {
            throw CoreStoreModelError.duplicateInstalledCore
        }
        for record in installed { try record.validate() }
        let installedIDs = Set(installed.map(\.coreID))
        for protectedID in [activeCoreID, previousKnownGoodCoreID, pinnedCoreID].compactMap({ $0 }) {
            guard protectedID.isFactory || installedIDs.contains(protectedID) else {
                throw CoreStoreModelError.missingProtectedCore(protectedID)
            }
        }
        if highestCatalogSequence == 0 {
            guard lastCatalogSHA256 == nil else {
                throw CoreStoreModelError.invalidCatalogCheckpoint
            }
        } else {
            guard let lastCatalogSHA256,
                lastCatalogSHA256.utf8.count == 64,
                lastCatalogSHA256.utf8.allSatisfy({
                    (48 ... 57).contains($0) || (97 ... 102).contains($0)
                })
            else {
                throw CoreStoreModelError.invalidCatalogCheckpoint
            }
        }
    }

    func record(for coreID: CoreID) -> InstalledCoreRecord? {
        installed.first { $0.coreID == coreID }
    }

    var catalogVerificationState: CoreCatalogVerificationState {
        CoreCatalogVerificationState(
            highestSequence: highestCatalogSequence,
            lastCatalogSHA256: lastCatalogSHA256
        )
    }
}

/// The verified Catalog checkpoint that authorized one user-store installation.
/// It is persisted in the install journal so a filesystem move can never be
/// mistaken for a state-committed installation after a crash.
nonisolated struct CoreInstallCatalogIdentity: Codable, Equatable, Sendable {
    let sequence: UInt64
    let sha256: String

    func validate() throws {
        guard sequence > 0,
            sha256.utf8.count == 64,
            sha256.utf8.allSatisfy({
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            })
        else {
            throw CoreStoreModelError.invalidInstallCatalogIdentity
        }
    }
}

nonisolated enum CoreInstallJournalPhase: String, Codable, CaseIterable, Sendable {
    /// The durable journal exists; staging may or may not have been created yet.
    case preparing
    /// All fixed-role files have been reconstructed and synchronized in staging.
    case bundleReady
    /// The journal was synchronized immediately before the atomic move.
    case moving
    /// The atomic move to the fixed installation directory was synchronized.
    case moved
    /// `state.json` durably contains the matching InstalledCoreRecord.
    case stateCommitted

    func canAdvance(to next: Self) -> Bool {
        if self == next { return true }
        return switch (self, next) {
        case (.preparing, .bundleReady),
            (.bundleReady, .moving),
            (.moving, .moved),
            (.moved, .stateCommitted):
            true
        default:
            false
        }
    }
}

/// Small, strict and path-bounded journal for the user Core Store's atomic
/// staging-to-installed move. Only path *components* are persisted; validation
/// derives both components again from transactionID/CoreID before use.
nonisolated struct CoreInstallJournal: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    let transactionID: UUID
    let coreID: CoreID
    let upstreamVersion: String
    let packageRevision: Int
    let catalog: CoreInstallCatalogIdentity
    let startedAt: Date
    var phase: CoreInstallJournalPhase
    let stagingComponent: String
    let finalComponent: String

    init(
        schemaVersion: Int = supportedSchemaVersion,
        transactionID: UUID,
        coreID: CoreID,
        upstreamVersion: String,
        packageRevision: Int,
        catalog: CoreInstallCatalogIdentity,
        startedAt: Date = .now,
        phase: CoreInstallJournalPhase = .preparing
    ) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.coreID = coreID
        self.upstreamVersion = upstreamVersion
        self.packageRevision = packageRevision
        self.catalog = catalog
        self.startedAt = startedAt
        self.phase = phase
        stagingComponent = transactionID.uuidString
        finalComponent = coreID.rawValue.replacingOccurrences(of: ":", with: "_")
    }

    func validate() throws {
        try catalog.validate()
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw CoreStoreModelError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !coreID.isFactory,
            coreID.upstreamVersion == upstreamVersion,
            coreID.packageRevision == packageRevision,
            packageRevision > 0,
            stagingComponent == transactionID.uuidString,
            finalComponent == coreID.rawValue.replacingOccurrences(of: ":", with: "_"),
            Self.isSingleSafeComponent(stagingComponent),
            Self.isSingleSafeComponent(finalComponent)
        else {
            throw CoreStoreModelError.invalidInstallJournal
        }
    }

    func matches(_ record: InstalledCoreRecord) -> Bool {
        record.coreID == coreID
            && record.upstreamVersion == upstreamVersion
            && record.packageRevision == packageRevision
            && record.catalogSequence == catalog.sequence
            && record.catalogSHA256 == catalog.sha256
    }

    private static func isSingleSafeComponent(_ value: String) -> Bool {
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
}

nonisolated enum CoreInstallReconciliationResult: Equatable, Sendable {
    case noWork
    case installationInProgress(UUID)
    case discarded(coreID: CoreID, phase: CoreInstallJournalPhase)
    case committed(coreID: CoreID)
    case committedBundleMissing(coreID: CoreID)
    case discardedUntrustedJournal(orphanInstallations: Int, orphanStaging: Int)
    case cleanedOrphans(installations: Int, staging: Int)
}

nonisolated enum CoreActivationPhase: String, Codable, CaseIterable, Sendable {
    case downloading
    case filesVerified
    case bundleBuilt
    case codeVerified
    case configValidated
    case smokeTested
    case installedUser
    case installedPrivileged
    case ready
    case activating
    case probation
    case committed
    case rollingBack
    case failed

    var isTerminal: Bool { self == .committed || self == .failed }
}

nonisolated enum CoreBackendSelection: String, Codable, CaseIterable, Sendable {
    case user
    case systemProxy
    case tun
}

nonisolated struct CoreActivationSnapshot: Codable, Equatable, Sendable {
    let previousCoreID: CoreID
    let backend: CoreBackendSelection
    let profileID: UUID
    let profileRevisionID: UUID?
    let sceneID: UUID?
    let mihomoMode: MihomoMode?
    let proxySelections: [UpdateProxySelection]
    let systemProxyDesired: Bool
    let configurationGenerationID: UUID

    init(
        previousCoreID: CoreID,
        backend: CoreBackendSelection,
        profileID: UUID,
        profileRevisionID: UUID? = nil,
        sceneID: UUID? = nil,
        mihomoMode: MihomoMode? = nil,
        proxySelections: [UpdateProxySelection] = [],
        systemProxyDesired: Bool? = nil,
        configurationGenerationID: UUID
    ) {
        self.previousCoreID = previousCoreID
        self.backend = backend
        self.profileID = profileID
        self.profileRevisionID = profileRevisionID
        self.sceneID = sceneID
        self.mihomoMode = mihomoMode
        self.proxySelections = proxySelections
        self.systemProxyDesired = systemProxyDesired ?? (backend == .systemProxy)
        self.configurationGenerationID = configurationGenerationID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        previousCoreID = try container.decode(CoreID.self, forKey: .previousCoreID)
        backend = try container.decode(CoreBackendSelection.self, forKey: .backend)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        profileRevisionID = try container.decodeIfPresent(UUID.self, forKey: .profileRevisionID)
        sceneID = try container.decodeIfPresent(UUID.self, forKey: .sceneID)
        mihomoMode = try container.decodeIfPresent(MihomoMode.self, forKey: .mihomoMode)
        proxySelections = try container.decodeIfPresent(
            [UpdateProxySelection].self,
            forKey: .proxySelections
        ) ?? []
        systemProxyDesired = try container.decodeIfPresent(
            Bool.self,
            forKey: .systemProxyDesired
        ) ?? (backend == .systemProxy)
        configurationGenerationID = try container.decode(
            UUID.self,
            forKey: .configurationGenerationID
        )
    }

    func validate() throws {
        guard !systemProxyDesired || backend == .systemProxy else {
            throw CoreStoreModelError.invalidActivationSnapshot
        }
        do {
            try UpdateRuntimeSnapshot(
                profileID: profileID,
                profileRevisionID: profileRevisionID,
                sceneID: sceneID,
                systemProxyDesired: systemProxyDesired,
                mihomoMode: mihomoMode,
                configurationGenerationID: configurationGenerationID,
                proxySelections: proxySelections
            ).validate()
        } catch {
            throw CoreStoreModelError.invalidActivationSnapshot
        }
    }
}

nonisolated struct CoreActivationTransaction: Codable, Equatable, Identifiable, Sendable {
    static let supportedSchemaVersion = 1

    var id: UUID { transactionID }
    var schemaVersion: Int
    let transactionID: UUID
    let coreID: CoreID
    var phase: CoreActivationPhase
    let startedAt: Date
    let snapshot: CoreActivationSnapshot?
    var automaticRollbackAttempts: Int

    init(
        schemaVersion: Int = supportedSchemaVersion,
        transactionID: UUID = UUID(),
        coreID: CoreID,
        phase: CoreActivationPhase,
        startedAt: Date = .now,
        snapshot: CoreActivationSnapshot? = nil,
        automaticRollbackAttempts: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.coreID = coreID
        self.phase = phase
        self.startedAt = startedAt
        self.snapshot = snapshot
        self.automaticRollbackAttempts = automaticRollbackAttempts
    }

    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw CoreStoreModelError.unsupportedSchemaVersion(schemaVersion)
        }
        guard automaticRollbackAttempts >= 0, automaticRollbackAttempts <= 1 else {
            throw CoreStoreModelError.invalidRollbackAttempts
        }
        if [.activating, .probation, .committed, .rollingBack].contains(phase) {
            guard snapshot != nil else { throw CoreStoreModelError.missingActivationSnapshot }
        }
        try snapshot?.validate()
    }
}

nonisolated enum CoreStoreModelError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidSelectionPreferences
    case invalidInstalledRecord(CoreID)
    case duplicateInstalledCore
    case missingProtectedCore(CoreID)
    case invalidCatalogCheckpoint
    case invalidRollbackAttempts
    case missingActivationSnapshot
    case invalidActivationSnapshot
    case invalidInstallCatalogIdentity
    case invalidInstallJournal
}
