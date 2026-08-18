#if DEBUG
import Foundation

enum FaultInjectionPoint: String, Codable, CaseIterable, Sendable {
    case fileWrite = "file.write"
    case profileAtomicReplace = "profile.commit.atomicReplace"
    case keychainRead = "keychain.read"
    case keychainWrite = "keychain.write"
    case keychainDelete = "keychain.delete"
    case subscriptionResponse = "subscription.response"
    case controllerStartup = "controller.startup"
    case controllerTimeout = "controller.timeout"
    case controllerHTTPResponse = "controller.httpResponse"
    case connectionsWebSocket = "connections.webSocket.disconnect"
    case processLaunch = "process.launch"
    case ownedProcessTermination = "process.ownedTermination"
    case helperHandshake = "helper.handshake"
    case helperRPCTimeout = "helper.rpc.timeout"
    case helperRPCInterruption = "helper.rpc.interruption"
    case privilegedStart = "privileged.start"
    case tunWaitForController = "tun.waitForController"
    case tunInterfaceReady = "tun.interfaceReady"
    case routeHealth = "route.health"
    case systemProxyVerification = "systemProxy.verification"
    case configurationCompile = "configuration.compile"
    case configurationValidation = "configuration.validation"
    case configurationApply = "configuration.apply"
    case appUpdateJournal = "appUpdate.journal"
    case coreInstall = "core.install"
    case coreActivate = "core.activate"
    case coreProbation = "core.probation.processExit"
    case sceneCommit = "scene.commit"
    case automationSocket = "automation.socket"
    case helpExport = "help.export"
    case supportBundleWrite = "supportBundle.write"
    case filesystemInsufficientDisk = "testFilesystem.insufficientDisk"
    case filesystemPermissionDenied = "testFilesystem.permissionDenied"
    case clockJump = "clock.jump"
    case sleepWake = "system.sleepWake"
}

enum FaultStableErrorCode: String, Codable, CaseIterable, Sendable {
    case testInjectedFailure
    case testInsufficientDisk
    case testPermissionDenied
    case testKeychainUnavailable
    case testControllerUnavailable
    case testValidationRejected
    case testSignatureRejected
    case testJournalFailure
}

enum FaultHTTPStatusFixture: Int, Codable, CaseIterable, Sendable {
    case unauthorized = 401
    case forbidden = 403
    case requestTimeout = 408
    case conflict = 409
    case payloadTooLarge = 413
    case tooManyRequests = 429
    case internalServerError = 500
    case badGateway = 502
    case serviceUnavailable = 503
    case gatewayTimeout = 504
}

enum FaultWebSocketCloseFixture: String, Codable, CaseIterable, Sendable {
    case goingAway
    case serverRestart
    case protocolError
    case abnormalClosure
}

enum FaultTestPathFixture: String, Codable, CaseIterable, Sendable {
    case ownedTemporaryFile
    case ownedTemporaryDirectory
    case ownedReadOnlyFile
    case ownedReadOnlyDirectory
    case ownedMissingPath
}

enum FaultSleepWakeFixture: String, Codable, CaseIterable, Sendable {
    case sleep
    case wake
    case sleepThenWake
}

enum FaultEffect: Codable, Equatable, Sendable {
    case throwError(FaultStableErrorCode)
    case timeout(milliseconds: Int)
    case httpStatus(FaultHTTPStatusFixture)
    case closeWebSocket(FaultWebSocketCloseFixture)
    case insufficientDisk
    case permissionDenied
    case testPath(FaultTestPathFixture)
    case clockJump(seconds: Int)
    case sleepWake(FaultSleepWakeFixture)
    case cancellation
    case ownedProcessExit(exitCode: Int32)

    private enum Kind: String, Codable {
        case `throw`
        case timeout
        case httpStatus
        case closeWebSocket
        case insufficientDisk
        case permissionDenied
        case testPath
        case clockJump
        case sleepWake
        case cancellation
        case ownedProcessExit
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case code
        case milliseconds
        case status
        case reason
        case fixture
        case seconds
        case phase
        case exitCode
    }

    init(from decoder: Decoder) throws {
        let allKeys = try decoder.container(keyedBy: FaultCodingKey.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        let allowed: Set<String>
        switch kind {
        case .throw:
            allowed = [CodingKeys.kind.rawValue, CodingKeys.code.rawValue]
            self = .throwError(try container.decode(FaultStableErrorCode.self, forKey: .code))
        case .timeout:
            allowed = [CodingKeys.kind.rawValue, CodingKeys.milliseconds.rawValue]
            self = .timeout(milliseconds: try container.decode(Int.self, forKey: .milliseconds))
        case .httpStatus:
            allowed = [CodingKeys.kind.rawValue, CodingKeys.status.rawValue]
            self = .httpStatus(try container.decode(FaultHTTPStatusFixture.self, forKey: .status))
        case .closeWebSocket:
            allowed = [CodingKeys.kind.rawValue, CodingKeys.reason.rawValue]
            self = .closeWebSocket(try container.decode(FaultWebSocketCloseFixture.self, forKey: .reason))
        case .insufficientDisk:
            allowed = [CodingKeys.kind.rawValue]
            self = .insufficientDisk
        case .permissionDenied:
            allowed = [CodingKeys.kind.rawValue]
            self = .permissionDenied
        case .testPath:
            allowed = [CodingKeys.kind.rawValue, CodingKeys.fixture.rawValue]
            self = .testPath(try container.decode(FaultTestPathFixture.self, forKey: .fixture))
        case .clockJump:
            allowed = [CodingKeys.kind.rawValue, CodingKeys.seconds.rawValue]
            self = .clockJump(seconds: try container.decode(Int.self, forKey: .seconds))
        case .sleepWake:
            allowed = [CodingKeys.kind.rawValue, CodingKeys.phase.rawValue]
            self = .sleepWake(try container.decode(FaultSleepWakeFixture.self, forKey: .phase))
        case .cancellation:
            allowed = [CodingKeys.kind.rawValue]
            self = .cancellation
        case .ownedProcessExit:
            allowed = [CodingKeys.kind.rawValue, CodingKeys.exitCode.rawValue]
            self = .ownedProcessExit(exitCode: try container.decode(Int32.self, forKey: .exitCode))
        }

        guard allKeys.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw FaultPlanError.unknownField
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .throwError(code):
            try container.encode(Kind.throw, forKey: .kind)
            try container.encode(code, forKey: .code)
        case let .timeout(milliseconds):
            try container.encode(Kind.timeout, forKey: .kind)
            try container.encode(milliseconds, forKey: .milliseconds)
        case let .httpStatus(status):
            try container.encode(Kind.httpStatus, forKey: .kind)
            try container.encode(status, forKey: .status)
        case let .closeWebSocket(reason):
            try container.encode(Kind.closeWebSocket, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .insufficientDisk:
            try container.encode(Kind.insufficientDisk, forKey: .kind)
        case .permissionDenied:
            try container.encode(Kind.permissionDenied, forKey: .kind)
        case let .testPath(fixture):
            try container.encode(Kind.testPath, forKey: .kind)
            try container.encode(fixture, forKey: .fixture)
        case let .clockJump(seconds):
            try container.encode(Kind.clockJump, forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
        case let .sleepWake(phase):
            try container.encode(Kind.sleepWake, forKey: .kind)
            try container.encode(phase, forKey: .phase)
        case .cancellation:
            try container.encode(Kind.cancellation, forKey: .kind)
        case let .ownedProcessExit(exitCode):
            try container.encode(Kind.ownedProcessExit, forKey: .kind)
            try container.encode(exitCode, forKey: .exitCode)
        }
    }
}

enum FaultExpectedSafeState: String, Codable, CaseIterable, Sendable {
    case noMutation
    case previousBackendHealthy
    case previousRevisionActive
    case previousKnownGoodCoreActive
    case lastKnownGoodConfigurationReadOnly
    case safeMode
    case tunOff
    case systemProxyOff
    case rollbackComplete
    case supportExportAbsent
    case ownedProcessStopped
    case retryBounded
}

enum FaultForbiddenOutcome: String, Codable, CaseIterable, Sendable {
    case tunRouteResidue
    case systemProxyUnknown
    case infiniteRetry
    case emptyProfileStore
    case activeConfigCorrupt
    case factoryCoreDeleted
    case rollbackLoop
    case partialWrite
    case secretExposure
    case unauthorizedMutation
    case orphanProcess
    case staleJournal
    case unsafeBackendActive
}

struct FaultScenario: Codable, Equatable, Sendable {
    let id: String
    let point: FaultInjectionPoint
    let occurrence: Int
    let delayMilliseconds: Int
    let effect: FaultEffect
    let expectedSafeState: FaultExpectedSafeState
    let forbiddenOutcomes: [FaultForbiddenOutcome]
    let destructive: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case point
        case occurrence
        case delayMilliseconds
        case effect
        case expectedSafeState
        case forbiddenOutcomes
        case destructive
    }

    init(
        id: String,
        point: FaultInjectionPoint,
        occurrence: Int,
        delayMilliseconds: Int = 0,
        effect: FaultEffect,
        expectedSafeState: FaultExpectedSafeState,
        forbiddenOutcomes: [FaultForbiddenOutcome],
        destructive: Bool
    ) {
        self.id = id
        self.point = point
        self.occurrence = occurrence
        self.delayMilliseconds = delayMilliseconds
        self.effect = effect
        self.expectedSafeState = expectedSafeState
        self.forbiddenOutcomes = forbiddenOutcomes
        self.destructive = destructive
    }

    init(from decoder: Decoder) throws {
        let allKeys = try decoder.container(keyedBy: FaultCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard allKeys.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw FaultPlanError.unknownField
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        point = try container.decode(FaultInjectionPoint.self, forKey: .point)
        occurrence = try container.decode(Int.self, forKey: .occurrence)
        delayMilliseconds = try container.decodeIfPresent(Int.self, forKey: .delayMilliseconds) ?? 0
        effect = try container.decode(FaultEffect.self, forKey: .effect)
        expectedSafeState = try container.decode(FaultExpectedSafeState.self, forKey: .expectedSafeState)
        forbiddenOutcomes = try container.decode([FaultForbiddenOutcome].self, forKey: .forbiddenOutcomes)
        destructive = try container.decode(Bool.self, forKey: .destructive)
    }
}

struct FaultPlan: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let planID: UUID
    let testRunID: UUID?
    let seed: UInt64
    let scenarios: [FaultScenario]

    var resolvedTestRunID: UUID { testRunID ?? planID }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case planID
        case testRunID
        case seed
        case scenarios
    }

    init(
        schemaVersion: Int = 1,
        planID: UUID,
        testRunID: UUID? = nil,
        seed: UInt64,
        scenarios: [FaultScenario]
    ) {
        self.schemaVersion = schemaVersion
        self.planID = planID
        self.testRunID = testRunID
        self.seed = seed
        self.scenarios = scenarios
    }

    init(from decoder: Decoder) throws {
        let allKeys = try decoder.container(keyedBy: FaultCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard allKeys.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw FaultPlanError.unknownField
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        planID = try container.decode(UUID.self, forKey: .planID)
        testRunID = try container.decodeIfPresent(UUID.self, forKey: .testRunID)
        seed = try container.decode(UInt64.self, forKey: .seed)
        scenarios = try container.decode([FaultScenario].self, forKey: .scenarios)
    }
}

enum FaultPlanError: Error, Equatable, Sendable {
    case emptyPlan
    case planTooLarge
    case malformedJSON
    case unknownField
    case unsupportedSchema
    case invalidScenarioCount
    case invalidScenarioID
    case duplicateScenarioID
    case duplicateTrigger
    case invalidOccurrence
    case invalidDelay
    case invalidEffect
    case invalidForbiddenOutcomes
    case incompatibleEffect
    case testRunMismatch
}

enum FaultInjectorError: Error, Equatable, Sendable {
    case testRunMismatch
    case counterExhausted
}

struct FaultScope: Equatable, Sendable {
    let testRunID: UUID
}

struct FaultRule: Equatable, Sendable {
    let scenarioID: String
    let point: FaultInjectionPoint
    let occurrence: Int
    let delayMilliseconds: Int
    let effect: FaultEffect
    let seed: UInt64
    let deterministicSequence: UInt64
    let scope: FaultScope
    let expectedSafeState: FaultExpectedSafeState
    let forbiddenOutcomes: [FaultForbiddenOutcome]
    let destructive: Bool
}

enum FaultObservedState: String, Codable, CaseIterable, Sendable {
    case notObserved
    case expectedSafeStateReached
    case safeModeEntered
    case rollbackCompleted
    case recoveryFailed
}

enum FaultCleanupResult: String, Codable, CaseIterable, Sendable {
    case notRequired
    case succeeded
    case failed
}

struct FaultInjectionEvidenceSummary: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let planSHA256: String
    let seed: UInt64
    let testRunID: UUID
    let point: FaultInjectionPoint
    let triggerCount: Int
    let expectedSafeState: FaultExpectedSafeState
    let observedState: FaultObservedState
    let cleanupResult: FaultCleanupResult
}

struct FaultTrigger: Equatable, Sendable {
    let planSHA256: String
    let rule: FaultRule
    let triggerCount: Int

    func evidenceSummary(
        observedState: FaultObservedState,
        cleanupResult: FaultCleanupResult
    ) -> FaultInjectionEvidenceSummary {
        FaultInjectionEvidenceSummary(
            schemaVersion: 1,
            planSHA256: planSHA256,
            seed: rule.seed,
            testRunID: rule.scope.testRunID,
            point: rule.point,
            triggerCount: triggerCount,
            expectedSafeState: rule.expectedSafeState,
            observedState: observedState,
            cleanupResult: cleanupResult
        )
    }
}

struct FaultInjectorSnapshot: Equatable, Sendable {
    let planSHA256: String
    let seed: UInt64
    let testRunID: UUID
    let checkCounts: [FaultInjectionPoint: Int]
}

struct FaultCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
#endif
