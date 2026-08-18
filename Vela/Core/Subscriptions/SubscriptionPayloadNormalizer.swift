import Foundation

nonisolated enum SubscriptionPayloadFormat: Equatable, Sendable {
    case mihomoYAML
}

nonisolated struct NormalizedSubscriptionPayload: Equatable, Sendable {
    let yaml: String
    let data: Data
    let format: SubscriptionPayloadFormat
}

/// Performs the deliberately narrow first-stage validation for remote subscriptions.
/// Vela accepts Clash/Mihomo YAML only; protocol URI lists and Base64 subscriptions are
/// rejected with a recovery hint so the user can request YAML from the provider instead.
nonisolated enum SubscriptionPayloadNormalizer {
    static func normalize(
        text: String,
        maximumOutputBytes: Int
    ) throws -> NormalizedSubscriptionPayload {
        let yaml = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SubscriptionUpdateFailure.emptyResponse }

        let document: YAMLDocument
        do {
            document = try YAMLDocument(yaml: trimmed)
        } catch {
            throw SubscriptionUpdateFailure.yamlParsingFailed
        }
        guard document["proxies"] != nil || document["proxy-providers"] != nil else {
            throw SubscriptionUpdateFailure.missingProxySection
        }

        let normalizedYAML = yaml.hasSuffix("\n") ? yaml : yaml + "\n"
        let data = Data(normalizedYAML.utf8)
        guard data.count <= maximumOutputBytes else {
            throw SubscriptionUpdateFailure.responseTooLarge(
                expected: Int64(data.count),
                limit: Int64(maximumOutputBytes)
            )
        }
        return NormalizedSubscriptionPayload(
            yaml: normalizedYAML,
            data: data,
            format: .mihomoYAML
        )
    }
}
