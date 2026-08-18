import Foundation
import Testing
@testable import Vela

@Suite("Proxy catalog models")
struct ProxyModelsTests {
    @Test("Catalog keeps visible groups in stable name order and members in API order")
    func stableGroupSortingAndMemberOrder() throws {
        let catalog = try makeCatalog(from: #"""
        {
          "proxies": {
            "Zulu": {
              "name": "Zulu",
              "type": "Fallback",
              "now": "Missing Node",
              "fixed": "",
              "all": ["Node B", "Missing Node", "Node A"],
              "hidden": false,
              "testUrl": "https://example.com/generate_204",
              "expectedStatus": "200/204"
            },
            "Node A": {"name": "Node A", "type": "Shadowsocks"},
            "Alpha": {
              "name": "Alpha",
              "type": "Selector",
              "now": "Node A",
              "all": ["Node A"]
            },
            "Hidden": {
              "name": "Hidden",
              "type": "Selector",
              "all": ["Node A"],
              "hidden": true
            },
            "Node B": {"name": "Node B", "type": "Trojan"},
            "DIRECT": {"name": "DIRECT", "type": "Direct"}
          }
        }
        """#)

        #expect(catalog.groups.map(\.name) == ["Alpha", "Zulu"])

        let zulu = try #require(catalog.group(named: "Zulu"))
        #expect(zulu.nodes.map(\.name) == ["Node B", "Missing Node", "Node A"])
        #expect(zulu.type == "Fallback")
        #expect(zulu.now == "Missing Node")
        #expect(zulu.fixed == "")
        #expect(zulu.testURL == "https://example.com/generate_204")
        #expect(zulu.expectedStatus == "200/204")
    }

    @Test("Member state for the group test URL wins and missing members remain placeholders")
    func testURLStateAndMissingMembers() throws {
        let catalog = try makeCatalog(from: #"""
        {
          "proxies": {
            "Primary": {
              "name": "Primary",
              "type": "Selector",
              "now": "Missing Node",
              "fixed": "Node B",
              "all": ["Node B", "Missing Node", "Node A"],
              "testUrl": "https://example.com/generate_204"
            },
            "Node A": {
              "name": "Node A",
              "type": "WireGuard",
              "alive": true,
              "history": [{"time": "latest", "delay": 48}],
              "extra": {
                "https://example.com/generate_204": {
                  "alive": false
                }
              }
            },
            "Node B": {
              "name": "Node B",
              "type": "Trojan",
              "alive": true,
              "history": [{"time": "latest", "delay": 99}],
              "extra": {
                "https://example.com/other": {
                  "alive": true,
                  "history": [{"time": "latest", "delay": 7}]
                },
                "https://example.com/generate_204": {
                  "alive": false,
                  "history": [
                    {"time": "first", "delay": 21},
                    {"time": "latest", "delay": 0}
                  ]
                }
              }
            }
          }
        }
        """#)

        let group = try #require(catalog.group(named: "Primary"))
        let nodeB = try #require(group.nodes.first { $0.name == "Node B" })
        #expect(nodeB.type == "Trojan")
        #expect(nodeB.alive == false)
        #expect(nodeB.delay == .unavailable)
        #expect(nodeB.isFixed)
        #expect(!nodeB.isCurrent)
        #expect(!nodeB.isPlaceholder)

        let missing = try #require(group.nodes.first { $0.name == "Missing Node" })
        #expect(missing.type == nil)
        #expect(missing.alive == nil)
        #expect(missing.delay == .untested)
        #expect(missing.isCurrent)
        #expect(!missing.isFixed)
        #expect(missing.isPlaceholder)

        let nodeA = try #require(group.nodes.first { $0.name == "Node A" })
        #expect(nodeA.alive == false)
        #expect(nodeA.delay == .measured(milliseconds: 48))
    }

    @Test("Only the three supported raw group types are selectable")
    func selectableRawTypes() throws {
        let catalog = try makeCatalog(from: #"""
        {
          "proxies": {
            "Selector": {"name": "Selector", "type": "Selector", "all": []},
            "URLTest": {"name": "URLTest", "type": "URLTest", "all": []},
            "Fallback": {"name": "Fallback", "type": "Fallback", "all": []},
            "LoadBalance": {"name": "LoadBalance", "type": "LoadBalance", "all": []},
            "lowercase": {"name": "lowercase", "type": "selector", "all": []}
          }
        }
        """#)

        let selectableByName = Dictionary(
            uniqueKeysWithValues: catalog.groups.map { ($0.name, $0.isSelectable) }
        )
        #expect(selectableByName == [
            "Selector": true,
            "URLTest": true,
            "Fallback": true,
            "LoadBalance": false,
            "lowercase": false,
        ])
        #expect(catalog.group(named: "LoadBalance")?.type == "LoadBalance")
        #expect(catalog.group(named: "lowercase")?.type == "selector")
    }

    @Test("Latest delay distinguishes untested, unavailable, and measured nodes")
    func latestDelayMapping() throws {
        let catalog = try makeCatalog(from: #"""
        {
          "proxies": {
            "Group": {
              "name": "Group",
              "type": "Selector",
              "all": ["No History", "Empty History", "Unavailable", "Measured"]
            },
            "No History": {"name": "No History", "type": "Direct"},
            "Empty History": {"name": "Empty History", "type": "Direct", "history": []},
            "Unavailable": {
              "name": "Unavailable",
              "type": "Direct",
              "history": [
                {"time": "first", "delay": 18},
                {"time": "latest", "delay": 0}
              ]
            },
            "Measured": {
              "name": "Measured",
              "type": "Direct",
              "history": [
                {"time": "first", "delay": 0},
                {"time": "latest", "delay": 91}
              ],
              "extra": {
                "https://www.gstatic.com/generate_204": {
                  "alive": true,
                  "history": [{"time": "latest", "delay": 73}]
                }
              }
            }
          }
        }
        """#)

        let group = try #require(catalog.group(named: "Group"))
        #expect(group.nodes.first { $0.name == "No History" }?.delay == .untested)
        #expect(group.nodes.first { $0.name == "Empty History" }?.delay == .untested)
        #expect(group.nodes.first { $0.name == "Unavailable" }?.delay == .unavailable)
        #expect(group.nodes.first { $0.name == "Measured" }?.delay == .measured(milliseconds: 73))
        #expect(group.nodes.first { $0.name == "Measured" }?.delay.milliseconds == 73)
        #expect(group.nodes.first { $0.name == "Unavailable" }?.delay.milliseconds == nil)
    }

    @Test("Provider nodes keep origin and composite identity without overwriting same-name nodes")
    func providerOriginsAndCompositeIdentity() throws {
        let runtimeResponse = try JSONDecoder().decode(
            MihomoProxiesResponse.self,
            from: Data(#"""
            {
              "proxies": {
                "Primary": {
                  "name": "Primary",
                  "type": "Selector",
                  "now": "Provider Only",
                  "all": ["Provider Only", "Shared Node", "Missing Node"]
                },
                "Shared Node": {
                  "name": "Shared Node",
                  "type": "Direct",
                  "alive": true
                }
              }
            }
            """#.utf8)
        )
        let providerResponse = try providerFixture()

        let catalog = ProxyCatalog(
            runtimeResponse: runtimeResponse,
            providerResponse: providerResponse
        )

        #expect(catalog.providers.map(\.name) == [
            "Partial Provider", "Provider A", "Provider B",
        ])
        #expect(catalog.nodes(named: "Shared Node").map(\.id) == [
            ProxyCatalogID(origin: .runtime, name: "Shared Node"),
            ProxyCatalogID(origin: .provider(name: "Provider A"), name: "Shared Node"),
            ProxyCatalogID(origin: .provider(name: "Provider B"), name: "Shared Node"),
        ])
        #expect(catalog.node(id: ProxyCatalogID(
            origin: .provider(name: "Provider A"),
            name: "Provider Only"
        ))?.type == "Shadowsocks")

        let group = try #require(catalog.group(named: "Primary"))
        #expect(group.nodes.map(\.id) == [
            ProxyCatalogID(origin: .provider(name: "Provider A"), name: "Provider Only"),
            ProxyCatalogID(origin: .runtime, name: "Shared Node"),
            ProxyCatalogID(origin: .runtime, name: "Missing Node"),
        ])
        #expect(group.nodes[0].isCurrent)
        #expect(!group.nodes[0].isPlaceholder)
        #expect(group.nodes[2].isPlaceholder)
        #expect(providerResponse.providers["Partial Provider"]?.name == nil)
        #expect(providerResponse.providers["Partial Provider"]?.proxies == [])
    }

    @Test("Nested runtime groups remain single members instead of expanding compatible views")
    func nestedRuntimeGroupsRemainSingleMembers() throws {
        let nodeNames = (1 ... 39).map { "Node \($0)" }
        let countryNames = (1 ... 16).map { "Country \($0)" }
        var runtimeProxies: [String: Any] = Dictionary(
            uniqueKeysWithValues: nodeNames.map { name in
                (name, ["name": name, "type": "AnyTLS"])
            }
        )
        for countryName in countryNames {
            runtimeProxies[countryName] = [
                "name": countryName,
                "type": "Selector",
                "all": [nodeNames[0]],
            ]
        }
        runtimeProxies["Auto"] = [
            "name": "Auto",
            "type": "Fallback",
            "all": countryNames,
        ]
        runtimeProxies["SSRDOG"] = [
            "name": "SSRDOG",
            "type": "Selector",
            "all": nodeNames + ["Auto"],
        ]

        let compatibleProviderNames = [
            "Auto", "default", "Disney", "Google", "HBO",
            "Netflix", "OpenAI", "Telegram", "TikTok",
        ]
        var compatibleProviders: [String: Any] = [:]
        for providerName in compatibleProviderNames {
            var members = countryNames
            if providerName == "Disney" {
                members.removeLast()
            }
            if providerName == "default" {
                members.append("Auto")
            }
            compatibleProviders[providerName] = [
                "name": providerName,
                "type": "Proxy",
                "vehicleType": "Compatible",
                "proxies": members.map { name in
                    ["name": name, "type": "Selector"]
                },
            ]
        }
        compatibleProviders["SSRDOG"] = [
            "name": "SSRDOG",
            "type": "Proxy",
            "vehicleType": "Compatible",
            "proxies": [["name": "Auto", "type": "Fallback"]],
        ]

        let runtimeData = try JSONSerialization.data(withJSONObject: ["proxies": runtimeProxies])
        let providerData = try JSONSerialization.data(
            withJSONObject: ["providers": compatibleProviders]
        )
        let runtimeResponse = try JSONDecoder().decode(
            MihomoProxiesResponse.self,
            from: runtimeData
        )
        let providerResponse = try JSONDecoder().decode(
            MihomoProxyProvidersResponse.self,
            from: providerData
        )

        let catalog = ProxyCatalog(
            runtimeResponse: runtimeResponse,
            providerResponse: providerResponse
        )

        let subscription = try #require(catalog.group(named: "SSRDOG"))
        #expect(subscription.nodes.count == 40)
        #expect(subscription.nodes.map(\.name) == nodeNames + ["Auto"])
        #expect(subscription.nodes.last?.type == "Fallback")

        let automatic = try #require(catalog.group(named: "Auto"))
        #expect(automatic.nodes.count == 16)
        #expect(automatic.nodes.map(\.name) == countryNames)
        #expect(automatic.nodes.allSatisfy { $0.type == "Selector" })
        #expect(catalog.providers.isEmpty)
    }

    @Test("Ambiguous provider-only members remain one safe placeholder")
    func ambiguousProviderOnlyMembersRemainSinglePlaceholders() throws {
        let runtimeResponse = try JSONDecoder().decode(
            MihomoProxiesResponse.self,
            from: Data(#"{"proxies":{"Primary":{"name":"Primary","type":"Selector","all":["Shared"]}}}"#.utf8)
        )
        let providerResponse = try JSONDecoder().decode(
            MihomoProxyProvidersResponse.self,
            from: Data(#"{"providers":{"Provider A":{"vehicleType":"HTTP","proxies":[{"name":"Shared","type":"Trojan"}]},"Provider B":{"vehicleType":"File","proxies":[{"name":"Shared","type":"VLESS"}]}}}"#.utf8)
        )

        let catalog = ProxyCatalog(
            runtimeResponse: runtimeResponse,
            providerResponse: providerResponse
        )
        let group = try #require(catalog.group(named: "Primary"))

        #expect(group.nodes.count == 1)
        #expect(group.nodes[0].name == "Shared")
        #expect(group.nodes[0].isPlaceholder)
        #expect(group.nodes[0].origin == .runtime)
    }

    @Test("Provider fetch failures are structured degradation while runtime groups remain usable")
    func providerFailureDegradesOnlyProviderCatalog() throws {
        let runtimeResponse = try JSONDecoder().decode(
            MihomoProxiesResponse.self,
            from: Data(#"""
            {
              "proxies": {
                "Primary": {
                  "name": "Primary",
                  "type": "Selector",
                  "all": ["DIRECT"]
                },
                "DIRECT": {"name": "DIRECT", "type": "Direct"}
              }
            }
            """#.utf8)
        )
        let fetchError = ProxyCatalogFetchError(
            source: .proxyProviders,
            endpoint: "/providers/proxies",
            message: "Mihomo returned HTTP 500."
        )

        let catalog = ProxyCatalog(
            runtimeResponse: runtimeResponse,
            providerResponse: .empty,
            fetchErrors: [fetchError]
        )

        #expect(catalog.group(named: "Primary")?.nodes.map(\.name) == ["DIRECT"])
        #expect(catalog.fetchErrors == [fetchError])
        #expect(catalog.fetchErrors.first?.localizedDescription.contains("/providers/proxies") == true)
    }

    private func makeCatalog(from json: String) throws -> ProxyCatalog {
        let response = try JSONDecoder().decode(
            MihomoProxiesResponse.self,
            from: Data(json.utf8)
        )
        return ProxyCatalog(response: response)
    }

    private func providerFixture() throws -> MihomoProxyProvidersResponse {
        let name = "providers-proxies-v1.19.28.json"
        guard let fixtureURL = Bundle(for: MihomoMockURLProtocol.self).url(
            forResource: name,
            withExtension: nil
        ) else {
            throw ProxyModelsTestError.missingFixture(name)
        }
        return try JSONDecoder().decode(
            MihomoProxyProvidersResponse.self,
            from: Data(contentsOf: fixtureURL)
        )
    }
}

private enum ProxyModelsTestError: Error {
    case missingFixture(String)
}
