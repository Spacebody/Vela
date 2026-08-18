import Foundation
import VelaIPC

nonisolated enum ReleaseChannel: String, Codable, CaseIterable, Equatable, Sendable {
    case stable
    case beta

    /// Sparkle always includes unchannelled (stable) items. Beta users opt in
    /// only to the additional beta channel.
    var allowedSparkleChannels: Set<String> {
        switch self {
        case .stable:
            []
        case .beta:
            [Self.beta.rawValue]
        }
    }
}
nonisolated struct ReleaseBuildIdentity: Codable, Equatable, Sendable {
    let version: String
    let build: Int

    init(version: String, build: Int) {
        self.version = version
        self.build = build
    }

    init(bundle: Bundle) throws {
        guard let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
            let encodedBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion"),
            let build = Int(String(describing: encodedBuild)),
            !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            build > 0
        else {
            throw ReleaseManifestValidationError.invalidBundleIdentity
        }
        self.init(version: version, build: build)
    }
}

nonisolated struct ProtocolCompatibilityRange: Codable, Equatable, Sendable {
    let min: Int
    let max: Int

    init(min: Int, max: Int) {
        self.min = min
        self.max = max
    }

    var isValid: Bool {
        min > 0 && max >= min
    }

    func overlaps(_ other: ProtocolCompatibilityRange) -> Bool {
        isValid && other.isValid && min <= other.max && max >= other.min
    }

    func negotiatedVersion(with other: ProtocolCompatibilityRange) -> Int? {
        guard overlaps(other) else { return nil }
        return Swift.min(max, other.max)
    }
}

nonisolated struct ReleaseManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumEncodedBytes = 1 * 1_024 * 1_024

    let schemaVersion: Int
    let app: Application
    let build: Build
    let platform: Platform
    let components: Components
    let protocols: Protocols
    let schemas: Schemas
    let source: Source
    let toolchain: Toolchain

    nonisolated struct Application: Codable, Equatable, Sendable {
        let version: String
        let build: Int
        let channel: ReleaseChannel
        let prereleaseLabel: String?
        let bundleIdentifier: String

        var identity: ReleaseBuildIdentity {
            ReleaseBuildIdentity(version: version, build: build)
        }
    }

    nonisolated struct Build: Codable, Equatable, Sendable {
        let createdAtUTC: Date
        let sourceDirty: Bool
    }

    nonisolated struct Platform: Codable, Equatable, Sendable {
        let minimumMacOS: String
        let architectures: [String]
    }

    nonisolated struct Components: Codable, Equatable, Sendable {
        let mihomo: String
        let sparkle: String
        let helper: String
        let cli: String?
    }

    nonisolated struct Protocols: Codable, Equatable, Sendable {
        let helper: ProtocolCompatibilityRange
        let automation: ProtocolCompatibilityRange?
        let cli: ProtocolCompatibilityRange?

        private enum CodingKeys: String, CodingKey {
            case helperMinimum
            case helperMaximum
            case automationMinimum
            case automationMaximum
            case cliMinimum
            case cliMaximum
        }

        init(
            helper: ProtocolCompatibilityRange,
            automation: ProtocolCompatibilityRange? = nil,
            cli: ProtocolCompatibilityRange? = nil
        ) {
            self.helper = helper
            self.automation = automation
            self.cli = cli
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            helper = ProtocolCompatibilityRange(
                min: try container.decode(Int.self, forKey: .helperMinimum),
                max: try container.decode(Int.self, forKey: .helperMaximum)
            )
            automation = try Self.decodeRange(
                minimum: .automationMinimum,
                maximum: .automationMaximum,
                from: container
            )
            cli = try Self.decodeRange(
                minimum: .cliMinimum,
                maximum: .cliMaximum,
                from: container
            )
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(helper.min, forKey: .helperMinimum)
            try container.encode(helper.max, forKey: .helperMaximum)
            try Self.encodeRange(
                automation,
                minimum: .automationMinimum,
                maximum: .automationMaximum,
                to: &container
            )
            try Self.encodeRange(
                cli,
                minimum: .cliMinimum,
                maximum: .cliMaximum,
                to: &container
            )
        }

        private static func decodeRange(
            minimum: CodingKeys,
            maximum: CodingKeys,
            from container: KeyedDecodingContainer<CodingKeys>
        ) throws -> ProtocolCompatibilityRange? {
            let min = try container.decodeIfPresent(Int.self, forKey: minimum)
            let max = try container.decodeIfPresent(Int.self, forKey: maximum)
            guard min != nil || max != nil else { return nil }
            guard let min, let max else {
                throw DecodingError.dataCorruptedError(
                    forKey: min == nil ? minimum : maximum,
                    in: container,
                    debugDescription: "A protocol range requires both minimum and maximum."
                )
            }
            return ProtocolCompatibilityRange(min: min, max: max)
        }

        private static func encodeRange(
            _ range: ProtocolCompatibilityRange?,
            minimum: CodingKeys,
            maximum: CodingKeys,
            to container: inout KeyedEncodingContainer<CodingKeys>
        ) throws {
            guard let range else { return }
            try container.encode(range.min, forKey: minimum)
            try container.encode(range.max, forKey: maximum)
        }
    }

    nonisolated struct Schemas: Codable, Equatable, Sendable {
        let data: Int
        let profiles: Int
        let configuration: Int
        let scene: Int?
        let updateJournal: Int
    }

    nonisolated struct Source: Codable, Equatable, Sendable {
        let commit: String
        let tag: String
        let packageResolvedSHA256: String
    }

    nonisolated struct Toolchain: Codable, Equatable, Sendable {
        let xcode: String
        let swift: String?
        let sdk: String?
        let hostArchitecture: String?
    }

    var buildIdentity: ReleaseBuildIdentity { app.identity }

    func validateCurrentRelease(
        expectedBuildIdentity: ReleaseBuildIdentity? = nil,
        requirements: ReleaseCompatibilityRequirements = .current
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ReleaseManifestValidationError.unsupportedSchema(schemaVersion)
        }
        guard app.build > 0,
            !app.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ReleaseManifestValidationError.invalidBuildIdentity
        }
        if let expectedBuildIdentity, app.identity != expectedBuildIdentity {
            throw ReleaseManifestValidationError.bundleIdentityMismatch(
                expected: expectedBuildIdentity,
                actual: app.identity
            )
        }
        guard app.bundleIdentifier == requirements.bundleIdentifier else {
            throw ReleaseManifestValidationError.valueMismatch(
                field: "app.bundleIdentifier",
                expected: requirements.bundleIdentifier,
                actual: app.bundleIdentifier
            )
        }
        guard !build.sourceDirty else {
            throw ReleaseManifestValidationError.dirtySource
        }
        guard platform.minimumMacOS == requirements.minimumMacOS else {
            throw ReleaseManifestValidationError.valueMismatch(
                field: "platform.minimumMacOS",
                expected: requirements.minimumMacOS,
                actual: platform.minimumMacOS
            )
        }
        guard platform.architectures == requirements.architectures else {
            throw ReleaseManifestValidationError.valueMismatch(
                field: "platform.architectures",
                expected: requirements.architectures.joined(separator: ","),
                actual: platform.architectures.joined(separator: ",")
            )
        }
        guard components.mihomo == requirements.mihomoVersion else {
            throw ReleaseManifestValidationError.valueMismatch(
                field: "components.mihomo",
                expected: requirements.mihomoVersion,
                actual: components.mihomo
            )
        }
        guard components.sparkle == requirements.sparkleVersion else {
            throw ReleaseManifestValidationError.valueMismatch(
                field: "components.sparkle",
                expected: requirements.sparkleVersion,
                actual: components.sparkle
            )
        }
        guard components.helper == requirements.helperVersion else {
            throw ReleaseManifestValidationError.valueMismatch(
                field: "components.helper",
                expected: requirements.helperVersion,
                actual: components.helper
            )
        }
        guard protocols.helper.isValid else {
            throw ReleaseManifestValidationError.invalidProtocolRange("helper")
        }
        guard protocols.helper == requirements.helperProtocol else {
            throw ReleaseManifestValidationError.valueMismatch(
                field: "protocols.helper",
                expected: "\(requirements.helperProtocol.min)...\(requirements.helperProtocol.max)",
                actual: "\(protocols.helper.min)...\(protocols.helper.max)"
            )
        }
        for (name, range) in [
            ("automation", protocols.automation),
            ("cli", protocols.cli),
        ] where range?.isValid == false {
            throw ReleaseManifestValidationError.invalidProtocolRange(name)
        }
        guard schemas.data == requirements.dataSchema else {
            throw ReleaseManifestValidationError.schemaMismatch(
                name: "data",
                expected: requirements.dataSchema,
                actual: schemas.data
            )
        }
        guard schemas.profiles == requirements.profileSchema else {
            throw ReleaseManifestValidationError.schemaMismatch(
                name: "profiles",
                expected: requirements.profileSchema,
                actual: schemas.profiles
            )
        }
        guard schemas.configuration == requirements.configurationSchema else {
            throw ReleaseManifestValidationError.schemaMismatch(
                name: "configuration",
                expected: requirements.configurationSchema,
                actual: schemas.configuration
            )
        }
        guard schemas.scene == requirements.sceneSchema else {
            throw ReleaseManifestValidationError.optionalSchemaMismatch(
                name: "scene",
                expected: requirements.sceneSchema,
                actual: schemas.scene
            )
        }
        guard schemas.updateJournal == requirements.updateJournalSchema else {
            throw ReleaseManifestValidationError.schemaMismatch(
                name: "updateJournal",
                expected: requirements.updateJournalSchema,
                actual: schemas.updateJournal
            )
        }
        guard Self.isLowercaseSHA256(source.packageResolvedSHA256) else {
            throw ReleaseManifestValidationError.invalidSHA256(
                field: "source.packageResolvedSHA256"
            )
        }
        guard Self.isLowercaseCommit(source.commit) else {
            throw ReleaseManifestValidationError.invalidCommit
        }
        guard !source.tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReleaseManifestValidationError.invalidTag
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy(Self.isLowercaseHex)
    }

    private static func isLowercaseCommit(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy(Self.isLowercaseHex)
    }

    private static func isLowercaseHex(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 97...102:
            true
        default:
            false
        }
    }
}

nonisolated struct ReleaseCompatibilityRequirements: Equatable, Sendable {
    let bundleIdentifier: String
    let minimumMacOS: String
    let architectures: [String]
    let mihomoVersion: String
    let sparkleVersion: String
    let helperVersion: String
    let helperProtocol: ProtocolCompatibilityRange
    let dataSchema: Int
    let profileSchema: Int
    let configurationSchema: Int
    let sceneSchema: Int?
    let updateJournalSchema: Int

    static let current = ReleaseCompatibilityRequirements(
        bundleIdentifier: VelaIPCConstants.mainBundleIdentifier,
        minimumMacOS: "15.0",
        architectures: ["arm64"],
        mihomoVersion: VelaIPCConstants.expectedMihomoVersion,
        sparkleVersion: "2.9.4",
        helperVersion: VelaIPCConstants.helperSemanticVersion,
        helperProtocol: ProtocolCompatibilityRange(
            min: VelaIPCConstants.protocolMinimum,
            max: VelaIPCConstants.protocolMaximum
        ),
        dataSchema: VelaIPCConstants.rootDataSchemaVersion,
        profileSchema: ProfileDatabaseEnvelope.currentSchemaVersion,
        configurationSchema: ConfigurationLayerStoreDocument.currentSchemaVersion,
        sceneSchema: nil,
        updateJournalSchema: UpdateJournal.currentSchemaVersion
    )
}

nonisolated enum ReleaseManifestValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidBundleIdentity
    case invalidBuildIdentity
    case bundleIdentityMismatch(expected: ReleaseBuildIdentity, actual: ReleaseBuildIdentity)
    case dirtySource
    case valueMismatch(field: String, expected: String, actual: String)
    case invalidProtocolRange(String)
    case schemaMismatch(name: String, expected: Int, actual: Int)
    case optionalSchemaMismatch(name: String, expected: Int?, actual: Int?)
    case invalidSHA256(field: String)
    case invalidCommit
    case invalidTag
}
