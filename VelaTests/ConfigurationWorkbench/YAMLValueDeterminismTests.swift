import Foundation
import Testing
@testable import Vela

@Suite("Ordered YAML value model")
struct YAMLValueDeterminismTests {
    @Test("Mappings sort keys and Codable round-trips every value kind")
    func codableRoundTrip() throws {
        let value = YAMLValue.mapping([
            "z": .null,
            "a": .sequence([
                .bool(true),
                .integer(42),
                .floatingPoint(1.25),
                .floatingPoint(1.0),
                .string("hello"),
            ]),
        ])
        guard case let .mapping(mapping) = value else {
            Issue.record("Expected a mapping")
            return
        }
        #expect(mapping.keys == ["a", "z"])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        #expect(try JSONDecoder().decode(YAMLValue.self, from: data) == value)
        #expect(try encoder.encode(YAMLValue.integer(1)) != encoder.encode(YAMLValue.floatingPoint(1.0)))
    }

    @Test("YAML serialization is byte-identical across repeated runs")
    func deterministicSerialization() throws {
        let source = """
        zeta: value
        alpha:
          z: 1
          a: 2
        unicode: 你好
        """
        let document = try YAMLDocument(yaml: source)
        let outputs = try Set((0..<100).map { _ in try document.serialized() })
        #expect(outputs.count == 1)
        #expect(outputs.first?.contains("你好") == true)
    }

    @Test("Non-finite YAML numbers fail closed")
    func nonFiniteNumbersFail() {
        #expect(throws: YAMLDocumentError.self) {
            try YAMLDocument(yaml: "value: .nan\n")
        }
        #expect(throws: YAMLDocumentError.self) {
            try YAMLDocument(yaml: "value: .inf\n")
        }
    }

    @Test("Duplicate mapping keys fail instead of silently choosing one")
    func duplicateKeysFail() {
        #expect(throws: YAMLDocumentError.self) {
            try YAMLDocument(yaml: "mode: rule\nmode: direct\n")
        }
    }
}
