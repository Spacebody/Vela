import Foundation

nonisolated struct ShadowsocksURIParser: ProxyURIParser {
    let schemes: Set<String> = ["ss"]

    private static let supportedCiphers: Set<String> = [
        "aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
        "xchacha20-ietf-poly1305", "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
        "2022-blake3-chacha20-poly1305", "aes-128-ctr", "aes-192-ctr", "aes-256-ctr",
        "aes-128-cfb", "aes-192-cfb", "aes-256-cfb", "rc4-md5", "chacha20-ietf",
    ]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        guard uri.lowercased().hasPrefix("ss://") else {
            throw malformed(context, "The Shadowsocks URI has an invalid scheme.")
        }
        let components = try ProxyURIParsingSupport.components(for: uri)
        let query = URIQueryValues(components.queryItems ?? [])
        let rawWithoutScheme = String(uri.dropFirst(5))
        let rawAuthority = rawWithoutScheme
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let decodedAuthority: String
        if rawAuthority.contains("@") {
            decodedAuthority = String(rawAuthority)
        } else if let decoded = SubscriptionBase64Decoder.decodeString(
            String(rawAuthority),
            maximumBytes: 64 * 1_024
        ) {
            decodedAuthority = decoded
        } else {
            throw malformed(context, "The Shadowsocks credentials could not be decoded.")
        }

        guard let atIndex = decodedAuthority.lastIndex(of: "@") else {
            throw malformed(context, "The Shadowsocks endpoint is missing.")
        }
        var userInfo = String(decodedAuthority[..<atIndex])
        let endpointText = String(decodedAuthority[decodedAuthority.index(after: atIndex)...])
        if !userInfo.contains(":"),
            let decoded = SubscriptionBase64Decoder.decodeString(
                userInfo,
                maximumBytes: 64 * 1_024
            )
        {
            userInfo = decoded
        }
        guard let colon = userInfo.firstIndex(of: ":") else {
            throw malformed(context, "The cipher or password is missing.")
        }
        let cipher = String(userInfo[..<colon]).removingPercentEncoding ?? String(userInfo[..<colon])
        let passwordPart = String(userInfo[userInfo.index(after: colon)...])
        let password = passwordPart.removingPercentEncoding ?? passwordPart
        guard Self.supportedCiphers.contains(cipher.lowercased()) else {
            throw malformed(context, "The Shadowsocks cipher is not supported by Mihomo.")
        }
        guard !password.isEmpty else {
            throw malformed(context, "The Shadowsocks password is missing.")
        }
        let endpoint = try parseEndpoint(endpointText, context: context)

        var plugin: String?
        var pluginOptions: [String: String] = [:]
        if let rawPlugin = query.first("plugin"), !rawPlugin.isEmpty {
            let decoded = rawPlugin.removingPercentEncoding ?? rawPlugin
            let parts = splitPlugin(decoded)
            plugin = parts.first
            for part in parts.dropFirst() {
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                pluginOptions[key] = pair.count == 2 ? String(pair[1]) : "true"
            }
        }
        let name = ProxyURIParsingSupport.name(
            fragment: components.fragment,
            fallback: "\(endpoint.server):\(endpoint.port)"
        )
        return SubscriptionProxyNode(
            name: name,
            server: endpoint.server,
            port: endpoint.port,
            protocolType: .shadowsocks,
            authentication: .password(password),
            udp: query.bool("udp"),
            tfo: query.bool("tfo", "fast-open"),
            protocolOptions: .shadowsocks(
                ShadowsocksOptions(
                    cipher: cipher,
                    password: password,
                    plugin: plugin,
                    pluginOptions: pluginOptions
                )
            ),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: "ss"
            )
        )
    }

    private func parseEndpoint(
        _ value: String,
        context: URIParsingContext
    ) throws -> (server: String, port: Int) {
        guard let components = URLComponents(string: "ss://placeholder:placeholder@\(value)") else {
            throw malformed(context, "The Shadowsocks endpoint is malformed.")
        }
        return try ProxyURIParsingSupport.endpoint(from: components, context: context)
    }

    private func splitPlugin(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == ";" {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result.filter { !$0.isEmpty }
    }

    private func malformed(
        _ context: URIParsingContext,
        _ reason: String
    ) -> SubscriptionConversionError {
        .malformedURI(index: context.index, reason: reason)
    }
}
