import Foundation

nonisolated enum ProviderKind: String, Codable, CaseIterable, Equatable, Sendable {
    case proxy
    case rule
}

nonisolated struct ProviderOperationKey: Hashable, Sendable {
    let kind: ProviderKind
    let name: String
}

nonisolated enum ProviderOperation: String, Equatable, Sendable {
    case update
    case healthCheck
}

nonisolated enum ProviderOperationState: Equatable, Sendable {
    case idle
    case running(ProviderOperation)
    case succeeded(ProviderOperation, Date)
    case failed(ProviderOperation, ProviderFailure)
}

nonisolated enum ProviderFailure: Error, Equatable, Sendable {
    case fetchFailed
    case updateFailed
    case healthCheckFailed
    case decodeFailed
    case providerNotFound
    case operationAlreadyRunning
    case unsupportedOperation
    case cancelledBeforeStart
    case cancelledResultUnknown
    case updateInProgress
}

nonisolated struct ProviderCatalogSnapshot: Equatable, Sendable {
    let proxyProviders: [String: MihomoProxyProvider]
    let ruleProviders: [String: MihomoRuleProvider]

    static let empty = ProviderCatalogSnapshot(proxyProviders: [:], ruleProviders: [:])
}

nonisolated struct ProviderBatchResult: Equatable, Sendable {
    let key: ProviderOperationKey
    let result: Result<Void, ProviderFailure>

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.key == rhs.key else { return false }
        return switch (lhs.result, rhs.result) {
        case (.success, .success): true
        case let (.failure(lhsError), .failure(rhsError)): lhsError == rhsError
        default: false
        }
    }
}

actor ProviderManagementService {
    private let apiClient: any MihomoAPIProviding
    private let staticConfigurationCatalog: (any StaticConfigurationCatalogProviding)?
    private let runtimeMutationGate: RuntimeMutationGate?
    private let now: @Sendable () -> Date
    private var operationStates: [ProviderOperationKey: ProviderOperationState] = [:]

    init(
        apiClient: any MihomoAPIProviding,
        staticConfigurationCatalog: (any StaticConfigurationCatalogProviding)? = nil,
        runtimeMutationGate: RuntimeMutationGate? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.apiClient = apiClient
        self.staticConfigurationCatalog = staticConfigurationCatalog
        self.runtimeMutationGate = runtimeMutationGate
        self.now = now
    }

    func refresh() async throws -> ProviderCatalogSnapshot {
        do {
            async let proxy = apiClient.proxyProviders()
            async let rule = apiClient.ruleProviders()
            return try await ProviderCatalogSnapshot(
                proxyProviders: proxy.providers,
                ruleProviders: rule.providers
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch is DecodingError {
            return try await configuredSnapshot(or: .decodeFailed)
        } catch let error as MihomoAPIError {
            if case .decodingFailed = error {
                return try await configuredSnapshot(or: .decodeFailed)
            }
            return try await configuredSnapshot(or: .fetchFailed)
        } catch {
            return try await configuredSnapshot(or: .fetchFailed)
        }
    }

    private func configuredSnapshot(
        or failure: ProviderFailure
    ) async throws -> ProviderCatalogSnapshot {
        guard let staticConfigurationCatalog else { throw failure }
        do {
            guard let snapshot = try await staticConfigurationCatalog.selectedSnapshot() else {
                throw failure
            }
            return snapshot.providers
        } catch is CancellationError {
            throw CancellationError()
        } catch let providerFailure as ProviderFailure {
            throw providerFailure
        } catch {
            throw failure
        }
    }

    func operationState(for key: ProviderOperationKey) -> ProviderOperationState {
        operationStates[key] ?? .idle
    }

    func update(_ key: ProviderOperationKey) async throws {
        try await withRuntimeMutationLease {
            try await performUpdate(key)
        }
    }

    private func performUpdate(_ key: ProviderOperationKey) async throws {
        guard !Task.isCancelled else {
            throw ProviderFailure.cancelledBeforeStart
        }
        try begin(.update, key: key)
        do {
            switch key.kind {
            case .proxy:
                try await apiClient.updateProxyProvider(named: key.name)
            case .rule:
                try await apiClient.updateRuleProvider(named: key.name)
            }
            guard !Task.isCancelled else {
                operationStates[key] = .failed(.update, .cancelledResultUnknown)
                throw ProviderFailure.cancelledResultUnknown
            }
            operationStates[key] = .succeeded(.update, now())
        } catch let failure as ProviderFailure {
            if failure == .cancelledResultUnknown
                || failure == .operationAlreadyRunning
                || failure == .updateInProgress
            {
                throw failure
            }
            operationStates[key] = .failed(.update, .updateFailed)
            throw ProviderFailure.updateFailed
        } catch is CancellationError {
            operationStates[key] = .failed(.update, .cancelledResultUnknown)
            throw ProviderFailure.cancelledResultUnknown
        } catch {
            operationStates[key] = .failed(.update, .updateFailed)
            throw ProviderFailure.updateFailed
        }
    }

    func healthCheckProxyProvider(named name: String) async throws {
        try await withRuntimeMutationLease {
            try await performHealthCheckProxyProvider(named: name)
        }
    }

    private func performHealthCheckProxyProvider(named name: String) async throws {
        let key = ProviderOperationKey(kind: .proxy, name: name)
        guard !Task.isCancelled else {
            throw ProviderFailure.cancelledBeforeStart
        }
        try begin(.healthCheck, key: key)
        do {
            try await apiClient.healthCheckProxyProvider(named: name)
            guard !Task.isCancelled else {
                operationStates[key] = .failed(.healthCheck, .cancelledResultUnknown)
                throw ProviderFailure.cancelledResultUnknown
            }
            operationStates[key] = .succeeded(.healthCheck, now())
        } catch let failure as ProviderFailure {
            if failure == .cancelledResultUnknown
                || failure == .operationAlreadyRunning
                || failure == .updateInProgress
            {
                throw failure
            }
            operationStates[key] = .failed(.healthCheck, .healthCheckFailed)
            throw ProviderFailure.healthCheckFailed
        } catch is CancellationError {
            operationStates[key] = .failed(.healthCheck, .cancelledResultUnknown)
            throw ProviderFailure.cancelledResultUnknown
        } catch {
            operationStates[key] = .failed(.healthCheck, .healthCheckFailed)
            throw ProviderFailure.healthCheckFailed
        }
    }

    func updateAll(
        _ keys: [ProviderOperationKey],
        maximumConcurrent: Int = 2
    ) async -> [ProviderBatchResult] {
        do {
            return try await withRuntimeMutationLease {
                await performUpdateAll(keys, maximumConcurrent: maximumConcurrent)
            }
        } catch {
            return Array(Set(keys)).map {
                ProviderBatchResult(key: $0, result: .failure(.updateInProgress))
            }.sorted {
                if $0.key.kind == $1.key.kind { return $0.key.name < $1.key.name }
                return $0.key.kind.rawValue < $1.key.kind.rawValue
            }
        }
    }

    private func performUpdateAll(
        _ keys: [ProviderOperationKey],
        maximumConcurrent: Int
    ) async -> [ProviderBatchResult] {
        let uniqueKeys = Array(Set(keys)).sorted {
            if $0.kind == $1.kind { return $0.name < $1.name }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        let available = uniqueKeys.filter { key in
            if case .running = operationStates[key] { return false }
            return true
        }
        for key in available {
            operationStates[key] = .running(.update)
        }

        let client = apiClient
        // Product policy intentionally caps provider mutations at two even when
        // a caller supplies a larger value.
        let limit = min(2, max(1, maximumConcurrent))
        var iterator = available.makeIterator()
        var results: [ProviderBatchResult] = []
        await withTaskGroup(of: ProviderBatchResult.self) { group in
            for _ in 0 ..< limit {
                guard !Task.isCancelled else { break }
                guard let key = iterator.next() else { break }
                group.addTask { await Self.performUpdate(key, client: client) }
            }
            while let result = await group.next() {
                results.append(result)
                record(result)
                if !Task.isCancelled, let next = iterator.next() {
                    group.addTask { await Self.performUpdate(next, client: client) }
                }
            }
        }

        // Cancellation stops dispatching queued operations. They are reported
        // as skipped instead of pretending that Mihomo cancelled them.
        while let key = iterator.next() {
            let result = ProviderBatchResult(
                key: key,
                result: .failure(.cancelledBeforeStart)
            )
            results.append(result)
            record(result)
        }
        let alreadyRunning = uniqueKeys.filter { !available.contains($0) }.map {
            ProviderBatchResult(key: $0, result: .failure(.operationAlreadyRunning))
        }
        return (results + alreadyRunning).sorted {
            if $0.key.kind == $1.key.kind { return $0.key.name < $1.key.name }
            return $0.key.kind.rawValue < $1.key.kind.rawValue
        }
    }

    private func withRuntimeMutationLease<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        guard let runtimeMutationGate else {
            return try await operation()
        }

        let lease: RuntimeMutationLease
        do {
            lease = try await runtimeMutationGate.acquire(.controllerMutation)
        } catch RuntimeMutationGateError.updateInProgress {
            throw ProviderFailure.updateInProgress
        }

        do {
            let value = try await operation()
            await runtimeMutationGate.release(lease)
            return value
        } catch {
            await runtimeMutationGate.release(lease)
            throw error
        }
    }

    private func begin(_ operation: ProviderOperation, key: ProviderOperationKey) throws {
        if case .running = operationStates[key] {
            throw ProviderFailure.operationAlreadyRunning
        }
        operationStates[key] = .running(operation)
    }

    private func record(_ result: ProviderBatchResult) {
        switch result.result {
        case .success:
            operationStates[result.key] = .succeeded(.update, now())
        case .failure(.cancelledBeforeStart):
            operationStates.removeValue(forKey: result.key)
        case let .failure(error):
            operationStates[result.key] = .failed(.update, error)
        }
    }

    private static func performUpdate(
        _ key: ProviderOperationKey,
        client: any MihomoAPIProviding
    ) async -> ProviderBatchResult {
        guard !Task.isCancelled else {
            return ProviderBatchResult(
                key: key,
                result: .failure(.cancelledBeforeStart)
            )
        }
        do {
            switch key.kind {
            case .proxy:
                try await client.updateProxyProvider(named: key.name)
            case .rule:
                try await client.updateRuleProvider(named: key.name)
            }
            guard !Task.isCancelled else {
                return ProviderBatchResult(
                    key: key,
                    result: .failure(.cancelledResultUnknown)
                )
            }
            return ProviderBatchResult(key: key, result: .success(()))
        } catch is CancellationError {
            return ProviderBatchResult(key: key, result: .failure(.cancelledResultUnknown))
        } catch {
            return ProviderBatchResult(key: key, result: .failure(.updateFailed))
        }
    }
}
