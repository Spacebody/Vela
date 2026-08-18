import Foundation

nonisolated protocol SubscriptionConverting: Sendable {
    func convertToMihomoYAML(
        content: String,
        sourceURL: URL?,
        options: SubscriptionConversionOptions
    ) async throws -> ConvertedSubscription
}

actor SubscriptionConversionService: SubscriptionConverting {
    private let detector: any SubscriptionContentDetecting
    private let parsers: [any SubscriptionContentParser]
    private let normalizer: ProxyNodeNormalizer
    private let encoder: any MihomoYAMLEncoding

    init(
        detector: any SubscriptionContentDetecting = SubscriptionContentDetector(),
        parsers: [any SubscriptionContentParser] = [
            URIListSubscriptionParser(),
            Base64SubscriptionParser(),
            SurgeSubscriptionParser(),
            SingBoxSubscriptionParser(),
        ],
        normalizer: ProxyNodeNormalizer = ProxyNodeNormalizer(),
        encoder: any MihomoYAMLEncoding = MihomoYAMLEncoder()
    ) {
        self.detector = detector
        self.parsers = parsers
        self.normalizer = normalizer
        self.encoder = encoder
    }

    func convertToMihomoYAML(
        content: String,
        sourceURL: URL?,
        options: SubscriptionConversionOptions = SubscriptionConversionOptions()
    ) async throws -> ConvertedSubscription {
        do {
            try Task.checkCancellation()
            guard content.utf8.count <= options.limits.maximumContentBytes else {
                throw SubscriptionConversionError.contentTooLarge(
                    limit: options.limits.maximumContentBytes
                )
            }

            let prepared = Self.preprocess(content)
            if prepared.first == "{" || prepared.first == "[" {
                try SubscriptionJSONDepthValidator.validate(
                    prepared,
                    maximumDepth: options.limits.maximumJSONDepth
                )
            }
            let detection = detector.detect(prepared)
            if detection.format == .mihomoYAML {
                return try Self.validateExistingYAML(prepared)
            }
            guard detection.format != .unknown,
                let parser = parsers.first(where: {
                    $0.supportedFormat == detection.format
                        && $0.canParse(prepared, detection: detection)
                })
            else {
                throw SubscriptionConversionError.unsupportedFormat
            }

            let parsingContext = SubscriptionParsingContext(
                sourceURL: sourceURL,
                options: options,
                detectedFormat: detection.format
            )
            let parsed = try await parser.parse(prepared, context: parsingContext)
            try Task.checkCancellation()
            let normalized = try normalizer.normalize(parsed.nodes, options: options)
            let yaml = try encoder.encode(
                nodes: normalized.nodes,
                options: MihomoEncodingOptions()
            )
            try Self.validateGeneratedYAML(yaml, expectedNodeCount: normalized.nodes.count)
            return ConvertedSubscription(
                yaml: yaml,
                detectedFormat: parsed.format,
                nodeCount: normalized.nodes.count,
                warnings: parsed.warnings + normalized.warnings,
                rejectedItems: parsed.rejectedItems + normalized.rejectedItems,
                convertedLocally: true
            )
        } catch is CancellationError {
            throw SubscriptionConversionError.cancelled
        }
    }

    private static func preprocess(_ content: String) -> String {
        var prepared = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if prepared.unicodeScalars.first == "\u{FEFF}" {
            prepared.removeFirst()
        }
        return prepared.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validateExistingYAML(_ yaml: String) throws -> ConvertedSubscription {
        do {
            let document = try YAMLDocument(yaml: yaml)
            let nodeCount: Int
            if case let .sequence(nodes)? = document["proxies"] {
                nodeCount = nodes.count
            } else {
                nodeCount = 0
            }
            guard nodeCount > 0 || document["proxy-providers"] != nil else {
                throw SubscriptionConversionError.noSupportedNodes
            }
            return ConvertedSubscription(
                yaml: yaml + (yaml.hasSuffix("\n") ? "" : "\n"),
                detectedFormat: .mihomoYAML,
                nodeCount: nodeCount,
                warnings: [],
                rejectedItems: [],
                convertedLocally: false
            )
        } catch let error as SubscriptionConversionError {
            throw error
        } catch {
            throw SubscriptionConversionError.conversionProducedInvalidYAML(
                String(describing: error)
            )
        }
    }

    private static func validateGeneratedYAML(
        _ yaml: String,
        expectedNodeCount: Int
    ) throws {
        do {
            let document = try YAMLDocument(yaml: yaml)
            guard case let .sequence(nodes)? = document["proxies"],
                nodes.count == expectedNodeCount,
                !nodes.isEmpty
            else {
                throw SubscriptionConversionError.conversionProducedInvalidYAML(
                    "The generated proxies collection is missing or incomplete."
                )
            }
        } catch let error as SubscriptionConversionError {
            throw error
        } catch {
            throw SubscriptionConversionError.conversionProducedInvalidYAML(
                String(describing: error)
            )
        }
    }
}
