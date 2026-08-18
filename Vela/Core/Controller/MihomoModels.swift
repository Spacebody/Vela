import Foundation

nonisolated struct MihomoVersion: Codable, Equatable, Sendable {
    let meta: Bool
    let version: String
}

nonisolated struct MihomoConfigs: Codable, Equatable, Sendable {
    let port: Int
    let socksPort: Int
    let redirPort: Int
    let tproxyPort: Int
    let mixedPort: Int
    let allowLan: Bool
    let bindAddress: String
    let mode: MihomoMode
    let logLevel: String
    let ipv6: Bool
    let unifiedDelay: Bool
    let tcpConcurrent: Bool
    let findProcessMode: String
    let interfaceName: String
    let sniffing: Bool

    enum CodingKeys: String, CodingKey {
        case port
        case socksPort = "socks-port"
        case redirPort = "redir-port"
        case tproxyPort = "tproxy-port"
        case mixedPort = "mixed-port"
        case allowLan = "allow-lan"
        case bindAddress = "bind-address"
        case mode
        case logLevel = "log-level"
        case ipv6
        case unifiedDelay = "unified-delay"
        case tcpConcurrent = "tcp-concurrent"
        case findProcessMode = "find-process-mode"
        case interfaceName = "interface-name"
        case sniffing
    }
}

nonisolated struct MihomoConfigPatch: Codable, Equatable, Sendable {
    var port: Int?
    var socksPort: Int?
    var redirPort: Int?
    var tproxyPort: Int?
    var mixedPort: Int?
    var allowLan: Bool?
    var bindAddress: String?
    var mode: MihomoMode?
    var logLevel: String?
    var ipv6: Bool?
    var sniffing: Bool?
    var tcpConcurrent: Bool?
    var findProcessMode: String?
    var interfaceName: String?

    init(
        port: Int? = nil,
        socksPort: Int? = nil,
        redirPort: Int? = nil,
        tproxyPort: Int? = nil,
        mixedPort: Int? = nil,
        allowLan: Bool? = nil,
        bindAddress: String? = nil,
        mode: MihomoMode? = nil,
        logLevel: String? = nil,
        ipv6: Bool? = nil,
        sniffing: Bool? = nil,
        tcpConcurrent: Bool? = nil,
        findProcessMode: String? = nil,
        interfaceName: String? = nil
    ) {
        self.port = port
        self.socksPort = socksPort
        self.redirPort = redirPort
        self.tproxyPort = tproxyPort
        self.mixedPort = mixedPort
        self.allowLan = allowLan
        self.bindAddress = bindAddress
        self.mode = mode
        self.logLevel = logLevel
        self.ipv6 = ipv6
        self.sniffing = sniffing
        self.tcpConcurrent = tcpConcurrent
        self.findProcessMode = findProcessMode
        self.interfaceName = interfaceName
    }

    enum CodingKeys: String, CodingKey {
        case port
        case socksPort = "socks-port"
        case redirPort = "redir-port"
        case tproxyPort = "tproxy-port"
        case mixedPort = "mixed-port"
        case allowLan = "allow-lan"
        case bindAddress = "bind-address"
        case mode
        case logLevel = "log-level"
        case ipv6
        case sniffing
        case tcpConcurrent = "tcp-concurrent"
        case findProcessMode = "find-process-mode"
        case interfaceName = "interface-name"
    }
}

nonisolated struct MihomoProxiesResponse: Codable, Equatable, Sendable {
    let proxies: [String: MihomoProxy]
}

nonisolated struct MihomoProxyProvidersResponse: Codable, Equatable, Sendable {
    static let empty = MihomoProxyProvidersResponse(providers: [:])

    let providers: [String: MihomoProxyProvider]
}

nonisolated struct MihomoProxyProvider: Codable, Equatable, Sendable {
    let name: String?
    let type: String?
    let vehicleType: String?
    let proxies: [MihomoProxy]
    let testURL: String?
    let expectedStatus: String?
    let updatedAt: String?
    let subscriptionInfo: MihomoSubscriptionInfo?

    init(
        name: String?,
        type: String?,
        vehicleType: String?,
        proxies: [MihomoProxy],
        testURL: String?,
        expectedStatus: String?,
        updatedAt: String?,
        subscriptionInfo: MihomoSubscriptionInfo? = nil
    ) {
        self.name = name
        self.type = type
        self.vehicleType = vehicleType
        self.proxies = proxies
        self.testURL = testURL
        self.expectedStatus = expectedStatus
        self.updatedAt = updatedAt
        self.subscriptionInfo = subscriptionInfo
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        vehicleType = try container.decodeIfPresent(String.self, forKey: .vehicleType)
        proxies = try container.decodeIfPresent([MihomoProxy].self, forKey: .proxies) ?? []
        testURL = try container.decodeIfPresent(String.self, forKey: .testURL)
        expectedStatus = try container.decodeIfPresent(String.self, forKey: .expectedStatus)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        subscriptionInfo = try container.decodeIfPresent(
            MihomoSubscriptionInfo.self,
            forKey: .subscriptionInfo
        )
    }

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case vehicleType
        case proxies
        case testURL = "testUrl"
        case expectedStatus
        case updatedAt
        case subscriptionInfo
    }
}

nonisolated struct MihomoProxy: Codable, Equatable, Sendable {
    let id: String?
    let name: String
    let type: String
    let alive: Bool?
    let udp: Bool?
    let uot: Bool?
    let xudp: Bool?
    let tfo: Bool?
    let mptcp: Bool?
    let smux: Bool?
    let interfaceName: String?
    let routingMark: Int?
    let providerName: String?
    let dialerProxy: String?
    let now: String?
    let all: [String]?
    let testURL: String?
    let expectedStatus: String?
    let fixed: String?
    let hidden: Bool?
    let icon: String?
    let emptyFallback: String?
    let history: [MihomoDelayHistory]?
    let extra: [String: MihomoProxyState]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case alive
        case udp
        case uot
        case xudp
        case tfo
        case mptcp
        case smux
        case interfaceName = "interface"
        case routingMark = "routing-mark"
        case providerName = "provider-name"
        case dialerProxy = "dialer-proxy"
        case now
        case all
        case testURL = "testUrl"
        case expectedStatus
        case fixed
        case hidden
        case icon
        case emptyFallback
        case history
        case extra
    }
}

nonisolated struct MihomoProxyDelayResponse: Codable, Equatable, Sendable {
    let delay: UInt16
}

nonisolated struct MihomoDelayHistory: Codable, Equatable, Sendable {
    let time: String
    let delay: UInt16
}

nonisolated struct MihomoProxyState: Codable, Equatable, Sendable {
    let alive: Bool
    let history: [MihomoDelayHistory]?
}
