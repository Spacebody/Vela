import Foundation
import Synchronization
import Testing
@testable import Vela

@Suite("Network path observer")
struct NetworkPathObserverTests {
    @Test("Start is idempotent, route updates are preserved, and stop can restart")
    func lifecycleAndRouteUpdates() async {
        let harness = NetworkPathSessionHarness()
        let observer = NetworkPathObserver(sessionFactory: {
            harness.makeSession()
        })
        let recorder = NetworkPathEventRecorder()
        let events = await observer.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await observer.start()
        await observer.start()
        #expect(harness.sessionCount == 1)

        let satisfied = NetworkPathSnapshot(
            status: .satisfied,
            isExpensive: true,
            isConstrained: true
        )
        harness.yield(satisfied)
        harness.yield(satisfied)

        #expect(await waitUntil {
            await recorder.events == [.unknown, satisfied, satisfied]
        })

        await observer.stop()
        #expect(harness.cancellationCount == 1)

        await observer.start()
        #expect(harness.sessionCount == 2)
        let unsatisfied = NetworkPathSnapshot(status: .unsatisfied)
        harness.yield(unsatisfied)
        #expect(await waitUntil {
            await recorder.events == [.unknown, satisfied, satisfied, unsatisfied]
        })

        await observer.stop()
        #expect(harness.cancellationCount == 2)
        eventTask.cancel()
        await eventTask.value
    }

    @Test("Only a satisfied path is reported as network reachable")
    func reachabilitySemantics() {
        #expect(NetworkPathSnapshot(status: .satisfied).networkReachable)
        #expect(!NetworkPathSnapshot.unknown.networkReachable)
        #expect(!NetworkPathSnapshot(status: .unsatisfied).networkReachable)
        #expect(!NetworkPathSnapshot(status: .requiresConnection).networkReachable)
    }
}

private actor NetworkPathEventRecorder {
    private(set) var events: [NetworkPathSnapshot] = []

    func record(_ event: NetworkPathSnapshot) {
        events.append(event)
    }
}

nonisolated private final class NetworkPathSessionHarness: Sendable {
    private struct State: Sendable {
        var continuations: [
            UUID: AsyncStream<NetworkPathSnapshot>.Continuation
        ] = [:]
        var sessionCount = 0
        var cancellationCount = 0
    }

    private let state = Mutex(State())

    var sessionCount: Int {
        state.withLock { $0.sessionCount }
    }

    var cancellationCount: Int {
        state.withLock { $0.cancellationCount }
    }

    func makeSession() -> NetworkPathObservationSession {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: NetworkPathSnapshot.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        state.withLock { value in
            value.sessionCount += 1
            value.continuations[id] = continuation
        }

        return NetworkPathObservationSession(
            snapshots: stream,
            cancel: { [weak self] in
                guard let self else { return }
                let removed = state.withLock { value in
                    value.cancellationCount += 1
                    return value.continuations.removeValue(forKey: id)
                }
                removed?.finish()
            }
        )
    }

    func yield(_ snapshot: NetworkPathSnapshot) {
        let activeContinuations = state.withLock {
            Array($0.continuations.values)
        }
        activeContinuations.forEach { $0.yield(snapshot) }
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    // A pure Task.yield loop can exhaust before the observer's child task is
    // scheduled when the complete test bundle is under load. Keep the wait
    // bounded, but give the cooperative executor real scheduling windows.
    for _ in 0..<2_000 {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}
