import Foundation

nonisolated struct HysteriaURIParser: ProxyURIParser {
    let schemes: Set<String> = ["hysteria"]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        let components = try ProxyURIParsingSupport.components(for: uri)
        let endpoint = try ProxyURIParsingSupport.endpoint(from: components, context: context)
        let query = URIQueryValues(components.queryItems ?? [])
        let authentication = components.user?.removingPercentEncoding
            ?? query.first("auth", "auth-str", "auth_str")
        let tls = ProxyTLSOptions(
            enabled: true,
            serverName: query.first("sni", "peer"),
            skipCertificateVerification: query.bool("insecure", "skip-cert-verify"),
            alpn: ProxyURIParsingSupport.list(query.first("alpn")),
            fingerprint: query.first("fingerprint"),
            clientFingerprint: query.first("fp"),
            reality: nil
        )
        return SubscriptionProxyNode(
            name: ProxyURIParsingSupport.name(
                fragment: components.fragment,
                fallback: "\(endpoint.server):\(endpoint.port)"
            ),
            server: endpoint.server,
            port: endpoint.port,
            protocolType: .hysteria,
            authentication: authentication.map(ProxyAuthentication.password) ?? .none,
            tls: tls,
            udp: true,
            protocolOptions: .hysteria(
                HysteriaOptions(
                    authentication: authentication,
                    protocolName: query.first("protocol"),
                    obfuscation: query.first("obfs"),
                    upstream: query.first("up", "upmbps"),
                    downstream: query.first("down", "downmbps"),
                    ports: query.first("ports", "mport")
                )
            ),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: "hysteria"
            )
        )
    }
}
