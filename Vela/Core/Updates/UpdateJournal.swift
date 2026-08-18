import Foundation
import VelaIPC

nonisolated enum UpdateJournalPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case preparing
    case quiescing
    case readyForInstaller
    case installerStarted
    case firstLaunch
    case migrating
    case verifying
    case restoring
    case committed
    case failed
    case recoveryRequired
}
nonisolated enum UpdateJournalBackend: String, Codable, Equatable, Sendable {
    case userProcess
    case tun
}

nonisolated struct UpdateProxySelection: Codable, Equatable, Sendable {
    let groupID: String
    let proxyID: String

    init(groupID: String, proxyID: String) {
        self.groupID = groupID
        self.proxyID = proxyID
    }
}

nonisolated struct UpdateRuntimeSnapshot: Codable, Equatable, Sendable {
    let profileID: UUID?
    let profileRevisionID: UUID?
    let sceneID: UUID?
    let backend: UpdateJournalBackend?
    let systemProxyDesired: Bool
    let mihomoMode: MihomoMode?
    let automaticScenesEnabled: Bool
    let helperVersion: String?
    let helperProtocol: Int?
    let configurationGenerationID: UUID?
    let proxySelections: [UpdateProxySelection]
    let activeCoreID: CoreID?
    let previousKnownGoodCoreID: CoreID?
    let coreSelectionMode: CoreSelectionMode?
    let highestCatalogSequence: UInt64?
    let coreTrustRootSetVersion: Int?

    init(
        profileID: UUID? = nil,
        profileRevisionID: UUID? = nil,
        sceneID: UUID? = nil,
        backend: UpdateJournalBackend? = nil,
        systemProxyDesired: Bool = false,
        mihomoMode: MihomoMode? = nil,
        automaticScenesEnabled: Bool = false,
        helperVersion: String? = nil,
        helperProtocol: Int? = nil,
        configurationGenerationID: UUID? = nil,
        proxySelections: [UpdateProxySelection] = [],
        activeCoreID: CoreID? = nil,
        previousKnownGoodCoreID: CoreID? = nil,
        coreSelectionMode: CoreSelectionMode? = nil,
        highestCatalogSequence: UInt64? = nil,
        coreTrustRootSetVersion: Int? = nil
    ) {
        self.profileID = profileID
        self.profileRevisionID = profileRevisionID
        self.sceneID = sceneID
        self.backend = backend
        self.systemProxyDesired = systemProxyDesired
        self.mihomoMode = mihomoMode
        self.automaticScenesEnabled = automaticScenesEnabled
        self.helperVersion = helperVersion
        self.helperProtocol = helperProtocol
        self.configurationGenerationID = configurationGenerationID
        self.proxySelections = proxySelections
        self.activeCoreID = activeCoreID
        self.previousKnownGoodCoreID = previousKnownGoodCoreID
        self.coreSelectionMode = coreSelectionMode
        self.highestCatalogSequence = highestCatalogSequence
        self.coreTrustRootSetVersion = coreTrustRootSetVersion
    }

    func validate() throws {
        if profileRevisionID != nil, profileID == nil {
            throw UpdateJournalValidationError.revisionWithoutProfile
        }
        if let helperProtocol, helperProtocol <= 0 {
            throw UpdateJournalValidationError.invalidHelperProtocol(helperProtocol)
        }
        if let helperVersion {
            try UpdateJournalPersistedTextPolicy.validate(
                helperVersion,
                field: "snapshot.helperVersion",
                maximumLength: 128
            )
        }
        if let coreTrustRootSetVersion, coreTrustRootSetVersion <= 0 {
            throw UpdateJournalValidationError.invalidCoreTrustRootSetVersion(
                coreTrustRootSetVersion
            )
        }
        if activeCoreID == nil {
            guard previousKnownGoodCoreID == nil,
                coreSelectionMode == nil,
                highestCatalogSequence == nil,
                coreTrustRootSetVersion == nil
            else {
                throw UpdateJournalValidationError.incompleteCoreSnapshot
            }
        }
        guard proxySelections.count <= 256 else {
            throw UpdateJournalValidationError.tooManyProxySelections
        }
        var groups = Set<String>()
        for selection in proxySelections {
            try UpdateJournalPersistedTextPolicy.validate(
                selection.groupID,
                field: "snapshot.proxySelections.groupID",
                maximumLength: 512
            )
            try UpdateJournalPersistedTextPolicy.validate(
                selection.proxyID,
                field: "snapshot.proxySelections.proxyID",
                maximumLength: 512
            )
            guard groups.insert(selection.groupID).inserted else {
                throw UpdateJournalValidationError.duplicateProxySelectionGroup(
                    selection.groupID
                )
            }
        }
    }
}

nonisolated struct UpdateFailureSummary: Codable, Equatable, Sendable {
    let code: String
    let phase: UpdateJournalPhase?
    let summary: String

    init(code: String, phase: UpdateJournalPhase? = nil, summary: String) {
        self.code = code
        self.phase = phase
        self.summary = DiagnosticTextSanitizer.redact(summary)
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case phase
        case summary
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        phase = try container.decodeIfPresent(UpdateJournalPhase.self, forKey: .phase)
        summary = DiagnosticTextSanitizer.redact(
            try container.decode(String.self, forKey: .summary)
        )
    }

    func validate() throws {
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !code.isEmpty,
            code.count <= 128,
            code.unicodeScalars.allSatisfy(permitted.contains)
        else {
            throw UpdateJournalValidationError.invalidFailureCode
        }
        guard summary.count <= 1_024,
            summary == DiagnosticTextSanitizer.redact(summary)
        else {
            throw UpdateJournalValidationError.unsafeFailureSummary
        }
    }
}

nonisolated struct UpdateJournal: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumEncodedBytes = 1 * 1_024 * 1_024
    static let maximumRecoveryAttempts = 1

    let schemaVersion: Int
    let updateID: UUID
    let source: ReleaseBuildIdentity
    let target: ReleaseBuildIdentity
    var phase: UpdateJournalPhase
    let snapshot: UpdateRuntimeSnapshot
    let startedAt: Date
    var lastUpdatedAt: Date
    var failure: UpdateFailureSummary?
    var recoveryAttempts: Int

    init(
        schemaVersion: Int = currentSchemaVersion,
        updateID: UUID = UUID(),
        source: ReleaseBuildIdentity,
        target: ReleaseBuildIdentity,
        phase: UpdateJournalPhase = .preparing,
        snapshot: UpdateRuntimeSnapshot,
        startedAt: Date = .now,
        lastUpdatedAt: Date? = nil,
        failure: UpdateFailureSummary? = nil,
        recoveryAttempts: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.updateID = updateID
        self.source = source
        self.target = target
        self.phase = phase
        self.snapshot = snapshot
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt ?? startedAt
        self.failure = failure
        self.recoveryAttempts = recoveryAttempts
    }

    var isActive: Bool {
        phase != .committed
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw UpdateJournalValidationError.unsupportedSchema(schemaVersion)
        }
        guard source.build > 0,
            target.build > source.build,
            !source.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !target.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw UpdateJournalValidationError.invalidBuildTransition
        }
        guard startedAt.timeIntervalSince1970.isFinite,
            lastUpdatedAt.timeIntervalSince1970.isFinite,
            lastUpdatedAt >= startedAt
        else {
            throw UpdateJournalValidationError.invalidTimestampOrder
        }
        guard (0...Self.maximumRecoveryAttempts).contains(recoveryAttempts) else {
            throw UpdateJournalValidationError.invalidRecoveryAttempts(recoveryAttempts)
        }
        try UpdateJournalPersistedTextPolicy.validate(
            source.version,
            field: "source.version",
            maximumLength: 128
        )
        try UpdateJournalPersistedTextPolicy.validate(
            target.version,
            field: "target.version",
            maximumLength: 128
        )
        try snapshot.validate()
        try failure?.validate()
    }

    var diagnosticSummary: UpdateJournalDiagnosticSummary {
        UpdateJournalDiagnosticSummary(
            schemaVersion: schemaVersion,
            updateID: updateID,
            source: source,
            target: target,
            phase: phase,
            startedAt: startedAt,
            lastUpdatedAt: lastUpdatedAt,
            failureCode: failure?.code,
            recoveryAttempts: recoveryAttempts,
            backend: snapshot.backend,
            systemProxyDesired: snapshot.systemProxyDesired,
            hasProfileSnapshot: snapshot.profileID != nil,
            hasSceneSnapshot: snapshot.sceneID != nil,
            helperVersion: snapshot.helperVersion,
            helperProtocol: snapshot.helperProtocol,
            proxySelectionCount: snapshot.proxySelections.count,
            activeCoreID: snapshot.activeCoreID,
            coreSelectionMode: snapshot.coreSelectionMode,
            highestCatalogSequence: snapshot.highestCatalogSequence,
            coreTrustRootSetVersion: snapshot.coreTrustRootSetVersion
        )
    }
}

nonisolated struct UpdateJournalDiagnosticSummary: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let updateID: UUID
    let source: ReleaseBuildIdentity
    let target: ReleaseBuildIdentity
    let phase: UpdateJournalPhase
    let startedAt: Date
    let lastUpdatedAt: Date
    let failureCode: String?
    let recoveryAttempts: Int
    let backend: UpdateJournalBackend?
    let systemProxyDesired: Bool
    let hasProfileSnapshot: Bool
    let hasSceneSnapshot: Bool
    let helperVersion: String?
    let helperProtocol: Int?
    let proxySelectionCount: Int
    let activeCoreID: CoreID?
    let coreSelectionMode: CoreSelectionMode?
    let highestCatalogSequence: UInt64?
    let coreTrustRootSetVersion: Int?
}

nonisolated enum UpdateJournalValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidBuildTransition
    case invalidTimestampOrder
    case invalidRecoveryAttempts(Int)
    case revisionWithoutProfile
    case invalidHelperProtocol(Int)
    case invalidCoreTrustRootSetVersion(Int)
    case incompleteCoreSnapshot
    case tooManyProxySelections
    case duplicateProxySelectionGroup(String)
    case invalidPersistedText(field: String)
    case invalidFailureCode
    case unsafeFailureSummary
}

nonisolated private enum UpdateJournalPersistedTextPolicy {
    static func validate(
        _ value: String,
        field: String,
        maximumLength: Int
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = value.lowercased()
        guard !trimmed.isEmpty,
            value.count <= maximumLength,
            !value.contains("\n"),
            !value.contains("\r"),
            !value.contains("\0"),
            !lowered.contains("://"),
            !lowered.contains("authorization:"),
            !lowered.contains("bearer "),
            !lowered.contains("password="),
            !lowered.contains("token=")
        else {
            throw UpdateJournalValidationError.invalidPersistedText(field: field)
        }
    }
}
