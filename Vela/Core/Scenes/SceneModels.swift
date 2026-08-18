import Foundation

nonisolated enum SceneBackendPreference: String, CaseIterable, Codable, Equatable, Sendable {
    case keepCurrent
    case systemProxy
    case tun
    case engineOnly
    case off
}

nonisolated enum SceneProxyMissingPolicy: String, CaseIterable, Codable, Equatable, Sendable {
    case keepDefault
    case failScene
    case warnAndContinue
}

nonisolated struct SceneProxySelection: Codable, Equatable, Sendable {
    var groupID: String?
    var groupName: String
    var proxyID: String?
    var proxyName: String
    var missingPolicy: SceneProxyMissingPolicy

    init(
        groupID: String? = nil,
        groupName: String,
        proxyID: String? = nil,
        proxyName: String,
        missingPolicy: SceneProxyMissingPolicy = .warnAndContinue
    ) {
        self.groupID = groupID
        self.groupName = groupName
        self.proxyID = proxyID
        self.proxyName = proxyName
        self.missingPolicy = missingPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case groupID
        case groupName
        case proxyID
        case proxyName
        case missingPolicy
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
        groupName = try container.decode(String.self, forKey: .groupName)
        proxyID = try container.decodeIfPresent(String.self, forKey: .proxyID)
        proxyName = try container.decode(String.self, forKey: .proxyName)
        missingPolicy = try container.decodeIfPresent(
            SceneProxyMissingPolicy.self,
            forKey: .missingPolicy
        ) ?? .warnAndContinue
    }
}

nonisolated enum ManualLockPolicy: Equatable, Sendable {
    static let defaultDurationSeconds = 30 * 60

    case none
    case duration(seconds: Int)
    case untilNextNetworkChange
    case untilDisabled
}

extension ManualLockPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case seconds
    }

    private enum Kind: String, Codable {
        case none
        case duration
        case untilNextNetworkChange
        case untilDisabled
    }

    init(from decoder: any Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
            let rawValue = try? singleValue.decode(String.self)
        {
            switch rawValue {
            case Kind.none.rawValue:
                self = .none
            case "thirtyMinutes":
                self = .duration(seconds: Self.defaultDurationSeconds)
            case Kind.untilNextNetworkChange.rawValue:
                self = .untilNextNetworkChange
            case Kind.untilDisabled.rawValue:
                self = .untilDisabled
            default:
                throw DecodingError.dataCorruptedError(
                    in: singleValue,
                    debugDescription: "Unsupported manual lock policy."
                )
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .duration:
            self = .duration(seconds: try container.decode(Int.self, forKey: .seconds))
        case .untilNextNetworkChange:
            self = .untilNextNetworkChange
        case .untilDisabled:
            self = .untilDisabled
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .none:
            var container = encoder.singleValueContainer()
            try container.encode(Kind.none.rawValue)
        case let .duration(seconds):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.duration, forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
        case .untilNextNetworkChange:
            var container = encoder.singleValueContainer()
            try container.encode(Kind.untilNextNetworkChange.rawValue)
        case .untilDisabled:
            var container = encoder.singleValueContainer()
            try container.encode(Kind.untilDisabled.rawValue)
        }
    }
}

nonisolated enum SceneTriggerKind: String, CaseIterable, Codable, Equatable, Sendable {
    case networkInterface
    case wifiSSID
    case localTimeWindow
    case powerSource
    case networkExpensive
    case networkConstrained
}

nonisolated enum SceneNetworkInterface: String, CaseIterable, Codable, Equatable, Sendable {
    case wifi
    case wiredEthernet
    case other
}

nonisolated enum ScenePowerSource: String, CaseIterable, Codable, Equatable, Sendable {
    case ac
    case battery
    case unknown
}

nonisolated enum SceneTriggerValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
}

extension SceneTriggerValue: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A Scene trigger value must be a string, Boolean or integer."
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        }
    }
}

/// A local-calendar time window. Weekdays use Calendar's 1...7 weekday values.
/// An end minute earlier than the start minute represents an overnight window.
nonisolated struct SceneLocalTimeWindow: Codable, Equatable, Sendable {
    var weekdays: [Int]
    var startMinute: Int
    var endMinute: Int

    init(weekdays: [Int], startMinute: Int, endMinute: Int) {
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

nonisolated struct SceneTrigger: Codable, Equatable, Sendable {
    var kind: SceneTriggerKind
    var enabled: Bool
    var value: SceneTriggerValue?
    var secretReference: String?
    var secretHash: String?
    var displayLabel: String?
    var timeWindow: SceneLocalTimeWindow?

    init(
        kind: SceneTriggerKind,
        enabled: Bool = true,
        value: SceneTriggerValue? = nil,
        secretReference: String? = nil,
        secretHash: String? = nil,
        displayLabel: String? = nil,
        timeWindow: SceneLocalTimeWindow? = nil
    ) {
        self.kind = kind
        self.enabled = enabled
        self.value = value
        self.secretReference = secretReference
        self.secretHash = secretHash
        self.displayLabel = displayLabel
        self.timeWindow = timeWindow
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case enabled
        case value
        case secretReference
        case secretHash
        case displayLabel
        case timeWindow
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(SceneTriggerKind.self, forKey: .kind)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        value = try container.decodeIfPresent(SceneTriggerValue.self, forKey: .value)
        secretReference = try container.decodeIfPresent(String.self, forKey: .secretReference)
        secretHash = try container.decodeIfPresent(String.self, forKey: .secretHash)
        displayLabel = try container.decodeIfPresent(String.self, forKey: .displayLabel)
        timeWindow = try container.decodeIfPresent(
            SceneLocalTimeWindow.self,
            forKey: .timeWindow
        )
    }
}

nonisolated struct SceneTriggerGroup: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var triggers: [SceneTrigger]

    init(id: UUID = UUID(), triggers: [SceneTrigger]) {
        self.id = id
        self.triggers = triggers
    }
}

nonisolated struct VelaScene: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1
    static let defaultSymbolName = "network"
    static let defaultCooldownSeconds = 60
    static let defaultTimestamp = Date(timeIntervalSince1970: 0)

    let id: UUID
    var schemaVersion: Int
    var name: String
    var symbolName: String
    var enabled: Bool
    var priority: Int
    var profileID: UUID?
    var backend: SceneBackendPreference
    var mihomoMode: MihomoMode?
    var proxySelections: [SceneProxySelection]
    var configurationLayerID: UUID?
    var triggerGroups: [SceneTriggerGroup]
    var cooldownSeconds: Int
    var manualLockPolicy: ManualLockPolicy
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        schemaVersion: Int = currentSchemaVersion,
        name: String,
        symbolName: String = defaultSymbolName,
        enabled: Bool = true,
        priority: Int = 0,
        profileID: UUID? = nil,
        backend: SceneBackendPreference = .keepCurrent,
        mihomoMode: MihomoMode? = nil,
        proxySelections: [SceneProxySelection] = [],
        configurationLayerID: UUID? = nil,
        triggerGroups: [SceneTriggerGroup] = [],
        cooldownSeconds: Int = defaultCooldownSeconds,
        manualLockPolicy: ManualLockPolicy = .duration(
            seconds: ManualLockPolicy.defaultDurationSeconds
        ),
        createdAt: Date = defaultTimestamp,
        updatedAt: Date = defaultTimestamp
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.symbolName = symbolName
        self.enabled = enabled
        self.priority = priority
        self.profileID = profileID
        self.backend = backend
        self.mihomoMode = mihomoMode
        self.proxySelections = proxySelections
        self.configurationLayerID = configurationLayerID
        self.triggerGroups = triggerGroups
        self.cooldownSeconds = cooldownSeconds
        self.manualLockPolicy = manualLockPolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case name
        case symbolName
        case enabled
        case priority
        case profileID
        case backend
        case mihomoMode
        case proxySelections
        case configurationLayerID
        case triggerGroups
        case cooldownSeconds
        case manualLockPolicy
        case createdAt
        case updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        name = try container.decode(String.self, forKey: .name)
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)
            ?? Self.defaultSymbolName
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        backend = try container.decodeIfPresent(
            SceneBackendPreference.self,
            forKey: .backend
        ) ?? .keepCurrent
        mihomoMode = try container.decodeIfPresent(MihomoMode.self, forKey: .mihomoMode)
        proxySelections = try container.decodeIfPresent(
            [SceneProxySelection].self,
            forKey: .proxySelections
        ) ?? []
        configurationLayerID = try container.decodeIfPresent(
            UUID.self,
            forKey: .configurationLayerID
        )
        triggerGroups = try container.decodeIfPresent(
            [SceneTriggerGroup].self,
            forKey: .triggerGroups
        ) ?? []
        cooldownSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .cooldownSeconds
        ) ?? Self.defaultCooldownSeconds
        manualLockPolicy = try container.decodeIfPresent(
            ManualLockPolicy.self,
            forKey: .manualLockPolicy
        ) ?? .duration(seconds: ManualLockPolicy.defaultDurationSeconds)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? Self.defaultTimestamp
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? createdAt
    }

    func validated() throws -> VelaScene {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneValidationError.unsupportedSchemaVersion(schemaVersion)
        }

        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 120 else {
            throw SceneValidationError.invalidName
        }
        result.symbolName = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.symbolName.isEmpty, result.symbolName.count <= 120 else {
            throw SceneValidationError.invalidSymbolName
        }
        guard (-100...100).contains(priority) else {
            throw SceneValidationError.invalidPriority(priority)
        }
        guard (0...86_400).contains(cooldownSeconds) else {
            throw SceneValidationError.invalidCooldown(cooldownSeconds)
        }
        if case let .duration(seconds) = manualLockPolicy,
            !(0...604_800).contains(seconds)
        {
            throw SceneValidationError.invalidManualLockDuration(seconds)
        }
        guard triggerGroups.count <= 16 else {
            throw SceneValidationError.tooManyTriggerGroups(triggerGroups.count)
        }

        for groupIndex in result.triggerGroups.indices {
            for triggerIndex in result.triggerGroups[groupIndex].triggers.indices {
                var trigger = result.triggerGroups[groupIndex].triggers[triggerIndex]
                trigger.secretReference = trigger.secretReference?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                trigger.secretHash = trigger.secretHash?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                trigger.displayLabel = trigger.displayLabel?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if var window = trigger.timeWindow {
                    window.weekdays.sort()
                    trigger.timeWindow = window
                }
                result.triggerGroups[groupIndex].triggers[triggerIndex] = trigger
            }
        }

        var groupIDs: Set<UUID> = []
        for group in result.triggerGroups {
            guard groupIDs.insert(group.id).inserted else {
                throw SceneValidationError.duplicateTriggerGroupID(group.id)
            }
            guard !group.triggers.isEmpty else {
                throw SceneValidationError.emptyTriggerGroup(group.id)
            }
            guard group.triggers.count <= 16 else {
                throw SceneValidationError.tooManyTriggers(
                    groupID: group.id,
                    count: group.triggers.count
                )
            }
            guard group.triggers.contains(where: \.enabled) else {
                throw SceneValidationError.triggerGroupHasNoEnabledTriggers(group.id)
            }
            for trigger in group.triggers {
                try Self.validate(trigger, groupID: group.id)
            }
        }

        var seenProxyGroups: Set<String> = []
        for index in result.proxySelections.indices {
            result.proxySelections[index].groupName = result.proxySelections[index].groupName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.proxySelections[index].proxyName = result.proxySelections[index].proxyName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.proxySelections[index].groupName.isEmpty else {
                throw SceneValidationError.invalidProxyGroupName
            }
            guard !result.proxySelections[index].proxyName.isEmpty else {
                throw SceneValidationError.invalidProxyName
            }
            let normalizedGroup = result.proxySelections[index].groupName
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
            guard seenProxyGroups.insert(normalizedGroup).inserted else {
                throw SceneValidationError.duplicateProxyGroupSelection
            }
        }

        guard createdAt <= updatedAt else {
            throw SceneValidationError.invalidTimestamps
        }
        return result
    }

    private static func validate(_ trigger: SceneTrigger, groupID: UUID) throws {
        guard trigger.enabled else { return }

        switch trigger.kind {
        case .networkInterface:
            guard let value = trigger.value?.stringValue,
                SceneNetworkInterface(rawValue: value) != nil
            else {
                throw SceneValidationError.invalidNetworkInterface(groupID)
            }
        case .wifiSSID:
            // Plain SSIDs never belong in the Scene document. Matching is done
            // outside this model and passed to the evaluator as opaque refs.
            guard trigger.value == nil else {
                throw SceneValidationError.plaintextSSIDForbidden(groupID)
            }
            guard let reference = trigger.secretReference?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !reference.isEmpty,
                reference.count <= 240,
                reference.contains("/"),
                reference.unicodeScalars.allSatisfy({ scalar in
                    CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "/"
                        || scalar == "."
                        || scalar == "_"
                        || scalar == "-"
                })
            else {
                throw SceneValidationError.missingSSIDSecretReference(groupID)
            }
            if let hash = trigger.secretHash {
                guard hash.count == 64,
                    hash.unicodeScalars.allSatisfy({ scalar in
                        (48...57).contains(scalar.value)
                            || (65...70).contains(scalar.value)
                            || (97...102).contains(scalar.value)
                    })
                else {
                    throw SceneValidationError.invalidSSIDHash(groupID)
                }
            }
        case .localTimeWindow:
            guard let window = trigger.timeWindow,
                !window.weekdays.isEmpty,
                window.weekdays.allSatisfy({ (1...7).contains($0) }),
                Set(window.weekdays).count == window.weekdays.count,
                (0..<1_440).contains(window.startMinute),
                (0..<1_440).contains(window.endMinute),
                window.startMinute != window.endMinute
            else {
                throw SceneValidationError.invalidTimeWindow(groupID)
            }
        case .powerSource:
            guard let value = trigger.value?.stringValue,
                value != ScenePowerSource.unknown.rawValue,
                ScenePowerSource(rawValue: value) != nil
            else {
                throw SceneValidationError.invalidPowerSource(groupID)
            }
        case .networkExpensive, .networkConstrained:
            guard trigger.value?.boolValue != nil else {
                throw SceneValidationError.invalidBooleanTrigger(groupID)
            }
        }
    }
}

nonisolated enum SceneEvaluationOutcomeCode: String, Codable, Equatable, Sendable {
    case selected
    case alreadyActive
    case noMatchingScene
    case automaticDisabled
    case manualLock
    case cooldown
    case repairRequired
    case draftPending
}

/// Persistable evaluator evidence. It intentionally contains only opaque IDs,
/// counts, trigger kinds and outcome codes; reasons and trigger values stay in memory.
nonisolated struct SceneEvaluationSummary: Codable, Equatable, Sendable {
    let evaluatedAt: Date
    let selectedSceneID: UUID?
    let recommendedSceneID: UUID?
    let outcome: SceneEvaluationOutcomeCode
    let evaluatedSceneCount: Int
    let matchingSceneIDs: [UUID]
    let blockedTriggerKinds: [SceneTriggerKind]

    init(
        evaluatedAt: Date,
        selectedSceneID: UUID? = nil,
        recommendedSceneID: UUID? = nil,
        outcome: SceneEvaluationOutcomeCode,
        evaluatedSceneCount: Int,
        matchingSceneIDs: [UUID] = [],
        blockedTriggerKinds: [SceneTriggerKind] = []
    ) {
        self.evaluatedAt = evaluatedAt
        self.selectedSceneID = selectedSceneID
        self.recommendedSceneID = recommendedSceneID
        self.outcome = outcome
        self.evaluatedSceneCount = evaluatedSceneCount
        self.matchingSceneIDs = matchingSceneIDs
        self.blockedTriggerKinds = blockedTriggerKinds
    }
}

nonisolated struct SceneStoreDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var scenes: [VelaScene]
    var activeSceneID: UUID?
    var automaticScenesEnabled: Bool
    var manualLockUntil: Date?
    var lastAutomaticSwitchAt: Date?
    var lastEvaluation: SceneEvaluationSummary?
    var manualRepairRequired: Bool
    var manualRepairReasonCode: String?

    init(
        schemaVersion: Int = currentSchemaVersion,
        scenes: [VelaScene] = [],
        activeSceneID: UUID? = nil,
        automaticScenesEnabled: Bool = false,
        manualLockUntil: Date? = nil,
        lastAutomaticSwitchAt: Date? = nil,
        lastEvaluation: SceneEvaluationSummary? = nil,
        manualRepairRequired: Bool = false,
        manualRepairReasonCode: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.scenes = scenes
        self.activeSceneID = activeSceneID
        self.automaticScenesEnabled = automaticScenesEnabled
        self.manualLockUntil = manualLockUntil
        self.lastAutomaticSwitchAt = lastAutomaticSwitchAt
        self.lastEvaluation = lastEvaluation
        self.manualRepairRequired = manualRepairRequired
        self.manualRepairReasonCode = manualRepairReasonCode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case scenes
        case activeSceneID
        case automaticScenesEnabled
        case manualLockUntil
        case lastAutomaticSwitchAt
        case lastEvaluation
        case manualRepairRequired
        case manualRepairReasonCode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        scenes = try container.decodeIfPresent([VelaScene].self, forKey: .scenes) ?? []
        activeSceneID = try container.decodeIfPresent(UUID.self, forKey: .activeSceneID)
        automaticScenesEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticScenesEnabled
        ) ?? false
        manualLockUntil = try container.decodeIfPresent(Date.self, forKey: .manualLockUntil)
        lastAutomaticSwitchAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastAutomaticSwitchAt
        )
        lastEvaluation = try container.decodeIfPresent(
            SceneEvaluationSummary.self,
            forKey: .lastEvaluation
        )
        manualRepairRequired = try container.decodeIfPresent(
            Bool.self,
            forKey: .manualRepairRequired
        ) ?? false
        manualRepairReasonCode = try container.decodeIfPresent(
            String.self,
            forKey: .manualRepairReasonCode
        )
    }
}

nonisolated enum SceneValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidName
    case invalidSymbolName
    case invalidPriority(Int)
    case invalidCooldown(Int)
    case invalidManualLockDuration(Int)
    case tooManyTriggerGroups(Int)
    case duplicateTriggerGroupID(UUID)
    case emptyTriggerGroup(UUID)
    case tooManyTriggers(groupID: UUID, count: Int)
    case triggerGroupHasNoEnabledTriggers(UUID)
    case invalidNetworkInterface(UUID)
    case plaintextSSIDForbidden(UUID)
    case missingSSIDSecretReference(UUID)
    case invalidSSIDHash(UUID)
    case invalidTimeWindow(UUID)
    case invalidPowerSource(UUID)
    case invalidBooleanTrigger(UUID)
    case invalidProxyGroupName
    case invalidProxyName
    case duplicateProxyGroupSelection
    case invalidTimestamps
}

extension SceneValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion:
            "This Scene uses an unsupported data version."
        case .invalidName:
            "Enter a Scene name between 1 and 120 characters."
        case .invalidSymbolName:
            "Choose a valid symbol for this Scene."
        case .invalidPriority:
            "Scene priority must be between -100 and 100."
        case .invalidCooldown:
            "Scene cooldown must be between 0 seconds and 24 hours."
        case .invalidManualLockDuration:
            "The manual lock duration is outside the supported range."
        case .tooManyTriggerGroups:
            "A Scene can contain at most 16 trigger groups."
        case .duplicateTriggerGroupID:
            "Two Scene trigger groups have the same identifier."
        case .emptyTriggerGroup:
            "A trigger group cannot be empty. Remove the group or add a trigger."
        case .tooManyTriggers:
            "A Scene trigger group can contain at most 16 triggers."
        case .triggerGroupHasNoEnabledTriggers:
            "A trigger group must contain at least one enabled trigger."
        case .invalidNetworkInterface:
            "Choose a supported network interface for this trigger."
        case .plaintextSSIDForbidden:
            "Wi-Fi names must be stored securely, not in the Scene document."
        case .missingSSIDSecretReference:
            "Reconnect this Wi-Fi trigger to its secure value."
        case .invalidSSIDHash:
            "Reconnect this Wi-Fi trigger because its secure fingerprint is invalid."
        case .invalidTimeWindow:
            "Choose a valid local time window and at least one weekday."
        case .invalidPowerSource:
            "Choose AC power or battery power for this trigger."
        case .invalidBooleanTrigger:
            "The network condition trigger has an invalid value."
        case .invalidProxyGroupName:
            "Choose a proxy group for every Scene proxy selection."
        case .invalidProxyName:
            "Choose a proxy for every Scene proxy selection."
        case .duplicateProxyGroupSelection:
            "A Scene can select only one proxy in each proxy group."
        case .invalidTimestamps:
            "The Scene modification date cannot be earlier than its creation date."
        }
    }
}
