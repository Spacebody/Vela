import CryptoKit
import Foundation

nonisolated enum ReliabilityCrashComponent: String, CaseIterable, Codable, Sendable {
    case velaApp
    case helper
    case cli
    case mihomo
    case sparkle
    case updateRecovery
    case coreRecovery
    case migration
    case testHarness
}

nonisolated enum ReliabilityCrashException: String, CaseIterable, Codable, Sendable {
    case excBadAccess = "EXC_BAD_ACCESS"
    case excBadInstruction = "EXC_BAD_INSTRUCTION"
    case excArithmetic = "EXC_ARITHMETIC"
    case excBreakpoint = "EXC_BREAKPOINT"
    case sigAbort = "SIGABRT"
    case sigBus = "SIGBUS"
    case sigIll = "SIGILL"
    case sigSegv = "SIGSEGV"
    case uncaughtException = "UNCAUGHT_EXCEPTION"
    case watchdog = "WATCHDOG"
    case resourceLimit = "RESOURCE_LIMIT"
    case unknown = "UNKNOWN"
}

nonisolated enum ReliabilityCrashCategory: String, CaseIterable, Codable, Sendable {
    case launch
    case stateTransition
    case xpc
    case configuration
    case ui
    case update
    case core
    case migration
    case resourceExhaustion
    case upstreamMihomo
    case unknown
}

/// A symbol-only application frame. Addresses, paths, whitespace, and arbitrary text are rejected.
nonisolated struct ReliabilityCrashApplicationFrame: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        let lowercased = rawValue.lowercased()
        let forbiddenFragments = [
            "authorization", "bearer", "bssid", "http", "password", "privatekey",
            "secret", "ssid", "token", "users",
        ]
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 160,
              rawValue.utf8.allSatisfy(Self.isAllowedSymbolByte),
              rawValue.utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) }),
              rawValue.contains(".") || rawValue.contains("::"),
              !lowercased.hasPrefix("0x"),
              !forbiddenFragments.contains(where: lowercased.contains)
        else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let validated = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid application frame"
            )
        }
        self = validated
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isAllowedSymbolByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
            || [0x24, 0x2b, 0x2d, 0x2e, 0x3a, 0x3c, 0x3e, 0x5f].contains(byte)
    }
}

nonisolated struct ReliabilityCrashSignature: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumFrameCount = 8

    let schemaVersion: Int
    let component: ReliabilityCrashComponent
    let category: ReliabilityCrashCategory
    let identity: ReliabilityBuildIdentity
    let exception: ReliabilityCrashException
    let topApplicationFrames: [ReliabilityCrashApplicationFrame]
    let signatureSHA256: ReliabilitySHA256
    let containsUserData: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case component
        case category
        case identity
        case exception
        case topApplicationFrames
        case signatureSHA256
        case containsUserData
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        component = try container.decode(ReliabilityCrashComponent.self, forKey: .component)
        category = try container.decode(ReliabilityCrashCategory.self, forKey: .category)
        identity = try container.decode(ReliabilityBuildIdentity.self, forKey: .identity)
        exception = try container.decode(ReliabilityCrashException.self, forKey: .exception)
        topApplicationFrames = try container.decode(
            [ReliabilityCrashApplicationFrame].self,
            forKey: .topApplicationFrames
        )
        signatureSHA256 = try container.decode(ReliabilitySHA256.self, forKey: .signatureSHA256)
        containsUserData = try container.decode(Bool.self, forKey: .containsUserData)
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid crash signature"
                )
            )
        }
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              identity.build > 0,
              !topApplicationFrames.isEmpty,
              topApplicationFrames.count <= Self.maximumFrameCount,
              !containsUserData,
              Self.computeHash(
                  component: component,
                  category: category,
                  identity: identity,
                  exception: exception,
                  frames: topApplicationFrames
              ) == signatureSHA256
        else {
            throw ReliabilityCrashSignatureError.invalidSignature
        }
    }

    private static func computeHash(
        component: ReliabilityCrashComponent,
        category: ReliabilityCrashCategory,
        identity: ReliabilityBuildIdentity,
        exception: ReliabilityCrashException,
        frames: [ReliabilityCrashApplicationFrame]
    ) -> ReliabilitySHA256 {
        let canonical = ([
            "schema=1",
            "component=\(component.rawValue)",
            "category=\(category.rawValue)",
            "version=\(identity.version.rawValue)",
            "build=\(identity.build)",
            "exception=\(exception.rawValue)",
        ] + frames.map { "frame=\($0.rawValue)" }).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        // CryptoKit SHA-256 always emits exactly 64 lower-case hexadecimal characters.
        return ReliabilitySHA256(cryptographicDigest: digest)
    }

    fileprivate init(
        component: ReliabilityCrashComponent,
        category: ReliabilityCrashCategory,
        identity: ReliabilityBuildIdentity,
        exception: ReliabilityCrashException,
        topApplicationFrames: [ReliabilityCrashApplicationFrame]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.component = component
        self.category = category
        self.identity = identity
        self.exception = exception
        self.topApplicationFrames = Array(topApplicationFrames.prefix(Self.maximumFrameCount))
        signatureSHA256 = Self.computeHash(
            component: component,
            category: category,
            identity: identity,
            exception: exception,
            frames: self.topApplicationFrames
        )
        containsUserData = false
    }
}

nonisolated enum ReliabilityCrashSignatureBuilder {
    static func make(
        component: ReliabilityCrashComponent,
        category: ReliabilityCrashCategory,
        identity: ReliabilityBuildIdentity,
        exception: ReliabilityCrashException,
        topApplicationFrames: [ReliabilityCrashApplicationFrame]
    ) throws -> ReliabilityCrashSignature {
        guard !topApplicationFrames.isEmpty else {
            throw ReliabilityCrashSignatureError.noApplicationFrames
        }
        guard topApplicationFrames.count <= ReliabilityCrashSignature.maximumFrameCount else {
            throw ReliabilityCrashSignatureError.tooManyApplicationFrames
        }
        let signature = ReliabilityCrashSignature(
            component: component,
            category: category,
            identity: identity,
            exception: exception,
            topApplicationFrames: topApplicationFrames
        )
        try signature.validate()
        return signature
    }
}

nonisolated struct ReliabilityCrashSignatureOccurrence: Codable, Equatable, Sendable {
    let signature: ReliabilityCrashSignature
    let count: Int
}

nonisolated enum ReliabilityCrashSignatureDeduplicator {
    static func group(
        _ signatures: [ReliabilityCrashSignature]
    ) -> [ReliabilityCrashSignatureOccurrence] {
        var grouped: [ReliabilitySHA256: (ReliabilityCrashSignature, Int)] = [:]
        for signature in signatures {
            if let existing = grouped[signature.signatureSHA256] {
                grouped[signature.signatureSHA256] = (existing.0, existing.1 + 1)
            } else {
                grouped[signature.signatureSHA256] = (signature, 1)
            }
        }
        return grouped.values
            .map { ReliabilityCrashSignatureOccurrence(signature: $0.0, count: $0.1) }
            .sorted { $0.signature.signatureSHA256.rawValue < $1.signature.signatureSHA256.rawValue }
    }
}

nonisolated enum ReliabilityCrashSignatureError: Error, Equatable, Sendable {
    case noApplicationFrames
    case tooManyApplicationFrames
    case invalidSignature
}

extension ReliabilitySHA256 {
    /// Only a CryptoKit SHA-256 digest reaches this initializer.
    nonisolated fileprivate init(cryptographicDigest: String) {
        rawValue = cryptographicDigest
    }
}
