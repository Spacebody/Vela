import Foundation
import Testing
@testable import Vela

@Suite("Connections service and stream", .serialized)
struct ConnectionsServiceTests {
    @Test("REST snapshot returns the decoded in-memory value")
    func restSnapshot() async throws {
        let expected = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "rest", upload: 42)],
            detailed: true
        )
        let api = ConnectionsAPIStub(readActions: [.snapshot(expected)])
        let service = ConnectionsService(apiClient: api)

        let actual = try await service.snapshot()

        #expect(actual == expected)
        #expect(actual.connections[0].metadata.sourcePort == 54_321)
        #expect(actual.connections[0].metadata.destinationPort == 443)
        #expect(actual.connections[0].start != nil)
        let readCount = await api.readCount()
        #expect(readCount == 1)
    }

    @Test("REST decoding and transport failures map to stable Connections failures")
    func restFailureMapping() async throws {
        let decodingAPI = ConnectionsAPIStub(readActions: [.decodingFailure])
        let decodingService = ConnectionsService(apiClient: decodingAPI)
        await expectFailure(.snapshotDecodeFailed) {
            _ = try await decodingService.snapshot()
        }

        let transportAPI = ConnectionsAPIStub(
            readActions: [.failure(.disconnected)]
        )
        let transportService = ConnectionsService(apiClient: transportAPI)
        await expectFailure(.streamUnavailable) {
            _ = try await transportService.snapshot()
        }
    }

    @Test("WebSocket emits the first and repeated snapshots with request contract")
    func firstAndRepeatedSnapshots() async throws {
        let first = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "first", upload: 1)]
        )
        let second = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "second", upload: 2)]
        )
        let connection = ConnectionsWebSocketConnectionStub()
        let transport = ConnectionsWebSocketTransportStub(actions: [
            .connection(connection)
        ])
        let stream = try makeStream(
            controllerURL: "https://127.0.0.1:9090/api/?discarded=yes#fragment",
            secret: "connections-secret",
            transport: transport
        )
        let generation = ConfigurationGeneration()
        let snapshots = stream.snapshots(generation: generation)
        var iterator = snapshots.makeAsyncIterator()

        #expect(await waitForRequest(transport))
        await connection.enqueue(try ConnectionsTestFixtures.message(first))
        let firstEvent = try #require(try await iterator.next())
        await connection.enqueue(try ConnectionsTestFixtures.message(second))
        let secondEvent = try #require(try await iterator.next())

        #expect(firstEvent.generation == generation)
        #expect(firstEvent.snapshot == first)
        #expect(secondEvent.generation == generation)
        #expect(secondEvent.snapshot == second)

        let requests = await transport.recordedRequests()
        let request = try #require(requests.first)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        )
        #expect(requests.count == 1)
        #expect(components.scheme == "wss")
        #expect(components.path == "/api/connections")
        #expect(components.queryItems == [
            URLQueryItem(name: "interval", value: "1000")
        ])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer connections-secret")

        await stream.stop()
        #expect(await waitForClose(connection))
    }

    @Test("Stream buffering keeps only the newest unread snapshot")
    func newestSnapshotBuffer() async throws {
        let snapshots = try (1...3).map { value in
            try ConnectionsTestFixtures.snapshot(
                entries: [.init(id: "snapshot-\(value)", upload: Int64(value))]
            )
        }
        let connection = ConnectionsWebSocketConnectionStub()
        let transport = ConnectionsWebSocketTransportStub(actions: [
            .connection(connection)
        ])
        let stream = try makeStream(transport: transport)
        let source = stream.snapshots(generation: ConfigurationGeneration())

        #expect(await waitForRequest(transport))
        for snapshot in snapshots {
            await connection.enqueue(try ConnectionsTestFixtures.message(snapshot))
        }
        #expect(await ConnectionsTestFixtures.waitUntil {
            await connection.receiveCount() >= 4
        })

        var iterator = source.makeAsyncIterator()
        let event = try #require(try await iterator.next())
        #expect(event.snapshot == snapshots[2])

        await stream.stop()
        #expect(await waitForClose(connection))
    }

    @Test("A newer generation replaces and closes the sole active WebSocket")
    func generationReplacementMaintainsOneConnection() async throws {
        let firstConnection = ConnectionsWebSocketConnectionStub()
        let secondConnection = ConnectionsWebSocketConnectionStub()
        let transport = ConnectionsWebSocketTransportStub(actions: [
            .connection(firstConnection),
            .connection(secondConnection),
        ])
        let stream = try makeStream(transport: transport)
        let firstGeneration = ConfigurationGeneration()
        let firstSource = stream.snapshots(generation: firstGeneration)
        var firstIterator = firstSource.makeAsyncIterator()
        #expect(await waitForRequest(transport, count: 1))

        let secondGeneration = ConfigurationGeneration()
        let secondSource = stream.snapshots(generation: secondGeneration)
        var secondIterator = secondSource.makeAsyncIterator()
        #expect(await waitForRequest(transport, count: 2))
        #expect(await waitForClose(firstConnection))

        let firstEnded = try await firstIterator.next()
        #expect(firstEnded == nil)

        let current = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "new-generation")]
        )
        await secondConnection.enqueue(try ConnectionsTestFixtures.message(current))
        let event = try #require(try await secondIterator.next())
        #expect(event.generation == secondGeneration)
        #expect(event.snapshot == current)

        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        await stream.stop()
        #expect(await waitForClose(secondConnection))
    }

    @Test("Cancelling the only consumer closes the underlying connection once")
    func consumerCancellationClosesConnection() async throws {
        let connection = ConnectionsWebSocketConnectionStub()
        let transport = ConnectionsWebSocketTransportStub(actions: [
            .connection(connection)
        ])
        let stream = try makeStream(transport: transport)
        let source = stream.snapshots(generation: ConfigurationGeneration())
        let consumer = Task {
            do {
                for try await _ in source {}
            } catch {
                // Cancellation deliberately finishes the public stream.
            }
        }

        #expect(await waitForRequest(transport))
        consumer.cancel()
        await consumer.value

        #expect(await waitForClose(connection))
        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
        let closeCount = await connection.closeCount()
        #expect(closeCount == 1)
    }

    @Test("View model stop-start keeps the replacement stream authoritative")
    @MainActor
    func viewModelStopStartKeepsReplacementStream() async throws {
        let firstConnection = ConnectionsWebSocketConnectionStub()
        let replacementConnection = ConnectionsWebSocketConnectionStub()
        let transport = ConnectionsWebSocketTransportStub(actions: [
            .connection(firstConnection),
            .connection(replacementConnection),
        ])
        let stream = try makeStream(transport: transport)
        let model = ConnectionsViewModel(
            service: ConnectionsService(apiClient: ConnectionsAPIStub()),
            stream: stream
        )

        model.viewDidAppear()
        model.engineRunningChanged(true)
        #expect(await waitForRequest(transport, count: 1))

        model.stop()
        model.start()
        #expect(await waitForRequest(transport, count: 2))
        #expect(await waitForClose(firstConnection))

        for _ in 0..<5 { await Task.yield() }
        #expect(model.isStreaming)

        model.start()
        try await Task.sleep(for: .milliseconds(30))
        let requestCount = await transport.recordedRequests().count
        #expect(requestCount == 2)

        let expected = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "replacement")]
        )
        await replacementConnection.enqueue(
            try ConnectionsTestFixtures.message(expected)
        )
        #expect(await waitForViewModel { model.snapshot == expected })
        #expect(model.isStreaming)

        model.stop()
        #expect(!model.isStreaming)
        #expect(await waitForClose(replacementConnection))
    }

    @Test("Hidden pages never stream across engine starts and visible engine stop closes once")
    @MainActor
    func visibilityAndEngineLifecycleGateStreaming() async throws {
        let firstConnection = ConnectionsWebSocketConnectionStub()
        let secondConnection = ConnectionsWebSocketConnectionStub()
        let transport = ConnectionsWebSocketTransportStub(actions: [
            .connection(firstConnection),
            .connection(secondConnection),
        ])
        let stream = try makeStream(transport: transport)
        let model = ConnectionsViewModel(
            service: ConnectionsService(apiClient: ConnectionsAPIStub()),
            stream: stream
        )

        model.engineRunningChanged(true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.recordedRequests().isEmpty)

        model.viewDidAppear()
        #expect(await waitForRequest(transport, count: 1))
        model.viewDidDisappear()
        #expect(await waitForClose(firstConnection))

        model.engineRunningChanged(false)
        model.engineRunningChanged(true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.recordedRequests().count == 1)

        model.viewDidAppear()
        #expect(await waitForRequest(transport, count: 2))
        let populated = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "visible")]
        )
        await secondConnection.enqueue(try ConnectionsTestFixtures.message(populated))
        #expect(await waitForViewModel { model.snapshot == populated })

        model.engineRunningChanged(false)
        #expect(await waitForClose(secondConnection))
        #expect(!model.isStreaming)
        #expect(model.snapshot == populated)
        #expect(model.presentation.phase == .offlineWithSnapshot)
        #expect(model.presentation.rows.map(\.id) == ["visible"])
        #expect(!model.presentation.actions.canCloseAll)
        #expect(await firstConnection.closeCount() == 1)
        #expect(await secondConnection.closeCount() == 1)
    }

    @Test("Overview and Connections share one stream until the final consumer leaves")
    @MainActor
    func overlappingConsumersShareOneStream() async throws {
        let connection = ConnectionsWebSocketConnectionStub()
        let transport = ConnectionsWebSocketTransportStub(actions: [
            .connection(connection)
        ])
        let stream = try makeStream(transport: transport)
        let model = ConnectionsViewModel(
            service: ConnectionsService(apiClient: ConnectionsAPIStub()),
            stream: stream
        )

        model.overviewDidAppear()
        model.engineRunningChanged(true)
        #expect(await waitForRequest(transport))

        model.viewDidAppear()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.recordedRequests().count == 1)

        model.overviewDidDisappear()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await connection.closeCount() == 0)
        #expect(model.isStreaming)

        model.viewDidDisappear()
        #expect(await waitForClose(connection))
        #expect(!model.isStreaming)
    }

    @Test("A visible view model restarts after the stream reconnect budget is exhausted")
    @MainActor
    func viewModelRestartsAfterReconnectBudget() async throws {
        let recoveredConnection = ConnectionsWebSocketConnectionStub()
        let transport = ConnectionsWebSocketTransportStub(actions: [
            .failure(.disconnected),
            .connection(recoveredConnection),
        ])
        let stream = try makeStream(
            transport: transport,
            maximumReconnectCount: 0
        )
        let model = ConnectionsViewModel(
            service: ConnectionsService(apiClient: ConnectionsAPIStub()),
            stream: stream,
            streamRestartDelay: { _ in .zero }
        )

        model.viewDidAppear()
        model.engineRunningChanged(true)
        #expect(await waitForRequest(transport, count: 2))

        let expected = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "view-model-recovered")]
        )
        await recoveredConnection.enqueue(
            try ConnectionsTestFixtures.message(expected)
        )
        #expect(await waitForViewModel { model.snapshot == expected })
        #expect(model.isStreaming)
        #expect(model.lastError == nil)

        model.stop()
        #expect(await waitForClose(recoveredConnection))
    }

    @Test("100 configuration restarts retain one authoritative stream without socket growth")
    @MainActor
    func rapidConfigurationRestartsKeepNewestStream() async throws {
        let connections = (0...100).map { _ in ConnectionsWebSocketConnectionStub() }
        let transport = ConnectionsWebSocketTransportStub(
            actions: connections.map { .connection($0) }
        )
        let stream = try makeStream(transport: transport)
        let model = ConnectionsViewModel(
            service: ConnectionsService(apiClient: ConnectionsAPIStub()),
            stream: stream
        )

        model.viewDidAppear()
        model.engineRunningChanged(true)
        #expect(await waitForRequest(transport, count: 1))

        for index in 0..<100 {
            model.configurationDidChange(ConfigurationGeneration())
            #expect(await waitForRequest(transport, count: index + 2))
            #expect(await waitForClose(connections[index]))
            #expect(await connections[index].closeCount() == 1)
        }

        for _ in 0..<5 { await Task.yield() }
        #expect(model.isStreaming)

        let expected = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "newest-generation")]
        )
        await connections[100].enqueue(
            try ConnectionsTestFixtures.message(expected)
        )
        #expect(await waitForViewModel { model.snapshot == expected })

        model.start()
        try await Task.sleep(for: .milliseconds(30))
        let requestCount = await transport.recordedRequests().count
        #expect(requestCount == 101)

        model.stop()
        #expect(await waitForClose(connections[100]))
        #expect(await connections[100].closeCount() == 1)
    }

    @Test("A transient disconnect reconnects and resumes snapshot delivery")
    func reconnectRecovers() async throws {
        let expected = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "recovered")]
        )
        let disconnectedConnection = ConnectionsWebSocketConnectionStub(actions: [
            .failure(.disconnected)
        ])
        let recoveredConnection = ConnectionsWebSocketConnectionStub(actions: [
            .message(try ConnectionsTestFixtures.message(expected))
        ])
        let transport = ConnectionsWebSocketTransportStub(actions: [
            .connection(disconnectedConnection),
            .connection(recoveredConnection),
        ])
        let stream = try makeStream(
            transport: transport,
            maximumReconnectCount: 2
        )
        var iterator = stream.snapshots(
            generation: ConfigurationGeneration()
        ).makeAsyncIterator()

        let event = try #require(try await iterator.next())
        #expect(event.snapshot == expected)
        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(await waitForClose(disconnectedConnection))

        await stream.stop()
        #expect(await waitForClose(recoveredConnection))
    }

    @Test("Successful snapshots reset the bounded reconnect budget across repeated outages")
    func recoveredEpisodesResetReconnectBudget() async throws {
        // 101 successful streams create 100 explicit reconnect transitions.
        let snapshots = try (1...101).map { value in
            try ConnectionsTestFixtures.snapshot(
                entries: [.init(id: "episode-\(value)")]
            )
        }
        let connections = try snapshots.map { snapshot in
            ConnectionsWebSocketConnectionStub(actions: [
                .message(try ConnectionsTestFixtures.message(snapshot)),
            ])
        }
        let transport = ConnectionsWebSocketTransportStub(
            actions: connections.map { .connection($0) }
        )
        let stream = try makeStream(
            transport: transport,
            maximumReconnectCount: 1
        )
        var iterator = stream.snapshots(
            generation: ConfigurationGeneration()
        ).makeAsyncIterator()

        for (index, expected) in snapshots.enumerated() {
            let event = try #require(try await iterator.next())
            #expect(event.snapshot == expected)
            if index < snapshots.count - 1 {
                // The production stream intentionally buffers only the newest
                // unread snapshot. Trigger each outage only after its recovered
                // snapshot is observed so this test isolates reconnect-budget
                // reset semantics instead of racing the buffering policy.
                await connections[index].fail()
                #expect(await waitForRequest(transport, count: index + 2))
            }
        }
        #expect(await transport.recordedRequests().count == snapshots.count)

        await stream.stop()
        for connection in connections {
            #expect(await waitForClose(connection))
        }
    }

    @Test("Reconnect attempts are globally bounded for one visible stream")
    func reconnectIsBounded() async throws {
        let transport = ConnectionsWebSocketTransportStub()
        let stream = try makeStream(
            transport: transport,
            maximumReconnectCount: 2
        )
        var iterator = stream.snapshots(
            generation: ConfigurationGeneration()
        ).makeAsyncIterator()

        do {
            _ = try await iterator.next()
            Issue.record("Expected the bounded stream to fail")
        } catch let failure as ConnectionsFailure {
            #expect(failure == .streamUnavailable)
        }

        let requests = await transport.recordedRequests()
        #expect(requests.count == 3)
    }

    @Test("Malformed snapshot fails once without reconnecting")
    func malformedSnapshotDoesNotReconnect() async throws {
        let connection = ConnectionsWebSocketConnectionStub(actions: [
            .message(.data(Data(#"{"#.utf8)))
        ])
        let transport = ConnectionsWebSocketTransportStub(actions: [
            .connection(connection)
        ])
        let stream = try makeStream(
            transport: transport,
            maximumReconnectCount: 3
        )
        var iterator = stream.snapshots(
            generation: ConfigurationGeneration()
        ).makeAsyncIterator()

        do {
            _ = try await iterator.next()
            Issue.record("Expected malformed snapshot failure")
        } catch let failure as ConnectionsFailure {
            #expect(failure == .snapshotDecodeFailed)
        }

        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
        #expect(await waitForClose(connection))
    }

    @Test("The O(n) diff handles a 10,000-row replacement")
    func tenThousandConnectionDiff() throws {
        let snapshots = try ConnectionsTestFixtures.tenThousandSnapshots()
        let clock = ContinuousClock()
        let start = clock.now

        let diff = ConnectionsDiff.between(
            snapshots.previous.connections,
            and: snapshots.current.connections
        )
        let elapsed = start.duration(to: clock.now)

        #expect(diff.added.map(\.id) == ["connection-10000"])
        #expect(diff.updated.map(\.id) == ["connection-5000"])
        #expect(diff.removedIDs == ["connection-0"])
        #expect(elapsed < .seconds(2))
    }

    @Test("Close one sends one DELETE and confirms disappearance by REST")
    func closeOne() async throws {
        let api = ConnectionsAPIStub(readActions: [
            .snapshot(ConnectionsTestFixtures.empty)
        ])
        let service = ConnectionsService(
            apiClient: api,
            confirmationTimeout: .seconds(1),
            pollInterval: .milliseconds(5)
        )

        try await service.closeConnection(id: "close-me")

        let closedIDs = await api.closeOneIDs()
        let readCount = await api.readCount()
        let pendingIDs = await service.pendingCloseIDs()
        #expect(closedIDs == ["close-me"])
        #expect(readCount == 1)
        #expect(pendingIDs.isEmpty)
    }

    @Test("Close all uses the aggregate DELETE and confirms an empty snapshot")
    func closeAll() async throws {
        let api = ConnectionsAPIStub(readActions: [
            .snapshot(ConnectionsTestFixtures.empty)
        ])
        let service = ConnectionsService(
            apiClient: api,
            confirmationTimeout: .seconds(1),
            pollInterval: .milliseconds(5)
        )

        try await service.closeAll()

        let closeAllCount = await api.closeAllCount()
        let closeOneIDs = await api.closeOneIDs()
        let pending = await service.isCloseAllPending()
        #expect(closeAllCount == 1)
        #expect(closeOneIDs.isEmpty)
        #expect(!pending)
    }

    @Test("Close one remains pending until timeout and always clears state")
    func closeOnePendingTimeout() async throws {
        let existing = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "still-open")]
        )
        let api = ConnectionsAPIStub(fallbackSnapshot: existing)
        let service = ConnectionsService(
            apiClient: api,
            confirmationTimeout: .milliseconds(60),
            pollInterval: .milliseconds(5)
        )
        let closeTask = Task {
            try await service.closeConnection(id: "still-open")
        }

        #expect(await ConnectionsTestFixtures.waitUntil {
            await service.pendingCloseIDs().contains("still-open")
        })
        do {
            try await closeTask.value
            Issue.record("Expected close confirmation timeout")
        } catch let failure as ConnectionsFailure {
            #expect(failure == .closeConfirmationTimedOut)
        }

        let pendingIDs = await service.pendingCloseIDs()
        let closedIDs = await api.closeOneIDs()
        #expect(pendingIDs.isEmpty)
        #expect(closedIDs == ["still-open"])
    }

    @Test("Close all exposes pending state and clears it after timeout")
    func closeAllPendingTimeout() async throws {
        let existing = try ConnectionsTestFixtures.snapshot(
            entries: [.init(id: "remaining")]
        )
        let api = ConnectionsAPIStub(fallbackSnapshot: existing)
        let service = ConnectionsService(
            apiClient: api,
            confirmationTimeout: .milliseconds(60),
            pollInterval: .milliseconds(5)
        )
        let closeTask = Task {
            try await service.closeAll()
        }

        #expect(await ConnectionsTestFixtures.waitUntil {
            await service.isCloseAllPending()
        })
        do {
            try await closeTask.value
            Issue.record("Expected close-all confirmation timeout")
        } catch let failure as ConnectionsFailure {
            #expect(failure == .closeConfirmationTimedOut)
        }

        let pending = await service.isCloseAllPending()
        let closeAllCount = await api.closeAllCount()
        #expect(!pending)
        #expect(closeAllCount == 1)
    }

    @Test("Mutation failures map correctly and clear pending state")
    func mutationFailures() async throws {
        let api = ConnectionsAPIStub(
            closeOneFails: true,
            closeAllFails: true
        )
        let service = ConnectionsService(apiClient: api)

        await expectFailure(.closeFailed) {
            try await service.closeConnection(id: "failure")
        }
        await expectFailure(.closeAllFailed) {
            try await service.closeAll()
        }

        let pendingIDs = await service.pendingCloseIDs()
        let closeAllPending = await service.isCloseAllPending()
        #expect(pendingIDs.isEmpty)
        #expect(!closeAllPending)
    }

    private func makeStream(
        controllerURL: String = "http://127.0.0.1:9090",
        secret: String? = nil,
        transport: any TelemetryWebSocketTransporting,
        maximumReconnectCount: Int = 3
    ) throws -> MihomoConnectionsStream {
        let url = try #require(URL(string: controllerURL))
        return MihomoConnectionsStream(
            controllerURL: url,
            secret: secret,
            transport: transport,
            intervalMilliseconds: 1_000,
            maximumReconnectCount: maximumReconnectCount,
            reconnectDelay: .zero
        )
    }

    private func waitForRequest(
        _ transport: ConnectionsWebSocketTransportStub,
        count: Int = 1
    ) async -> Bool {
        await ConnectionsTestFixtures.waitUntil {
            await transport.recordedRequests().count >= count
        }
    }

    private func waitForClose(
        _ connection: ConnectionsWebSocketConnectionStub
    ) async -> Bool {
        await ConnectionsTestFixtures.waitUntil {
            await connection.closeCount() == 1
        }
    }

    @MainActor
    private func waitForViewModel(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func expectFailure(
        _ expected: ConnectionsFailure,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected \(expected)")
        } catch let failure as ConnectionsFailure {
            #expect(failure == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
