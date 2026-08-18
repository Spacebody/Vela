#if DEBUG
import Foundation

protocol FaultInjecting: Sendable {
    func trigger(
        at point: FaultInjectionPoint,
        testRunID: UUID
    ) async throws -> FaultTrigger?
}

struct NoFaultInjector: FaultInjecting {
    func trigger(
        at point: FaultInjectionPoint,
        testRunID: UUID
    ) async throws -> FaultTrigger? {
        nil
    }
}

actor FaultInjector: FaultInjecting {
    private let planSHA256: String
    private let seed: UInt64
    private let testRunID: UUID
    private let rulesByPoint: [FaultInjectionPoint: [FaultRule]]
    private var checkCounts: [FaultInjectionPoint: Int] = [:]

    init(plan: FaultPlan) throws {
        let parsedPlan = try FaultPlanParser.parse(plan: plan)
        self.init(parsedPlan: parsedPlan)
    }

    init(planData: Data, expectedTestRunID: UUID? = nil) throws {
        let parsedPlan = try FaultPlanParser.parse(planData, expectedTestRunID: expectedTestRunID)
        self.init(parsedPlan: parsedPlan)
    }

    private init(parsedPlan: ParsedFaultPlan) {
        planSHA256 = parsedPlan.planSHA256
        seed = parsedPlan.plan.seed
        testRunID = parsedPlan.plan.resolvedTestRunID
        rulesByPoint = Dictionary(grouping: parsedPlan.rules, by: \.point)
            .mapValues { rules in
                rules.sorted {
                    if $0.occurrence != $1.occurrence {
                        return $0.occurrence < $1.occurrence
                    }
                    if $0.deterministicSequence != $1.deterministicSequence {
                        return $0.deterministicSequence < $1.deterministicSequence
                    }
                    return $0.scenarioID < $1.scenarioID
                }
            }
    }

    func trigger(
        at point: FaultInjectionPoint,
        testRunID requestedTestRunID: UUID
    ) async throws -> FaultTrigger? {
        guard requestedTestRunID == testRunID else {
            throw FaultInjectorError.testRunMismatch
        }

        let previousCount = checkCounts[point, default: 0]
        guard previousCount < Int.max else {
            throw FaultInjectorError.counterExhausted
        }
        let currentCount = previousCount + 1
        checkCounts[point] = currentCount

        guard let rule = rulesByPoint[point]?.first(where: { $0.occurrence == currentCount }) else {
            return nil
        }
        return FaultTrigger(planSHA256: planSHA256, rule: rule, triggerCount: currentCount)
    }

    func reset(testRunID requestedTestRunID: UUID) throws {
        guard requestedTestRunID == testRunID else {
            throw FaultInjectorError.testRunMismatch
        }
        checkCounts.removeAll(keepingCapacity: true)
    }

    func snapshot(testRunID requestedTestRunID: UUID) throws -> FaultInjectorSnapshot {
        guard requestedTestRunID == testRunID else {
            throw FaultInjectorError.testRunMismatch
        }
        return FaultInjectorSnapshot(
            planSHA256: planSHA256,
            seed: seed,
            testRunID: testRunID,
            checkCounts: checkCounts
        )
    }
}

enum FaultInjectionLaunchEnvironment {
    static let planKey = "VELA_TEST_FAULT_PLAN"

    static func injector(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        expectedTestRunID: UUID
    ) throws -> FaultInjector? {
        guard let encodedPlan = environment[planKey] else {
            return nil
        }
        guard let data = encodedPlan.data(using: .utf8) else {
            throw FaultPlanError.malformedJSON
        }
        return try FaultInjector(planData: data, expectedTestRunID: expectedTestRunID)
    }
}
#endif
