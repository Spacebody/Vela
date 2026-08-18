#if DEBUG
import CryptoKit
import Foundation

struct ParsedFaultPlan: Equatable, Sendable {
    let plan: FaultPlan
    let planSHA256: String
    let rules: [FaultRule]
}

enum FaultPlanParser {
    static let maximumPlanBytes = 256 * 1_024
    static let maximumScenarios = 128
    static let maximumOccurrence = 10_000
    static let maximumDelayMilliseconds = 30_000
    static let maximumTimeoutMilliseconds = 120_000
    static let maximumClockJumpSeconds = 86_400
    static let maximumForbiddenOutcomes = 16

    static func parse(
        _ data: Data,
        expectedTestRunID: UUID? = nil
    ) throws -> ParsedFaultPlan {
        guard !data.isEmpty else {
            throw FaultPlanError.emptyPlan
        }
        guard data.count <= maximumPlanBytes else {
            throw FaultPlanError.planTooLarge
        }

        let plan: FaultPlan
        do {
            plan = try JSONDecoder().decode(FaultPlan.self, from: data)
        } catch let error as FaultPlanError {
            throw error
        } catch {
            throw FaultPlanError.malformedJSON
        }

        try validate(plan, expectedTestRunID: expectedTestRunID)
        let digest = sha256(data)
        let scope = FaultScope(testRunID: plan.resolvedTestRunID)
        let rules = plan.scenarios.map { scenario in
            FaultRule(
                scenarioID: scenario.id,
                point: scenario.point,
                occurrence: scenario.occurrence,
                delayMilliseconds: scenario.delayMilliseconds,
                effect: scenario.effect,
                seed: plan.seed,
                deterministicSequence: deterministicSequence(seed: plan.seed, scenarioID: scenario.id),
                scope: scope,
                expectedSafeState: scenario.expectedSafeState,
                forbiddenOutcomes: scenario.forbiddenOutcomes,
                destructive: scenario.destructive
            )
        }.sorted(by: seededRuleOrder)

        return ParsedFaultPlan(plan: plan, planSHA256: digest, rules: rules)
    }

    static func parse(
        plan: FaultPlan,
        expectedTestRunID: UUID? = nil
    ) throws -> ParsedFaultPlan {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(plan)
        } catch {
            throw FaultPlanError.malformedJSON
        }
        return try parse(data, expectedTestRunID: expectedTestRunID)
    }

    private static func validate(
        _ plan: FaultPlan,
        expectedTestRunID: UUID?
    ) throws {
        guard plan.schemaVersion == 1 else {
            throw FaultPlanError.unsupportedSchema
        }
        guard (1...maximumScenarios).contains(plan.scenarios.count) else {
            throw FaultPlanError.invalidScenarioCount
        }
        if let expectedTestRunID, plan.resolvedTestRunID != expectedTestRunID {
            throw FaultPlanError.testRunMismatch
        }

        var scenarioIDs = Set<String>()
        var triggers = Set<FaultTriggerIdentity>()
        for scenario in plan.scenarios {
            guard isValidScenarioID(scenario.id) else {
                throw FaultPlanError.invalidScenarioID
            }
            guard scenarioIDs.insert(scenario.id).inserted else {
                throw FaultPlanError.duplicateScenarioID
            }
            guard (1...maximumOccurrence).contains(scenario.occurrence) else {
                throw FaultPlanError.invalidOccurrence
            }
            guard (0...maximumDelayMilliseconds).contains(scenario.delayMilliseconds) else {
                throw FaultPlanError.invalidDelay
            }
            let trigger = FaultTriggerIdentity(point: scenario.point, occurrence: scenario.occurrence)
            guard triggers.insert(trigger).inserted else {
                throw FaultPlanError.duplicateTrigger
            }
            guard
                (1...maximumForbiddenOutcomes).contains(scenario.forbiddenOutcomes.count),
                Set(scenario.forbiddenOutcomes).count == scenario.forbiddenOutcomes.count
            else {
                throw FaultPlanError.invalidForbiddenOutcomes
            }

            try validate(effect: scenario.effect, point: scenario.point, destructive: scenario.destructive)
        }
    }

    private static func validate(
        effect: FaultEffect,
        point: FaultInjectionPoint,
        destructive: Bool
    ) throws {
        switch effect {
        case .throwError, .cancellation:
            break
        case let .timeout(milliseconds):
            guard (1...maximumTimeoutMilliseconds).contains(milliseconds) else {
                throw FaultPlanError.invalidEffect
            }
        case .httpStatus:
            guard point == .subscriptionResponse || point == .controllerHTTPResponse else {
                throw FaultPlanError.incompatibleEffect
            }
        case .closeWebSocket:
            guard point == .connectionsWebSocket else {
                throw FaultPlanError.incompatibleEffect
            }
        case .insufficientDisk, .permissionDenied:
            guard filesystemCompatiblePoints.contains(point) else {
                throw FaultPlanError.incompatibleEffect
            }
        case .testPath:
            guard pathProviderCompatiblePoints.contains(point) else {
                throw FaultPlanError.incompatibleEffect
            }
        case let .clockJump(seconds):
            guard
                point == .clockJump,
                seconds != 0,
                (-maximumClockJumpSeconds...maximumClockJumpSeconds).contains(seconds)
            else {
                throw FaultPlanError.invalidEffect
            }
        case .sleepWake:
            guard point == .sleepWake else {
                throw FaultPlanError.incompatibleEffect
            }
        case let .ownedProcessExit(exitCode):
            guard
                point == .ownedProcessTermination || point == .coreProbation,
                destructive,
                (1...255).contains(Int(exitCode))
            else {
                throw FaultPlanError.incompatibleEffect
            }
        }
    }

    private static let filesystemCompatiblePoints: Set<FaultInjectionPoint> = [
        .fileWrite,
        .profileAtomicReplace,
        .filesystemInsufficientDisk,
        .filesystemPermissionDenied,
        .configurationCompile,
        .configurationApply,
        .appUpdateJournal,
        .coreInstall,
        .supportBundleWrite,
        .helpExport,
    ]

    private static let pathProviderCompatiblePoints: Set<FaultInjectionPoint> = [
        .fileWrite,
        .profileAtomicReplace,
        .configurationCompile,
        .configurationValidation,
        .configurationApply,
        .appUpdateJournal,
        .coreInstall,
        .helpExport,
        .supportBundleWrite,
    ]

    private static func isValidScenarioID(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 46
                || byte == 95
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func deterministicSequence(seed: UInt64, scenarioID: String) -> UInt64 {
        var hash = seed ^ 0xCBF2_9CE4_8422_2325
        for byte in scenarioID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }

        hash &+= 0x9E37_79B9_7F4A_7C15
        var mixed = hash
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    private static func seededRuleOrder(_ lhs: FaultRule, _ rhs: FaultRule) -> Bool {
        if lhs.deterministicSequence != rhs.deterministicSequence {
            return lhs.deterministicSequence < rhs.deterministicSequence
        }
        return lhs.scenarioID < rhs.scenarioID
    }
}

private struct FaultTriggerIdentity: Hashable {
    let point: FaultInjectionPoint
    let occurrence: Int
}
#endif
