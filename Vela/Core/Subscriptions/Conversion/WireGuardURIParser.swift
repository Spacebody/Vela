import Foundation

nonisolated struct WireGuardURIParser: ProxyURIParser {
    let schemes: Set<String> = ["wireguard", "wg"]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        let components = try ProxyURIParsingSupport.components(for: uri)
        let endpoint = try ProxyURIParsingSupport.endpoint(from: components, context: context)
        let query = URIQueryValues(components.queryItems ?? [])
        let privateKey = query.first("private-key", "private_key")
        let publicKey = query.first("public-key", "public_key")
        guard privateKey != nil, publicKey != nil else {
            throw SubscriptionConversionError.malformedURI(
                index: context.index,
                reason: "The WireGuard private key or peer public key is missing."
            )
        }
        return SubscriptionProxyNode(
            name: ProxyURIParsingSupport.name(
                fragment: components.fragment,
                fallback: "\(endpoint.server):\(endpoint.port)"
            ),
            server: endpoint.server,
            port: endpoint.port,
            protocolType: .wireGuard,
            authentication: .none,
            udp: true,
            protocolOptions: .wireGuard(
                WireGuardOptions(
                    privateKey: privateKey,
                    publicKey: publicKey,
                    presharedKey: query.first("pre-shared-key", "preshared-key"),
                    ip: query.first("ip"),
                    ipv6: query.first("ipv6"),
                    mtu: query.first("mtu").flatMap(Int.init)
                )
            ),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: components.scheme ?? "wireguard"
            ),
            warnings: [
                .approximatedField(
                    field: "wireguard URI",
                    detail: "WireGuard URI conventions vary between clients; only Mihomo-compatible keys were kept."
                )
            ]
        )
    }
}
