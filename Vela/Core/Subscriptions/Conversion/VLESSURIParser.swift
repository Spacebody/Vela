import Foundation

nonisolated struct VLESSURIParser: ProxyURIParser {
    let schemes: Set<String> = ["vless"]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        let components = try ProxyURIParsingSupport.components(for: uri)
        let endpoint = try ProxyURIParsingSupport.endpoint(from: components, context: context)
        guard let uuid = ProxyURIParsingSupport.nonempty(
            components.user?.removingPercentEncoding ?? components.user
        )
        else {
            throw SubscriptionConversionError.malformedURI(
                index: context.index,
                reason: "The VLESS UUID is missing."
            )
        }
        let query = URIQueryValues(components.queryItems ?? [])
        let name = ProxyURIParsingSupport.name(
            fragment: components.fragment,
            fallback: "\(endpoint.server):\(endpoint.port)"
        )
        var warnings: [ConversionWarning] = []
        if let transportName = query.first("type", "network"),
            ProxyURIParsingSupport.transport(query: query) == nil
        {
            warnings.append(.unsupportedField(format: "VLESS", field: "type=\(transportName)"))
        }
        return SubscriptionProxyNode(
            name: name,
            server: endpoint.server,
            port: endpoint.port,
            protocolType: .vless,
            authentication: .uuid(uuid),
            transport: ProxyURIParsingSupport.transport(query: query),
            tls: ProxyURIParsingSupport.tls(query: query),
            udp: query.bool("udp"),
            tfo: query.bool("tfo", "fast-open"),
            protocolOptions: .vless(
                VLESSOptions(
                    uuid: uuid,
                    encryption: query.first("encryption"),
                    flow: query.first("flow"),
                    packetEncoding: query.first("packetEncoding", "packet-encoding")
                )
            ),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: "vless"
            ),
            warnings: warnings
        )
    }
}
