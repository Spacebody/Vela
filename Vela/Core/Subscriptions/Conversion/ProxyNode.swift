import Foundation

nonisolated enum ProxyProtocol: String, Codable, CaseIterable, Sendable {
    case shadowsocks = "ss"
    case shadowsocksR = "ssr"
    case vmess
    case vless
    case trojan
    case hysteria
    case hysteria2
    case tuic
    case wireGuard = "wireguard"
    case socks5
    case http
    case ssh
}

nonisolated enum ProxyAuthentication: Hashable, Sendable {
    case none
    case password(String)
    case usernamePassword(username: String, password: String)
    case uuid(String)
}

nonisolated struct WebSocketOptions: Hashable, Sendable {
    var path: String?
    var headers: [String: String]
    var maximumEarlyData: Int?
    var earlyDataHeaderName: String?
}

nonisolated struct GRPCOptions: Hashable, Sendable {
    var serviceName: String?
}

nonisolated struct HTTPTransportOptions: Hashable, Sendable {
    var path: String?
    var hosts: [String]
    var headers: [String: String]
}

nonisolated struct HTTP2Options: Hashable, Sendable {
    var path: String?
    var hosts: [String]
}

nonisolated struct QUICOptions: Hashable, Sendable {
    var security: String?
    var key: String?
}

nonisolated enum ProxyTransport: Hashable, Sendable {
    case tcp
    case ws(WebSocketOptions)
    case grpc(GRPCOptions)
    case http(HTTPTransportOptions)
    case h2(HTTP2Options)
    case quic(QUICOptions)
}

nonisolated struct RealityOptions: Hashable, Sendable {
    var publicKey: String
    var shortID: String?
}

nonisolated struct ProxyTLSOptions: Hashable, Sendable {
    var enabled: Bool
    var serverName: String?
    var skipCertificateVerification: Bool?
    var alpn: [String]?
    var fingerprint: String?
    var clientFingerprint: String?
    var reality: RealityOptions?

    init(
        enabled: Bool,
        serverName: String? = nil,
        skipCertificateVerification: Bool? = nil,
        alpn: [String]? = nil,
        fingerprint: String? = nil,
        clientFingerprint: String? = nil,
        reality: RealityOptions? = nil
    ) {
        self.enabled = enabled
        self.serverName = serverName
        self.skipCertificateVerification = skipCertificateVerification
        self.alpn = alpn
        self.fingerprint = fingerprint
        self.clientFingerprint = clientFingerprint
        self.reality = reality
    }
}

nonisolated struct ShadowsocksOptions: Hashable, Sendable {
    var cipher: String
    var password: String
    var plugin: String?
    var pluginOptions: [String: String]
}

nonisolated struct ShadowsocksROptions: Hashable, Sendable {
    var cipher: String
    var password: String
    var protocolName: String
    var protocolParameter: String?
    var obfuscation: String
    var obfuscationParameter: String?
    var group: String?
}

nonisolated struct VMessOptions: Hashable, Sendable {
    var uuid: String
    var alterID: Int
    var cipher: String
    var packetEncoding: String?
}

nonisolated struct VLESSOptions: Hashable, Sendable {
    var uuid: String
    var encryption: String?
    var flow: String?
    var packetEncoding: String?
}

nonisolated struct TrojanOptions: Hashable, Sendable {
    var password: String
}

nonisolated struct HysteriaOptions: Hashable, Sendable {
    var authentication: String?
    var protocolName: String?
    var obfuscation: String?
    var upstream: String?
    var downstream: String?
    var ports: String?
}

nonisolated struct Hysteria2Options: Hashable, Sendable {
    var password: String
    var obfuscation: String?
    var obfuscationPassword: String?
    var upstream: String?
    var downstream: String?
    var ports: String?
}

nonisolated struct TUICOptions: Hashable, Sendable {
    var uuid: String
    var password: String
    var token: String?
    var congestionController: String?
    var udpRelayMode: String?
    var heartbeatInterval: Int?
}

nonisolated struct WireGuardOptions: Hashable, Sendable {
    var privateKey: String?
    var publicKey: String?
    var presharedKey: String?
    var ip: String?
    var ipv6: String?
    var mtu: Int?
}

nonisolated struct SOCKS5Options: Hashable, Sendable {
    var username: String?
    var password: String?
}

nonisolated struct HTTPProxyOptions: Hashable, Sendable {
    var username: String?
    var password: String?
}

nonisolated struct SSHOptions: Hashable, Sendable {
    var username: String
    var password: String?
    var privateKey: String?
    var privateKeyPassphrase: String?
    var hostKeyAlgorithms: [String]?
}

nonisolated enum ProxyProtocolOptions: Hashable, Sendable {
    case shadowsocks(ShadowsocksOptions)
    case shadowsocksR(ShadowsocksROptions)
    case vmess(VMessOptions)
    case vless(VLESSOptions)
    case trojan(TrojanOptions)
    case hysteria(HysteriaOptions)
    case hysteria2(Hysteria2Options)
    case tuic(TUICOptions)
    case wireGuard(WireGuardOptions)
    case socks5(SOCKS5Options)
    case http(HTTPProxyOptions)
    case ssh(SSHOptions)
}

nonisolated struct ProxyNodeSource: Hashable, Sendable {
    var format: SubscriptionContentFormat
    var itemIndex: Int
    var safeDescription: String
}

nonisolated struct SubscriptionProxyNode: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var server: String
    var port: Int
    var protocolType: ProxyProtocol
    var authentication: ProxyAuthentication
    var transport: ProxyTransport?
    var tls: ProxyTLSOptions?
    var udp: Bool?
    var tfo: Bool?
    var interfaceName: String?
    var routingMark: Int?
    var protocolOptions: ProxyProtocolOptions
    var source: ProxyNodeSource
    var warnings: [ConversionWarning]

    init(
        id: UUID = UUID(),
        name: String,
        server: String,
        port: Int,
        protocolType: ProxyProtocol,
        authentication: ProxyAuthentication,
        transport: ProxyTransport? = nil,
        tls: ProxyTLSOptions? = nil,
        udp: Bool? = nil,
        tfo: Bool? = nil,
        interfaceName: String? = nil,
        routingMark: Int? = nil,
        protocolOptions: ProxyProtocolOptions,
        source: ProxyNodeSource,
        warnings: [ConversionWarning] = []
    ) {
        self.id = id
        self.name = name
        self.server = server
        self.port = port
        self.protocolType = protocolType
        self.authentication = authentication
        self.transport = transport
        self.tls = tls
        self.udp = udp
        self.tfo = tfo
        self.interfaceName = interfaceName
        self.routingMark = routingMark
        self.protocolOptions = protocolOptions
        self.source = source
        self.warnings = warnings
    }
}
