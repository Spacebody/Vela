import Foundation

nonisolated enum RulesWorkspacePhase: String, Equatable, Sendable {
    case loading
    case loaded
    case refreshing
    case stale
    case emptyConfiguration
    case noFilterResults
    case partialFailure
    case failure
    case configurationApplying
    case temporaryMutation

    var preservesCommittedRows: Bool {
        switch self {
        case .loaded, .refreshing, .stale, .partialFailure,
             .configurationApplying, .temporaryMutation:
            true
        case .loading, .emptyConfiguration, .noFilterResults, .failure:
            false
        }
    }
}

nonisolated enum RuleSourceLayer: String, CaseIterable, Equatable, Sendable {
    case upstream
    case global
    case configuration
    case scene
    case runtimeForced
    case builtIn
    case provider
    case unavailable
}

nonisolated enum RuleSourceConfidence: String, CaseIterable, Equatable, Sendable {
    case exact
    case ambiguous
    case unavailable
    case stale
}

nonisolated struct RuleProvenanceEvidence: Equatable, Sendable {
    let sourceLayer: RuleSourceLayer
    let sourceDisplayName: String?
    let sourcePointer: String?
    let providerDisplayName: String?
    let providerEntry: String?
    let providerStatus: String?
    let confidence: RuleSourceConfidence
    let evidenceGenerationID: UUID?

    static func unavailable(
        generationID: UUID?
    ) -> RuleProvenanceEvidence {
        RuleProvenanceEvidence(
            sourceLayer: .unavailable,
            sourceDisplayName: nil,
            sourcePointer: nil,
            providerDisplayName: nil,
            providerEntry: nil,
            providerStatus: nil,
            confidence: .unavailable,
            evidenceGenerationID: generationID
        )
    }
}

nonisolated enum RuleMutationPhase: String, CaseIterable, Equatable, Sendable {
    case preparing
    case applying
    case verifying
    case rollingBack
}

nonisolated struct PendingRuleMutation: Equatable, Sendable {
    let targetRuleID: RuleID
    let currentDisabled: Bool
    let requestedDisabled: Bool
    let phase: RuleMutationPhase
    let startedAt: Date
}

nonisolated struct RuntimeRuleRowModel: Identifiable, Equatable, Sendable {
    let rule: ManagedRule
    let runtimePosition: Int
    let provenance: RuleProvenanceEvidence

    var id: RuleID { rule.id }
    var runtimeIndex: Int { rule.originalIndex }
    var type: String { rule.value.type }
    var payload: String { rule.value.payload }
    var policy: String { rule.value.proxy }
    var hitCount: UInt64? { rule.value.extra?.hitCount }
    var lastMatchedAt: Date? { rule.value.extra?.hitAt }
    var isTemporarilyDisabled: Bool? { rule.value.extra?.disabled }

    var rawRule: String {
        [type, payload, policy]
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }
}

nonisolated struct RuleInspectorSnapshot: Equatable, Sendable {
    let row: RuntimeRuleRowModel
    let confidence: RuleSourceConfidence
    let pendingMutation: PendingRuleMutation?
    let isFinalFallback: Bool
}

nonisolated struct RulesActionAvailability: Equatable, Sendable {
    let canRefresh: Bool
    let canSearchAndFilter: Bool
    let canToggleTemporaryState: Bool
    let canOpenWorkbench: Bool
    let canOpenProvider: Bool
}

nonisolated struct RulesPresentationSnapshot: Equatable, Sendable {
    let phase: RulesWorkspacePhase
    let configurationGenerationID: UUID?
    let allRows: [RuntimeRuleRowModel]
    let rows: [RuntimeRuleRowModel]
    let totalRuleCount: Int
    let selectedRuleID: RuleID?
    let inspector: RuleInspectorSnapshot?
    let actions: RulesActionAvailability
    let availableTypes: [String]
    let availablePolicies: [String]
    let availableSources: [String]
    let hasSearchOrFilters: Bool
    let snapshotAge: TimeInterval?
    let lastError: RulesFailure?
    let pendingMutation: PendingRuleMutation?
}

nonisolated enum RulesSelectionPolicy {
    static func resolve(
        requestedID: RuleID?,
        rows: [RuntimeRuleRowModel]
    ) -> RuleID? {
        guard let requestedID,
              rows.contains(where: { $0.id == requestedID })
        else { return nil }
        return requestedID
    }
}

nonisolated enum RulesPresentationFactory {
    static func make(
        phase: RulesWorkspacePhase,
        configurationGenerationID: UUID?,
        allRows: [RuntimeRuleRowModel],
        visibleRows: [RuntimeRuleRowModel],
        selectedRuleID: RuleID?,
        availableTypes: [String],
        availablePolicies: [String],
        availableSources: [String],
        hasSearchOrFilters: Bool,
        lastSuccessfulRefreshAt: Date?,
        referenceDate: Date,
        lastError: RulesFailure?,
        pendingMutation: PendingRuleMutation?
    ) -> RulesPresentationSnapshot {
        let rows: [RuntimeRuleRowModel]
        switch phase {
        case .loading, .emptyConfiguration, .failure, .noFilterResults:
            rows = []
        case .loaded, .refreshing, .stale, .partialFailure,
             .configurationApplying, .temporaryMutation:
            rows = visibleRows
        }

        let selection = RulesSelectionPolicy.resolve(
            requestedID: selectedRuleID,
            rows: rows
        )
        let selectedRow = selection.flatMap { id in
            rows.first { $0.id == id }
        }
        let confidence: RuleSourceConfidence? = selectedRow.map { row in
            if phase == .stale || phase == .configurationApplying {
                return .stale
            }
            return row.provenance.confidence
        }
        let inspector = selectedRow.map { row in
            RuleInspectorSnapshot(
                row: row,
                confidence: confidence ?? .unavailable,
                pendingMutation: pendingMutation?.targetRuleID == row.id
                    ? pendingMutation
                    : nil,
                isFinalFallback: allRows.last?.id == row.id
                    && row.type.caseInsensitiveCompare("MATCH") == .orderedSame
            )
        }
        let selectedSupportsMutation = selectedRow?.rule.value.extra != nil
        let selectedHasExactSource = inspector?.confidence == .exact
        let selectedHasProvider = selectedRow?.provenance.providerDisplayName != nil
        let interactionsAreStable = phase == .loaded

        return RulesPresentationSnapshot(
            phase: phase,
            configurationGenerationID: configurationGenerationID,
            allRows: allRows,
            rows: rows,
            totalRuleCount: allRows.count,
            selectedRuleID: selection,
            inspector: inspector,
            actions: RulesActionAvailability(
                canRefresh: ![.loading, .refreshing, .configurationApplying,
                              .temporaryMutation].contains(phase),
                canSearchAndFilter: !allRows.isEmpty
                    && ![.configurationApplying, .temporaryMutation].contains(phase),
                canToggleTemporaryState: interactionsAreStable
                    && selectedSupportsMutation,
                canOpenWorkbench: selectedHasExactSource,
                canOpenProvider: selectedHasExactSource && selectedHasProvider
            ),
            availableTypes: availableTypes,
            availablePolicies: availablePolicies,
            availableSources: availableSources,
            hasSearchOrFilters: hasSearchOrFilters,
            snapshotAge: lastSuccessfulRefreshAt.map {
                max(0, referenceDate.timeIntervalSince($0))
            },
            lastError: lastError,
            pendingMutation: pendingMutation
        )
    }
}

nonisolated struct RulePresentationFilterSelection: Equatable, Sendable {
    let type: String?
    let policy: String?
    let source: String?
}

nonisolated struct RulesProcessingRequest: Sendable {
    let revision: UInt64
    let rules: [ManagedRule]
    let query: String
    let filters: RulePresentationFilterSelection
    let provenanceByID: [RuleID: RuleProvenanceEvidence]
}

nonisolated struct RulesProcessingResult: Sendable {
    let revision: UInt64
    let allRows: [RuntimeRuleRowModel]
    let rows: [RuntimeRuleRowModel]
    let rowsByID: [RuleID: RuntimeRuleRowModel]
    let availableTypes: [String]
    let availablePolicies: [String]
    let availableSources: [String]
}

nonisolated struct RulesProcessingDiagnostics: Equatable, Sendable {
    let submittedRequestCount: Int
    let startedWorkerCount: Int
    let completedWorkerCount: Int
    let cancelledWorkerCount: Int
    let activeWorkerCount: Int
    let maximumConcurrentWorkerCount: Int
}

actor RulesPresentationPipeline {
    private struct ActiveWorker {
        let ticket: UInt64
        let task: Task<RulesProcessingResult?, Never>
    }

    private var nextTicket: UInt64 = 0
    private var latestTicket: UInt64 = 0
    private var activeWorker: ActiveWorker?
    private var finalizedTicket: UInt64 = 0
    private var submittedRequestCount = 0
    private var startedWorkerCount = 0
    private var completedWorkerCount = 0
    private var cancelledWorkerCount = 0
    private var activeWorkerCount = 0
    private var maximumConcurrentWorkerCount = 0

    func process(
        _ request: RulesProcessingRequest
    ) async -> RulesProcessingResult? {
        nextTicket &+= 1
        let ticket = nextTicket
        latestTicket = ticket
        submittedRequestCount += 1

        if let previous = activeWorker {
            previous.task.cancel()
            let previousResult = await previous.task.value
            recordCompletion(of: previous, result: previousResult)
            if activeWorker?.ticket == previous.ticket {
                activeWorker = nil
            }
        }
        guard ticket == latestTicket, !Task.isCancelled else { return nil }

        let worker = ActiveWorker(
            ticket: ticket,
            task: Task.detached(priority: .userInitiated) {
                RulesPresentationBuilder.build(request)
            }
        )
        activeWorker = worker
        startedWorkerCount += 1
        activeWorkerCount += 1
        maximumConcurrentWorkerCount = max(
            maximumConcurrentWorkerCount,
            activeWorkerCount
        )

        let result = await withTaskCancellationHandler {
            await worker.task.value
        } onCancel: {
            worker.task.cancel()
        }
        recordCompletion(of: worker, result: result)
        if activeWorker?.ticket == ticket {
            activeWorker = nil
        }
        guard ticket == latestTicket, !Task.isCancelled else { return nil }
        return result
    }

    func cancel() async {
        nextTicket &+= 1
        latestTicket = nextTicket
        guard let worker = activeWorker else { return }
        worker.task.cancel()
        let result = await worker.task.value
        recordCompletion(of: worker, result: result)
        if activeWorker?.ticket == worker.ticket {
            activeWorker = nil
        }
    }

    func diagnostics() -> RulesProcessingDiagnostics {
        RulesProcessingDiagnostics(
            submittedRequestCount: submittedRequestCount,
            startedWorkerCount: startedWorkerCount,
            completedWorkerCount: completedWorkerCount,
            cancelledWorkerCount: cancelledWorkerCount,
            activeWorkerCount: activeWorkerCount,
            maximumConcurrentWorkerCount: maximumConcurrentWorkerCount
        )
    }

    private func recordCompletion(
        of worker: ActiveWorker,
        result: RulesProcessingResult?
    ) {
        guard worker.ticket > finalizedTicket else { return }
        finalizedTicket = worker.ticket
        activeWorkerCount = max(0, activeWorkerCount - 1)
        if result == nil {
            cancelledWorkerCount += 1
        } else {
            completedWorkerCount += 1
        }
    }
}

nonisolated private enum RulesPresentationBuilder {
    static func build(
        _ request: RulesProcessingRequest
    ) -> RulesProcessingResult? {
        var allRows: [RuntimeRuleRowModel] = []
        var rows: [RuntimeRuleRowModel] = []
        var rowsByID: [RuleID: RuntimeRuleRowModel] = [:]
        var types = Set<String>()
        var policies = Set<String>()
        var sources = Set<String>()
        allRows.reserveCapacity(request.rules.count)
        rows.reserveCapacity(request.rules.count)
        rowsByID.reserveCapacity(request.rules.count)

        for (position, rule) in request.rules.enumerated() {
            if position.isMultiple(of: 128), Task.isCancelled { return nil }
            let evidence = request.provenanceByID[rule.id]
                ?? .unavailable(generationID: rule.id.configurationGeneration.id)
            let row = RuntimeRuleRowModel(
                rule: rule,
                runtimePosition: position,
                provenance: evidence
            )
            allRows.append(row)
            if !row.type.isEmpty { types.insert(row.type) }
            if !row.policy.isEmpty { policies.insert(row.policy) }
            if let source = evidence.sourceDisplayName, !source.isEmpty {
                sources.insert(source)
            }
            guard matchesFilters(row, filters: request.filters) else { continue }
            guard matchesQuery(row, query: request.query) else { continue }
            rows.append(row)
            rowsByID[row.id] = row
        }
        guard !Task.isCancelled else { return nil }

        return RulesProcessingResult(
            revision: request.revision,
            allRows: allRows,
            rows: rows,
            rowsByID: rowsByID,
            availableTypes: sorted(types),
            availablePolicies: sorted(policies),
            availableSources: sorted(sources)
        )
    }

    private static func matchesFilters(
        _ row: RuntimeRuleRowModel,
        filters: RulePresentationFilterSelection
    ) -> Bool {
        guard filters.type == nil || row.type == filters.type else { return false }
        guard filters.policy == nil || row.policy == filters.policy else { return false }
        guard filters.source == nil
                || row.provenance.sourceDisplayName == filters.source
        else { return false }
        return true
    }

    private static func matchesQuery(
        _ row: RuntimeRuleRowModel,
        query: String
    ) -> Bool {
        guard !query.isEmpty else { return true }
        return [
            row.type,
            row.payload,
            row.policy,
            row.provenance.sourceDisplayName,
            row.provenance.providerDisplayName,
            row.provenance.sourcePointer,
            row.provenance.providerEntry,
        ]
        .compactMap { $0 }
        .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func sorted(_ values: Set<String>) -> [String] {
        values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
}
