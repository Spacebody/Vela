import Foundation
import VelaIPC

nonisolated struct TunPreferences: Codable, Equatable, Sendable {
    var settings: TunSettings
    var restoreSystemProxyAfterTun: Bool

    static let defaults = TunPreferences(
        settings: .defaults,
        restoreSystemProxyAfterTun: true
    )
}

nonisolated protocol TunPreferenceStoring: Sendable {
    func load() -> TunPreferences
    func save(_ preferences: TunPreferences)
}

nonisolated struct TransientTunPreferenceStore: TunPreferenceStoring, Sendable {
    private let preferences: TunPreferences

    init(preferences: TunPreferences = .defaults) {
        self.preferences = preferences
    }

    func load() -> TunPreferences { preferences }
    func save(_ preferences: TunPreferences) {}
}

nonisolated struct UserDefaultsTunPreferenceStore: TunPreferenceStoring, Sendable {
    private let suiteName: String?
    private let key: String

    init(
        suiteName: String? = nil,
        key: String = "privilegedTun.preferences.v1"
    ) {
        self.suiteName = suiteName
        self.key = key
    }

    func load() -> TunPreferences {
        guard let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(TunPreferences.self, from: data),
            let validated = try? decoded.settings.validated()
        else {
            return .defaults
        }
        return TunPreferences(
            settings: validated,
            restoreSystemProxyAfterTun: decoded.restoreSystemProxyAfterTun
        )
    }

    func save(_ preferences: TunPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
