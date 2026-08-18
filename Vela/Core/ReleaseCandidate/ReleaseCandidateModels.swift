import Foundation

nonisolated struct ReleaseCandidateBaseline: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumEncodedBytes = 64 * 1_024
    static let maximumPublicContractBytes = 1 * 1_024 * 1_024
    static let requiredPublicContractResource = "public-contract-freeze.json"
    static let requiredKnownLimitationsResource = "known-limitations.json"
    static let requiredMarketingVersion = "1.0.0"
    static let requiredMinimumMacOS = "15.0"
    static let requiredArchitectures = ["arm64"]
    static let requiredMihomoVersion = "v1.19.29"
    static let requiredSparkleVersion = "2.9.4"
    static let requiredDataSchemaVersion = 3
    static let requiredHelperProtocolMinimum = 2
    static let requiredHelperProtocolMaximum = 2

    let schemaVersion: Int
    let marketingVersion: String
    let platform: Platform
    let components: Components
    let publicContractSHA256: String
    let publicContractFileSHA256: String
    let architectureFreezeSHA256: String
    let dataSchemaVersion: Int
    let helperProtocol: ProtocolRange
    let automationProtocol: ProtocolRange?
    let publicContractResource: String
    let knownLimitationsResource: String

    nonisolated struct Platform: Codable, Equatable, Sendable {
        let minimumMacOS: String
        let architectures: [String]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case minimumMacOS, architectures
        }

        init(minimumMacOS: String, architectures: [String]) {
            self.minimumMacOS = minimumMacOS
            self.architectures = architectures
        }

        init(from decoder: any Decoder) throws {
            try decoder.rejectReleaseCandidateUnknownKeys(CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            minimumMacOS = try container.decode(String.self, forKey: .minimumMacOS)
            architectures = try container.decode([String].self, forKey: .architectures)
        }

        func validate() throws {
            guard minimumMacOS == ReleaseCandidateBaseline.requiredMinimumMacOS,
                architectures == ReleaseCandidateBaseline.requiredArchitectures
            else {
                throw ReleaseCandidateValidationError.invalidPlatform
            }
        }
    }

    nonisolated struct Components: Codable, Equatable, Sendable {
        let mihomo: String
        let sparkle: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case mihomo, sparkle
        }

        init(mihomo: String, sparkle: String) {
            self.mihomo = mihomo
            self.sparkle = sparkle
        }

        init(from decoder: any Decoder) throws {
            try decoder.rejectReleaseCandidateUnknownKeys(CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mihomo = try container.decode(String.self, forKey: .mihomo)
            sparkle = try container.decode(String.self, forKey: .sparkle)
        }

        func validate() throws {
            guard mihomo == ReleaseCandidateBaseline.requiredMihomoVersion,
                sparkle == ReleaseCandidateBaseline.requiredSparkleVersion
            else {
                throw ReleaseCandidateValidationError.invalidComponents
            }
        }
    }

    nonisolated struct ProtocolRange: Codable, Equatable, Sendable {
        let minimum: Int
        let maximum: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case minimum, maximum
        }

        init(minimum: Int, maximum: Int) {
            self.minimum = minimum
            self.maximum = maximum
        }

        init(from decoder: any Decoder) throws {
            try decoder.rejectReleaseCandidateUnknownKeys(CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            minimum = try container.decode(Int.self, forKey: .minimum)
            maximum = try container.decode(Int.self, forKey: .maximum)
        }

        func validate() throws {
            guard minimum > 0, maximum >= minimum, maximum <= 1_000 else {
                throw ReleaseCandidateValidationError.invalidHelperProtocol
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case marketingVersion
        case platform
        case components
        case publicContractSHA256
        case publicContractFileSHA256
        case architectureFreezeSHA256
        case dataSchemaVersion
        case helperProtocol
        case automationProtocol
        case publicContractResource
        case knownLimitationsResource
    }

    init(
        schemaVersion: Int,
        marketingVersion: String,
        platform: Platform,
        components: Components,
        publicContractSHA256: String,
        publicContractFileSHA256: String,
        architectureFreezeSHA256: String,
        dataSchemaVersion: Int,
        helperProtocol: ProtocolRange,
        automationProtocol: ProtocolRange? = nil,
        publicContractResource: String = "public-contract-freeze.json",
        knownLimitationsResource: String = Self.requiredKnownLimitationsResource
    ) {
        self.schemaVersion = schemaVersion
        self.marketingVersion = marketingVersion
        self.platform = platform
        self.components = components
        self.publicContractSHA256 = publicContractSHA256
        self.publicContractFileSHA256 = publicContractFileSHA256
        self.architectureFreezeSHA256 = architectureFreezeSHA256
        self.dataSchemaVersion = dataSchemaVersion
        self.helperProtocol = helperProtocol
        self.automationProtocol = automationProtocol
        self.publicContractResource = publicContractResource
        self.knownLimitationsResource = knownLimitationsResource
    }

    init(from decoder: any Decoder) throws {
        try decoder.rejectReleaseCandidateUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        marketingVersion = try container.decode(String.self, forKey: .marketingVersion)
        platform = try container.decode(Platform.self, forKey: .platform)
        components = try container.decode(Components.self, forKey: .components)
        publicContractSHA256 = try container.decode(String.self, forKey: .publicContractSHA256)
        publicContractFileSHA256 = try container.decode(
            String.self,
            forKey: .publicContractFileSHA256
        )
        architectureFreezeSHA256 = try container.decode(
            String.self,
            forKey: .architectureFreezeSHA256
        )
        dataSchemaVersion = try container.decode(Int.self, forKey: .dataSchemaVersion)
        helperProtocol = try container.decode(ProtocolRange.self, forKey: .helperProtocol)
        guard container.contains(.automationProtocol) else {
            throw DecodingError.keyNotFound(
                CodingKeys.automationProtocol,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "automationProtocol must be explicitly null when absent"
                )
            )
        }
        automationProtocol = try container.decodeIfPresent(
            ProtocolRange.self,
            forKey: .automationProtocol
        )
        publicContractResource = try container.decode(
            String.self,
            forKey: .publicContractResource
        )
        knownLimitationsResource = try container.decode(
            String.self,
            forKey: .knownLimitationsResource
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(marketingVersion, forKey: .marketingVersion)
        try container.encode(platform, forKey: .platform)
        try container.encode(components, forKey: .components)
        try container.encode(publicContractSHA256, forKey: .publicContractSHA256)
        try container.encode(publicContractFileSHA256, forKey: .publicContractFileSHA256)
        try container.encode(architectureFreezeSHA256, forKey: .architectureFreezeSHA256)
        try container.encode(dataSchemaVersion, forKey: .dataSchemaVersion)
        try container.encode(helperProtocol, forKey: .helperProtocol)
        if let automationProtocol {
            try container.encode(automationProtocol, forKey: .automationProtocol)
        } else {
            try container.encodeNil(forKey: .automationProtocol)
        }
        try container.encode(publicContractResource, forKey: .publicContractResource)
        try container.encode(knownLimitationsResource, forKey: .knownLimitationsResource)
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ReleaseCandidateValidationError.unsupportedSchema(schemaVersion)
        }
        try ReleaseCandidateTextPolicy.validateVersion(
            marketingVersion,
            label: "marketingVersion"
        )
        guard marketingVersion == Self.requiredMarketingVersion else {
            throw ReleaseCandidateValidationError.invalidMarketingVersion
        }
        try platform.validate()
        try components.validate()
        guard ReleaseCandidateTextPolicy.isSHA256(publicContractSHA256) else {
            throw ReleaseCandidateValidationError.invalidSHA256("publicContractSHA256")
        }
        guard ReleaseCandidateTextPolicy.isSHA256(publicContractFileSHA256) else {
            throw ReleaseCandidateValidationError.invalidSHA256("publicContractFileSHA256")
        }
        guard ReleaseCandidateTextPolicy.isSHA256(architectureFreezeSHA256) else {
            throw ReleaseCandidateValidationError.invalidSHA256("architectureFreezeSHA256")
        }
        guard dataSchemaVersion == Self.requiredDataSchemaVersion else {
            throw ReleaseCandidateValidationError.invalidDataSchemaVersion
        }
        try helperProtocol.validate()
        guard helperProtocol.minimum == Self.requiredHelperProtocolMinimum,
            helperProtocol.maximum == Self.requiredHelperProtocolMaximum
        else {
            throw ReleaseCandidateValidationError.invalidHelperProtocol
        }
        guard automationProtocol == nil else {
            throw ReleaseCandidateValidationError.automationProtocolMustBeAbsent
        }
        guard publicContractResource == Self.requiredPublicContractResource else {
            throw ReleaseCandidateValidationError.invalidPublicContractResource
        }
        guard knownLimitationsResource == Self.requiredKnownLimitationsResource else {
            throw ReleaseCandidateValidationError.invalidKnownLimitationsResource
        }
    }

    var publicContractShortSHA256: String {
        Self.shortDigest(publicContractSHA256)
    }

    var architectureFreezeShortSHA256: String {
        Self.shortDigest(architectureFreezeSHA256)
    }

    private static func shortDigest(_ digest: String) -> String {
        String(digest.prefix(12)) + "…"
    }
}

nonisolated struct KnownLimitationsManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumEncodedBytes = 256 * 1_024
    static let maximumLimitationCount = 64

    let schemaVersion: Int
    let version: String
    let limitations: [KnownLimitation]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, version, limitations
    }

    init(schemaVersion: Int, version: String, limitations: [KnownLimitation]) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.limitations = limitations
    }

    init(from decoder: any Decoder) throws {
        try decoder.rejectReleaseCandidateUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        version = try container.decode(String.self, forKey: .version)
        limitations = try container.decode([KnownLimitation].self, forKey: .limitations)
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ReleaseCandidateValidationError.unsupportedKnownLimitationsSchema(
                schemaVersion
            )
        }
        try ReleaseCandidateTextPolicy.validateVersion(version, label: "version")
        guard !limitations.isEmpty, limitations.count <= Self.maximumLimitationCount else {
            throw ReleaseCandidateValidationError.invalidKnownLimitationCount
        }
        guard Set(limitations.map(\.id)).count == limitations.count else {
            throw ReleaseCandidateValidationError.duplicateKnownLimitationID
        }
        for limitation in limitations {
            try limitation.validate()
        }
    }
}

nonisolated struct KnownLimitation: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let severity: KnownLimitationSeverity
    let title: String
    let description: String
    let impact: KnownLimitationImpact
    let workaround: String?
    let helpTopicID: String
    let owner: String
    let targetVersion: String?
    let stopShip: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, severity, title, description, impact, workaround, helpTopicID, owner
        case targetVersion, stopShip
    }

    init(
        id: String,
        severity: KnownLimitationSeverity,
        title: String,
        description: String,
        impact: KnownLimitationImpact,
        workaround: String?,
        helpTopicID: String,
        owner: String,
        targetVersion: String?,
        stopShip: Bool
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.description = description
        self.impact = impact
        self.workaround = workaround
        self.helpTopicID = helpTopicID
        self.owner = owner
        self.targetVersion = targetVersion
        self.stopShip = stopShip
    }

    init(from decoder: any Decoder) throws {
        try decoder.rejectReleaseCandidateUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        severity = try container.decode(KnownLimitationSeverity.self, forKey: .severity)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        impact = try container.decode(KnownLimitationImpact.self, forKey: .impact)
        workaround = try container.decodeIfPresent(String.self, forKey: .workaround)
        helpTopicID = try container.decode(String.self, forKey: .helpTopicID)
        owner = try container.decode(String.self, forKey: .owner)
        targetVersion = try container.decodeIfPresent(String.self, forKey: .targetVersion)
        stopShip = try container.decode(Bool.self, forKey: .stopShip)
    }

    func validate() throws {
        try ReleaseCandidateTextPolicy.validateIdentifier(id, label: "limitation.id")
        try ReleaseCandidateTextPolicy.validateText(
            title,
            label: "limitation.title",
            maximumUTF8Bytes: 200
        )
        try ReleaseCandidateTextPolicy.validateText(
            description,
            label: "limitation.description",
            maximumUTF8Bytes: 2_048
        )
        if let workaround {
            try ReleaseCandidateTextPolicy.validateText(
                workaround,
                label: "limitation.workaround",
                maximumUTF8Bytes: 2_048
            )
        }
        try ReleaseCandidateTextPolicy.validateIdentifier(
            helpTopicID,
            label: "limitation.helpTopicID"
        )
        try ReleaseCandidateTextPolicy.validateText(
            owner,
            label: "limitation.owner",
            maximumUTF8Bytes: 160
        )
        if let targetVersion {
            try ReleaseCandidateTextPolicy.validateVersion(
                targetVersion,
                label: "limitation.targetVersion"
            )
        }
        guard !stopShip else {
            throw ReleaseCandidateValidationError.stopShipCannotBeKnownLimitation(id)
        }
        let impactLevels = [impact.security, impact.data, impact.network]
        guard !impactLevels.contains(.material) else {
            throw ReleaseCandidateValidationError.materialImpactMustRemainStopShip(id)
        }
        if severity == .medium, workaround == nil || targetVersion == nil {
            throw ReleaseCandidateValidationError.mediumLimitationRequiresMitigation(id)
        }
        if impactLevels.contains(where: { $0 != .none }), workaround == nil {
            throw ReleaseCandidateValidationError.impactRequiresWorkaround(id)
        }
    }
}

nonisolated enum KnownLimitationSeverity: String, Codable, CaseIterable, Sendable {
    case informational
    case low
    case medium
}

nonisolated struct KnownLimitationImpact: Codable, Equatable, Sendable {
    let security: KnownLimitationImpactLevel
    let data: KnownLimitationImpactLevel
    let network: KnownLimitationImpactLevel

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case security, data, network
    }

    init(
        security: KnownLimitationImpactLevel,
        data: KnownLimitationImpactLevel,
        network: KnownLimitationImpactLevel
    ) {
        self.security = security
        self.data = data
        self.network = network
    }

    init(from decoder: any Decoder) throws {
        try decoder.rejectReleaseCandidateUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        security = try container.decode(KnownLimitationImpactLevel.self, forKey: .security)
        data = try container.decode(KnownLimitationImpactLevel.self, forKey: .data)
        network = try container.decode(KnownLimitationImpactLevel.self, forKey: .network)
    }
}

nonisolated enum KnownLimitationImpactLevel: String, Codable, CaseIterable, Sendable {
    case none
    case limited
    case material
}

nonisolated struct ReleaseCandidateResources: Equatable, Sendable {
    let baseline: ReleaseCandidateBaseline
    let publicContract: Data
    let knownLimitations: KnownLimitationsManifest
}

nonisolated struct ReleaseCandidateBundleIdentity: Equatable, Sendable {
    let marketingVersion: String
    let prereleaseLabel: String
    let buildChannel: ReleaseChannel

    func releaseEvidenceAvailability(
        hasValidatedBuildManifest: Bool
    ) -> ReleaseCandidateReleaseEvidenceAvailability {
        guard hasValidatedBuildManifest else { return .unavailable }
        switch (buildChannel, prereleaseLabel) {
        case (.stable, ""):
            return .externalVerificationRequired
        case (.beta, let label)
        where label.range(of: #"^RC [1-9][0-9]*$"#, options: .regularExpression) != nil:
            return .externalVerificationRequired
        default:
            return .unavailable
        }
    }

    init(infoDictionary: [String: Any]) throws {
        guard let marketingVersion = infoDictionary["CFBundleShortVersionString"] as? String else {
            throw ReleaseCandidateBundleIdentityError.missingMarketingVersion
        }
        guard let prereleaseLabel = infoDictionary["VelaPrereleaseLabel"] as? String else {
            throw ReleaseCandidateBundleIdentityError.missingPrereleaseLabel
        }
        guard let releaseChannel = infoDictionary["VelaReleaseChannel"] as? String else {
            throw ReleaseCandidateBundleIdentityError.missingBuildChannel
        }
        guard let buildChannel = ReleaseChannel(rawValue: releaseChannel) else {
            throw ReleaseCandidateBundleIdentityError.invalidBuildChannel
        }
        do {
            try ReleaseCandidateTextPolicy.validateVersion(
                marketingVersion,
                label: "CFBundleShortVersionString"
            )
        } catch {
            throw ReleaseCandidateBundleIdentityError.invalidMarketingVersion
        }
        if !prereleaseLabel.isEmpty {
            do {
                try ReleaseCandidateTextPolicy.validateText(
                    prereleaseLabel,
                    label: "VelaPrereleaseLabel",
                    maximumUTF8Bytes: 80
                )
            } catch {
                throw ReleaseCandidateBundleIdentityError.invalidPrereleaseLabel
            }
        }
        self.marketingVersion = marketingVersion
        self.prereleaseLabel = prereleaseLabel
        self.buildChannel = buildChannel
    }

    init(bundle: Bundle) throws {
        try self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }
}

nonisolated enum ReleaseCandidateBundleIdentityError: Error, Equatable, Sendable {
    case missingMarketingVersion
    case invalidMarketingVersion
    case missingPrereleaseLabel
    case invalidPrereleaseLabel
    case missingBuildChannel
    case invalidBuildChannel
}

nonisolated enum ReleaseCandidateReleaseEvidenceAvailability: Equatable, Sendable {
    case externalVerificationRequired
    case unavailable
}

nonisolated enum ReleaseCandidateValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case unsupportedKnownLimitationsSchema(Int)
    case invalidText(String)
    case invalidIdentifier(String)
    case invalidVersion(String)
    case invalidSHA256(String)
    case invalidPlatform
    case invalidComponents
    case invalidMarketingVersion
    case invalidDataSchemaVersion
    case invalidHelperProtocol
    case automationProtocolMustBeAbsent
    case invalidPublicContractResource
    case invalidKnownLimitationsResource
    case invalidKnownLimitationCount
    case duplicateKnownLimitationID
    case stopShipCannotBeKnownLimitation(String)
    case materialImpactMustRemainStopShip(String)
    case mediumLimitationRequiresMitigation(String)
    case impactRequiresWorkaround(String)
}

nonisolated private enum ReleaseCandidateTextPolicy {
    static func validateText(
        _ value: String,
        label: String,
        maximumUTF8Bytes: Int
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.utf8.count <= maximumUTF8Bytes,
            !containsForbiddenScalar(value)
        else {
            throw ReleaseCandidateValidationError.invalidText(label)
        }
    }

    static func validateIdentifier(_ value: String, label: String) throws {
        guard !value.isEmpty, value.utf8.count <= 96,
            value.unicodeScalars.allSatisfy({ scalar in
                (scalar.value >= 97 && scalar.value <= 122)
                    || (scalar.value >= 48 && scalar.value <= 57)
                    || scalar.value == 45
            }),
            value.first != "-", value.last != "-"
        else {
            throw ReleaseCandidateValidationError.invalidIdentifier(label)
        }
    }

    static func validateVersion(_ value: String, label: String) throws {
        guard !value.isEmpty, value.utf8.count <= 80,
            value.unicodeScalars.allSatisfy({ scalar in
                (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
                    || (scalar.value >= 48 && scalar.value <= 57)
                    || scalar.value == 45
                    || scalar.value == 46
                    || scalar.value == 43
            })
        else {
            throw ReleaseCandidateValidationError.invalidVersion(label)
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private static func containsForbiddenScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            let code = scalar.value
            let control = (code < 0x20 && code != 0x09 && code != 0x0A && code != 0x0D)
                || code == 0x7F
            let bidi = code == 0x061C || code == 0x200E || code == 0x200F
                || (0x202A...0x202E).contains(code)
                || (0x2066...0x2069).contains(code)
            return control || bidi
        }
    }
}

nonisolated private struct ReleaseCandidateAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

nonisolated private extension Decoder {
    func rejectReleaseCandidateUnknownKeys<Key>(_ keyType: Key.Type) throws
    where Key: CodingKey & CaseIterable, Key.AllCases: Sequence {
        let container = try container(keyedBy: ReleaseCandidateAnyCodingKey.self)
        let allowed = Set(keyType.allCases.map(\.stringValue))
        let unknown = container.allKeys
            .map(\.stringValue)
            .filter { !allowed.contains($0) }
            .sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Unknown keys: \(unknown.joined(separator: ", "))"
                )
            )
        }
    }
}
