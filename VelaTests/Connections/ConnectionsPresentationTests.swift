import Foundation
import Testing
@testable import Vela

@Suite("Connections presentation and responsive layout", .serialized)
struct ConnectionsPresentationTests {
    private let configurationID = UUID(
        uuidString: "75D9B98B-1E13-4689-866B-53AF23BFD321"
    )!
    private let referenceDate = Date(timeIntervalSince1970: 1_752_400_000)

    @Test("No-snapshot phases clear rows, selection, and Inspector")
    func noSnapshotPhasesClearLastGoodData() async throws {
        let rows = try await makeRows(ids: ["alpha", "beta"])

        for phase in [
            ConnectionsWorkspacePhase.loading,
            .failure,
            .offlineWithoutSnapshot,
        ] {
            let snapshot = makePresentation(
                phase: phase,
                rows: rows,
                selectedID: "alpha"
            )
            #expect(snapshot.rows.isEmpty, "Unexpected rows in \(phase)")
            #expect(snapshot.selectedConnectionID == nil)
            #expect(snapshot.inspector == nil)
            #expect(!snapshot.actions.canCloseSelected)
            #expect(!snapshot.actions.canCloseAll)
        }
    }

    @Test("Last-good phases preserve stable rows and same-generation selection")
    func lastGoodPhasesPreserveRows() async throws {
        let rows = try await makeRows(ids: ["alpha", "beta"])

        for phase in [
            ConnectionsWorkspacePhase.refreshing,
            .stale,
            .partialFailure,
            .offlineWithSnapshot,
        ] {
            let snapshot = makePresentation(
                phase: phase,
                rows: rows,
                selectedID: "beta"
            )
            #expect(snapshot.rows.map(\.id) == ["alpha", "beta"])
            #expect(snapshot.selectedConnectionID == "beta")
            #expect(snapshot.inspector?.id == "beta")
        }
    }

    @Test("Disappearing, filtered, or old-generation selection never falls back")
    func destructiveSelectionIsFailClosed() async throws {
        let rows = try await makeRows(ids: ["alpha", "beta"])

        #expect(
            ConnectionsSelectionPolicy.resolve(
                requestedID: "missing",
                selectionConfigurationID: configurationID,
                currentConfigurationID: configurationID,
                rows: rows
            ) == nil
        )
        #expect(
            ConnectionsSelectionPolicy.resolve(
                requestedID: "alpha",
                selectionConfigurationID: UUID(),
                currentConfigurationID: configurationID,
                rows: rows
            ) == nil
        )
        let filtered = makePresentation(
            phase: .loaded,
            rows: [rows[1]],
            selectedID: "alpha"
        )
        #expect(filtered.selectedConnectionID == nil)
        #expect(filtered.inspector == nil)
        #expect(!filtered.actions.canCloseSelected)
    }

    @Test("Pending close retains its named row and disables destructive actions")
    func pendingCloseDoesNotOptimisticallyDelete() async throws {
        let rows = try await makeRows(ids: ["alpha", "beta"])
        for phase in ConnectionMutationPhase.allCases {
            let mutation = PendingConnectionMutation(
                targetConnectionID: "alpha",
                configurationID: configurationID,
                phase: phase,
                startedAt: referenceDate
            )
            let snapshot = makePresentation(
                phase: .pendingMutation,
                rows: rows,
                selectedID: "alpha",
                pendingMutation: mutation
            )
            #expect(snapshot.rows.map(\.id) == ["alpha", "beta"])
            #expect(snapshot.inspector?.pendingMutation == mutation)
            #expect(!snapshot.actions.canCloseSelected)
            #expect(!snapshot.actions.canCloseAll)
        }
    }

    @Test("Mutation availability follows verified workspace state")
    func actionAvailability() async throws {
        let rows = try await makeRows(ids: ["alpha"])
        for phase in [
            ConnectionsWorkspacePhase.loaded,
            .stale,
            .partialFailure,
        ] {
            let snapshot = makePresentation(
                phase: phase,
                rows: rows,
                selectedID: "alpha"
            )
            #expect(snapshot.actions.canCloseSelected)
            #expect(snapshot.actions.canCloseAll)
        }
        for phase in [
            ConnectionsWorkspacePhase.loading,
            .refreshing,
            .failure,
            .pendingMutation,
            .offlineWithSnapshot,
            .offlineWithoutSnapshot,
        ] {
            let snapshot = makePresentation(
                phase: phase,
                rows: rows,
                selectedID: "alpha"
            )
            #expect(!snapshot.actions.canCloseSelected)
            #expect(!snapshot.actions.canCloseAll)
        }
    }

    @Test("Stale generations label route evidence without claiming exact confidence")
    func staleRouteEvidence() async throws {
        let rows = try await makeRows(ids: ["alpha"])
        let stale = makePresentation(
            phase: .stale,
            rows: rows,
            selectedID: "alpha"
        )
        let loaded = makePresentation(
            phase: .loaded,
            rows: rows,
            selectedID: "alpha"
        )

        #expect(stale.inspector?.evidenceConfidence == .staleGeneration)
        #expect(loaded.inspector?.evidenceConfidence == .unavailable)
        #expect(stale.snapshotAge == 120)
    }

    @Test("Responsive columns and bounded Inspector widths are deterministic")
    func responsiveLayoutMetrics() {
        let compact = ConnectionsLayoutMetrics.resolve(
            detailWidth: 700,
            tableAvailableWidth: 619
        )
        let regular = ConnectionsLayoutMetrics.resolve(
            detailWidth: 990,
            tableAvailableWidth: 620
        )
        let spacious = ConnectionsLayoutMetrics.resolve(
            detailWidth: 1_600,
            tableAvailableWidth: 900
        )

        #expect(compact.columnSet == .compact)
        #expect(regular.columnSet == .regular)
        #expect(spacious.columnSet == .spacious)
        #expect(compact.inspectorIdealWidth == 300)
        #expect(regular.inspectorIdealWidth > 300)
        #expect(spacious.inspectorIdealWidth == 380)
        #expect(ConnectionsLayoutMetrics.targetRowHeight == VelaMetrics.tableRowHeight)
        #expect(ConnectionsLayoutMetrics.tableCellContentHeight == 26)
    }

    @Test("Empty metadata strings fall back to process path and destination IP")
    func emptyMetadataUsesUsefulFallbacks() async throws {
        let root: [String: Any] = [
            "downloadTotal": 0,
            "uploadTotal": 0,
            "connections": [[
                "id": "empty-metadata",
                "metadata": [
                    "sniffHost": "",
                    "host": "   ",
                    "destinationIP": "203.0.113.42",
                    "destinationPort": 443,
                    "process": "",
                    "processPath": "/Applications/OpenAI.app/Contents/MacOS/OpenAI",
                ],
                "upload": 0,
                "download": 0,
                "chains": ["DIRECT"],
                "providerChains": [],
                "rule": "Match",
                "rulePayload": "",
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        let snapshot = try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
        let result = try #require(
            await ConnectionsPresentationPipeline().process(
                ConnectionsProcessingRequest(
                    snapshotRevision: 1,
                    snapshot: snapshot,
                    query: "",
                    filters: ConnectionFilterSelection(
                        protocolName: nil,
                        network: nil,
                        process: nil,
                        rule: nil
                    ),
                    sort: ConnectionSortSelection(field: .host, ascending: true),
                    now: referenceDate,
                    localeIdentifier: "en_US_POSIX"
                )
            )
        )
        let row = try #require(result.rows.first)

        #expect(row.application == "OpenAI")
        #expect(row.process == "OpenAI")
        #expect(row.host == "203.0.113.42")
        #expect(row.destinationIP == "203.0.113.42")
        #expect(row.destination == "203.0.113.42:443")
    }

    @Test("Protocol filter uses its content width instead of filling the toolbar")
    func protocolFilterWidthIsContentBounded() {
        #expect(ConnectionsFilterLayoutMetrics.protocolPickerWidth(protocols: []) == 64)
        #expect(
            ConnectionsFilterLayoutMetrics.protocolPickerWidth(protocols: ["tcp"])
                == 128
        )
        #expect(
            ConnectionsFilterLayoutMetrics.protocolPickerWidth(
                protocols: ["tcp", "udp", "very-long-protocol-name"]
            ) == 390
        )
        #expect(
            ConnectionsFilterLayoutMetrics.protocolPickerWidth(
                protocols: ["dns", "http", "https", "quic", "tls"]
            ) == 388
        )
        #expect(
            !ConnectionsFilterLayoutMetrics.usesOverflowMenu(
                protocols: ["dns", "http", "https", "quic", "tls"]
            )
        )
        #expect(
            ConnectionsFilterLayoutMetrics.usesOverflowMenu(
                protocols: ["dns", "http", "https", "quic", "tls", "tcp"]
            )
        )
        #expect(
            ConnectionsFilterLayoutMetrics.usesOverflowMenu(
                protocols: ["dns", "http", "https", "quic", "tls"],
                maximumWidth: 300
            )
        )
    }

    @Test("View model clears selection when a local filter hides the target")
    @MainActor
    func filterHiddenSelectionClearsInspector() async throws {
        let snapshot = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "alpha"), .init(id: "beta")],
            detailed: true
        )
        let model = try makeViewModel(snapshot: snapshot)
        await model.refreshSnapshot()
        #expect(await waitForModel(model) { $0.visibleRows.count == 2 })
        model.selectedConnectionID = "alpha"
        #expect(model.presentation.inspector?.id == "alpha")

        model.searchText = "never-matches-this-connection"
        #expect(await waitForModel(model) { $0.visibleRows.isEmpty })
        #expect(model.selectedConnectionID == nil)
        #expect(model.presentation.inspector == nil)
    }

    @Test("Configuration generation change clears last-good data and selection")
    @MainActor
    func generationChangeClearsPresentation() async throws {
        let snapshot = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "alpha")],
            detailed: true
        )
        let model = try makeViewModel(snapshot: snapshot)
        await model.refreshSnapshot()
        #expect(await waitForModel(model) { $0.visibleRows.count == 1 })
        model.selectedConnectionID = "alpha"

        model.configurationDidChange(ConfigurationGeneration())

        #expect(model.snapshot.connections.isEmpty)
        #expect(model.visibleRows.isEmpty)
        #expect(model.selectedConnectionID == nil)
        #expect(model.presentation.inspector == nil)
    }

    private func makePresentation(
        phase: ConnectionsWorkspacePhase,
        rows: [ConnectionRowModel],
        selectedID: String?,
        pendingMutation: PendingConnectionMutation? = nil
    ) -> ConnectionsPresentationSnapshot {
        ConnectionsPresentationFactory.make(
            configurationID: configurationID,
            snapshotRevision: 7,
            phase: phase,
            rows: rows,
            selectedConnectionID: selectedID,
            selectionConfigurationID: selectedID == nil ? nil : configurationID,
            metrics: ConnectionMetricsPresentation(
                connectionCount: rows.count,
                uploadText: "1 MB",
                downloadText: "2 MB",
                memoryText: "64 MB"
            ),
            availableProtocols: ["HTTPS", "TCP"],
            lastSuccessfulRefreshAt: referenceDate.addingTimeInterval(-120),
            referenceDate: referenceDate,
            pendingMutation: pendingMutation,
            lastError: nil,
            isPaused: false
        )
    }

    private func makeRows(ids: [String]) async throws -> [ConnectionRowModel] {
        let snapshot = try ConnectionsTestFixtures.snapshot(
            entries: ids.map { ConnectionsTestFixtures.Entry(id: $0) },
            detailed: true
        )
        let pipeline = ConnectionsPresentationPipeline()
        return try #require(
            await pipeline.process(
                ConnectionsProcessingRequest(
                    snapshotRevision: 1,
                    snapshot: snapshot,
                    query: "",
                    filters: ConnectionFilterSelection(
                        protocolName: nil,
                        network: nil,
                        process: nil,
                        rule: nil
                    ),
                    sort: ConnectionSortSelection(field: .host, ascending: true),
                    now: referenceDate,
                    localeIdentifier: "en_US_POSIX"
                )
            )
        ).rows
    }

    @MainActor
    private func makeViewModel(snapshot: ConnectionsSnapshot) throws -> ConnectionsViewModel {
        let url = try #require(URL(string: "http://127.0.0.1:9090"))
        return ConnectionsViewModel(
            service: ConnectionsService(
                apiClient: ConnectionsAPIStub(readActions: [.snapshot(snapshot)])
            ),
            stream: MihomoConnectionsStream(
                controllerURL: url,
                secret: nil,
                transport: ConnectionsWebSocketTransportStub(),
                reconnectDelay: .zero
            ),
            now: { Date(timeIntervalSince1970: 1_752_400_000) },
            localeIdentifier: { "en_US_POSIX" }
        )
    }

    @MainActor
    private func waitForModel(
        _ model: ConnectionsViewModel,
        condition: @escaping @MainActor (ConnectionsViewModel) -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if condition(model) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition(model)
    }
}
