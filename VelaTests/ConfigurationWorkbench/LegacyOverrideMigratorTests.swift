import Foundation
import Testing
@testable import Vela

@Suite("Legacy V0.2 override migration")
struct LegacyOverrideMigratorTests {
    @Test("Every DNS and Sniffer field uses a fixed set-operation order")
    func allSetFieldsUseStaticOrder() throws {
        let profileID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let layer = LegacyOverrideLayerMapper.makeLayer(
            profileID: profileID,
            overrides: allSetOverrides()
        )

        #expect(layer.operations.count == 30)
        #expect(layer.operations.map(\.order) == Array(stride(from: 10, through: 300, by: 10)))
        #expect(layer.operations.map(\.path.rawValue) == expectedPaths)
        #expect(layer.operations.allSatisfy { $0.kind == .set })
        #expect(layer.operations[20].value == .sequence([.integer(80), .string("443-8443")]))
        #expect(
            layer.operations[15].value
                == .mapping([
                    "example.com": .sequence([.string("1.1.1.1")]),
                ])
        )
        #expect(!layer.operations.contains { $0.path.rawValue.hasPrefix("/tun") })
    }

    @Test("Every DNS and Sniffer field maps remove while inherit maps nothing")
    func removeAndInheritMappingsAreComplete() {
        let profileID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let removed = LegacyOverrideLayerMapper.makeLayer(
            profileID: profileID,
            overrides: allRemoveOverrides()
        )
        let inherited = LegacyOverrideLayerMapper.makeLayer(
            profileID: profileID,
            overrides: ProfileStructuredOverrides()
        )

        #expect(removed.operations.count == 30)
        #expect(removed.operations.map(\.path.rawValue) == expectedPaths)
        #expect(removed.operations.allSatisfy { $0.kind == .remove && $0.value == nil })
        #expect(inherited.operations.isEmpty)
    }

    @Test("Layer and operation identifiers are deterministic")
    func identifiersAreDeterministic() {
        let profileID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let first = LegacyOverrideLayerMapper.makeLayer(
            profileID: profileID,
            overrides: allSetOverrides()
        )
        let second = LegacyOverrideLayerMapper.makeLayer(
            profileID: profileID,
            overrides: allSetOverrides()
        )
        let other = LegacyOverrideLayerMapper.makeLayer(
            profileID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
            overrides: allSetOverrides()
        )

        #expect(first.id == second.id)
        #expect(first.operations.map(\.id) == second.operations.map(\.id))
        #expect(first.id != other.id)
        #expect(first.operations.map(\.id) != other.operations.map(\.id))
        #expect(Set(first.operations.map(\.id)).count == first.operations.count)
    }

    @Test("Migrated operations preserve the V0.2 processor semantics")
    func migratedCompilerSemanticsMatchLegacyProcessor() throws {
        let profileID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let upstream = """
        mode: rule
        dns:
          enable: false
          ipv6: true
          nameserver:
            - 8.8.8.8
          nameserver-policy:
            old.example: 8.8.4.4
        sniffer:
          enable: false
          sniff:
            HTTP:
              ports:
                - 8080
              override-destination: false
            TLS:
              ports:
                - 8443
            QUIC:
              ports:
                - 8443
        """

        for overrides in [allSetOverrides(), allRemoveOverrides()] {
            let legacy = try ConfigurationOverrideProcessor().process(
                upstreamYAML: upstream,
                overrides: overrides
            )
            let migratedLayer = LegacyOverrideLayerMapper.makeLayer(
                profileID: profileID,
                overrides: overrides
            )
            let compiled = try ConfigurationCompiler().compile(
                upstreamYAML: upstream,
                context: ConfigurationCompilationContext(
                    profileID: profileID,
                    layers: [migratedLayer]
                )
            )

            #expect(compiled.semanticRoot == .mapping(legacy.finalDocument.root))
        }
    }

    @Test("Persistent rules migrate as one deterministic prepend operation")
    func prependedRulesMigrateWithoutDataLoss() throws {
        let profileID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let overrides = ProfileStructuredOverrides(
            prependedRules: [
                "DOMAIN-SUFFIX,custom.example,DIRECT",
                "DOMAIN-SUFFIX,upstream.example,DIRECT",
            ]
        )
        let layer = LegacyOverrideLayerMapper.makeLayer(
            profileID: profileID,
            overrides: overrides
        )
        let operation = try #require(layer.operations.first)

        #expect(layer.operations.count == 1)
        #expect(operation.order == 310)
        #expect(operation.path.rawValue == "/rules")
        #expect(operation.kind == .prependUnique)
        #expect(operation.value == .sequence([
            .string("DOMAIN-SUFFIX,custom.example,DIRECT"),
            .string("DOMAIN-SUFFIX,upstream.example,DIRECT"),
        ]))

        let upstream = """
        mode: rule
        rules:
          - DOMAIN-SUFFIX,upstream.example,DIRECT
          - MATCH,PROXY
        """
        let legacy = try ConfigurationOverrideProcessor().process(
            upstreamYAML: upstream,
            overrides: overrides
        )
        let compiled = try ConfigurationCompiler().compile(
            upstreamYAML: upstream,
            context: ConfigurationCompilationContext(
                profileID: profileID,
                layers: [layer]
            )
        )

        #expect(compiled.semanticRoot == .mapping(legacy.finalDocument.root))
    }

    @Test("Migration backs up once, reports unknown fields, and is idempotent")
    func migrationIsSafeAndIdempotent() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }
        let directories = ApplicationDirectories(root: root)
        try directories.prepare()
        let profileID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let sourceData = try legacyDataWithNestedUnknownFields(
            allSetOverrides(),
            extra: [
                "future-field": ["keep": true],
                "tun": ["enable": true, "auto-route": false],
            ]
        )
        try sourceData.write(to: directories.overrideURL(for: profileID), options: .atomic)
        let store = ConfigurationLayerStore(directories: directories)
        let migrator = LegacyOverrideMigrator(
            directories: directories,
            layerStore: store
        )

        let first = try await migrator.migrate(profileIDs: [profileID])
        let firstResult = try #require(first.results.first)
        #expect(firstResult.status == .migrated)
        #expect(firstResult.operationCount == 30)
        #expect(firstResult.unknownTopLevelKeys == ["future-field", "tun"])
        #expect(firstResult.unknownFieldPointers == [
            "/dns/enable/future-option",
            "/dns/future-field",
            "/dns/nameserver-policy/value/0/future-entry-field",
            "/future-field",
            "/sniffer/sniff/HTTP/future-http-field",
            "/tun",
        ])
        let backupURL = directories.legacyOverrideMigrationBackupURL(for: profileID)
        #expect(try Data(contentsOf: backupURL) == sourceData)
        #expect(try Data(contentsOf: directories.overrideURL(for: profileID)) == sourceData)
        try expectPermissions(0o600, at: backupURL)
        try expectPermissions(0o600, at: directories.configurationLayers)

        let layer = try #require(try await store.layer(kind: .profile, ownerID: profileID))
        #expect(layer.operations.count == 30)
        #expect(!layer.operations.contains { $0.path.rawValue.hasPrefix("/tun") })
        let firstStoreData = try Data(contentsOf: directories.configurationLayers)

        let second = try await migrator.migrate(profileIDs: [profileID])
        #expect(second.results.first?.status == .alreadyMigrated)
        #expect(second.results.first?.unknownTopLevelKeys == ["future-field", "tun"])
        #expect(second.results.first?.unknownFieldPointers == firstResult.unknownFieldPointers)
        #expect(try Data(contentsOf: directories.configurationLayers) == firstStoreData)
        #expect(try Data(contentsOf: backupURL) == sourceData)
    }

    @Test("Migration evidence without nested-pointer metadata remains decodable")
    func legacyMigrationEvidenceRemainsDecodable() throws {
        let data = Data(
            """
            {
              "profileID": "11111111-2222-4333-8444-555555555555",
              "layerID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
              "sourceSHA256": "abc123",
              "backupFileName": "legacy.json",
              "unknownTopLevelKeys": ["future/key", "tun"]
            }
            """.utf8
        )

        let record = try JSONDecoder().decode(LegacyOverrideMigrationRecord.self, from: data)

        #expect(record.unknownTopLevelKeys == ["future/key", "tun"])
        #expect(record.unknownFieldPointers == ["/future~1key", "/tun"])
    }

    @Test("A batch decode failure does not commit any migrated layer")
    func batchFailureDoesNotPartiallyCommit() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }
        let directories = ApplicationDirectories(root: root)
        try directories.prepare()
        let validID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let invalidID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        let validData = try JSONEncoder().encode(allSetOverrides())
        try validData.write(to: directories.overrideURL(for: validID), options: .atomic)
        try Data("{not-json".utf8).write(
            to: directories.overrideURL(for: invalidID),
            options: .atomic
        )
        let store = ConfigurationLayerStore(directories: directories)
        let global = ConfigurationLayer(
            id: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            name: "Existing global",
            kind: .global,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        _ = try await store.save(global)
        let before = try Data(contentsOf: directories.configurationLayers)
        let migrator = LegacyOverrideMigrator(
            directories: directories,
            layerStore: store
        )

        do {
            _ = try await migrator.migrate(profileIDs: [validID, invalidID])
            Issue.record("Expected invalid legacy JSON to abort the batch")
        } catch let error as LegacyOverrideMigrationError {
            #expect(error == .invalidTopLevelObject(invalidID))
        }

        #expect(try Data(contentsOf: directories.configurationLayers) == before)
        #expect(try await store.layer(kind: .profile, ownerID: validID) == nil)
        #expect(try await store.snapshot().legacyOverrideMigrations.isEmpty)
        #expect(try Data(contentsOf: directories.overrideURL(for: validID)) == validData)
    }

    @Test("Changed legacy source and mismatched retained backup are rejected")
    func changedEvidenceIsRejected() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }
        let directories = ApplicationDirectories(root: root)
        try directories.prepare()
        let profileID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let sourceURL = directories.overrideURL(for: profileID)
        let sourceData = try JSONEncoder().encode(allSetOverrides())
        try sourceData.write(to: sourceURL, options: .atomic)
        let store = ConfigurationLayerStore(directories: directories)
        let migrator = LegacyOverrideMigrator(
            directories: directories,
            layerStore: store
        )
        _ = try await migrator.migrate(profileIDs: [profileID])

        let backupURL = directories.legacyOverrideMigrationBackupURL(for: profileID)
        try Data("different-backup".utf8).write(to: backupURL, options: .atomic)
        do {
            _ = try await migrator.migrate(profileIDs: [profileID])
            Issue.record("Expected a mismatched retained backup to fail")
        } catch let error as LegacyOverrideMigrationError {
            #expect(error == .backupMismatch(profileID))
        }

        try Data("{}".utf8).write(to: sourceURL, options: .atomic)
        do {
            _ = try await migrator.migrate(profileIDs: [profileID])
            Issue.record("Expected a changed legacy source to fail")
        } catch let error as LegacyOverrideMigrationError {
            #expect(error == .sourceChangedAfterMigration(profileID))
        }
    }

    private var expectedPaths: [String] {
        [
            "/dns/enable",
            "/dns/ipv6",
            "/dns/enhanced-mode",
            "/dns/fake-ip-range",
            "/dns/fake-ip-filter-mode",
            "/dns/fake-ip-filter",
            "/dns/use-hosts",
            "/dns/use-system-hosts",
            "/dns/respect-rules",
            "/dns/default-nameserver",
            "/dns/nameserver",
            "/dns/fallback",
            "/dns/proxy-server-nameserver",
            "/dns/direct-nameserver",
            "/dns/direct-nameserver-follow-policy",
            "/dns/nameserver-policy",
            "/sniffer/enable",
            "/sniffer/force-dns-mapping",
            "/sniffer/parse-pure-ip",
            "/sniffer/override-destination",
            "/sniffer/sniff/HTTP/ports",
            "/sniffer/sniff/HTTP/override-destination",
            "/sniffer/sniff/TLS/ports",
            "/sniffer/sniff/TLS/override-destination",
            "/sniffer/sniff/QUIC/ports",
            "/sniffer/sniff/QUIC/override-destination",
            "/sniffer/force-domain",
            "/sniffer/skip-domain",
            "/sniffer/skip-src-address",
            "/sniffer/skip-dst-address",
        ]
    }

    private func allSetOverrides() -> ProfileStructuredOverrides {
        ProfileStructuredOverrides(
            dns: DNSOverrides(
                enable: .set(true),
                ipv6: .set(false),
                enhancedMode: .set(.fakeIP),
                fakeIPRange: .set("198.18.0.1/16"),
                fakeIPFilterMode: .set(.blacklist),
                fakeIPFilter: .set(["+.lan"]),
                useHosts: .set(true),
                useSystemHosts: .set(false),
                respectRules: .set(true),
                defaultNameserver: .set(["1.1.1.1"]),
                nameserver: .set(["https://1.1.1.1/dns-query"]),
                fallback: .set(["8.8.8.8"]),
                proxyServerNameserver: .set(["9.9.9.9"]),
                directNameserver: .set(["223.5.5.5"]),
                directNameserverFollowPolicy: .set(true),
                nameserverPolicy: .set([
                    NameserverPolicyEntry(pattern: "example.com", servers: ["1.1.1.1"]),
                ])
            ),
            sniffer: SnifferOverrides(
                enable: .set(true),
                forceDNSMapping: .set(true),
                parsePureIP: .set(false),
                overrideDestination: .set(true),
                sniff: SnifferProtocolSetOverrides(
                    http: SnifferProtocolOverrides(
                        ports: .set([.single(80), .range(start: 443, end: 8_443)]),
                        overrideDestination: .set(true)
                    ),
                    tls: SnifferProtocolOverrides(
                        ports: .set([.single(443)]),
                        overrideDestination: .set(false)
                    ),
                    quic: SnifferProtocolOverrides(
                        ports: .set([.single(443)]),
                        overrideDestination: .set(true)
                    )
                ),
                forceDomain: .set(["+.example.com"]),
                skipDomain: .set(["+.apple.com"]),
                skipSourceAddress: .set(["192.0.2.0/24"]),
                skipDestinationAddress: .set(["2001:db8::/32"])
            )
        )
    }

    private func allRemoveOverrides() -> ProfileStructuredOverrides {
        ProfileStructuredOverrides(
            dns: DNSOverrides(
                enable: .remove,
                ipv6: .remove,
                enhancedMode: .remove,
                fakeIPRange: .remove,
                fakeIPFilterMode: .remove,
                fakeIPFilter: .remove,
                useHosts: .remove,
                useSystemHosts: .remove,
                respectRules: .remove,
                defaultNameserver: .remove,
                nameserver: .remove,
                fallback: .remove,
                proxyServerNameserver: .remove,
                directNameserver: .remove,
                directNameserverFollowPolicy: .remove,
                nameserverPolicy: .remove
            ),
            sniffer: SnifferOverrides(
                enable: .remove,
                forceDNSMapping: .remove,
                parsePureIP: .remove,
                overrideDestination: .remove,
                sniff: SnifferProtocolSetOverrides(
                    http: SnifferProtocolOverrides(
                        ports: .remove,
                        overrideDestination: .remove
                    ),
                    tls: SnifferProtocolOverrides(
                        ports: .remove,
                        overrideDestination: .remove
                    ),
                    quic: SnifferProtocolOverrides(
                        ports: .remove,
                        overrideDestination: .remove
                    )
                ),
                forceDomain: .remove,
                skipDomain: .remove,
                skipSourceAddress: .remove,
                skipDestinationAddress: .remove
            )
        )
    }

    private func legacyData(
        _ overrides: ProfileStructuredOverrides,
        extra: [String: Any]
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(overrides)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for (key, value) in extra {
            object[key] = value
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func legacyDataWithNestedUnknownFields(
        _ overrides: ProfileStructuredOverrides,
        extra: [String: Any]
    ) throws -> Data {
        let data = try legacyData(overrides, extra: extra)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        var dns = try #require(object["dns"] as? [String: Any])
        dns["future-field"] = ["keep": true]
        var enable = try #require(dns["enable"] as? [String: Any])
        enable["future-option"] = true
        dns["enable"] = enable
        var nameserverPolicy = try #require(
            dns["nameserver-policy"] as? [String: Any]
        )
        var entries = try #require(nameserverPolicy["value"] as? [[String: Any]])
        entries[0]["future-entry-field"] = "preserve-in-report"
        nameserverPolicy["value"] = entries
        dns["nameserver-policy"] = nameserverPolicy
        object["dns"] = dns

        var sniffer = try #require(object["sniffer"] as? [String: Any])
        var sniff = try #require(sniffer["sniff"] as? [String: Any])
        var http = try #require(sniff["HTTP"] as? [String: Any])
        http["future-http-field"] = ["keep": true]
        sniff["HTTP"] = http
        sniffer["sniff"] = sniff
        object["sniffer"] = sniffer

        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func expectPermissions(_ expected: Int, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == expected)
    }
}
