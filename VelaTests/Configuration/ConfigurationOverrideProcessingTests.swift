import Testing
@testable import Vela

@Suite("Configuration override processing and previews")
struct ConfigurationOverrideProcessingTests {
    private let upstreamYAML = """
    mixed-port: 7890
    external-controller: 127.0.0.1:9090
    secret: upstream-secret
    mode: rule
    dns:
      enable: true
      ipv6: true
      enhanced-mode: redir-host
      nameserver:
        - 1.1.1.1
      unknown-upstream-field:
        nested: keep-me
    sniffer:
      enable: false
      unknown-sniffer-field: keep-me-too
      sniff:
        TLS:
          ports:
            - 443
          upstream-only: preserved
    proxy-providers:
      airport:
        type: http
        url: https://provider.example/subscription?token=provider-token
        password: node-password
    subscription-url: https://subscription.example/config?token=subscription-token
    authorization: Bearer top-secret-token
    """

    @Test("Inherit leaves the source semantics unchanged")
    func inheritLeavesSourceUnchanged() throws {
        let processor = ConfigurationOverrideProcessor()
        let source = try YAMLDocument(yaml: upstreamYAML)
        let result = try processor.process(
            upstream: source,
            overrides: ProfileStructuredOverrides()
        )

        #expect(result.finalDocument == source)
        #expect(result.preview.semanticDiff.isEmpty)
    }

    @Test("Persistent rule overrides are normalized, deduplicated, and prepended")
    func prependedRulesAreAppliedBeforeUpstreamRules() throws {
        let result = try ConfigurationOverrideProcessor().process(
            upstreamYAML: """
            mode: rule
            rules:
              - DOMAIN-SUFFIX,upstream.example,DIRECT
              - MATCH,PROXY
            """,
            overrides: ProfileStructuredOverrides(
                prependedRules: [
                    " DOMAIN-SUFFIX, custom.example , DIRECT ",
                    "DOMAIN-SUFFIX,custom.example,DIRECT",
                    "DOMAIN-SUFFIX,upstream.example,DIRECT",
                ]
            )
        )

        #expect(result.normalizedOverrides.prependedRules == [
            "DOMAIN-SUFFIX,custom.example,DIRECT",
            "DOMAIN-SUFFIX,upstream.example,DIRECT",
        ])
        #expect(
            try result.finalDocument.value(at: ["rules"]) == .sequence([
                .string("DOMAIN-SUFFIX,custom.example,DIRECT"),
                .string("DOMAIN-SUFFIX,upstream.example,DIRECT"),
                .string("MATCH,PROXY"),
            ])
        )
        #expect(result.preview.semanticDiff.first(where: { $0.path == "rules" })?.source == .velaOverride)
    }

    @Test("Deep set and remove preserve unknown upstream fields")
    func deepMergeAndRemove() throws {
        let overrides = ProfileStructuredOverrides(
            dns: DNSOverrides(
                ipv6: .remove,
                enhancedMode: .set(.fakeIP),
                nameserver: .set([" 8.8.8.8 ", "8.8.8.8", "1.0.0.1"]),
                nameserverPolicy: .set([
                    NameserverPolicyEntry(pattern: "+.example.com", servers: ["1.1.1.1"])
                ])
            ),
            sniffer: SnifferOverrides(
                enable: .set(true),
                sniff: SnifferProtocolSetOverrides(
                    tls: SnifferProtocolOverrides(
                        ports: .set([.single(8443), .single(443), .single(8443)]),
                        overrideDestination: .set(true)
                    )
                )
            )
        )

        let result = try ConfigurationOverrideProcessor().process(
            upstreamYAML: upstreamYAML,
            overrides: overrides
        )

        #expect(try result.finalDocument.value(at: ["dns", "ipv6"]) == nil)
        #expect(
            try result.finalDocument.value(at: ["dns", "enhanced-mode"])
                == .string("fake-ip")
        )
        #expect(
            try result.finalDocument.value(at: ["dns", "nameserver"])
                == .sequence([.string("8.8.8.8"), .string("1.0.0.1")])
        )
        #expect(
            try result.finalDocument.value(at: ["dns", "unknown-upstream-field", "nested"])
                == .string("keep-me")
        )
        #expect(
            try result.finalDocument.value(
                at: ["sniffer", "sniff", "TLS", "upstream-only"]
            ) == .string("preserved")
        )
        #expect(
            try result.finalDocument.value(at: ["sniffer", "unknown-sniffer-field"])
                == .string("keep-me-too")
        )
        #expect(
            try result.finalDocument.value(at: ["sniffer", "sniff", "TLS", "ports"])
                == .sequence([.integer(443), .integer(8443)])
        )
        #expect(!result.finalYAML.contains("ipv6: null"))
        #expect(result.normalizedOverrides.dns.nameserver == .set(["8.8.8.8", "1.0.0.1"]))
    }

    @Test("Vela forced fields are applied last and own the final diff")
    func forcedFieldsWin() throws {
        let overrides = ProfileStructuredOverrides(
            dns: DNSOverrides(enable: .set(true))
        )
        let forcedFields = [
            ConfigurationForcedField(path: ["mixed-port"], value: .integer(17_890)),
            ConfigurationForcedField(
                path: ["external-controller"],
                value: .string("127.0.0.1:19090")
            ),
            ConfigurationForcedField(path: ["secret"], value: .string("runtime-secret")),
            ConfigurationForcedField(path: ["dns", "enable"], value: .bool(false)),
        ]

        let result = try ConfigurationOverrideProcessor().process(
            upstreamYAML: upstreamYAML,
            overrides: overrides,
            forcedFields: forcedFields
        )

        #expect(result.finalDocument["mixed-port"] == .integer(17_890))
        #expect(result.finalDocument["external-controller"] == .string("127.0.0.1:19090"))
        #expect(result.finalDocument["secret"] == .string("runtime-secret"))
        #expect(try result.finalDocument.value(at: ["dns", "enable"]) == .bool(false))
        #expect(
            result.preview.semanticDiff.first { $0.path == "dns.enable" }?.source
                == .velaForced
        )
        #expect(
            result.preview.semanticDiff.first { $0.path == "secret" }?.source
                == .velaForced
        )
    }

    @Test("Every supported DNS and Sniffer field maps to its Mihomo YAML path")
    func allSupportedFieldsMapToYAML() throws {
        let overrides = ProfileStructuredOverrides(
            dns: DNSOverrides(
                enable: .set(true),
                ipv6: .set(false),
                enhancedMode: .set(.fakeIP),
                fakeIPRange: .set("198.18.0.1/16"),
                fakeIPFilterMode: .set(.whitelist),
                fakeIPFilter: .set(["+.example.com"]),
                useHosts: .set(true),
                useSystemHosts: .set(false),
                respectRules: .set(true),
                defaultNameserver: .set(["223.5.5.5"]),
                nameserver: .set(["https://dns.example/dns-query"]),
                fallback: .set(["1.0.0.1"]),
                proxyServerNameserver: .set(["1.1.1.1"]),
                directNameserver: .set(["system"]),
                directNameserverFollowPolicy: .set(true),
                nameserverPolicy: .set([
                    NameserverPolicyEntry(pattern: "geosite:cn", servers: ["223.5.5.5"])
                ])
            ),
            sniffer: SnifferOverrides(
                enable: .set(true),
                forceDNSMapping: .set(true),
                parsePureIP: .set(true),
                overrideDestination: .set(false),
                sniff: SnifferProtocolSetOverrides(
                    http: SnifferProtocolOverrides(
                        ports: .set([.single(80)]),
                        overrideDestination: .set(true)
                    ),
                    tls: SnifferProtocolOverrides(
                        ports: .set([.single(443)]),
                        overrideDestination: .set(true)
                    ),
                    quic: SnifferProtocolOverrides(
                        ports: .set([.range(start: 4_000, end: 5_000)]),
                        overrideDestination: .set(false)
                    )
                ),
                forceDomain: .set(["+.force.example"]),
                skipDomain: .set(["+.skip.example"]),
                skipSourceAddress: .set(["192.0.2.0/24"]),
                skipDestinationAddress: .set(["2001:db8::/32"])
            )
        )

        let document = try ConfigurationOverrideProcessor().process(
            upstreamYAML: "mode: rule\n",
            overrides: overrides
        ).finalDocument
        let expected: [String: YAMLValue] = [
            "dns.enable": .bool(true),
            "dns.ipv6": .bool(false),
            "dns.enhanced-mode": .string("fake-ip"),
            "dns.fake-ip-range": .string("198.18.0.1/16"),
            "dns.fake-ip-filter-mode": .string("whitelist"),
            "dns.fake-ip-filter": .sequence([.string("+.example.com")]),
            "dns.use-hosts": .bool(true),
            "dns.use-system-hosts": .bool(false),
            "dns.respect-rules": .bool(true),
            "dns.default-nameserver": .sequence([.string("223.5.5.5")]),
            "dns.nameserver": .sequence([.string("https://dns.example/dns-query")]),
            "dns.fallback": .sequence([.string("1.0.0.1")]),
            "dns.proxy-server-nameserver": .sequence([.string("1.1.1.1")]),
            "dns.direct-nameserver": .sequence([.string("system")]),
            "dns.direct-nameserver-follow-policy": .bool(true),
            "dns.nameserver-policy": .mapping([
                "geosite:cn": .sequence([.string("223.5.5.5")])
            ]),
            "sniffer.enable": .bool(true),
            "sniffer.force-dns-mapping": .bool(true),
            "sniffer.parse-pure-ip": .bool(true),
            "sniffer.override-destination": .bool(false),
            "sniffer.sniff.HTTP.ports": .sequence([.integer(80)]),
            "sniffer.sniff.HTTP.override-destination": .bool(true),
            "sniffer.sniff.TLS.ports": .sequence([.integer(443)]),
            "sniffer.sniff.TLS.override-destination": .bool(true),
            "sniffer.sniff.QUIC.ports": .sequence([.string("4000-5000")]),
            "sniffer.sniff.QUIC.override-destination": .bool(false),
            "sniffer.force-domain": .sequence([.string("+.force.example")]),
            "sniffer.skip-domain": .sequence([.string("+.skip.example")]),
            "sniffer.skip-src-address": .sequence([.string("192.0.2.0/24")]),
            "sniffer.skip-dst-address": .sequence([.string("2001:db8::/32")]),
        ]

        for path in expected.keys.sorted() {
            #expect(try document.value(at: path.split(separator: ".").map(String.init)) == expected[path])
        }
    }

    @Test("Semantic diff is deterministic and describes add, change, and remove")
    func stableSemanticDiff() throws {
        let overrides = ProfileStructuredOverrides(
            dns: DNSOverrides(
                ipv6: .remove,
                enhancedMode: .set(.fakeIP),
                fakeIPRange: .set("198.18.0.1/16")
            )
        )

        let first: [ConfigurationSemanticDiffEntry] = try ConfigurationOverrideProcessor().process(
            upstreamYAML: upstreamYAML,
            overrides: overrides
        ).preview.semanticDiff
        let second: [ConfigurationSemanticDiffEntry] = try ConfigurationOverrideProcessor().process(
            upstreamYAML: upstreamYAML,
            overrides: overrides
        ).preview.semanticDiff
        let paths = first.map { $0.path }

        #expect(first == second)
        #expect(paths == paths.sorted())
        #expect(first.first { $0.path == "dns.fake-ip-range" }?.operation == .add)
        #expect(first.first { $0.path == "dns.enhanced-mode" }?.operation == .change)
        #expect(first.first { $0.path == "dns.ipv6" }?.operation == .remove)
        #expect(first.allSatisfy { $0.source == ConfigurationValueSource.velaOverride })
    }

    @Test("Raw and final previews redact secrets, credentials, and subscription URLs")
    func previewRedaction() throws {
        let result = try ConfigurationOverrideProcessor().process(
            upstreamYAML: upstreamYAML,
            overrides: ProfileStructuredOverrides(),
            forcedFields: [
                ConfigurationForcedField(path: ["secret"], value: .string("runtime-secret"))
            ]
        )

        for preview in [result.preview.rawYAML, result.preview.finalYAML] {
            #expect(preview.contains("<redacted>"))
            #expect(!preview.contains("upstream-secret"))
            #expect(!preview.contains("runtime-secret"))
            #expect(!preview.contains("provider-token"))
            #expect(!preview.contains("node-password"))
            #expect(!preview.contains("subscription-token"))
            #expect(!preview.contains("top-secret-token"))
        }

        #expect(result.finalYAML.contains("runtime-secret"))
        let secretDiff = try #require(
            result.preview.semanticDiff.first { $0.path == "secret" }
        )
        #expect(secretDiff.before == .string("<redacted>"))
        #expect(secretDiff.after == .string("<redacted>"))
    }

    @Test("respect-rules without proxy nameservers emits a non-blocking warning")
    func respectRulesWarning() throws {
        let result = try ConfigurationOverrideProcessor().process(
            upstreamYAML: upstreamYAML,
            overrides: ProfileStructuredOverrides(
                dns: DNSOverrides(
                    respectRules: .set(true),
                    proxyServerNameserver: .set([])
                )
            )
        )

        #expect(result.preview.validation.isValid)
        #expect(
            result.preview.validation.warnings.contains {
                $0.code == .missingProxyNameserver
                    && $0.path == "dns.proxy-server-nameserver"
            }
        )
    }

    @Test("Invalid drafts fail before mutating the upstream document")
    func invalidDraftFailsClosed() {
        let invalid = ProfileStructuredOverrides(
            dns: DNSOverrides(fakeIPRange: .set("not-a-cidr"))
        )

        #expect(throws: ConfigurationOverrideProcessingError.self) {
            try ConfigurationOverrideProcessor().process(
                upstreamYAML: upstreamYAML,
                overrides: invalid
            )
        }
    }
}
