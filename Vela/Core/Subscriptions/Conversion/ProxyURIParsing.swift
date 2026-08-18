import Foundation

nonisolated protocol ProxyURIParser: Sendable {
    var schemes: Set<String> { get }
    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode
}

nonisolated struct ProxyURIParserRegistry: Sendable {
    private let parsersByScheme: [String: any ProxyURIParser]

    init(parsers: [any ProxyURIParser]) {
        var registered: [String: any ProxyURIParser] = [:]
        for parser in parsers {
            for scheme in parser.schemes {
                registered[scheme.lowercased()] = parser
            }
        }
        parsersByScheme = registered
    }

    func parser(for scheme: String) -> (any ProxyURIParser)? {
        parsersByScheme[scheme.lowercased()]
    }

    static var standard: ProxyURIParserRegistry {
        ProxyURIParserRegistry(parsers: [
            ShadowsocksURIParser(),
            VMessURIParser(),
            VLESSURIParser(),
            TrojanURIParser(),
            Hysteria2URIParser(),
            TUICURIParser(),
            ShadowsocksRURIParser(),
            HysteriaURIParser(),
            SOCKSURIParser(),
            HTTPProxyURIParser(),
            SSHURIParser(),
            WireGuardURIParser(),
        ])
    }
}

nonisolated enum SubscriptionBase64Decoder {
    static func decodeData(_ value: String, maximumBytes: Int) -> Data? {
        var compact = value.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return nil }
        compact = compact.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = compact.utf8.count % 4
        if remainder != 0 {
            compact.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: compact, options: [.ignoreUnknownCharacters]),
            data.count <= maximumBytes
        else {
            return nil
        }
        return data
    }

    static func decodeString(_ value: String, maximumBytes: Int) -> String? {
        guard let data = decodeData(value, maximumBytes: maximumBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

nonisolated struct URIQueryValues: Sendable {
    private let values: [String: [String]]

    init(_ items: [URLQueryItem]) {
        var storage: [String: [String]] = [:]
        for item in items {
            storage[item.name.lowercased(), default: []].append(item.value ?? "")
        }
        values = storage
    }

    func first(_ names: String...) -> String? {
        names.lazy.compactMap { values[$0.lowercased()]?.first }.first
    }

    func all(_ names: String...) -> [String] {
        names.flatMap { values[$0.lowercased()] ?? [] }
    }

    func bool(_ names: String...) -> Bool? {
        guard let value = first(names) else { return nil }
        return switch value.lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: nil
        }
    }

    private func first(_ names: [String]) -> String? {
        names.lazy.compactMap { values[$0.lowercased()]?.first }.first
    }
}

nonisolated enum ProxyURIParsingSupport {
    static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func components(for rawURI: String) throws -> URLComponents {
        guard let components = URLComponents(string: rawURI),
            components.scheme != nil
        else {
            throw SubscriptionConversionError.malformedURI(
                index: 0,
                reason: "The URI is malformed."
            )
        }
        return components
    }

    static func endpoint(
        from components: URLComponents,
        context: URIParsingContext
    ) throws -> (server: String, port: Int) {
        guard let rawServer = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawServer.isEmpty
        else {
            throw SubscriptionConversionError.malformedURI(
                index: context.index,
                reason: "The server is missing."
            )
        }
        guard let port = components.port, (1 ... 65_535).contains(port) else {
            throw SubscriptionConversionError.malformedURI(
                index: context.index,
                reason: "The port is missing or outside 1...65535."
            )
        }
        let server: String
        if rawServer.hasPrefix("["), rawServer.hasSuffix("]") {
            server = String(rawServer.dropFirst().dropLast())
        } else {
            server = rawServer
        }
        return (server, port)
    }

    static func name(
        fragment: String?,
        fallback: String,
        maximumLength: Int = 512
    ) -> String {
        let preferred = fragment?.removingPercentEncoding ?? fragment
        let source = preferred?.isEmpty == false ? preferred! : fallback
        let scalars = source.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                || scalar == "\t" || scalar == "\n"
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nonempty = cleaned.isEmpty ? fallback : cleaned
        return String(nonempty.prefix(maximumLength))
    }

    static func list(_ value: String?) -> [String]? {
        guard let value else { return nil }
        let result = value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return result.isEmpty ? nil : result
    }

    static func tls(
        query: URIQueryValues,
        defaultEnabled: Bool = false
    ) -> ProxyTLSOptions? {
        let security = query.first("security", "tls")?.lowercased()
        let reality = security == "reality"
        let enabled = defaultEnabled || reality || security == "tls" || query.bool("tls") == true
        let serverName = query.first("sni", "servername", "server_name", "peer")
        let skipVerify = query.bool("skip-cert-verify", "allowinsecure", "insecure")
        let alpn = list(query.first("alpn"))
        let fingerprint = query.first("fingerprint")
        let clientFingerprint = query.first("fp", "client-fingerprint", "client_fingerprint")
        let publicKey = query.first("pbk", "public-key", "public_key")
        let shortID = query.first("sid", "short-id", "short_id")
        let realityOptions = publicKey.map { RealityOptions(publicKey: $0, shortID: shortID) }
        guard enabled || serverName != nil || skipVerify != nil || alpn != nil
            || fingerprint != nil || clientFingerprint != nil || realityOptions != nil
        else { return nil }
        return ProxyTLSOptions(
            enabled: enabled,
            serverName: serverName,
            skipCertificateVerification: skipVerify,
            alpn: alpn,
            fingerprint: fingerprint,
            clientFingerprint: clientFingerprint,
            reality: realityOptions
        )
    }

    static func transport(query: URIQueryValues) -> ProxyTransport? {
        let type = query.first("type", "network", "net")?.lowercased() ?? "tcp"
        switch type {
        case "tcp", "none":
            return .tcp
        case "ws", "websocket", "httpupgrade":
            var headers: [String: String] = [:]
            if let host = query.first("host"), !host.isEmpty { headers["Host"] = host }
            return .ws(
                WebSocketOptions(
                    path: query.first("path"),
                    headers: headers,
                    maximumEarlyData: query.first("ed", "max-early-data").flatMap(Int.init),
                    earlyDataHeaderName: query.first("eh", "early-data-header-name")
                )
            )
        case "grpc", "gun":
            return .grpc(GRPCOptions(serviceName: query.first("serviceName", "service-name")))
        case "http":
            return .http(
                HTTPTransportOptions(
                    path: query.first("path"),
                    hosts: list(query.first("host")) ?? [],
                    headers: [:]
                )
            )
        case "h2":
            return .h2(
                HTTP2Options(
                    path: query.first("path"),
                    hosts: list(query.first("host")) ?? []
                )
            )
        case "quic":
            return .quic(
                QUICOptions(
                    security: query.first("quic-security"),
                    key: query.first("key")
                )
            )
        default:
            return nil
        }
    }

    static func source(
        format: SubscriptionContentFormat,
        index: Int,
        scheme: String
    ) -> ProxyNodeSource {
        ProxyNodeSource(
            format: format,
            itemIndex: index,
            safeDescription: "\(scheme.lowercased()) node \(index + 1)"
        )
    }
}
