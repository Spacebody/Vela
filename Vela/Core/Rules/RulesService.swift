import Foundation

nonisolated struct ConfigurationGeneration: Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

nonisolated struct RuleID: Hashable, Sendable {
    let configurationGeneration: ConfigurationGeneration
    let originalIndex: Int
}

nonisolated struct ManagedRule: Identifiable, Equatable, Sendable {
    let id: RuleID
    let value: MihomoRule

    var originalIndex: Int { id.originalIndex }
}

nonisolated enum RulesFailure: Error, Equatable, Sendable {
    case fetchFailed
    case toggleUnsupported
    case toggleFailed
    case configurationGenerationChanged
    case ruleNotFound
    case operationAlreadyRunning
}

actor RulesService {
    private let apiClient: any MihomoAPIProviding
    private let staticConfigurationCatalog: (any StaticConfigurationCatalogProviding)?
    private(set) var generation: ConfigurationGeneration
    private var cachedRules: [ManagedRule] = []
    private var pendingRuleIDs: Set<RuleID> = []

    init(
        apiClient: any MihomoAPIProviding,
        staticConfigurationCatalog: (any StaticConfigurationCatalogProviding)? = nil,
        generation: ConfigurationGeneration = ConfigurationGeneration()
    ) {
        self.apiClient = apiClient
        self.staticConfigurationCatalog = staticConfigurationCatalog
        self.generation = generation
    }

    func refresh() async throws -> [ManagedRule] {
        let capturedGeneration = generation
        do {
            let response = try await apiClient.rules()
            guard generation == capturedGeneration else {
                throw RulesFailure.configurationGenerationChanged
            }
            cachedRules = try makeManagedRules(
                response.rules,
                generation: capturedGeneration
            )
            return cachedRules
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as RulesFailure {
            throw failure
        } catch {
            return try await loadConfiguredRules(generation: capturedGeneration)
        }
    }

    func rules() -> [ManagedRule] {
        cachedRules
    }

    func isPending(originalIndex: Int) -> Bool {
        pendingRuleIDs.contains(
            RuleID(
                configurationGeneration: generation,
                originalIndex: originalIndex
            )
        )
    }

    @discardableResult
    func setDisabled(
        _ disabled: Bool,
        for ruleID: RuleID
    ) async throws -> [ManagedRule] {
        guard ruleID.configurationGeneration == generation else {
            throw RulesFailure.configurationGenerationChanged
        }
        guard let originalRule = cachedRules.first(where: { $0.id == ruleID }) else {
            throw RulesFailure.ruleNotFound
        }
        guard originalRule.value.extra != nil else {
            throw RulesFailure.toggleUnsupported
        }
        guard !pendingRuleIDs.contains(ruleID) else {
            throw RulesFailure.operationAlreadyRunning
        }
        pendingRuleIDs.insert(ruleID)
        defer { pendingRuleIDs.remove(ruleID) }

        do {
            try await apiClient.setRulesDisabled([ruleID.originalIndex: disabled])
        } catch is CancellationError {
            throw RulesFailure.toggleFailed
        } catch {
            throw RulesFailure.toggleFailed
        }
        guard ruleID.configurationGeneration == generation else {
            throw RulesFailure.configurationGenerationChanged
        }

        let response: MihomoRulesResponse
        do {
            response = try await apiClient.rules()
        } catch {
            throw RulesFailure.toggleFailed
        }
        guard ruleID.configurationGeneration == generation else {
            throw RulesFailure.configurationGenerationChanged
        }
        let confirmed: [ManagedRule]
        do {
            confirmed = try makeManagedRules(
                response.rules,
                generation: ruleID.configurationGeneration
            )
        } catch {
            throw RulesFailure.toggleFailed
        }
        guard let value = confirmed.first(where: { $0.originalIndex == ruleID.originalIndex }) else {
            throw RulesFailure.ruleNotFound
        }
        if value.value.extra?.disabled != disabled {
            throw RulesFailure.toggleFailed
        }
        cachedRules = confirmed
        return confirmed
    }

    @discardableResult
    func configurationDidChange(
        to newGeneration: ConfigurationGeneration = ConfigurationGeneration()
    ) -> ConfigurationGeneration {
        generation = newGeneration
        cachedRules = []
        pendingRuleIDs = []
        return newGeneration
    }

    private func makeManagedRules(
        _ rules: [MihomoRule],
        generation: ConfigurationGeneration
    ) throws -> [ManagedRule] {
        let seenIndices = Set(rules.map(\.index))
        guard seenIndices.count == rules.count else {
            throw RulesFailure.fetchFailed
        }
        return rules.map {
            ManagedRule(
                id: RuleID(
                    configurationGeneration: generation,
                    originalIndex: $0.index
                ),
                value: $0
            )
        }
    }

    private func loadConfiguredRules(
        generation capturedGeneration: ConfigurationGeneration
    ) async throws -> [ManagedRule] {
        guard let staticConfigurationCatalog else {
            throw RulesFailure.fetchFailed
        }
        let snapshot: StaticConfigurationCatalogSnapshot?
        do {
            snapshot = try await staticConfigurationCatalog.selectedSnapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RulesFailure.fetchFailed
        }
        guard generation == capturedGeneration else {
            throw RulesFailure.configurationGenerationChanged
        }
        guard let snapshot else {
            throw RulesFailure.fetchFailed
        }
        cachedRules = try makeManagedRules(
            snapshot.rules,
            generation: capturedGeneration
        )
        return cachedRules
    }
}
