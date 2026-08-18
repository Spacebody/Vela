import Foundation
import VelaIPC

/// A path which is safe to resolve relative to an already-open directory descriptor.
///
/// The privileged component intentionally accepts a narrower grammar than APFS.
/// Resource destinations are machine-generated identifiers, so accepting control
/// characters, Unicode normalization variants, or shell metacharacters creates risk
/// without adding product value.
public struct SafeRelativePath: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let maximumComponentCount = 32
    public static let maximumComponentBytes = 255
    public static let maximumPathBytes = 4_096

    public let components: [String]

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw SafeRelativePathError.empty
        }
        guard rawValue.utf8.count <= Self.maximumPathBytes else {
            throw SafeRelativePathError.pathTooLong
        }
        guard !rawValue.utf8.contains(0) else {
            throw SafeRelativePathError.nulByte
        }
        guard !rawValue.hasPrefix("/") else {
            throw SafeRelativePathError.absolute
        }

        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count <= Self.maximumComponentCount else {
            throw SafeRelativePathError.tooManyComponents
        }

        for component in components {
            guard !component.isEmpty else {
                throw SafeRelativePathError.emptyComponent
            }
            guard component != ".", component != ".." else {
                throw SafeRelativePathError.traversal
            }
            guard component.utf8.count <= Self.maximumComponentBytes else {
                throw SafeRelativePathError.componentTooLong
            }
            guard component.unicodeScalars.allSatisfy(Self.isAllowed) else {
                throw SafeRelativePathError.unsupportedCharacter
            }
        }

        self.components = components
    }

    public init(components: [String]) throws {
        try self.init(components.joined(separator: "/"))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid privileged relative path."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        components.joined(separator: "/")
    }

    public var deletingLastComponent: SafeRelativePath? {
        guard components.count > 1 else { return nil }
        return try? SafeRelativePath(components: Array(components.dropLast()))
    }

    public var lastComponent: String {
        components[components.count - 1]
    }

    public func appending(_ component: String) throws -> SafeRelativePath {
        try SafeRelativePath(components: components + [component])
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 46, 48...57, 65...90, 95, 97...122:
            true
        default:
            false
        }
    }
}

public enum SafeRelativePathError: Error, Equatable, Sendable {
    case empty
    case absolute
    case nulByte
    case emptyComponent
    case traversal
    case componentTooLong
    case tooManyComponents
    case pathTooLong
    case unsupportedCharacter
}

extension SafeRelativePathError: LocalizedError {
    public var errorDescription: String? {
        // Keep this deliberately generic. A rejected attacker-controlled path must
        // never be echoed into an NSError, diagnostics export, or root OSLog entry.
        "The privileged resource path is unsafe."
    }
}

extension SafeRelativePathError {
    public var helperFailure: VelaHelperFailure {
        VelaHelperFailure(
            code: .unsafePath,
            safeMessage: "The privileged resource path is unsafe."
        )
    }
}
