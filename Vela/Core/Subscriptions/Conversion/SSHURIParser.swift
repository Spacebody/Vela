import Foundation

nonisolated struct SSHURIParser: ProxyURIParser {
    let schemes: Set<String> = ["ssh"]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        let components = try ProxyURIParsingSupport.components(for: uri)
        let endpoint = try ProxyURIParsingSupport.endpoint(from: components, context: context)
        guard let username = ProxyURIParsingSupport.nonempty(
            components.user?.removingPercentEncoding ?? components.user
        )
        else {
            throw SubscriptionConversionError.malformedURI(
                index: context.index,
                reason: "The SSH username is missing."
            )
        }
        let password = components.password?.removingPercentEncoding ?? components.password
        let query = URIQueryValues(components.queryItems ?? [])
        return SubscriptionProxyNode(
            name: ProxyURIParsingSupport.name(
                fragment: components.fragment,
                fallback: "\(endpoint.server):\(endpoint.port)"
            ),
            server: endpoint.server,
            port: endpoint.port,
            protocolType: .ssh,
            authentication: password.map {
                .usernamePassword(username: username, password: $0)
            } ?? .usernamePassword(username: username, password: ""),
            protocolOptions: .ssh(
                SSHOptions(
                    username: username,
                    password: password,
                    privateKey: query.first("private-key"),
                    privateKeyPassphrase: query.first("private-key-passphrase"),
                    hostKeyAlgorithms: ProxyURIParsingSupport.list(
                        query.first("host-key-algorithms")
                    )
                )
            ),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: "ssh"
            )
        )
    }
}
