import Foundation

nonisolated struct ConnectionsSnapshot: Decodable, Equatable, Sendable {
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connections: [MihomoConnection]
    let memory: UInt64?

    init(
        downloadTotal: Int64,
        uploadTotal: Int64,
        connections: [MihomoConnection],
        memory: UInt64?
    ) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
        self.memory = memory
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadTotal = try container.decodeIfPresent(Int64.self, forKey: .downloadTotal) ?? 0
        uploadTotal = try container.decodeIfPresent(Int64.self, forKey: .uploadTotal) ?? 0
        connections = try container.decodeIfPresent([MihomoConnection].self, forKey: .connections) ?? []
        memory = try container.decodeIfPresent(UInt64.self, forKey: .memory)
    }

    private enum CodingKeys: String, CodingKey {
        case downloadTotal
        case uploadTotal
        case connections
        case memory
    }
}

nonisolated struct MihomoConnection: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let metadata: ConnectionMetadata
    let upload: Int64
    let download: Int64
    let start: Date?
    let chains: [String]
    let providerChains: [String]
    let rule: String
    let rulePayload: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        metadata = try container.decodeIfPresent(ConnectionMetadata.self, forKey: .metadata) ?? .empty
        upload = try container.decodeIfPresent(Int64.self, forKey: .upload) ?? 0
        download = try container.decodeIfPresent(Int64.self, forKey: .download) ?? 0
        start = Self.parseDate(try container.decodeIfPresent(String.self, forKey: .start))
        chains = try container.decodeIfPresent([String].self, forKey: .chains) ?? []
        providerChains = try container.decodeIfPresent([String].self, forKey: .providerChains) ?? []
        rule = try container.decodeIfPresent(String.self, forKey: .rule) ?? ""
        rulePayload = try container.decodeIfPresent(String.self, forKey: .rulePayload) ?? ""
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.hasPrefix("0001-01-01") else { return nil }
        return try? Date(value, strategy: .iso8601)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case metadata
        case upload
        case download
        case start
        case chains
        case providerChains
        case rule
        case rulePayload
    }
}

nonisolated struct ConnectionMetadata: Decodable, Equatable, Sendable {
    static let empty = ConnectionMetadata()

    let network: String?
    let type: String?
    let sourceIP: String?
    let destinationIP: String?
    let sourceGeoIP: [String]
    let destinationGeoIP: [String]
    let sourceIPASN: String?
    let destinationIPASN: String?
    let sourcePort: Int?
    let destinationPort: Int?
    let inboundIP: String?
    let inboundPort: Int?
    let inboundName: String?
    let inboundUser: String?
    let rematchName: String?
    let host: String?
    let dnsMode: String?
    let uid: Int?
    let process: String?
    let processPath: String?
    let specialProxy: String?
    let specialRules: String?
    let remoteDestination: String?
    let dscp: Int?
    let sniffHost: String?

    private init() {
        network = nil
        type = nil
        sourceIP = nil
        destinationIP = nil
        sourceGeoIP = []
        destinationGeoIP = []
        sourceIPASN = nil
        destinationIPASN = nil
        sourcePort = nil
        destinationPort = nil
        inboundIP = nil
        inboundPort = nil
        inboundName = nil
        inboundUser = nil
        rematchName = nil
        host = nil
        dnsMode = nil
        uid = nil
        process = nil
        processPath = nil
        specialProxy = nil
        specialRules = nil
        remoteDestination = nil
        dscp = nil
        sniffHost = nil
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        network = try container.decodeIfPresent(String.self, forKey: .network)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        sourceIP = try container.decodeIfPresent(String.self, forKey: .sourceIP)
        destinationIP = try container.decodeIfPresent(String.self, forKey: .destinationIP)
        sourceGeoIP = try container.decodeIfPresent([String].self, forKey: .sourceGeoIP) ?? []
        destinationGeoIP = try container.decodeIfPresent([String].self, forKey: .destinationGeoIP) ?? []
        sourceIPASN = try container.decodeIfPresent(String.self, forKey: .sourceIPASN)
        destinationIPASN = try container.decodeIfPresent(String.self, forKey: .destinationIPASN)
        sourcePort = Self.decodeFlexibleIntIfPresent(from: container, forKey: .sourcePort)
        destinationPort = Self.decodeFlexibleIntIfPresent(
            from: container,
            forKey: .destinationPort
        )
        inboundIP = try container.decodeIfPresent(String.self, forKey: .inboundIP)
        inboundPort = Self.decodeFlexibleIntIfPresent(from: container, forKey: .inboundPort)
        inboundName = try container.decodeIfPresent(String.self, forKey: .inboundName)
        inboundUser = try container.decodeIfPresent(String.self, forKey: .inboundUser)
        rematchName = try container.decodeIfPresent(String.self, forKey: .rematchName)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        dnsMode = try container.decodeIfPresent(String.self, forKey: .dnsMode)
        uid = Self.decodeFlexibleIntIfPresent(from: container, forKey: .uid)
        process = try container.decodeIfPresent(String.self, forKey: .process)
        processPath = try container.decodeIfPresent(String.self, forKey: .processPath)
        specialProxy = try container.decodeIfPresent(String.self, forKey: .specialProxy)
        specialRules = try container.decodeIfPresent(String.self, forKey: .specialRules)
        remoteDestination = try container.decodeIfPresent(String.self, forKey: .remoteDestination)
        dscp = Self.decodeFlexibleIntIfPresent(from: container, forKey: .dscp)
        sniffHost = try container.decodeIfPresent(String.self, forKey: .sniffHost)
    }

    private static func decodeFlexibleIntIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case network
        case type
        case sourceIP
        case destinationIP
        case sourceGeoIP
        case destinationGeoIP
        case sourceIPASN
        case destinationIPASN
        case sourcePort
        case destinationPort
        case inboundIP
        case inboundPort
        case inboundName
        case inboundUser
        case rematchName
        case host
        case dnsMode
        case uid
        case process
        case processPath
        case specialProxy
        case specialRules
        case remoteDestination
        case dscp
        case sniffHost
    }
}
