import Foundation
import Testing
@testable import Vela

@Suite("Connections 10k presentation performance", .serialized)
struct ConnectionsViewModelPerformanceTests {
    @Test("View model presents 10,000 rows with cached options and formatted text")
    @MainActor
    func tenThousandRowsPresentation() async throws {
        let snapshot = try ConnectionsTestFixtures.performanceSnapshot()
        let model = try makeViewModel(readActions: [.snapshot(snapshot)])
        let clock = ContinuousClock()
        let start = clock.now

        await model.refreshSnapshot()
        #expect(await waitForModel(model) {
            $0.appliedSnapshotRevision == 1 && $0.visibleRows.count == 10_000
        })
        let elapsed = start.duration(to: clock.now)

        #expect(model.metrics.connectionCount == 10_000)
        #expect(!model.metrics.uploadText.isEmpty)
        #expect(!model.metrics.downloadText.isEmpty)
        #expect(model.metrics.memoryText != nil)
        #expect(model.availableProtocols == ["HTTP", "HTTPS", "SOCKS5"])
        #expect(model.availableNetworks == ["tcp", "udp"])
        #expect(model.availableProcesses.count == 37)
        #expect(model.availableRules == ["DomainSuffix", "IPCIDR", "Match"])

        let first = try #require(model.visibleRows.first)
        #expect(!first.uploadText.isEmpty)
        #expect(!first.downloadText.isEmpty)
        #expect(first.durationText != "—")
        #expect(first.destination.contains(":"))

        model.selectedConnectionID = first.id
        #expect(model.selectedRow?.id == first.id)
        #expect(model.selectedStartedAtText != nil)
        #expect(elapsed < .seconds(6))
    }

    @Test("Continuous 10,000-row snapshots publish only the newest result")
    @MainActor
    func continuousSnapshotsKeepLatestResult() async throws {
        let snapshots = try (0..<3).map {
            try ConnectionsTestFixtures.performanceSnapshot(revision: $0)
        }
        let model = try makeViewModel(
            readActions: snapshots.map(ConnectionsAPIReadAction.snapshot)
        )
        let clock = ContinuousClock()
        let start = clock.now

        for _ in snapshots {
            await model.refreshSnapshot()
        }

        #expect(await waitForModel(model, timeout: .seconds(10)) {
            $0.appliedSnapshotRevision == 3 && $0.visibleRows.count == 10_000
        })
        let latest = try #require(
            model.visibleRows.first { $0.id == "performance-0" }
        )
        let diagnostics = await model.processingDiagnostics()

        #expect(latest.connection.upload == 2_000_000)
        #expect(latest.host.hasPrefix("revision-2-"))
        #expect(model.metrics.uploadText == ConnectionTextFormatter.shared.bytes(30_000_000))
        #expect(diagnostics.maximumConcurrentWorkerCount == 1)
        #expect(diagnostics.activeWorkerCount == 0)
        #expect(start.duration(to: clock.now) < .seconds(10))
    }

    @Test("Replacement cancels and joins old 10,000-row work before latest sorting")
    func cancellationIsSerialAndLatestWins() async throws {
        let snapshot = try ConnectionsTestFixtures.performanceSnapshot()
        let pipeline = ConnectionsPresentationPipeline()
        let firstRequest = request(
            snapshot: snapshot,
            revision: 1,
            query: "payload",
            sort: .host,
            ascending: true
        )
        let latestRequest = request(
            snapshot: snapshot,
            revision: 2,
            query: "process",
            sort: .download,
            ascending: false
        )

        let first = Task { await pipeline.process(firstRequest) }
        #expect(await waitForPipeline(pipeline) { $0.activeWorkerCount == 1 })
        let latest = Task { await pipeline.process(latestRequest) }

        let firstResult = await first.value
        let latestResult = await latest.value
        let diagnostics = await pipeline.diagnostics()

        #expect(firstResult == nil)
        #expect(latestResult?.snapshotRevision == 2)
        #expect(latestResult?.rows.count == 10_000)
        #expect(latestResult?.rows.first?.connection.download == 9_999)
        #expect(diagnostics.startedWorkerCount == 2)
        #expect(diagnostics.cancelledWorkerCount == 1)
        #expect(diagnostics.completedWorkerCount == 1)
        #expect(diagnostics.activeWorkerCount == 0)
        #expect(diagnostics.maximumConcurrentWorkerCount == 1)
    }

    @Test("10,000-row formatting leaves the MainActor responsive")
    @MainActor
    func processingDoesNotBlockMainActor() async throws {
        let snapshot = try ConnectionsTestFixtures.performanceSnapshot()
        let model = try makeViewModel(readActions: [.snapshot(snapshot)])

        await model.refreshSnapshot()
        #expect(await waitForModelDiagnostics(model) {
            $0.activeWorkerCount == 1
        })

        let clock = ContinuousClock()
        let start = clock.now
        let marker = Task.detached(priority: .userInitiated) {
            await MainActor.run {}
        }
        await marker.value
        let latency = start.duration(to: clock.now)

        #expect(latency < .milliseconds(250))
        #expect(await waitForModel(model, timeout: .seconds(8)) {
            $0.visibleRows.count == 10_000
        })
    }

    @Test("500 search changes leave no presentation workers active")
    func fiveHundredSearchChangesDoNotGrowWorkers() async throws {
        let snapshot = try ConnectionsTestFixtures.snapshot(
            entries: (0..<200).map {
                ConnectionsTestFixtures.Entry(id: "search-resource-\($0)")
            },
            detailed: true
        )
        let pipeline = ConnectionsPresentationPipeline()

        for revision in 1...500 {
            let result = await pipeline.process(
                request(
                    snapshot: snapshot,
                    revision: UInt64(revision),
                    query: revision == 500 ? "search-resource-199" : "resource",
                    sort: .host,
                    ascending: revision.isMultiple(of: 2)
                )
            )
            #expect(result?.snapshotRevision == UInt64(revision))
        }

        let diagnostics = await pipeline.diagnostics()
        #expect(diagnostics.submittedRequestCount == 500)
        #expect(diagnostics.startedWorkerCount == 500)
        #expect(diagnostics.completedWorkerCount == 500)
        #expect(diagnostics.cancelledWorkerCount == 0)
        #expect(diagnostics.activeWorkerCount == 0)
        #expect(diagnostics.maximumConcurrentWorkerCount == 1)
    }

    private func request(
        snapshot: ConnectionsSnapshot,
        revision: UInt64,
        query: String,
        sort: ConnectionSortField,
        ascending: Bool
    ) -> ConnectionsProcessingRequest {
        ConnectionsProcessingRequest(
            snapshotRevision: revision,
            snapshot: snapshot,
            query: query,
            filters: ConnectionFilterSelection(
                protocolName: nil,
                network: nil,
                process: nil,
                rule: nil
            ),
            sort: ConnectionSortSelection(field: sort, ascending: ascending),
            now: Date(timeIntervalSince1970: 1_752_400_000),
            localeIdentifier: "en_US_POSIX"
        )
    }

    @MainActor
    private func makeViewModel(
        readActions: [ConnectionsAPIReadAction]
    ) throws -> ConnectionsViewModel {
        let url = try #require(URL(string: "http://127.0.0.1:9090"))
        let transport = ConnectionsWebSocketTransportStub()
        return ConnectionsViewModel(
            service: ConnectionsService(
                apiClient: ConnectionsAPIStub(readActions: readActions)
            ),
            stream: MihomoConnectionsStream(
                controllerURL: url,
                secret: nil,
                transport: transport,
                reconnectDelay: .zero
            )
        )
    }

    @MainActor
    private func waitForModel(
        _ model: ConnectionsViewModel,
        timeout: Duration = .seconds(8),
        condition: @escaping @MainActor (ConnectionsViewModel) -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition(model) { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition(model)
    }

    @MainActor
    private func waitForModelDiagnostics(
        _ model: ConnectionsViewModel,
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable (ConnectionsProcessingDiagnostics) -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition(await model.processingDiagnostics()) { return true }
            try? await Task.sleep(for: .microseconds(200))
        }
        return condition(await model.processingDiagnostics())
    }

    private func waitForPipeline(
        _ pipeline: ConnectionsPresentationPipeline,
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable (ConnectionsProcessingDiagnostics) -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition(await pipeline.diagnostics()) { return true }
            try? await Task.sleep(for: .microseconds(200))
        }
        return condition(await pipeline.diagnostics())
    }
}
