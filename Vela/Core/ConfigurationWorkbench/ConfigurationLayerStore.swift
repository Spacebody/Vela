import Foundation

nonisolated struct ConfigurationLayerRecord: Codable, Equatable, Identifiable, Sendable {
    let ownerID: UUID?
    var layer: ConfigurationLayer

    var id: UUID { layer.id }

    init(ownerID: UUID?, layer: ConfigurationLayer) {
        self.ownerID = ownerID
        self.layer = layer
    }
}

nonisolated struct LegacyOverrideMigrationRecord: Codable, Equatable, Sendable {
    let profileID: UUID
    let layerID: UUID
    let sourceSHA256: String
    let backupFileName: String
    let unknownTopLevelKeys: [String]
    let unknownFieldPointers: [String]

    init(
        profileID: UUID,
        layerID: UUID,
        sourceSHA256: String,
        backupFileName: String,
        unknownTopLevelKeys: [String],
        unknownFieldPointers: [String] = []
    ) {
        self.profileID = profileID
        self.layerID = layerID
        self.sourceSHA256 = sourceSHA256
        self.backupFileName = backupFileName
        self.unknownTopLevelKeys = unknownTopLevelKeys
        self.unknownFieldPointers = unknownFieldPointers
    }

    private enum CodingKeys: String, CodingKey {
        case profileID
        case layerID
        case sourceSHA256
        case backupFileName
        case unknownTopLevelKeys
        case unknownFieldPointers
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        layerID = try container.decode(UUID.self, forKey: .layerID)
        sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
        backupFileName = try container.decode(String.self, forKey: .backupFileName)
        unknownTopLevelKeys = try container.decodeIfPresent(
            [String].self,
            forKey: .unknownTopLevelKeys
        ) ?? []
        unknownFieldPointers = try container.decodeIfPresent(
            [String].self,
            forKey: .unknownFieldPointers
        ) ?? unknownTopLevelKeys.map {
            YAMLPointer(components: [$0]).rawValue
        }
    }
}

nonisolated struct ConfigurationLayerStoreDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var layers: [ConfigurationLayerRecord]
    var legacyOverrideMigrations: [LegacyOverrideMigrationRecord]

    init(
        schemaVersion: Int = currentSchemaVersion,
        layers: [ConfigurationLayerRecord] = [],
        legacyOverrideMigrations: [LegacyOverrideMigrationRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.layers = layers
        self.legacyOverrideMigrations = legacyOverrideMigrations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case layers
        case legacyOverrideMigrations
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        layers = try container.decodeIfPresent(
            [ConfigurationLayerRecord].self,
            forKey: .layers
        ) ?? []
        legacyOverrideMigrations = try container.decodeIfPresent(
            [LegacyOverrideMigrationRecord].self,
            forKey: .legacyOverrideMigrations
        ) ?? []
    }
}

nonisolated enum ConfigurationLayerStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidLayerSchemaVersion(Int)
    case invalidLayerName
    case invalidLayerRevision(Int)
    case nonEditableLayerKind(ConfigurationLayerKind)
    case ownerRequired(ConfigurationLayerKind)
    case ownerForbidden(ConfigurationLayerKind)
    case duplicateLayerID(UUID)
    case duplicateLayerSlot(kind: ConfigurationLayerKind, ownerID: UUID?)
    case duplicateOperationID(UUID)
    case invalidLayer(layerID: UUID, reason: String)
    case layerIdentityMismatch(expected: UUID, actual: UUID)
    case layerTooLarge(UUID)
    case migrationConflict(UUID)
    case readFailed
    case decodeFailed
    case candidateVerificationFailed
    case writeFailed
    case rollbackFailed
}

actor ConfigurationLayerStore {
    private static let privateDirectoryPermissions = 0o700
    private static let privateFilePermissions = 0o600
    private static let maximumLayerBytes = 1 * 1_024 * 1_024

    private let directories: ApplicationDirectories
    private let fileSystem: any FileSystemProviding
    private let now: @Sendable () -> Date

    init(
        directories: ApplicationDirectories,
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.directories = directories
        self.fileSystem = fileSystem
        self.now = now
    }

    func snapshot() throws -> ConfigurationLayerStoreDocument {
        try loadDocument()
    }

    func layer(
        kind: ConfigurationLayerKind,
        ownerID: UUID? = nil
    ) throws -> ConfigurationLayer? {
        try loadDocument().layers.first {
            $0.layer.kind == kind && $0.ownerID == ownerID
        }?.layer
    }

    /// Returns only enabled committed layers in compiler precedence order.
    /// Drafts are intentionally not persisted in this store.
    func layers(profileID: UUID?, sceneID: UUID?) throws -> [ConfigurationLayer] {
        let document = try loadDocument()
        return document.layers.compactMap { record -> ConfigurationLayer? in
            guard record.layer.enabled else { return nil }
            switch record.layer.kind {
            case .global:
                return record.ownerID == nil ? record.layer : nil
            case .profile:
                return profileID == record.ownerID ? record.layer : nil
            case .scene:
                return sceneID == record.ownerID ? record.layer : nil
            case .runtimeForced, .privilegedSanitizer:
                return nil
            }
        }.sorted(by: Self.layerPrecedes)
    }

    @discardableResult
    func save(
        _ draft: ConfigurationLayer,
        ownerID: UUID? = nil
    ) throws -> ConfigurationLayer {
        var document = try loadDocument()
        let existingIndex = document.layers.firstIndex {
            $0.layer.kind == draft.kind && $0.ownerID == ownerID
        }
        let timestamp = now()
        let committed: ConfigurationLayer

        if let existingIndex {
            let existing = document.layers[existingIndex].layer
            guard existing.id == draft.id else {
                throw ConfigurationLayerStoreError.layerIdentityMismatch(
                    expected: existing.id,
                    actual: draft.id
                )
            }
            committed = ConfigurationLayer(
                id: existing.id,
                schemaVersion: draft.schemaVersion,
                revision: existing.revision + 1,
                name: draft.name,
                kind: draft.kind,
                enabled: draft.enabled,
                operations: draft.operations,
                createdAt: existing.createdAt,
                updatedAt: timestamp
            )
            document.layers[existingIndex] = ConfigurationLayerRecord(
                ownerID: ownerID,
                layer: committed
            )
        } else {
            committed = ConfigurationLayer(
                id: draft.id,
                schemaVersion: draft.schemaVersion,
                revision: 1,
                name: draft.name,
                kind: draft.kind,
                enabled: draft.enabled,
                operations: draft.operations,
                createdAt: draft.createdAt,
                updatedAt: timestamp
            )
            document.layers.append(
                ConfigurationLayerRecord(ownerID: ownerID, layer: committed)
            )
        }

        try persist(document)
        return committed
    }

    @discardableResult
    func remove(
        kind: ConfigurationLayerKind,
        ownerID: UUID? = nil
    ) throws -> ConfigurationLayer? {
        var document = try loadDocument()
        guard let index = document.layers.firstIndex(where: {
            $0.layer.kind == kind && $0.ownerID == ownerID
        }) else {
            return nil
        }
        let removed = document.layers.remove(at: index).layer
        try persist(document)
        return removed
    }

    /// Commits all legacy profile layers and their migration evidence in one
    /// layers.json replacement. Existing user layers are never overwritten.
    @discardableResult
    func commitLegacyMigration(
        layers migratedLayers: [ConfigurationLayerRecord],
        records migrationRecords: [LegacyOverrideMigrationRecord]
    ) throws -> ConfigurationLayerStoreDocument {
        guard migratedLayers.count == migrationRecords.count else {
            throw ConfigurationLayerStoreError.writeFailed
        }

        var document = try loadDocument()
        var changed = false
        for (migratedLayer, migrationRecord) in zip(migratedLayers, migrationRecords) {
            guard migratedLayer.layer.kind == .profile,
                migratedLayer.ownerID == migrationRecord.profileID,
                migratedLayer.layer.id == migrationRecord.layerID
            else {
                throw ConfigurationLayerStoreError.migrationConflict(
                    migrationRecord.profileID
                )
            }

            if let existingMigration = document.legacyOverrideMigrations.first(where: {
                $0.profileID == migrationRecord.profileID
            }) {
                let existingLayer = document.layers.first(where: {
                    $0.layer.kind == .profile && $0.ownerID == migrationRecord.profileID
                })
                guard existingMigration == migrationRecord,
                    existingLayer == migratedLayer
                else {
                    throw ConfigurationLayerStoreError.migrationConflict(
                        migrationRecord.profileID
                    )
                }
                continue
            }

            guard document.layers.allSatisfy({
                !($0.layer.kind == .profile && $0.ownerID == migrationRecord.profileID)
            }) else {
                throw ConfigurationLayerStoreError.migrationConflict(
                    migrationRecord.profileID
                )
            }

            document.layers.append(migratedLayer)
            document.legacyOverrideMigrations.append(migrationRecord)
            changed = true
        }

        if changed {
            try persist(document)
        }
        return try normalized(document)
    }

    private func loadDocument() throws -> ConfigurationLayerStoreDocument {
        do {
            try directories.prepare(fileSystem: fileSystem)
        } catch {
            throw ConfigurationLayerStoreError.readFailed
        }
        guard fileSystem.fileExists(at: directories.configurationLayers) else {
            return ConfigurationLayerStoreDocument()
        }

        let data: Data
        do {
            data = try fileSystem.readData(at: directories.configurationLayers)
        } catch {
            throw ConfigurationLayerStoreError.readFailed
        }
        do {
            let document = try JSONDecoder().decode(
                ConfigurationLayerStoreDocument.self,
                from: data
            )
            try validate(document)
            return try normalized(document)
        } catch let error as ConfigurationLayerStoreError {
            throw error
        } catch {
            throw ConfigurationLayerStoreError.decodeFailed
        }
    }

    private func persist(_ document: ConfigurationLayerStoreDocument) throws {
        let document = try normalized(document)
        try validate(document)
        let data = try encoded(document)
        let operationID = UUID()
        let candidateURL = directories.configurationLayerCandidateURL(
            operationID: operationID
        )
        let destinationURL = directories.configurationLayers
        let previousData: Data?

        do {
            try directories.prepare(fileSystem: fileSystem)
            previousData = fileSystem.fileExists(at: destinationURL)
                ? try fileSystem.readData(at: destinationURL)
                : nil
            try writePrivate(data, to: candidateURL)
            let verifiedData = try fileSystem.readData(at: candidateURL)
            guard verifiedData == data else {
                throw ConfigurationLayerStoreError.candidateVerificationFailed
            }
            let verified = try JSONDecoder().decode(
                ConfigurationLayerStoreDocument.self,
                from: verifiedData
            )
            try validate(verified)
            guard try normalized(verified) == document else {
                throw ConfigurationLayerStoreError.candidateVerificationFailed
            }
        } catch let error as ConfigurationLayerStoreError {
            if fileSystem.fileExists(at: candidateURL) {
                try? fileSystem.removeItem(at: candidateURL)
            }
            throw error
        } catch {
            if fileSystem.fileExists(at: candidateURL) {
                try? fileSystem.removeItem(at: candidateURL)
            }
            throw ConfigurationLayerStoreError.writeFailed
        }

        defer {
            if fileSystem.fileExists(at: candidateURL) {
                try? fileSystem.removeItem(at: candidateURL)
            }
        }
        do {
            try fileSystem.writeDataAtomically(data, to: destinationURL)
            try fileSystem.setPOSIXPermissions(
                Self.privateFilePermissions,
                at: destinationURL
            )
            let committedData = try fileSystem.readData(at: destinationURL)
            guard committedData == data else {
                throw ConfigurationLayerStoreError.candidateVerificationFailed
            }
            let committed = try JSONDecoder().decode(
                ConfigurationLayerStoreDocument.self,
                from: committedData
            )
            try validate(committed)
            guard try normalized(committed) == document else {
                throw ConfigurationLayerStoreError.candidateVerificationFailed
            }
        } catch {
            do {
                if let previousData {
                    try fileSystem.writeDataAtomically(previousData, to: destinationURL)
                    try fileSystem.setPOSIXPermissions(
                        Self.privateFilePermissions,
                        at: destinationURL
                    )
                    guard try fileSystem.readData(at: destinationURL) == previousData else {
                        throw ConfigurationLayerStoreError.rollbackFailed
                    }
                } else if fileSystem.fileExists(at: destinationURL) {
                    try fileSystem.removeItem(at: destinationURL)
                }
            } catch {
                throw ConfigurationLayerStoreError.rollbackFailed
            }
            if let error = error as? ConfigurationLayerStoreError {
                throw error
            }
            throw ConfigurationLayerStoreError.writeFailed
        }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileSystem.createDirectory(at: parent)
        try fileSystem.setPOSIXPermissions(Self.privateDirectoryPermissions, at: parent)
        try fileSystem.writeDataAtomically(data, to: url)
        try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: url)
    }

    private func encoded(_ document: ConfigurationLayerStoreDocument) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(document)
        } catch {
            throw ConfigurationLayerStoreError.writeFailed
        }
    }

    private func normalized(
        _ document: ConfigurationLayerStoreDocument
    ) throws -> ConfigurationLayerStoreDocument {
        ConfigurationLayerStoreDocument(
            schemaVersion: document.schemaVersion,
            layers: document.layers.sorted { lhs, rhs in
                if lhs.layer.kind.precedence != rhs.layer.kind.precedence {
                    return lhs.layer.kind.precedence < rhs.layer.kind.precedence
                }
                let lhsOwner = lhs.ownerID?.uuidString ?? ""
                let rhsOwner = rhs.ownerID?.uuidString ?? ""
                if lhsOwner != rhsOwner { return lhsOwner < rhsOwner }
                return lhs.layer.id.uuidString < rhs.layer.id.uuidString
            },
            legacyOverrideMigrations: document.legacyOverrideMigrations.sorted {
                $0.profileID.uuidString < $1.profileID.uuidString
            }
        )
    }

    private func validate(_ document: ConfigurationLayerStoreDocument) throws {
        guard document.schemaVersion == ConfigurationLayerStoreDocument.currentSchemaVersion else {
            throw ConfigurationLayerStoreError.unsupportedSchemaVersion(
                document.schemaVersion
            )
        }

        var layerIDs = Set<UUID>()
        var slots = Set<String>()
        for record in document.layers {
            let layer = record.layer
            guard layer.schemaVersion == ConfigurationLayer.currentSchemaVersion else {
                throw ConfigurationLayerStoreError.invalidLayerSchemaVersion(
                    layer.schemaVersion
                )
            }
            guard layer.revision >= 1 else {
                throw ConfigurationLayerStoreError.invalidLayerRevision(layer.revision)
            }
            let trimmedName = layer.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, trimmedName.count <= 120 else {
                throw ConfigurationLayerStoreError.invalidLayerName
            }
            guard layer.kind.isUserEditable else {
                throw ConfigurationLayerStoreError.nonEditableLayerKind(layer.kind)
            }
            switch layer.kind {
            case .global:
                guard record.ownerID == nil else {
                    throw ConfigurationLayerStoreError.ownerForbidden(layer.kind)
                }
            case .profile, .scene:
                guard record.ownerID != nil else {
                    throw ConfigurationLayerStoreError.ownerRequired(layer.kind)
                }
            case .runtimeForced, .privilegedSanitizer:
                throw ConfigurationLayerStoreError.nonEditableLayerKind(layer.kind)
            }
            guard layerIDs.insert(layer.id).inserted else {
                throw ConfigurationLayerStoreError.duplicateLayerID(layer.id)
            }
            let slot = "\(layer.kind.rawValue):\(record.ownerID?.uuidString ?? "-")"
            guard slots.insert(slot).inserted else {
                throw ConfigurationLayerStoreError.duplicateLayerSlot(
                    kind: layer.kind,
                    ownerID: record.ownerID
                )
            }
            var operationIDs = Set<UUID>()
            for operation in layer.operations {
                guard operationIDs.insert(operation.id).inserted else {
                    throw ConfigurationLayerStoreError.duplicateOperationID(operation.id)
                }
            }
            do {
                _ = try PatchEngine().apply(
                    root: .mapping(OrderedYAMLMapping()),
                    profileRevisionID: nil,
                    layers: [layer],
                    context: ConfigurationBackendContext()
                )
            } catch {
                throw ConfigurationLayerStoreError.invalidLayer(
                    layerID: layer.id,
                    reason: error.localizedDescription
                )
            }
            let layerData = try encodedLayer(layer)
            guard layerData.count <= Self.maximumLayerBytes else {
                throw ConfigurationLayerStoreError.layerTooLarge(layer.id)
            }
        }

        var migratedProfileIDs = Set<UUID>()
        for record in document.legacyOverrideMigrations {
            guard migratedProfileIDs.insert(record.profileID).inserted else {
                throw ConfigurationLayerStoreError.migrationConflict(record.profileID)
            }
            guard document.layers.contains(where: {
                $0.ownerID == record.profileID
                    && $0.layer.kind == .profile
                    && $0.layer.id == record.layerID
            }) else {
                throw ConfigurationLayerStoreError.migrationConflict(record.profileID)
            }
        }
    }

    private func encodedLayer(_ layer: ConfigurationLayer) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(layer)
        } catch {
            throw ConfigurationLayerStoreError.writeFailed
        }
    }

    private nonisolated static func layerPrecedes(
        _ lhs: ConfigurationLayer,
        _ rhs: ConfigurationLayer
    ) -> Bool {
        if lhs.kind.precedence != rhs.kind.precedence {
            return lhs.kind.precedence < rhs.kind.precedence
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

extension ConfigurationLayerStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Unsupported configuration layer store schema version \(version)."
        case let .invalidLayerSchemaVersion(version):
            "Unsupported configuration layer schema version \(version)."
        case .invalidLayerName:
            "A configuration layer name must contain 1 to 120 characters."
        case let .invalidLayerRevision(revision):
            "A configuration layer revision must be positive; got \(revision)."
        case let .nonEditableLayerKind(kind):
            "The \(kind.rawValue) layer is runtime-owned and cannot be persisted."
        case let .ownerRequired(kind):
            "The \(kind.rawValue) layer requires an owner identifier."
        case let .ownerForbidden(kind):
            "The \(kind.rawValue) layer cannot have an owner identifier."
        case let .duplicateLayerID(id):
            "Configuration layer identifier \(id.uuidString) is duplicated."
        case let .duplicateLayerSlot(kind, ownerID):
            "A \(kind.rawValue) layer already exists for \(ownerID?.uuidString ?? "global")."
        case let .duplicateOperationID(id):
            "Configuration operation identifier \(id.uuidString) is duplicated."
        case let .invalidLayer(layerID, reason):
            "Configuration layer \(layerID.uuidString) is invalid: \(reason)"
        case let .layerIdentityMismatch(expected, actual):
            "Layer identity cannot change from \(expected.uuidString) to \(actual.uuidString)."
        case let .layerTooLarge(id):
            "Configuration layer \(id.uuidString) exceeds 1 MiB."
        case let .migrationConflict(profileID):
            "Legacy override migration conflicts with the layer for profile \(profileID.uuidString)."
        case .readFailed:
            "The configuration layer store could not be read."
        case .decodeFailed:
            "The configuration layer store is invalid."
        case .candidateVerificationFailed:
            "The staged configuration layer store failed verification."
        case .writeFailed:
            "The configuration layer store could not be saved."
        case .rollbackFailed:
            "The configuration layer store could not restore its previous data."
        }
    }
}
