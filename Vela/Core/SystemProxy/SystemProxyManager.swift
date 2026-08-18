import Foundation

actor SystemProxyTransactionGate {
    private struct QueueObserver {
        let minimumDepth: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var queueObservers: [QueueObserver] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            resumeSatisfiedObservers()
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }

        // Keep the gate held while ownership passes directly to the oldest
        // waiter. This makes all manager transactions strictly FIFO.
        waiters.removeFirst().resume()
    }

    func waitUntilQueueDepth(_ minimumDepth: Int) async {
        guard waiters.count < minimumDepth else {
            return
        }
        await withCheckedContinuation { continuation in
            queueObservers.append(
                QueueObserver(
                    minimumDepth: minimumDepth,
                    continuation: continuation
                )
            )
        }
    }

    private func resumeSatisfiedObservers() {
        var remainingObservers: [QueueObserver] = []
        for observer in queueObservers {
            if waiters.count >= observer.minimumDepth {
                observer.continuation.resume()
            } else {
                remainingObservers.append(observer)
            }
        }
        queueObservers = remainingObservers
    }
}

actor SystemProxyManager: SystemProxyManaging {
    private let backend: any SystemProxyBackend
    private let recoveryStore: any SystemProxyRecoveryStoring
    private let transactionGate: SystemProxyTransactionGate
    private let now: @Sendable () -> Date
    private var lastTarget: SystemProxyTarget

    init(
        backend: any SystemProxyBackend,
        recoveryStore: any SystemProxyRecoveryStoring,
        transactionGate: SystemProxyTransactionGate = SystemProxyTransactionGate(),
        initialTarget: SystemProxyTarget = SystemProxyTarget(port: Int(7890)),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.backend = backend
        self.recoveryStore = recoveryStore
        self.transactionGate = transactionGate
        self.lastTarget = initialTarget
        self.now = now
    }

    func status(for target: SystemProxyTarget) async throws -> SystemProxyStatus {
        await transactionGate.acquire()
        do {
            let result = try await performStatus(for: target)
            await transactionGate.release()
            return result
        } catch {
            await transactionGate.release()
            throw error
        }
    }

    private func performStatus(for target: SystemProxyTarget) async throws -> SystemProxyStatus {
        try validate(target)
        lastTarget = target

        let currentServices = try await backend.currentServices()
        let lease = try await recoveryStore.load()
        let leasedServices: [SystemProxyBackendService]
        if let lease {
            leasedServices = try await backend.services(withIDs: lease.services.map(\.id))
        } else {
            leasedServices = []
        }
        return try makeStatus(
            target: target,
            currentServices: currentServices,
            lease: lease,
            leasedServices: leasedServices
        )
    }

    func enable(_ target: SystemProxyTarget) async throws -> SystemProxyEnableResult {
        await transactionGate.acquire()
        do {
            // Cancellation while queued must not turn into a delayed system
            // write after an older transaction releases the FIFO gate.
            try Task.checkCancellation()
            let result = try await performEnable(target)
            await transactionGate.release()
            return result
        } catch {
            await transactionGate.release()
            throw error
        }
    }

    private func performEnable(_ target: SystemProxyTarget) async throws -> SystemProxyEnableResult {
        try validate(target)
        lastTarget = target

        let existingLease = try await recoveryStore.load()
        if let existingLease, existingLease.target != target {
            throw SystemProxyManagerError.recoveryLeaseTargetMismatch(
                expected: existingLease.target,
                requested: target
            )
        }

        let currentServices = try await backend.currentServices()
        guard !currentServices.isEmpty else {
            throw SystemProxyManagerError.noActiveNetworkServices
        }
        let automaticServiceNames = try currentServices.compactMap { service -> String? in
            let automatic = try SystemProxyPropertyList.automaticConfiguration(
                in: service.configuration
            )
            return automatic.isEnabled ? service.name : nil
        }.sorted()
        guard automaticServiceNames.isEmpty else {
            throw SystemProxyManagerError.automaticConfigurationEnabled(
                serviceNames: automaticServiceNames
            )
        }

        let existingEntries = Dictionary(
            uniqueKeysWithValues: (existingLease?.services ?? []).map { ($0.id, $0) }
        )
        let externallyTargetedServiceNames = try currentServices.compactMap { service -> String? in
            guard existingEntries[service.id] == nil else {
                return nil
            }
            let endpoints = try SystemProxyPropertyList.endpoints(in: service.configuration)
            return endpoints.contains { $0.matches(target) } ? service.name : nil
        }.sorted()
        guard externallyTargetedServiceNames.isEmpty else {
            throw SystemProxyManagerError.targetAlreadyConfiguredExternally(
                serviceNames: externallyTargetedServiceNames
            )
        }

        var candidateEntries = existingLease?.services ?? []
        var candidateLeaseChanged = false
        var mutations: [SystemProxyBackendMutation] = []
        var rollbackPoints: [RollbackPoint] = []
        var conflicts: [String] = []

        for service in currentServices {
            let desired = try SystemProxyPropertyList.applying(
                target: target,
                to: service.configuration
            )

            if let entry = existingEntries[service.id] {
                if SystemProxyPropertyList.managedFieldsEqual(
                    service.configuration,
                    entry.managedConfiguration
                ) {
                    continue
                }
                guard SystemProxyPropertyList.managedFieldsEqual(
                    service.configuration,
                    entry.originalConfiguration
                ) else {
                    conflicts.append(service.name)
                    continue
                }

                replaceEntry(
                    id: service.id,
                    in: &candidateEntries,
                    with: SystemProxyRecoveryService(
                        id: entry.id,
                        name: service.name,
                        originalConfiguration: entry.originalConfiguration,
                        managedConfiguration: desired
                    )
                )
                candidateLeaseChanged = true
                mutations.append(
                    SystemProxyBackendMutation(
                        serviceID: service.id,
                        serviceName: service.name,
                        expectedConfiguration: service.configuration,
                        configuration: desired
                    )
                )
                rollbackPoints.append(
                    RollbackPoint(
                        serviceID: service.id,
                        serviceName: service.name,
                        before: service.configuration,
                        after: desired
                    )
                )
            } else {
                guard !SystemProxyPropertyList.managedFieldsEqual(
                    service.configuration,
                    desired
                ) else {
                    continue
                }
                candidateEntries.append(
                    SystemProxyRecoveryService(
                        id: service.id,
                        name: service.name,
                        originalConfiguration: service.configuration,
                        managedConfiguration: desired
                    )
                )
                candidateLeaseChanged = true
                mutations.append(
                    SystemProxyBackendMutation(
                        serviceID: service.id,
                        serviceName: service.name,
                        expectedConfiguration: service.configuration,
                        configuration: desired
                    )
                )
                rollbackPoints.append(
                    RollbackPoint(
                        serviceID: service.id,
                        serviceName: service.name,
                        before: service.configuration,
                        after: desired
                    )
                )
            }
        }

        guard conflicts.isEmpty else {
            throw SystemProxyManagerError.externallyModified(
                serviceNames: conflicts.sorted()
            )
        }

        let candidateLease = SystemProxyRecoveryLease(
            createdAt: existingLease?.createdAt ?? now(),
            target: target,
            services: candidateEntries
        )
        if mutations.isEmpty {
            if candidateLeaseChanged {
                try await recoveryStore.save(candidateLease)
            }
            return SystemProxyEnableResult(
                status: try await performStatus(for: target),
                changedServiceNames: []
            )
        }
        try await recoveryStore.save(candidateLease)

        do {
            try await backend.apply(mutations)
        } catch let error as SystemProxyBackendError where error.definitelyRejectedBeforeCommit {
            let cleanupReason = await restoreRecoveryMetadata(to: existingLease)
            throw SystemProxyManagerError.enableRejectedBeforeCommit(
                reason: error.localizedDescription,
                recoveryCleanupReason: cleanupReason
            )
        } catch {
            let rollbackReason = await rollback(
                rollbackPoints,
                previousLease: existingLease
            )
            throw SystemProxyManagerError.enableFailed(
                reason: error.localizedDescription,
                rollbackReason: rollbackReason
            )
        }

        let failedVerification = try await servicesFailingVerification(
            rollbackPoints.map {
                VerificationPoint(
                    serviceID: $0.serviceID,
                    serviceName: $0.serviceName,
                    expected: $0.after
                )
            }
        )
        guard failedVerification.isEmpty else {
            let rollbackReason = await rollback(
                rollbackPoints,
                previousLease: existingLease
            )
            throw SystemProxyManagerError.enableVerificationFailed(
                serviceNames: failedVerification,
                rollbackReason: rollbackReason
            )
        }

        return SystemProxyEnableResult(
            status: try await performStatus(for: target),
            changedServiceNames: mutations.map(\.serviceName).sorted()
        )
    }

    func restore() async throws -> SystemProxyRestoreResult {
        await transactionGate.acquire()
        do {
            let result = try await performRestore()
            await transactionGate.release()
            return result
        } catch {
            await transactionGate.release()
            throw error
        }
    }

    private func performRestore() async throws -> SystemProxyRestoreResult {
        guard let lease = try await recoveryStore.load() else {
            return SystemProxyRestoreResult(
                status: try await performStatus(for: lastTarget),
                restoredServiceNames: [],
                alreadyRestoredServiceNames: [],
                conflictedServiceNames: [],
                missingServiceNames: []
            )
        }
        lastTarget = lease.target

        let actualServices = try await backend.services(withIDs: lease.services.map(\.id))
        let actualByID = Dictionary(uniqueKeysWithValues: actualServices.map { ($0.id, $0) })
        var mutations: [SystemProxyBackendMutation] = []
        var verificationPoints: [VerificationPoint] = []
        var restoredNames: [String] = []
        var alreadyRestoredNames: [String] = []
        var conflictNames: [String] = []
        var missingNames: [String] = []
        var retainedEntries: [SystemProxyRecoveryService] = []

        for entry in lease.services {
            guard let actual = actualByID[entry.id] else {
                missingNames.append(entry.name)
                retainedEntries.append(entry)
                continue
            }
            guard try recoveryBaselineContainsTarget(entry, target: lease.target) == false else {
                // A lease produced by an older/invalid adoption flow cannot
                // prove that this route belonged to Vela. Keep it blocking
                // recovery rather than clearing it and allowing Mihomo to stop.
                conflictNames.append(actual.name)
                retainedEntries.append(entry)
                continue
            }

            if SystemProxyPropertyList.managedFieldsEqual(actual.configuration, entry.originalConfiguration) {
                alreadyRestoredNames.append(actual.name)
                continue
            }

            let fieldRestore = try SystemProxyPropertyList.restoringManagedFieldsCAS(
                original: entry.originalConfiguration,
                managed: entry.managedConfiguration,
                actual: actual.configuration
            )
            if fieldRestore.conflictedKeyCount > 0 {
                conflictNames.append(actual.name)
            }
            guard fieldRestore.restoredKeyCount > 0 else {
                continue
            }
            mutations.append(
                SystemProxyBackendMutation(
                    serviceID: entry.id,
                    serviceName: actual.name,
                    expectedConfiguration: actual.configuration,
                    configuration: fieldRestore.configuration
                )
            )
            verificationPoints.append(
                VerificationPoint(
                    serviceID: entry.id,
                    serviceName: actual.name,
                    expected: fieldRestore.configuration
                )
            )
            restoredNames.append(actual.name)
        }

        if !mutations.isEmpty {
            do {
                try await backend.apply(mutations)
            } catch {
                throw SystemProxyManagerError.restoreFailed(
                    serviceNames: mutations.map(\.serviceName).sorted(),
                    reason: error.localizedDescription
                )
            }

            let failedVerification = try await servicesFailingVerification(verificationPoints)
            guard failedVerification.isEmpty else {
                throw SystemProxyManagerError.restoreVerificationFailed(
                    serviceNames: failedVerification
                )
            }
        }

        // Ordinary conflicts are released because their managed fields no
        // longer belong to Vela. Missing services and unsafe legacy baselines
        // remain blocking entries until they can be repaired safely.
        if retainedEntries.isEmpty {
            try await recoveryStore.clear()
        } else {
            try await recoveryStore.save(
                SystemProxyRecoveryLease(
                    version: lease.version,
                    createdAt: lease.createdAt,
                    target: lease.target,
                    services: retainedEntries
                )
            )
        }

        return SystemProxyRestoreResult(
            status: try await performStatus(for: lease.target),
            restoredServiceNames: restoredNames.sorted(),
            alreadyRestoredServiceNames: alreadyRestoredNames.sorted(),
            conflictedServiceNames: conflictNames.sorted(),
            missingServiceNames: missingNames.sorted()
        )
    }

    private func makeStatus(
        target: SystemProxyTarget,
        currentServices: [SystemProxyBackendService],
        lease: SystemProxyRecoveryLease?,
        leasedServices: [SystemProxyBackendService]
    ) throws -> SystemProxyStatus {
        let leaseByID = Dictionary(
            uniqueKeysWithValues: (lease?.services ?? []).map { ($0.id, $0) }
        )
        let serviceStates = try currentServices.map { service in
            let endpoints = try SystemProxyPropertyList.endpoints(in: service.configuration)
            let automatic = try SystemProxyPropertyList.automaticConfiguration(
                in: service.configuration
            )
            let ownership: SystemProxyServiceOwnership
            if let entry = leaseByID[service.id] {
                if try recoveryBaselineContainsTarget(entry, target: target) {
                    ownership = .untracked
                } else if SystemProxyPropertyList.managedFieldsEqual(
                    service.configuration,
                    entry.managedConfiguration
                ) {
                    ownership = .managedByVela
                } else if SystemProxyPropertyList.managedFieldsEqual(
                    service.configuration,
                    entry.originalConfiguration
                ) {
                    ownership = .alreadyRestored
                } else {
                    ownership = .externallyModified
                }
            } else {
                ownership = .untracked
            }

            return SystemProxyServiceState(
                id: service.id,
                name: service.name,
                isServiceEnabled: service.isEnabled,
                http: endpoints[0],
                https: endpoints[1],
                socks: endpoints[2],
                automatic: automatic,
                ownership: ownership
            )
        }

        let aggregate: SystemProxyAggregateState
        let endpoints = serviceStates.flatMap(\.endpoints)
        if serviceStates.isEmpty {
            aggregate = .unavailable
        } else if serviceStates.contains(where: { $0.automatic.isEnabled }) {
            aggregate = .externallyConfigured
        } else if endpoints.allSatisfy({ !$0.isEnabled }) {
            aggregate = .disabled
        } else if endpoints.allSatisfy({ $0.matches(target) }) {
            aggregate = serviceStates.allSatisfy { $0.ownership == .managedByVela }
                ? .applied
                : .externallyConfigured
        } else if endpoints.contains(where: { $0.matches(target) }) {
            aggregate = .partiallyApplied
        } else {
            aggregate = .externallyConfigured
        }

        let recovery: SystemProxyRecoveryState
        if let lease {
            let leasedByID = Dictionary(uniqueKeysWithValues: leasedServices.map { ($0.id, $0) })
            let managedNames = try lease.services.compactMap { entry -> String? in
                guard try recoveryBaselineContainsTarget(entry, target: lease.target) == false else {
                    return nil
                }
                guard let actual = leasedByID[entry.id] else {
                    return nil
                }
                return SystemProxyPropertyList.managedFieldsEqual(
                    actual.configuration,
                    entry.managedConfiguration
                ) ? actual.name : nil
            }
            if managedNames.count == lease.services.count {
                recovery = .managed(serviceNames: managedNames.sorted())
            } else {
                recovery = .recoveryRequired(
                    serviceNames: lease.services.map(\.name).sorted()
                )
            }
        } else {
            recovery = .none
        }

        return SystemProxyStatus(
            target: target,
            aggregate: aggregate,
            services: serviceStates,
            recovery: recovery
        )
    }

    private func rollback(
        _ points: [RollbackPoint],
        previousLease: SystemProxyRecoveryLease?
    ) async -> String? {
        do {
            let actualServices = try await backend.services(withIDs: points.map(\.serviceID))
            let actualByID = Dictionary(uniqueKeysWithValues: actualServices.map { ($0.id, $0) })
            var mutations: [SystemProxyBackendMutation] = []

            for point in points {
                guard let actual = actualByID[point.serviceID] else {
                    throw RollbackError.serviceMissing(point.serviceName)
                }
                if SystemProxyPropertyList.managedFieldsEqual(actual.configuration, point.before) {
                    continue
                }

                let fieldRestore = try SystemProxyPropertyList.restoringManagedFieldsCAS(
                    original: point.before,
                    managed: point.after,
                    actual: actual.configuration
                )
                guard fieldRestore.restoredKeyCount > 0 else {
                    continue
                }
                mutations.append(
                    SystemProxyBackendMutation(
                        serviceID: point.serviceID,
                        serviceName: point.serviceName,
                        expectedConfiguration: actual.configuration,
                        configuration: fieldRestore.configuration
                    )
                )
            }

            try await backend.apply(mutations)

            // A second CAS pass proves no fields attributable to Vela remain.
            // Keys changed by another owner are intentionally preserved.
            let verificationServices = try await backend.services(withIDs: points.map(\.serviceID))
            let verificationByID = Dictionary(
                uniqueKeysWithValues: verificationServices.map { ($0.id, $0) }
            )
            var residualNames: [String] = []
            for point in points {
                guard let actual = verificationByID[point.serviceID] else {
                    throw RollbackError.serviceMissing(point.serviceName)
                }
                let residual = try SystemProxyPropertyList.restoringManagedFieldsCAS(
                    original: point.before,
                    managed: point.after,
                    actual: actual.configuration
                )
                if residual.restoredKeyCount > 0 {
                    residualNames.append(point.serviceName)
                }
            }
            guard residualNames.isEmpty else {
                throw RollbackError.verificationFailed(residualNames.sorted())
            }

            if let previousLease {
                try await recoveryStore.save(previousLease)
            } else {
                try await recoveryStore.clear()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func restoreRecoveryMetadata(
        to previousLease: SystemProxyRecoveryLease?
    ) async -> String? {
        do {
            if let previousLease {
                try await recoveryStore.save(previousLease)
            } else {
                try await recoveryStore.clear()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func servicesFailingVerification(
        _ points: [VerificationPoint]
    ) async throws -> [String] {
        guard !points.isEmpty else {
            return []
        }
        let actualServices = try await backend.services(withIDs: points.map(\.serviceID))
        let actualByID = Dictionary(uniqueKeysWithValues: actualServices.map { ($0.id, $0) })
        return points.compactMap { point in
            guard let actual = actualByID[point.serviceID] else {
                return point.serviceName
            }
            return SystemProxyPropertyList.managedFieldsEqual(
                actual.configuration,
                point.expected
            ) ? nil : point.serviceName
        }.sorted()
    }

    private func replaceEntry(
        id: String,
        in entries: inout [SystemProxyRecoveryService],
        with replacement: SystemProxyRecoveryService
    ) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index] = replacement
        } else {
            entries.append(replacement)
        }
    }

    private func validate(_ target: SystemProxyTarget) throws {
        guard
            !target.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (1...65_535).contains(target.port)
        else {
            throw SystemProxyManagerError.invalidTarget(host: target.host, port: target.port)
        }
    }

    private func recoveryBaselineContainsTarget(
        _ entry: SystemProxyRecoveryService,
        target: SystemProxyTarget
    ) throws -> Bool {
        try SystemProxyPropertyList.endpoints(in: entry.originalConfiguration)
            .contains { $0.matches(target) }
    }
}

nonisolated private struct RollbackPoint: Sendable {
    let serviceID: String
    let serviceName: String
    let before: Data
    let after: Data
}

nonisolated private struct VerificationPoint: Sendable {
    let serviceID: String
    let serviceName: String
    let expected: Data
}

nonisolated private enum RollbackError: Error, Sendable {
    case serviceMissing(String)
    case externallyModified(String)
    case verificationFailed([String])
}

extension RollbackError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .serviceMissing(name):
            "Network service \(name) disappeared during rollback."
        case let .externallyModified(name):
            "Network service \(name) changed externally during rollback."
        case let .verificationFailed(names):
            "Rollback verification failed for \(names.joined(separator: ", "))."
        }
    }
}
