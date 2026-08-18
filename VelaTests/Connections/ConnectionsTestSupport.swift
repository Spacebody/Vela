import Foundation
@testable import Vela

nonisolated enum ConnectionsTestError: Error, Equatable, Sendable {
    case disconnected
    case mutationFailed
    case unsupported
}

nonisolated enum ConnectionsWebSocketAction: Sendable {
    case message(TelemetryWebSocketMessage)
    case failure(ConnectionsTestError)
}

nonisolated enum ConnectionsWebSocketConnectAction: Sendable {
    case connection(any TelemetryWebSocketConnection)
    case failure(ConnectionsTestError)
}

nonisolated enum ConnectionsAPIReadAction: Sendable {
    case snapshot(ConnectionsSnapshot)
    case decodingFailure
    case failure(ConnectionsTestError)
}

final class ConnectionsWebSocketConnectionStub: TelemetryWebSocketConnection, Sendable {
    private let state: State

    init(actions: [ConnectionsWebSocketAction] = []) {
        state = State(actions: actions)
    }

    func receive() async throws -> TelemetryWebSocketMessage {
        try await state.receive()
    }

    func close() async {
        await state.close()
    }

    func enqueue(_ message: TelemetryWebSocketMessage) async {
        await state.enqueue(.message(message))
    }

    func fail(_ error: ConnectionsTestError = .disconnected) async {
        await state.enqueue(.failure(error))
    }

    func closeCount() async -> Int {
        await state.closeCount()
    }

    func receiveCount() async -> Int {
        await state.receiveCount()
    }

    private actor State {
        private var actions: [ConnectionsWebSocketAction]
        private var waiter: CheckedContinuation<TelemetryWebSocketMessage, any Error>?
        private var isClosed = false
        private var closeInvocations = 0
        private var receiveInvocations = 0

        init(actions: [ConnectionsWebSocketAction]) {
            self.actions = actions
        }

        func receive() async throws -> TelemetryWebSocketMessage {
            receiveInvocations += 1
            guard !isClosed else { throw CancellationError() }

            if !actions.isEmpty {
                return try Self.resolve(actions.removeFirst())
            }

            return try await withCheckedThrowingContinuation { continuation in
                precondition(waiter == nil, "Only one receive may be pending per connection")
                waiter = continuation
            }
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            closeInvocations += 1
            let pending = waiter
            waiter = nil
            pending?.resume(throwing: CancellationError())
        }

        func enqueue(_ action: ConnectionsWebSocketAction) {
            guard !isClosed else { return }
            guard let pending = waiter else {
                actions.append(action)
                return
            }

            waiter = nil
            switch action {
            case let .message(message):
                pending.resume(returning: message)
            case let .failure(error):
                pending.resume(throwing: error)
            }
        }

        func closeCount() -> Int {
            closeInvocations
        }

        func receiveCount() -> Int {
            receiveInvocations
        }

        private nonisolated static func resolve(
            _ action: ConnectionsWebSocketAction
        ) throws -> TelemetryWebSocketMessage {
            switch action {
            case let .message(message):
                message
            case let .failure(error):
                throw error
            }
        }
    }
}

final class ConnectionsWebSocketTransportStub: TelemetryWebSocketTransporting, Sendable {
    private let state: State

    init(actions: [ConnectionsWebSocketConnectAction] = []) {
        state = State(actions: actions)
    }

    func connect(
        request: URLRequest
    ) async throws -> any TelemetryWebSocketConnection {
        try await state.connect(request: request)
    }

    func recordedRequests() async -> [URLRequest] {
        await state.recordedRequests()
    }

    private actor State {
        private var actions: [ConnectionsWebSocketConnectAction]
        private var requests: [URLRequest] = []

        init(actions: [ConnectionsWebSocketConnectAction]) {
            self.actions = actions
        }

        func connect(
            request: URLRequest
        ) throws -> any TelemetryWebSocketConnection {
            requests.append(request)
            guard !actions.isEmpty else {
                throw ConnectionsTestError.disconnected
            }

            switch actions.removeFirst() {
            case let .connection(connection):
                return connection
            case let .failure(error):
                throw error
            }
        }

        func recordedRequests() -> [URLRequest] {
            requests
        }
    }
}

final class ConnectionsAPIStub: MihomoAPIProviding, Sendable {
    private let state: State

    init(
        readActions: [ConnectionsAPIReadAction] = [],
        fallbackSnapshot: ConnectionsSnapshot = ConnectionsSnapshot(
            downloadTotal: 0,
            uploadTotal: 0,
            connections: [],
            memory: nil
        ),
        closeOneFails: Bool = false,
        closeAllFails: Bool = false
    ) {
        state = State(
            readActions: readActions,
            fallbackSnapshot: fallbackSnapshot,
            closeOneFails: closeOneFails,
            closeAllFails: closeAllFails
        )
    }

    func connections() async throws -> ConnectionsSnapshot {
        try await state.connections()
    }

    func closeConnection(id: String) async throws {
        try await state.closeConnection(id: id)
    }

    func closeAllConnections() async throws {
        try await state.closeAllConnections()
    }

    func readCount() async -> Int {
        await state.readCount()
    }

    func closeOneIDs() async -> [String] {
        await state.closeOneIDs()
    }

    func closeAllCount() async -> Int {
        await state.closeAllCount()
    }

    func version() async throws -> MihomoVersion {
        throw ConnectionsTestError.unsupported
    }

    func configs() async throws -> MihomoConfigs {
        throw ConnectionsTestError.unsupported
    }

    func patchConfigs(_ patch: MihomoConfigPatch) async throws {
        throw ConnectionsTestError.unsupported
    }

    func proxies() async throws -> MihomoProxiesResponse {
        throw ConnectionsTestError.unsupported
    }

    private actor State {
        private var readActions: [ConnectionsAPIReadAction]
        private let fallbackSnapshot: ConnectionsSnapshot
        private let closeOneFails: Bool
        private let closeAllFails: Bool
        private var readInvocations = 0
        private var closedConnectionIDs: [String] = []
        private var closeAllInvocations = 0

        init(
            readActions: [ConnectionsAPIReadAction],
            fallbackSnapshot: ConnectionsSnapshot,
            closeOneFails: Bool,
            closeAllFails: Bool
        ) {
            self.readActions = readActions
            self.fallbackSnapshot = fallbackSnapshot
            self.closeOneFails = closeOneFails
            self.closeAllFails = closeAllFails
        }

        func connections() throws -> ConnectionsSnapshot {
            readInvocations += 1
            guard !readActions.isEmpty else { return fallbackSnapshot }

            switch readActions.removeFirst() {
            case let .snapshot(snapshot):
                return snapshot
            case .decodingFailure:
                throw MihomoAPIError.decodingFailed(
                    endpoint: "/connections",
                    message: "fixture decode failed"
                )
            case let .failure(error):
                throw error
            }
        }

        func closeConnection(id: String) throws {
            closedConnectionIDs.append(id)
            if closeOneFails { throw ConnectionsTestError.mutationFailed }
        }

        func closeAllConnections() throws {
            closeAllInvocations += 1
            if closeAllFails { throw ConnectionsTestError.mutationFailed }
        }

        func readCount() -> Int {
            readInvocations
        }

        func closeOneIDs() -> [String] {
            closedConnectionIDs
        }

        func closeAllCount() -> Int {
            closeAllInvocations
        }
    }
}

nonisolated enum ConnectionsTestFixtures {
    struct Entry: Sendable {
        let id: String
        let upload: Int64

        init(id: String, upload: Int64 = 0) {
            self.id = id
            self.upload = upload
        }
    }

    static let empty = ConnectionsSnapshot(
        downloadTotal: 0,
        uploadTotal: 0,
        connections: [],
        memory: nil
    )

    static func snapshot(
        entries: [Entry],
        detailed: Bool = false
    ) throws -> ConnectionsSnapshot {
        let connections: [[String: Any]] = entries.map { entry in
            var value: [String: Any] = [
                "id": entry.id,
                "upload": entry.upload,
                "download": entry.upload,
                "chains": ["DIRECT"],
                "providerChains": [],
                "rule": "Match",
                "rulePayload": "",
            ]
            if detailed {
                value["metadata"] = [
                    "sourceIP": "127.0.0.1",
                    "destinationIP": "203.0.113.10",
                    "sourcePort": "54321",
                    "destinationPort": 443,
                ]
                value["start"] = "2026-07-11T03:00:00.123456Z"
            }
            return value
        }
        let root: [String: Any] = [
            "downloadTotal": 987_654,
            "uploadTotal": 123_456,
            "memory": 67_108_864,
            "connections": connections,
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        return try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
    }

    static func message(_ snapshot: ConnectionsSnapshot) throws -> TelemetryWebSocketMessage {
        let connections: [[String: Any]] = snapshot.connections.map { connection in
            [
                "id": connection.id,
                "upload": connection.upload,
                "download": connection.download,
                "chains": connection.chains,
                "providerChains": connection.providerChains,
                "rule": connection.rule,
                "rulePayload": connection.rulePayload,
            ]
        }
        var root: [String: Any] = [
            "downloadTotal": snapshot.downloadTotal,
            "uploadTotal": snapshot.uploadTotal,
            "connections": connections,
        ]
        if let memory = snapshot.memory {
            root["memory"] = memory
        }
        return .data(try JSONSerialization.data(withJSONObject: root))
    }

    static func tenThousandSnapshots() throws -> (
        previous: ConnectionsSnapshot,
        current: ConnectionsSnapshot
    ) {
        let previousEntries = (0..<10_000).map {
            Entry(id: "connection-\($0)", upload: Int64($0))
        }
        var currentEntries = (1..<10_000).map {
            Entry(
                id: "connection-\($0)",
                upload: $0 == 5_000 ? 999_999 : Int64($0)
            )
        }
        currentEntries.append(Entry(id: "connection-10000", upload: 10_000))
        return (
            previous: try snapshot(entries: previousEntries),
            current: try snapshot(entries: currentEntries)
        )
    }

    static func performanceSnapshot(
        count: Int = 10_000,
        revision: Int = 0
    ) throws -> ConnectionsSnapshot {
        let protocolNames = ["HTTP", "HTTPS", "SOCKS5"]
        let networks = ["tcp", "udp"]
        let rules = ["DomainSuffix", "IPCIDR", "Match"]
        let connections: [[String: Any]] = (0..<count).map { index in
            [
                "id": "performance-\(index)",
                "metadata": [
                    "type": protocolNames[index % protocolNames.count],
                    "network": networks[index % networks.count],
                    "sourceIP": "127.0.0.1",
                    "destinationIP": "203.0.113.\((index % 250) + 1)",
                    "sourcePort": String(10_000 + index % 50_000),
                    "destinationPort": index.isMultiple(of: 2) ? 443 : 80,
                    "host": "revision-\(revision)-host-\(index).example.com",
                    "process": "Process-\(index % 37)",
                    "processPath": "/Applications/Process-\(index % 37).app",
                ],
                "upload": Int64(revision) * 1_000_000 + Int64(index),
                "download": Int64(revision) * 2_000_000 + Int64(index),
                "start": "2026-07-11T03:\(String(format: "%02d", index % 60)):00.123Z",
                "chains": ["Proxy-\(index % 11)", "DIRECT"],
                "providerChains": ["Provider-\(index % 5)"],
                "rule": rules[index % rules.count],
                "rulePayload": "payload-\(index % 101)",
            ]
        }
        let root: [String: Any] = [
            "downloadTotal": Int64(revision + 1) * 20_000_000,
            "uploadTotal": Int64(revision + 1) * 10_000_000,
            "memory": 134_217_728,
            "connections": connections,
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        return try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
    }

    static func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}
