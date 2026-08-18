import Foundation
import Testing
@testable import Vela

@Suite("Mihomo V0.2 controller models")
struct MihomoV02ModelsTests {
    @Test("Proxy subscription info accepts upstream uppercase and lowercase keys")
    func subscriptionInfoKeyCompatibility() throws {
        let uppercase = try decodeFixture(
            MihomoProxyProvidersResponse.self,
            named: "proxy-providers-v0.2.json"
        )
        let upperInfo = try #require(uppercase.providers["airport"]?.subscriptionInfo)
        #expect(upperInfo.upload == 1_024)
        #expect(upperInfo.download == 2_048)
        #expect(upperInfo.total == 107_374_182_400)
        #expect(upperInfo.expire == 1_893_456_000)

        let lowercaseData = Data(#"""
        {
          "providers": {
            "lowercase": {
              "proxies": [],
              "subscriptionInfo": {
                "upload": "11",
                "download": 22,
                "total": 33,
                "expire": "44"
              }
            }
          }
        }
        """#.utf8)
        let lowercase = try JSONDecoder().decode(
            MihomoProxyProvidersResponse.self,
            from: lowercaseData
        )
        #expect(lowercase.providers["lowercase"]?.subscriptionInfo == MihomoSubscriptionInfo(
            upload: 11,
            download: 22,
            total: 33,
            expire: 44
        ))
    }

    @Test("Rule provider fixture keeps metadata and optional inline payload")
    func ruleProviderFixture() throws {
        let response = try decodeFixture(
            MihomoRuleProvidersResponse.self,
            named: "rule-providers-v0.2.json"
        )

        #expect(response.providers["private"]?.behavior == "Domain")
        #expect(response.providers["private"]?.ruleCount == 42)
        #expect(response.providers["inline-rules"]?.vehicleType == "Inline")
        #expect(response.providers["inline-rules"]?.payload == [
            "DOMAIN-SUFFIX,example.com",
            "IP-CIDR,192.0.2.0/24",
        ])
    }

    @Test("Connection fixture accepts string and number ports plus both ISO-8601 date variants")
    func connectionFixture() throws {
        let snapshot = try decodeFixture(
            ConnectionsSnapshot.self,
            named: "connections-snapshot-v0.2.json"
        )

        #expect(snapshot.downloadTotal == 987_654)
        #expect(snapshot.uploadTotal == 123_456)
        #expect(snapshot.memory == 67_108_864)
        #expect(snapshot.connections.count == 2)
        #expect(snapshot.connections[0].metadata.sourcePort == 54_321)
        #expect(snapshot.connections[0].metadata.destinationPort == 443)
        #expect(snapshot.connections[0].metadata.inboundPort == 7_890)
        #expect(snapshot.connections[1].metadata.sourcePort == 55_001)
        #expect(snapshot.connections[1].metadata.destinationPort == 53)
        #expect(snapshot.connections.allSatisfy { $0.start != nil })
        let firstStart = try #require(snapshot.connections[0].start)
        let secondStart = try #require(snapshot.connections[1].start)
        #expect(firstStart < secondStart)
    }

    @Test("Connection decoder tolerates absent optional payload fields")
    func sparseConnection() throws {
        let response = try JSONDecoder().decode(
            ConnectionsSnapshot.self,
            from: Data(#"{"connections":[{"id":"sparse"}]}"#.utf8)
        )

        let connection = try #require(response.connections.first)
        #expect(response.downloadTotal == 0)
        #expect(response.uploadTotal == 0)
        #expect(connection.metadata == .empty)
        #expect(connection.upload == 0)
        #expect(connection.download == 0)
        #expect(connection.start == nil)
        #expect(connection.chains.isEmpty)
        #expect(connection.providerChains.isEmpty)
    }

    @Test("Rules preserve original indexes and map Go zero time to nil")
    func rulesFixture() throws {
        let response = try decodeFixture(
            MihomoRulesResponse.self,
            named: "rules-v0.2.json"
        )

        #expect(response.rules.map(\.index) == [0, 1, 2])
        #expect(response.rules[0].extra?.hitCount == 12)
        #expect(response.rules[0].extra?.hitAt != nil)
        #expect(response.rules[1].extra == nil)
        #expect(response.rules[2].extra?.hitAt == nil)
        #expect(response.rules[2].extra?.missAt == nil)
    }

    private func decodeFixture<Value: Decodable>(
        _ type: Value.Type,
        named name: String
    ) throws -> Value {
        guard let bundledURL = Bundle(for: MihomoMockURLProtocol.self).url(
            forResource: name,
            withExtension: nil
        ) else {
            throw MihomoV02ModelsTestError.missingFixture(name)
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: bundledURL))
    }
}

nonisolated private enum MihomoV02ModelsTestError: Error {
    case missingFixture(String)
}
