import Foundation

nonisolated struct SingBoxSubscriptionParser: SubscriptionContentParser {
    let supportedFormat: SubscriptionContentFormat = .singBox

    func canParse(
        _: String,
        detection: SubscriptionContentDetection
    ) -> Bool {
        detection.format == .singBox
    }

    func parse(
        _ content: String,
        context: SubscriptionParsingContext
    ) async throws -> SubscriptionConversionResult {
        guard let data = content.data(using: .utf8) else {
            throw SubscriptionConversionError.decodedContentInvalidUTF8
        }
        let document: SingBoxDocument
        do {
            document = try JSONDecoder().decode(SingBoxDocument.self, from: data)
        } catch {
            throw SubscriptionConversionError.invalidSingBoxConfiguration(
                "The JSON root or outbounds array is invalid."
            )
        }
        guard let outbounds = document.outbounds, !outbounds.isEmpty else {
            throw SubscriptionConversionError.invalidSingBoxConfiguration(
                "No outbounds were found."
            )
        }
        var nodes: [SubscriptionProxyNode] = []
        var warnings: [ConversionWarning] = []
        var rejected: [RejectedSubscriptionItem] = []
        let ignoredTypes: Set<String> = [
            "direct", "block", "dns", "selector", "urltest", "fallback", "loadbalance",
        ]

        for (index, outbound) in outbounds.enumerated() {
            try Task.checkCancellation()
            let type = outbound.type.lowercased()
            if ignoredTypes.contains(type) {
                warnings.append(
                    .unsupportedField(format: "sing-box", field: "outbound type '\(type)'")
                )
                continue
            }
            do {
                let node = try convert(outbound, index: index)
                nodes.append(node)
                warnings.append(contentsOf: node.warnings)
            } catch let error as SubscriptionConversionError {
                let reason = error.errorDescription ?? "The outbound is invalid."
                warnings.append(.invalidNode(index: index, reason: reason))
                rejected.append(
                    RejectedSubscriptionItem(
                        index: index,
                        safeDescription: "sing-box \(type) outbound \(index + 1)",
                        reason: reason
                    )
                )
                if !context.options.continueOnInvalidNode { throw error }
            }
        }
        guard !nodes.isEmpty else { throw SubscriptionConversionError.noSupportedNodes }
        warnings.append(.unsupportedField(format: "sing-box", field: "dns"))
        warnings.append(.unsupportedField(format: "sing-box", field: "route"))
        return SubscriptionConversionResult(
            format: .singBox,
            nodes: nodes,
            warnings: warnings,
            rejectedItems: rejected,
            metadata: SubscriptionConversionMetadata(
                sourceDescription: "sing-box remote outbounds; DNS, route, TUN, and listeners were not imported"
            )
        )
    }

    private func convert(
        _ outbound: SingBoxOutbound,
        index: Int
    ) throws -> SubscriptionProxyNode {
        let type = outbound.type.lowercased()
        guard let server = outbound.server?.trimmingCharacters(in: .whitespacesAndNewlines),
            !server.isEmpty,
            let port = outbound.serverPort?.integerValue,
            (1 ... 65_535).contains(port)
        else {
            throw malformed(index, "The server or server_port is missing or invalid.")
        }
        let name = ProxyURIParsingSupport.name(
            fragment: outbound.tag,
            fallback: "\(server):\(port)"
        )
        let tls = makeTLS(outbound.tls)
        let transport = makeTransport(outbound.transport)
        var warnings: [ConversionWarning] = []
        if outbound.transport?.type.lowercased() == "httpupgrade" {
            warnings.append(.transportDowngraded(from: "httpupgrade", to: "ws"))
        }
        let source = ProxyURIParsingSupport.source(
            format: .singBox,
            index: index,
            scheme: type
        )

        switch type {
        case "shadowsocks", "ss":
            guard let method = outbound.method?.nonempty,
                let password = outbound.password?.nonempty
            else { throw malformed(index, "The Shadowsocks method or password is missing.") }
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .shadowsocks,
                authentication: .password(password),
                udp: outbound.udp?.boolValue,
                protocolOptions: .shadowsocks(
                    ShadowsocksOptions(
                        cipher: method,
                        password: password,
                        plugin: outbound.plugin,
                        pluginOptions: outbound.pluginOptions ?? [:]
                    )
                ),
                source: source,
                warnings: warnings
            )
        case "vmess":
            guard let uuid = outbound.uuid?.nonempty else {
                throw malformed(index, "The VMess UUID is missing.")
            }
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .vmess,
                authentication: .uuid(uuid),
                transport: transport,
                tls: tls,
                udp: outbound.udp?.boolValue,
                protocolOptions: .vmess(
                    VMessOptions(
                        uuid: uuid,
                        alterID: outbound.alterID?.integerValue ?? 0,
                        cipher: outbound.security?.nonempty ?? "auto",
                        packetEncoding: outbound.packetEncoding
                    )
                ),
                source: source,
                warnings: warnings
            )
        case "vless":
            guard let uuid = outbound.uuid?.nonempty else {
                throw malformed(index, "The VLESS UUID is missing.")
            }
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .vless,
                authentication: .uuid(uuid),
                transport: transport,
                tls: tls,
                udp: outbound.udp?.boolValue,
                protocolOptions: .vless(
                    VLESSOptions(
                        uuid: uuid,
                        encryption: outbound.encryption,
                        flow: outbound.flow,
                        packetEncoding: outbound.packetEncoding
                    )
                ),
                source: source,
                warnings: warnings
            )
        case "trojan":
            guard let password = outbound.password?.nonempty else {
                throw malformed(index, "The Trojan password is missing.")
            }
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .trojan,
                authentication: .password(password),
                transport: transport,
                tls: tls ?? ProxyTLSOptions(enabled: true),
                udp: outbound.udp?.boolValue,
                protocolOptions: .trojan(TrojanOptions(password: password)),
                source: source,
                warnings: warnings
            )
        case "hysteria":
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .hysteria,
                authentication: outbound.authString.map(ProxyAuthentication.password) ?? .none,
                tls: tls ?? ProxyTLSOptions(enabled: true),
                udp: true,
                protocolOptions: .hysteria(
                    HysteriaOptions(
                        authentication: outbound.authString,
                        protocolName: outbound.protocolName,
                        obfuscation: outbound.obfs?.type,
                        upstream: outbound.upMbps?.stringValue,
                        downstream: outbound.downMbps?.stringValue,
                        ports: outbound.serverPorts?.joined(separator: ",")
                    )
                ),
                source: source,
                warnings: warnings
            )
        case "hysteria2":
            guard let password = outbound.password?.nonempty else {
                throw malformed(index, "The Hysteria2 password is missing.")
            }
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .hysteria2,
                authentication: .password(password),
                tls: tls ?? ProxyTLSOptions(enabled: true),
                udp: true,
                protocolOptions: .hysteria2(
                    Hysteria2Options(
                        password: password,
                        obfuscation: outbound.obfs?.type,
                        obfuscationPassword: outbound.obfs?.password,
                        upstream: outbound.upMbps?.stringValue,
                        downstream: outbound.downMbps?.stringValue,
                        ports: outbound.serverPorts?.joined(separator: ",")
                    )
                ),
                source: source,
                warnings: warnings
            )
        case "tuic":
            guard let uuid = outbound.uuid?.nonempty,
                let password = outbound.password?.nonempty
            else { throw malformed(index, "The TUIC UUID or password is missing.") }
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .tuic,
                authentication: .uuid(uuid),
                tls: tls ?? ProxyTLSOptions(enabled: true),
                udp: true,
                protocolOptions: .tuic(
                    TUICOptions(
                        uuid: uuid,
                        password: password,
                        token: outbound.token,
                        congestionController: outbound.congestionControl,
                        udpRelayMode: outbound.udpRelayMode,
                        heartbeatInterval: outbound.heartbeat?.integerValue
                    )
                ),
                source: source,
                warnings: warnings
            )
        case "socks", "socks5":
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .socks5,
                authentication: outbound.username.map {
                    .usernamePassword(username: $0, password: outbound.password ?? "")
                } ?? .none,
                tls: tls,
                udp: outbound.udp?.boolValue,
                protocolOptions: .socks5(
                    SOCKS5Options(username: outbound.username, password: outbound.password)
                ),
                source: source,
                warnings: warnings
            )
        case "http":
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .http,
                authentication: outbound.username.map {
                    .usernamePassword(username: $0, password: outbound.password ?? "")
                } ?? .none,
                tls: tls,
                protocolOptions: .http(
                    HTTPProxyOptions(username: outbound.username, password: outbound.password)
                ),
                source: source,
                warnings: warnings
            )
        case "ssh":
            guard let username = outbound.user?.nonempty ?? outbound.username?.nonempty else {
                throw malformed(index, "The SSH username is missing.")
            }
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .ssh,
                authentication: .usernamePassword(
                    username: username,
                    password: outbound.password ?? ""
                ),
                protocolOptions: .ssh(
                    SSHOptions(
                        username: username,
                        password: outbound.password,
                        privateKey: outbound.privateKey,
                        privateKeyPassphrase: outbound.privateKeyPassphrase,
                        hostKeyAlgorithms: outbound.hostKeyAlgorithms
                    )
                ),
                source: source,
                warnings: warnings
            )
        case "wireguard":
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .wireGuard,
                authentication: .none,
                udp: true,
                protocolOptions: .wireGuard(
                    WireGuardOptions(
                        privateKey: outbound.privateKey,
                        publicKey: outbound.peerPublicKey ?? outbound.publicKey,
                        presharedKey: outbound.preSharedKey,
                        ip: outbound.localAddress?.first(where: { !$0.contains(":") }),
                        ipv6: outbound.localAddress?.first(where: { $0.contains(":") }),
                        mtu: outbound.mtu?.integerValue
                    )
                ),
                source: source,
                warnings: warnings
            )
        default:
            throw malformed(index, "The outbound protocol '\(type)' is not supported.")
        }
    }

    private func makeTLS(_ input: SingBoxTLS?) -> ProxyTLSOptions? {
        guard let input, input.enabled != false else { return nil }
        let reality = input.reality?.enabled == true
            ? input.reality?.publicKey.map {
                RealityOptions(publicKey: $0, shortID: input.reality?.shortID)
            }
            : nil
        return ProxyTLSOptions(
            enabled: input.enabled ?? true,
            serverName: input.serverName,
            skipCertificateVerification: input.insecure,
            alpn: input.alpn,
            fingerprint: nil,
            clientFingerprint: input.utls?.enabled == true ? input.utls?.fingerprint : nil,
            reality: reality
        )
    }

    private func makeTransport(_ input: SingBoxTransport?) -> ProxyTransport? {
        guard let input else { return nil }
        switch input.type.lowercased() {
        case "ws", "httpupgrade":
            return .ws(
                WebSocketOptions(
                    path: input.path,
                    headers: input.headers ?? [:],
                    maximumEarlyData: input.maxEarlyData?.integerValue,
                    earlyDataHeaderName: input.earlyDataHeaderName
                )
            )
        case "grpc":
            return .grpc(GRPCOptions(serviceName: input.serviceName))
        case "http":
            return .http(
                HTTPTransportOptions(
                    path: input.path,
                    hosts: input.host?.arrayValue ?? [],
                    headers: input.headers ?? [:]
                )
            )
        case "h2":
            return .h2(
                HTTP2Options(path: input.path, hosts: input.host?.arrayValue ?? [])
            )
        case "quic":
            return .quic(QUICOptions(security: nil, key: nil))
        default:
            return nil
        }
    }

    private func malformed(_ index: Int, _ reason: String) -> SubscriptionConversionError {
        .malformedURI(index: index, reason: reason)
    }
}

nonisolated private struct SingBoxDocument: Decodable, Sendable {
    var outbounds: [SingBoxOutbound]?
}

nonisolated private struct SingBoxOutbound: Decodable, Sendable {
    var type: String
    var tag: String?
    var server: String?
    var serverPort: FlexibleScalar?
    var serverPorts: [String]?
    var method: String?
    var password: String?
    var uuid: String?
    var alterID: FlexibleScalar?
    var security: String?
    var encryption: String?
    var flow: String?
    var packetEncoding: String?
    var username: String?
    var user: String?
    var privateKey: String?
    var privateKeyPassphrase: String?
    var publicKey: String?
    var peerPublicKey: String?
    var preSharedKey: String?
    var localAddress: [String]?
    var mtu: FlexibleScalar?
    var congestionControl: String?
    var udpRelayMode: String?
    var heartbeat: FlexibleScalar?
    var upMbps: FlexibleScalar?
    var downMbps: FlexibleScalar?
    var authString: String?
    var protocolName: String?
    var token: String?
    var udp: FlexibleScalar?
    var plugin: String?
    var pluginOptions: [String: String]?
    var hostKeyAlgorithms: [String]?
    var tls: SingBoxTLS?
    var transport: SingBoxTransport?
    var obfs: SingBoxObfs?

    enum CodingKeys: String, CodingKey {
        case type, tag, server, method, password, uuid, security, encryption, flow, username, user
        case tls, transport, obfs, token, udp, plugin
        case serverPort = "server_port"
        case serverPorts = "server_ports"
        case alterID = "alter_id"
        case packetEncoding = "packet_encoding"
        case privateKey = "private_key"
        case privateKeyPassphrase = "private_key_passphrase"
        case publicKey = "public_key"
        case peerPublicKey = "peer_public_key"
        case preSharedKey = "pre_shared_key"
        case localAddress = "local_address"
        case mtu
        case congestionControl = "congestion_control"
        case udpRelayMode = "udp_relay_mode"
        case heartbeat
        case upMbps = "up_mbps"
        case downMbps = "down_mbps"
        case authString = "auth_str"
        case protocolName = "protocol"
        case pluginOptions = "plugin_opts"
        case hostKeyAlgorithms = "host_key_algorithms"
    }
}

nonisolated private struct SingBoxTLS: Decodable, Sendable {
    var enabled: Bool?
    var serverName: String?
    var insecure: Bool?
    var alpn: [String]?
    var utls: SingBoxUTLS?
    var reality: SingBoxReality?

    enum CodingKeys: String, CodingKey {
        case enabled, insecure, alpn, utls, reality
        case serverName = "server_name"
    }
}

nonisolated private struct SingBoxUTLS: Decodable, Sendable {
    var enabled: Bool?
    var fingerprint: String?
}

nonisolated private struct SingBoxReality: Decodable, Sendable {
    var enabled: Bool?
    var publicKey: String?
    var shortID: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case publicKey = "public_key"
        case shortID = "short_id"
    }
}

nonisolated private struct SingBoxTransport: Decodable, Sendable {
    var type: String
    var path: String?
    var headers: [String: String]?
    var host: StringOrArray?
    var serviceName: String?
    var maxEarlyData: FlexibleScalar?
    var earlyDataHeaderName: String?

    enum CodingKeys: String, CodingKey {
        case type, path, headers, host
        case serviceName = "service_name"
        case maxEarlyData = "max_early_data"
        case earlyDataHeaderName = "early_data_header_name"
    }
}

nonisolated private struct SingBoxObfs: Decodable, Sendable {
    var type: String?
    var password: String?
}

nonisolated private enum StringOrArray: Decodable, Sendable {
    case string(String)
    case array([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .array(try container.decode([String].self))
        }
    }

    var arrayValue: [String] {
        switch self {
        case let .string(value): [value]
        case let .array(value): value
        }
    }
}

nonisolated private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}

nonisolated extension FlexibleScalar {
    var stringValue: String {
        switch self {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .bool(value): String(value)
        }
    }
}
