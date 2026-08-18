import Testing
@testable import Vela

@Suite("YAML document deep editing")
struct YAMLDocumentTests {
    @Test("Deep set creates missing mappings and preserves siblings")
    func deepSetPreservesSiblings() throws {
        var document = try YAMLDocument(
            yaml: """
            dns:
              enable: false
              unknown-option:
                nested: keep-me
            mode: rule
            """
        )

        try document.setValue(.bool(true), at: ["dns", "ipv6"])
        try document.setValue(.integer(443), at: ["sniffer", "sniff", "TLS", "port"])

        #expect(try document.value(at: ["dns", "enable"]) == .bool(false))
        #expect(
            try document.value(at: ["dns", "unknown-option", "nested"])
                == .string("keep-me")
        )
        #expect(try document.value(at: ["dns", "ipv6"]) == .bool(true))
        #expect(
            try document.value(at: ["sniffer", "sniff", "TLS", "port"])
                == .integer(443)
        )
        #expect(document["mode"] == .string("rule"))
    }

    @Test("Deep remove deletes the key rather than writing YAML null")
    func deepRemoveDeletesKey() throws {
        var document = try YAMLDocument(
            yaml: """
            dns:
              enable: true
              ipv6: true
            """
        )

        let removed = try document.removeValue(at: ["dns", "ipv6"])
        let serialized = try document.serialized()
        let reparsed = try YAMLDocument(yaml: serialized)

        #expect(removed == .bool(true))
        #expect(try reparsed.value(at: ["dns", "ipv6"]) == nil)
        #expect(try reparsed.value(at: ["dns", "enable"]) == .bool(true))
        #expect(!serialized.contains("ipv6: null"))
        #expect(try document.removeValue(at: ["dns", "missing"]) == nil)
    }

    @Test("Deep editing rejects traversal through a scalar")
    func rejectsScalarTraversal() throws {
        var document = try YAMLDocument(yaml: "dns: disabled\n")

        #expect(throws: YAMLDocumentError.pathComponentIsNotMapping(path: "dns")) {
            try document.setValue(.bool(true), at: ["dns", "enable"])
        }
        #expect(throws: YAMLDocumentError.pathComponentIsNotMapping(path: "dns")) {
            try document.removeValue(at: ["dns", "enable"])
        }
        #expect(throws: YAMLDocumentError.pathComponentIsNotMapping(path: "dns")) {
            try document.value(at: ["dns", "enable"])
        }
    }

    @Test("Empty and malformed paths are rejected")
    func rejectsMalformedPaths() throws {
        var document = try YAMLDocument(yaml: "mode: rule\n")

        #expect(throws: YAMLDocumentError.emptyPath) {
            try document.setValue(.bool(true), at: [])
        }
        #expect(
            throws: YAMLDocumentError.emptyPathComponent(path: ["dns", ""])
        ) {
            try document.removeValue(at: ["dns", ""])
        }
    }
}
