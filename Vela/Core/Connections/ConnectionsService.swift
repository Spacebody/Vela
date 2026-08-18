import Foundation
import Synchronization

nonisolated enum ConnectionsFailure: Error, Equatable, Sendable {
    case invalidControllerURL
    case streamUnavailable
    case snapshotDecodeFailed
    case closeFailed
    case closeAllFailed
    case closeConfirmationTimedOut
}

nonisolated struct ConnectionsStreamEvent: Equatable, Sendable {
    let generation: ConfigurationGeneration
    let snapshot: ConnectionsSnapshot
}

nonisolated struct ConnectionsDiff: Equatable, Sendable {
    let added: [MihomoConnection]
    let updated: [MihomoConnection]
    let removedIDs: Set<String>

    static func between(
        _ previous: [MihomoConnection],
        and current: [MihomoConnection]
    ) -> ConnectionsDiff {
        var previousByID: [String: MihomoConnection] = [:]
        previousByID.reserveCapacity(previous.count)
        for connection in previous {
            previousByID[connection.id] = connection
        }

        var currentIDs = Set<String>()
        currentIDs.reserveCapacity(current.count)
        var added: [MihomoConnection] = []
        var updated: [MihomoConnection] = []
        added.reserveCapacity(max(0, current.count - previous.count))
        for connection in current {
            guard currentIDs.insert(connection.id).inserted else { continue }
            guard let old = previousByID[connection.id] else {
                added.append(connection)
                continue
            }
            if old != connection {
                updated.append(connection)
            }
        }
        return ConnectionsDiff(
            added: added,
            updated: updated,
            removedIDs: Set(previousByID.keys).subtracting(currentIDs)
        )
    }
}

nonisolated protocol MihomoConnectionsStreaming: Sendable {
    func snapshots(
        generation: ConfigurationGeneration
    ) -> AsyncThrowingStream<ConnectionsStreamEvent, Error>
    func stop() async
}

nonisolated struct MihomoConnectionsStream: MihomoConnectionsStreaming, Sendable {
    private let controllerURL: URL
    private let secret: String?
    private let intervalMilliseconds: Int
    private let registration: ConnectionsStreamRegistration

    init(
        controllerURL: URL,
        secret: String?,
        transport: any TelemetryWebSocketTransporting = URLSessionWebSocketTransport(),
        intervalMilliseconds: Int = 1_000,
        maximumReconnectCount: Int = 3,
        reconnectDelay: Duration = .milliseconds(250)
    ) {
        self.controllerURL = controllerURL
        self.secret = secret
        self.intervalMilliseconds = max(250, intervalMilliseconds)
        registration = ConnectionsStreamRegistration(
            transport: transport,
            maximumReconnectCount: maximumReconnectCount,
            reconnectDelay: reconnectDelay
        )
    }

    func snapshots(
        generation: ConfigurationGeneration
    ) -> AsyncThrowingStream<ConnectionsStreamEvent, Error> {
        let request: URLRequest
        do {
            request = try makeRequest()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let sequence = registration.reserveSequence()
        let coordinator = registration.coordinator
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let startTask = Task {
                await coordinator.start(
                    sequence: sequence,
                    request: request,
                    generation: generation,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in
                startTask.cancel()
                Task { await coordinator.stop(sequence: sequence) }
            }
        }
    }

    func stop() async {
        let barrierSequence = registration.reserveSequence()
        await registration.coordinator.stopAll(
            invalidatingThrough: barrierSequence
        )
    }

    private func makeRequest() throws -> URLRequest {
        guard var components = URLComponents(url: controllerURL, resolvingAgainstBaseURL: false) else {
            throw ConnectionsFailure.invalidControllerURL
        }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: throw ConnectionsFailure.invalidControllerURL
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + "/connections"
        components.queryItems = [
            URLQueryItem(name: "interval", value: String(intervalMilliseconds)),
        ]
        components.fragment = nil
        guard let url = components.url else { throw ConnectionsFailure.invalidControllerURL }
        var request = URLRequest(url: url)
        if let secret, !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

nonisolated private final class ConnectionsStreamRegistration: Sendable {
    let coordinator: ConnectionsStreamCoordinator
    private let sequence = Mutex<UInt64>(0)

    init(
        transport: any TelemetryWebSocketTransporting,
        maximumReconnectCount: Int,
        reconnectDelay: Duration
    ) {
        coordinator = ConnectionsStreamCoordinator(
            transport: transport,
            maximumReconnectCount: maximumReconnectCount,
            reconnectDelay: reconnectDelay
        )
    }

    func reserveSequence() -> UInt64 {
        sequence.withLock { value in
            value &+= 1
            return value
        }
    }
}

private actor ConnectionsStreamCoordinator {
    private struct ActiveSession {
        let sequence: UInt64
        let continuation: AsyncThrowingStream<ConnectionsStreamEvent, Error>.Continuation
        let lifecycle: ConnectionsStreamLifecycle
        let worker: Task<Void, Never>
    }

    private let transport: any TelemetryWebSocketTransporting
    private let maximumReconnectCount: Int
    private let reconnectDelay: Duration
    private var latestSequence: UInt64 = 0
    private var activeSession: ActiveSession?

    init(
        transport: any TelemetryWebSocketTransporting,
        maximumReconnectCount: Int,
        reconnectDelay: Duration
    ) {
        self.transport = transport
        self.maximumReconnectCount = max(0, maximumReconnectCount)
        self.reconnectDelay = max(.zero, reconnectDelay)
    }

    func start(
        sequence: UInt64,
        request: URLRequest,
        generation: ConfigurationGeneration,
        continuation: AsyncThrowingStream<ConnectionsStreamEvent, Error>.Continuation
    ) async {
        guard sequence > latestSequence, !Task.isCancelled else {
            continuation.finish()
            return
        }

        latestSequence = sequence
        await stopActiveSession()
        guard sequence == latestSequence, !Task.isCancelled else {
            continuation.finish()
            return
        }

        let lifecycle = ConnectionsStreamLifecycle()
        let transport = self.transport
        let maximumReconnectCount = self.maximumReconnectCount
        let reconnectDelay = self.reconnectDelay
        let worker = Task.detached(priority: .userInitiated) {
            await ConnectionsStreamWorker.run(
                request: request,
                generation: generation,
                continuation: continuation,
                lifecycle: lifecycle,
                transport: transport,
                maximumReconnectCount: maximumReconnectCount,
                reconnectDelay: reconnectDelay
            )
        }
        activeSession = ActiveSession(
            sequence: sequence,
            continuation: continuation,
            lifecycle: lifecycle,
            worker: worker
        )

        Task {
            await worker.value
            self.removeCompletedSession(sequence: sequence)
        }
    }

    func stop(sequence: UInt64) async {
        guard activeSession?.sequence == sequence else { return }
        await stopActiveSession()
    }

    func stopAll(invalidatingThrough sequence: UInt64) async {
        latestSequence = max(latestSequence, sequence)
        guard (activeSession?.sequence ?? 0) <= sequence else { return }
        await stopActiveSession()
    }

    private func stopActiveSession() async {
        guard let session = activeSession else { return }
        activeSession = nil
        session.worker.cancel()
        await session.lifecycle.close()
        session.continuation.finish()
        await session.worker.value
    }

    private func removeCompletedSession(sequence: UInt64) {
        guard activeSession?.sequence == sequence else { return }
        activeSession = nil
    }
}

nonisolated private enum ConnectionsStreamWorker {
    static func run(
        request: URLRequest,
        generation: ConfigurationGeneration,
        continuation: AsyncThrowingStream<ConnectionsStreamEvent, Error>.Continuation,
        lifecycle: ConnectionsStreamLifecycle,
        transport: any TelemetryWebSocketTransporting,
        maximumReconnectCount: Int,
        reconnectDelay: Duration
    ) async {
        var reconnectCount = 0

        while !Task.isCancelled {
            do {
                let connection = try await transport.connect(request: request)
                try Task.checkCancellation()
                guard await lifecycle.install(connection) else { break }

                while !Task.isCancelled {
                    let message = try await connection.receive()
                    try Task.checkCancellation()

                    let snapshot: ConnectionsSnapshot
                    do {
                        snapshot = try JSONDecoder().decode(
                            ConnectionsSnapshot.self,
                            from: message.data
                        )
                    } catch {
                        throw ConnectionsFailure.snapshotDecodeFailed
                    }

                    // The retry budget limits consecutive failures. Once a
                    // connection produces a valid snapshot it has recovered,
                    // so a later Wi-Fi/sleep interruption starts a new bounded
                    // retry episode instead of consuming a lifetime quota.
                    reconnectCount = 0

                    let result = continuation.yield(
                        ConnectionsStreamEvent(
                            generation: generation,
                            snapshot: snapshot
                        )
                    )
                    if case .terminated = result {
                        await lifecycle.close()
                        return
                    }
                }
            } catch is CancellationError {
                break
            } catch let error as URLError where error.code == .cancelled
                && Task.isCancelled
            {
                break
            } catch let failure as ConnectionsFailure
                where failure == .snapshotDecodeFailed
            {
                continuation.finish(throwing: failure)
                await lifecycle.close()
                return
            } catch {
                await lifecycle.closeCurrent()
                guard reconnectCount < maximumReconnectCount else {
                    continuation.finish(throwing: ConnectionsFailure.streamUnavailable)
                    await lifecycle.close()
                    return
                }

                reconnectCount += 1
                do {
                    if reconnectDelay == .zero {
                        await Task.yield()
                    } else {
                        try await Task.sleep(for: reconnectDelay)
                    }
                } catch {
                    break
                }
            }
        }

        continuation.finish()
        await lifecycle.close()
    }
}

private actor ConnectionsStreamLifecycle {
    private var connection: (any TelemetryWebSocketConnection)?
    private var closed = false

    func install(_ newConnection: any TelemetryWebSocketConnection) async -> Bool {
        guard !closed else {
            await newConnection.close()
            return false
        }
        let old = connection
        connection = newConnection
        await old?.close()
        return true
    }

    func closeCurrent() async {
        let value = connection
        connection = nil
        await value?.close()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await closeCurrent()
    }
}

actor ConnectionsService {
    private let apiClient: any MihomoAPIProviding
    private let confirmationTimeout: Duration
    private let pollInterval: Duration
    private var pendingConnectionIDs: Set<String> = []
    private var isClosingAll = false

    init(
        apiClient: any MihomoAPIProviding,
        confirmationTimeout: Duration = .seconds(3),
        pollInterval: Duration = .milliseconds(250)
    ) {
        self.apiClient = apiClient
        self.confirmationTimeout = max(.zero, confirmationTimeout)
        self.pollInterval = max(.milliseconds(1), pollInterval)
    }

    func snapshot() async throws -> ConnectionsSnapshot {
        do {
            return try await apiClient.connections()
        } catch is DecodingError {
            throw ConnectionsFailure.snapshotDecodeFailed
        } catch let error as MihomoAPIError {
            if case .decodingFailed = error {
                throw ConnectionsFailure.snapshotDecodeFailed
            }
            throw ConnectionsFailure.streamUnavailable
        } catch {
            throw ConnectionsFailure.streamUnavailable
        }
    }

    func pendingCloseIDs() -> Set<String> {
        pendingConnectionIDs
    }

    func isCloseAllPending() -> Bool {
        isClosingAll
    }

    func closeConnection(id: String, confirm: Bool = true) async throws {
        guard !pendingConnectionIDs.contains(id) else { return }
        pendingConnectionIDs.insert(id)
        defer { pendingConnectionIDs.remove(id) }
        do {
            try await apiClient.closeConnection(id: id)
        } catch {
            throw ConnectionsFailure.closeFailed
        }
        guard confirm else { return }
        try await waitUntil { snapshot in
            !snapshot.connections.contains { $0.id == id }
        }
    }

    func closeAll(confirm: Bool = true) async throws {
        guard !isClosingAll else { return }
        isClosingAll = true
        defer { isClosingAll = false }
        do {
            try await apiClient.closeAllConnections()
        } catch {
            throw ConnectionsFailure.closeAllFailed
        }
        guard confirm else { return }
        try await waitUntil { $0.connections.isEmpty }
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable (ConnectionsSnapshot) -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: confirmationTimeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                if predicate(try await apiClient.connections()) { return }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Controller reloads can briefly interrupt the confirmation read.
            }

            let now = clock.now
            guard now < deadline else { break }
            try await Task.sleep(for: min(pollInterval, now.duration(to: deadline)))
        }
        throw ConnectionsFailure.closeConfirmationTimedOut
    }
}
