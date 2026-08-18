import Foundation

nonisolated struct TUICURIParser: ProxyURIParser {
    let schemes: Set<String> = ["tuic"]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        let components = try ProxyURIParsingSupport.components(for: uri)
        let endpoint = try ProxyURIParsingSupport.endpoint(from: components, context: context)
        guard let rawUUID = ProxyURIParsingSupport.nonempty(components.user) else {
            throw malformed(context, "The TUIC UUID is missing.")
        }
        guard let rawPassword = ProxyURIParsingSupport.nonempty(components.password) else {
            throw malformed(context, "The TUIC password is missing.")
        }
        let uuid = rawUUID.removingPercentEncoding ?? rawUUID
        let password = rawPassword.removingPercentEncoding ?? rawPassword
        let query = URIQueryValues(components.queryItems ?? [])
        let tls = ProxyTLSOptions(
            enabled: true,
            serverName: query.first("sni", "server_name"),
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
            protocolType: .tuic,
            authentication: .uuid(uuid),
            tls: tls,
            udp: true,
            protocolOptions: .tuic(
                TUICOptions(
                    uuid: uuid,
                    password: password,
                    token: query.first("token"),
                    congestionController: query.first(
                        "congestion_control",
                        "congestion-controller"
                    ),
                    udpRelayMode: query.first("udp_relay_mode", "udp-relay-mode"),
                    heartbeatInterval: query.first("heartbeat_interval", "heartbeat-interval")
                        .flatMap(Int.init)
                )
            ),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: "tuic"
            )
        )
    }

    private func malformed(
        _ context: URIParsingContext,
        _ reason: String
    ) -> SubscriptionConversionError {
        .malformedURI(index: context.index, reason: reason)
    }
}
