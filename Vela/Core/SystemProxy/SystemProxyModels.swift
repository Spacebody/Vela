import Foundation

nonisolated protocol SystemProxyManaging: Actor {
    func status(for target: SystemProxyTarget) async throws -> SystemProxyStatus
    func enable(_ target: SystemProxyTarget) async throws -> SystemProxyEnableResult
    func restore() async throws -> SystemProxyRestoreResult
}

nonisolated struct SystemProxyTarget: Codable, Equatable, Sendable {
    let host: String
    let port: Int

    init(host: String = "127.0.0.1", port: Int) {
        self.host = host
        self.port = port
    }

    init(host: String = "127.0.0.1", port: UInt16) {
        self.host = host
        self.port = Int(port)
    }
}

nonisolated enum SystemProxyEndpointKind: String, CaseIterable, Codable, Sendable {
    case http
    case https
    case socks
}

nonisolated struct SystemProxyEndpointState: Equatable, Sendable {
    let kind: SystemProxyEndpointKind
    let isEnabled: Bool
    let host: String?
    let port: Int?

    func matches(_ target: SystemProxyTarget) -> Bool {
        isEnabled && host == target.host && port == target.port
    }
}

nonisolated enum SystemProxyServiceOwnership: Equatable, Sendable {
    case untracked
    case managedByVela
    case alreadyRestored
    case externallyModified
}

nonisolated struct SystemProxyAutomaticConfigurationState: Equatable, Sendable {
    let isAutoConfigurationEnabled: Bool
    let autoConfigurationURL: String?
    let isAutoDiscoveryEnabled: Bool

    var isEnabled: Bool {
        isAutoConfigurationEnabled || isAutoDiscoveryEnabled
    }

    static let disabled = SystemProxyAutomaticConfigurationState(
        isAutoConfigurationEnabled: false,
        autoConfigurationURL: nil,
        isAutoDiscoveryEnabled: false
    )
}

nonisolated struct SystemProxyServiceState: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let isServiceEnabled: Bool
    let http: SystemProxyEndpointState
    let https: SystemProxyEndpointState
    let socks: SystemProxyEndpointState
    let automatic: SystemProxyAutomaticConfigurationState
    let ownership: SystemProxyServiceOwnership

    init(
        id: String,
        name: String,
        isServiceEnabled: Bool,
        http: SystemProxyEndpointState,
        https: SystemProxyEndpointState,
        socks: SystemProxyEndpointState,
        automatic: SystemProxyAutomaticConfigurationState = .disabled,
        ownership: SystemProxyServiceOwnership
    ) {
        self.id = id
        self.name = name
        self.isServiceEnabled = isServiceEnabled
        self.http = http
        self.https = https
        self.socks = socks
        self.automatic = automatic
        self.ownership = ownership
    }

    var endpoints: [SystemProxyEndpointState] {
        [http, https, socks]
    }
}

nonisolated enum SystemProxyAggregateState: Equatable, Sendable {
    case unavailable
    case disabled
    case applied
    case partiallyApplied
    case externallyConfigured
}

nonisolated enum SystemProxyRecoveryState: Equatable, Sendable {
    case none
    case managed(serviceNames: [String])
    case recoveryRequired(serviceNames: [String])
}

nonisolated struct SystemProxyStatus: Equatable, Sendable {
    let target: SystemProxyTarget
    let aggregate: SystemProxyAggregateState
    let services: [SystemProxyServiceState]
    let recovery: SystemProxyRecoveryState
}

nonisolated struct SystemProxyEnableResult: Equatable, Sendable {
    let status: SystemProxyStatus
    let changedServiceNames: [String]
}

nonisolated struct SystemProxyRestoreResult: Equatable, Sendable {
    let status: SystemProxyStatus
    let restoredServiceNames: [String]
    let alreadyRestoredServiceNames: [String]
    let conflictedServiceNames: [String]
    let missingServiceNames: [String]
}

nonisolated enum SystemProxyManagerError: Error, Equatable, Sendable {
    case invalidTarget(host: String, port: Int)
    case noActiveNetworkServices
    case recoveryLeaseTargetMismatch(expected: SystemProxyTarget, requested: SystemProxyTarget)
    case externallyModified(serviceNames: [String])
    case targetAlreadyConfiguredExternally(serviceNames: [String])
    case automaticConfigurationEnabled(serviceNames: [String])
    case enableRejectedBeforeCommit(reason: String, recoveryCleanupReason: String?)
    case enableFailed(reason: String, rollbackReason: String?)
    case enableVerificationFailed(serviceNames: [String], rollbackReason: String?)
    case restoreFailed(serviceNames: [String], reason: String)
    case restoreVerificationFailed(serviceNames: [String])
}

extension SystemProxyManagerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidTarget(host, port):
            return "Invalid system proxy target \(host):\(port)."
        case .noActiveNetworkServices:
            return "No enabled network services are available for system proxy configuration."
        case let .recoveryLeaseTargetMismatch(expected, requested):
            return "System proxy recovery data belongs to \(expected.host):\(expected.port), not \(requested.host):\(requested.port). Restore it before enabling a different target."
        case let .externallyModified(serviceNames):
            return "System proxy settings were modified outside Vela for: \(serviceNames.joined(separator: ", "))."
        case let .targetAlreadyConfiguredExternally(serviceNames):
            return "The Vela proxy target is already configured outside Vela for: \(serviceNames.joined(separator: ", ")). Vela will not claim or overwrite those settings."
        case let .automaticConfigurationEnabled(serviceNames):
            return "Disable automatic proxy configuration or auto-discovery before enabling Vela for: \(serviceNames.joined(separator: ", "))."
        case let .enableRejectedBeforeCommit(reason, recoveryCleanupReason):
            if let recoveryCleanupReason {
                return "System proxy settings changed before Vela could commit: \(reason). No proxy settings were written, but recovery metadata cleanup failed: \(recoveryCleanupReason)"
            }
            return "System proxy settings changed before Vela could commit: \(reason). No proxy settings were written."
        case let .enableFailed(reason, rollbackReason):
            if let rollbackReason {
                return "Could not enable the system proxy: \(reason). Rollback also failed: \(rollbackReason)"
            } else {
                return "Could not enable the system proxy: \(reason). The original settings were restored."
            }
        case let .enableVerificationFailed(serviceNames, rollbackReason):
            let names = serviceNames.joined(separator: ", ")
            if let rollbackReason {
                return "System proxy verification failed for \(names). Rollback also failed: \(rollbackReason)"
            } else {
                return "System proxy verification failed for \(names). The original settings were restored."
            }
        case let .restoreFailed(serviceNames, reason):
            return "Could not restore system proxy settings for \(serviceNames.joined(separator: ", ")): \(reason)"
        case let .restoreVerificationFailed(serviceNames):
            return "System proxy restoration could not be verified for: \(serviceNames.joined(separator: ", "))."
        }
    }
}
