import Foundation

nonisolated enum SubscriptionContentFormat: String, Codable, CaseIterable, Sendable {
    case mihomoYAML
    case base64NodeList
    case nodeURIList
    case surge
    case singBox
    case unknown

    var displayName: String {
        switch self {
        case .mihomoYAML: "Clash/Mihomo YAML"
        case .base64NodeList: "Base64 node subscription"
        case .nodeURIList: "Proxy URI list"
        case .surge: "Surge configuration"
        case .singBox: "sing-box configuration"
        case .unknown: "Unknown"
        }
    }
}

nonisolated struct SubscriptionContentDetection: Equatable, Sendable {
    var format: SubscriptionContentFormat
    var confidence: Double
    var decodedContent: String?
    var evidence: [String]
}

nonisolated enum ConversionWarning: Hashable, Sendable {
    case unsupportedField(format: String, field: String)
    case approximatedField(field: String, detail: String)
    case duplicateNameRenamed(original: String, renamed: String)
    case unsupportedProtocol(String)
    case invalidNode(index: Int, reason: String)
    case transportDowngraded(from: String, to: String)

    var safeDescription: String {
        switch self {
        case let .unsupportedField(format, field):
            "\(format) field '\(field)' was not imported."
        case let .approximatedField(field, detail):
            "Field '\(field)' was approximated: \(detail)"
        case let .duplicateNameRenamed(original, renamed):
            "Duplicate node name '\(original)' was renamed to '\(renamed)'."
        case let .unsupportedProtocol(value):
            "Protocol '\(value)' is not supported."
        case let .invalidNode(index, reason):
            "Node \(index + 1) was ignored: \(reason)"
        case let .transportDowngraded(from, to):
            "Transport '\(from)' was mapped to '\(to)'."
        }
    }

    var storedValue: StoredConversionWarning {
        switch self {
        case .unsupportedField:
            StoredConversionWarning(kind: "unsupportedField", message: safeDescription)
        case .approximatedField:
            StoredConversionWarning(kind: "approximatedField", message: safeDescription)
        case .duplicateNameRenamed:
            StoredConversionWarning(kind: "duplicateNameRenamed", message: safeDescription)
        case .unsupportedProtocol:
            StoredConversionWarning(kind: "unsupportedProtocol", message: safeDescription)
        case .invalidNode:
            StoredConversionWarning(kind: "invalidNode", message: safeDescription)
        case .transportDowngraded:
            StoredConversionWarning(kind: "transportDowngraded", message: safeDescription)
        }
    }
}

nonisolated struct StoredConversionWarning: Codable, Equatable, Hashable, Sendable {
    var kind: String
    var message: String
}

nonisolated struct RejectedSubscriptionItem: Equatable, Sendable {
    var index: Int
    var safeDescription: String
    var reason: String
}

nonisolated struct SubscriptionConversionMetadata: Equatable, Sendable {
    var sourceDescription: String?
    var importedProxyGroups: Int
    var importedRules: Int

    init(
        sourceDescription: String? = nil,
        importedProxyGroups: Int = 0,
        importedRules: Int = 0
    ) {
        self.sourceDescription = sourceDescription
        self.importedProxyGroups = importedProxyGroups
        self.importedRules = importedRules
    }
}

nonisolated struct SubscriptionConversionResult: Equatable, Sendable {
    var format: SubscriptionContentFormat
    var nodes: [SubscriptionProxyNode]
    var warnings: [ConversionWarning]
    var rejectedItems: [RejectedSubscriptionItem]
    var metadata: SubscriptionConversionMetadata
}

nonisolated struct ConvertedSubscription: Equatable, Sendable {
    var yaml: String
    var detectedFormat: SubscriptionContentFormat
    var nodeCount: Int
    var warnings: [ConversionWarning]
    var rejectedItems: [RejectedSubscriptionItem]
    var convertedLocally: Bool
}

nonisolated struct SubscriptionConversionSummary: Equatable, Sendable {
    var detectedFormat: SubscriptionContentFormat
    var convertedLocally: Bool
    var nodeCount: Int
    var warnings: [StoredConversionWarning]
    var rejectedItemCount: Int

    init(_ converted: ConvertedSubscription) {
        detectedFormat = converted.detectedFormat
        convertedLocally = converted.convertedLocally
        nodeCount = converted.nodeCount
        warnings = converted.warnings.map(\.storedValue)
        rejectedItemCount = converted.rejectedItems.count
    }
}

nonisolated struct SubscriptionConversionLimits: Equatable, Sendable {
    var maximumContentBytes = 20 * 1_024 * 1_024
    var maximumDecodedBytes = 40 * 1_024 * 1_024
    var maximumNodeCount = 10_000
    var maximumLineLength = 64 * 1_024
    var maximumJSONDepth = 64
    var maximumBase64RecursionDepth = 2
    var maximumFieldLength = 64 * 1_024
    var maximumNodeNameLength = 512
}

nonisolated struct SubscriptionConversionOptions: Equatable, Sendable {
    var continueOnInvalidNode = true
    var removeDuplicateNodes = true
    var renameDuplicateNodes = true
    var limits = SubscriptionConversionLimits()
}

/// User-controlled conversion behavior stored with the protected subscription
/// settings. Resource limits remain application-owned and are intentionally
/// not persisted so an older profile cannot weaken limits after an upgrade.
nonisolated struct SubscriptionConversionPreferences: Codable, Equatable, Sendable {
    var continueOnInvalidNode: Bool
    var removeDuplicateNodes: Bool
    var renameDuplicateNodes: Bool

    init(
        continueOnInvalidNode: Bool = true,
        removeDuplicateNodes: Bool = true,
        renameDuplicateNodes: Bool = true
    ) {
        self.continueOnInvalidNode = continueOnInvalidNode
        self.removeDuplicateNodes = removeDuplicateNodes
        self.renameDuplicateNodes = renameDuplicateNodes
    }

    var options: SubscriptionConversionOptions {
        SubscriptionConversionOptions(
            continueOnInvalidNode: continueOnInvalidNode,
            removeDuplicateNodes: removeDuplicateNodes,
            renameDuplicateNodes: renameDuplicateNodes
        )
    }
}

nonisolated struct SubscriptionParsingContext: Equatable, Sendable {
    var sourceURL: URL?
    var options: SubscriptionConversionOptions
    var detectedFormat: SubscriptionContentFormat
}

nonisolated struct URIParsingContext: Equatable, Sendable {
    var index: Int
    var sourceFormat: SubscriptionContentFormat
}

nonisolated struct MihomoEncodingOptions: Equatable, Sendable {
    var includeManagedPolicyScaffold = false
}

nonisolated enum SubscriptionConversionError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case base64DecodeFailed
    case decodedContentInvalidUTF8
    case noSupportedNodes
    case malformedURI(index: Int, reason: String)
    case invalidSurgeConfiguration(String)
    case invalidSingBoxConfiguration(String)
    case conversionProducedInvalidYAML(String)
    case tooManyNodes(limit: Int)
    case contentTooLarge(limit: Int)
    case lineTooLong(limit: Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "The subscription format is not supported."
        case .base64DecodeFailed:
            "The Base64 subscription could not be decoded."
        case .decodedContentInvalidUTF8:
            "The decoded subscription is not valid UTF-8 text."
        case .noSupportedNodes:
            "The content was decoded, but it did not contain any proxy nodes supported by Vela."
        case let .malformedURI(index, reason):
            "Node \(index + 1) is invalid: \(reason)"
        case let .invalidSurgeConfiguration(reason):
            "The Surge configuration could not be converted: \(reason)"
        case let .invalidSingBoxConfiguration(reason):
            "The sing-box configuration could not be converted: \(reason)"
        case let .conversionProducedInvalidYAML(reason):
            "The locally converted Mihomo configuration is invalid: \(reason)"
        case let .tooManyNodes(limit):
            "The subscription contains more than \(limit) nodes."
        case let .contentTooLarge(limit):
            "The subscription exceeds the \(limit)-byte conversion limit."
        case let .lineTooLong(limit):
            "The subscription contains a line longer than \(limit) bytes."
        case .cancelled:
            "The subscription conversion was cancelled."
        }
    }
}

nonisolated protocol SubscriptionContentDetecting: Sendable {
    func detect(_ content: String) -> SubscriptionContentDetection
}

nonisolated protocol SubscriptionContentParser: Sendable {
    var supportedFormat: SubscriptionContentFormat { get }

    func canParse(
        _ content: String,
        detection: SubscriptionContentDetection
    ) -> Bool

    func parse(
        _ content: String,
        context: SubscriptionParsingContext
    ) async throws -> SubscriptionConversionResult
}

nonisolated protocol MihomoYAMLEncoding: Sendable {
    func encode(
        nodes: [SubscriptionProxyNode],
        options: MihomoEncodingOptions
    ) throws -> String
}
