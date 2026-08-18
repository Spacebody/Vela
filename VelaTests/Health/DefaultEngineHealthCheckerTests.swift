import Foundation
import Testing
@testable import Vela

@Suite("Default engine health checker")
struct DefaultEngineHealthCheckerTests {
    @Test("A complete healthy check preserves the raw system proxy readback")
    func healthyReportAggregatesEveryReadOnlyProbe() async throws {
        let target = SystemProxyTarget(port: UInt16(7_890))
        let fingerprint = RuntimeConfigurationFingerprint(
            url: URL(fileURLWithPath: "/tmp/active.yaml"),
            sha256: "validated",
            byteCount: 42
        )
        let proxyStatus = managedProxyStatus(target: target)
        let systemProxy = HealthSystemProxyFake(status: proxyStatus)
        let checker = DefaultEngineHealthChecker(
            processManager: HealthProcessManagerFake(running: true),
            controllerProbe: HealthControllerProbeFake(reachable: true),
            configurationInspector: HealthConfigurationInspectorFake(
                inspection: .matches(fingerprint)
            ),
            connectivityProbe: HealthConnectivityProbeFake(
                result: ConnectivityProbeResult(
                    networkReachable: true,
                    internetReachable: true,
                    mixedPortListening: true,
                    details: []
                )
            ),
            systemProxyManager: systemProxy,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let context = EngineHealthCheckContext(
            sessionID: UUID(),
            expectedRunning: true,
            configurationFingerprint: fingerprint,
            mixedPort: 7_890,
            systemProxyTarget: target,
            systemProxyExpected: true,
            networkPath: NetworkPathSnapshot(
                status: .satisfied,
                isExpensive: false,
                isConstrained: false
            )
        )

        let report = await checker.check(
            context: context,
            triggers: [.manual],
            sequence: 7
        )

        #expect(report.sessionID == context.sessionID)
        #expect(report.sequence == 7)
        #expect(report.state == .healthy)
        #expect(report.issues.isEmpty)
        #expect(report.checks.count == EngineHealthComponent.allCases.count)
        #expect(report.systemProxyStatus == proxyStatus)
        #expect(report.health.processRunning)
        #expect(report.health.controllerReachable)
        #expect(report.health.configurationValid)
        #expect(report.health.systemProxyApplied)
        #expect(report.health.networkReachable)
        #expect(report.health.internetReachable)
        #expect(report.health.portsListening)
        #expect(await systemProxy.statusCallCount() == 1)
    }

    @Test("A stopped process and residual Vela proxy produce actionable failures")
    func criticalReadbackProducesIssuesWithoutRepair() async throws {
        let target = SystemProxyTarget(port: UInt16(7_890))
        let proxyStatus = managedProxyStatus(target: target)
        let systemProxy = HealthSystemProxyFake(status: proxyStatus)
        let checker = DefaultEngineHealthChecker(
            processManager: HealthProcessManagerFake(running: false),
            controllerProbe: HealthControllerProbeFake(reachable: false),
            configurationInspector: HealthConfigurationInspectorFake(inspection: .notRequired),
            connectivityProbe: HealthConnectivityProbeFake(
                result: ConnectivityProbeResult(
                    networkReachable: false,
                    internetReachable: false,
                    mixedPortListening: false,
                    details: ["offline"]
                )
            ),
            systemProxyManager: systemProxy
        )
        let context = EngineHealthCheckContext(
            sessionID: UUID(),
            expectedRunning: false,
            configurationFingerprint: nil,
            mixedPort: 7_890,
            systemProxyTarget: target,
            systemProxyExpected: false,
            networkPath: .unknown
        )

        let report = await checker.check(context: context, triggers: [.periodic], sequence: 1)

        #expect(report.state == .failed)
        #expect(report.issues.contains {
            $0.component == .systemProxy && $0.severity == .error
        })
        #expect(await systemProxy.enableCallCount() == 0)
        #expect(await systemProxy.restoreCallCount() == 0)
    }

    @Test("A stopped engine still checks independent connectivity")
    func stoppedEngineSkipsConnectivityProbe() async {
        let target = SystemProxyTarget(port: UInt16(7_890))
        let connectivity = CountingHealthConnectivityProbeFake()
        let checker = DefaultEngineHealthChecker(
            processManager: HealthProcessManagerFake(running: false),
            controllerProbe: HealthControllerProbeFake(reachable: false),
            configurationInspector: HealthConfigurationInspectorFake(inspection: .notRequired),
            connectivityProbe: connectivity,
            systemProxyManager: HealthSystemProxyFake(
                status: SystemProxyStatus(
                    target: target,
                    aggregate: .disabled,
                    services: [],
                    recovery: .none
                )
            )
        )
        let context = EngineHealthCheckContext(
            sessionID: UUID(),
            expectedRunning: false,
            configurationFingerprint: nil,
            mixedPort: 7_890,
            systemProxyTarget: target,
            systemProxyExpected: false,
            networkPath: NetworkPathSnapshot(status: .satisfied)
        )

        let report = await checker.check(context: context, triggers: [.periodic], sequence: 1)

        #expect(await connectivity.callCount() == 1)
        #expect(report.checks.first { $0.component == .mixedPort }?.state == .skipped)
        #expect(report.checks.first { $0.component == .networkPath }?.state == .passing)
        #expect(report.checks.first { $0.component == .internet }?.state == .degraded)
    }

    @Test("An untracked external proxy on Vela's port is not claimed as residual Vela state")
    func externalMatchingTargetPreservesOwnershipBoundary() async {
        let target = SystemProxyTarget(port: UInt16(7_890))
        let fingerprint = RuntimeConfigurationFingerprint(
            url: URL(fileURLWithPath: "/tmp/active.yaml"),
            sha256: "validated",
            byteCount: 42
        )
        func endpoint(_ kind: SystemProxyEndpointKind) -> SystemProxyEndpointState {
            SystemProxyEndpointState(
                kind: kind,
                isEnabled: true,
                host: target.host,
                port: target.port
            )
        }
        let externalStatus = SystemProxyStatus(
            target: target,
            aggregate: .externallyConfigured,
            services: [
                SystemProxyServiceState(
                    id: "wifi",
                    name: "Wi-Fi",
                    isServiceEnabled: true,
                    http: endpoint(.http),
                    https: endpoint(.https),
                    socks: endpoint(.socks),
                    ownership: .untracked
                )
            ],
            recovery: .none
        )
        let checker = DefaultEngineHealthChecker(
            processManager: HealthProcessManagerFake(running: true),
            controllerProbe: HealthControllerProbeFake(reachable: true),
            configurationInspector: HealthConfigurationInspectorFake(
                inspection: .matches(fingerprint)
            ),
            connectivityProbe: HealthConnectivityProbeFake(
                result: ConnectivityProbeResult(
                    networkReachable: true,
                    internetReachable: true,
                    mixedPortListening: true,
                    details: []
                )
            ),
            systemProxyManager: HealthSystemProxyFake(status: externalStatus)
        )
        let report = await checker.check(
            context: EngineHealthCheckContext(
                sessionID: UUID(),
                expectedRunning: true,
                configurationFingerprint: fingerprint,
                mixedPort: 7_890,
                systemProxyTarget: target,
                systemProxyExpected: false,
                networkPath: NetworkPathSnapshot(status: .satisfied)
            ),
            triggers: [.manual],
            sequence: 1
        )

        #expect(!report.issues.contains { $0.component == .systemProxy })
        #expect(report.checks.first { $0.component == .systemProxy }?.state == .passing)
    }
}

private nonisolated func managedProxyStatus(target: SystemProxyTarget) -> SystemProxyStatus {
    func endpoint(_ kind: SystemProxyEndpointKind) -> SystemProxyEndpointState {
        SystemProxyEndpointState(
            kind: kind,
            isEnabled: true,
            host: target.host,
            port: target.port
        )
    }
    return SystemProxyStatus(
        target: target,
        aggregate: .applied,
        services: [
            SystemProxyServiceState(
                id: "wifi",
                name: "Wi-Fi",
                isServiceEnabled: true,
                http: endpoint(.http),
                https: endpoint(.https),
                socks: endpoint(.socks),
                ownership: .managedByVela
            )
        ],
        recovery: .managed(serviceNames: ["Wi-Fi"])
    )
}

private actor HealthProcessManagerFake: MihomoProcessManaging {
    private let running: Bool

    init(running: Bool) { self.running = running }

    func start(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration
    ) async throws -> MihomoProcessSnapshot { .stopped }

    func stop(timeout: Duration) async throws -> MihomoProcessTermination? { nil }

    func restart(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration,
        stopTimeout: Duration
    ) async throws -> MihomoProcessSnapshot { .stopped }

    func isRunning() async -> Bool { running }
    func snapshot() async -> MihomoProcessSnapshot { .stopped }
    func events() async -> AsyncStream<MihomoProcessEvent> { AsyncStream { $0.finish() } }
}

private struct HealthControllerProbeFake: ControllerHealthProbing {
    let reachable: Bool

    func probe() async -> ControllerHealthProbeResult {
        ControllerHealthProbeResult(
            reachable: reachable,
            version: reachable ? "test" : nil,
            details: reachable ? nil : "unreachable",
            timedOut: false,
            duration: .milliseconds(1)
        )
    }
}

private struct HealthConfigurationInspectorFake: RuntimeConfigurationInspecting {
    let inspection: RuntimeConfigurationInspection

    func fingerprint(at url: URL) async throws -> RuntimeConfigurationFingerprint {
        RuntimeConfigurationFingerprint(url: url, sha256: "fake", byteCount: 1)
    }

    func inspect(expected: RuntimeConfigurationFingerprint) async -> RuntimeConfigurationInspection {
        inspection
    }
}

private struct HealthConnectivityProbeFake: ConnectivityProbing {
    let result: ConnectivityProbeResult

    func probe(
        networkPath: NetworkPathSnapshot,
        host: String,
        mixedPort: UInt16
    ) async -> ConnectivityProbeResult {
        result
    }
}

private actor CountingHealthConnectivityProbeFake: ConnectivityProbing {
    private var calls = 0

    func probe(
        networkPath: NetworkPathSnapshot,
        host: String,
        mixedPort: UInt16
    ) async -> ConnectivityProbeResult {
        calls += 1
        return ConnectivityProbeResult(
            networkReachable: false,
            internetReachable: false,
            mixedPortListening: false,
            details: []
        )
    }

    func callCount() -> Int { calls }
}

private actor HealthSystemProxyFake: SystemProxyManaging {
    private let storedStatus: SystemProxyStatus
    private var statusCalls = 0
    private var enableCalls = 0
    private var restoreCalls = 0

    init(status: SystemProxyStatus) { storedStatus = status }

    func status(for target: SystemProxyTarget) async throws -> SystemProxyStatus {
        statusCalls += 1
        return storedStatus
    }

    func enable(_ target: SystemProxyTarget) async throws -> SystemProxyEnableResult {
        enableCalls += 1
        return SystemProxyEnableResult(status: storedStatus, changedServiceNames: [])
    }

    func restore() async throws -> SystemProxyRestoreResult {
        restoreCalls += 1
        return SystemProxyRestoreResult(
            status: storedStatus,
            restoredServiceNames: [],
            alreadyRestoredServiceNames: [],
            conflictedServiceNames: [],
            missingServiceNames: []
        )
    }

    func statusCallCount() -> Int { statusCalls }
    func enableCallCount() -> Int { enableCalls }
    func restoreCallCount() -> Int { restoreCalls }
}
