import Foundation
import Testing
@testable import Vela

@Suite("Runtime configuration builder")
struct RuntimeConfigBuilderTests {
    private let sourceYAML = """
    mixed-port: 7890
    external-controller: 127.0.0.1:9090
    secret: old-secret
    mode: rule
    proxies:
      - name: DIRECT-TEST
        type: direct
    proxy-groups:
      - name: PROXY
        type: select
        proxies:
          - DIRECT-TEST
          - DIRECT
    rules:
      - MATCH,PROXY
    """

    @Test("Managed runtime fields are injected while other YAML remains")
    func injectsManagedFields() throws {
        let parameters = RuntimeConfigParameters(
            externalController: "127.0.0.1:19090",
            secret: "test-runtime-secret",
            mixedPort: 17890
        )

        let output = try RuntimeConfigBuilder().build(
            from: sourceYAML,
            parameters: parameters
        )
        let document = try YAMLDocument(yaml: output)

        #expect(document["external-controller"] == .string("127.0.0.1:19090"))
        #expect(document["secret"] == .string("test-runtime-secret"))
        #expect(document["mixed-port"] == .integer(17890))
        #expect(document["mode"] == .string("rule"))
        #expect(document["proxies"] != nil)
        #expect(document["rules"] != nil)
    }

    @Test("Managed IPv6 preference overrides the source configuration")
    func injectsManagedIPv6Preference() throws {
        let output = try RuntimeConfigBuilder().build(
            from: "ipv6: false\n" + sourceYAML,
            parameters: RuntimeConfigParameters(
                externalController: "127.0.0.1:19090",
                secret: "test-runtime-secret",
                mixedPort: 17890,
                ipv6: true
            )
        )

        let document = try YAMLDocument(yaml: output)
        #expect(document["ipv6"] == .bool(true))
    }

    @Test("Writing active.yaml never modifies the imported source")
    func leavesSourceUntouched() throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let source = try ConfigurationTestSupport.write(
            sourceYAML,
            named: "source.yaml",
            in: temporaryDirectory
        )
        let originalData = try Data(contentsOf: source)
        let destination = temporaryDirectory
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("active.yaml", isDirectory: false)

        try RuntimeConfigBuilder().writeRuntimeConfiguration(
            from: source,
            to: destination,
            parameters: RuntimeConfigParameters(
                externalController: "127.0.0.1:19090",
                secret: "test-runtime-secret",
                mixedPort: 17890
            )
        )

        #expect(try Data(contentsOf: source) == originalData)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: destination) != originalData)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let filePermissions = try #require(fileAttributes[.posixPermissions] as? NSNumber)
        #expect(filePermissions.intValue & 0o777 == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: destination.deletingLastPathComponent().path
        )
        let directoryPermissions = try #require(
            directoryAttributes[.posixPermissions] as? NSNumber
        )
        #expect(directoryPermissions.intValue & 0o777 == 0o700)
    }

    @Test("Invalid inputs return structured errors")
    func invalidInputsAreStructured() throws {
        do {
            _ = try RuntimeConfigBuilder().build(
                from: Data([0xFF, 0xFE]),
                parameters: RuntimeConfigParameters(
                    externalController: "127.0.0.1:19090",
                    secret: "test-secret",
                    mixedPort: 17890
                )
            )
            Issue.record("Expected non-UTF-8 data to fail")
        } catch let error as RuntimeConfigBuilderError {
            #expect(error == .sourceIsNotUTF8)
        }

        do {
            _ = try RuntimeConfigBuilder().build(
                from: "- not\n- a\n- mapping\n",
                parameters: RuntimeConfigParameters(
                    externalController: "127.0.0.1:19090",
                    secret: "test-secret",
                    mixedPort: 17890
                )
            )
            Issue.record("Expected a non-mapping YAML root to fail")
        } catch let error as RuntimeConfigBuilderError {
            #expect(error == .invalidYAML(.rootIsNotMapping))
        }
    }
}
