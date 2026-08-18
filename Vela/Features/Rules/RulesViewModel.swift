import Foundation
import Observation

@MainActor
@Observable
final class RulesViewModel {
    private let service: RulesService
    private let now: @MainActor @Sendable () -> Date
    private let presentationPipeline = RulesPresentationPipeline()
    private var filterTask: Task<Void, Never>?
    private var processingRevision: UInt64 = 0
    private var provenanceByID: [RuleID: RuleProvenanceEvidence] = [:]

    private(set) var rules: [ManagedRule] = []
    private(set) var visibleRules: [ManagedRule] = []
    private(set) var allRows: [RuntimeRuleRowModel] = []
    private(set) var visibleRows: [RuntimeRuleRowModel] = []
    private(set) var availableTypes: [String] = []
    private(set) var availablePolicies: [String] = []
    private(set) var availableSources: [String] = []
    private(set) var isLoading = false
    private(set) var isConfigurationApplying = false
    private(set) var hasReceivedSnapshot = false
    private(set) var lastSuccessfulRefreshAt: Date?
    private(set) var lastError: RulesFailure?
    private(set) var pendingMutation: PendingRuleMutation?
    private(set) var displayedGenerationID: UUID?
    private(set) var appliedProcessingRevision: UInt64 = 0

    var selectedRuleID: RuleID?
    var searchText = "" {
        didSet { scheduleProcessing(debounced: true) }
    }
    var typeFilter: String? {
        didSet { scheduleProcessing() }
    }
    var policyFilter: String? {
        didSet { scheduleProcessing() }
    }
    var sourceFilter: String? {
        didSet { scheduleProcessing() }
    }

#if DEBUG
    private var debugPhaseOverride: RulesWorkspacePhase?
    private(set) var isDebugFixtureReady = false
#endif

    init(
        service: RulesService,
        now: @escaping @MainActor @Sendable () -> Date = Date.init
    ) {
        self.service = service
        self.now = now
    }

    var selectedRule: ManagedRule? {
        presentation.inspector?.row.rule
    }

    var hasActiveFilters: Bool {
        typeFilter != nil || policyFilter != nil || sourceFilter != nil
    }

    var hasSearchOrFilters: Bool {
        hasActiveFilters
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var workspacePhase: RulesWorkspacePhase {
#if DEBUG
        if let debugPhaseOverride { return debugPhaseOverride }
#endif
        if pendingMutation != nil { return .temporaryMutation }
        if isConfigurationApplying { return .configurationApplying }
        if isLoading { return allRows.isEmpty ? .loading : .refreshing }
        if lastError != nil { return allRows.isEmpty ? .failure : .partialFailure }
        if !hasReceivedSnapshot { return .loading }
        if allRows.isEmpty { return .emptyConfiguration }
        if visibleRows.isEmpty, hasSearchOrFilters { return .noFilterResults }
        return .loaded
    }

    var presentation: RulesPresentationSnapshot {
        RulesPresentationFactory.make(
            phase: workspacePhase,
            configurationGenerationID: displayedGenerationID,
            allRows: allRows,
            visibleRows: visibleRows,
            selectedRuleID: selectedRuleID,
            availableTypes: availableTypes,
            availablePolicies: availablePolicies,
            availableSources: availableSources,
            hasSearchOrFilters: hasSearchOrFilters,
            lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
            referenceDate: now(),
            lastError: lastError,
            pendingMutation: pendingMutation
        )
    }

    func refresh() async {
        guard !isLoading, !isConfigurationApplying, pendingMutation == nil else {
            return
        }
        isLoading = true
        if allRows.isEmpty {
            selectedRuleID = nil
        }
        defer { isLoading = false }
        do {
            let refreshed = try await service.refresh()
            rules = refreshed
            displayedGenerationID = refreshed.first?.id.configurationGeneration.id
                ?? displayedGenerationID
            hasReceivedSnapshot = true
            lastSuccessfulRefreshAt = now()
            lastError = nil
            provenanceByID = provenanceByID.filter { id, _ in
                refreshed.contains(where: { $0.id == id })
            }
            await processCurrentState()
        } catch is CancellationError {
            // A page lifecycle cancellation is not a Controller failure.
        } catch let failure as RulesFailure {
            lastError = failure
            if allRows.isEmpty { selectedRuleID = nil }
            await processCurrentState()
        } catch {
            lastError = .fetchFailed
            if allRows.isEmpty { selectedRuleID = nil }
            await processCurrentState()
        }
    }

    func setDisabled(
        _ disabled: Bool,
        rule: ManagedRule
    ) async {
        let snapshot = presentation
        guard snapshot.actions.canToggleTemporaryState,
              snapshot.selectedRuleID == rule.id,
              let currentDisabled = rule.value.extra?.disabled,
              pendingMutation == nil
        else { return }

        pendingMutation = PendingRuleMutation(
            targetRuleID: rule.id,
            currentDisabled: currentDisabled,
            requestedDisabled: disabled,
            phase: .applying,
            startedAt: now()
        )
        lastError = nil
        do {
            let confirmed = try await service.setDisabled(disabled, for: rule.id)
            pendingMutation = PendingRuleMutation(
                targetRuleID: rule.id,
                currentDisabled: currentDisabled,
                requestedDisabled: disabled,
                phase: .verifying,
                startedAt: pendingMutation?.startedAt ?? now()
            )
            rules = confirmed
            lastSuccessfulRefreshAt = now()
            await processCurrentState()
            pendingMutation = nil
            lastError = nil
        } catch let failure as RulesFailure {
            pendingMutation = PendingRuleMutation(
                targetRuleID: rule.id,
                currentDisabled: currentDisabled,
                requestedDisabled: disabled,
                phase: .rollingBack,
                startedAt: pendingMutation?.startedAt ?? now()
            )
            lastError = failure
            await processCurrentState()
            pendingMutation = nil
        } catch {
            lastError = .toggleFailed
            await processCurrentState()
            pendingMutation = nil
        }
    }

    /// Observes the existing configuration transaction's catalog refresh.
    /// The committed rows remain visible and non-interactive until the new
    /// generation is confirmed; this does not create a second transaction.
    func configurationDidChange(
        _ generation: ConfigurationGeneration
    ) async {
        guard !isConfigurationApplying else { return }
        filterTask?.cancel()
        filterTask = nil
        pendingMutation = nil
        let committedRules = rules
        let committedSelection = selectedRuleID
        let committedGenerationID = displayedGenerationID
        let committedProvenance = provenanceByID
        isConfigurationApplying = true
        lastError = nil
        _ = await service.configurationDidChange(to: generation)

        do {
            let refreshed = try await service.refresh()
            rules = refreshed
            displayedGenerationID = generation.id
            provenanceByID = [:]
            selectedRuleID = nil
            hasReceivedSnapshot = true
            lastSuccessfulRefreshAt = now()
            lastError = nil
            await processCurrentState()
        } catch let failure as RulesFailure {
            rules = committedRules
            selectedRuleID = committedSelection
            displayedGenerationID = committedGenerationID
            provenanceByID = committedProvenance
            lastError = failure
            await processCurrentState()
        } catch {
            rules = committedRules
            selectedRuleID = committedSelection
            displayedGenerationID = committedGenerationID
            provenanceByID = committedProvenance
            lastError = .fetchFailed
            await processCurrentState()
        }
        isConfigurationApplying = false
    }

    func clearFilters() {
        searchText = ""
        typeFilter = nil
        policyFilter = nil
        sourceFilter = nil
    }

    func processingDiagnostics() async -> RulesProcessingDiagnostics {
        await presentationPipeline.diagnostics()
    }

#if DEBUG
    func installVisualFixture(
        rules fixtureRules: [ManagedRule],
        phase: RulesWorkspacePhase,
        selectedRuleID: RuleID?,
        provenance: [RuleID: RuleProvenanceEvidence],
        lastSuccessfulRefreshAt: Date?,
        error: RulesFailure? = nil,
        pendingMutation: PendingRuleMutation? = nil
    ) async {
        filterTask?.cancel()
        filterTask = nil
        debugPhaseOverride = phase == .loaded ? nil : phase
        isLoading = false
        isConfigurationApplying = false
        rules = phase.preservesCommittedRows ? fixtureRules : []
        provenanceByID = phase.preservesCommittedRows ? provenance : [:]
        displayedGenerationID = fixtureRules.first?.id.configurationGeneration.id
        hasReceivedSnapshot = phase != .loading
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
        lastError = error
        self.pendingMutation = pendingMutation
        self.selectedRuleID = selectedRuleID
        await processCurrentState()
        isDebugFixtureReady = true
    }
#endif

    private func scheduleProcessing(
        debounced: Bool = false
    ) {
        processingRevision &+= 1
        let revision = processingRevision
        filterTask?.cancel()
        filterTask = Task { @MainActor [weak self] in
            if debounced {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.processCurrentState(expectedRevision: revision)
        }
    }

    private func processCurrentState(
        expectedRevision: UInt64? = nil
    ) async {
        if expectedRevision == nil {
            processingRevision &+= 1
        }
        let revision = expectedRevision ?? processingRevision
        let request = RulesProcessingRequest(
            revision: revision,
            rules: rules,
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            filters: RulePresentationFilterSelection(
                type: typeFilter,
                policy: policyFilter,
                source: sourceFilter
            ),
            provenanceByID: provenanceByID
        )
        guard let result = await presentationPipeline.process(request),
              !Task.isCancelled,
              result.revision == processingRevision
        else { return }
        apply(result)
    }

    private func apply(
        _ result: RulesProcessingResult
    ) {
        allRows = result.allRows
        visibleRows = result.rows
        visibleRules = result.rows.map(\.rule)
        availableTypes = result.availableTypes
        availablePolicies = result.availablePolicies
        availableSources = result.availableSources
        appliedProcessingRevision = result.revision
        if let selectedRuleID,
           !result.rowsByID.keys.contains(selectedRuleID)
        {
            self.selectedRuleID = nil
        }
    }
}
