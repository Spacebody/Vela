import Foundation
import Testing
@testable import Vela

@Suite("Configuration override Codable models")
struct ConfigurationOverrideCodableTests {
    @Test("OverrideValue uses an explicit stable mode envelope")
    func stableModeEnvelope() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let inherited = try encoder.encode(OverrideValue<Bool>.inherit)
        let set = try encoder.encode(OverrideValue<Bool>.set(true))
        let removed = try encoder.encode(OverrideValue<Bool>.remove)

        #expect(String(decoding: inherited, as: UTF8.self) == #"{"mode":"inherit"}"#)
        #expect(String(decoding: set, as: UTF8.self) == #"{"mode":"set","value":true}"#)
        #expect(String(decoding: removed, as: UTF8.self) == #"{"mode":"remove"}"#)

        let decoder = JSONDecoder()
        #expect(try decoder.decode(OverrideValue<Bool>.self, from: inherited) == .inherit)
        #expect(try decoder.decode(OverrideValue<Bool>.self, from: set) == .set(true))
        #expect(try decoder.decode(OverrideValue<Bool>.self, from: removed) == .remove)
    }

    @Test("Malformed mode envelopes are rejected")
    func malformedModeEnvelopeIsRejected() {
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                OverrideValue<Bool>.self,
                from: Data(#"{"mode":"set"}"#.utf8)
            )
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                OverrideValue<Bool>.self,
                from: Data(#"{"mode":"inherit","value":true}"#.utf8)
            )
        }
    }

    @Test("Missing typed fields default to inherit")
    func missingFieldsDefaultToInherit() throws {
        let data = Data(
            #"{"schemaVersion":1,"dns":{"enable":{"mode":"set","value":true}}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(ProfileStructuredOverrides.self, from: data)

        #expect(decoded.dns.enable == .set(true))
        #expect(decoded.dns.ipv6 == .inherit)
        #expect(decoded.dns.nameserverPolicy == .inherit)
        #expect(decoded.sniffer.enable == .inherit)
        #expect(decoded.sniffer.sniff.tls.ports == .inherit)
        #expect(decoded.prependedRules.isEmpty)
    }

    @Test("The complete typed document round-trips")
    func completeDocumentRoundTrips() throws {
        let overrides = ProfileStructuredOverrides(
            dns: DNSOverrides(
                enable: .set(true),
                ipv6: .remove,
                enhancedMode: .set(.fakeIP),
                fakeIPRange: .set("198.18.0.1/16"),
                fakeIPFilterMode: .set(.rule),
                fakeIPFilter: .set(["+.example.com"]),
                useHosts: .set(true),
                useSystemHosts: .set(false),
                respectRules: .set(true),
                defaultNameserver: .set(["223.5.5.5"]),
                nameserver: .set(["https://dns.example/dns-query"]),
                fallback: .remove,
                proxyServerNameserver: .set(["1.1.1.1"]),
                directNameserver: .set(["system"]),
                directNameserverFollowPolicy: .set(true),
                nameserverPolicy: .set([
                    NameserverPolicyEntry(
                        pattern: "geosite:cn",
                        servers: ["https://dns.example/dns-query"]
                    )
                ])
            ),
            sniffer: SnifferOverrides(
                enable: .set(true),
                forceDNSMapping: .set(true),
                parsePureIP: .set(true),
                overrideDestination: .set(false),
                sniff: SnifferProtocolSetOverrides(
                    http: SnifferProtocolOverrides(
                        ports: .set([.single(80), .range(start: 8080, end: 8880)]),
                        overrideDestination: .set(true)
                    ),
                    tls: SnifferProtocolOverrides(ports: .set([.single(443)])),
                    quic: SnifferProtocolOverrides(ports: .remove)
                ),
                forceDomain: .set(["+.example.com"]),
                skipDomain: .set(["Mijia Cloud"]),
                skipSourceAddress: .set(["192.0.2.0/24"]),
                skipDestinationAddress: .set(["2001:db8::/32"])
            ),
            prependedRules: ["DOMAIN-SUFFIX,example.com,DIRECT"]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(overrides)
        let decoded = try JSONDecoder().decode(ProfileStructuredOverrides.self, from: data)

        #expect(decoded == overrides)
        #expect(String(decoding: data, as: UTF8.self).contains(#""enhanced-mode""#))
        #expect(String(decoding: data, as: UTF8.self).contains(#""TLS""#))
        #expect(decoded.prependedRules == ["DOMAIN-SUFFIX,example.com,DIRECT"])
    }

    @Test("Sniffer ports parse and encode canonically")
    func snifferPortCanonicalization() throws {
        #expect(try SnifferPort(parsing: " 443 ") == .single(443))
        #expect(try SnifferPort(parsing: "8000...9000") == .range(start: 8000, end: 9000))
        #expect(try SnifferPort(parsing: "8000:9000") == .range(start: 8000, end: 9000))
        #expect(throws: SnifferPortParseError.outOfRange(start: 0, end: 0)) {
            try SnifferPort(parsing: "0")
        }
        #expect(throws: SnifferPortParseError.rangeIsDescending(start: 9000, end: 8000)) {
            try SnifferPort(parsing: "9000-8000")
        }

        let data = try JSONEncoder().encode(SnifferPort.range(start: 8000, end: 9000))
        #expect(String(decoding: data, as: UTF8.self) == #""8000-9000""#)
    }
}
