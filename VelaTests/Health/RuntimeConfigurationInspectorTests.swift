import Foundation
import Testing
@testable import Vela

@Suite("Runtime configuration inspector")
struct RuntimeConfigurationInspectorTests {
    @Test("A validated fingerprint matches unchanged bytes")
    func unchangedConfigurationMatches() async throws {
        let fixture = try RuntimeConfigurationFixture(contents: "mixed-port: 7890\n")
        defer { fixture.remove() }

        let expected = try await fixture.inspector.fingerprint(at: fixture.url)
        let inspection = await fixture.inspector.inspect(expected: expected)

        #expect(inspection == .matches(expected))
        #expect(inspection.isMatch)
    }

    @Test("Byte changes are detected without rerunning Mihomo validation")
    func changedConfigurationIsDetected() async throws {
        let fixture = try RuntimeConfigurationFixture(contents: "mixed-port: 7890\n")
        defer { fixture.remove() }
        let expected = try await fixture.inspector.fingerprint(at: fixture.url)
        try Data("mixed-port: 7891\n".utf8).write(to: fixture.url, options: .atomic)

        let inspection = await fixture.inspector.inspect(expected: expected)

        guard case let .changed(recorded, actual) = inspection else {
            Issue.record("Expected a changed fingerprint")
            return
        }
        #expect(recorded == expected)
        #expect(actual.sha256 != expected.sha256)
        #expect(!inspection.isMatch)
    }

    @Test("A deleted runtime configuration is reported as missing")
    func missingConfigurationIsDetected() async throws {
        let fixture = try RuntimeConfigurationFixture(contents: "mixed-port: 7890\n")
        defer { fixture.remove() }
        let expected = try await fixture.inspector.fingerprint(at: fixture.url)
        try FileManager.default.removeItem(at: fixture.url)

        #expect(await fixture.inspector.inspect(expected: expected) == .missing(fixture.url))
    }
}

private struct RuntimeConfigurationFixture {
    let root: URL
    let url: URL
    let inspector = RuntimeConfigurationInspector()

    init(contents: String) throws {
        root = URL.temporaryDirectory.appendingPathComponent(
            "Vela-HealthConfigTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("active.yaml")
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
