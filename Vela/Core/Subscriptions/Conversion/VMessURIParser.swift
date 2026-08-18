import Foundation

nonisolated struct VMessURIParser: ProxyURIParser {
    let schemes: Set<String> = ["vmess"]

    func parse(_ uri: String, context: URIParsingContext) throws -> SubscriptionProxyNode {
        guard uri.lowercased().hasPrefix("vmess://") else {
            throw malformed(context, "The VMess URI has an invalid scheme.")
        }
        let encoded = String(uri.dropFirst("vmess://".count))
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let data = SubscriptionBase64Decoder.decodeData(
            String(encoded),
            maximumBytes: 1_024 * 1_024
        ) else {
            throw malformed(context, "The VMess payload is not valid Base64.")
        }
        let payload: VMessPayload
        do {
            payload = try JSONDecoder().decode(VMessPayload.self, from: data)
        } catch {
            throw malformed(context, "The VMess payload is not valid JSON.")
        }
        guard let server = ProxyURIParsingSupport.nonempty(payload.add) else {
            throw malformed(context, "The VMess server is missing.")
        }
        guard let port = payload.port?.integerValue, (1 ... 65_535).contains(port) else {
            throw malformed(context, "The VMess port is invalid.")
        }
        guard let uuid = ProxyURIParsingSupport.nonempty(payload.id) else {
            throw malformed(context, "The VMess UUID is missing.")
        }
        let query = URIQueryValues([
            URLQueryItem(name: "type", value: payload.net),
            URLQueryItem(name: "host", value: payload.host),
            URLQueryItem(name: "path", value: payload.path),
            URLQueryItem(name: "serviceName", value: payload.path),
        ])
        let tlsEnabled = ["tls", "reality"].contains(payload.tls?.lowercased())
        let reality = payload.pbk.map {
            RealityOptions(publicKey: $0, shortID: payload.sid)
        }
        let tls = ProxyTLSOptions(
            enabled: tlsEnabled,
            serverName: ProxyURIParsingSupport.nonempty(payload.sni),
            skipCertificateVerification: payload.allowInsecure?.boolValue,
            alpn: ProxyURIParsingSupport.list(payload.alpn),
            fingerprint: nil,
            clientFingerprint: ProxyURIParsingSupport.nonempty(payload.fp),
            reality: reality
        )
        let name = ProxyURIParsingSupport.name(
            fragment: nil,
            fallback: ProxyURIParsingSupport.nonempty(payload.ps) ?? "\(server):\(port)"
        )
        var warnings: [ConversionWarning] = []
        if let network = payload.net?.lowercased(),
            !["tcp", "none", "ws", "websocket", "grpc", "gun", "http", "h2", "quic"].contains(network)
        {
            warnings.append(.unsupportedField(format: "VMess", field: "net=\(network)"))
        }
        return SubscriptionProxyNode(
            name: name,
            server: server,
            port: port,
            protocolType: .vmess,
            authentication: .uuid(uuid),
            transport: ProxyURIParsingSupport.transport(query: query),
            tls: tlsEnabled || reality != nil || ProxyURIParsingSupport.nonempty(payload.sni) != nil ? tls : nil,
            udp: payload.udp?.boolValue,
            protocolOptions: .vmess(
                VMessOptions(
                    uuid: uuid,
                    alterID: payload.aid?.integerValue ?? 0,
                    cipher: ProxyURIParsingSupport.nonempty(payload.scy) ?? "auto",
                    packetEncoding: ProxyURIParsingSupport.nonempty(payload.packetEncoding)
                )
            ),
            source: ProxyURIParsingSupport.source(
                format: context.sourceFormat,
                index: context.index,
                scheme: "vmess"
            ),
            warnings: warnings
        )
    }

    private func malformed(
        _ context: URIParsingContext,
        _ reason: String
    ) -> SubscriptionConversionError {
        .malformedURI(index: context.index, reason: reason)
    }
}

nonisolated private struct VMessPayload: Decodable, Sendable {
    var ps: String?
    var add: String?
    var port: FlexibleScalar?
    var id: String?
    var aid: FlexibleScalar?
    var scy: String?
    var net: String?
    var host: String?
    var path: String?
    var tls: String?
    var sni: String?
    var alpn: String?
    var fp: String?
    var pbk: String?
    var sid: String?
    var packetEncoding: String?
    var allowInsecure: FlexibleScalar?
    var udp: FlexibleScalar?

    enum CodingKeys: String, CodingKey {
        case ps, add, port, id, aid, scy, net, host, path, tls, sni, alpn, fp, pbk, sid, udp
        case packetEncoding = "packet-encoding"
        case allowInsecure
    }
}

nonisolated enum FlexibleScalar: Decodable, Sendable {
    case string(String)
    case integer(Int)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            throw DecodingError.typeMismatch(
                FlexibleScalar.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a string, integer, or Boolean."
                )
            )
        }
    }

    var integerValue: Int? {
        switch self {
        case let .integer(value): value
        case let .string(value): Int(value)
        case let .bool(value): value ? 1 : 0
        }
    }

    var boolValue: Bool? {
        switch self {
        case let .bool(value): value
        case let .integer(value): value != 0
        case let .string(value):
            switch value.lowercased() {
            case "1", "true", "yes", "on": true
            case "0", "false", "no", "off": false
            default: nil
            }
        }
    }
}
