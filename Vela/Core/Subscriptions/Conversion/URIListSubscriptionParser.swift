import Foundation

nonisolated struct URIListSubscriptionParser: SubscriptionContentParser {
    let supportedFormat: SubscriptionContentFormat = .nodeURIList
    private let registry: ProxyURIParserRegistry

    init(registry: ProxyURIParserRegistry = .standard) {
        self.registry = registry
    }

    func canParse(
        _: String,
        detection: SubscriptionContentDetection
    ) -> Bool {
        detection.format == .nodeURIList
    }

    func parse(
        _ content: String,
        context: SubscriptionParsingContext
    ) async throws -> SubscriptionConversionResult {
        let candidates = try candidates(
            in: content,
            maximumLineLength: context.options.limits.maximumLineLength
        )
        var nodes: [SubscriptionProxyNode] = []
        var warnings: [ConversionWarning] = []
        var rejected: [RejectedSubscriptionItem] = []

        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            guard let separator = candidate.range(of: "://") else {
                let reason = "The line is not a supported proxy URI."
                warnings.append(.invalidNode(index: index, reason: reason))
                rejected.append(
                    RejectedSubscriptionItem(
                        index: index,
                        safeDescription: "node \(index + 1)",
                        reason: reason
                    )
                )
                if !context.options.continueOnInvalidNode {
                    throw SubscriptionConversionError.malformedURI(index: index, reason: reason)
                }
                continue
            }
            let scheme = String(candidate[..<separator.lowerBound]).lowercased()
            guard let parser = registry.parser(for: scheme) else {
                let warning = ConversionWarning.unsupportedProtocol(scheme)
                warnings.append(warning)
                rejected.append(
                    RejectedSubscriptionItem(
                        index: index,
                        safeDescription: "\(scheme) node \(index + 1)",
                        reason: warning.safeDescription
                    )
                )
                continue
            }
            do {
                let node = try parser.parse(
                    candidate,
                    context: URIParsingContext(
                        index: index,
                        sourceFormat: context.detectedFormat
                    )
                )
                nodes.append(node)
                warnings.append(contentsOf: node.warnings)
            } catch let error as SubscriptionConversionError {
                let reason = error.errorDescription ?? "The node is invalid."
                warnings.append(.invalidNode(index: index, reason: reason))
                rejected.append(
                    RejectedSubscriptionItem(
                        index: index,
                        safeDescription: "\(scheme) node \(index + 1)",
                        reason: reason
                    )
                )
                if !context.options.continueOnInvalidNode { throw error }
            } catch {
                let reason = "The node could not be parsed."
                warnings.append(.invalidNode(index: index, reason: reason))
                rejected.append(
                    RejectedSubscriptionItem(
                        index: index,
                        safeDescription: "\(scheme) node \(index + 1)",
                        reason: reason
                    )
                )
                if !context.options.continueOnInvalidNode {
                    throw SubscriptionConversionError.malformedURI(index: index, reason: reason)
                }
            }
            guard nodes.count <= context.options.limits.maximumNodeCount else {
                throw SubscriptionConversionError.tooManyNodes(
                    limit: context.options.limits.maximumNodeCount
                )
            }
        }
        guard !nodes.isEmpty else { throw SubscriptionConversionError.noSupportedNodes }
        return SubscriptionConversionResult(
            format: context.detectedFormat,
            nodes: nodes,
            warnings: warnings,
            rejectedItems: rejected,
            metadata: SubscriptionConversionMetadata(
                sourceDescription: "Local URI conversion"
            )
        )
    }

    private func candidates(
        in content: String,
        maximumLineLength: Int
    ) throws -> [String] {
        var result: [String] = []
        for rawLine in content.split(whereSeparator: \.isNewline) {
            guard rawLine.utf8.count <= maximumLineLength else {
                throw SubscriptionConversionError.lineTooLong(limit: maximumLineLength)
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if let direct = tokens.first(where: { $0.contains("://") }) {
                result.append(direct)
            } else {
                result.append(line)
            }
        }
        return result
    }
}
