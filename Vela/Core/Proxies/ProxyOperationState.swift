import Foundation

nonisolated enum ProxyOperationState: Equatable, Sendable {
    case refreshing
    case selecting(groupName: String, proxyID: ProxyCatalogID)
    case testingProxy(groupName: String, proxyID: ProxyCatalogID)
    case testingGroup(groupName: String)
}

nonisolated enum ProxyDelayState: Equatable, Sendable {
    case testing
    case measured(milliseconds: UInt16)
    case unavailable
    case failed(String)

    var milliseconds: UInt16? {
        guard case let .measured(milliseconds) = self else { return nil }
        return milliseconds
    }
}

nonisolated struct ProxyDelayCacheKey: Hashable, Sendable {
    let profileID: UUID
    let groupName: String
    let proxyID: ProxyCatalogID
    let testURL: String
    let expectedStatus: String?
}

nonisolated enum ProxyTestDefaults {
    static let url = "https://www.gstatic.com/generate_204"
    static let timeoutMilliseconds = 5_000
    static let groupConcurrencyLimit = 4
}
