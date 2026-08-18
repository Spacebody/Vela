import Foundation
import Testing
import XCTest
@testable import Vela

@Suite("V0.4 deterministic configuration compiler")
struct ConfigurationCompilerTests {
    @Test("Pack fixtures compile to the expected semantic configuration and source map")
    func packFixturesCompile() throws {
        let root = Self.packRoot
        let upstream = try Data(contentsOf: root.appending(path: "fixtures/upstream-config.yaml"))
        let expectedData = try Data(contentsOf: root.appending(path: "fixtures/expected-effective.yaml"))
        let expected = try YAMLDocument(yaml: String(decoding: expectedData, as: UTF8.self))
        let decoder = JSONDecoder()
        let global = try decoder.decode(
            ConfigurationLayer.self,
            from: Data(contentsOf: root.appending(path: "fixtures/global-layer.json"))
        )
        let profile = try decoder.decode(
            ConfigurationLayer.self,
            from: Data(contentsOf: root.appending(path: "fixtures/profile-layer.json"))
        )
        let scene = try decoder.decode(
            ConfigurationLayer.self,
            from: Data(contentsOf: root.appending(path: "fixtures/scene-layer.json"))
        )
        let expectedSourceMap = try decoder.decode(
            ExpectedSourceMapFixture.self,
            from: Data(contentsOf: root.appending(path: "fixtures/expected-source-map.json"))
        )

        let compiled = try ConfigurationCompiler().compile(
            upstreamYAML: upstream,
            context: ConfigurationCompilationContext(
                layers: [scene, profile, global],
                generationID: expectedSourceMap.configurationGenerationID
            )
        )

        #expect(compiled.semanticRoot == .mapping(expected.root))
        #expect(expectedSourceMap.schemaVersion == 1)
        #expect(
            try Self.value(at: "/dns/custom-unknown-field", in: compiled.semanticRoot)
                == .string("preserve-me")
        )
        #expect(compiled.provenance.paths["/dns/enable"]?.effectiveSource.kind == .upstream)
        #expect(compiled.provenance.paths["/dns/ipv6"]?.effectiveSource.layerID == global.id)
        #expect(compiled.provenance.paths["/sniffer/enable"]?.effectiveSource.layerID == profile.id)
        #expect(compiled.provenance.paths["/dns/respect-rules"]?.effectiveSource.layerID == scene.id)
        #expect(compiled.ruleIndexMap.entries.count == 2)
        #expect(compiled.configurationGenerationID == expectedSourceMap.configurationGenerationID)

        let kindsByLayerID: [UUID: String] = [
            global.id: "global",
            profile.id: "profile",
            scene.id: "scene",
        ]
        for (path, expected) in expectedSourceMap.paths {
            let actual = try #require(compiled.provenance.paths[path])
            let actualSource = actual.effectiveSource.kind == .upstream
                ? "upstream"
                : actual.effectiveSource.layerID.flatMap { kindsByLayerID[$0] }
            #expect(actualSource == expected.source)
            #expect(actual.effectiveSource.operationID == expected.operationID)
        }
    }

    @Test("Identical input compiles byte-identically one hundred times")
    func deterministicOneHundredRuns() throws {
        let upstream = try Data(contentsOf: Self.packRoot.appending(path: "fixtures/upstream-config.yaml"))
        let layer = try JSONDecoder().decode(
            ConfigurationLayer.self,
            from: Data(contentsOf: Self.packRoot.appending(path: "fixtures/global-layer.json"))
        )
        let compiler = ConfigurationCompiler()
        var yamlOutputs = Set<Data>()
        var hashes = Set<String>()
        var generationIDs = Set<UUID>()

        for _ in 0..<100 {
            let output = try compiler.compile(
                upstreamYAML: upstream,
                context: ConfigurationCompilationContext(layers: [layer])
            )
            yamlOutputs.insert(output.yaml)
            hashes.insert(output.sha256)
            generationIDs.insert(output.configurationGenerationID)
        }

        #expect(yamlOutputs.count == 1)
        #expect(hashes.count == 1)
        #expect(generationIDs.count == 1)
    }

    @Test("All seven patch operations have stable semantics")
    func allPatchOperations() throws {
        let layer = ConfigurationLayer(
            id: Self.uuid(1),
            name: "operations",
            kind: .global,
            operations: [
                Self.operation(1, order: 10, path: "/root/new", kind: .set, value: .integer(2)),
                Self.operation(2, order: 20, path: "/remove-me", kind: .remove),
                Self.operation(3, order: 30, path: "/root", kind: .deepMerge, value: .mapping([
                    "nested": .mapping(["added": .bool(true)]),
                ])),
                Self.operation(4, order: 40, path: "/sequence", kind: .prependUnique, value: .sequence([
                    .string("b"), .string("z"),
                ])),
                Self.operation(5, order: 50, path: "/sequence", kind: .appendUnique, value: .sequence([
                    .string("q"), .string("a"),
                ])),
                Self.operation(
                    6,
                    order: 60,
                    path: "/items",
                    kind: .upsertNamed,
                    value: .mapping(["name": .string("A"), "value": .integer(9)]),
                    identityKey: "name",
                    identityValue: "A"
                ),
                Self.operation(
                    7,
                    order: 70,
                    path: "/items",
                    kind: .removeNamed,
                    identityKey: "name",
                    identityValue: "B"
                ),
            ],
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let input = """
        root:
          keep: true
          nested:
            existing: "yes"
        remove-me: value
        sequence: [a, b]
        items:
          - name: A
            value: 1
          - name: B
            value: 2
        """

        let output = try ConfigurationCompiler().compile(
            upstreamYAML: input,
            context: ConfigurationCompilationContext(layers: [layer])
        )

        #expect(try Self.value(at: "/root/new", in: output.semanticRoot) == .integer(2))
        #expect(try Self.value(at: "/root/nested/existing", in: output.semanticRoot) == .string("yes"))
        #expect(try Self.value(at: "/root/nested/added", in: output.semanticRoot) == .bool(true))
        #expect(try Self.value(at: "/remove-me", in: output.semanticRoot) == nil)
        #expect(
            try Self.value(at: "/sequence", in: output.semanticRoot)
                == .sequence([.string("z"), .string("a"), .string("b"), .string("q")])
        )
        #expect(
            try Self.value(at: "/items", in: output.semanticRoot)
                == .sequence([.mapping(["name": .string("A"), "value": .integer(9)])])
        )
        #expect(output.diagnostics.contains { $0.code == .duplicateValueIgnored })
    }

    @Test("Cross-layer overrides retain contributors and a warning")
    func crossLayerProvenance() throws {
        let global = ConfigurationLayer(
            id: Self.uuid(10),
            name: "global",
            kind: .global,
            operations: [Self.operation(10, order: 1, path: "/mode", kind: .set, value: .string("global"))]
        )
        let profile = ConfigurationLayer(
            id: Self.uuid(11),
            name: "profile",
            kind: .profile,
            operations: [Self.operation(11, order: 1, path: "/mode", kind: .set, value: .string("direct"))]
        )

        let output = try ConfigurationCompiler().compile(
            upstreamYAML: "mode: rule\n",
            context: ConfigurationCompilationContext(layers: [profile, global])
        )
        let source = try #require(output.provenance.paths["/mode"])
        #expect(try Self.value(at: "/mode", in: output.semanticRoot) == .string("direct"))
        #expect(source.effectiveSource.layerID == profile.id)
        #expect(source.contributors.count == 2)
        #expect(source.conflicts.count == 2)
        #expect(output.diagnostics.filter { $0.code == .crossLayerOverride }.count == 2)
    }

    @Test("Protected paths fail before they can mutate the candidate", arguments: [
        "/secret",
        "/external-controller",
        "/allow-lan",
        "/listeners",
        "/tun/auto-route",
        "/mixed-port",
        "/external-ui",
        "/external-controller-cors/private-network",
        "/routing-mark",
        "/interface-name",
    ])
    func protectedPaths(path: String) throws {
        let layer = ConfigurationLayer(
            id: Self.uuid(20),
            name: "blocked",
            kind: .profile,
            operations: [Self.operation(20, order: 1, path: path, kind: .set, value: .bool(true))]
        )

        do {
            _ = try ConfigurationCompiler().compile(
                upstreamYAML: "mode: rule\n",
                context: ConfigurationCompilationContext(layers: [layer])
            )
            Issue.record("Expected protected path \(path) to fail")
        } catch let error as ConfigurationCompilerError {
            guard case let .patch(.protectedPath(_, _, rejectedPath, _)) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(rejectedPath == path)
        }
    }

    @Test("Fixture that attacks two protected paths is rejected")
    func protectedFixtureIsRejected() throws {
        let layer = try JSONDecoder().decode(
            ConfigurationLayer.self,
            from: Data(contentsOf: Self.packRoot.appending(path: "fixtures/protected-path-layer.json"))
        )
        #expect(throws: ConfigurationCompilerError.self) {
            try ConfigurationCompiler().compile(
                upstreamYAML: "mode: rule\n",
                context: ConfigurationCompilationContext(layers: [layer])
            )
        }
    }

    @Test("Conflicting sets in one layer fail deterministically")
    func sameLayerConflictFails() throws {
        let layer = ConfigurationLayer(
            id: Self.uuid(30),
            name: "conflict",
            kind: .global,
            operations: [
                Self.operation(31, order: 1, path: "/mode", kind: .set, value: .string("rule")),
                Self.operation(32, order: 2, path: "/mode", kind: .set, value: .string("direct")),
            ]
        )
        do {
            _ = try ConfigurationCompiler().compile(
                upstreamYAML: "mode: global\n",
                context: ConfigurationCompilationContext(layers: [layer])
            )
            Issue.record("Expected a conflict")
        } catch let error as ConfigurationCompilerError {
            guard case .patch(.operationConflict) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("Numeric pointer components address mapping keys, never array indexes")
    func numericKeysAreNotArrayIndexes() throws {
        let mappingLayer = ConfigurationLayer(
            name: "numeric mapping",
            kind: .global,
            operations: [Self.operation(40, order: 1, path: "/numeric/0", kind: .set, value: .string("new"))]
        )
        let mappingOutput = try ConfigurationCompiler().compile(
            upstreamYAML: "numeric:\n  '0': old\n",
            context: ConfigurationCompilationContext(layers: [mappingLayer])
        )
        #expect(try Self.value(at: "/numeric/0", in: mappingOutput.semanticRoot) == .string("new"))

        let sequenceLayer = ConfigurationLayer(
            name: "numeric sequence",
            kind: .global,
            operations: [Self.operation(41, order: 1, path: "/items/0", kind: .set, value: .string("new"))]
        )
        #expect(throws: ConfigurationCompilerError.self) {
            try ConfigurationCompiler().compile(
                upstreamYAML: "items: [old]\n",
                context: ConfigurationCompilationContext(layers: [sequenceLayer])
            )
        }
    }

    @Test("Runtime forced values win and are protected in provenance")
    func runtimeForcedValues() throws {
        let layer = ConfigurationLayer(
            name: "mode",
            kind: .global,
            operations: [Self.operation(50, order: 1, path: "/mode", kind: .set, value: .string("global"))]
        )
        let path = try YAMLPointer("/mode")
        let output = try ConfigurationCompiler().compile(
            upstreamYAML: "mode: rule\n",
            context: ConfigurationCompilationContext(
                layers: [layer],
                runtimeForcedValues: [RuntimeForcedConfigurationValue(
                    path: path,
                    value: .string("direct"),
                    reasonCode: "test"
                )]
            )
        )
        #expect(try Self.value(at: "/mode", in: output.semanticRoot) == .string("direct"))
        #expect(output.provenance.paths["/mode"]?.effectiveSource.kind == .runtimeForced)
        #expect(output.provenance.paths["/mode"]?.isProtected == true)
    }

    @Test("Provenance removes stale descendants and records deep-merge leaf conflicts")
    func provenanceTracksTheFinalTree() throws {
        let layer = ConfigurationLayer(
            id: Self.uuid(52),
            name: "provenance",
            kind: .global,
            operations: [
                Self.operation(
                    52,
                    order: 1,
                    path: "/container",
                    kind: .deepMerge,
                    value: .mapping([
                        "changed": .string("new"),
                        "added": .bool(true),
                    ])
                ),
                Self.operation(
                    53,
                    order: 2,
                    path: "/container",
                    kind: .deepMerge,
                    value: .mapping(["second": .integer(2)])
                ),
                Self.operation(54, order: 3, path: "/obsolete", kind: .remove),
                Self.operation(55, order: 4, path: "/replace", kind: .set, value: .string("scalar")),
            ]
        )
        let output = try ConfigurationCompiler().compile(
            upstreamYAML: """
            container:
              changed: old
              untouched: keep
            obsolete:
              child: old
            replace:
              child: old
            """,
            context: ConfigurationCompilationContext(layers: [layer])
        )

        let changed = try #require(output.provenance.paths["/container/changed"])
        #expect(changed.effectiveSource.operationID == Self.uuid(52))
        #expect(changed.contributors.count == 1)
        #expect(changed.conflicts.count == 1)
        #expect(output.provenance.paths["/container/untouched"]?.effectiveSource.kind == .upstream)
        #expect(output.provenance.paths["/container/added"]?.effectiveSource.operationID == Self.uuid(52))
        #expect(output.provenance.paths["/container/second"]?.effectiveSource.operationID == Self.uuid(53))
        #expect(output.provenance.paths["/obsolete"] == nil)
        #expect(output.provenance.paths["/obsolete/child"] == nil)
        #expect(output.provenance.paths["/replace/child"] == nil)
        #expect(output.diagnostics.filter { $0.code == .crossLayerOverride }.allSatisfy {
            $0.operationID != Self.uuid(53)
        })
    }

    @Test("Rule index origins survive prepends and identify layer-owned rules")
    func ruleOriginsRemainAccurate() throws {
        let layer = ConfigurationLayer(
            id: Self.uuid(56),
            name: "rules",
            kind: .global,
            operations: [
                Self.operation(
                    56,
                    order: 1,
                    path: "/rules",
                    kind: .prependUnique,
                    value: .sequence([.string("DOMAIN,new.example,DIRECT")])
                ),
            ]
        )
        let output = try ConfigurationCompiler().compile(
            upstreamYAML: """
            mode: rule
            rules:
              - DOMAIN,first.example,DIRECT
              - MATCH,DIRECT
            """,
            context: ConfigurationCompilationContext(layers: [layer])
        )

        #expect(output.ruleIndexMap.entries.count == 3)
        guard case .global = output.ruleIndexMap.entries[0].origin else {
            Issue.record("Expected the prepended rule to be global-owned")
            return
        }
        #expect(output.ruleIndexMap.entries[1].origin == .upstream(originalIndex: 0))
        #expect(output.ruleIndexMap.entries[2].origin == .upstream(originalIndex: 1))
    }

    @Test("Canonical uniqueness distinguishes an integer from an integral double")
    func canonicalNumbersRemainDistinct() throws {
        let layer = ConfigurationLayer(
            name: "numbers",
            kind: .global,
            operations: [
                Self.operation(
                    57,
                    order: 1,
                    path: "/values",
                    kind: .appendUnique,
                    value: .sequence([.floatingPoint(1.0)])
                ),
            ]
        )
        let output = try ConfigurationCompiler().compile(
            upstreamYAML: "values: [1]\n",
            context: ConfigurationCompilationContext(layers: [layer])
        )
        #expect(
            try Self.value(at: "/values", in: output.semanticRoot)
                == .sequence([.integer(1), .floatingPoint(1.0)])
        )
    }

    @Test("Sensitive contributors use a non-oracle redacted marker")
    func provenanceRedactsSensitiveFingerprints() throws {
        let layer = ConfigurationLayer(
            name: "provider secret",
            kind: .profile,
            operations: [
                Self.operation(
                    58,
                    order: 1,
                    path: "/proxy-providers/main/access-token",
                    kind: .set,
                    value: .string("new-token")
                ),
                Self.operation(
                    59,
                    order: 2,
                    path: "/proxy-providers/main/url",
                    kind: .set,
                    value: .string("https://new.invalid/sub")
                ),
            ]
        )
        let output = try ConfigurationCompiler().compile(
            upstreamYAML: """
            proxy-providers:
              main:
                access-token: old-token
                url: https://old.invalid/sub
            secret: old-controller-secret
            """,
            context: ConfigurationCompilationContext(
                layers: [layer],
                runtimeForcedValues: [RuntimeForcedConfigurationValue(
                    path: try YAMLPointer("/secret"),
                    value: .string("new-controller-secret"),
                    reasonCode: "managedControllerSecret"
                )]
            )
        )

        for path in [
            "/proxy-providers/main/access-token",
            "/proxy-providers/main/url",
            "/secret",
        ] {
            let provenance = try #require(output.provenance.paths[path])
            #expect(provenance.isRedacted)
            #expect(provenance.contributors.allSatisfy { $0.valueFingerprint == "redacted" })
        }
    }

    @Test("Configured limits reject oversized paths and values")
    func limitsAreEnforced() throws {
        var limits = ConfigurationCompilerLimits.default
        limits.maximumPointerBytes = 8
        let longPathLayer = ConfigurationLayer(
            name: "long path",
            kind: .global,
            operations: [Self.operation(60, order: 1, path: "/this-is-long", kind: .set, value: .bool(true))]
        )
        #expect(throws: ConfigurationCompilerError.self) {
            try ConfigurationCompiler(limits: limits).compile(
                upstreamYAML: "mode: rule\n",
                context: ConfigurationCompilationContext(layers: [longPathLayer])
            )
        }

        limits = .default
        limits.maximumDepth = 4
        let combinedDepthLayer = ConfigurationLayer(
            name: "combined depth",
            kind: .global,
            operations: [
                Self.operation(62, order: 1, path: "/a/b/c/d", kind: .set, value: .bool(true)),
            ]
        )
        #expect(throws: ConfigurationCompilerError.self) {
            try ConfigurationCompiler(limits: limits).compile(
                upstreamYAML: "mode: rule\n",
                context: ConfigurationCompilationContext(layers: [combinedDepthLayer])
            )
        }

        #expect(throws: ConfigurationCompilerError.self) {
            try ConfigurationCompiler(limits: limits).compile(
                upstreamYAML: "mode: rule\n",
                context: ConfigurationCompilationContext(
                    runtimeForcedValues: [RuntimeForcedConfigurationValue(
                        path: try YAMLPointer("/a/b/c/d"),
                        value: .bool(true),
                        reasonCode: "tooDeep"
                    )]
                )
            )
        }

        #expect(throws: ConfigurationCompilerError.self) {
            try ConfigurationCompiler().compile(
                upstreamYAML: "rules: [MATCH,DIRECT]\n",
                context: ConfigurationCompilationContext(
                    runtimeForcedValues: [RuntimeForcedConfigurationValue(
                        path: try YAMLPointer("/rules"),
                        value: .sequence([.string("MATCH,REJECT")]),
                        reasonCode: "unsupportedRuleOrigin"
                    )]
                )
            )
        }

        limits = .default
        limits.maximumValueBytes = 16
        let hugeValueLayer = ConfigurationLayer(
            name: "huge value",
            kind: .global,
            operations: [Self.operation(61, order: 1, path: "/notes", kind: .set, value: .string(String(repeating: "x", count: 100)))]
        )
        #expect(throws: ConfigurationCompilerError.self) {
            try ConfigurationCompiler(limits: limits).compile(
                upstreamYAML: "mode: rule\n",
                context: ConfigurationCompilationContext(layers: [hugeValueLayer])
            )
        }
    }

    @Test("A pre-cancelled compile exits at a safe checkpoint")
    func cancellationIsObserved() async {
        let task = Task {
            try ConfigurationCompiler().compile(upstreamYAML: "mode: rule\n")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("Actual bundled Mihomo v1.19.29 accepts the compiled fixture")
    func actualMihomoValidation() async throws {
        let root = Self.packRoot
        let decoder = JSONDecoder()
        let layers = try ["global-layer.json", "profile-layer.json", "scene-layer.json"].map {
            try decoder.decode(
                ConfigurationLayer.self,
                from: Data(contentsOf: root.appending(path: "fixtures/\($0)"))
            )
        }
        let output = try ConfigurationCompiler().compile(
            upstreamYAML: Data(contentsOf: root.appending(path: "fixtures/upstream-config.yaml")),
            context: ConfigurationCompilationContext(layers: layers)
        )
        let temporary = URL.temporaryDirectory.appending(
            path: "Vela-v04-mihomo-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let configurationURL = temporary.appending(path: "compiled.yaml")
        try output.yaml.write(to: configurationURL, options: .atomic)

        let executable = Self.repositoryRoot.appending(path: "Vendor/Mihomo/bin/mihomo")
        let result = try await ProcessExecutor().execute(ProcessExecutionRequest(
            executableURL: executable,
            arguments: ["-t", "-f", configurationURL.path, "-d", temporary.path],
            timeout: .seconds(15)
        ))
        #expect(result.succeeded)
        #expect(result.stderr.isEmpty || !result.stderr.localizedCaseInsensitiveContains("error"))
    }

    private static var packRoot: URL {
        repositoryRoot
            .appending(path: "VelaTests/Fixtures/ConfigurationCompiler")
    }

    private static var repositoryRoot: URL {
        if let stagedRoot = ProcessInfo.processInfo.environment["VELA_TEST_REPOSITORY_ROOT"],
           !stagedRoot.isEmpty
        {
            return URL(fileURLWithPath: stagedRoot, isDirectory: true)
        }
        let derivedDataRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stagedRoot = derivedDataRoot.appendingPathComponent(
            "Vela-CI-TestAssets",
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: stagedRoot.path, isDirectory: &isDirectory),
           isDirectory.boolValue
        {
            return stagedRoot
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func operation(
        _ seed: Int,
        order: Int,
        path: String,
        kind: ConfigurationOperationKind,
        value: YAMLValue? = nil,
        identityKey: String? = nil,
        identityValue: String? = nil
    ) -> ConfigurationOperation {
        ConfigurationOperation(
            id: uuid(seed),
            order: order,
            path: try! YAMLPointer(path),
            kind: kind,
            value: value,
            identityKey: identityKey,
            identityValue: identityValue
        )
    }

    private static func uuid(_ seed: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", seed))!
    }

    private static func value(at pointer: String, in root: YAMLValue) throws -> YAMLValue? {
        var value = root
        for component in try YAMLPointer(pointer).components {
            guard case let .mapping(mapping) = value, let next = mapping[component] else {
                return nil
            }
            value = next
        }
        return value
    }
}

nonisolated private struct ExpectedSourceMapFixture: Decodable {
    let schemaVersion: Int
    let configurationGenerationID: UUID
    let paths: [String: ExpectedSourceMapPathFixture]
}

nonisolated private struct ExpectedSourceMapPathFixture: Decodable {
    let source: String
    let operationID: UUID?
}

/// The CI runner isolates this 50k-rule benchmark from the default concurrent
/// business-test batch so it cannot starve unrelated deadline tests.
nonisolated final class ConfigurationCompilerPerformanceTests: XCTestCase {
    func testLargeRuleSetPerformance() throws {
        let compiler = ConfigurationCompiler()
        for (ruleCount, documentedBudget) in [(10_000, 2.0), (50_000, 5.0)] {
            let rules = (0..<ruleCount).map { index in
                "  - DOMAIN,host-\(index).example,DIRECT"
            }
            let upstream = "mode: rule\nrules:\n" + rules.joined(separator: "\n") + "\n"
            let startedAt = ProcessInfo.processInfo.systemUptime
            let output = try compiler.compile(upstreamYAML: upstream)
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

            print(
                "VELA_V04_PERFORMANCE rules=\(ruleCount) seconds=\(String(format: "%.3f", elapsed)) "
                    + "documented_budget=\(String(format: "%.1f", documentedBudget))"
            )
            XCTAssertEqual(output.ruleIndexMap.entries.count, ruleCount)
            XCTAssertFalse(output.yaml.isEmpty)
            XCTAssertTrue(elapsed.isFinite)
        }
    }
}
