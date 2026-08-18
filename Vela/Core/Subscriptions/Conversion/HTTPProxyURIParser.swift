import Foundation

nonisolated struct HTTPProxyURIParser: ProxyURIParser {
    let schemes: Set<String> = ["http", "https"]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        let components = try ProxyURIParsingSupport.components(for: uri)
        guard components.user != nil || components.password != nil else {
            throw SubscriptionConversionError.malformedURI(
                index: context.index,
                reason: "A plain web URL is not an HTTP proxy node."
            )
        }
        let endpoint = try ProxyURIParsingSupport.endpoint(from: components, context: context)
        let username = components.user?.removingPercentEncoding ?? components.user
        let password = components.password?.removingPercentEncoding ?? components.password
        let isTLS = components.scheme?.lowercased() == "https"
        let query = URIQueryValues(components.queryItems ?? [])
        return SubscriptionProxyNode(
            name: ProxyURIParsingSupport.name(
                fragment: components.fragment,
                fallback: "\(endpoint.server):\(endpoint.port)"
            ),
            server: endpoint.server,
            port: endpoint.port,
            protocolType: .http,
            authentication: username.map {
                .usernamePassword(username: $0, password: password ?? "")
            } ?? .none,
            tls: ProxyURIParsingSupport.tls(query: query, defaultEnabled: isTLS),
            protocolOptions: .http(
                HTTPProxyOptions(username: username, password: password)
            ),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: components.scheme ?? "http"
            )
        )
    }
}
