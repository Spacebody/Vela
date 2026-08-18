import Foundation

nonisolated struct Hysteria2URIParser: ProxyURIParser {
    let schemes: Set<String> = ["hysteria2", "hy2"]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        let components = try ProxyURIParsingSupport.components(for: uri)
        let endpoint = try ProxyURIParsingSupport.endpoint(from: components, context: context)
        guard let rawPassword = ProxyURIParsingSupport.nonempty(components.user) else {
            throw SubscriptionConversionError.malformedURI(
                index: context.index,
                reason: "The Hysteria2 authentication string is missing."
            )
        }
        let password = rawPassword.removingPercentEncoding ?? rawPassword
        let query = URIQueryValues(components.queryItems ?? [])
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
            protocolType: .hysteria2,
            authentication: .password(password),
            tls: tls,
            udp: query.bool("udp") ?? true,
            tfo: query.bool("tfo", "fast-open"),
            protocolOptions: .hysteria2(
                Hysteria2Options(
                    password: password,
                    obfuscation: query.first("obfs"),
                    obfuscationPassword: query.first("obfs-password", "obfs_password"),
                    upstream: query.first("up", "upmbps"),
                    downstream: query.first("down", "downmbps"),
                    ports: query.first("ports", "mport")
                )
            ),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: components.scheme ?? "hysteria2"
            )
        )
    }
}
