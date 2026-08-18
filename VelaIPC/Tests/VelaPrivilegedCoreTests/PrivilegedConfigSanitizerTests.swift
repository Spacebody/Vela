import Foundation
import Testing
import VelaIPC
import Yams
@testable import VelaPrivilegedCore

@Suite("Root runtime configuration sanitizer")
struct PrivilegedConfigSanitizerTests {
    @Test("Forces a loopback controller and removes expansion surfaces")
    func controllerIsForced() throws {
        let yaml = """
        mixed-port: 80
        port: 22
        socks-port: 23
        allow-lan: true
        bind-address: "*"
        external-controller: 0.0.0.0:9090
        external-controller-tls: 0.0.0.0:9443
        secret: attacker-secret
        external-ui-url: https://attacker.invalid/ui.zip
        external-controller-cors:
          allow-origins: ["*"]
        dns:
          enable: true
          nameserver: [1.1.1.1]
        rules: [MATCH,DIRECT]
        """
        let output = try sanitizer().sanitize(
            configuration: Data(yaml.utf8),
            tunSettings: TunSettings(localMixedPort: 55_000),
            resources: [],
            controllerPort: 55_001
        )
        let root = try mapping(output.data)

        #expect(root["external-controller"] as? String == "127.0.0.1:55001")
        #expect(root["secret"] as? String == TestSecretGenerator.value)
        #expect(root["allow-lan"] as? Bool == false)
        #expect(root["bind-address"] as? String == "127.0.0.1")
        #expect(root["mixed-port"] as? Int == 55_000)
        #expect(root["port"] as? Int == 0)
        #expect(root["external-controller-tls"] == nil)
        #expect(root["external-ui-url"] == nil)
        #expect(root["external-controller-cors"] == nil)
        #expect(!output.description.contains(TestSecretGenerator.value))
        #expect(!output.changes.description.contains("attacker.invalid"))
        #expect(!output.changes.description.contains("attacker-secret"))
    }

    @Test("Rejects custom server inbounds instead of silently running them as root")
    func rejectsListener() {
        let yaml = """
        listeners:
          - name: bad
            type: http
            port: 22
            listen: 0.0.0.0
        dns:
          enable: true
          nameserver: [1.1.1.1]
        """
        #expect(throws: PrivilegedConfigSanitizerError.unsafeInbound("listeners")) {
            _ = try sanitizer().sanitize(
                configuration: Data(yaml.utf8),
                tunSettings: .defaults,
                resources: [],
                controllerPort: 55_001
            )
        }
    }

    @Test("Rejects tunnel listeners that would bind arbitrary root-owned ports")
    func rejectsTunnelListener() {
        let yaml = """
        tunnels:
          - tcp/udp,0.0.0.0:22,example.invalid:22
        dns:
          enable: true
          nameserver: [1.1.1.1]
        """
        #expect(throws: PrivilegedConfigSanitizerError.unsafeInbound("tunnels")) {
            _ = try sanitizer().sanitize(
                configuration: Data(yaml.utf8),
                tunSettings: .defaults,
                resources: [],
                controllerPort: 55_001
            )
        }
    }

    @Test("Removes root-amplified network, clock, TLS, and host configuration")
    func removesRootPrivilegeSurfaces() throws {
        let yaml = """
        mode: rule
        dns:
          enable: true
          nameserver: [1.1.1.1]
          listen: 0.0.0.0:53
          listen-routing-mark: 31337
        ntp:
          enable: true
          write-to-system: true
          server: attacker.invalid
        tls:
          client-auth-cert: /etc/passwd
        iptables:
          enable: true
        external-controller-routing-mark: 11
        routing-mark: 12
        geo-auto-update: true
        geox-url:
          geoip: file:///etc/passwd
        interface-name: en9
        profile:
          store-selected: true
        rules: [MATCH,DIRECT]
        """

        let output = try sanitizer().sanitize(
            configuration: Data(yaml.utf8),
            tunSettings: .defaults,
            resources: [],
            controllerPort: 55_001
        )
        let root = try mapping(output.data)
        let dns = try #require(root["dns"] as? [String: Any])

        #expect(dns["listen"] == nil)
        #expect(dns["listen-routing-mark"] == nil)
        #expect(root["ntp"] == nil)
        #expect(root["tls"] == nil)
        #expect(root["iptables"] == nil)
        #expect(root["external-controller-routing-mark"] == nil)
        #expect(root["routing-mark"] == nil)
        #expect(root["geox-url"] == nil)
        #expect(root["interface-name"] == nil)
        #expect(root["geo-auto-update"] as? Bool == false)
        #expect(root["mode"] as? String == "rule")
        #expect(root["profile"] != nil)

        let expectedChanges = [
            SanitizerChange(path: "dns.listen", action: .removed),
            SanitizerChange(path: "dns.listen-routing-mark", action: .removed),
            SanitizerChange(path: "ntp", action: .removed),
            SanitizerChange(path: "tls", action: .removed),
            SanitizerChange(path: "iptables", action: .removed),
            SanitizerChange(path: "external-controller-routing-mark", action: .removed),
            SanitizerChange(path: "routing-mark", action: .removed),
            SanitizerChange(path: "geo-auto-update", action: .overwritten),
            SanitizerChange(path: "geox-url", action: .removed),
            SanitizerChange(path: "interface-name", action: .removed),
        ]
        #expect(expectedChanges.allSatisfy(output.changes.contains))
        #expect(!output.changes.description.contains("attacker.invalid"))
        #expect(!output.changes.description.contains("/etc/passwd"))
    }

    @Test("Typed TUN settings replace all untrusted TUN fields")
    func typedTunWins() throws {
        let yaml = """
        dns:
          enable: true
          nameserver: [1.1.1.1]
        tun:
          enable: false
          stack: attacker
          auto-redirect: true
          gso: true
          include-uid: [0]
        """
        let output = try sanitizer().sanitize(
            configuration: Data(yaml.utf8),
            tunSettings: TunSettings(
                stack: .gvisor,
                routeExcludeCIDRs: ["192.168.1.0/24"],
                mtu: 1_400
            ),
            resources: [],
            controllerPort: 55_001
        )
        let root = try mapping(output.data)
        let tun = try #require(root["tun"] as? [String: Any])
        #expect(tun["enable"] as? Bool == true)
        #expect(tun["stack"] as? String == "gvisor")
        #expect(tun["auto-redirect"] == nil)
        #expect(tun["gso"] == nil)
        #expect(tun["include-uid"] == nil)
        #expect(tun["mtu"] as? Int == 1_400)
    }

    @Test("Rewrites staged file providers to root-owned relative resources")
    func rewritesFileProviders() throws {
        let yaml = """
        dns:
          enable: true
          nameserver: [1.1.1.1]
        proxy-providers:
          local-proxies:
            type: file
            path: ../../../../etc/passwd
        rule-providers:
          local-rules:
            type: file
            behavior: domain
            path: /etc/hosts
        """
        let resources = [
            SanitizerResource(
                logicalID: "local-proxies",
                kind: .proxyProvider,
                runtimeRelativePath: try SafeRelativePath("resources/providers/proxies.yaml")
            ),
            SanitizerResource(
                logicalID: "local-rules",
                kind: .ruleProvider,
                runtimeRelativePath: try SafeRelativePath("resources/providers/rules.yaml")
            ),
        ]
        let output = try sanitizer().sanitize(
            configuration: Data(yaml.utf8),
            tunSettings: .defaults,
            resources: resources,
            controllerPort: 55_001
        )
        let root = try mapping(output.data)
        let proxyProviders = try #require(root["proxy-providers"] as? [String: Any])
        let proxy = try #require(proxyProviders["local-proxies"] as? [String: Any])
        let ruleProviders = try #require(root["rule-providers"] as? [String: Any])
        let rule = try #require(ruleProviders["local-rules"] as? [String: Any])
        #expect(proxy["path"] as? String == "resources/providers/proxies.yaml")
        #expect(rule["path"] as? String == "resources/providers/rules.yaml")
        #expect(!String(decoding: output.data, as: UTF8.self).contains("/etc/"))
    }

    @Test("Same provider name is resolved by its typed logical ID")
    func sameNameAcrossProviderKinds() throws {
        let yaml = """
        proxy-providers:
          shared:
            type: file
            path: ./providers/proxies.yaml
        rule-providers:
          shared:
            type: file
            behavior: domain
            path: ./providers/rules.yaml
        """
        let resources = [
            SanitizerResource(
                logicalID: "proxyProvider:shared",
                kind: .proxyProvider,
                runtimeRelativePath: try SafeRelativePath(
                    "resources/providers/proxyProvider/proxies.yaml"
                )
            ),
            SanitizerResource(
                logicalID: "ruleProvider:shared",
                kind: .ruleProvider,
                runtimeRelativePath: try SafeRelativePath(
                    "resources/providers/ruleProvider/rules.yaml"
                )
            ),
        ]

        let output = try sanitizer().sanitize(
            configuration: Data(yaml.utf8),
            tunSettings: TunSettings(dnsHijack: false),
            resources: resources,
            controllerPort: 55_001
        )
        let root = try mapping(output.data)
        let proxyProviders = try #require(root["proxy-providers"] as? [String: Any])
        let proxy = try #require(proxyProviders["shared"] as? [String: Any])
        let ruleProviders = try #require(root["rule-providers"] as? [String: Any])
        let rule = try #require(ruleProviders["shared"] as? [String: Any])

        #expect(
            proxy["path"] as? String
                == "resources/providers/proxyProvider/proxies.yaml"
        )
        #expect(
            rule["path"] as? String
                == "resources/providers/ruleProvider/rules.yaml"
        )
    }

    @Test("Rejects an unstaged local provider")
    func rejectsUnstagedProvider() {
        let yaml = """
        dns:
          enable: true
          nameserver: [1.1.1.1]
        proxy-providers:
          bad:
            type: file
            path: ../../../../etc/passwd
        """
        #expect(throws: PrivilegedConfigSanitizerError.missingStagedResource("bad")) {
            _ = try sanitizer().sanitize(
                configuration: Data(yaml.utf8),
                tunSettings: .defaults,
                resources: [],
                controllerPort: 55_001
            )
        }
    }

    @Test("Drops unsupported top-level TLS material before root execution")
    func dropsUnsupportedCertificate() throws {
        let yaml = """
        dns:
          enable: true
          nameserver: [1.1.1.1]
        tls:
          certificate: /etc/passwd
        """
        let output = try sanitizer().sanitize(
            configuration: Data(yaml.utf8),
            tunSettings: .defaults,
            resources: [],
            controllerPort: 55_001
        )
        let root = try mapping(output.data)
        #expect(root["tls"] == nil)
        #expect(output.changes.contains(SanitizerChange(path: "tls", action: .removed)))
    }

    @Test("Rejects DNS hijack when Mihomo DNS is not usable")
    func dnsPrecondition() {
        let yaml = "dns:\n  enable: false\n"
        #expect(throws: PrivilegedConfigSanitizerError.dnsPreconditionFailed) {
            _ = try sanitizer().sanitize(
                configuration: Data(yaml.utf8),
                tunSettings: .defaults,
                resources: [],
                controllerPort: 55_001
            )
        }
    }

    @Test("Rejects an alias-heavy YAML before root execution")
    func aliasBudget() {
        let aliases = (0..<17).map { "value\($0): &a\($0) x" }.joined(separator: "\n")
        #expect(throws: PrivilegedConfigSanitizerError.aliasesLimitExceeded) {
            _ = try sanitizer().sanitize(
                configuration: Data(aliases.utf8),
                tunSettings: TunSettings(dnsHijack: false),
                resources: [],
                controllerPort: 55_001
            )
        }
    }

    private func sanitizer() -> PrivilegedConfigSanitizer {
        PrivilegedConfigSanitizer(secretGenerator: TestSecretGenerator())
    }

    private func mapping(_ data: Data) throws -> [String: Any] {
        let yaml = String(decoding: data, as: UTF8.self)
        return try #require(Yams.load(yaml: yaml) as? [String: Any])
    }
}

private struct TestSecretGenerator: ControllerSecretGenerating {
    static let value = "test-controller-secret-never-log"
    func makeSecret() throws -> SecretValue { SecretValue(Self.value) }
}
