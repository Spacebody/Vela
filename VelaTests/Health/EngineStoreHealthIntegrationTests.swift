import Foundation
import Testing
@testable import Vela

@MainActor
@Suite("Engine store health integration")
struct EngineStoreHealthIntegrationTests {
    @Test("Health reports apply degraded state and recover to healthy")
    func healthReportsApplyAndRecover() async {
        let fixture = makeFixture()
        await fixture.store.bootstrap()
        await fixture.store.start()
        await fixture.controller.emit(.ready(HealthStoreValues.controllerSnapshot))
        await waitForControllerState(fixture.store, expected: .connected)

        guard let sessionID = await fixture.monitor.activeSessionID() else {
            Issue.record("Expected health monitoring to start with the engine")
            await fixture.finish()
            return
        }

        let degraded = makeReport(
            sessionID: sessionID,
            sequence: 1,
            triggers: [.periodic],
            processRunning: true,
            controllerReachable: true,
            overallState: .degraded
        )
        await fixture.monitor.emit(degraded)
        await waitForReport(fixture.store, sequence: 1)

        #expect(fixture.store.lastHealthReport == degraded)
        #expect(fixture.store.state == .running(degraded.health))

        let healthy = makeReport(
            sessionID: sessionID,
            sequence: 2,
            triggers: [.periodic],
            processRunning: true,
            controllerReachable: true,
            overallState: .healthy
        )
        await fixture.monitor.emit(healthy)
        await waitForReport(fixture.store, sequence: 2)

        #expect(fixture.store.lastHealthReport == healthy)
        #expect(fixture.store.state == .running(healthy.health))
        await fixture.finish()
    }

    @Test("A periodic Controller failure never triggers reconnect")
    func periodicFailureDoesNotReconnect() async {
        let fixture = makeFixture()
        await fixture.store.bootstrap()
        await fixture.store.start()

        guard let sessionID = await fixture.monitor.activeSessionID() else {
            Issue.record("Expected health monitoring to start with the engine")
            await fixture.finish()
            return
        }

        await fixture.monitor.emit(makeReport(
            sessionID: sessionID,
            sequence: 1,
            triggers: [.periodic],
            processRunning: true,
            controllerReachable: false,
            overallState: .degraded
        ))
        await waitForReport(fixture.store, sequence: 1)
        await settleEventConsumers()

        #expect(await fixture.controller.refreshCallCount() == 0)
        await fixture.finish()
    }

    @Test("Triggered Controller recovery is once per episode and capped per engine run")
    func triggeredRecoveryIsBounded() async {
        let fixture = makeFixture()
        await fixture.store.bootstrap()
        await fixture.store.start()
        await fixture.controller.emit(.disconnected)
        await waitForControllerState(fixture.store, expected: .disconnected)

        guard let sessionID = await fixture.monitor.activeSessionID() else {
            Issue.record("Expected health monitoring to start with the engine")
            await fixture.finish()
            return
        }

        await fixture.monitor.emit(makeReport(
            sessionID: sessionID,
            sequence: 1,
            triggers: [.networkChanged],
            processRunning: true,
            controllerReachable: false,
            overallState: .degraded
        ))
        await waitForRefreshCount(fixture.controller, expected: 1)

        await fixture.monitor.emit(makeReport(
            sessionID: sessionID,
            sequence: 2,
            triggers: [.manual],
            processRunning: true,
            controllerReachable: false,
            overallState: .degraded
        ))
        await waitForReport(fixture.store, sequence: 2)
        await settleEventConsumers()
        #expect(await fixture.controller.refreshCallCount() == 1)

        await fixture.controller.emit(.ready(HealthStoreValues.controllerSnapshot))
        await waitForControllerState(fixture.store, expected: .connected)
        await fixture.monitor.emit(makeReport(
            sessionID: sessionID,
            sequence: 3,
            triggers: [.periodic],
            processRunning: true,
            controllerReachable: true,
            overallState: .healthy
        ))
        await waitForReport(fixture.store, sequence: 3)

        await fixture.controller.emit(.disconnected)
        await waitForControllerState(fixture.store, expected: .disconnected)
        await fixture.monitor.emit(makeReport(
            sessionID: sessionID,
            sequence: 4,
            triggers: [.manual],
            processRunning: true,
            controllerReachable: false,
            overallState: .degraded
        ))
        await waitForRefreshCount(fixture.controller, expected: 2)

        await fixture.controller.emit(.ready(HealthStoreValues.controllerSnapshot))
        await waitForControllerState(fixture.store, expected: .connected)
        await fixture.monitor.emit(makeReport(
            sessionID: sessionID,
            sequence: 5,
            triggers: [.periodic],
            processRunning: true,
            controllerReachable: true,
            overallState: .healthy
        ))
        await waitForReport(fixture.store, sequence: 5)

        await fixture.controller.emit(.disconnected)
        await waitForControllerState(fixture.store, expected: .disconnected)
        await fixture.monitor.emit(makeReport(
            sessionID: sessionID,
            sequence: 6,
            triggers: [.networkChanged],
            processRunning: true,
            controllerReachable: false,
            overallState: .degraded
        ))
        await waitForRefreshCount(fixture.controller, expected: 3)

        await fixture.controller.emit(.ready(HealthStoreValues.controllerSnapshot))
        await waitForControllerState(fixture.store, expected: .connected)
        await fixture.monitor.emit(makeReport(
            sessionID: sessionID,
            sequence: 7,
            triggers: [.periodic],
            processRunning: true,
            controllerReachable: true,
            overallState: .healthy
        ))
        await waitForReport(fixture.store, sequence: 7)

        await fixture.controller.emit(.disconnected)
        await waitForControllerState(fixture.store, expected: .disconnected)
        await fixture.monitor.emit(makeReport(
            sessionID: sessionID,
            sequence: 8,
            triggers: [.manual],
            processRunning: true,
            controllerReachable: false,
            overallState: .degraded
        ))
        await waitForReport(fixture.store, sequence: 8)
        await settleEventConsumers()

        #expect(await fixture.controller.refreshCallCount() == 3)
        #expect(await fixture.controller.applicationLogCount() == 3)
        await fixture.finish()
    }

    @Test("Stop during reconnect logging prevents a late Controller refresh")
    func stopDuringReconnectLoggingPreventsRefresh() async {
        let fixture = makeFixture(suspendControllerLog: true)
        await fixture.store.bootstrap()
        await fixture.store.start()
        await fixture.controller.emit(.disconnected)
        await waitForControllerState(fixture.store, expected: .disconnected)

        guard let sessionID = await fixture.monitor.activeSessionID() else {
            Issue.record("Expected health monitoring to start with the engine")
            await fixture.finish()
            return
        }

        await fixture.monitor.emit(makeReport(
            sessionID: sessionID,
            sequence: 1,
            triggers: [.manual],
            processRunning: true,
            controllerReachable: false,
            overallState: .degraded
        ))
        await waitForSuspendedApplicationLog(fixture.controller)

        await fixture.store.stop()
        await fixture.controller.releaseApplicationLog()
        await settleEventConsumers()

        #expect(fixture.store.state == .stopped)
        #expect(await fixture.controller.refreshCallCount() == 0)
        #expect(!(await fixture.monitor.hasActiveSession()))
        await fixture.finish()
    }

    @Test("A report with a missing process fails without auto-starting Mihomo")
    func missingProcessReportFailsWithoutRestart() async {
        let fixture = makeFixture()
        await fixture.store.bootstrap()
        await fixture.store.start()

        guard let sessionID = await fixture.monitor.activeSessionID() else {
            Issue.record("Expected health monitoring to start with the engine")
            await fixture.finish()
            return
        }
        #expect(await fixture.process.startCallCount() == 1)

        let missingProcess = makeReport(
            sessionID: sessionID,
            sequence: 1,
            triggers: [.periodic],
            processRunning: false,
            controllerReachable: false,
            overallState: .failed
        )
        await fixture.monitor.emit(missingProcess)
        await waitForFailedState(fixture.store)

        #expect(fixture.store.lastHealthReport == missingProcess)
        #expect(await fixture.process.startCallCount() == 1)
        #expect(await fixture.controller.refreshCallCount() == 0)
        #expect(!(await fixture.monitor.hasActiveSession()))
        await fixture.finish()
    }

    @Test("A report arriving after Stop cannot revive the old health session")
    func lateReportAfterStopIsIgnored() async {
        let fixture = makeFixture()
        await fixture.store.bootstrap()
        await fixture.store.start()

        guard let sessionID = await fixture.monitor.activeSessionID() else {
            Issue.record("Expected health monitoring to start with the engine")
            await fixture.finish()
            return
        }

        await fixture.store.stop()
        let lateReport = makeReport(
            sessionID: sessionID,
            sequence: 1,
            triggers: [.periodic],
            processRunning: true,
            controllerReachable: true,
            overallState: .healthy
        )
        await fixture.monitor.emit(lateReport)
        await settleEventConsumers()

        #expect(fixture.store.state == .stopped)
        #expect(fixture.store.lastHealthReport == nil)
        #expect(!(await fixture.monitor.hasActiveSession()))
        #expect(await fixture.process.startCallCount() == 1)
        await fixture.finish()
    }

    @Test("Stop serializes behind suspended health monitor activation")
    func stopWinsAgainstDelayedApplicationActivation() async {
        let fixture = makeFixture(delay: .setApplicationActive)
        await fixture.store.bootstrap()

        let startTask = Task { @MainActor in
            await fixture.store.start()
        }
        await waitForMonitorDelay(fixture.monitor, phase: .setApplicationActive)

        let stopTask = Task { @MainActor in
            await fixture.store.stop()
        }
        fixture.monitor.releaseApplicationActivationDelay()
        await startTask.value
        await stopTask.value
        await settleEventConsumers()

        #expect(fixture.store.state == .stopped)
        #expect(await fixture.monitor.startCallCount() == 1)
        #expect(!(await fixture.monitor.hasActiveSession()))
        #expect(await fixture.process.stopCallCount() == 1)
        await fixture.finish()
    }

    @Test("Stop serializes behind a health session whose start call finishes late")
    func stopWinsAgainstDelayedMonitorStart() async {
        let fixture = makeFixture(delay: .start)
        await fixture.store.bootstrap()

        let startTask = Task { @MainActor in
            await fixture.store.start()
        }
        await waitForMonitorDelay(fixture.monitor, phase: .start)

        let stopTask = Task { @MainActor in
            await fixture.store.stop()
        }
        await fixture.monitor.releaseStartDelay()
        await startTask.value
        await stopTask.value
        await settleEventConsumers()

        #expect(fixture.store.state == .stopped)
        #expect(await fixture.monitor.startCallCount() == 1)
        #expect(await fixture.monitor.stopCallCount() >= 1)
        #expect(!(await fixture.monitor.hasActiveSession()))
        #expect(await fixture.process.stopCallCount() == 1)
        await fixture.finish()
    }

    @Test("Unexpected termination supersedes a Stop suspended in proxy restore")
    func terminationSupersedesSuspendedStopRestore() async {
        let systemProxy = HealthStoreSystemProxyManagerFake(suspendRestore: true)
        let fixture = makeFixture(systemProxyManager: systemProxy)
        await fixture.store.bootstrap()
        await fixture.store.start()
        await fixture.controller.emit(.ready(HealthStoreValues.controllerSnapshot))
        await waitForControllerState(fixture.store, expected: .connected)
        await fixture.store.setSystemProxyEnabled(true)
        #expect(fixture.store.isSystemProxyApplied)

        let stopTask = Task { @MainActor in
            await fixture.store.stop()
        }
        await waitForSuspendedRestore(systemProxy)

        await fixture.process.emit(.terminated(HealthStoreValues.unexpectedTermination))
        await waitForFailedState(fixture.store)
        await systemProxy.releaseRestore()
        await stopTask.value
        await settleEventConsumers()

        if case .failed = fixture.store.state {
            // Expected: the newer termination event owns the final state.
        } else {
            Issue.record("A stale Stop operation replaced the unexpected termination state")
        }
        #expect(!(await fixture.monitor.hasActiveSession()))
        #expect(await fixture.process.startCallCount() == 1)
        await fixture.finish()
    }

    @Test("A user Stop serializes behind Restart suspended in process inspection")
    func stopSerializesBehindSuspendedRestart() async {
        let fixture = makeFixture()
        await fixture.store.bootstrap()
        await fixture.store.start()
        await fixture.process.suspendNextIsRunningCall()

        let restartTask = Task { @MainActor in
            await fixture.store.restart()
        }
        await waitForSuspendedIsRunning(fixture.process)

        let stopTask = Task { @MainActor in
            await fixture.store.stop()
        }
        await fixture.process.releaseIsRunningCall()
        await restartTask.value
        await stopTask.value
        await settleEventConsumers()

        #expect(fixture.store.state == .stopped)
        #expect(await fixture.process.startCallCount() == 2)
        #expect(await fixture.process.stopCallCount() == 2)
        #expect(!(await fixture.monitor.hasActiveSession()))
        await fixture.finish()
    }

    private func makeFixture(
        delay: HealthStoreMonitorDelay = .none,
        suspendControllerLog: Bool = false,
        systemProxyManager: (any SystemProxyManaging)? = nil
    ) -> HealthStoreFixture {
        let process = HealthStoreProcessManagerFake()
        let controller = HealthStoreControllerManagerFake(
            suspendApplicationLog: suspendControllerLog
        )
        let monitor = HealthStoreHealthMonitorFake(delay: delay)
        let profileStore = HealthStoreProfileManagerFake(
            profile: HealthStoreValues.profile
        )
        let store = EngineStore(
            profileStore: profileStore,
            runtimeParameters: RuntimeConfigParameters(
                externalController: "127.0.0.1:19090",
                secret: "health-store-test-secret",
                mixedPort: 17_890
            ),
            executableResolver: HealthStoreExecutableResolverFake(),
            configurationValidator: HealthStoreConfigurationValidatorFake(),
            processManager: process,
            controllerManager: controller,
            systemProxyManager: systemProxyManager,
            healthMonitor: monitor,
            mihomoDataDirectoryURL: HealthStoreValues.dataDirectory
        )
        return HealthStoreFixture(
            store: store,
            process: process,
            controller: controller,
            monitor: monitor
        )
    }

    private func makeReport(
        sessionID: UUID,
        sequence: UInt64,
        triggers: [HealthCheckTrigger],
        processRunning: Bool,
        controllerReachable: Bool,
        overallState: EngineHealthState
    ) -> EngineHealthReport {
        let timestamp = Date(timeIntervalSince1970: 1_720_000_000 + Double(sequence))
        let isHealthy = overallState == .healthy
        let issues: [EngineHealthIssue] = if controllerReachable || !processRunning {
            []
        } else {
            [EngineHealthIssue(
                component: .controller,
                severity: .warning,
                summary: "Controller probe failed.",
                technicalDetails: "Test probe was unreachable.",
                suggestedAction: "Retry the Controller connection."
            )]
        }
        return EngineHealthReport(
            sessionID: sessionID,
            sequence: sequence,
            triggers: triggers,
            health: EngineHealth(
                processRunning: processRunning,
                controllerReachable: controllerReachable,
                configurationValid: processRunning,
                systemProxyApplied: false,
                networkReachable: processRunning,
                internetReachable: isHealthy,
                portsListening: processRunning,
                lastCheckedAt: timestamp,
                overallState: overallState
            ),
            systemProxyStatus: nil,
            checks: [],
            issues: issues,
            startedAt: timestamp.addingTimeInterval(-0.05),
            completedAt: timestamp
        )
    }

    private func waitForReport(_ store: EngineStore, sequence: UInt64) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.lastHealthReport?.sequence == sequence {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for health report sequence \(sequence)")
    }

    private func waitForFailedState(_ store: EngineStore) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if case .failed = store.state {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for failed engine state")
    }

    private func waitForControllerState(
        _ store: EngineStore,
        expected: ControllerConnectionState
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.controllerState == expected {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for Controller state \(expected)")
    }

    private func waitForEngineState(
        _ store: EngineStore,
        expected: EngineState
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.state == expected {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for engine state \(expected)")
    }

    private func waitForRefreshCount(
        _ controller: HealthStoreControllerManagerFake,
        expected: Int
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await controller.refreshCallCount() == expected {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for \(expected) Controller reconnects")
    }

    private func waitForSuspendedApplicationLog(
        _ controller: HealthStoreControllerManagerFake
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await controller.didSuspendApplicationLog() {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for Controller recovery logging to suspend")
    }

    private func waitForSuspendedRestore(
        _ manager: HealthStoreSystemProxyManagerFake
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await manager.didSuspendRestore() {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for System Proxy restore to suspend")
    }

    private func waitForSuspendedIsRunning(
        _ process: HealthStoreProcessManagerFake
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await process.didSuspendIsRunningCall() {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for process inspection to suspend")
    }

    private func waitForMonitorDelay(
        _ monitor: HealthStoreHealthMonitorFake,
        phase: HealthStoreMonitorDelay
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            let isSuspended = switch phase {
            case .setApplicationActive:
                monitor.isApplicationActivationSuspended()
            case .start:
                await monitor.suspendedPhase() == .start
            case .none:
                false
            }
            if isSuspended {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for the health monitor \(phase) delay")
    }

    private func settleEventConsumers() async {
        for _ in 0..<100 {
            await Task.yield()
        }
    }
}

private struct HealthStoreFixture {
    let store: EngineStore
    let process: HealthStoreProcessManagerFake
    let controller: HealthStoreControllerManagerFake
    let monitor: HealthStoreHealthMonitorFake

    func finish() async {
        await monitor.finishEvents()
        await controller.finishEvents()
        await process.finishEvents()
    }
}

nonisolated private enum HealthStoreMonitorDelay: Equatable, Sendable {
    case none
    case setApplicationActive
    case start
}

private actor HealthStoreHealthMonitorFake: EngineHealthMonitoring {
    nonisolated private let applicationActivationGate = HealthStoreSynchronousGate()
    private let delay: HealthStoreMonitorDelay
    private var continuation: AsyncStream<EngineHealthReport>.Continuation?
    private var activeContext: EngineHealthCheckContext?
    private var starts = 0
    private var stops = 0
    private var currentSuspendedPhase: HealthStoreMonitorDelay = .none
    private var delayContinuation: CheckedContinuation<Void, Never>?

    init(delay: HealthStoreMonitorDelay) {
        self.delay = delay
    }

    func events() -> AsyncStream<EngineHealthReport> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            self.continuation = continuation
        }
    }

    func start(context: EngineHealthCheckContext) async {
        starts += 1
        if delay == .start {
            currentSuspendedPhase = .start
            await withCheckedContinuation { continuation in
                delayContinuation = continuation
            }
            currentSuspendedPhase = .none
        }
        activeContext = context
    }

    func updateContext(_ context: EngineHealthCheckContext) {
        guard activeContext?.sessionID == context.sessionID else { return }
        activeContext = context
    }

    func trigger(_ trigger: HealthCheckTrigger) {}

    func setApplicationActive(_ active: Bool) {
        if delay == .setApplicationActive {
            applicationActivationGate.block()
        }
    }

    func stop() {
        stops += 1
        activeContext = nil
    }

    func emit(_ report: EngineHealthReport) {
        continuation?.yield(report)
    }

    func activeSessionID() -> UUID? {
        activeContext?.sessionID
    }

    func hasActiveSession() -> Bool {
        activeContext != nil
    }

    func startCallCount() -> Int { starts }
    func stopCallCount() -> Int { stops }
    func suspendedPhase() -> HealthStoreMonitorDelay { currentSuspendedPhase }

    nonisolated func isApplicationActivationSuspended() -> Bool {
        applicationActivationGate.isBlocked
    }

    nonisolated func releaseApplicationActivationDelay() {
        applicationActivationGate.release()
    }

    func releaseStartDelay() {
        let continuation = delayContinuation
        delayContinuation = nil
        continuation?.resume()
    }

    func finishEvents() {
        continuation?.finish()
        continuation = nil
    }
}

nonisolated private final class HealthStoreSynchronousGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false

    var isBlocked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return blocked
    }

    func block() {
        condition.lock()
        blocked = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        blocked = false
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor HealthStoreProfileManagerFake: ProfileManaging {
    private let profile: Profile

    init(profile: Profile) {
        self.profile = profile
    }

    func prepareStorage() throws {}

    func importProfile(from source: URL, name: String?) throws -> Profile {
        profile
    }

    func profiles() throws -> [Profile] {
        [profile]
    }

    func selectedProfileID() throws -> UUID? {
        profile.id
    }

    func selectProfile(id: UUID) throws {}

    func configurationURL(for profileID: UUID) -> URL {
        HealthStoreValues.runtimeConfiguration
    }

    func buildRuntimeConfiguration(
        for profileID: UUID,
        parameters: RuntimeConfigParameters,
        using builder: RuntimeConfigBuilder
    ) throws -> URL {
        HealthStoreValues.runtimeConfiguration
    }
}

nonisolated private struct HealthStoreExecutableResolverFake: MihomoExecutableResolving {
    func resolve() async throws -> ResolvedMihomoExecutable {
        HealthStoreValues.executable
    }
}

nonisolated private struct HealthStoreConfigurationValidatorFake: ConfigurationValidating {
    func validate(
        configurationURL: URL,
        using executable: ResolvedMihomoExecutable,
        timeout: Duration
    ) async -> ConfigurationValidationResult {
        HealthStoreValues.validValidation
    }
}

private actor HealthStoreProcessManagerFake: MihomoProcessManaging {
    private var running = false
    private var starts = 0
    private var stops = 0
    private var continuation: AsyncStream<MihomoProcessEvent>.Continuation?
    private var shouldSuspendNextIsRunning = false
    private var isRunningDidSuspend = false
    private var isRunningContinuation: CheckedContinuation<Void, Never>?

    func start(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration
    ) async throws -> MihomoProcessSnapshot {
        starts += 1
        running = true
        return HealthStoreValues.runningSnapshot
    }

    func stop(timeout: Duration) async throws -> MihomoProcessTermination? {
        stops += 1
        running = false
        return nil
    }

    func restart(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration,
        stopTimeout: Duration
    ) async throws -> MihomoProcessSnapshot {
        _ = try await stop(timeout: stopTimeout)
        return try await start(
            configurationURL: configurationURL,
            dataDirectoryURL: dataDirectoryURL,
            additionalArguments: additionalArguments,
            validationTimeout: validationTimeout
        )
    }

    func isRunning() async -> Bool {
        let result = running
        if shouldSuspendNextIsRunning {
            shouldSuspendNextIsRunning = false
            isRunningDidSuspend = true
            await withCheckedContinuation { continuation in
                isRunningContinuation = continuation
            }
        }
        return result
    }

    func snapshot() -> MihomoProcessSnapshot {
        running ? HealthStoreValues.runningSnapshot : .stopped
    }

    func events() -> AsyncStream<MihomoProcessEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            self.continuation = continuation
        }
    }

    func startCallCount() -> Int { starts }
    func stopCallCount() -> Int { stops }

    func emit(_ event: MihomoProcessEvent) {
        if case .terminated = event {
            running = false
        }
        continuation?.yield(event)
    }

    func suspendNextIsRunningCall() {
        shouldSuspendNextIsRunning = true
        isRunningDidSuspend = false
    }

    func didSuspendIsRunningCall() -> Bool { isRunningDidSuspend }

    func releaseIsRunningCall() {
        let continuation = isRunningContinuation
        isRunningContinuation = nil
        continuation?.resume()
    }

    func finishEvents() {
        continuation?.finish()
        continuation = nil
    }
}

private actor HealthStoreSystemProxyManagerFake: SystemProxyManaging {
    private let suspendRestore: Bool
    private var currentStatus: SystemProxyStatus
    private var restoreDidSuspend = false
    private var restoreContinuation: CheckedContinuation<Void, Never>?

    init(suspendRestore: Bool) {
        self.suspendRestore = suspendRestore
        currentStatus = Self.status(enabled: false)
    }

    func status(for target: SystemProxyTarget) async throws -> SystemProxyStatus {
        currentStatus
    }

    func enable(_ target: SystemProxyTarget) async throws -> SystemProxyEnableResult {
        currentStatus = Self.status(enabled: true)
        return SystemProxyEnableResult(
            status: currentStatus,
            changedServiceNames: ["Wi-Fi"]
        )
    }

    func restore() async throws -> SystemProxyRestoreResult {
        if suspendRestore {
            restoreDidSuspend = true
            await withCheckedContinuation { continuation in
                restoreContinuation = continuation
            }
        }
        currentStatus = Self.status(enabled: false)
        return SystemProxyRestoreResult(
            status: currentStatus,
            restoredServiceNames: ["Wi-Fi"],
            alreadyRestoredServiceNames: [],
            conflictedServiceNames: [],
            missingServiceNames: []
        )
    }

    func didSuspendRestore() -> Bool { restoreDidSuspend }

    func releaseRestore() {
        let continuation = restoreContinuation
        restoreContinuation = nil
        continuation?.resume()
    }

    private nonisolated static func status(enabled: Bool) -> SystemProxyStatus {
        let target = SystemProxyTarget(port: 17_890)
        func endpoint(_ kind: SystemProxyEndpointKind) -> SystemProxyEndpointState {
            SystemProxyEndpointState(
                kind: kind,
                isEnabled: enabled,
                host: enabled ? target.host : nil,
                port: enabled ? target.port : nil
            )
        }
        return SystemProxyStatus(
            target: target,
            aggregate: enabled ? .applied : .disabled,
            services: [SystemProxyServiceState(
                id: "wifi",
                name: "Wi-Fi",
                isServiceEnabled: true,
                http: endpoint(.http),
                https: endpoint(.https),
                socks: endpoint(.socks),
                ownership: enabled ? .managedByVela : .alreadyRestored
            )],
            recovery: enabled ? .managed(serviceNames: ["Wi-Fi"]) : .none
        )
    }
}

private actor HealthStoreControllerManagerFake: MihomoControllerManaging {
    private let suspendApplicationLog: Bool
    private var continuation: AsyncStream<MihomoControllerEvent>.Continuation?
    private var refreshes = 0
    private var applicationLogs = 0
    private var applicationLogDidSuspend = false
    private var applicationLogContinuation: CheckedContinuation<Void, Never>?

    init(suspendApplicationLog: Bool) {
        self.suspendApplicationLog = suspendApplicationLog
    }

    func events() -> AsyncStream<MihomoControllerEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            self.continuation = continuation
        }
    }

    func start() {}
    func refresh() { refreshes += 1 }
    func stop() {}
    func changeMode(_ mode: MihomoMode) throws {}
    func refreshProxies() throws {}
    func selectProxy(group: String, proxy: String) throws {}

    func testProxyDelay(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) throws -> MihomoProxyDelayResult {
        MihomoProxyDelayResult(proxyName: name, delayMilliseconds: 1)
    }

    func testProxyGroupDelay(
        names: [String],
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?,
        concurrencyLimit: Int
    ) throws -> [MihomoProxyDelayResult] {
        names.map { MihomoProxyDelayResult(proxyName: $0, delayMilliseconds: 1) }
    }

    func appendProcessOutput(_ output: MihomoProcessOutput) {}

    func recordApplicationLog(level: LogLevel, message: String) async {
        applicationLogs += 1
        if suspendApplicationLog {
            applicationLogDidSuspend = true
            await withCheckedContinuation { continuation in
                applicationLogContinuation = continuation
            }
        }
    }

    func clearLogs() {}

    func emit(_ event: MihomoControllerEvent) {
        continuation?.yield(event)
    }

    func refreshCallCount() -> Int { refreshes }
    func applicationLogCount() -> Int { applicationLogs }
    func didSuspendApplicationLog() -> Bool { applicationLogDidSuspend }

    func releaseApplicationLog() {
        let continuation = applicationLogContinuation
        applicationLogContinuation = nil
        continuation?.resume()
    }

    func finishEvents() {
        continuation?.finish()
        continuation = nil
    }
}

nonisolated private enum HealthStoreValues {
    static let profile = Profile(
        id: UUID(uuidString: "C985C643-95D7-4ED8-90B3-69CA4353C6A2") ?? UUID(),
        name: "Health Test Profile",
        originalFileName: "health-test.yaml",
        createdAt: Date(timeIntervalSince1970: 1_720_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_720_000_000)
    )
    static let runtimeConfiguration = URL(
        fileURLWithPath: "/tmp/vela-health-store-active.yaml"
    )
    static let executable = ResolvedMihomoExecutable(
        url: URL(fileURLWithPath: "/tmp/vela-health-store-mihomo"),
        version: "Mihomo Meta health-test",
        sha256: String(repeating: "b", count: 64)
    )
    static let dataDirectory = URL(
        fileURLWithPath: "/tmp/vela-health-store-data"
    )
    static let validValidation = ConfigurationValidationResult(
        status: .valid,
        stdout: "configuration is valid",
        stderr: "",
        issues: [],
        duration: .milliseconds(1)
    )
    static let runningSnapshot = MihomoProcessSnapshot(
        pid: 71,
        isRunning: true,
        executable: executable,
        configurationURL: runtimeConfiguration,
        startedAt: Date(timeIntervalSince1970: 1_720_000_001)
    )
    static let controllerSnapshot = MihomoControllerSnapshot(
        version: MihomoVersion(meta: true, version: "1.19.28-health-test"),
        configs: MihomoConfigs(
            port: 0,
            socksPort: 0,
            redirPort: 0,
            tproxyPort: 0,
            mixedPort: 17_890,
            allowLan: false,
            bindAddress: "*",
            mode: .rule,
            logLevel: "info",
            ipv6: true,
            unifiedDelay: false,
            tcpConcurrent: true,
            findProcessMode: "strict",
            interfaceName: "",
            sniffing: false
        )
    )
    static let unexpectedTermination = MihomoProcessTermination(
        pid: 71,
        status: 9,
        reason: .exit,
        expected: false,
        forced: false,
        stdout: "",
        stderr: "unexpected exit",
        startedAt: Date(timeIntervalSince1970: 1_720_000_001),
        endedAt: Date(timeIntervalSince1970: 1_720_000_002)
    )
}
