import Foundation

nonisolated struct TrojanURIParser: ProxyURIParser {
    let schemes: Set<String> = ["trojan"]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        let components = try ProxyURIParsingSupport.components(for: uri)
        let endpoint = try ProxyURIParsingSupport.endpoint(from: components, context: context)
        guard let rawPassword = ProxyURIParsingSupport.nonempty(components.user) else {
            throw SubscriptionConversionError.malformedURI(
                index: context.index,
                reason: "The Trojan password is missing."
            )
        }
        let password = rawPassword.removingPercentEncoding ?? rawPassword
        let query = URIQueryValues(components.queryItems ?? [])
        return SubscriptionProxyNode(
            name: ProxyURIParsingSupport.name(
                fragment: components.fragment,
                fallback: "\(endpoint.server):\(endpoint.port)"
            ),
            server: endpoint.server,
            port: endpoint.port,
            protocolType: .trojan,
            authentication: .password(password),
            transport: ProxyURIParsingSupport.transport(query: query),
            tls: ProxyURIParsingSupport.tls(query: query, defaultEnabled: true),
            udp: query.bool("udp"),
            tfo: query.bool("tfo", "fast-open"),
            protocolOptions: .trojan(TrojanOptions(password: password)),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: "trojan"
            )
        )
    }
}
