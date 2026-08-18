import CryptoKit
import Foundation

nonisolated enum LegacyOverrideMigrationStatus: String, Codable, Equatable, Sendable {
    case migrated
    case alreadyMigrated
    case skippedNoOverride
}

nonisolated struct LegacyOverrideProfileMigrationResult: Codable, Equatable, Sendable {
    let profileID: UUID
    let status: LegacyOverrideMigrationStatus
    let layerID: UUID?
    let operationCount: Int
    let unknownTopLevelKeys: [String]
    let unknownFieldPointers: [String]
    let backupURL: URL?

    init(
        profileID: UUID,
        status: LegacyOverrideMigrationStatus,
        layerID: UUID?,
        operationCount: Int,
        unknownTopLevelKeys: [String],
        unknownFieldPointers: [String] = [],
        backupURL: URL?
    ) {
        self.profileID = profileID
        self.status = status
        self.layerID = layerID
        self.operationCount = operationCount
        self.unknownTopLevelKeys = unknownTopLevelKeys
        self.unknownFieldPointers = unknownFieldPointers
        self.backupURL = backupURL
    }

    private enum CodingKeys: String, CodingKey {
        case profileID
        case status
        case layerID
        case operationCount
        case unknownTopLevelKeys
        case unknownFieldPointers
        case backupURL
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        status = try container.decode(LegacyOverrideMigrationStatus.self, forKey: .status)
        layerID = try container.decodeIfPresent(UUID.self, forKey: .layerID)
        operationCount = try container.decode(Int.self, forKey: .operationCount)
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
        backupURL = try container.decodeIfPresent(URL.self, forKey: .backupURL)
    }
}

nonisolated struct LegacyOverrideMigrationReport: Codable, Equatable, Sendable {
    let results: [LegacyOverrideProfileMigrationResult]

    var migratedCount: Int {
        results.count { $0.status == .migrated }
    }

    var alreadyMigratedCount: Int {
        results.count { $0.status == .alreadyMigrated }
    }
}

nonisolated enum LegacyOverrideMigrationError: Error, Equatable, Sendable {
    case discoveryFailed
    case sourceReadFailed(UUID)
    case invalidTopLevelObject(UUID)
    case decodeFailed(UUID)
    case unsupportedSchemaVersion(profileID: UUID, version: Int)
    case validationFailed(UUID)
    case backupMismatch(UUID)
    case backupFailed(UUID)
    case sourceChangedAfterMigration(UUID)
    case migrationEvidenceCorrupt(UUID)
}

actor LegacyOverrideMigrator {
    private static let knownTopLevelKeys: Set<String> = [
        "schemaVersion", "dns", "sniffer", "prependedRules",
    ]
    private static let knownDNSKeys: Set<String> = [
        "enable",
        "ipv6",
        "enhanced-mode",
        "fake-ip-range",
        "fake-ip-filter-mode",
        "fake-ip-filter",
        "use-hosts",
        "use-system-hosts",
        "respect-rules",
        "default-nameserver",
        "nameserver",
        "fallback",
        "proxy-server-nameserver",
        "direct-nameserver",
        "direct-nameserver-follow-policy",
        "nameserver-policy",
    ]
    private static let knownSnifferKeys: Set<String> = [
        "enable",
        "force-dns-mapping",
        "parse-pure-ip",
        "override-destination",
        "sniff",
        "force-domain",
        "skip-domain",
        "skip-src-address",
        "skip-dst-address",
    ]
    private static let knownSniffProtocolKeys: Set<String> = [
        "HTTP", "TLS", "QUIC",
    ]
    private static let knownProtocolOverrideKeys: Set<String> = [
        "ports", "override-destination",
    ]
    private static let knownOverrideValueKeys: Set<String> = [
        "mode", "value",
    ]
    private static let knownNameserverPolicyEntryKeys: Set<String> = [
        "pattern", "servers",
    ]

    private let directories: ApplicationDirectories
    private let fileSystem: any FileSystemProviding
    private let layerStore: ConfigurationLayerStore

    init(
        directories: ApplicationDirectories,
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        layerStore: ConfigurationLayerStore
    ) {
        self.directories = directories
        self.fileSystem = fileSystem
        self.layerStore = layerStore
    }

    func migrateDiscoveredOverrides() async throws -> LegacyOverrideMigrationReport {
        let urls: [URL]
        do {
            try directories.prepare(fileSystem: fileSystem)
            urls = try fileSystem.contentsOfDirectory(at: directories.overrides)
        } catch {
            throw LegacyOverrideMigrationError.discoveryFailed
        }
        let profileIDs = urls.compactMap { url -> UUID? in
            guard url.pathExtension.lowercased() == "json",
                !url.lastPathComponent.hasPrefix(".")
            else {
                return nil
            }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }
        return try await migrate(profileIDs: profileIDs)
    }

    func migrate(profileIDs: [UUID]) async throws -> LegacyOverrideMigrationReport {
        let orderedProfileIDs = Array(Set(profileIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        let existing = try await layerStore.snapshot()
        var migratedLayers: [ConfigurationLayerRecord] = []
        var migrationRecords: [LegacyOverrideMigrationRecord] = []
        var results: [LegacyOverrideProfileMigrationResult] = []

        for profileID in orderedProfileIDs {
            let sourceURL = directories.overrideURL(for: profileID)
            guard fileSystem.fileExists(at: sourceURL) else {
                results.append(
                    LegacyOverrideProfileMigrationResult(
                        profileID: profileID,
                        status: .skippedNoOverride,
                        layerID: nil,
                        operationCount: 0,
                        unknownTopLevelKeys: [],
                        unknownFieldPointers: [],
                        backupURL: nil
                    )
                )
                continue
            }

            let sourceData: Data
            do {
                sourceData = try fileSystem.readData(at: sourceURL)
            } catch {
                throw LegacyOverrideMigrationError.sourceReadFailed(profileID)
            }
            let sourceSHA256 = Self.sha256(sourceData)

            if let record = existing.legacyOverrideMigrations.first(where: {
                $0.profileID == profileID
            }) {
                guard record.sourceSHA256 == sourceSHA256 else {
                    throw LegacyOverrideMigrationError.sourceChangedAfterMigration(profileID)
                }
                let unknownFields = try Self.unknownFields(
                    in: sourceData,
                    profileID: profileID
                )
                guard let layer = existing.layers.first(where: {
                    $0.ownerID == profileID
                        && $0.layer.kind == .profile
                        && $0.layer.id == record.layerID
                }) else {
                    throw LegacyOverrideMigrationError.migrationEvidenceCorrupt(profileID)
                }
                let backupURL = directories.legacyOverrideMigrationBackupURL(
                    for: profileID
                )
                try ensureBackup(sourceData, at: backupURL, profileID: profileID)
                results.append(
                    LegacyOverrideProfileMigrationResult(
                        profileID: profileID,
                        status: .alreadyMigrated,
                        layerID: record.layerID,
                        operationCount: layer.layer.operations.count,
                        unknownTopLevelKeys: unknownFields.topLevelKeys,
                        unknownFieldPointers: unknownFields.pointers,
                        backupURL: backupURL
                    )
                )
                continue
            }

            let unknownFields = try Self.unknownFields(
                in: sourceData,
                profileID: profileID
            )
            let overrides: ProfileStructuredOverrides
            do {
                overrides = try JSONDecoder().decode(
                    ProfileStructuredOverrides.self,
                    from: sourceData
                )
            } catch {
                throw LegacyOverrideMigrationError.decodeFailed(profileID)
            }
            guard overrides.schemaVersion == ProfileStructuredOverrides.currentSchemaVersion else {
                throw LegacyOverrideMigrationError.unsupportedSchemaVersion(
                    profileID: profileID,
                    version: overrides.schemaVersion
                )
            }
            let validator = ConfigurationOverrideValidator()
            let validation = validator.validate(overrides)
            guard validation.errors.isEmpty else {
                throw LegacyOverrideMigrationError.validationFailed(profileID)
            }
            let normalizedOverrides = validator.normalized(overrides)

            let backupURL = directories.legacyOverrideMigrationBackupURL(for: profileID)
            try ensureBackup(sourceData, at: backupURL, profileID: profileID)
            let layer = LegacyOverrideLayerMapper.makeLayer(
                profileID: profileID,
                overrides: normalizedOverrides
            )
            let migrationRecord = LegacyOverrideMigrationRecord(
                profileID: profileID,
                layerID: layer.id,
                sourceSHA256: sourceSHA256,
                backupFileName: backupURL.lastPathComponent,
                unknownTopLevelKeys: unknownFields.topLevelKeys,
                unknownFieldPointers: unknownFields.pointers
            )
            migratedLayers.append(
                ConfigurationLayerRecord(ownerID: profileID, layer: layer)
            )
            migrationRecords.append(migrationRecord)
            results.append(
                LegacyOverrideProfileMigrationResult(
                    profileID: profileID,
                    status: .migrated,
                    layerID: layer.id,
                    operationCount: layer.operations.count,
                    unknownTopLevelKeys: unknownFields.topLevelKeys,
                    unknownFieldPointers: unknownFields.pointers,
                    backupURL: backupURL
                )
            )
        }

        if !migratedLayers.isEmpty {
            _ = try await layerStore.commitLegacyMigration(
                layers: migratedLayers,
                records: migrationRecords
            )
        }
        return LegacyOverrideMigrationReport(results: results)
    }

    private func ensureBackup(
        _ sourceData: Data,
        at backupURL: URL,
        profileID: UUID
    ) throws {
        if fileSystem.fileExists(at: backupURL) {
            let existing: Data
            do {
                existing = try fileSystem.readData(at: backupURL)
            } catch {
                throw LegacyOverrideMigrationError.backupFailed(profileID)
            }
            guard existing == sourceData else {
                throw LegacyOverrideMigrationError.backupMismatch(profileID)
            }
            do {
                try fileSystem.setPOSIXPermissions(0o600, at: backupURL)
            } catch {
                throw LegacyOverrideMigrationError.backupFailed(profileID)
            }
            return
        }

        do {
            try fileSystem.createDirectory(
                at: backupURL.deletingLastPathComponent()
            )
            try fileSystem.setPOSIXPermissions(
                0o700,
                at: backupURL.deletingLastPathComponent()
            )
            try fileSystem.writeDataAtomically(sourceData, to: backupURL)
            try fileSystem.setPOSIXPermissions(0o600, at: backupURL)
            guard try fileSystem.readData(at: backupURL) == sourceData else {
                throw LegacyOverrideMigrationError.backupFailed(profileID)
            }
        } catch {
            if fileSystem.fileExists(at: backupURL) {
                try? fileSystem.removeItem(at: backupURL)
            }
            if let error = error as? LegacyOverrideMigrationError {
                throw error
            }
            throw LegacyOverrideMigrationError.backupFailed(profileID)
        }
    }

    private nonisolated static func unknownFields(
        in data: Data,
        profileID: UUID
    ) throws -> (topLevelKeys: [String], pointers: [String]) {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LegacyOverrideMigrationError.invalidTopLevelObject(profileID)
        }
        guard let mapping = object as? [String: Any] else {
            throw LegacyOverrideMigrationError.invalidTopLevelObject(profileID)
        }

        var pointers = Set<String>()
        collectUnknownKeys(
            in: mapping,
            knownKeys: knownTopLevelKeys,
            path: [],
            into: &pointers
        )

        if let dns = mapping["dns"] as? [String: Any] {
            collectUnknownKeys(
                in: dns,
                knownKeys: knownDNSKeys,
                path: ["dns"],
                into: &pointers
            )
            for key in knownDNSKeys {
                inspectOverrideValue(
                    dns[key],
                    path: ["dns", key],
                    into: &pointers
                )
            }
            inspectNameserverPolicyEntries(
                dns["nameserver-policy"],
                path: ["dns", "nameserver-policy"],
                into: &pointers
            )
        }

        if let sniffer = mapping["sniffer"] as? [String: Any] {
            collectUnknownKeys(
                in: sniffer,
                knownKeys: knownSnifferKeys,
                path: ["sniffer"],
                into: &pointers
            )
            for key in knownSnifferKeys where key != "sniff" {
                inspectOverrideValue(
                    sniffer[key],
                    path: ["sniffer", key],
                    into: &pointers
                )
            }

            if let sniff = sniffer["sniff"] as? [String: Any] {
                collectUnknownKeys(
                    in: sniff,
                    knownKeys: knownSniffProtocolKeys,
                    path: ["sniffer", "sniff"],
                    into: &pointers
                )
                for protocolName in knownSniffProtocolKeys {
                    guard let protocolOverrides = sniff[protocolName] as? [String: Any] else {
                        continue
                    }
                    let protocolPath = ["sniffer", "sniff", protocolName]
                    collectUnknownKeys(
                        in: protocolOverrides,
                        knownKeys: knownProtocolOverrideKeys,
                        path: protocolPath,
                        into: &pointers
                    )
                    for key in knownProtocolOverrideKeys {
                        inspectOverrideValue(
                            protocolOverrides[key],
                            path: protocolPath + [key],
                            into: &pointers
                        )
                    }
                }
            }
        }

        let topLevelKeys = Set(mapping.keys)
            .subtracting(knownTopLevelKeys)
            .sorted()
        return (topLevelKeys, pointers.sorted())
    }

    private nonisolated static func inspectOverrideValue(
        _ value: Any?,
        path: [String],
        into pointers: inout Set<String>
    ) {
        guard let mapping = value as? [String: Any] else { return }
        collectUnknownKeys(
            in: mapping,
            knownKeys: knownOverrideValueKeys,
            path: path,
            into: &pointers
        )
    }

    private nonisolated static func inspectNameserverPolicyEntries(
        _ overrideValue: Any?,
        path: [String],
        into pointers: inout Set<String>
    ) {
        guard let mapping = overrideValue as? [String: Any],
            let entries = mapping["value"] as? [Any]
        else {
            return
        }
        for (index, entry) in entries.enumerated() {
            guard let entry = entry as? [String: Any] else { continue }
            collectUnknownKeys(
                in: entry,
                knownKeys: knownNameserverPolicyEntryKeys,
                path: path + ["value", String(index)],
                into: &pointers
            )
        }
    }

    private nonisolated static func collectUnknownKeys(
        in mapping: [String: Any],
        knownKeys: Set<String>,
        path: [String],
        into pointers: inout Set<String>
    ) {
        for key in mapping.keys where !knownKeys.contains(key) {
            pointers.insert(YAMLPointer(components: path + [key]).rawValue)
        }
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

nonisolated struct LegacyOverrideLayerMapper: Sendable {
    static func makeLayer(
        profileID: UUID,
        overrides: ProfileStructuredOverrides
    ) -> ConfigurationLayer {
        var builder = Builder(profileID: profileID)

        builder.add(overrides.dns.enable, order: 10, path: ["dns", "enable"]) {
            .bool($0)
        }
        builder.add(overrides.dns.ipv6, order: 20, path: ["dns", "ipv6"]) {
            .bool($0)
        }
        builder.add(
            overrides.dns.enhancedMode,
            order: 30,
            path: ["dns", "enhanced-mode"]
        ) { .string($0.rawValue) }
        builder.add(
            overrides.dns.fakeIPRange,
            order: 40,
            path: ["dns", "fake-ip-range"]
        ) { .string($0) }
        builder.add(
            overrides.dns.fakeIPFilterMode,
            order: 50,
            path: ["dns", "fake-ip-filter-mode"]
        ) { .string($0.rawValue) }
        builder.addStringList(
            overrides.dns.fakeIPFilter,
            order: 60,
            path: ["dns", "fake-ip-filter"]
        )
        builder.add(overrides.dns.useHosts, order: 70, path: ["dns", "use-hosts"]) {
            .bool($0)
        }
        builder.add(
            overrides.dns.useSystemHosts,
            order: 80,
            path: ["dns", "use-system-hosts"]
        ) { .bool($0) }
        builder.add(
            overrides.dns.respectRules,
            order: 90,
            path: ["dns", "respect-rules"]
        ) { .bool($0) }
        builder.addStringList(
            overrides.dns.defaultNameserver,
            order: 100,
            path: ["dns", "default-nameserver"]
        )
        builder.addStringList(
            overrides.dns.nameserver,
            order: 110,
            path: ["dns", "nameserver"]
        )
        builder.addStringList(
            overrides.dns.fallback,
            order: 120,
            path: ["dns", "fallback"]
        )
        builder.addStringList(
            overrides.dns.proxyServerNameserver,
            order: 130,
            path: ["dns", "proxy-server-nameserver"]
        )
        builder.addStringList(
            overrides.dns.directNameserver,
            order: 140,
            path: ["dns", "direct-nameserver"]
        )
        builder.add(
            overrides.dns.directNameserverFollowPolicy,
            order: 150,
            path: ["dns", "direct-nameserver-follow-policy"]
        ) { .bool($0) }
        builder.add(
            overrides.dns.nameserverPolicy,
            order: 160,
            path: ["dns", "nameserver-policy"]
        ) { entries in
            var mapping = OrderedYAMLMapping()
            for entry in entries {
                mapping[entry.pattern] = .sequence(
                    entry.servers.map(YAMLValue.string)
                )
            }
            return .mapping(mapping)
        }

        builder.add(
            overrides.sniffer.enable,
            order: 170,
            path: ["sniffer", "enable"]
        ) { .bool($0) }
        builder.add(
            overrides.sniffer.forceDNSMapping,
            order: 180,
            path: ["sniffer", "force-dns-mapping"]
        ) { .bool($0) }
        builder.add(
            overrides.sniffer.parsePureIP,
            order: 190,
            path: ["sniffer", "parse-pure-ip"]
        ) { .bool($0) }
        builder.add(
            overrides.sniffer.overrideDestination,
            order: 200,
            path: ["sniffer", "override-destination"]
        ) { .bool($0) }

        builder.addPorts(
            overrides.sniffer.sniff.http.ports,
            order: 210,
            path: ["sniffer", "sniff", "HTTP", "ports"]
        )
        builder.add(
            overrides.sniffer.sniff.http.overrideDestination,
            order: 220,
            path: ["sniffer", "sniff", "HTTP", "override-destination"]
        ) { .bool($0) }
        builder.addPorts(
            overrides.sniffer.sniff.tls.ports,
            order: 230,
            path: ["sniffer", "sniff", "TLS", "ports"]
        )
        builder.add(
            overrides.sniffer.sniff.tls.overrideDestination,
            order: 240,
            path: ["sniffer", "sniff", "TLS", "override-destination"]
        ) { .bool($0) }
        builder.addPorts(
            overrides.sniffer.sniff.quic.ports,
            order: 250,
            path: ["sniffer", "sniff", "QUIC", "ports"]
        )
        builder.add(
            overrides.sniffer.sniff.quic.overrideDestination,
            order: 260,
            path: ["sniffer", "sniff", "QUIC", "override-destination"]
        ) { .bool($0) }

        builder.addStringList(
            overrides.sniffer.forceDomain,
            order: 270,
            path: ["sniffer", "force-domain"]
        )
        builder.addStringList(
            overrides.sniffer.skipDomain,
            order: 280,
            path: ["sniffer", "skip-domain"]
        )
        builder.addStringList(
            overrides.sniffer.skipSourceAddress,
            order: 290,
            path: ["sniffer", "skip-src-address"]
        )
        builder.addStringList(
            overrides.sniffer.skipDestinationAddress,
            order: 300,
            path: ["sniffer", "skip-dst-address"]
        )
        builder.prependUniqueStrings(
            overrides.prependedRules,
            order: 310,
            path: ["rules"]
        )

        return ConfigurationLayer(
            id: DeterministicMigrationUUID.make(
                "vela-v04",
                "v02-structured-overrides",
                profileID.uuidString.lowercased(),
                "profile-layer"
            ),
            revision: 1,
            name: "Migrated V0.2 Overrides",
            kind: .profile,
            enabled: true,
            operations: builder.operations,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private struct Builder {
        let profileID: UUID
        var operations: [ConfigurationOperation] = []

        mutating func add<Value: Codable & Sendable>(
            _ override: OverrideValue<Value>,
            order: Int,
            path: [String],
            transform: (Value) -> YAMLValue
        ) {
            let pointer = YAMLPointer(components: path)
            let kind: ConfigurationOperationKind
            let value: YAMLValue?
            switch override {
            case .inherit:
                return
            case let .set(rawValue):
                kind = .set
                value = transform(rawValue)
            case .remove:
                kind = .remove
                value = nil
            }
            operations.append(
                ConfigurationOperation(
                    id: DeterministicMigrationUUID.make(
                        "vela-v04",
                        "v02-structured-overrides",
                        profileID.uuidString.lowercased(),
                        pointer.rawValue,
                        kind.rawValue
                    ),
                    enabled: true,
                    order: order,
                    path: pointer,
                    kind: kind,
                    value: value,
                    note: "Migrated from V0.2 structured overrides."
                )
            )
        }

        mutating func addStringList(
            _ override: OverrideValue<[String]>,
            order: Int,
            path: [String]
        ) {
            add(override, order: order, path: path) {
                .sequence($0.map(YAMLValue.string))
            }
        }

        mutating func addPorts(
            _ override: OverrideValue<[SnifferPort]>,
            order: Int,
            path: [String]
        ) {
            add(override, order: order, path: path) { ports in
                .sequence(ports.map { port in
                    switch port {
                    case let .single(value): .integer(value)
                    case .range: .string(port.canonicalText)
                    }
                })
            }
        }

        mutating func prependUniqueStrings(
            _ values: [String],
            order: Int,
            path: [String]
        ) {
            guard !values.isEmpty else { return }
            let pointer = YAMLPointer(components: path)
            let kind = ConfigurationOperationKind.prependUnique
            operations.append(
                ConfigurationOperation(
                    id: DeterministicMigrationUUID.make(
                        "vela-v04",
                        "v02-structured-overrides",
                        profileID.uuidString.lowercased(),
                        pointer.rawValue,
                        kind.rawValue
                    ),
                    enabled: true,
                    order: order,
                    path: pointer,
                    kind: kind,
                    value: .sequence(values.map(YAMLValue.string)),
                    note: "Migrated from V0.2 structured overrides."
                )
            )
        }
    }
}

nonisolated enum DeterministicMigrationUUID {
    static func make(_ components: String...) -> UUID {
        let input = components.joined(separator: "\u{1F}")
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        // RFC 4122 variant with a version-5-shaped marker. SHA-256 is used for
        // collision resistance; this UUID is an internal deterministic key.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

extension LegacyOverrideMigrationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .discoveryFailed:
            "Legacy override files could not be enumerated."
        case let .sourceReadFailed(profileID):
            "The legacy override for profile \(profileID.uuidString) could not be read."
        case let .invalidTopLevelObject(profileID):
            "The legacy override for profile \(profileID.uuidString) is not a JSON object."
        case let .decodeFailed(profileID):
            "The legacy override for profile \(profileID.uuidString) is invalid."
        case let .unsupportedSchemaVersion(profileID, version):
            "The legacy override for profile \(profileID.uuidString) uses unsupported schema \(version)."
        case let .validationFailed(profileID):
            "The legacy override for profile \(profileID.uuidString) failed validation."
        case let .backupMismatch(profileID):
            "The retained legacy override backup for profile \(profileID.uuidString) differs from the source."
        case let .backupFailed(profileID):
            "The legacy override for profile \(profileID.uuidString) could not be backed up."
        case let .sourceChangedAfterMigration(profileID):
            "The legacy override for profile \(profileID.uuidString) changed after migration."
        case let .migrationEvidenceCorrupt(profileID):
            "Migration evidence for profile \(profileID.uuidString) does not reference its committed layer."
        }
    }
}
