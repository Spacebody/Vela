import Foundation
import Testing
@testable import Vela

@Suite("RFC 6901 YAML Pointer")
struct YAMLPointerTests {
    @Test("Escaped slash and tilde round-trip")
    func escapedComponentsRoundTrip() throws {
        let pointer = try YAMLPointer("/dns/a~1b/~0token/")
        #expect(pointer.components == ["dns", "a/b", "~token", ""])
        #expect(YAMLPointer(components: pointer.components).rawValue == pointer.rawValue)
    }

    @Test("Empty pointer represents the read-only root")
    func emptyPointerIsRoot() throws {
        let pointer = try YAMLPointer("")
        #expect(pointer.isRoot)
        #expect(pointer.components.isEmpty)
    }

    @Test("Malformed pointers fail instead of normalizing")
    func malformedPointersFail() {
        #expect(throws: YAMLPointerError.mustStartWithSlash("dns/enable")) {
            try YAMLPointer("dns/enable")
        }
        #expect(throws: YAMLPointerError.invalidEscape("/dns/~2")) {
            try YAMLPointer("/dns/~2")
        }
        #expect(throws: YAMLPointerError.invalidEscape("/dns/~")) {
            try YAMLPointer("/dns/~")
        }
    }

    @Test("Codable representation is the pointer string")
    func codableRoundTrip() throws {
        let pointer = try YAMLPointer("/proxy-groups/0")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(pointer)
        #expect(String(decoding: data, as: UTF8.self) == "\"/proxy-groups/0\"")
        #expect(try JSONDecoder().decode(YAMLPointer.self, from: data) == pointer)
    }
}
