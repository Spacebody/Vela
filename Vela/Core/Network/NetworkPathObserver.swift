import Foundation
import Network
import OSLog

nonisolated struct NetworkPathSnapshot: Equatable, Sendable {
    nonisolated enum InterfaceKind: String, Equatable, Sendable {
        case wifi
        case wiredEthernet
        case other
    }

    nonisolated enum Status: String, Equatable, Sendable {
        case unknown
        case satisfied
        case unsatisfied
        case requiresConnection
    }

    let status: Status
    let isExpensive: Bool
    let isConstrained: Bool
    let interfaceKind: InterfaceKind?

    static let unknown = NetworkPathSnapshot(
        status: .unknown,
        isExpensive: false,
        isConstrained: false,
        interfaceKind: nil
    )

    var networkReachable: Bool {
        status == .satisfied
    }

    init(
        status: Status,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        interfaceKind: InterfaceKind? = nil
    ) {
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interfaceKind = interfaceKind
    }

    init(path: NWPath) {
        status = switch path.status {
        case .satisfied:
            .satisfied
        case .unsatisfied:
            .unsatisfied
        case .requiresConnection:
            .requiresConnection
        @unknown default:
            .unknown
        }
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        interfaceKind = if path.usesInterfaceType(.wifi) {
            .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            .wiredEthernet
        } else if path.status == .satisfied {
            .other
        } else {
            nil
        }
    }
}

nonisolated protocol NetworkPathObserving: Actor {
    func start()
    func events() -> AsyncStream<NetworkPathSnapshot>
    func stop() async
}

nonisolated struct NetworkPathObservationSession: Sendable {
    let snapshots: AsyncStream<NetworkPathSnapshot>
    let cancel: @Sendable () -> Void
}

actor NetworkPathObserver: NetworkPathObserving {
    typealias SessionFactory = @Sendable () -> NetworkPathObservationSession

    private nonisolated static let logger = Logger(
        subsystem: "dev.yilin.Vela",
        category: "NetworkPath"
    )

    private let sessionFactory: SessionFactory
    private var session: NetworkPathObservationSession?
    private var observationTask: Task<Void, Never>?
    private var lastSnapshot: NetworkPathSnapshot = .unknown
    private var continuations: [
        UUID: AsyncStream<NetworkPathSnapshot>.Continuation
    ] = [:]

    init(sessionFactory: @escaping SessionFactory = NetworkPathObserver.makeLiveSession) {
        self.sessionFactory = sessionFactory
    }

    func start() {
        guard observationTask == nil else { return }

        let session = sessionFactory()
        self.session = session
        observationTask = Task { [weak self, session] in
            for await snapshot in session.snapshots {
                guard !Task.isCancelled else { break }
                await self?.accept(snapshot)
            }
        }
    }

    func events() -> AsyncStream<NetworkPathSnapshot> {
        let id = UUID()
        let initialSnapshot = lastSnapshot
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            continuations[id] = continuation
            continuation.yield(initialSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    func stop() async {
        let activeSession = session
        let activeTask = observationTask
        session = nil
        observationTask = nil

        activeTask?.cancel()
        activeSession?.cancel()
        if let activeTask {
            await activeTask.value
        }
    }

    private func accept(_ snapshot: NetworkPathSnapshot) {
        lastSnapshot = snapshot

        Self.logger.info(
            "Path status=\(snapshot.status.rawValue, privacy: .public) expensive=\(snapshot.isExpensive, privacy: .public) constrained=\(snapshot.isConstrained, privacy: .public)"
        )
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    nonisolated private static func makeLiveSession() -> NetworkPathObservationSession {
        let monitor = NWPathMonitor()
        let (snapshots, continuation) = AsyncStream.makeStream(
            of: NetworkPathSnapshot.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        let producerTask = Task {
            for await path in monitor {
                guard !Task.isCancelled else { break }
                continuation.yield(NetworkPathSnapshot(path: path))
            }
            continuation.finish()
        }

        return NetworkPathObservationSession(
            snapshots: snapshots,
            cancel: {
                producerTask.cancel()
                monitor.cancel()
                continuation.finish()
            }
        )
    }
}
