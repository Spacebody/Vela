import Foundation
import Testing
@testable import Vela

@Suite("Engine health monitor")
struct EngineHealthMonitorTests {
    @Test("Active and inactive cadence use five and thirty seconds")
    func cadenceChangesWithApplicationActivity() async throws {
        let checker = HealthCheckerFake(suspends: false)
        let scheduler = ManualHealthScheduler()
        let monitor = EngineHealthMonitor(checker: checker, scheduler: scheduler)
        var reports = await monitor.events().makeAsyncIterator()

        await monitor.start(context: healthContext())
        _ = try #require(await reports.next())
        await scheduler.waitUntilRequestCount(1)
        #expect(await scheduler.requestedDurations().first == .seconds(5))

        await monitor.setApplicationActive(false)
        await scheduler.waitUntilRequestCount(2)
        #expect(await scheduler.requestedDurations().last == .seconds(30))

        await monitor.stop()
    }

    @Test("Triggers during a slow check coalesce into one single-flight follow-up")
    func burstTriggersCoalesceWithoutOverlap() async throws {
        let checker = HealthCheckerFake(suspends: true)
        let scheduler = ManualHealthScheduler()
        let monitor = EngineHealthMonitor(checker: checker, scheduler: scheduler)
        var reports = await monitor.events().makeAsyncIterator()

        await monitor.start(context: healthContext())
        await checker.waitUntilCallCount(1)
        await monitor.trigger(.manual)
        await monitor.trigger(.networkChanged)
        await monitor.trigger(.wokeFromSleep)
        #expect(await checker.maximumConcurrentCalls() == 1)

        await checker.releaseNext()
        let first = try #require(await reports.next())
        #expect(first.sequence == 1)
        await checker.waitUntilCallCount(2)
        #expect(await checker.maximumConcurrentCalls() == 1)

        await checker.releaseNext()
        let second = try #require(await reports.next())
        #expect(second.sequence == 2)
        #expect(second.triggers == [.manual, .networkChanged, .wokeFromSleep])
        #expect(await checker.callCount() == 2)

        await monitor.stop()
    }

    @Test("Stop cancels and joins an in-flight check and permits a clean restart")
    func stopCancelsAndJoinsCheck() async throws {
        let checker = CancellationAwareHealthChecker()
        let scheduler = ManualHealthScheduler()
        let monitor = EngineHealthMonitor(checker: checker, scheduler: scheduler)

        await monitor.start(context: healthContext())
        await checker.waitUntilStarted()
        await monitor.stop()

        #expect(await checker.wasCancelled())

        await monitor.start(context: healthContext(sessionID: UUID()))
        await checker.waitUntilStartCount(2)
        await monitor.stop()
        #expect(await checker.maximumConcurrentCalls() == 1)
    }

    @Test("A context update discards the in-flight stale report and checks the new context")
    func contextRevisionRejectsStaleReport() async throws {
        let checker = HealthCheckerFake(suspends: true)
        let scheduler = ManualHealthScheduler()
        let monitor = EngineHealthMonitor(checker: checker, scheduler: scheduler)
        var reports = await monitor.events().makeAsyncIterator()
        let sessionID = UUID()

        await monitor.start(context: healthContext(sessionID: sessionID))
        await checker.waitUntilCallCount(1)
        await monitor.updateContext(
            EngineHealthCheckContext(
                sessionID: sessionID,
                expectedRunning: true,
                configurationFingerprint: nil,
                mixedPort: 7_890,
                systemProxyTarget: SystemProxyTarget(port: UInt16(7_890)),
                systemProxyExpected: false,
                networkPath: NetworkPathSnapshot(status: .satisfied)
            )
        )
        await monitor.trigger(.networkChanged)

        await checker.releaseNext()
        await checker.waitUntilCallCount(2)
        await checker.releaseNext()

        let report = try #require(await reports.next())
        #expect(report.sequence == 2)
        #expect(report.triggers == [.manual, .networkChanged])
        await monitor.stop()
    }

    @Test("Wake forces one immediate check even when activity state does not change")
    func wakeAlwaysTriggersOneCheck() async throws {
        let checker = HealthCheckerFake(suspends: false)
        let scheduler = ManualHealthScheduler()
        let monitor = EngineHealthMonitor(checker: checker, scheduler: scheduler)
        var reports = await monitor.events().makeAsyncIterator()

        await monitor.setApplicationActive(false)
        await monitor.start(context: healthContext())
        _ = try #require(await reports.next())
        await monitor.resumeAfterWake(applicationActive: false)

        let wakeReport = try #require(await reports.next())
        #expect(wakeReport.triggers == [.wokeFromSleep])
        #expect(await checker.callCount() == 2)
        await monitor.stop()
    }
}

private nonisolated func healthContext(
    sessionID: UUID = UUID()
) -> EngineHealthCheckContext {
    EngineHealthCheckContext(
        sessionID: sessionID,
        expectedRunning: true,
        configurationFingerprint: nil,
        mixedPort: 7_890,
        systemProxyTarget: SystemProxyTarget(port: UInt16(7_890)),
        systemProxyExpected: false,
        networkPath: .unknown
    )
}

private nonisolated func healthReport(
    context: EngineHealthCheckContext,
    triggers: [HealthCheckTrigger],
    sequence: UInt64
) -> EngineHealthReport {
    let timestamp = Date(timeIntervalSince1970: TimeInterval(sequence))
    return EngineHealthReport(
        sessionID: context.sessionID,
        sequence: sequence,
        triggers: triggers,
        health: EngineHealth(
            processRunning: true,
            controllerReachable: true,
            configurationValid: true,
            systemProxyApplied: false,
            networkReachable: true,
            internetReachable: true,
            portsListening: true,
            lastCheckedAt: timestamp,
            overallState: .healthy
        ),
        systemProxyStatus: nil,
        checks: [],
        issues: [],
        startedAt: timestamp,
        completedAt: timestamp
    )
}

private actor HealthCheckerFake: EngineHealthChecking {
    private let suspends: Bool
    private var calls = 0
    private var concurrentCalls = 0
    private var maximumConcurrency = 0
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var callObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    init(suspends: Bool) {
        self.suspends = suspends
    }

    func check(
        context: EngineHealthCheckContext,
        triggers: [HealthCheckTrigger],
        sequence: UInt64
    ) async -> EngineHealthReport {
        calls += 1
        concurrentCalls += 1
        maximumConcurrency = max(maximumConcurrency, concurrentCalls)
        resumeCallObservers()
        if suspends {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        concurrentCalls -= 1
        return healthReport(context: context, triggers: triggers, sequence: sequence)
    }

    func waitUntilCallCount(_ count: Int) async {
        guard calls < count else { return }
        await withCheckedContinuation { continuation in
            callObservers.append((count, continuation))
        }
    }

    func releaseNext() {
        guard !releaseContinuations.isEmpty else { return }
        releaseContinuations.removeFirst().resume()
    }

    func callCount() -> Int { calls }
    func maximumConcurrentCalls() -> Int { maximumConcurrency }

    private func resumeCallObservers() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for observer in callObservers {
            if calls >= observer.0 {
                observer.1.resume()
            } else {
                remaining.append(observer)
            }
        }
        callObservers = remaining
    }
}

private actor CancellationAwareHealthChecker: EngineHealthChecking {
    private var starts = 0
    private var concurrent = 0
    private var maximumConcurrency = 0
    private var cancellations = 0
    private var startObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    func check(
        context: EngineHealthCheckContext,
        triggers: [HealthCheckTrigger],
        sequence: UInt64
    ) async -> EngineHealthReport {
        starts += 1
        concurrent += 1
        maximumConcurrency = max(maximumConcurrency, concurrent)
        resumeObservers()
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancellations += 1
        }
        concurrent -= 1
        return healthReport(context: context, triggers: triggers, sequence: sequence)
    }

    func waitUntilStarted() async { await waitUntilStartCount(1) }

    func waitUntilStartCount(_ count: Int) async {
        guard starts < count else { return }
        await withCheckedContinuation { continuation in
            startObservers.append((count, continuation))
        }
    }

    func wasCancelled() -> Bool { cancellations > 0 }
    func maximumConcurrentCalls() -> Int { maximumConcurrency }

    private func resumeObservers() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for observer in startObservers {
            if starts >= observer.0 {
                observer.1.resume()
            } else {
                remaining.append(observer)
            }
        }
        startObservers = remaining
    }
}

private actor ManualHealthScheduler: EngineHealthScheduling {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var durations: [Duration] = []
    private var waiters: [Waiter] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                durations.append(duration)
                waiters.append(Waiter(id: id, continuation: continuation))
                resumeObservers()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilRequestCount(_ count: Int) async {
        guard durations.count < count else { return }
        await withCheckedContinuation { continuation in
            observers.append((count, continuation))
        }
    }

    func requestedDurations() -> [Duration] { durations }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resumeObservers() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for observer in observers {
            if durations.count >= observer.0 {
                observer.1.resume()
            } else {
                remaining.append(observer)
            }
        }
        observers = remaining
    }
}
