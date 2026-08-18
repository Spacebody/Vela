import Foundation
import Testing
@testable import VelaPrivilegedCore

@Suite("Safe relative paths")
struct SafeRelativePathTests {
    @Test("Accepts a narrow resource path")
    func acceptsSafePath() throws {
        let path = try SafeRelativePath("providers/proxies-01.yaml")
        #expect(path.components == ["providers", "proxies-01.yaml"])
        #expect(path.description == "providers/proxies-01.yaml")
    }

    @Test(
        "Rejects traversal and ambiguous paths",
        arguments: [
            "", "/etc/passwd", "../etc/passwd", "a/../b", "a/./b", "a//b",
            "a/", "a\0b", "provider/密钥.yaml", "provider/$value.yaml",
        ]
    )
    func rejectsUnsafePath(_ value: String) {
        #expect(throws: SafeRelativePathError.self) {
            _ = try SafeRelativePath(value)
        }
    }

    @Test("Codable decoding re-runs validation and cannot inject components")
    func decodingCannotBypassValidation() throws {
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(SafeRelativePath.self, from: Data(#""../escape""#.utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(
                SafeRelativePath.self,
                from: Data(#"{"components":["..","escape"]}"#.utf8)
            )
        }
        let valid = try decoder.decode(
            SafeRelativePath.self,
            from: Data(#""resources/provider.yaml""#.utf8)
        )
        #expect(valid.description == "resources/provider.yaml")
        #expect(
            try decoder.decode(
                SafeRelativePath.self,
                from: JSONEncoder().encode(valid)
            ) == valid
        )
    }
}
