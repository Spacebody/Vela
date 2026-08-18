import Foundation

nonisolated enum EngineHealthState: String, Equatable, Sendable {
    case unknown
    case healthy
    case degraded
    case failed
}

nonisolated struct EngineHealth: Equatable, Sendable {
    let processRunning: Bool
    let controllerReachable: Bool
    let configurationValid: Bool
    let systemProxyApplied: Bool
    let networkReachable: Bool
    let internetReachable: Bool
    let portsListening: Bool
    let lastCheckedAt: Date
    let overallState: EngineHealthState

    init(
        processRunning: Bool,
        controllerReachable: Bool,
        configurationValid: Bool,
        systemProxyApplied: Bool,
        networkReachable: Bool,
        internetReachable: Bool,
        portsListening: Bool,
        lastCheckedAt: Date,
        overallState: EngineHealthState
    ) {
        self.processRunning = processRunning
        self.controllerReachable = controllerReachable
        self.configurationValid = configurationValid
        self.systemProxyApplied = systemProxyApplied
        self.networkReachable = networkReachable
        self.internetReachable = internetReachable
        self.portsListening = portsListening
        self.lastCheckedAt = lastCheckedAt
        self.overallState = overallState
    }

    static func sprintOne(processRunning: Bool, configurationValid: Bool) -> EngineHealth {
        EngineHealth(
            processRunning: processRunning,
            controllerReachable: false,
            configurationValid: configurationValid,
            systemProxyApplied: false,
            networkReachable: false,
            internetReachable: false,
            portsListening: false,
            lastCheckedAt: .now,
            overallState: processRunning ? .degraded : .failed
        )
    }

    static func sprintTwo(
        processRunning: Bool,
        controllerReachable: Bool,
        configurationValid: Bool,
        systemProxyApplied: Bool = false
    ) -> EngineHealth {
        EngineHealth(
            processRunning: processRunning,
            controllerReachable: controllerReachable,
            configurationValid: configurationValid,
            systemProxyApplied: systemProxyApplied,
            networkReachable: false,
            internetReachable: false,
            portsListening: false,
            lastCheckedAt: .now,
            overallState: processRunning ? .degraded : .failed
        )
    }
}
