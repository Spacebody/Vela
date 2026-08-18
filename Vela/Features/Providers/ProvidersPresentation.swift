import Foundation

nonisolated enum ProviderFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case proxy
    case rule

    func includes(_ kind: ProviderKind) -> Bool {
        switch self {
        case .all: true
        case .proxy: kind == .proxy
        case .rule: kind == .rule
        }
    }
}

/// A provider only has a stable identity inside one committed runtime catalog.
/// Names remain opaque and the kind is part of the key because Mihomo permits
/// the proxy and rule namespaces to contain the same raw name.
nonisolated struct ProviderIdentity: Hashable, Sendable {
    let activeProfileID: UUID?
    let kind: ProviderKind
    let rawName: String
    let runtimeGeneration: UUID

    func hash(into hasher: inout Hasher) {
        hasher.combine(activeProfileID)
        hasher.combine(kind.rawValue)
        hasher.combine(rawName)
        hasher.combine(runtimeGeneration)
    }
}

nonisolated enum ProviderAvailability: Equatable, Sendable {
    case loaded
    case unavailable
    case error
}

nonisolated enum ProviderFreshness: Equatable, Sendable {
    case current
    case updating
    case failed
    case unknown
}

nonisolated struct ProviderProxyHealthSummary: Equatable, Sendable {
    let healthy: Int
    let failed: Int
    let unknown: Int

    var hasEvidence: Bool { healthy + failed > 0 }
}

nonisolated enum ProviderDetails: Equatable, Sendable {
    case proxy(MihomoProxyProvider)
    case rule(MihomoRuleProvider)
}

nonisolated struct ProviderRowModel: Identifiable, Equatable, Sendable {
    let id: ProviderIdentity
    let rawName: String
    let kind: ProviderKind
    let itemCount: Int
    let vehicle: String?
    let format: String?
    let behavior: String?
    let updatedAt: String?
    let availability: ProviderAvailability
    let freshness: ProviderFreshness
    let proxyHealth: ProviderProxyHealthSummary?
    let operationOutcome: ProviderBatchOutcome?
    let details: ProviderDetails

    var operationKey: ProviderOperationKey {
        ProviderOperationKey(kind: kind, name: rawName)
    }

    var searchableEvidence: [String] {
        [
            rawName,
            kind.rawValue,
            vehicle,
            format,
            behavior,
            updatedAt,
            freshness.searchToken,
            availability.searchToken,
        ].compactMap { $0 }
    }
}

nonisolated enum ProvidersTablePresentation {
    static func rows(
        snapshot: ProviderCatalogSnapshot,
        activeProfileID: UUID?,
        runtimeGeneration: UUID,
        runningOperations: Set<ProviderOperationKey> = [],
        outcomes: [ProviderOperationKey: ProviderBatchOutcome] = [:]
    ) -> [ProviderRowModel] {
        let proxyRows = snapshot.proxyProviders.map { rawName, provider in
            let key = ProviderOperationKey(kind: .proxy, name: rawName)
            return ProviderRowModel(
                id: ProviderIdentity(
                    activeProfileID: activeProfileID,
                    kind: .proxy,
                    rawName: rawName,
                    runtimeGeneration: runtimeGeneration
                ),
                rawName: rawName,
                kind: .proxy,
                itemCount: provider.proxies.count,
                vehicle: provider.vehicleType,
                format: nil,
                behavior: nil,
                updatedAt: provider.updatedAt,
                availability: .loaded,
                freshness: freshness(
                    key: key,
                    updatedAt: provider.updatedAt,
                    runningOperations: runningOperations,
                    outcomes: outcomes
                ),
                proxyHealth: proxyHealth(provider.proxies),
                operationOutcome: outcomes[key],
                details: .proxy(provider)
            )
        }
        let ruleRows = snapshot.ruleProviders.map { rawName, provider in
            let key = ProviderOperationKey(kind: .rule, name: rawName)
            return ProviderRowModel(
                id: ProviderIdentity(
                    activeProfileID: activeProfileID,
                    kind: .rule,
                    rawName: rawName,
                    runtimeGeneration: runtimeGeneration
                ),
                rawName: rawName,
                kind: .rule,
                itemCount: provider.ruleCount ?? provider.payload?.count ?? 0,
                vehicle: provider.vehicleType,
                format: provider.format,
                behavior: provider.behavior,
                updatedAt: provider.updatedAt,
                availability: .loaded,
                freshness: freshness(
                    key: key,
                    updatedAt: provider.updatedAt,
                    runningOperations: runningOperations,
                    outcomes: outcomes
                ),
                proxyHealth: nil,
                operationOutcome: outcomes[key],
                details: .rule(provider)
            )
        }

        // The API exposes keyed dictionaries rather than authoritative source
        // ordering. A deterministic raw-name order is therefore the only
        // honest stable order available to the presentation layer.
        return (proxyRows + ruleRows).sorted {
            let comparison = $0.rawName.localizedStandardCompare($1.rawName)
            if comparison == .orderedSame {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return comparison == .orderedAscending
        }
    }

    static func filter(
        _ rows: [ProviderRowModel],
        kind: ProviderFilter,
        query: String
    ) -> [ProviderRowModel] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            guard kind.includes(row.kind) else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return row.searchableEvidence.contains {
                $0.localizedCaseInsensitiveContains(normalizedQuery)
            }
        }
    }

    static func reconciledSelection(
        _ selection: ProviderIdentity?,
        visibleRows: [ProviderRowModel]
    ) -> ProviderIdentity? {
        guard let selection else { return nil }
        return visibleRows.contains(where: { $0.id == selection }) ? selection : nil
    }

    private static func freshness(
        key: ProviderOperationKey,
        updatedAt: String?,
        runningOperations: Set<ProviderOperationKey>,
        outcomes: [ProviderOperationKey: ProviderBatchOutcome]
    ) -> ProviderFreshness {
        if runningOperations.contains(key) { return .updating }
        if let outcome = outcomes[key] {
            if case .failure = outcome.result { return .failed }
            return .current
        }
        return updatedAt == nil ? .unknown : .current
    }

    private static func proxyHealth(
        _ proxies: [MihomoProxy]
    ) -> ProviderProxyHealthSummary {
        ProviderProxyHealthSummary(
            healthy: proxies.count { $0.alive == true },
            failed: proxies.count { $0.alive == false },
            unknown: proxies.count { $0.alive == nil }
        )
    }
}

nonisolated private extension ProviderFreshness {
    var searchToken: String {
        switch self {
        case .current: "current"
        case .updating: "updating"
        case .failed: "failed"
        case .unknown: "unknown"
        }
    }
}

nonisolated private extension ProviderAvailability {
    var searchToken: String {
        switch self {
        case .loaded: "loaded"
        case .unavailable: "unavailable"
        case .error: "error"
        }
    }
}
