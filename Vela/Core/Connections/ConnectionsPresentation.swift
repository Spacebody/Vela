import Foundation

nonisolated enum ConnectionsWorkspacePhase: String, Equatable, Sendable {
    case loading
    case loaded
    case empty
    case refreshing
    case stale
    case partialFailure
    case failure
    case pendingMutation
    case offlineWithSnapshot
    case offlineWithoutSnapshot

    var retainsLastGoodSnapshot: Bool {
        switch self {
        case .loaded, .refreshing, .stale, .partialFailure,
             .pendingMutation, .offlineWithSnapshot:
            true
        case .loading, .empty, .failure, .offlineWithoutSnapshot:
            false
        }
    }

    var permitsConnectionMutation: Bool {
        switch self {
        case .loaded, .stale, .partialFailure:
            true
        case .loading, .empty, .refreshing, .failure, .pendingMutation,
             .offlineWithSnapshot, .offlineWithoutSnapshot:
            false
        }
    }
}

nonisolated struct ConnectionsPresentationGeneration: Equatable, Sendable {
    let configurationID: UUID
    let snapshotRevision: UInt64
}

nonisolated enum ConnectionMutationPhase: String, CaseIterable, Equatable, Sendable {
    case preparing
    case closing
    case verifying
    case committing
    case rollingBack
}

nonisolated struct PendingConnectionMutation: Equatable, Sendable {
    let targetConnectionID: String
    let configurationID: UUID
    let phase: ConnectionMutationPhase
    let startedAt: Date
}

nonisolated struct ConnectionInspectorSnapshot: Equatable, Sendable {
    let generation: ConnectionsPresentationGeneration
    let row: ConnectionRowModel
    let evidenceConfidence: ConnectionRouteEvidenceConfidence
    let pendingMutation: PendingConnectionMutation?
    let snapshotAge: TimeInterval?

    var id: String { row.id }
}

nonisolated struct ConnectionsActionAvailability: Equatable, Sendable {
    let canRefresh: Bool
    let canCloseSelected: Bool
    let canCloseAll: Bool
    let canCopyRedactedSummary: Bool
    let canRunDiagnostics: Bool
}

nonisolated struct ConnectionsPresentationSnapshot: Equatable, Sendable {
    let generation: ConnectionsPresentationGeneration
    let phase: ConnectionsWorkspacePhase
    let rows: [ConnectionRowModel]
    let selectedConnectionID: String?
    let inspector: ConnectionInspectorSnapshot?
    let metrics: ConnectionMetricsPresentation
    let availableProtocols: [String]
    let lastSuccessfulRefreshAt: Date?
    let snapshotAge: TimeInterval?
    let pendingMutation: PendingConnectionMutation?
    let lastError: ConnectionsFailure?
    let isPaused: Bool
    let actions: ConnectionsActionAvailability

    var totalConnectionCount: Int { metrics.connectionCount }
}

nonisolated enum ConnectionsSelectionPolicy {
    static func resolve(
        requestedID: String?,
        selectionConfigurationID: UUID?,
        currentConfigurationID: UUID,
        rows: [ConnectionRowModel]
    ) -> String? {
        guard let requestedID,
              selectionConfigurationID == currentConfigurationID,
              rows.contains(where: { $0.id == requestedID })
        else {
            return nil
        }
        return requestedID
    }
}

nonisolated enum ConnectionsPresentationFactory {
    static func make(
        configurationID: UUID,
        snapshotRevision: UInt64,
        phase: ConnectionsWorkspacePhase,
        rows: [ConnectionRowModel],
        selectedConnectionID: String?,
        selectionConfigurationID: UUID?,
        metrics: ConnectionMetricsPresentation,
        availableProtocols: [String],
        lastSuccessfulRefreshAt: Date?,
        referenceDate: Date,
        pendingMutation: PendingConnectionMutation?,
        lastError: ConnectionsFailure?,
        isPaused: Bool
    ) -> ConnectionsPresentationSnapshot {
        let generation = ConnectionsPresentationGeneration(
            configurationID: configurationID,
            snapshotRevision: snapshotRevision
        )
        let visibleRows = phase.retainsLastGoodSnapshot ? rows : []
        let resolvedSelection = ConnectionsSelectionPolicy.resolve(
            requestedID: selectedConnectionID,
            selectionConfigurationID: selectionConfigurationID,
            currentConfigurationID: configurationID,
            rows: visibleRows
        )
        let validMutation = pendingMutation.flatMap { mutation in
            mutation.configurationID == configurationID
                && visibleRows.contains(where: { $0.id == mutation.targetConnectionID })
                ? mutation
                : nil
        }
        let snapshotAge = lastSuccessfulRefreshAt.map {
            max(0, referenceDate.timeIntervalSince($0))
        }
        let inspector = resolvedSelection.flatMap { id in
            visibleRows.first(where: { $0.id == id }).map { row in
                ConnectionInspectorSnapshot(
                    generation: generation,
                    row: row,
                    evidenceConfidence: evidenceConfidence(for: phase),
                    pendingMutation: validMutation?.targetConnectionID == id
                        ? validMutation
                        : nil,
                    snapshotAge: snapshotAge
                )
            }
        }
        let canMutate = phase.permitsConnectionMutation && validMutation == nil
        let actions = ConnectionsActionAvailability(
            canRefresh: phase != .loading
                && phase != .refreshing
                && phase != .pendingMutation,
            canCloseSelected: canMutate && resolvedSelection != nil,
            canCloseAll: canMutate && !visibleRows.isEmpty,
            canCopyRedactedSummary: inspector != nil,
            canRunDiagnostics: phase == .failure
                || phase == .partialFailure
                || phase == .offlineWithSnapshot
                || phase == .offlineWithoutSnapshot
        )

        return ConnectionsPresentationSnapshot(
            generation: generation,
            phase: phase,
            rows: visibleRows,
            selectedConnectionID: resolvedSelection,
            inspector: inspector,
            metrics: metrics,
            availableProtocols: availableProtocols,
            lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
            snapshotAge: snapshotAge,
            pendingMutation: validMutation,
            lastError: lastError,
            isPaused: isPaused,
            actions: actions
        )
    }

    private static func evidenceConfidence(
        for phase: ConnectionsWorkspacePhase
    ) -> ConnectionRouteEvidenceConfidence {
        switch phase {
        case .stale, .offlineWithSnapshot:
            .staleGeneration
        case .loading, .loaded, .empty, .refreshing, .partialFailure,
             .failure, .pendingMutation, .offlineWithoutSnapshot:
            // Mihomo exposes the chosen rule and chain, but not the rule-source
            // confidence or an index tied to the active runtime generation.
            .unavailable
        }
    }
}
