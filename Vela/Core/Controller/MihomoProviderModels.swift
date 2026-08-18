import Foundation

nonisolated struct MihomoSubscriptionInfo: Codable, Equatable, Sendable {
    let upload: UInt64?
    let download: UInt64?
    let total: UInt64?
    let expire: Int64?

    init(
        upload: UInt64?,
        download: UInt64?,
        total: UInt64?,
        expire: Int64?
    ) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        upload = Self.decodeUnsigned(names: ["upload", "Upload"], from: container)
        download = Self.decodeUnsigned(names: ["download", "Download"], from: container)
        total = Self.decodeUnsigned(names: ["total", "Total"], from: container)
        expire = Self.decodeSigned(names: ["expire", "Expire"], from: container)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CanonicalCodingKeys.self)
        try container.encodeIfPresent(upload, forKey: .upload)
        try container.encodeIfPresent(download, forKey: .download)
        try container.encodeIfPresent(total, forKey: .total)
        try container.encodeIfPresent(expire, forKey: .expire)
    }

    private static func decodeUnsigned(
        names: [String],
        from container: KeyedDecodingContainer<FlexibleCodingKey>
    ) -> UInt64? {
        for name in names {
            let key = FlexibleCodingKey(stringValue: name)
            if let value = try? container.decode(UInt64.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(Int64.self, forKey: key), value >= 0 {
                return UInt64(value)
            }
            if let value = try? container.decode(String.self, forKey: key),
                let parsed = UInt64(value)
            {
                return parsed
            }
        }
        return nil
    }

    private static func decodeSigned(
        names: [String],
        from container: KeyedDecodingContainer<FlexibleCodingKey>
    ) -> Int64? {
        for name in names {
            let key = FlexibleCodingKey(stringValue: name)
            if let value = try? container.decode(Int64.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(UInt64.self, forKey: key),
                value <= UInt64(Int64.max)
            {
                return Int64(value)
            }
            if let value = try? container.decode(String.self, forKey: key),
                let parsed = Int64(value)
            {
                return parsed
            }
        }
        return nil
    }

    private enum CanonicalCodingKeys: String, CodingKey {
        case upload
        case download
        case total
        case expire
    }
}

nonisolated struct MihomoRuleProvidersResponse: Codable, Equatable, Sendable {
    static let empty = MihomoRuleProvidersResponse(providers: [:])

    let providers: [String: MihomoRuleProvider]
}

nonisolated struct MihomoRuleProvider: Codable, Equatable, Sendable {
    let behavior: String?
    let format: String?
    let name: String?
    let ruleCount: Int?
    let type: String?
    let vehicleType: String?
    let updatedAt: String?
    let payload: [String]?
}

nonisolated private struct FlexibleCodingKey: CodingKey, Sendable {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
