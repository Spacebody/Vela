import Foundation

nonisolated struct MihomoRulesResponse: Decodable, Equatable, Sendable {
    let rules: [MihomoRule]

    init(rules: [MihomoRule]) {
        self.rules = rules
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decodeIfPresent([MihomoRule].self, forKey: .rules) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case rules
    }
}

nonisolated struct MihomoRule: Decodable, Equatable, Sendable {
    let index: Int
    let type: String
    let payload: String
    let proxy: String
    let size: Int
    let extra: RuleRuntimeStats?

    init(
        index: Int,
        type: String,
        payload: String,
        proxy: String,
        size: Int,
        extra: RuleRuntimeStats?
    ) {
        self.index = index
        self.type = type
        self.payload = payload
        self.proxy = proxy
        self.size = size
        self.extra = extra
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        payload = try container.decodeIfPresent(String.self, forKey: .payload) ?? ""
        proxy = try container.decodeIfPresent(String.self, forKey: .proxy) ?? ""
        size = try container.decodeIfPresent(Int.self, forKey: .size) ?? -1
        extra = try container.decodeIfPresent(RuleRuntimeStats.self, forKey: .extra)
    }

    private enum CodingKeys: String, CodingKey {
        case index
        case type
        case payload
        case proxy
        case size
        case extra
    }
}

nonisolated struct RuleRuntimeStats: Decodable, Equatable, Sendable {
    let disabled: Bool
    let hitCount: UInt64
    let hitAt: Date?
    let missCount: UInt64
    let missAt: Date?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        hitCount = try container.decodeIfPresent(UInt64.self, forKey: .hitCount) ?? 0
        hitAt = Self.parseDate(try container.decodeIfPresent(String.self, forKey: .hitAt))
        missCount = try container.decodeIfPresent(UInt64.self, forKey: .missCount) ?? 0
        missAt = Self.parseDate(try container.decodeIfPresent(String.self, forKey: .missAt))
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.hasPrefix("0001-01-01") else { return nil }
        return try? Date(value, strategy: .iso8601)
    }

    private enum CodingKeys: String, CodingKey {
        case disabled
        case hitCount
        case hitAt
        case missCount
        case missAt
    }
}
