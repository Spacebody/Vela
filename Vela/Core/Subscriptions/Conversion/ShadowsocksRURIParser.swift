import Foundation

nonisolated struct ShadowsocksRURIParser: ProxyURIParser {
    let schemes: Set<String> = ["ssr"]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        guard uri.lowercased().hasPrefix("ssr://"),
            let decoded = SubscriptionBase64Decoder.decodeString(
                String(uri.dropFirst("ssr://".count)),
                maximumBytes: 1_024 * 1_024
            )
        else {
            throw malformed(context, "The SSR payload is not valid Base64.")
        }
        let sections = decoded.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let core = String(sections[0])
        let values = core.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard values.count >= 6 else {
            throw malformed(context, "The SSR payload is incomplete.")
        }
        let server = values.dropLast(5).joined(separator: ":").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !server.isEmpty, let port = Int(values[values.count - 5]), (1 ... 65_535).contains(port) else {
            throw malformed(context, "The SSR server or port is invalid.")
        }
        let protocolName = values[values.count - 4]
        let cipher = values[values.count - 3]
        let obfuscation = values[values.count - 2]
        guard let password = SubscriptionBase64Decoder.decodeString(
            values[values.count - 1],
            maximumBytes: 64 * 1_024
        ), !password.isEmpty else {
            throw malformed(context, "The SSR password is missing or invalid.")
        }
        let query = sections.count == 2
            ? queryValues(String(sections[1]).trimmingCharacters(in: CharacterSet(charactersIn: "?")))
            : URIQueryValues([])
        let remarks = decodeNested(query.first("remarks"))
        return SubscriptionProxyNode(
            name: ProxyURIParsingSupport.name(
                fragment: remarks,
                fallback: "\(server):\(port)"
            ),
            server: server,
            port: port,
            protocolType: .shadowsocksR,
            authentication: .password(password),
            udp: query.bool("udp"),
            protocolOptions: .shadowsocksR(
                ShadowsocksROptions(
                    cipher: cipher,
                    password: password,
                    protocolName: protocolName,
                    protocolParameter: decodeNested(query.first("protoparam")),
                    obfuscation: obfuscation,
                    obfuscationParameter: decodeNested(query.first("obfsparam")),
                    group: decodeNested(query.first("group"))
                )
            ),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: "ssr"
            )
        )
    }

    private func queryValues(_ value: String) -> URIQueryValues {
        let components = URLComponents(string: "https://vela.invalid/?\(value)")
        return URIQueryValues(components?.queryItems ?? [])
    }

    private func decodeNested(_ value: String?) -> String? {
        guard let value else { return nil }
        return SubscriptionBase64Decoder.decodeString(value, maximumBytes: 64 * 1_024)
    }

    private func malformed(
        _ context: URIParsingContext,
        _ reason: String
    ) -> SubscriptionConversionError {
        .malformedURI(index: context.index, reason: reason)
    }
}
