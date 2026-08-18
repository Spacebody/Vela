import Foundation

nonisolated enum ReliabilityEventKind: String, CaseIterable, Codable, Sendable {
    case appLaunch
    case engineTransition
    case backendTransition
    case systemProxyTransition
    case tunTransition
    case helperHandshake
    case configurationTransaction
    case configurationValidation
    case profileUpdate
    case sceneTransition
    case workbenchSave
    case connectionsProcessing
    case rulesProcessing
    case appUpdate
    case coreActivation
    case coreProbation
    case recovery
    case migration
    case helpSearch
    case supportExport
}

nonisolated enum ReliabilityEventPhase: String, CaseIterable, Codable, Sendable {
    case requested
    case preparing
    case validating
    case applying
    case awaitingHealth
    case committed
    case rollingBack
    case rolledBack
    case failed
    case cancelled
    case timedOut
    case recovering
    case recovered
    case launching
    case rendering
    case handshaking
    case compiling
    case testing
    case activating
    case probation
    case searching
    case redacting
    case exporting
    case cleaningUp
}

/// Stable, non-diagnostic result identifiers. Raw errors never enter evidence.
nonisolated enum ReliabilityResultCode: String, CaseIterable, Codable, Sendable {
    case success
    case cancelled
    case timedOut
    case invalidState
    case duplicateRequest
    case permissionDenied
    case diskFull
    case validationFailed
    case processExited
    case handshakeFailed
    case healthCheckFailed
    case applyFailed
    case rollbackSucceeded
    case rollbackFailed
    case recoverySucceeded
    case recoveryFailed
    case corruptEvidenceQuarantined
    case unavailable
    case rejected
    case unknownFailure

    var isFailure: Bool {
        switch self {
        case .success, .rollbackSucceeded, .recoverySucceeded:
            false
        case .cancelled, .timedOut, .invalidState, .duplicateRequest,
             .permissionDenied, .diskFull, .validationFailed, .processExited,
             .handshakeFailed, .healthCheckFailed, .applyFailed, .rollbackFailed,
             .recoveryFailed, .corruptEvidenceQuarantined, .unavailable,
             .rejected, .unknownFailure:
            true
        }
    }
}

nonisolated enum ReliabilityRollbackOutcome: String, CaseIterable, Codable, Sendable {
    case succeeded
    case failed
    case previousKnownGoodHealthy
    case previousKnownGoodUnavailable
    case cleanupSucceeded
    case cleanupFailed
}

nonisolated enum ReliabilityChannel: String, CaseIterable, Codable, Sendable {
    case development
    case beta
    case stable
    case unknown
}

nonisolated enum ReliabilityDurationBucket: String, CaseIterable, Codable, Sendable {
    case under50Milliseconds
    case under200Milliseconds
    case under1Second
    case under5Seconds
    case under30Seconds
    case thirtySecondsOrMore

    static func bucket(for milliseconds: Int) -> Self {
        switch milliseconds {
        case ..<50: .under50Milliseconds
        case ..<200: .under200Milliseconds
        case ..<1_000: .under1Second
        case ..<5_000: .under5Seconds
        case ..<30_000: .under30Seconds
        default: .thirtySecondsOrMore
        }
    }
}

/// A deliberately narrow app-version value. It cannot carry paths, URLs, or messages.
nonisolated struct ReliabilityAppVersion: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 32,
              rawValue.utf8.first.map({ (48...57).contains($0) }) == true,
              !rawValue.contains(".."),
              rawValue.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 0x2e
                      || byte == 0x2b
                      || byte == 0x2d
              })
        else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let validated = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid app version"
            )
        }
        self = validated
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct ReliabilityBuildIdentity: Codable, Hashable, Sendable {
    let version: ReliabilityAppVersion
    let build: Int
    let channel: ReliabilityChannel

    init(version: ReliabilityAppVersion, build: Int, channel: ReliabilityChannel) {
        self.version = version
        self.build = build
        self.channel = channel
    }
}

nonisolated struct ReliabilitySHA256: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        let normalized = rawValue.lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              })
        else { return nil }
        self.rawValue = normalized
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let validated = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid SHA-256"
            )
        }
        self = validated
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Numeric process counters only; it intentionally has no labels or free-form fields.
nonisolated struct ReliabilityResourceSummary: Codable, Equatable, Sendable {
    let residentMemoryMiB: Int?
    let openFileDescriptorCount: Int?
    let threadCount: Int?
    let activeTaskCount: Int?
    let socketCount: Int?

    init(
        residentMemoryMiB: Int? = nil,
        openFileDescriptorCount: Int? = nil,
        threadCount: Int? = nil,
        activeTaskCount: Int? = nil,
        socketCount: Int? = nil
    ) {
        self.residentMemoryMiB = residentMemoryMiB
        self.openFileDescriptorCount = openFileDescriptorCount
        self.threadCount = threadCount
        self.activeTaskCount = activeTaskCount
        self.socketCount = socketCount
    }

    var isEmpty: Bool {
        residentMemoryMiB == nil
            && openFileDescriptorCount == nil
            && threadCount == nil
            && activeTaskCount == nil
            && socketCount == nil
    }

    func validate() throws {
        try Self.validate(residentMemoryMiB, maximum: 1_048_576)
        try Self.validate(openFileDescriptorCount, maximum: 1_000_000)
        try Self.validate(threadCount, maximum: 1_000_000)
        try Self.validate(activeTaskCount, maximum: 1_000_000)
        try Self.validate(socketCount, maximum: 1_000_000)
    }

    private static func validate(_ value: Int?, maximum: Int) throws {
        if let value, !(0...maximum).contains(value) {
            throw ReliabilityEvidenceValidationError.invalidResourceCounter
        }
    }
}

/// Input accepted by the store. Identity, time, event ID, and session ID are store-owned.
nonisolated struct ReliabilityEventDraft: Sendable {
    let kind: ReliabilityEventKind
    let phase: ReliabilityEventPhase
    let resultCode: ReliabilityResultCode
    let durationMilliseconds: Int?
    let rollbackOutcome: ReliabilityRollbackOutcome?
    let resourceSummary: ReliabilityResourceSummary?
    let crashSignatureSHA256: ReliabilitySHA256?
    let testRunID: UUID?

    init(
        kind: ReliabilityEventKind,
        phase: ReliabilityEventPhase,
        resultCode: ReliabilityResultCode,
        durationMilliseconds: Int? = nil,
        rollbackOutcome: ReliabilityRollbackOutcome? = nil,
        resourceSummary: ReliabilityResourceSummary? = nil,
        crashSignatureSHA256: ReliabilitySHA256? = nil,
        testRunID: UUID? = nil
    ) {
        self.kind = kind
        self.phase = phase
        self.resultCode = resultCode
        self.durationMilliseconds = durationMilliseconds
        self.rollbackOutcome = rollbackOutcome
        self.resourceSummary = resourceSummary?.isEmpty == true ? nil : resourceSummary
        self.crashSignatureSHA256 = crashSignatureSHA256
        self.testRunID = testRunID
    }
}

nonisolated struct ReliabilityEvidence: Codable, Identifiable, Equatable, Sendable {
    static let maximumDurationMilliseconds = 86_400_000

    let id: UUID
    let occurredAt: Date
    let identity: ReliabilityBuildIdentity
    let sessionID: UUID
    let testRunID: UUID?
    let kind: ReliabilityEventKind
    let phase: ReliabilityEventPhase
    let resultCode: ReliabilityResultCode
    let durationMilliseconds: Int?
    let durationBucket: ReliabilityDurationBucket?
    let rollbackOutcome: ReliabilityRollbackOutcome?
    let resourceSummary: ReliabilityResourceSummary?
    let crashSignatureSHA256: ReliabilitySHA256?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id = "eventID"
        case occurredAt
        case identity
        case sessionID
        case testRunID
        case kind
        case phase
        case resultCode
        case durationMilliseconds
        case durationBucket
        case rollbackOutcome
        case resourceSummary
        case crashSignatureSHA256
    }

    init(
        id: UUID,
        occurredAt: Date,
        identity: ReliabilityBuildIdentity,
        sessionID: UUID,
        draft: ReliabilityEventDraft
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.identity = identity
        self.sessionID = sessionID
        testRunID = draft.testRunID
        kind = draft.kind
        phase = draft.phase
        resultCode = draft.resultCode
        durationMilliseconds = draft.durationMilliseconds
        durationBucket = draft.durationMilliseconds.map(ReliabilityDurationBucket.bucket)
        rollbackOutcome = draft.rollbackOutcome
        resourceSummary = draft.resourceSummary
        crashSignatureSHA256 = draft.crashSignatureSHA256
    }

    func validate(referenceDate: Date) throws {
        guard identity.build > 0, identity.build <= 9_999_999_999 else {
            throw ReliabilityEvidenceValidationError.invalidBuild
        }
        guard occurredAt.timeIntervalSince1970 >= 0,
              occurredAt <= referenceDate.addingTimeInterval(86_400)
        else {
            throw ReliabilityEvidenceValidationError.invalidTimestamp
        }
        if let durationMilliseconds {
            guard (0...Self.maximumDurationMilliseconds).contains(durationMilliseconds),
                  durationBucket == .bucket(for: durationMilliseconds)
            else {
                throw ReliabilityEvidenceValidationError.invalidDuration
            }
        } else if durationBucket != nil {
            throw ReliabilityEvidenceValidationError.invalidDuration
        }
        try resourceSummary?.validate()
    }
}

nonisolated struct ReliabilityRetentionPolicy: Codable, Equatable, Sendable {
    static let maximumAllowedDays = 30
    static let maximumAllowedEvents = 5_000
    static let `default` = ReliabilityRetentionPolicy(
        maximumDays: maximumAllowedDays,
        maximumEvents: maximumAllowedEvents
    )

    let maximumDays: Int
    let maximumEvents: Int

    init(maximumDays: Int, maximumEvents: Int) {
        self.maximumDays = min(max(1, maximumDays), Self.maximumAllowedDays)
        self.maximumEvents = min(max(1, maximumEvents), Self.maximumAllowedEvents)
    }

    func validate() throws {
        guard (1...Self.maximumAllowedDays).contains(maximumDays),
              (1...Self.maximumAllowedEvents).contains(maximumEvents)
        else {
            throw ReliabilityEvidenceValidationError.invalidRetention
        }
    }
}

nonisolated struct ReliabilityEvidenceLedger: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let retention: ReliabilityRetentionPolicy
    var events: [ReliabilityEvidence]

    init(retention: ReliabilityRetentionPolicy, events: [ReliabilityEvidence]) {
        schemaVersion = Self.currentSchemaVersion
        self.retention = retention
        self.events = events
    }

    func validate(referenceDate: Date) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ReliabilityEvidenceValidationError.unsupportedSchema
        }
        try retention.validate()
        guard events.count <= ReliabilityRetentionPolicy.maximumAllowedEvents,
              Set(events.map(\.id)).count == events.count
        else {
            throw ReliabilityEvidenceValidationError.invalidEventCollection
        }
        for event in events {
            try event.validate(referenceDate: referenceDate)
        }
    }
}

nonisolated enum ReliabilityEvidenceValidationError: Error, Equatable, Sendable {
    case unsupportedSchema
    case invalidRetention
    case invalidBuild
    case invalidTimestamp
    case invalidDuration
    case invalidResourceCounter
    case invalidEventCollection
    case unexpectedJSONShape
}

nonisolated enum ReliabilityEvidenceCoding {
    static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
