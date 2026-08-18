import Foundation
import Testing
@testable import Vela

@Suite("Static configuration catalog")
struct StaticConfigurationCatalogTests {
    @Test("Selected configuration exposes rules, inline proxies, groups, and providers offline")
    func parsesSelectedConfiguration() async throws {
        let fixture = try await makeCatalogFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let snapshot = try #require(try await fixture.catalog.selectedSnapshot())

        #expect(snapshot.profileID == fixture.profileID)
        #expect(snapshot.rules.map(\.type) == ["DOMAIN-SUFFIX", "AND", "IP-CIDR"])
        #expect(snapshot.rules.map(\.proxy) == ["Proxy", "DIRECT", "DIRECT"])
        #expect(snapshot.rules[1].payload == "((DOMAIN,example.com),(NETWORK,UDP))")

        let group = try #require(snapshot.proxyCatalog.group(named: "Proxy"))
        #expect(group.type == "URLTest")
        #expect(group.nodes.map(\.name) == ["Hong Kong", "Japan", "DIRECT"])
        #expect(group.nodes.map(\.type) == ["ss", "vmess", nil])

        let proxyProvider = try #require(snapshot.providers.proxyProviders["remote-nodes"])
        #expect(proxyProvider.name == "remote-nodes")
        #expect(proxyProvider.vehicleType == "HTTP")
        #expect(proxyProvider.testURL == "https://example.com/generate_204")
        let ruleProvider = try #require(snapshot.providers.ruleProviders["geosite"])
        #expect(ruleProvider.name == "geosite")
        #expect(ruleProvider.vehicleType == "HTTP")
        #expect(ruleProvider.behavior == "domain")
    }

    @Test("Rules service falls back to selected static rules when Controller is unavailable")
    func rulesFallback() async throws {
        let fixture = try await makeCatalogFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let generation = ConfigurationGeneration(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000F001")!
        )
        let service = RulesService(
            apiClient: OfflineCatalogAPI(),
            staticConfigurationCatalog: fixture.catalog,
            generation: generation
        )

        let rules = try await service.refresh()

        #expect(rules.count == 3)
        #expect(rules.map(\.originalIndex) == [0, 1, 2])
        #expect(rules.allSatisfy { $0.id.configurationGeneration == generation })
        #expect(rules.allSatisfy { $0.value.extra == nil })
    }

    @Test("Provider service falls back to selected static providers when Controller is unavailable")
    func providersFallback() async throws {
        let fixture = try await makeCatalogFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ProviderManagementService(
            apiClient: OfflineCatalogAPI(),
            staticConfigurationCatalog: fixture.catalog
        )

        let snapshot = try await service.refresh()

        #expect(snapshot.proxyProviders.keys.sorted() == ["remote-nodes"])
        #expect(snapshot.ruleProviders.keys.sorted() == ["geosite"])
    }

    private func makeCatalogFixture() async throws -> CatalogFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VelaStaticCatalogTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceURL = root.appendingPathComponent("fixture.yaml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.yaml.utf8).write(to: sourceURL, options: .atomic)

        let profileStore = ProfileStore(
            directories: ApplicationDirectories(root: root.appendingPathComponent("data"))
        )
        let profile = try await profileStore.importProfile(from: sourceURL, name: "Offline")
        try await profileStore.selectProfile(id: profile.id)
        return CatalogFixture(
            root: root,
            profileID: profile.id,
            catalog: StaticConfigurationCatalogService(profileStore: profileStore)
        )
    }

    private static let yaml = #"""
    proxies:
      - name: Hong Kong
        type: ss
        server: hk.example.com
        port: 443
        cipher: aes-128-gcm
        password: test
      - name: Japan
        type: vmess
        server: jp.example.com
        port: 443
        uuid: 00000000-0000-0000-0000-000000000001
    proxy-groups:
      - name: Proxy
        type: url-test
        url: https://example.com/generate_204
        proxies: [Hong Kong, Japan, DIRECT]
    proxy-providers:
      remote-nodes:
        type: http
        url: https://example.com/nodes.yaml
        path: ./providers/nodes.yaml
        health-check:
          enable: true
          url: https://example.com/generate_204
    rule-providers:
      geosite:
        type: http
        behavior: domain
        format: yaml
        url: https://example.com/geosite.yaml
        path: ./providers/geosite.yaml
    rules:
      - DOMAIN-SUFFIX,example.com,Proxy
      - AND,((DOMAIN,example.com),(NETWORK,UDP)),DIRECT
      - IP-CIDR,192.0.2.0/24,DIRECT,no-resolve
    """#
}

private struct CatalogFixture {
    let root: URL
    let profileID: UUID
    let catalog: StaticConfigurationCatalogService
}

private struct OfflineCatalogAPI: MihomoAPIProviding {
    private struct Disconnected: Error {}

    func version() async throws -> MihomoVersion { throw Disconnected() }
    func configs() async throws -> MihomoConfigs { throw Disconnected() }
    func patchConfigs(_: MihomoConfigPatch) async throws { throw Disconnected() }
    func proxies() async throws -> MihomoProxiesResponse { throw Disconnected() }
    func proxyDelay(
        name _: String,
        url _: String,
        timeoutMilliseconds _: Int,
        expectedStatus _: String?
    ) async throws -> MihomoProxyDelayResponse {
        throw Disconnected()
    }
}
