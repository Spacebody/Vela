import Foundation
import VelaIPC

nonisolated enum ConfigurationLayerKind: String, Codable, CaseIterable, Equatable, Sendable {
    case global
    case profile
    case scene
    case runtimeForced
    case privilegedSanitizer

    var precedence: Int {
        switch self {
        case .global: 0
        case .profile: 1
        case .scene: 2
        case .runtimeForced: 3
        case .privilegedSanitizer: 4
        }
    }

    var isUserEditable: Bool {
        switch self {
        case .global, .profile, .scene: true
        case .runtimeForced, .privilegedSanitizer: false
        }
    }
}

nonisolated enum ConfigurationOperationKind: String, Codable, Equatable, Sendable {
    case set
    case remove
    case deepMerge
    case prependUnique
    case appendUnique
    case upsertNamed
    case removeNamed
}

nonisolated enum ConfigurationDuplicatePolicy: String, Codable, Equatable, Sendable {
    case replace
    case deepMerge
    case error
}

nonisolated enum ConfigurationInsertionPosition: String, Codable, Equatable, Sendable {
    case beginning
    case end
}

nonisolated struct ConfigurationOperation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var enabled: Bool
    var order: Int
    var path: YAMLPointer
    var kind: ConfigurationOperationKind
    var value: YAMLValue?
    var identityKey: String?
    var identityValue: String?
    var duplicatePolicy: ConfigurationDuplicatePolicy
    var insertionPosition: ConfigurationInsertionPosition
    var note: String?

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        order: Int,
        path: YAMLPointer,
        kind: ConfigurationOperationKind,
        value: YAMLValue? = nil,
        identityKey: String? = nil,
        identityValue: String? = nil,
        duplicatePolicy: ConfigurationDuplicatePolicy = .replace,
        insertionPosition: ConfigurationInsertionPosition = .end,
        note: String? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.order = order
        self.path = path
        self.kind = kind
        self.value = value
        self.identityKey = identityKey
        self.identityValue = identityValue
        self.duplicatePolicy = duplicatePolicy
        self.insertionPosition = insertionPosition
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, enabled, order, path, kind, value, identityKey, identityValue
        case duplicatePolicy, insertionPosition, note
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        order = try container.decode(Int.self, forKey: .order)
        path = try container.decode(YAMLPointer.self, forKey: .path)
        kind = try container.decode(ConfigurationOperationKind.self, forKey: .kind)
        value = try container.decodeIfPresent(YAMLValue.self, forKey: .value)
        identityKey = try container.decodeIfPresent(String.self, forKey: .identityKey)
        identityValue = try container.decodeIfPresent(String.self, forKey: .identityValue)
        duplicatePolicy = try container.decodeIfPresent(
            ConfigurationDuplicatePolicy.self,
            forKey: .duplicatePolicy
        ) ?? .replace
        insertionPosition = try container.decodeIfPresent(
            ConfigurationInsertionPosition.self,
            forKey: .insertionPosition
        ) ?? .end
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

nonisolated struct ConfigurationLayer: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    var revision: Int
    var name: String
    var kind: ConfigurationLayerKind
    var enabled: Bool
    var operations: [ConfigurationOperation]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        schemaVersion: Int = currentSchemaVersion,
        revision: Int = 1,
        name: String,
        kind: ConfigurationLayerKind,
        enabled: Bool = true,
        operations: [ConfigurationOperation] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.operations = operations
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, revision, name, kind, enabled, operations, createdAt, updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decode(Int.self, forKey: .revision)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(ConfigurationLayerKind.self, forKey: .kind)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        operations = try container.decode([ConfigurationOperation].self, forKey: .operations)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

nonisolated enum ConfigurationDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case warning
    case error
}

nonisolated enum ConfigurationDiagnosticCode: String, Codable, Equatable, Sendable {
    case removeMissingPath
    case typeMismatch
    case crossLayerOverride
    case duplicateValueIgnored
    case invalidYAML
    case invalidPointer
    case protectedPath
    case operationConflict
    case invalidOperation
    case limitExceeded
    case deterministicEncodingFailed
}

nonisolated struct ConfigurationDiagnostic: Codable, Equatable, Sendable {
    let severity: ConfigurationDiagnosticSeverity
    let code: ConfigurationDiagnosticCode
    let message: String
    let path: YAMLPointer?
    let layerID: UUID?
    let operationID: UUID?
}

nonisolated struct ConfigurationConflict: Codable, Equatable, Sendable {
    let path: YAMLPointer
    let previousSource: SourceReference
    let overridingSource: SourceReference
    let message: String
}

nonisolated enum SourceReferenceKind: String, Codable, Equatable, Sendable {
    case upstream
    case layer
    case runtimeForced
    case privilegedSanitizer
}

nonisolated struct SourceReference: Codable, Equatable, Sendable {
    let kind: SourceReferenceKind
    let profileRevisionID: UUID?
    let semanticPath: YAMLPointer?
    let layerID: UUID?
    let layerRevision: Int?
    let operationID: UUID?
    let reasonCode: String?

    static func upstream(profileRevisionID: UUID?, path: YAMLPointer) -> SourceReference {
        SourceReference(
            kind: .upstream,
            profileRevisionID: profileRevisionID,
            semanticPath: path,
            layerID: nil,
            layerRevision: nil,
            operationID: nil,
            reasonCode: nil
        )
    }

    static func layer(_ layer: ConfigurationLayer, operationID: UUID) -> SourceReference {
        SourceReference(
            kind: .layer,
            profileRevisionID: nil,
            semanticPath: nil,
            layerID: layer.id,
            layerRevision: layer.revision,
            operationID: operationID,
            reasonCode: nil
        )
    }

    static func runtimeForced(_ reasonCode: String) -> SourceReference {
        SourceReference(
            kind: .runtimeForced,
            profileRevisionID: nil,
            semanticPath: nil,
            layerID: nil,
            layerRevision: nil,
            operationID: nil,
            reasonCode: reasonCode
        )
    }
}

nonisolated struct SourceContribution: Codable, Equatable, Sendable {
    let source: SourceReference
    let valueFingerprint: String
}

nonisolated struct ConfigPathProvenance: Codable, Equatable, Sendable {
    let path: YAMLPointer
    var effectiveSource: SourceReference
    var contributors: [SourceContribution]
    var conflicts: [ConfigurationConflict]
    var isProtected: Bool
    var isRedacted: Bool
}

nonisolated struct ConfigurationProvenanceGraph: Codable, Equatable, Sendable {
    var paths: [String: ConfigPathProvenance]

    subscript(pointer: YAMLPointer) -> ConfigPathProvenance? {
        paths[pointer.rawValue]
    }
}

nonisolated enum RuleOrigin: Codable, Equatable, Sendable {
    case upstream(originalIndex: Int)
    case global(ruleID: UUID)
    case profile(ruleID: UUID)
    case scene(ruleID: UUID)
}

nonisolated struct EffectiveRuleOrigin: Codable, Equatable, Sendable {
    let runtimeIndex: Int
    let ruleFingerprint: String
    let origin: RuleOrigin
    let configurationGenerationID: UUID
}

nonisolated struct EffectiveRuleIndexMap: Codable, Equatable, Sendable {
    let entries: [EffectiveRuleOrigin]
}

nonisolated struct EffectiveConfigurationGeneration: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let profileID: UUID
    let profileRevisionID: UUID
    let globalLayerRevision: Int
    let profileLayerRevision: Int
    let sceneID: UUID?
    let sceneLayerRevision: Int?
    let backend: EngineBackendKind
    let compiledSHA256: String
    let appliedAt: Date
}

nonisolated struct ConfigurationCompilerLimits: Equatable, Sendable {
    var maximumLayerBytes = 1 * 1_024 * 1_024
    var maximumOperationsPerLayer = 2_000
    var maximumPointerBytes = 1_024
    var maximumDepth = 64
    var maximumValueBytes = 256 * 1_024
    var maximumOutputBytes = 20 * 1_024 * 1_024

    static let `default` = ConfigurationCompilerLimits()
}
