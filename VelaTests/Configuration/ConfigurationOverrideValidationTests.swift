import Testing
@testable import Vela

@Suite("Configuration override validation")
struct ConfigurationOverrideValidationTests {
    private let validator = ConfigurationOverrideValidator()

    @Test("CIDR parser strictly accepts IPv4 and IPv6 networks")
    func cidrParsing() throws {
        #expect(try IPCIDR(parsing: "198.18.0.1/16").family == .ipv4)
        #expect(try IPCIDR(parsing: "2001:db8::/32").family == .ipv6)
        #expect(throws: IPCIDRParseError.invalidAddress("999.1.1.1")) {
            try IPCIDR(parsing: "999.1.1.1/24")
        }
        #expect(throws: IPCIDRParseError.prefixOutOfRange(33, family: .ipv4)) {
            try IPCIDR(parsing: "192.0.2.1/33")
        }
        #expect(throws: IPCIDRParseError.ipv4Required("2001:db8::")) {
            try IPCIDR(parsing: "2001:db8::/32", requiresIPv4: true)
        }
        #expect(throws: IPCIDRParseError.invalidSyntax("192.0.2.1")) {
            try IPCIDR(parsing: "192.0.2.1")
        }
    }

    @Test("DNS validation reports invalid ranges, entries, and policy rows")
    func dnsValidation() {
        let overrides = ProfileStructuredOverrides(
            dns: DNSOverrides(
                fakeIPRange: .set("2001:db8::/32"),
                fakeIPFilter: .set(["", "example.com\nMATCH"]),
                nameserver: .set(["  ", "https://dns.example/dns-query\nsecret"]),
                nameserverPolicy: .set([
                    NameserverPolicyEntry(pattern: " example.com ", servers: []),
                    NameserverPolicyEntry(pattern: "example.com", servers: [""])
                ])
            )
        )

        let result = validator.validate(overrides)
        let codes = Set(result.errors.map(\.code))

        #expect(!result.isValid)
        #expect(codes.contains(.invalidIPv4CIDR))
        #expect(codes.contains(.emptyEntry))
        #expect(codes.contains(.multilineEntry))
        #expect(codes.contains(.duplicateNameserverPolicy))
        #expect(codes.contains(.emptyNameserverPolicy))
    }

    @Test("Known and unknown Mihomo nameserver schemes remain accepted")
    func nameserverSchemesAreNotOverrestricted() {
        let overrides = ProfileStructuredOverrides(
            dns: DNSOverrides(
                nameserver: .set([
                    "https://dns.example/dns-query",
                    "quic://dns.example:853",
                    "future-dns-scheme://resolver.example"
                ])
            )
        )

        #expect(validator.validate(overrides).isValid)
    }

    @Test("Sniffer ports, domains, and CIDRs are validated")
    func snifferValidation() {
        let overrides = ProfileStructuredOverrides(
            sniffer: SnifferOverrides(
                sniff: SnifferProtocolSetOverrides(
                    http: SnifferProtocolOverrides(
                        ports: .set([
                            .single(0),
                            .range(start: 9_000, end: 8_000),
                            .single(65_536)
                        ])
                    )
                ),
                forceDomain: .set(["*.example.com", "+.example.org"]),
                skipDomain: .set(["not allowed"]),
                skipSourceAddress: .set(["192.0.2.0/24", "192.0.2.999/24"]),
                skipDestinationAddress: .set(["2001:db8::/32"])
            )
        )

        let result = validator.validate(overrides)

        #expect(result.errors.filter { $0.code == .invalidPort }.count == 3)
        #expect(result.errors.contains { $0.code == .invalidDomainPattern })
        #expect(result.errors.contains { $0.code == .invalidCIDR })
        #expect(!result.errors.contains { $0.path.contains("force-domain") })
        #expect(!result.errors.contains { $0.path.contains("skip-dst-address") })
    }

    @Test("Normalization trims, deduplicates, and orders structured values")
    func normalization() {
        let overrides = ProfileStructuredOverrides(
            dns: DNSOverrides(
                fakeIPFilter: .set([" +.example.com ", "+.example.com", "example.org"]),
                nameserverPolicy: .set([
                    NameserverPolicyEntry(
                        pattern: " geosite:cn ",
                        servers: [" 1.1.1.1 ", "1.1.1.1", "223.5.5.5"]
                    )
                ])
            ),
            sniffer: SnifferOverrides(
                sniff: SnifferProtocolSetOverrides(
                    tls: SnifferProtocolOverrides(
                        ports: .set([
                            .single(443),
                            .range(start: 8_000, end: 9_000),
                            .single(443),
                            .single(80)
                        ])
                    )
                ),
                skipDomain: .set([" +.apple.com ", "+.apple.com"]),
                skipSourceAddress: .set([" 192.0.2.0/24 ", "192.0.2.0/24"])
            )
        )

        let normalized = validator.normalized(overrides)

        #expect(normalized.dns.fakeIPFilter == .set(["+.example.com", "example.org"]))
        #expect(
            normalized.dns.nameserverPolicy == .set([
                NameserverPolicyEntry(
                    pattern: "geosite:cn",
                    servers: ["1.1.1.1", "223.5.5.5"]
                )
            ])
        )
        #expect(
            normalized.sniffer.sniff.tls.ports
                == .set([.single(80), .single(443), .range(start: 8_000, end: 9_000)])
        )
        #expect(normalized.sniffer.skipDomain == .set(["+.apple.com"]))
        #expect(normalized.sniffer.skipSourceAddress == .set(["192.0.2.0/24"]))
    }

    @Test("Rule overrides reject incomplete entries and normalize duplicates")
    func ruleValidationAndNormalization() {
        let invalid = validator.validate(
            ProfileStructuredOverrides(prependedRules: [
                "DOMAIN-SUFFIX,,DIRECT",
                "DOMAIN-SUFFIX,example.com",
                "DOMAIN,example.com,DIRECT\nMATCH,REJECT",
            ])
        )

        #expect(invalid.errors.contains { $0.code == .emptyEntry })
        #expect(invalid.errors.contains { $0.code == .multilineEntry })

        let normalized = validator.normalized(
            ProfileStructuredOverrides(prependedRules: [
                " DOMAIN-SUFFIX, example.com , DIRECT ",
                "DOMAIN-SUFFIX,example.com,DIRECT",
            ])
        )
        #expect(normalized.prependedRules == ["DOMAIN-SUFFIX,example.com,DIRECT"])
    }

    @Test("Unsupported document schemas fail closed")
    func unsupportedSchema() {
        let result = validator.validate(ProfileStructuredOverrides(schemaVersion: 99))
        #expect(result.errors == [
            ConfigurationOverrideValidationIssue(
                severity: .error,
                code: .unsupportedSchemaVersion,
                path: "schemaVersion",
                message: "Unsupported override schema version 99."
            )
        ])
    }
}
