import Foundation

nonisolated struct MihomoYAMLEncoder: MihomoYAMLEncoding {
    func encode(
        nodes: [SubscriptionProxyNode],
        options: MihomoEncodingOptions
    ) throws -> String {
        guard !nodes.isEmpty else { throw SubscriptionConversionError.noSupportedNodes }
        var root: [String: YAMLValue] = [
            "proxies": .sequence(nodes.map { .mapping(OrderedYAMLMapping(proxyMapping($0))) }),
        ]
        if options.includeManagedPolicyScaffold {
            let names = nodes.map { YAMLValue.string($0.name) }
            root["proxy-groups"] = .sequence([
                .mapping(OrderedYAMLMapping([
                    "name": .string("PROXY"),
                    "type": .string("select"),
                    "proxies": .sequence(names + [.string("DIRECT")]),
                ])),
            ])
            root["rules"] = .sequence([.string("MATCH,PROXY")])
        }
        do {
            return try YAMLDocument(root: root).serialized()
        } catch {
            throw SubscriptionConversionError.conversionProducedInvalidYAML(
                String(describing: error)
            )
        }
    }

    private func proxyMapping(_ node: SubscriptionProxyNode) -> [String: YAMLValue] {
        var value: [String: YAMLValue] = [
            "name": .string(node.name),
            "type": .string(node.protocolType.rawValue),
            "server": .string(node.server),
            "port": .integer(node.port),
        ]
        set(node.udp.map(YAMLValue.bool), for: "udp", in: &value)
        set(node.tfo.map(YAMLValue.bool), for: "tfo", in: &value)
        set(node.interfaceName.map(YAMLValue.string), for: "interface-name", in: &value)
        set(node.routingMark.map(YAMLValue.integer), for: "routing-mark", in: &value)
        appendProtocolOptions(node.protocolOptions, to: &value)
        appendTransport(node.transport, to: &value)
        appendTLS(node.tls, to: &value)
        return value
    }

    private func appendProtocolOptions(
        _ options: ProxyProtocolOptions,
        to value: inout [String: YAMLValue]
    ) {
        switch options {
        case let .shadowsocks(options):
            value["cipher"] = .string(options.cipher)
            value["password"] = .string(options.password)
            set(options.plugin.map(YAMLValue.string), for: "plugin", in: &value)
            if !options.pluginOptions.isEmpty {
                value["plugin-opts"] = .mapping(
                    OrderedYAMLMapping(options.pluginOptions.mapValues(YAMLValue.string))
                )
            }
        case let .shadowsocksR(options):
            value["cipher"] = .string(options.cipher)
            value["password"] = .string(options.password)
            value["protocol"] = .string(options.protocolName)
            value["obfs"] = .string(options.obfuscation)
            set(options.protocolParameter.map(YAMLValue.string), for: "protocol-param", in: &value)
            set(options.obfuscationParameter.map(YAMLValue.string), for: "obfs-param", in: &value)
        case let .vmess(options):
            value["uuid"] = .string(options.uuid)
            value["alterId"] = .integer(options.alterID)
            value["cipher"] = .string(options.cipher)
            set(options.packetEncoding.map(YAMLValue.string), for: "packet-encoding", in: &value)
        case let .vless(options):
            value["uuid"] = .string(options.uuid)
            set(options.encryption.map(YAMLValue.string), for: "encryption", in: &value)
            set(options.flow.map(YAMLValue.string), for: "flow", in: &value)
            set(options.packetEncoding.map(YAMLValue.string), for: "packet-encoding", in: &value)
        case let .trojan(options):
            value["password"] = .string(options.password)
        case let .hysteria(options):
            set(options.authentication.map(YAMLValue.string), for: "auth-str", in: &value)
            set(options.protocolName.map(YAMLValue.string), for: "protocol", in: &value)
            set(options.obfuscation.map(YAMLValue.string), for: "obfs", in: &value)
            set(options.upstream.map(YAMLValue.string), for: "up", in: &value)
            set(options.downstream.map(YAMLValue.string), for: "down", in: &value)
            set(options.ports.map(YAMLValue.string), for: "ports", in: &value)
        case let .hysteria2(options):
            value["password"] = .string(options.password)
            set(options.obfuscation.map(YAMLValue.string), for: "obfs", in: &value)
            set(options.obfuscationPassword.map(YAMLValue.string), for: "obfs-password", in: &value)
            set(options.upstream.map(YAMLValue.string), for: "up", in: &value)
            set(options.downstream.map(YAMLValue.string), for: "down", in: &value)
            set(options.ports.map(YAMLValue.string), for: "ports", in: &value)
        case let .tuic(options):
            value["uuid"] = .string(options.uuid)
            value["password"] = .string(options.password)
            set(options.token.map(YAMLValue.string), for: "token", in: &value)
            set(options.congestionController.map(YAMLValue.string), for: "congestion-controller", in: &value)
            set(options.udpRelayMode.map(YAMLValue.string), for: "udp-relay-mode", in: &value)
            set(options.heartbeatInterval.map(YAMLValue.integer), for: "heartbeat-interval", in: &value)
        case let .wireGuard(options):
            set(options.privateKey.map(YAMLValue.string), for: "private-key", in: &value)
            set(options.publicKey.map(YAMLValue.string), for: "public-key", in: &value)
            set(options.presharedKey.map(YAMLValue.string), for: "pre-shared-key", in: &value)
            set(options.ip.map(YAMLValue.string), for: "ip", in: &value)
            set(options.ipv6.map(YAMLValue.string), for: "ipv6", in: &value)
            set(options.mtu.map(YAMLValue.integer), for: "mtu", in: &value)
        case let .socks5(options):
            set(options.username.map(YAMLValue.string), for: "username", in: &value)
            set(options.password.map(YAMLValue.string), for: "password", in: &value)
        case let .http(options):
            set(options.username.map(YAMLValue.string), for: "username", in: &value)
            set(options.password.map(YAMLValue.string), for: "password", in: &value)
        case let .ssh(options):
            value["username"] = .string(options.username)
            set(options.password.map(YAMLValue.string), for: "password", in: &value)
            set(options.privateKey.map(YAMLValue.string), for: "private-key", in: &value)
            set(options.privateKeyPassphrase.map(YAMLValue.string), for: "private-key-passphrase", in: &value)
            set(options.hostKeyAlgorithms.map(stringSequence), for: "host-key-algorithms", in: &value)
        }
    }

    private func appendTLS(
        _ options: ProxyTLSOptions?,
        to value: inout [String: YAMLValue]
    ) {
        guard let options else { return }
        value["tls"] = .bool(options.enabled)
        set(options.serverName.map(YAMLValue.string), for: "servername", in: &value)
        set(
            options.skipCertificateVerification.map(YAMLValue.bool),
            for: "skip-cert-verify",
            in: &value
        )
        set(options.alpn.map(stringSequence), for: "alpn", in: &value)
        set(options.fingerprint.map(YAMLValue.string), for: "fingerprint", in: &value)
        set(
            options.clientFingerprint.map(YAMLValue.string),
            for: "client-fingerprint",
            in: &value
        )
        if let reality = options.reality {
            var realityValue: [String: YAMLValue] = [
                "public-key": .string(reality.publicKey),
            ]
            set(reality.shortID.map(YAMLValue.string), for: "short-id", in: &realityValue)
            value["reality-opts"] = .mapping(OrderedYAMLMapping(realityValue))
        }
    }

    private func appendTransport(
        _ transport: ProxyTransport?,
        to value: inout [String: YAMLValue]
    ) {
        guard let transport else { return }
        switch transport {
        case .tcp:
            value["network"] = .string("tcp")
        case let .ws(options):
            value["network"] = .string("ws")
            var mapping: [String: YAMLValue] = [:]
            set(options.path.map(YAMLValue.string), for: "path", in: &mapping)
            set(options.maximumEarlyData.map(YAMLValue.integer), for: "max-early-data", in: &mapping)
            set(
                options.earlyDataHeaderName.map(YAMLValue.string),
                for: "early-data-header-name",
                in: &mapping
            )
            if !options.headers.isEmpty {
                mapping["headers"] = stringMapping(options.headers)
            }
            if !mapping.isEmpty { value["ws-opts"] = .mapping(OrderedYAMLMapping(mapping)) }
        case let .grpc(options):
            value["network"] = .string("grpc")
            if let serviceName = options.serviceName {
                value["grpc-opts"] = .mapping(
                    OrderedYAMLMapping(["grpc-service-name": .string(serviceName)])
                )
            }
        case let .http(options):
            value["network"] = .string("http")
            var mapping: [String: YAMLValue] = [:]
            set(options.path.map(YAMLValue.string), for: "path", in: &mapping)
            if !options.hosts.isEmpty { mapping["host"] = stringSequence(options.hosts) }
            if !options.headers.isEmpty { mapping["headers"] = stringMapping(options.headers) }
            if !mapping.isEmpty { value["http-opts"] = .mapping(OrderedYAMLMapping(mapping)) }
        case let .h2(options):
            value["network"] = .string("h2")
            var mapping: [String: YAMLValue] = [:]
            set(options.path.map(YAMLValue.string), for: "path", in: &mapping)
            if !options.hosts.isEmpty { mapping["host"] = stringSequence(options.hosts) }
            if !mapping.isEmpty { value["h2-opts"] = .mapping(OrderedYAMLMapping(mapping)) }
        case let .quic(options):
            value["network"] = .string("quic")
            var mapping: [String: YAMLValue] = [:]
            set(options.security.map(YAMLValue.string), for: "security", in: &mapping)
            set(options.key.map(YAMLValue.string), for: "key", in: &mapping)
            if !mapping.isEmpty { value["quic-opts"] = .mapping(OrderedYAMLMapping(mapping)) }
        }
    }

    private func stringSequence(_ values: [String]) -> YAMLValue {
        .sequence(values.map(YAMLValue.string))
    }

    private func stringMapping(_ values: [String: String]) -> YAMLValue {
        .mapping(OrderedYAMLMapping(values.mapValues(YAMLValue.string)))
    }

    private func set(
        _ newValue: YAMLValue?,
        for key: String,
        in mapping: inout [String: YAMLValue]
    ) {
        if let newValue { mapping[key] = newValue }
    }
}
