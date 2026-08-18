import Foundation

public struct HelperHandshakeRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "clientProtocolMinimum", "clientProtocolMaximum",
        "clientVersion", "clientBuild", "requestedSessionID",
    ]

    public let schemaVersion: Int
    public let requestID: UUID
    public let clientProtocolMinimum: Int
    public let clientProtocolMaximum: Int
    public let clientVersion: String
    public let clientBuild: String
    public let requestedSessionID: UUID?

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        clientProtocolMinimum: Int = VelaIPCConstants.protocolMinimum,
        clientProtocolMaximum: Int = VelaIPCConstants.protocolMaximum,
        clientVersion: String,
        clientBuild: String,
        requestedSessionID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.clientProtocolMinimum = clientProtocolMinimum
        self.clientProtocolMaximum = clientProtocolMaximum
        self.clientVersion = clientVersion
        self.clientBuild = clientBuild
        self.requestedSessionID = requestedSessionID
    }
}

public struct HelperHandshakeResponse: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "helperProtocolMinimum", "helperProtocolMaximum",
        "helperVersion", "helperBuild", "signingIdentitySummary", "daemonUID",
        "currentOwnerUID", "sessionID", "mihomoVersion", "mihomoPlatform",
        "mihomoArchitecture", "rootDataSchemaVersion", "state", "processID",
    ]

    public let schemaVersion: Int
    public let requestID: UUID
    public let helperProtocolMinimum: Int
    public let helperProtocolMaximum: Int
    public let helperVersion: String
    public let helperBuild: String
    public let signingIdentitySummary: String?
    public let daemonUID: UInt32
    public let currentOwnerUID: UInt32?
    public let sessionID: UUID?
    public let mihomoVersion: String
    public let mihomoPlatform: String
    public let mihomoArchitecture: String
    public let rootDataSchemaVersion: Int
    public let state: HelperProcessState
    public let processID: Int32?

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID,
        helperProtocolMinimum: Int = VelaIPCConstants.protocolMinimum,
        helperProtocolMaximum: Int = VelaIPCConstants.protocolMaximum,
        helperVersion: String = VelaIPCConstants.helperSemanticVersion,
        helperBuild: String = VelaIPCConstants.helperBuild,
        signingIdentitySummary: String? = nil,
        daemonUID: UInt32,
        currentOwnerUID: UInt32? = nil,
        sessionID: UUID? = nil,
        mihomoVersion: String,
        mihomoPlatform: String,
        mihomoArchitecture: String,
        rootDataSchemaVersion: Int = VelaIPCConstants.rootDataSchemaVersion,
        state: HelperProcessState,
        processID: Int32? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.helperProtocolMinimum = helperProtocolMinimum
        self.helperProtocolMaximum = helperProtocolMaximum
        self.helperVersion = helperVersion
        self.helperBuild = helperBuild
        self.signingIdentitySummary = signingIdentitySummary
        self.daemonUID = daemonUID
        self.currentOwnerUID = currentOwnerUID
        self.sessionID = sessionID
        self.mihomoVersion = mihomoVersion
        self.mihomoPlatform = mihomoPlatform
        self.mihomoArchitecture = mihomoArchitecture
        self.rootDataSchemaVersion = rootDataSchemaVersion
        self.state = state
        self.processID = processID
    }

    public var hasCompatibleProtocol: Bool {
        helperProtocolMinimum <= VelaIPCConstants.protocolMaximum
            && helperProtocolMaximum >= VelaIPCConstants.protocolMinimum
    }
}

public struct HelperStatusRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = ["schemaVersion", "requestID", "sessionID"]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID?

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
    }
}

public struct PrivilegedRuntimeHealth: Codable, Equatable, Sendable {
    public let helperReachable: Bool
    public let helperVersionCompatible: Bool
    public let processRunning: Bool
    public let controllerReachable: Bool
    public let configurationHashMatches: Bool
    public let tunEnabledInController: Bool
    public let tunInterfacePresent: Bool
    public let routeApplied: Bool
    public let dnsReady: Bool
    public let ownerLeaseValid: Bool
    public let tunInterface: String?
    public let lastCheckedAt: Date

    public init(
        helperReachable: Bool,
        helperVersionCompatible: Bool,
        processRunning: Bool,
        controllerReachable: Bool,
        configurationHashMatches: Bool,
        tunEnabledInController: Bool,
        tunInterfacePresent: Bool,
        routeApplied: Bool,
        dnsReady: Bool,
        ownerLeaseValid: Bool,
        tunInterface: String?,
        lastCheckedAt: Date
    ) {
        self.helperReachable = helperReachable
        self.helperVersionCompatible = helperVersionCompatible
        self.processRunning = processRunning
        self.controllerReachable = controllerReachable
        self.configurationHashMatches = configurationHashMatches
        self.tunEnabledInController = tunEnabledInController
        self.tunInterfacePresent = tunInterfacePresent
        self.routeApplied = routeApplied
        self.dnsReady = dnsReady
        self.ownerLeaseValid = ownerLeaseValid
        self.tunInterface = tunInterface
        self.lastCheckedAt = lastCheckedAt
    }
}

public struct HelperStatusResponse: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "state", "currentOwnerUID", "processID",
        "instanceID", "configurationSHA256", "health", "lastStableErrorCode",
    ]
    public static let nestedObjectAllowedKeys: [String: Set<String>] = [
        "health": [
            "helperReachable", "helperVersionCompatible", "processRunning",
            "controllerReachable", "configurationHashMatches", "tunEnabledInController",
            "tunInterfacePresent", "routeApplied", "dnsReady", "ownerLeaseValid",
            "tunInterface", "lastCheckedAt",
        ]
    ]

    public let schemaVersion: Int
    public let requestID: UUID
    public let state: HelperProcessState
    public let currentOwnerUID: UInt32?
    public let processID: Int32?
    public let instanceID: UUID?
    public let configurationSHA256: String?
    public let health: PrivilegedRuntimeHealth
    public let lastStableErrorCode: VelaHelperErrorCode?

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID,
        state: HelperProcessState,
        currentOwnerUID: UInt32?,
        processID: Int32?,
        instanceID: UUID?,
        configurationSHA256: String?,
        health: PrivilegedRuntimeHealth,
        lastStableErrorCode: VelaHelperErrorCode? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.state = state
        self.currentOwnerUID = currentOwnerUID
        self.processID = processID
        self.instanceID = instanceID
        self.configurationSHA256 = configurationSHA256
        self.health = health
        self.lastStableErrorCode = lastStableErrorCode
    }
}

public enum PrivilegedResourceKind: String, Codable, Sendable {
    case proxyProvider
    case ruleProvider
}

public struct PrivilegedResourceDescriptor: Codable, Equatable, Sendable {
    public static let allowedKeys: Set<String> = [
        "logicalID", "relativeDestination", "expectedSize", "expectedSHA256", "kind",
    ]
    public let logicalID: String
    public let relativeDestination: String
    public let expectedSize: Int
    public let expectedSHA256: String
    public let kind: PrivilegedResourceKind

    public init(
        logicalID: String,
        relativeDestination: String,
        expectedSize: Int,
        expectedSHA256: String,
        kind: PrivilegedResourceKind
    ) {
        self.logicalID = logicalID
        self.relativeDestination = relativeDestination
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
        self.kind = kind
    }
}

public struct PrepareStartRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "configurationSize",
        "configurationSHA256", "resources", "tunSettings", "coreID",
    ]
    public static let nestedObjectAllowedKeys: [String: Set<String>] = [
        "tunSettings": TunSettings.payloadKeys
    ]
    public static let nestedArrayObjectAllowedKeys: [String: Set<String>] = [
        "resources": PrivilegedResourceDescriptor.allowedKeys
    ]

    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let configurationSize: Int
    public let configurationSHA256: String
    public let resources: [PrivilegedResourceDescriptor]
    public let tunSettings: TunSettings
    public let coreID: CoreID

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        configurationSize: Int,
        configurationSHA256: String,
        resources: [PrivilegedResourceDescriptor],
        tunSettings: TunSettings,
        coreID: CoreID = .factoryV11928
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.configurationSize = configurationSize
        self.configurationSHA256 = configurationSHA256
        self.resources = resources
        self.tunSettings = tunSettings
        self.coreID = coreID
    }
}

public struct PrepareStartResponse: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "transactionID", "expiresAt",
        "maximumResourceBytesRemaining",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let transactionID: UUID
    public let expiresAt: Date
    public let maximumResourceBytesRemaining: Int

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID,
        transactionID: UUID,
        expiresAt: Date,
        maximumResourceBytesRemaining: Int
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.transactionID = transactionID
        self.expiresAt = expiresAt
        self.maximumResourceBytesRemaining = maximumResourceBytesRemaining
    }
}

public struct StageConfigurationRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "transactionID", "expectedSize",
        "expectedSHA256",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let transactionID: UUID
    public let expectedSize: Int
    public let expectedSHA256: String

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        transactionID: UUID,
        expectedSize: Int,
        expectedSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.transactionID = transactionID
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
    }
}

public struct StageResourceRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "transactionID", "logicalID",
        "relativeDestination", "expectedSize", "expectedSHA256", "kind",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let transactionID: UUID
    public let logicalID: String
    public let relativeDestination: String
    public let expectedSize: Int
    public let expectedSHA256: String
    public let kind: PrivilegedResourceKind

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        transactionID: UUID,
        logicalID: String,
        relativeDestination: String,
        expectedSize: Int,
        expectedSHA256: String,
        kind: PrivilegedResourceKind
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.transactionID = transactionID
        self.logicalID = logicalID
        self.relativeDestination = relativeDestination
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
        self.kind = kind
    }
}

public struct EmptyHelperResponse: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = ["schemaVersion", "requestID"]
    public let schemaVersion: Int
    public let requestID: UUID

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
    }
}

public struct CommitStartRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "transactionID",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let transactionID: UUID

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        transactionID: UUID
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.transactionID = transactionID
    }
}

public struct PrivilegedEngineRuntime: HelperPayload, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "instanceID", "controllerHost", "controllerPort",
        "controllerSecret", "processID", "startedAt", "configurationSHA256",
        "tunInterface",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let instanceID: UUID
    public let controllerHost: String
    public let controllerPort: UInt16
    public let controllerSecret: String
    public let processID: Int32
    public let startedAt: Date
    public let configurationSHA256: String
    public let tunInterface: String?

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID,
        instanceID: UUID,
        controllerHost: String,
        controllerPort: UInt16,
        controllerSecret: String,
        processID: Int32,
        startedAt: Date,
        configurationSHA256: String,
        tunInterface: String?
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.instanceID = instanceID
        self.controllerHost = controllerHost
        self.controllerPort = controllerPort
        self.controllerSecret = controllerSecret
        self.processID = processID
        self.startedAt = startedAt
        self.configurationSHA256 = configurationSHA256
        self.tunInterface = tunInterface
    }

    public var description: String {
        "PrivilegedEngineRuntime(instanceID: \(instanceID), controllerSecret: <redacted>)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: [
            "instanceID": instanceID.uuidString,
            "backend": EngineBackendKind.privilegedDaemon.rawValue,
            "controllerHost": controllerHost,
            "controllerPort": controllerPort,
            "controllerSecret": "<redacted>",
            "processID": processID,
            "configurationSHA256": configurationSHA256,
            "tunInterface": tunInterface as Any,
        ])
    }
}

public enum HelperStopReason: String, Codable, Sendable {
    case userRequested
    case backendTransition
    case applicationQuit
    case pause
    case leaseExpired
    case uninstall
    case recovery
}

public struct StopHelperRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "instanceID", "reason",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let instanceID: UUID?
    public let reason: HelperStopReason

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        instanceID: UUID?,
        reason: HelperStopReason
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.instanceID = instanceID
        self.reason = reason
    }
}

public struct RenewLeaseRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "instanceID",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let instanceID: UUID?

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        instanceID: UUID?
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.instanceID = instanceID
    }
}

public struct ReadLogBatchRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "afterSequence", "maximumEntries",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let afterSequence: UInt64
    public let maximumEntries: Int

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        afterSequence: UInt64,
        maximumEntries: Int
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.afterSequence = afterSequence
        self.maximumEntries = maximumEntries
    }
}

public struct HelperLogEntry: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let timestamp: Date
    public let channel: String
    public let message: String

    public init(sequence: UInt64, timestamp: Date, channel: String, message: String) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.channel = channel
        self.message = message
    }
}

public struct ReadLogBatchResponse: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = ["schemaVersion", "requestID", "entries"]
    public static let nestedArrayObjectAllowedKeys: [String: Set<String>] = [
        "entries": ["sequence", "timestamp", "channel", "message"]
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let entries: [HelperLogEntry]

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID,
        entries: [HelperLogEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.entries = entries
    }
}

public enum PrivilegedCleanupMode: String, Codable, Sendable {
    case runtimeOnly
    case removeRuntimeData
    case keepDiagnosticMetadata
}

public struct CleanupHelperRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "mode",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let mode: PrivilegedCleanupMode

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        mode: PrivilegedCleanupMode
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.mode = mode
    }
}

public struct AbortStartRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "transactionID",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let transactionID: UUID

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        transactionID: UUID
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.transactionID = transactionID
    }
}

extension TunSettings {
    public static let payloadKeys: Set<String> = [
        "enabled", "stack", "autoRoute", "autoDetectInterface", "outboundInterface",
        "excludedInterfaces", "dnsHijack", "allowLocalNetwork", "routeExcludeCIDRs",
        "device", "mtu", "localMixedPort", "endpointIndependentNAT", "udpTimeoutSeconds",
    ]
}
