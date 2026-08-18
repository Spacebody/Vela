import Foundation

nonisolated enum ProfileSourceKind: String, Codable, Equatable, Sendable {
    case localFile
    case remoteSubscription
}

nonisolated enum SubscriptionSchedule: Equatable, Sendable {
    case hourly
    case everySixHours
    case everyTwelveHours
    case daily
    case custom(minutes: Int)

    var minutes: Int {
        switch self {
        case .hourly:
            60
        case .everySixHours:
            6 * 60
        case .everyTwelveHours:
            12 * 60
        case .daily:
            24 * 60
        case let .custom(minutes):
            minutes
        }
    }
}

extension SubscriptionSchedule: Codable {
    private enum Kind: String, Codable {
        case hourly
        case everySixHours
        case everyTwelveHours
        case daily
        case custom
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case minutes
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
            let value = try? single.decode(String.self),
            let kind = Kind(rawValue: value),
            kind != .custom
        {
            switch kind {
            case .hourly:
                self = .hourly
            case .everySixHours:
                self = .everySixHours
            case .everyTwelveHours:
                self = .everyTwelveHours
            case .daily:
                self = .daily
            case .custom:
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Custom schedules require a minute value."
                )
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        self = switch kind {
        case .hourly: .hourly
        case .everySixHours: .everySixHours
        case .everyTwelveHours: .everyTwelveHours
        case .daily: .daily
        case .custom:
            .custom(minutes: try container.decode(Int.self, forKey: .minutes))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hourly:
            try container.encode(Kind.hourly, forKey: .kind)
        case .everySixHours:
            try container.encode(Kind.everySixHours, forKey: .kind)
        case .everyTwelveHours:
            try container.encode(Kind.everyTwelveHours, forKey: .kind)
        case .daily:
            try container.encode(Kind.daily, forKey: .kind)
        case let .custom(minutes):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(minutes, forKey: .minutes)
        }
    }
}

nonisolated struct SubscriptionUsage: Codable, Equatable, Sendable {
    var upload: Int64?
    var download: Int64?
    var total: Int64?
    var expireUnixSeconds: Int64?

    init(
        upload: Int64? = nil,
        download: Int64? = nil,
        total: Int64? = nil,
        expireUnixSeconds: Int64? = nil
    ) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expireUnixSeconds = expireUnixSeconds
    }
}

nonisolated struct PersistedFailureSummary: Codable, Equatable, Sendable {
    var kind: String
    var message: String
    var occurredAt: Date
    /// Persists retry progression across app launches without storing any
    /// request URL, credentials, or response content.
    var consecutiveCount: Int?

    init(
        kind: String,
        message: String,
        occurredAt: Date,
        consecutiveCount: Int? = nil
    ) {
        self.kind = kind
        self.message = message
        self.occurredAt = occurredAt
        self.consecutiveCount = consecutiveCount
    }
}

nonisolated struct RemoteProfileMetadata: Codable, Equatable, Sendable {
    var redactedURL: String
    var autoUpdateEnabled: Bool
    var schedule: SubscriptionSchedule
    var etag: String?
    var lastModified: String?
    var lastCheckedAt: Date?
    var lastSuccessfulUpdateAt: Date?
    var nextScheduledUpdateAt: Date?
    var contentSHA256: String?
    var lastHTTPStatus: Int?
    var usage: SubscriptionUsage?
    var suggestedFileName: String?
    var suggestedUpdateIntervalMinutes: Int?
    var profileWebPageURL: URL?
    var lastFailure: PersistedFailureSummary?
    var originalFormat: SubscriptionContentFormat?
    var convertedLocally: Bool?
    var lastConvertedNodeCount: Int?
    var lastRejectedItemCount: Int?
    var lastConversionWarnings: [StoredConversionWarning]?

    init(
        redactedURL: String,
        autoUpdateEnabled: Bool = false,
        schedule: SubscriptionSchedule = .daily,
        etag: String? = nil,
        lastModified: String? = nil,
        lastCheckedAt: Date? = nil,
        lastSuccessfulUpdateAt: Date? = nil,
        nextScheduledUpdateAt: Date? = nil,
        contentSHA256: String? = nil,
        lastHTTPStatus: Int? = nil,
        usage: SubscriptionUsage? = nil,
        suggestedFileName: String? = nil,
        suggestedUpdateIntervalMinutes: Int? = nil,
        profileWebPageURL: URL? = nil,
        lastFailure: PersistedFailureSummary? = nil,
        originalFormat: SubscriptionContentFormat? = nil,
        convertedLocally: Bool? = nil,
        lastConvertedNodeCount: Int? = nil,
        lastRejectedItemCount: Int? = nil,
        lastConversionWarnings: [StoredConversionWarning]? = nil
    ) {
        self.redactedURL = redactedURL
        self.autoUpdateEnabled = autoUpdateEnabled
        self.schedule = schedule
        self.etag = etag
        self.lastModified = lastModified
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessfulUpdateAt = lastSuccessfulUpdateAt
        self.nextScheduledUpdateAt = nextScheduledUpdateAt
        self.contentSHA256 = contentSHA256
        self.lastHTTPStatus = lastHTTPStatus
        self.usage = usage
        self.suggestedFileName = suggestedFileName
        self.suggestedUpdateIntervalMinutes = suggestedUpdateIntervalMinutes
        self.profileWebPageURL = profileWebPageURL
        self.lastFailure = lastFailure
        self.originalFormat = originalFormat
        self.convertedLocally = convertedLocally
        self.lastConvertedNodeCount = lastConvertedNodeCount
        self.lastRejectedItemCount = lastRejectedItemCount
        self.lastConversionWarnings = lastConversionWarnings
    }
}

nonisolated struct ProfileRevision: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let contentSHA256: String
    let sourceFileName: String
    let byteCount: Int

    init(
        id: UUID,
        createdAt: Date,
        contentSHA256: String,
        sourceFileName: String,
        byteCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.contentSHA256 = contentSHA256
        self.sourceFileName = sourceFileName
        self.byteCount = byteCount
    }
}

/// A lossless JSON value used only for metadata fields unknown to this Vela build.
/// Keeping these values prevents a migration or later profile save from erasing
/// metadata written by a newer or older compatible build.
nonisolated indirect enum ProfileMetadataValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case floatingPoint(Double)
    case string(String)
    case array([ProfileMetadataValue])
    case object([String: ProfileMetadataValue])

    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var values: [ProfileMetadataValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(ProfileMetadataValue.self))
            }
            self = .array(values)
            return
        }

        if let container = try? decoder.container(keyedBy: ProfileCodingKey.self) {
            var values: [String: ProfileMetadataValue] = [:]
            for key in container.allKeys {
                values[key.stringValue] = try container.decode(
                    ProfileMetadataValue.self,
                    forKey: key
                )
            }
            self = .object(values)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .floatingPoint(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .integer(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .floatingPoint(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case let .object(values):
            var container = encoder.container(keyedBy: ProfileCodingKey.self)
            for key in values.keys.sorted() {
                try container.encode(values[key], forKey: ProfileCodingKey(key))
            }
        }
    }
}

nonisolated struct Profile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let originalFileName: String
    let createdAt: Date
    var updatedAt: Date
    var sourceKind: ProfileSourceKind
    var currentRevisionID: UUID?
    var previousRevisionIDs: [UUID]
    var revisions: [ProfileRevision]
    var remote: RemoteProfileMetadata?
    var overrideReference: String?
    var additionalMetadata: [String: ProfileMetadataValue]

    var configurationFileName: String {
        "\(id.uuidString).yaml"
    }

    init(
        id: UUID,
        name: String,
        originalFileName: String,
        createdAt: Date,
        updatedAt: Date,
        sourceKind: ProfileSourceKind = .localFile,
        currentRevisionID: UUID? = nil,
        previousRevisionIDs: [UUID] = [],
        revisions: [ProfileRevision] = [],
        remote: RemoteProfileMetadata? = nil,
        overrideReference: String? = nil,
        additionalMetadata: [String: ProfileMetadataValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.originalFileName = originalFileName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceKind = sourceKind
        self.currentRevisionID = currentRevisionID
        self.previousRevisionIDs = previousRevisionIDs
        self.revisions = revisions
        self.remote = remote
        self.overrideReference = overrideReference
        self.additionalMetadata = additionalMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProfileCodingKey.self)
        id = try container.decode(UUID.self, forKey: ProfileCodingKey("id"))
        name = try Self.decodeRequiredAlias(
            String.self,
            primary: "displayName",
            legacy: "name",
            from: container
        )
        originalFileName = try Self.decodeRequiredAlias(
            String.self,
            primary: "sourceFileName",
            legacy: "originalFileName",
            from: container
        )
        createdAt = try container.decode(Date.self, forKey: ProfileCodingKey("createdAt"))
        updatedAt = try container.decode(Date.self, forKey: ProfileCodingKey("updatedAt"))
        sourceKind = try container.decodeIfPresent(
            ProfileSourceKind.self,
            forKey: ProfileCodingKey("sourceKind")
        ) ?? .localFile
        currentRevisionID = try container.decodeIfPresent(
            UUID.self,
            forKey: ProfileCodingKey("currentRevisionID")
        )
        previousRevisionIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: ProfileCodingKey("previousRevisionIDs")
        ) ?? []
        revisions = try container.decodeIfPresent(
            [ProfileRevision].self,
            forKey: ProfileCodingKey("revisions")
        ) ?? []
        remote = try container.decodeIfPresent(
            RemoteProfileMetadata.self,
            forKey: ProfileCodingKey("remote")
        )
        overrideReference = try container.decodeIfPresent(
            String.self,
            forKey: ProfileCodingKey("overrideReference")
        )

        additionalMetadata = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            additionalMetadata[key.stringValue] = try container.decode(
                ProfileMetadataValue.self,
                forKey: key
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ProfileCodingKey.self)
        for key in additionalMetadata.keys.sorted() where !Self.knownKeys.contains(key) {
            try container.encode(additionalMetadata[key], forKey: ProfileCodingKey(key))
        }
        try container.encode(id, forKey: ProfileCodingKey("id"))
        try container.encode(name, forKey: ProfileCodingKey("displayName"))
        try container.encode(originalFileName, forKey: ProfileCodingKey("sourceFileName"))
        try container.encode(createdAt, forKey: ProfileCodingKey("createdAt"))
        try container.encode(updatedAt, forKey: ProfileCodingKey("updatedAt"))
        try container.encode(sourceKind, forKey: ProfileCodingKey("sourceKind"))
        try container.encodeIfPresent(
            currentRevisionID,
            forKey: ProfileCodingKey("currentRevisionID")
        )
        try container.encode(
            previousRevisionIDs,
            forKey: ProfileCodingKey("previousRevisionIDs")
        )
        try container.encode(revisions, forKey: ProfileCodingKey("revisions"))
        try container.encodeIfPresent(remote, forKey: ProfileCodingKey("remote"))
        try container.encodeIfPresent(
            overrideReference,
            forKey: ProfileCodingKey("overrideReference")
        )
    }

    private static let knownKeys: Set<String> = [
        "id",
        "displayName",
        "name",
        "sourceFileName",
        "originalFileName",
        "createdAt",
        "updatedAt",
        "sourceKind",
        "currentRevisionID",
        "previousRevisionIDs",
        "revisions",
        "remote",
        "overrideReference",
    ]

    private static func decodeRequiredAlias<Value: Decodable>(
        _ type: Value.Type,
        primary: String,
        legacy: String,
        from container: KeyedDecodingContainer<ProfileCodingKey>
    ) throws -> Value {
        if let value = try container.decodeIfPresent(type, forKey: ProfileCodingKey(primary)) {
            return value
        }
        return try container.decode(type, forKey: ProfileCodingKey(legacy))
    }
}

nonisolated struct ProfileDatabaseEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    var profiles: [Profile]
    var selectedProfileID: UUID?
    var additionalMetadata: [String: ProfileMetadataValue]

    init(
        schemaVersion: Int = currentSchemaVersion,
        profiles: [Profile] = [],
        selectedProfileID: UUID? = nil,
        additionalMetadata: [String: ProfileMetadataValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.additionalMetadata = additionalMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProfileCodingKey.self)
        schemaVersion = try container.decode(Int.self, forKey: ProfileCodingKey("schemaVersion"))
        profiles = try container.decode([Profile].self, forKey: ProfileCodingKey("profiles"))
        selectedProfileID = try container.decodeIfPresent(
            UUID.self,
            forKey: ProfileCodingKey("selectedProfileID")
        )
        additionalMetadata = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            additionalMetadata[key.stringValue] = try container.decode(
                ProfileMetadataValue.self,
                forKey: key
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ProfileCodingKey.self)
        for key in additionalMetadata.keys.sorted() where !Self.knownKeys.contains(key) {
            try container.encode(additionalMetadata[key], forKey: ProfileCodingKey(key))
        }
        try container.encode(schemaVersion, forKey: ProfileCodingKey("schemaVersion"))
        try container.encode(profiles, forKey: ProfileCodingKey("profiles"))
        try container.encodeIfPresent(
            selectedProfileID,
            forKey: ProfileCodingKey("selectedProfileID")
        )
    }

    private static let knownKeys: Set<String> = [
        "schemaVersion",
        "profiles",
        "selectedProfileID",
    ]
}

nonisolated private struct ProfileCodingKey: CodingKey, Hashable, Sendable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
