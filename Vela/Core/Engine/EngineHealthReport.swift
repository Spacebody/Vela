import Foundation

nonisolated enum HealthCheckTrigger: String, CaseIterable, Equatable, Hashable, Sendable {
    case startup
    case periodic
    case manual
    case applicationActivated
    case networkChanged
    case wokeFromSleep
}

nonisolated enum HealthCheckState: String, Equatable, Sendable {
    case passing
    case degraded
    case failing
    case unknown
    case skipped
}

nonisolated enum EngineHealthComponent: String, CaseIterable, Equatable, Sendable {
    case process
    case controller
    case configuration
    case mixedPort
    case systemProxy
    case networkPath
    case internet
}

nonisolated enum EngineHealthIssueSeverity: String, Equatable, Sendable {
    case warning
    case error
}

nonisolated struct EngineHealthCheck: Equatable, Sendable, Identifiable {
    var id: EngineHealthComponent { component }

    let component: EngineHealthComponent
    let state: HealthCheckState
    let summary: String
    let technicalDetails: String?
}

nonisolated struct EngineHealthIssue: Equatable, Sendable, Identifiable {
    let id: String
    let component: EngineHealthComponent
    let severity: EngineHealthIssueSeverity
    let summary: String
    let technicalDetails: String?
    let suggestedAction: String

    init(
        component: EngineHealthComponent,
        severity: EngineHealthIssueSeverity,
        summary: String,
        technicalDetails: String? = nil,
        suggestedAction: String
    ) {
        id = "\(component.rawValue):\(summary)"
        self.component = component
        self.severity = severity
        self.summary = summary
        self.technicalDetails = technicalDetails
        self.suggestedAction = suggestedAction
    }
}

nonisolated struct EngineHealthCheckContext: Equatable, Sendable {
    let sessionID: UUID
    let expectedRunning: Bool
    let configurationFingerprint: RuntimeConfigurationFingerprint?
    let mixedPort: UInt16
    let systemProxyTarget: SystemProxyTarget
    let systemProxyExpected: Bool
    let networkPath: NetworkPathSnapshot

    init(
        sessionID: UUID,
        expectedRunning: Bool,
        configurationFingerprint: RuntimeConfigurationFingerprint?,
        mixedPort: UInt16,
        systemProxyTarget: SystemProxyTarget,
        systemProxyExpected: Bool,
        networkPath: NetworkPathSnapshot
    ) {
        self.sessionID = sessionID
        self.expectedRunning = expectedRunning
        self.configurationFingerprint = configurationFingerprint
        self.mixedPort = mixedPort
        self.systemProxyTarget = systemProxyTarget
        self.systemProxyExpected = systemProxyExpected
        self.networkPath = networkPath
    }
}

nonisolated struct EngineHealthReport: Equatable, Sendable {
    let sessionID: UUID
    let sequence: UInt64
    let triggers: [HealthCheckTrigger]
    let health: EngineHealth
    let systemProxyStatus: SystemProxyStatus?
    let checks: [EngineHealthCheck]
    let issues: [EngineHealthIssue]
    let startedAt: Date
    let completedAt: Date

    var state: EngineHealthState {
        health.overallState
    }
}

nonisolated struct ControllerHealthProbeResult: Equatable, Sendable {
    let reachable: Bool
    let version: String?
    let details: String?
    let timedOut: Bool
    let duration: Duration
}

nonisolated protocol ControllerHealthProbing: Sendable {
    func probe() async -> ControllerHealthProbeResult
}

actor ControllerHealthProbe: ControllerHealthProbing {
    private enum ProbeOutcome: Sendable {
        case reachable(String)
        case failed(String)
        case timedOut
    }

    private let apiClient: any MihomoAPIProviding
    private let timeout: Duration

    init(
        apiClient: any MihomoAPIProviding,
        timeout: Duration = .seconds(1)
    ) {
        self.apiClient = apiClient
        self.timeout = timeout
    }

    init(
        baseURL: URL,
        secret: String,
        session: any URLSessionProviding = URLSession.shared,
        requestTimeout: TimeInterval = 0.75,
        timeout: Duration = .seconds(1)
    ) {
        apiClient = MihomoAPIClient(
            baseURL: baseURL,
            secret: secret,
            session: session,
            retryPolicy: MihomoRetryPolicy(maximumRetryCount: 0, retryDelay: .zero),
            requestTimeout: requestTimeout
        )
        self.timeout = timeout
    }

    func probe() async -> ControllerHealthProbeResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let apiClient = self.apiClient
        let timeout = self.timeout

        let outcome = await withTaskGroup(of: ProbeOutcome.self) { group in
            group.addTask {
                do {
                    let version = try await apiClient.version()
                    try Task.checkCancellation()
                    return .reachable(version.version)
                } catch is CancellationError {
                    return .failed("Controller probe was cancelled.")
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .failed("Controller probe was cancelled.")
                }
            }

            let first = await group.next() ?? .failed("Controller probe produced no result.")
            group.cancelAll()
            return first
        }

        let duration = startedAt.duration(to: clock.now)
        switch outcome {
        case let .reachable(version):
            return ControllerHealthProbeResult(
                reachable: true,
                version: version,
                details: nil,
                timedOut: false,
                duration: duration
            )
        case let .failed(details):
            return ControllerHealthProbeResult(
                reachable: false,
                version: nil,
                details: details,
                timedOut: false,
                duration: duration
            )
        case .timedOut:
            return ControllerHealthProbeResult(
                reachable: false,
                version: nil,
                details: "Controller probe exceeded its timeout.",
                timedOut: true,
                duration: duration
            )
        }
    }
}

nonisolated protocol EngineHealthChecking: Sendable {
    func check(
        context: EngineHealthCheckContext,
        triggers: [HealthCheckTrigger],
        sequence: UInt64
    ) async -> EngineHealthReport
}

nonisolated struct DefaultEngineHealthChecker: EngineHealthChecking, Sendable {
    private let processManager: any MihomoProcessManaging
    private let controllerProbe: any ControllerHealthProbing
    private let configurationInspector: any RuntimeConfigurationInspecting
    private let connectivityProbe: any ConnectivityProbing
    private let systemProxyManager: (any SystemProxyManaging)?
    private let now: @Sendable () -> Date

    init(
        processManager: any MihomoProcessManaging,
        controllerProbe: any ControllerHealthProbing,
        configurationInspector: any RuntimeConfigurationInspecting,
        connectivityProbe: any ConnectivityProbing,
        systemProxyManager: (any SystemProxyManaging)?,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.processManager = processManager
        self.controllerProbe = controllerProbe
        self.configurationInspector = configurationInspector
        self.connectivityProbe = connectivityProbe
        self.systemProxyManager = systemProxyManager
        self.now = now
    }

    func check(
        context: EngineHealthCheckContext,
        triggers: [HealthCheckTrigger],
        sequence: UInt64
    ) async -> EngineHealthReport {
        let startedAt = now()

        async let processRunningValue = processManager.isRunning()
        async let controllerValue = probeController(expected: context.expectedRunning)
        async let configurationValue = inspectConfiguration(
            expected: context.configurationFingerprint,
            expectedRunning: context.expectedRunning
        )
        async let connectivityValue = probeConnectivity(
            context: context
        )
        async let systemProxyValue = probeSystemProxy(target: context.systemProxyTarget)

        let processRunning = await processRunningValue
        let controller = await controllerValue
        let configuration = await configurationValue
        let connectivity = await connectivityValue
        let systemProxy = await systemProxyValue

        var checks: [EngineHealthCheck] = []
        var issues: [EngineHealthIssue] = []

        appendProcessCheck(
            processRunning: processRunning,
            expectedRunning: context.expectedRunning,
            checks: &checks,
            issues: &issues
        )
        appendControllerCheck(
            controller,
            expectedRunning: context.expectedRunning,
            checks: &checks,
            issues: &issues
        )
        appendConfigurationCheck(
            configuration,
            expectedRunning: context.expectedRunning,
            checks: &checks,
            issues: &issues
        )
        appendConnectivityChecks(
            connectivity,
            networkPath: context.networkPath,
            expectedRunning: context.expectedRunning,
            checks: &checks,
            issues: &issues
        )
        let systemProxyApplied = appendSystemProxyCheck(
            systemProxy,
            context: context,
            checks: &checks,
            issues: &issues
        )

        checks.sort { lhs, rhs in
            Self.componentOrder(lhs.component) < Self.componentOrder(rhs.component)
        }
        issues.sort { lhs, rhs in
            Self.componentOrder(lhs.component) < Self.componentOrder(rhs.component)
        }

        let overallState: EngineHealthState
        if issues.contains(where: { $0.severity == .error }) {
            overallState = .failed
        } else if !issues.isEmpty || checks.contains(where: { $0.state == .unknown }) {
            overallState = .degraded
        } else {
            overallState = .healthy
        }

        let completedAt = now()
        let health = EngineHealth(
            processRunning: processRunning,
            controllerReachable: controller.reachable,
            configurationValid: configuration.isMatch,
            systemProxyApplied: systemProxyApplied,
            networkReachable: connectivity.networkReachable,
            internetReachable: connectivity.internetReachable,
            portsListening: connectivity.mixedPortListening,
            lastCheckedAt: completedAt,
            overallState: overallState
        )

        return EngineHealthReport(
            sessionID: context.sessionID,
            sequence: sequence,
            triggers: Self.orderedTriggers(triggers),
            health: health,
            systemProxyStatus: systemProxy.status,
            checks: checks,
            issues: issues,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func probeController(expected: Bool) async -> ControllerHealthProbeResult {
        guard expected else {
            return ControllerHealthProbeResult(
                reachable: false,
                version: nil,
                details: "Mihomo is not expected to be running.",
                timedOut: false,
                duration: .zero
            )
        }
        return await controllerProbe.probe()
    }

    private func inspectConfiguration(
        expected: RuntimeConfigurationFingerprint?,
        expectedRunning: Bool
    ) async -> RuntimeConfigurationInspection {
        guard expectedRunning else {
            return .notRequired
        }
        guard let expected else {
            return .unavailable("No validated runtime configuration fingerprint is available.")
        }
        return await configurationInspector.inspect(expected: expected)
    }

    private func probeConnectivity(
        context: EngineHealthCheckContext
    ) async -> ConnectivityProbeResult {
        let result = await connectivityProbe.probe(
            networkPath: context.networkPath,
            host: context.systemProxyTarget.host,
            mixedPort: context.mixedPort
        )
        guard !context.expectedRunning else { return result }

        return ConnectivityProbeResult(
            networkReachable: result.networkReachable,
            internetReachable: result.internetReachable,
            mixedPortListening: false,
            details: Array(result.details.prefix(2))
        )
    }

    private func probeSystemProxy(target: SystemProxyTarget) async -> SystemProxyProbeOutcome {
        guard let systemProxyManager else {
            return .unavailable("System proxy management is unavailable.")
        }
        do {
            return .status(try await systemProxyManager.status(for: target))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func appendProcessCheck(
        processRunning: Bool,
        expectedRunning: Bool,
        checks: inout [EngineHealthCheck],
        issues: inout [EngineHealthIssue]
    ) {
        if expectedRunning, processRunning {
            checks.append(.init(
                component: .process,
                state: .passing,
                summary: "The managed Mihomo process is running.",
                technicalDetails: nil
            ))
        } else if expectedRunning {
            checks.append(.init(
                component: .process,
                state: .failing,
                summary: "The managed Mihomo process is not running.",
                technicalDetails: nil
            ))
            issues.append(.init(
                component: .process,
                severity: .error,
                summary: "Mihomo stopped unexpectedly.",
                suggestedAction: "Restart Mihomo and review its recent logs."
            ))
        } else if processRunning {
            checks.append(.init(
                component: .process,
                state: .degraded,
                summary: "Mihomo is running when Vela expects it to be stopped.",
                technicalDetails: nil
            ))
            issues.append(.init(
                component: .process,
                severity: .warning,
                summary: "An unexpected managed process is still running.",
                suggestedAction: "Use Stop before starting another Mihomo process."
            ))
        } else {
            checks.append(.init(
                component: .process,
                state: .passing,
                summary: "Mihomo is stopped as expected.",
                technicalDetails: nil
            ))
        }
    }

    private func appendControllerCheck(
        _ result: ControllerHealthProbeResult,
        expectedRunning: Bool,
        checks: inout [EngineHealthCheck],
        issues: inout [EngineHealthIssue]
    ) {
        guard expectedRunning else {
            checks.append(.init(
                component: .controller,
                state: .skipped,
                summary: "Controller probe is not required while Mihomo is stopped.",
                technicalDetails: nil
            ))
            return
        }
        checks.append(.init(
            component: .controller,
            state: result.reachable ? .passing : .degraded,
            summary: result.reachable
                ? "The Mihomo Controller is reachable."
                : "The Mihomo Controller is unavailable.",
            technicalDetails: result.details
        ))
        if !result.reachable {
            issues.append(.init(
                component: .controller,
                severity: .warning,
                summary: result.timedOut
                    ? "Controller health probe timed out."
                    : "Controller health probe failed.",
                technicalDetails: result.details,
                suggestedAction: "Wait for Mihomo to finish starting, then refresh health."
            ))
        }
    }

    private func appendConfigurationCheck(
        _ inspection: RuntimeConfigurationInspection,
        expectedRunning: Bool,
        checks: inout [EngineHealthCheck],
        issues: inout [EngineHealthIssue]
    ) {
        guard expectedRunning else {
            checks.append(.init(
                component: .configuration,
                state: .skipped,
                summary: "Runtime configuration inspection is not required while stopped.",
                technicalDetails: nil
            ))
            return
        }

        checks.append(.init(
            component: .configuration,
            state: inspection.checkState,
            summary: inspection.summary,
            technicalDetails: inspection.technicalDetails
        ))
        if !inspection.isMatch {
            issues.append(.init(
                component: .configuration,
                severity: .warning,
                summary: inspection.summary,
                technicalDetails: inspection.technicalDetails,
                suggestedAction: "Validate the selected profile before the next restart."
            ))
        }
    }

    private func appendConnectivityChecks(
        _ result: ConnectivityProbeResult,
        networkPath: NetworkPathSnapshot,
        expectedRunning: Bool,
        checks: inout [EngineHealthCheck],
        issues: inout [EngineHealthIssue]
    ) {
        let details = result.details.isEmpty ? nil : result.details.joined(separator: "\n")
        if expectedRunning {
            checks.append(.init(
                component: .mixedPort,
                state: result.mixedPortListening ? .passing : .degraded,
                summary: result.mixedPortListening
                    ? "The mixed proxy port is accepting TCP connections."
                    : "The mixed proxy port is not accepting connections.",
                technicalDetails: details
            ))
            if !result.mixedPortListening {
                issues.append(.init(
                    component: .mixedPort,
                    severity: .warning,
                    summary: "Mihomo's mixed port is not listening.",
                    technicalDetails: details,
                    suggestedAction: "Check the active runtime configuration and Mihomo logs."
                ))
            }
        } else {
            checks.append(.init(
                component: .mixedPort,
                state: .skipped,
                summary: "The mixed-port probe is not required while Mihomo is stopped.",
                technicalDetails: nil
            ))
        }

        let pathState: HealthCheckState = switch networkPath.status {
        case .satisfied: .passing
        case .unknown: .unknown
        case .unsatisfied, .requiresConnection: .degraded
        }
        let pathSummary = switch networkPath.status {
        case .satisfied:
            "A network path is available."
        case .unknown:
            "The initial network path is still being determined."
        case .unsatisfied, .requiresConnection:
            "No usable network path is available."
        }
        checks.append(.init(
            component: .networkPath,
            state: pathState,
            summary: pathSummary,
            technicalDetails: "NWPath status: \(networkPath.status.rawValue)"
        ))
        if networkPath.status == .unsatisfied || networkPath.status == .requiresConnection {
            issues.append(.init(
                component: .networkPath,
                severity: .warning,
                summary: "The network is currently unavailable.",
                technicalDetails: details,
                suggestedAction: "Reconnect Wi-Fi or another network interface."
            ))
        }

        let internetState: HealthCheckState = switch networkPath.status {
        case .satisfied:
            result.internetReachable ? .passing : .degraded
        case .unknown:
            .unknown
        case .unsatisfied, .requiresConnection:
            .skipped
        }
        let internetSummary = switch networkPath.status {
        case .satisfied:
            result.internetReachable
                ? "Internet connectivity is available."
                : "Internet connectivity could not be verified."
        case .unknown:
            "Internet connectivity is waiting for the initial network path."
        case .unsatisfied, .requiresConnection:
            "Internet connectivity requires a usable network path."
        }
        checks.append(.init(
            component: .internet,
            state: internetState,
            summary: internetSummary,
            technicalDetails: details
        ))
        if result.networkReachable, !result.internetReachable {
            issues.append(.init(
                component: .internet,
                severity: .warning,
                summary: "The network is up, but Internet connectivity failed.",
                technicalDetails: details,
                suggestedAction: "Check the selected proxy and upstream network."
            ))
        }
    }

    @discardableResult
    private func appendSystemProxyCheck(
        _ outcome: SystemProxyProbeOutcome,
        context: EngineHealthCheckContext,
        checks: inout [EngineHealthCheck],
        issues: inout [EngineHealthIssue]
    ) -> Bool {
        switch outcome {
        case let .unavailable(details):
            checks.append(.init(
                component: .systemProxy,
                state: .unknown,
                summary: "System proxy state could not be read.",
                technicalDetails: details
            ))
            if context.systemProxyExpected {
                issues.append(.init(
                    component: .systemProxy,
                    severity: .warning,
                    summary: "Vela could not verify the expected system proxy.",
                    technicalDetails: details,
                    suggestedAction: "Refresh health and review macOS Network settings."
                ))
            }
            return false

        case let .status(status):
            let isManaged: Bool
            if case .managed = status.recovery {
                isManaged = true
            } else {
                isManaged = false
            }
            let applied = status.aggregate == .applied && isManaged
            let visibleTargetServices = status.services.compactMap { service in
                service.endpoints.contains { $0.matches(context.systemProxyTarget) }
                    ? service.name
                    : nil
            }.sorted()
            let managedTargetServices = status.services.compactMap { service in
                service.ownership == .managedByVela
                    && service.endpoints.contains { $0.matches(context.systemProxyTarget) }
                    ? service.name
                    : nil
            }.sorted()

            if context.systemProxyExpected, applied {
                checks.append(.init(
                    component: .systemProxy,
                    state: .passing,
                    summary: "The Vela-owned system proxy matches the runtime port.",
                    technicalDetails: nil
                ))
            } else if context.systemProxyExpected {
                checks.append(.init(
                    component: .systemProxy,
                    state: .degraded,
                    summary: "The expected Vela system proxy is not fully applied.",
                    technicalDetails: visibleTargetServices.nilIfEmpty
                ))
                issues.append(.init(
                    component: .systemProxy,
                    severity: .warning,
                    summary: "System proxy state differs from Vela's expectation.",
                    technicalDetails: visibleTargetServices.nilIfEmpty,
                    suggestedAction: "Use Restore or Enable System Proxy after reviewing the affected services."
                ))
            } else if !managedTargetServices.isEmpty {
                let names = managedTargetServices.joined(separator: ", ")
                checks.append(.init(
                    component: .systemProxy,
                    state: .failing,
                    summary: "System proxy still points to Vela while it is expected off.",
                    technicalDetails: names
                ))
                issues.append(.init(
                    component: .systemProxy,
                    severity: .error,
                    summary: "Residual Vela proxy endpoints are visible.",
                    technicalDetails: names,
                    suggestedAction: "Restore System Proxy before stopping Mihomo."
                ))
            } else if status.recovery != .none {
                checks.append(.init(
                    component: .systemProxy,
                    state: .degraded,
                    summary: "System proxy recovery data still requires attention.",
                    technicalDetails: nil
                ))
                issues.append(.init(
                    component: .systemProxy,
                    severity: .warning,
                    summary: "A system proxy recovery lease remains.",
                    suggestedAction: "Reconnect missing services and retry Restore System Proxy."
                ))
            } else if !visibleTargetServices.isEmpty {
                checks.append(.init(
                    component: .systemProxy,
                    state: .passing,
                    summary: "An external system proxy points to the runtime port without Vela ownership.",
                    technicalDetails: visibleTargetServices.joined(separator: ", ")
                ))
            } else {
                checks.append(.init(
                    component: .systemProxy,
                    state: .passing,
                    summary: "Vela does not own an active system proxy.",
                    technicalDetails: nil
                ))
            }
            return applied
        }
    }

    private static func componentOrder(_ component: EngineHealthComponent) -> Int {
        EngineHealthComponent.allCases.firstIndex(of: component) ?? .max
    }

    private static func orderedTriggers(_ triggers: [HealthCheckTrigger]) -> [HealthCheckTrigger] {
        let values = Set(triggers)
        return HealthCheckTrigger.allCases.filter(values.contains)
    }
}

nonisolated private enum SystemProxyProbeOutcome: Sendable {
    case status(SystemProxyStatus)
    case unavailable(String)
}

nonisolated private extension SystemProxyProbeOutcome {
    var status: SystemProxyStatus? {
        if case let .status(value) = self { return value }
        return nil
    }
}

nonisolated private extension Array where Element == String {
    var nilIfEmpty: String? {
        isEmpty ? nil : joined(separator: ", ")
    }
}
