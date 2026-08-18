import Foundation
import Testing
import VelaIPC
@testable import Vela

@Suite("TUN preferences")
struct TunPreferencesTests {
    @Test("UserDefaults store round-trips validated non-secret settings")
    func roundTrip() throws {
        let suite = "dev.yilin.Vela.tests.tun.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsTunPreferenceStore(suiteName: suite)
        let expected = TunPreferences(
            settings: TunSettings(
                stack: .gvisor,
                autoDetectInterface: false,
                outboundInterface: "en0",
                dnsHijack: false,
                allowLocalNetwork: false,
                routeExcludeCIDRs: ["10.0.0.0/8"],
                mtu: 1_380,
                localMixedPort: 17_890
            ),
            restoreSystemProxyAfterTun: false
        )

        store.save(expected)

        #expect(store.load() == expected)
    }

    @Test("Invalid persisted settings fall back to safe defaults")
    func invalidDataFallsBack() throws {
        let suite = "dev.yilin.Vela.tests.tun.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: "privilegedTun.preferences.v1")

        #expect(UserDefaultsTunPreferenceStore(suiteName: suite).load() == .defaults)
    }

    @Test("Transient store never reads or mutates process defaults")
    func transientIsIsolated() {
        let expected = TunPreferences(
            settings: TunSettings(stack: .system, dnsHijack: false),
            restoreSystemProxyAfterTun: false
        )
        let store = TransientTunPreferenceStore(preferences: expected)

        store.save(.defaults)

        #expect(store.load() == expected)
    }
}
