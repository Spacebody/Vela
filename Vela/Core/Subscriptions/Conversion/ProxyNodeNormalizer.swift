import Foundation

nonisolated struct NodeNormalizationResult: Equatable, Sendable {
    var nodes: [SubscriptionProxyNode]
    var warnings: [ConversionWarning]
    var rejectedItems: [RejectedSubscriptionItem]
}

nonisolated struct ProxyNodeNormalizer: Sendable {
    func normalize(
        _ input: [SubscriptionProxyNode],
        options: SubscriptionConversionOptions
    ) throws -> NodeNormalizationResult {
        guard input.count <= options.limits.maximumNodeCount else {
            throw SubscriptionConversionError.tooManyNodes(
                limit: options.limits.maximumNodeCount
            )
        }
        var nodes: [SubscriptionProxyNode] = []
        var warnings: [ConversionWarning] = []
        var rejected: [RejectedSubscriptionItem] = []
        var fingerprints: Set<ProxyNodeFingerprint> = []
        var usedNames: [String: Int] = [:]

        for (index, var node) in input.enumerated() {
            let invalidReason = validationFailure(for: node)
            if let invalidReason {
                warnings.append(.invalidNode(index: index, reason: invalidReason))
                rejected.append(
                    RejectedSubscriptionItem(
                        index: index,
                        safeDescription: node.source.safeDescription,
                        reason: invalidReason
                    )
                )
                if !options.continueOnInvalidNode {
                    throw SubscriptionConversionError.malformedURI(
                        index: index,
                        reason: invalidReason
                    )
                }
                continue
            }
            node.name = ProxyURIParsingSupport.name(
                fragment: node.name,
                fallback: "\(node.server):\(node.port)",
                maximumLength: options.limits.maximumNodeNameLength
            )
            let fingerprint = ProxyNodeFingerprint(node)
            if options.removeDuplicateNodes, !fingerprints.insert(fingerprint).inserted {
                continue
            }
            if options.renameDuplicateNodes {
                let occurrence = (usedNames[node.name] ?? 0) + 1
                usedNames[node.name] = occurrence
                if occurrence > 1 {
                    let original = node.name
                    var suffix = occurrence
                    var renamed = "\(original) \(suffix)"
                    while usedNames[renamed] != nil {
                        suffix += 1
                        renamed = "\(original) \(suffix)"
                    }
                    node.name = renamed
                    usedNames[renamed] = 1
                    warnings.append(
                        .duplicateNameRenamed(original: original, renamed: renamed)
                    )
                }
            }
            nodes.append(node)
        }
        guard !nodes.isEmpty else { throw SubscriptionConversionError.noSupportedNodes }
        return NodeNormalizationResult(
            nodes: nodes,
            warnings: warnings,
            rejectedItems: rejected
        )
    }

    private func validationFailure(for node: SubscriptionProxyNode) -> String? {
        guard !node.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "The server is missing."
        }
        guard (1 ... 65_535).contains(node.port) else {
            return "The port is outside 1...65535."
        }
        switch node.protocolOptions {
        case let .shadowsocks(options):
            if options.cipher.isEmpty || options.password.isEmpty {
                return "The Shadowsocks cipher or password is missing."
            }
        case let .shadowsocksR(options):
            if options.password.isEmpty || options.protocolName.isEmpty {
                return "The SSR authentication or protocol is missing."
            }
        case let .vmess(options):
            if options.uuid.isEmpty { return "The VMess UUID is missing." }
        case let .vless(options):
            if options.uuid.isEmpty { return "The VLESS UUID is missing." }
        case let .trojan(options):
            if options.password.isEmpty { return "The Trojan password is missing." }
        case let .hysteria2(options):
            if options.password.isEmpty { return "The Hysteria2 authentication is missing." }
        case let .tuic(options):
            if options.uuid.isEmpty || options.password.isEmpty {
                return "The TUIC UUID or password is missing."
            }
        case let .ssh(options):
            if options.username.isEmpty { return "The SSH username is missing." }
        case .hysteria, .wireGuard, .socks5, .http:
            break
        }
        return nil
    }
}

nonisolated private struct ProxyNodeFingerprint: Hashable, Sendable {
    var protocolType: ProxyProtocol
    var server: String
    var port: Int
    var authentication: ProxyAuthentication
    var transport: ProxyTransport?
    var tls: ProxyTLSOptions?
    var protocolOptions: ProxyProtocolOptions

    init(_ node: SubscriptionProxyNode) {
        protocolType = node.protocolType
        server = node.server.lowercased()
        port = node.port
        authentication = node.authentication
        transport = node.transport
        tls = node.tls
        protocolOptions = node.protocolOptions
    }
}
