import Foundation

nonisolated struct Base64SubscriptionParser: SubscriptionContentParser {
    let supportedFormat: SubscriptionContentFormat = .base64NodeList
    private let detector: SubscriptionContentDetector
    private let uriParser: URIListSubscriptionParser

    init(
        limits: SubscriptionConversionLimits = SubscriptionConversionLimits(),
        registry: ProxyURIParserRegistry = .standard
    ) {
        detector = SubscriptionContentDetector(limits: limits)
        uriParser = URIListSubscriptionParser(registry: registry)
    }

    func canParse(
        _: String,
        detection: SubscriptionContentDetection
    ) -> Bool {
        detection.format == .base64NodeList
    }

    func parse(
        _ content: String,
        context: SubscriptionParsingContext
    ) async throws -> SubscriptionConversionResult {
        var candidate = content
        for _ in 0 ..< context.options.limits.maximumBase64RecursionDepth {
            try Task.checkCancellation()
            guard let decoded = SubscriptionBase64Decoder.decodeString(
                candidate,
                maximumBytes: context.options.limits.maximumDecodedBytes
            ) else {
                throw SubscriptionConversionError.base64DecodeFailed
            }
            let detection = detector.detect(decoded)
            if detection.format == .nodeURIList {
                var result = try await uriParser.parse(
                    decoded,
                    context: SubscriptionParsingContext(
                        sourceURL: context.sourceURL,
                        options: context.options,
                        detectedFormat: .base64NodeList
                    )
                )
                result.format = .base64NodeList
                return result
            }
            if detection.format == .base64NodeList {
                candidate = decoded
                continue
            }
            throw SubscriptionConversionError.noSupportedNodes
        }
        throw SubscriptionConversionError.noSupportedNodes
    }
}
