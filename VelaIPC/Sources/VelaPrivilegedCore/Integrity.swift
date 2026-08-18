import CryptoKit
import Foundation

public enum IntegrityValue {
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func normalizedSHA256(_ value: String) throws -> String {
        let normalized = value.lowercased()
        guard normalized.utf8.count == 64,
            normalized.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            })
        else {
            throw IntegrityValueError.invalidSHA256
        }
        return normalized
    }
}

public enum IntegrityValueError: Error, Equatable, Sendable {
    case invalidSHA256
}
