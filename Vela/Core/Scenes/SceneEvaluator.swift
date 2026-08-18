import Foundation

/// SSID resolution happens at the Keychain boundary. The evaluator receives
/// only opaque references that match the current network, never the SSID.
nonisolated enum SceneSSIDMatchState: Equatable, Sendable {
    case available(matchingSecretReferences: Set<String>)
    case permissionRequired
    case permissionDenied
    case unavailable
    case notOnWiFi
}

nonisolated struct SceneEvaluationContext: Sendable {
    var now: Date
    var calendar: Calendar
    var networkInterface: SceneNetworkInterface?
    var ssidState: SceneSSIDMatchState
    var powerSource: ScenePowerSource
    var networkExpensive: Bool?
    var networkConstrained: Bool?

    init(
        now: Date = .now,
        calendar: Calendar = .current,
        networkInterface: SceneNetworkInterface? = nil,
        ssidState: SceneSSIDMatchState = .unavailable,
        powerSource: ScenePowerSource = .unknown,
        networkExpensive: Bool? = nil,
        networkConstrained: Bool? = nil
    ) {
        self.now = now
        self.calendar = calendar
        self.networkInterface = networkInterface
        self.ssidState = ssidState
        self.powerSource = powerSource
        self.networkExpensive = networkExpensive
        self.networkConstrained = networkConstrained
    }
}

nonisolated struct SceneAutomationEvaluationState: Equatable, Sendable {
    var automaticScenesEnabled: Bool
    var activeSceneID: UUID?
    var manualLockUntil: Date?
    var manualLockActive: Bool
    var lastAutomaticSwitchAt: Date?
    var manualRepairRequired: Bool
    var hasUnsavedConfigurationDraft: Bool

    init(
        automaticScenesEnabled: Bool = true,
        activeSceneID: UUID? = nil,
        manualLockUntil: Date? = nil,
        manualLockActive: Bool = false,
        lastAutomaticSwitchAt: Date? = nil,
        manualRepairRequired: Bool = false,
        hasUnsavedConfigurationDraft: Bool = false
    ) {
        self.automaticScenesEnabled = automaticScenesEnabled
        self.activeSceneID = activeSceneID
        self.manualLockUntil = manualLockUntil
        self.manualLockActive = manualLockActive
        self.lastAutomaticSwitchAt = lastAutomaticSwitchAt
        self.manualRepairRequired = manualRepairRequired
        self.hasUnsavedConfigurationDraft = hasUnsavedConfigurationDraft
    }

    init(
        document: SceneStoreDocument,
        manualLockActive: Bool = false,
        hasUnsavedConfigurationDraft: Bool = false
    ) {
        self.init(
            automaticScenesEnabled: document.automaticScenesEnabled,
            activeSceneID: document.activeSceneID,
            manualLockUntil: document.manualLockUntil,
            manualLockActive: manualLockActive,
            lastAutomaticSwitchAt: document.lastAutomaticSwitchAt,
            manualRepairRequired: document.manualRepairRequired,
            hasUnsavedConfigurationDraft: hasUnsavedConfigurationDraft
        )
    }
}

nonisolated enum TriggerEvaluation: Equatable, Sendable {
    case matched(redactedReason: String)
    case notMatched(redactedReason: String)
    case blocked(redactedReason: String)
    case unavailable(redactedReason: String)

    var isMatched: Bool {
        if case .matched = self { return true }
        return false
    }

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

nonisolated struct SceneTriggerEvaluation: Equatable, Sendable {
    let kind: SceneTriggerKind
    let result: TriggerEvaluation
}

nonisolated enum SceneTriggerGroupStatus: String, Equatable, Sendable {
    case matched
    case notMatched
    case blocked
    case unavailable
}

nonisolated struct SceneTriggerGroupEvaluation: Equatable, Sendable {
    let groupID: UUID
    let status: SceneTriggerGroupStatus
    let triggerEvaluations: [SceneTriggerEvaluation]

    var specificity: Int {
        triggerEvaluations.reduce(into: 0) { count, evaluation in
            if evaluation.result.isMatched { count += 1 }
        }
    }
}

nonisolated struct SceneMatch: Equatable, Sendable {
    let scene: VelaScene
    let specificity: Int
    let groupEvaluations: [SceneTriggerGroupEvaluation]
}

nonisolated enum SceneDecisionStatus: String, Equatable, Sendable {
    case matched
    case notMatched
    case blocked
    case unavailable
    case disabled
    case manualOnly
    case invalid
}

nonisolated struct SceneDecision: Equatable, Sendable {
    let sceneID: UUID
    let status: SceneDecisionStatus
    let groupEvaluations: [SceneTriggerGroupEvaluation]
}

nonisolated struct SceneEvaluationResult: Equatable, Sendable {
    let selectedScene: VelaScene?
    let matches: [SceneMatch]
    let decisions: [SceneDecision]
    let summary: SceneEvaluationSummary
}

nonisolated struct SceneEvaluator: Sendable {
    init() {}

    func evaluate(
        scenes: [VelaScene],
        state: SceneAutomationEvaluationState,
        context: SceneEvaluationContext
    ) -> SceneEvaluationResult {
        let decisions = scenes
            .map { evaluateScene($0, context: context) }
            .sorted { $0.sceneID.uuidString < $1.sceneID.uuidString }
        let scenesByID = scenes.reduce(into: [UUID: VelaScene]()) { result, scene in
            // A persisted store rejects duplicate IDs. Keeping the first value
            // here makes direct/test evaluations defensive instead of trapping.
            if result[scene.id] == nil { result[scene.id] = scene }
        }
        let matches = decisions.compactMap { decision -> SceneMatch? in
            guard decision.status == .matched,
                let scene = scenesByID[decision.sceneID]
            else { return nil }
            let specificity = decision.groupEvaluations
                .filter { $0.status == .matched }
                .map(\.specificity)
                .max() ?? 0
            return SceneMatch(
                scene: scene,
                specificity: specificity,
                groupEvaluations: decision.groupEvaluations
            )
        }.sorted(by: Self.matchPrecedes)

        let blockedKinds = Array(Set(decisions.flatMap { decision in
            decision.groupEvaluations.flatMap { group in
                group.triggerEvaluations.compactMap { evaluation in
                    evaluation.result.isBlocked ? evaluation.kind : nil
                }
            }
        })).sorted { $0.rawValue < $1.rawValue }
        let matchIDs = matches.map { $0.scene.id }

        func result(
            selectedScene: VelaScene?,
            recommendedSceneID: UUID?,
            outcome: SceneEvaluationOutcomeCode
        ) -> SceneEvaluationResult {
            SceneEvaluationResult(
                selectedScene: selectedScene,
                matches: matches,
                decisions: decisions,
                summary: SceneEvaluationSummary(
                    evaluatedAt: context.now,
                    selectedSceneID: selectedScene?.id,
                    recommendedSceneID: recommendedSceneID,
                    outcome: outcome,
                    evaluatedSceneCount: scenes.count,
                    matchingSceneIDs: matchIDs,
                    blockedTriggerKinds: blockedKinds
                )
            )
        }

        guard state.automaticScenesEnabled else {
            return result(
                selectedScene: nil,
                recommendedSceneID: matches.first?.scene.id,
                outcome: .automaticDisabled
            )
        }
        guard !state.manualRepairRequired else {
            return result(
                selectedScene: nil,
                recommendedSceneID: matches.first?.scene.id,
                outcome: .repairRequired
            )
        }
        guard !state.hasUnsavedConfigurationDraft else {
            return result(
                selectedScene: nil,
                recommendedSceneID: matches.first?.scene.id,
                outcome: .draftPending
            )
        }
        let timedManualLockActive = state.manualLockUntil.map { context.now < $0 } ?? false
        guard !state.manualLockActive, !timedManualLockActive else {
            return result(
                selectedScene: nil,
                recommendedSceneID: matches.first?.scene.id,
                outcome: .manualLock
            )
        }
        guard let candidate = matches.first?.scene else {
            return result(
                selectedScene: nil,
                recommendedSceneID: nil,
                outcome: .noMatchingScene
            )
        }
        if candidate.id == state.activeSceneID {
            return result(
                selectedScene: candidate,
                recommendedSceneID: candidate.id,
                outcome: .alreadyActive
            )
        }
        let cooldownSeconds = state.activeSceneID
            .flatMap { scenesByID[$0]?.cooldownSeconds }
            ?? candidate.cooldownSeconds
        if let lastSwitch = state.lastAutomaticSwitchAt,
            context.now < lastSwitch.addingTimeInterval(TimeInterval(cooldownSeconds))
        {
            return result(
                selectedScene: nil,
                recommendedSceneID: candidate.id,
                outcome: .cooldown
            )
        }
        return result(
            selectedScene: candidate,
            recommendedSceneID: candidate.id,
            outcome: .selected
        )
    }

    func evaluateScene(
        _ scene: VelaScene,
        context: SceneEvaluationContext
    ) -> SceneDecision {
        guard scene.enabled else {
            return SceneDecision(sceneID: scene.id, status: .disabled, groupEvaluations: [])
        }
        guard (try? scene.validated()) != nil else {
            return SceneDecision(sceneID: scene.id, status: .invalid, groupEvaluations: [])
        }
        guard !scene.triggerGroups.isEmpty else {
            return SceneDecision(sceneID: scene.id, status: .manualOnly, groupEvaluations: [])
        }

        let groups = scene.triggerGroups.map { group in
            evaluate(group: group, context: context)
        }
        let status: SceneDecisionStatus
        if groups.contains(where: { $0.status == .matched }) {
            status = .matched
        } else if groups.contains(where: { $0.status == .blocked }) {
            status = .blocked
        } else if groups.contains(where: { $0.status == .unavailable }) {
            status = .unavailable
        } else {
            status = .notMatched
        }
        return SceneDecision(sceneID: scene.id, status: status, groupEvaluations: groups)
    }

    private func evaluate(
        group: SceneTriggerGroup,
        context: SceneEvaluationContext
    ) -> SceneTriggerGroupEvaluation {
        let triggerEvaluations = group.triggers.compactMap { trigger -> SceneTriggerEvaluation? in
            guard trigger.enabled else { return nil }
            return SceneTriggerEvaluation(
                kind: trigger.kind,
                result: evaluate(trigger: trigger, context: context)
            )
        }

        let status: SceneTriggerGroupStatus
        if triggerEvaluations.allSatisfy({ $0.result.isMatched }) {
            status = .matched
        } else if triggerEvaluations.contains(where: {
            if case .notMatched = $0.result { return true }
            return false
        }) {
            status = .notMatched
        } else if triggerEvaluations.contains(where: { $0.result.isBlocked }) {
            status = .blocked
        } else {
            status = .unavailable
        }
        return SceneTriggerGroupEvaluation(
            groupID: group.id,
            status: status,
            triggerEvaluations: triggerEvaluations
        )
    }

    private func evaluate(
        trigger: SceneTrigger,
        context: SceneEvaluationContext
    ) -> TriggerEvaluation {
        switch trigger.kind {
        case .networkInterface:
            guard let expected = trigger.value?.stringValue.flatMap(SceneNetworkInterface.init),
                let actual = context.networkInterface
            else {
                return .unavailable(redactedReason: "scene.trigger.interface.unavailable")
            }
            return expected == actual
                ? .matched(redactedReason: "scene.trigger.interface.matched")
                : .notMatched(redactedReason: "scene.trigger.interface.notMatched")

        case .wifiSSID:
            guard let reference = trigger.secretReference else {
                return .blocked(redactedReason: "scene.trigger.ssid.reconfigurationRequired")
            }
            switch context.ssidState {
            case let .available(matchingSecretReferences):
                return matchingSecretReferences.contains(reference)
                    ? .matched(redactedReason: "scene.trigger.ssid.matched")
                    : .notMatched(redactedReason: "scene.trigger.ssid.notMatched")
            case .permissionRequired:
                return .blocked(redactedReason: "scene.trigger.ssid.permissionRequired")
            case .permissionDenied:
                return .blocked(redactedReason: "scene.trigger.ssid.permissionDenied")
            case .unavailable:
                return .unavailable(redactedReason: "scene.trigger.ssid.unavailable")
            case .notOnWiFi:
                return .notMatched(redactedReason: "scene.trigger.ssid.notOnWiFi")
            }

        case .localTimeWindow:
            guard let window = trigger.timeWindow else {
                return .unavailable(redactedReason: "scene.trigger.time.invalid")
            }
            return matches(window: window, context: context)
                ? .matched(redactedReason: "scene.trigger.time.matched")
                : .notMatched(redactedReason: "scene.trigger.time.notMatched")

        case .powerSource:
            guard let expected = trigger.value?.stringValue.flatMap(ScenePowerSource.init),
                context.powerSource != .unknown
            else {
                return .unavailable(redactedReason: "scene.trigger.power.unavailable")
            }
            return expected == context.powerSource
                ? .matched(redactedReason: "scene.trigger.power.matched")
                : .notMatched(redactedReason: "scene.trigger.power.notMatched")

        case .networkExpensive:
            guard let expected = trigger.value?.boolValue,
                let actual = context.networkExpensive
            else {
                return .unavailable(redactedReason: "scene.trigger.expensive.unavailable")
            }
            return expected == actual
                ? .matched(redactedReason: "scene.trigger.expensive.matched")
                : .notMatched(redactedReason: "scene.trigger.expensive.notMatched")

        case .networkConstrained:
            guard let expected = trigger.value?.boolValue,
                let actual = context.networkConstrained
            else {
                return .unavailable(redactedReason: "scene.trigger.constrained.unavailable")
            }
            return expected == actual
                ? .matched(redactedReason: "scene.trigger.constrained.matched")
                : .notMatched(redactedReason: "scene.trigger.constrained.notMatched")
        }
    }

    private func matches(
        window: SceneLocalTimeWindow,
        context: SceneEvaluationContext
    ) -> Bool {
        let calendar = context.calendar
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: context.now)
        guard let weekday = components.weekday,
            let hour = components.hour,
            let minute = components.minute
        else { return false }
        let minuteOfDay = hour * 60 + minute
        let selectedWeekdays = Set(window.weekdays)

        if window.startMinute < window.endMinute {
            return selectedWeekdays.contains(weekday)
                && minuteOfDay >= window.startMinute
                && minuteOfDay < window.endMinute
        }

        if minuteOfDay >= window.startMinute {
            return selectedWeekdays.contains(weekday)
        }
        guard minuteOfDay < window.endMinute,
            let previousDay = calendar.date(byAdding: .day, value: -1, to: context.now)
        else { return false }
        return selectedWeekdays.contains(calendar.component(.weekday, from: previousDay))
    }

    private nonisolated static func matchPrecedes(_ lhs: SceneMatch, _ rhs: SceneMatch) -> Bool {
        if lhs.scene.priority != rhs.scene.priority {
            return lhs.scene.priority > rhs.scene.priority
        }
        if lhs.specificity != rhs.specificity {
            return lhs.specificity > rhs.specificity
        }
        return lhs.scene.id.uuidString < rhs.scene.id.uuidString
    }
}
