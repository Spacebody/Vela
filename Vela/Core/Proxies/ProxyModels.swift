import Foundation

nonisolated enum ProxyOrigin: Hashable, Sendable {
    case runtime
    case provider(name: String)
}

nonisolated struct ProxyCatalogID: Hashable, Sendable {
    let origin: ProxyOrigin
    let name: String
}

nonisolated enum ProxyCatalogFetchSource: String, Hashable, Sendable {
    case proxyProviders
}

nonisolated struct ProxyCatalogFetchError: Error, Equatable, Sendable {
    let source: ProxyCatalogFetchSource
    let endpoint: String
    let message: String
}

extension ProxyCatalogFetchError: LocalizedError {
    var errorDescription: String? {
        switch source {
        case .proxyProviders:
            "Provider proxy catalog unavailable at \(endpoint): \(message)"
        }
    }
}

nonisolated struct ProxyCatalog: Equatable, Sendable {
    static let empty = ProxyCatalog(groups: [])

    let groups: [ProxyGroup]
    let nodes: [ProxyCatalogID: ProxyNode]
    let providers: [ProxyProviderCatalog]
    let fetchErrors: [ProxyCatalogFetchError]
    let updatedAt: Date?

    init(
        groups: [ProxyGroup],
        nodes: [ProxyCatalogID: ProxyNode] = [:],
        providers: [ProxyProviderCatalog] = [],
        fetchErrors: [ProxyCatalogFetchError] = [],
        updatedAt: Date? = nil
    ) {
        self.groups = groups
        self.nodes = nodes
        self.providers = providers
        self.fetchErrors = fetchErrors
        self.updatedAt = updatedAt
    }

    init(response: MihomoProxiesResponse) {
        self.init(
            runtimeResponse: response,
            providerResponse: .empty
        )
    }

    init(
        runtimeResponse: MihomoProxiesResponse,
        providerResponse: MihomoProxyProvidersResponse,
        fetchErrors: [ProxyCatalogFetchError] = [],
        updatedAt: Date? = nil
    ) {
        let providerEntries = providerResponse.providers.filter { _, provider in
            provider.vehicleType?.lowercased() != "compatible"
        }
        let providerCatalogs: [ProxyProviderCatalog] = providerEntries.keys.sorted().compactMap {
            providerName -> ProxyProviderCatalog? in
            guard let provider = providerEntries[providerName] else { return nil }
            let effectiveTestURL = provider.testURL?.nilIfEmpty ?? ProxyTestDefaults.url
            let nodes = provider.proxies
                .filter { $0.hidden != true }
                .map { proxy in
                    ProxyNode(
                        proxy: proxy,
                        origin: .provider(name: providerName),
                        effectiveTestURL: effectiveTestURL,
                        isCurrent: false,
                        isFixed: false
                    )
                }

            return ProxyProviderCatalog(
                name: providerName,
                reportedName: provider.name,
                type: provider.type,
                vehicleType: provider.vehicleType,
                testURL: provider.testURL,
                expectedStatus: provider.expectedStatus,
                updatedAt: provider.updatedAt,
                nodes: nodes
            )
        }

        var catalogNodes: [ProxyCatalogID: ProxyNode] = [:]
        for proxy in runtimeResponse.proxies.values where proxy.all == nil && proxy.hidden != true {
            let node = ProxyNode(
                proxy: proxy,
                origin: .runtime,
                effectiveTestURL: ProxyTestDefaults.url,
                isCurrent: false,
                isFixed: false
            )
            catalogNodes[node.id] = node
        }
        for provider in providerCatalogs {
            for node in provider.nodes {
                catalogNodes[node.id] = node
            }
        }

        let sortedProviderNames = providerEntries.keys.sorted()
        let groups = runtimeResponse.proxies.values
            .filter { proxy in
                proxy.all != nil && proxy.hidden != true
            }
            .map { proxy in
                let effectiveTestURL = proxy.testURL?.nilIfEmpty ?? ProxyTestDefaults.url
                var memberNodes: [ProxyNode] = []

                for memberName in proxy.all ?? [] {
                    if let runtimeProxy = runtimeResponse.proxies[memberName],
                        runtimeProxy.hidden != true
                    {
                        memberNodes.append(
                            ProxyNode(
                                proxy: runtimeProxy,
                                origin: .runtime,
                                effectiveTestURL: effectiveTestURL,
                                isCurrent: memberName == proxy.now,
                                isFixed: memberName == proxy.fixed
                            )
                        )
                        continue
                    }

                    var providerMatches: [ProxyNode] = []
                    for providerName in sortedProviderNames {
                        guard let provider = providerEntries[providerName] else { continue }
                        providerMatches.append(
                            contentsOf: provider.proxies
                                .filter { $0.name == memberName && $0.hidden != true }
                                .map { providerProxy in
                                    ProxyNode(
                                        proxy: providerProxy,
                                        origin: .provider(name: providerName),
                                        effectiveTestURL: effectiveTestURL,
                                        isCurrent: memberName == proxy.now,
                                        isFixed: memberName == proxy.fixed
                                    )
                                }
                        )
                    }

                    if providerMatches.count != 1 {
                        memberNodes.append(
                            ProxyNode.placeholder(
                                name: memberName,
                                isCurrent: memberName == proxy.now,
                                isFixed: memberName == proxy.fixed
                            )
                        )
                    } else if let providerMatch = providerMatches.first {
                        memberNodes.append(providerMatch)
                    }
                }

                return ProxyGroup(proxy: proxy, nodes: memberNodes)
            }
            .sorted { lhs, rhs in
                lhs.name < rhs.name
            }

        self.init(
            groups: groups,
            nodes: catalogNodes,
            providers: providerCatalogs,
            fetchErrors: fetchErrors,
            updatedAt: updatedAt
        )
    }

    func group(named name: String) -> ProxyGroup? {
        groups.first { $0.name == name }
    }

    func node(id: ProxyCatalogID) -> ProxyNode? {
        nodes[id]
    }

    func nodes(named name: String) -> [ProxyNode] {
        nodes.values
            .filter { $0.name == name }
            .sorted { lhs, rhs in
                lhs.id.sortKey < rhs.id.sortKey
            }
    }

    func provider(named name: String) -> ProxyProviderCatalog? {
        providers.first { $0.name == name }
    }
}

nonisolated struct ProxyProviderCatalog: Identifiable, Equatable, Sendable {
    var id: String { name }

    let name: String
    let reportedName: String?
    let type: String?
    let vehicleType: String?
    let testURL: String?
    let expectedStatus: String?
    let updatedAt: String?
    let nodes: [ProxyNode]
}

nonisolated struct ProxyGroup: Identifiable, Equatable, Sendable {
    var id: String { name }

    let name: String
    let type: String
    let now: String?
    let fixed: String?
    let testURL: String?
    let expectedStatus: String?
    let nodes: [ProxyNode]

    var isSelectable: Bool {
        switch type {
        case "Selector", "URLTest", "Fallback":
            true
        default:
            false
        }
    }

    fileprivate init(proxy: MihomoProxy, nodes: [ProxyNode]) {
        name = proxy.name
        type = proxy.type
        now = proxy.now
        fixed = proxy.fixed
        testURL = proxy.testURL
        expectedStatus = proxy.expectedStatus
        self.nodes = nodes
    }

    static func configured(
        name: String,
        type: String,
        testURL: String?,
        expectedStatus: String?,
        nodes: [ProxyNode]
    ) -> ProxyGroup {
        ProxyGroup(
            name: name,
            type: type,
            now: nil,
            fixed: nil,
            testURL: testURL,
            expectedStatus: expectedStatus,
            nodes: nodes
        )
    }

    private init(
        name: String,
        type: String,
        now: String?,
        fixed: String?,
        testURL: String?,
        expectedStatus: String?,
        nodes: [ProxyNode]
    ) {
        self.name = name
        self.type = type
        self.now = now
        self.fixed = fixed
        self.testURL = testURL
        self.expectedStatus = expectedStatus
        self.nodes = nodes
    }
}

nonisolated struct ProxyNode: Identifiable, Equatable, Sendable {
    let id: ProxyCatalogID
    let origin: ProxyOrigin
    let name: String
    let type: String?
    let alive: Bool?
    let delay: ProxyDelay
    let isCurrent: Bool
    let isFixed: Bool
    let isPlaceholder: Bool

    fileprivate init(
        proxy: MihomoProxy,
        origin: ProxyOrigin,
        effectiveTestURL: String,
        isCurrent: Bool,
        isFixed: Bool
    ) {
        id = ProxyCatalogID(origin: origin, name: proxy.name)
        self.origin = origin
        name = proxy.name
        type = proxy.type
        let testState = proxy.extra?[effectiveTestURL]
        alive = testState?.alive ?? proxy.alive
        delay = ProxyDelay(history: testState?.history ?? proxy.history)
        self.isCurrent = isCurrent
        self.isFixed = isFixed
        isPlaceholder = false
    }

    fileprivate static func placeholder(
        name: String,
        isCurrent: Bool,
        isFixed: Bool
    ) -> ProxyNode {
        ProxyNode(
            id: ProxyCatalogID(origin: .runtime, name: name),
            origin: .runtime,
            name: name,
            type: nil,
            alive: nil,
            delay: .untested,
            isCurrent: isCurrent,
            isFixed: isFixed,
            isPlaceholder: true
        )
    }

    static func configured(name: String, type: String?) -> ProxyNode {
        ProxyNode(
            id: ProxyCatalogID(origin: .runtime, name: name),
            origin: .runtime,
            name: name,
            type: type,
            alive: nil,
            delay: .untested,
            isCurrent: false,
            isFixed: false,
            isPlaceholder: type == nil
        )
    }

    private init(
        id: ProxyCatalogID,
        origin: ProxyOrigin,
        name: String,
        type: String?,
        alive: Bool?,
        delay: ProxyDelay,
        isCurrent: Bool,
        isFixed: Bool,
        isPlaceholder: Bool
    ) {
        self.id = id
        self.origin = origin
        self.name = name
        self.type = type
        self.alive = alive
        self.delay = delay
        self.isCurrent = isCurrent
        self.isFixed = isFixed
        self.isPlaceholder = isPlaceholder
    }
}

nonisolated enum ProxyDelay: Equatable, Sendable {
    case untested
    case unavailable
    case measured(milliseconds: UInt16)

    var milliseconds: UInt16? {
        guard case let .measured(milliseconds) = self else { return nil }
        return milliseconds
    }

    fileprivate init(history: [MihomoDelayHistory]?) {
        guard let latest = history?.last else {
            self = .untested
            return
        }

        if latest.delay == 0 {
            self = .unavailable
        } else {
            self = .measured(milliseconds: latest.delay)
        }
    }
}

nonisolated private extension ProxyCatalogID {
    var sortKey: String {
        switch origin {
        case .runtime:
            "0-runtime-\(name)"
        case let .provider(providerName):
            "1-provider-\(providerName)-\(name)"
        }
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
