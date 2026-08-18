import Foundation

nonisolated struct SOCKSURIParser: ProxyURIParser {
    let schemes: Set<String> = ["socks", "socks5"]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        let components = try ProxyURIParsingSupport.components(for: uri)
        let endpoint = try ProxyURIParsingSupport.endpoint(from: components, context: context)
        let username = components.user?.removingPercentEncoding ?? components.user
        let password = components.password?.removingPercentEncoding ?? components.password
        let query = URIQueryValues(components.queryItems ?? [])
        let authentication: ProxyAuthentication = if let username {
            .usernamePassword(username: username, password: password ?? "")
        } else {
            .none
        }
        return SubscriptionProxyNode(
            name: ProxyURIParsingSupport.name(
                fragment: components.fragment,
                fallback: "\(endpoint.server):\(endpoint.port)"
            ),
            server: endpoint.server,
            port: endpoint.port,
            protocolType: .socks5,
            authentication: authentication,
            tls: ProxyURIParsingSupport.tls(query: query),
            udp: query.bool("udp"),
            protocolOptions: .socks5(
                SOCKS5Options(username: username, password: password)
            ),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: components.scheme ?? "socks5"
            )
        )
    }
}
