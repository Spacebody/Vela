import Foundation
import Testing
@testable import Vela

@Suite("Rules runtime inspector presentation")
struct RulesPresentationTests {
    private let generation = ConfigurationGeneration(
        id: UUID(uuidString: "6B832983-C3E8-4F53-9D9A-9D2402CB9C01")!
    )
    private let now = Date(timeIntervalSince1970: 1_752_485_100)

    @Test("Recovery reason preserves four truthful presentation states")
    func recoveryReasonResolution() {
        #expect(RulesRecoveryReason.resolve(
            phase: .failure,
            availability: RulesRuntimeAvailability(
                isMihomoRunning: false,
                isControllerConnected: false,
                hasConfiguration: true
            )
        ) == .mihomoStopped)
        #expect(RulesRecoveryReason.resolve(
            phase: .failure,
            availability: RulesRuntimeAvailability(
                isMihomoRunning: true,
                isControllerConnected: false,
                hasConfiguration: true
            )
        ) == .controllerDisconnected)
        #expect(RulesRecoveryReason.resolve(
            phase: .failure,
            availability: .available
        ) == .ruleFetchFailed)
        #expect(RulesRecoveryReason.resolve(
            phase: .emptyConfiguration,
            availability: RulesRuntimeAvailability(
                isMihomoRunning: false,
                isControllerConnected: false,
                hasConfiguration: false
            )
        ) == .emptyConfiguration)
    }

    @Test("Catalog entry refreshes once and requires explicit retry after failure")
    func catalogEntryRefreshPolicy() {
        #expect(CatalogEntryRefreshPolicy.shouldRefresh(
            hasReceivedSnapshot: false,
            hasError: false
        ))
        #expect(!CatalogEntryRefreshPolicy.shouldRefresh(
            hasReceivedSnapshot: true,
            hasError: false
        ))
        #expect(!CatalogEntryRefreshPolicy.shouldRefresh(
            hasReceivedSnapshot: false,
            hasError: true
        ))
        #expect(!CatalogEntryRefreshPolicy.shouldRefresh(
            hasReceivedSnapshot: true,
            hasError: true
        ))
    }

    @Test("No-snapshot and filtered-empty states fail closed")
    func noSnapshotStatesClearRowsSelectionAndInspector() throws {
        let rows = try makeRows()
        for phase in [
            RulesWorkspacePhase.loading,
            .emptyConfiguration,
            .noFilterResults,
            .failure,
        ] {
            let snapshot = makeSnapshot(
                phase: phase,
                rows: rows,
                selectedRuleID: rows[0].id,
                hasSearchOrFilters: phase == .noFilterResults
            )
            #expect(snapshot.rows.isEmpty)
            #expect(snapshot.selectedRuleID == nil)
            #expect(snapshot.inspector == nil)
            #expect(!snapshot.actions.canToggleTemporaryState)
        }
    }

    @Test("Refresh, stale, partial failure, and configuration apply preserve committed rows")
    func lastGoodSnapshotStatesPreserveRows() throws {
        let rows = try makeRows()
        for phase in [
            RulesWorkspacePhase.refreshing,
            .stale,
            .partialFailure,
            .configurationApplying,
        ] {
            let snapshot = makeSnapshot(
                phase: phase,
                rows: rows,
                selectedRuleID: rows[0].id
            )
            #expect(snapshot.rows.map(\.id) == rows.map(\.id))
            #expect(snapshot.selectedRuleID == rows[0].id)
            #expect(snapshot.inspector?.row.id == rows[0].id)
            #expect(!snapshot.actions.canToggleTemporaryState)
            if phase == .stale || phase == .configurationApplying {
                #expect(snapshot.inspector?.confidence == .stale)
            }
        }
    }

    @Test("Temporary mutation reports the exact target and committed/requested values")
    func temporaryMutationIsExplicit() throws {
        let rows = try makeRows()
        let mutation = PendingRuleMutation(
            targetRuleID: rows[0].id,
            currentDisabled: false,
            requestedDisabled: true,
            phase: .verifying,
            startedAt: now.addingTimeInterval(-1)
        )
        let snapshot = makeSnapshot(
            phase: .temporaryMutation,
            rows: rows,
            selectedRuleID: rows[0].id,
            pendingMutation: mutation
        )

        #expect(snapshot.pendingMutation == mutation)
        #expect(snapshot.inspector?.pendingMutation == mutation)
        #expect(snapshot.inspector?.pendingMutation?.currentDisabled == false)
        #expect(snapshot.inspector?.pendingMutation?.requestedDisabled == true)
        #expect(snapshot.inspector?.pendingMutation?.phase == .verifying)
        #expect(!snapshot.actions.canRefresh)
        #expect(!snapshot.actions.canSearchAndFilter)
    }

    @Test("Provenance actions require exact evidence and a matching provider")
    func provenanceActionsFailClosed() throws {
        let rows = try makeRows()

        let exact = makeSnapshot(
            phase: .loaded,
            rows: rows,
            selectedRuleID: rows[0].id
        )
        #expect(exact.actions.canOpenWorkbench)
        #expect(!exact.actions.canOpenProvider)
        #expect(exact.actions.canToggleTemporaryState)

        let provider = makeSnapshot(
            phase: .loaded,
            rows: rows,
            selectedRuleID: rows[1].id
        )
        #expect(provider.actions.canOpenWorkbench)
        #expect(provider.actions.canOpenProvider)

        let unavailable = makeSnapshot(
            phase: .loaded,
            rows: rows,
            selectedRuleID: rows[2].id
        )
        #expect(!unavailable.actions.canOpenWorkbench)
        #expect(!unavailable.actions.canOpenProvider)
        #expect(!unavailable.actions.canToggleTemporaryState)
    }

    @Test("Stable identity is generation-aware and runtime order is untouched")
    func generationIdentityAndRuntimeOrder() throws {
        let rows = try makeRows()
        #expect(rows.map(\.runtimeIndex) == [90, 4, 120])
        #expect(rows.map(\.runtimePosition) == [0, 1, 2])
        #expect(rows.map(\.id.originalIndex) == [90, 4, 120])

        let nextGeneration = ConfigurationGeneration(
            id: UUID(uuidString: "C4A37FF3-28B2-41B6-A94E-039EE2AEE402")!
        )
        let sameIndex = RuleID(
            configurationGeneration: nextGeneration,
            originalIndex: rows[0].runtimeIndex
        )
        #expect(sameIndex != rows[0].id)
        #expect(
            RulesSelectionPolicy.resolve(
                requestedID: sameIndex,
                rows: rows
            ) == nil
        )
    }

    @Test("MATCH final rule exposes fallback semantics")
    func finalFallbackIsDetected() throws {
        let rows = try makeRows()
        let snapshot = makeSnapshot(
            phase: .loaded,
            rows: rows,
            selectedRuleID: rows.last?.id
        )
        #expect(snapshot.inspector?.isFinalFallback == true)
    }

    @Test("Responsive layout uses compact, regular, and spacious columns")
    func responsiveLayoutMetrics() {
        let compact = RulesLayoutMetrics.resolve(
            detailWidth: 600,
            tableAvailableWidth: 600
        )
        let regular = RulesLayoutMetrics.resolve(
            detailWidth: 780,
            tableAvailableWidth: 780
        )
        let spacious = RulesLayoutMetrics.resolve(
            detailWidth: 1_050,
            tableAvailableWidth: 1_050
        )

        #expect(compact.columnSet == .compact)
        #expect(regular.columnSet == .regular)
        #expect(spacious.columnSet == .spacious)
        #expect(RulesLayoutMetrics.tableRowHeight == VelaMetrics.tableRowHeight)
        #expect(RulesLayoutMetrics.tableCellContentHeight == 26)
        #expect(RulesLayoutMetrics.inspectorMinimumWidth == 300)
        #expect(RulesLayoutMetrics.inspectorMaximumWidth == 380)
    }

    @Test("Search and filters preserve Controller order and include provenance")
    func pipelinePreservesOrderAndSearchesProvenance() async throws {
        let rules = try makeRows().map(\.rule)
        let evidence = try Dictionary(
            uniqueKeysWithValues: makeRows().map { ($0.id, $0.provenance) }
        )
        let pipeline = RulesPresentationPipeline()
        let result = try #require(await pipeline.process(
            RulesProcessingRequest(
                revision: 1,
                rules: rules,
                query: "Provider A",
                filters: RulePresentationFilterSelection(
                    type: nil,
                    policy: nil,
                    source: nil
                ),
                provenanceByID: evidence
            )
        ))

        #expect(result.allRows.map(\.runtimeIndex) == [90, 4, 120])
        #expect(result.rows.map(\.runtimeIndex) == [4])
    }

    @Test("Five hundred searches cancel and join without overlapping workers")
    func fiveHundredSearchResourceTest() async throws {
        let rows = try makeRows()
        let rules = rows.map(\.rule)
        let evidence = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.provenance) })
        let pipeline = RulesPresentationPipeline()

        for revision in 1...500 {
            let result = await pipeline.process(
                RulesProcessingRequest(
                    revision: UInt64(revision),
                    rules: rules,
                    query: revision.isMultiple(of: 2) ? "MATCH" : "Automatic",
                    filters: RulePresentationFilterSelection(
                        type: nil,
                        policy: nil,
                        source: nil
                    ),
                    provenanceByID: evidence
                )
            )
            #expect(result?.revision == UInt64(revision))
        }
        await pipeline.cancel()
        let diagnostics = await pipeline.diagnostics()
        #expect(diagnostics.submittedRequestCount == 500)
        #expect(diagnostics.activeWorkerCount == 0)
        #expect(diagnostics.maximumConcurrentWorkerCount == 1)
        #expect(
            diagnostics.completedWorkerCount + diagnostics.cancelledWorkerCount
                == diagnostics.startedWorkerCount
        )
    }

    @Test("One hundred refresh generations keep stable identity isolated")
    func oneHundredRefreshGenerationResourceTest() async throws {
        let rules = try makeRows().map(\.rule.value)
        let client = RulesPresentationAPIFake(rules: rules)
        let service = RulesService(apiClient: client)
        var generationIDs = Set<UUID>()

        for index in 0..<100 {
            let generation = ConfigurationGeneration(
                id: UUID(
                    uuid: (
                        0xA1, 0x04, 0x11, 0x9F,
                        0x32, 0x72,
                        0x4C, 0x89,
                        0xA5, 0x30,
                        0x00, 0x00, 0x00, 0x00,
                        UInt8(index / 256), UInt8(index % 256)
                    )
                )
            )
            await service.configurationDidChange(to: generation)
            let refreshed = try await service.refresh()
            #expect(refreshed.map(\.originalIndex) == [90, 4, 120])
            #expect(refreshed.allSatisfy {
                $0.id.configurationGeneration == generation
            })
            generationIDs.insert(generation.id)
        }
        #expect(generationIDs.count == 100)
        #expect(await client.ruleCallCount() == 100)
    }

    private func makeSnapshot(
        phase: RulesWorkspacePhase,
        rows: [RuntimeRuleRowModel],
        selectedRuleID: RuleID?,
        hasSearchOrFilters: Bool = false,
        pendingMutation: PendingRuleMutation? = nil
    ) -> RulesPresentationSnapshot {
        RulesPresentationFactory.make(
            phase: phase,
            configurationGenerationID: generation.id,
            allRows: rows,
            visibleRows: rows,
            selectedRuleID: selectedRuleID,
            availableTypes: ["DOMAIN-SUFFIX", "MATCH", "RULE-SET"],
            availablePolicies: ["Automatic", "Fallback", "Work"],
            availableSources: ["Daily Driver"],
            hasSearchOrFilters: hasSearchOrFilters,
            lastSuccessfulRefreshAt: now.addingTimeInterval(-42),
            referenceDate: now,
            lastError: phase == .failure || phase == .partialFailure
                ? .fetchFailed
                : nil,
            pendingMutation: pendingMutation
        )
    }

    private func makeRows() throws -> [RuntimeRuleRowModel] {
        let first = try makeRule(
            index: 90,
            type: "DOMAIN-SUFFIX",
            payload: "dashboard.example.invalid",
            proxy: "Automatic",
            disabled: false,
            hitCount: 24
        )
        let second = try makeRule(
            index: 4,
            type: "RULE-SET",
            payload: "Work",
            proxy: "Work",
            disabled: false,
            hitCount: 8
        )
        let fallback = try makeRule(
            index: 120,
            type: "MATCH",
            payload: "",
            proxy: "Fallback",
            disabled: nil,
            hitCount: 0
        )
        let managed = [first, second, fallback].map { value in
            ManagedRule(
                id: RuleID(
                    configurationGeneration: generation,
                    originalIndex: value.index
                ),
                value: value
            )
        }
        return managed.enumerated().map { position, rule in
            let evidence: RuleProvenanceEvidence
            switch position {
            case 0:
                evidence = RuleProvenanceEvidence(
                    sourceLayer: .configuration,
                    sourceDisplayName: "Daily Driver",
                    sourcePointer: "rules[90]",
                    providerDisplayName: nil,
                    providerEntry: nil,
                    providerStatus: nil,
                    confidence: .exact,
                    evidenceGenerationID: generation.id
                )
            case 1:
                evidence = RuleProvenanceEvidence(
                    sourceLayer: .provider,
                    sourceDisplayName: "Daily Driver",
                    sourcePointer: "rule-providers.work",
                    providerDisplayName: "Provider A",
                    providerEntry: "Work",
                    providerStatus: "Healthy",
                    confidence: .exact,
                    evidenceGenerationID: generation.id
                )
            default:
                evidence = .unavailable(generationID: generation.id)
            }
            return RuntimeRuleRowModel(
                rule: rule,
                runtimePosition: position,
                provenance: evidence
            )
        }
    }
}

private actor RulesPresentationAPIFake: MihomoAPIProviding {
    private let response: MihomoRulesResponse
    private var calls = 0

    init(rules: [MihomoRule]) {
        response = MihomoRulesResponse(rules: rules)
    }

    func rules() async throws -> MihomoRulesResponse {
        calls += 1
        return response
    }

    func ruleCallCount() -> Int { calls }

    func version() async throws -> MihomoVersion { throw RulesPresentationTestError.unexpected }
    func configs() async throws -> MihomoConfigs { throw RulesPresentationTestError.unexpected }
    func patchConfigs(_ patch: MihomoConfigPatch) async throws {
        throw RulesPresentationTestError.unexpected
    }
    func proxies() async throws -> MihomoProxiesResponse {
        throw RulesPresentationTestError.unexpected
    }
}

private enum RulesPresentationTestError: Error {
    case unexpected
}

private func makeRule(
    index: Int,
    type: String,
    payload: String,
    proxy: String,
    disabled: Bool?,
    hitCount: UInt64
) throws -> MihomoRule {
    var object: [String: Any] = [
        "index": index,
        "type": type,
        "payload": payload,
        "proxy": proxy,
        "size": 1,
    ]
    if let disabled {
        object["extra"] = [
            "disabled": disabled,
            "hitCount": hitCount,
            "missCount": 0,
        ]
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(MihomoRule.self, from: data)
}
