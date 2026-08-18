import Foundation
import Testing
@testable import VelaPrivilegedCore

@Suite("Async exclusive operation gate")
struct AsyncExclusiveOperationGateTests {
    @Test("Cancelling a queued operation cannot strand the privileged gate")
    func cancelledWaiterStillReleasesForTheNextOperation() async throws {
        let gate = AsyncExclusiveOperationGate()
        let probe = GateEventProbe()
        await gate.acquire()

        let cancelledWaiter = Task {
            await probe.record(.waiterStarted)
            await gate.acquire()
            defer { gate.release() }
            await probe.record(.cancelledWaiterEntered)
        }
        await probe.wait(until: .waiterStarted)
        try await Task.sleep(for: .milliseconds(20))
        cancelledWaiter.cancel()

        gate.release()
        await cancelledWaiter.value

        let follower = Task {
            await gate.acquire()
            defer { gate.release() }
            await probe.record(.followerEntered)
        }
        await follower.value

        #expect(cancelledWaiter.isCancelled)
        #expect(
            await probe.events()
                == [.waiterStarted, .cancelledWaiterEntered, .followerEntered]
        )
    }
}

private actor GateEventProbe {
    enum Event: Hashable {
        case waiterStarted
        case cancelledWaiterEntered
        case followerEntered
    }

    private var recorded: [Event] = []
    private var waiters: [Event: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ event: Event) {
        recorded.append(event)
        let continuations = waiters.removeValue(forKey: event) ?? []
        continuations.forEach { $0.resume() }
    }

    func wait(until event: Event) async {
        if recorded.contains(event) { return }
        await withCheckedContinuation { continuation in
            waiters[event, default: []].append(continuation)
        }
    }

    func events() -> [Event] { recorded }
}
