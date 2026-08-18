import Foundation
import Observation

nonisolated enum SceneActivationOrigin: Equatable, Sendable {
    case manual
    case automatic(evaluatedAt: Date, summary: SceneEvaluationSummary)
}

@MainActor
@Observable
final class SceneFeatureController {
    private(set) var document = SceneStoreDocument()
    private(set) var selectedSceneID: UUID?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isActivating = false
    private(set) var lastTestDecision: SceneDecision?
    private(set) var lastError: UserFacingError?

    @ObservationIgnored private let store: SceneStore
    @ObservationIgnored private let evaluator: SceneEvaluator
    @ObservationIgnored private let transitionCoordinator: SceneTransitionCoordinator
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var automationTask: Task<Void, Never>?
    @ObservationIgnored private var hasBootstrapped = false

    init(
        store: SceneStore,
        evaluator: SceneEvaluator = SceneEvaluator(),
        transitionCoordinator: SceneTransitionCoordinator,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.store = store
        self.evaluator = evaluator
        self.transitionCoordinator = transitionCoordinator
        self.now = now
    }

    deinit {
        automationTask?.cancel()
    }

    var scenes: [VelaScene] {
        document.scenes.sorted(by: Self.scenePrecedes)
    }

    var selectedScene: VelaScene? {
        scenes.first { $0.id == selectedSceneID }
    }

    var activeScene: VelaScene? {
        scenes.first { $0.id == document.activeSceneID }
    }

    var transitionPhase: SceneTransitionPhase {
        transitionCoordinator.phase
    }

    var isBusy: Bool {
        isLoading || isSaving || isActivating
    }

    func bootstrap(
        engineStore: EngineStore,
        startsAutomation: Bool = true
    ) async {
        guard !hasBootstrapped else {
            if startsAutomation {
                startAutomation(engineStore: engineStore)
                await evaluateCurrentNetwork(engineStore: engineStore)
            }
            return
        }
        isLoading = true
        do {
            document = try await store.document()
            selectedSceneID = document.activeSceneID ?? scenes.first?.id
            engineStore.restoreActiveSceneConfiguration(document.activeSceneID)
            hasBootstrapped = true
            isLoading = false
            if startsAutomation {
                startAutomation(engineStore: engineStore)
                await evaluateCurrentNetwork(engineStore: engineStore)
            }
        } catch {
            isLoading = false
            present(
                error,
                title: VelaL10n.string(
                    "scenes.error.load.title",
                    defaultValue: "Scenes Could Not Be Loaded"
                )
            )
        }
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await reloadDocument()
        } catch {
            present(
                error,
                title: VelaL10n.string(
                    "scenes.error.load.title",
                    defaultValue: "Scenes Could Not Be Loaded"
                )
            )
        }
    }

    func select(_ id: UUID?) {
        selectedSceneID = id
        lastTestDecision = nil
    }

    func save(_ scene: VelaScene) async -> Bool {
        guard !isBusy else { return false }
        guard scene.id != document.activeSceneID else {
            lastError = UserFacingError(
                title: VelaL10n.string(
                    "scenes.error.editActive.title",
                    defaultValue: "Active Scene Cannot Be Edited"
                ),
                message: VelaL10n.string(
                    "scenes.error.editActive.message",
                    defaultValue: "Activate another Scene before editing this Scene so the saved definition cannot diverge from the active runtime."
                ),
                isRetryable: false
            )
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let committed = try await store.upsert(scene)
            try await reloadDocument()
            selectedSceneID = committed.id
            lastError = nil
            return true
        } catch {
            present(
                error,
                title: VelaL10n.string(
                    "scenes.error.save.title",
                    defaultValue: "Scene Could Not Be Saved"
                )
            )
            return false
        }
    }

    func deleteSelectedScene() async {
        guard let selectedSceneID, !isBusy else { return }
        guard selectedSceneID != document.activeSceneID else {
            lastError = UserFacingError(
                title: VelaL10n.string(
                    "scenes.error.deleteActive.title",
                    defaultValue: "Active Scene Cannot Be Deleted"
                ),
                message: VelaL10n.string(
                    "scenes.error.deleteActive.message",
                    defaultValue: "Activate another Scene or stop using this Scene before deleting it."
                ),
                isRetryable: false
            )
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.remove(id: selectedSceneID)
            try await reloadDocument()
            self.selectedSceneID = document.activeSceneID ?? scenes.first?.id
            lastTestDecision = nil
            lastError = nil
        } catch {
            present(
                error,
                title: VelaL10n.string(
                    "scenes.error.delete.title",
                    defaultValue: "Scene Could Not Be Deleted"
                )
            )
        }
    }

    func setAutomaticScenesEnabled(_ enabled: Bool, engineStore: EngineStore) async {
        guard !isBusy else { return }
        isSaving = true
        do {
            try await store.setAutomaticScenesEnabled(enabled)
            try await reloadDocument()
            isSaving = false
            if enabled {
                await evaluateCurrentNetwork(engineStore: engineStore)
            }
        } catch {
            isSaving = false
            present(
                error,
                title: VelaL10n.string(
                    "scenes.error.automation.title",
                    defaultValue: "Automatic Scenes Could Not Be Updated"
                )
            )
        }
    }

    func activateSelectedScene() async {
        guard let selectedScene else { return }
        await activate(selectedScene, origin: .manual)
    }

    func activate(
        _ scene: VelaScene,
        origin: SceneActivationOrigin
    ) async {
        guard !isBusy else { return }
        guard !document.manualRepairRequired else {
            lastError = UserFacingError(
                title: VelaL10n.string(
                    "scenes.error.repairRequired.title",
                    defaultValue: "Scene Repair Is Required"
                ),
                message: VelaL10n.string(
                    "scenes.error.repairRequired.message",
                    defaultValue: "Automatic and manual Scene changes are paused until the previous rollback is repaired."
                ),
                isRetryable: false,
                recoveryActions: [.openDiagnostics]
            )
            return
        }

        isActivating = true
        let outcome = await transitionCoordinator.activate(
            scene,
            replacing: document.activeSceneID
        )
        var runtimeWasCommitted = false
        do {
            switch outcome {
            case .activated:
                runtimeWasCommitted = true
                let timestamp = now()
                let persistence = activationPersistence(
                    scene: scene,
                    origin: origin,
                    timestamp: timestamp
                )
                try await store.setActiveScene(
                    id: scene.id,
                    manualLockUntil: persistence.manualLockUntil,
                    lastAutomaticSwitchAt: persistence.lastAutomaticSwitchAt,
                    evaluation: persistence.summary
                )
                try await store.setManualRepairRequired(false)
                try await reloadDocument()
                selectedSceneID = scene.id
                lastError = nil
            case let .rejected(_, reason):
                presentSceneTransitionFailure(reason)
            case let .rolledBack(_, reason):
                presentSceneTransitionFailure(reason)
            case let .manualRepairRequired(_, originalReason, rollbackReason):
                try await store.setManualRepairRequired(
                    true,
                    reason: "scene.rollbackFailed"
                )
                try await reloadDocument()
                lastError = UserFacingError(
                    title: VelaL10n.string(
                        "scenes.error.rollback.title",
                        defaultValue: "Scene Rollback Needs Repair"
                    ),
                    message: VelaL10n.string(
                        "scenes.error.rollback.messageFormat",
                        defaultValue: "The Scene failed (%@), and Vela could not fully restore the previous runtime (%@).",
                        arguments: originalReason,
                        rollbackReason
                    ),
                    isRetryable: false,
                    recoveryActions: [.openDiagnostics]
                )
            }
        } catch {
            if runtimeWasCommitted {
                await handleCommittedRuntimePersistenceFailure(error)
            } else {
                present(
                    error,
                    title: VelaL10n.string(
                        "scenes.error.state.title",
                        defaultValue: "Scene State Could Not Be Saved"
                    )
                )
            }
        }
        isActivating = false
    }

    private func handleCommittedRuntimePersistenceFailure(_ error: any Error) async {
        // The runtime transition already committed, so the last durable Scene
        // record cannot be trusted. Fail closed in memory first, then persist
        // the repair gate on a best-effort basis. No further automatic or
        // manual Scene mutation is allowed until Diagnostics proves repair.
        document.automaticScenesEnabled = false
        document.manualRepairRequired = true
        document.manualRepairReasonCode = "scene.activationStatePersistenceFailed"
        do {
            try await store.setManualRepairRequired(
                true,
                reason: "scene.activationStatePersistenceFailed"
            )
            try await reloadDocument()
        } catch {
            // Keep the stricter in-memory gate when even the repair marker
            // cannot be written; replacing it with stale disk state is unsafe.
        }
        lastError = UserFacingError(
            title: VelaL10n.string(
                "scenes.error.state.title",
                defaultValue: "Scene State Could Not Be Saved"
            ),
            message: VelaL10n.string(
                "scenes.error.state.committedMessage",
                defaultValue: "The runtime changed, but Vela could not save the active Scene record. Scene changes are paused until Diagnostics confirms repair."
            ),
            technicalDetails: DiagnosticTextSanitizer.redact(
                error.localizedDescription
            ),
            isRetryable: false,
            recoveryActions: [.openDiagnostics]
        )
    }

    func test(_ scene: VelaScene, context: SceneEvaluationContext) {
        lastTestDecision = evaluator.evaluateScene(scene, context: context)
    }

    func testSelectedScene(engineStore: EngineStore) {
        guard let selectedScene else { return }
        test(selectedScene, context: evaluationContext(engineStore: engineStore))
    }

    func evaluateCurrentNetwork(engineStore: EngineStore) async {
        guard hasBootstrapped, !isBusy else { return }
        let context = evaluationContext(engineStore: engineStore)
        do {
            let latest = try await store.document()
            document = latest
            let result = evaluator.evaluate(
                scenes: latest.scenes,
                state: SceneAutomationEvaluationState(document: latest),
                context: context
            )
            guard result.summary.outcome == .selected,
                let candidate = result.selectedScene
            else {
                try await store.setActiveScene(
                    id: latest.activeSceneID,
                    manualLockUntil: latest.manualLockUntil,
                    lastAutomaticSwitchAt: latest.lastAutomaticSwitchAt,
                    evaluation: result.summary
                )
                try await reloadDocument()
                return
            }
            await activate(
                candidate,
                origin: .automatic(
                    evaluatedAt: context.now,
                    summary: result.summary
                )
            )
        } catch {
            present(
                error,
                title: VelaL10n.string(
                    "scenes.error.automation.title",
                    defaultValue: "Automatic Scenes Could Not Be Updated"
                )
            )
        }
    }

    func dismissError() {
        lastError = nil
    }

    private func startAutomation(engineStore: EngineStore) {
        guard automationTask == nil else { return }
        automationTask = Task { @MainActor [weak self, weak engineStore] in
            guard let self, let engineStore else { return }
            for await event in engineStore.lifecycleEvents() {
                guard !Task.isCancelled else { return }
                guard case .networkAvailabilityChanged = event else { continue }
                await self.releaseNetworkChangeLockIfNeeded()
                await self.evaluateCurrentNetwork(engineStore: engineStore)
            }
        }
    }

    private func releaseNetworkChangeLockIfNeeded() async {
        guard let activeScene,
            case .untilNextNetworkChange = activeScene.manualLockPolicy,
            document.manualLockUntil != nil
        else { return }
        do {
            try await store.setActiveScene(
                id: document.activeSceneID,
                manualLockUntil: nil,
                lastAutomaticSwitchAt: document.lastAutomaticSwitchAt,
                evaluation: document.lastEvaluation
            )
            try await reloadDocument()
        } catch {
            present(
                error,
                title: VelaL10n.string(
                    "scenes.error.state.title",
                    defaultValue: "Scene State Could Not Be Saved"
                )
            )
        }
    }

    private func reloadDocument() async throws {
        document = try await store.document()
        if let selectedSceneID,
            !document.scenes.contains(where: { $0.id == selectedSceneID })
        {
            self.selectedSceneID = document.activeSceneID ?? scenes.first?.id
        }
    }

    private func activationPersistence(
        scene: VelaScene,
        origin: SceneActivationOrigin,
        timestamp: Date
    ) -> (
        manualLockUntil: Date?,
        lastAutomaticSwitchAt: Date?,
        summary: SceneEvaluationSummary?
    ) {
        switch origin {
        case .manual:
            let lockUntil: Date? = switch scene.manualLockPolicy {
            case .none:
                nil
            case let .duration(seconds):
                timestamp.addingTimeInterval(TimeInterval(seconds))
            case .untilNextNetworkChange, .untilDisabled:
                .distantFuture
            }
            return (
                lockUntil,
                document.lastAutomaticSwitchAt,
                SceneEvaluationSummary(
                    evaluatedAt: timestamp,
                    selectedSceneID: scene.id,
                    recommendedSceneID: scene.id,
                    outcome: .selected,
                    evaluatedSceneCount: document.scenes.count,
                    matchingSceneIDs: []
                )
            )
        case let .automatic(evaluatedAt, summary):
            return (nil, evaluatedAt, summary)
        }
    }

    private func evaluationContext(engineStore: EngineStore) -> SceneEvaluationContext {
        let path = engineStore.networkPathSnapshot
        let interface: SceneNetworkInterface? = switch path.interfaceKind {
        case .wifi: .wifi
        case .wiredEthernet: .wiredEthernet
        case .other: .other
        case nil: nil
        }
        let isKnownPath = path.status != .unknown
        return SceneEvaluationContext(
            now: now(),
            networkInterface: interface,
            ssidState: interface == .wifi ? .unavailable : .notOnWiFi,
            powerSource: .unknown,
            networkExpensive: isKnownPath ? path.isExpensive : nil,
            networkConstrained: isKnownPath ? path.isConstrained : nil
        )
    }

    private func presentSceneTransitionFailure(_ reason: String) {
        lastError = UserFacingError(
            title: VelaL10n.string(
                "scenes.error.activation.title",
                defaultValue: "Scene Could Not Be Activated"
            ),
            message: reason,
            suggestedAction: VelaL10n.string(
                "scenes.error.activation.suggestion",
                defaultValue: "Review the Scene target and Diagnostics, then try again."
            ),
            isRetryable: true,
            recoveryActions: [.openDiagnostics]
        )
    }

    private func present(_ error: any Error, title: String) {
        lastError = UserFacingError(
            title: title,
            message: DiagnosticTextSanitizer.redact(error.localizedDescription),
            suggestedAction: VelaL10n.string(
                "scenes.error.retry.suggestion",
                defaultValue: "Review the Scene and try again."
            ),
            isRetryable: true
        )
    }

    private nonisolated static func scenePrecedes(_ lhs: VelaScene, _ rhs: VelaScene) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
