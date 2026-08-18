import Foundation
import VelaIPC

nonisolated enum MenuBarBackend: String, CaseIterable, Equatable, Sendable {
    case systemProxy
    case tun
    case engineOnly
}

nonisolated enum MenuBarFreshness: Equatable, Sendable {
    case live(verifiedAt: Date?, generation: UInt64)
    case stale(lastVerifiedAt: Date, ageSeconds: Int, generation: UInt64)
    case unknown
}

nonisolated enum MenuBarTunCapability: Equatable, Sendable {
    case ready
    case notInstalled
    case needsApproval
    case connecting
    case repairRequired
    case recoveryRequired
    case transitioning
}

nonisolated enum MenuBarOverallState: Equatable, Sendable {
    case connected(MenuBarBackend)
    case engineOnly
    case off
    case noProfile
    case partialFailure(issueCount: Int)
    case stale(ageSeconds: Int)
    case runtimeFailure
    case transitioning(current: MenuBarBackend?, requested: MenuBarBackend)
    case paused(remainingSeconds: Int)
    case recoveryRequired
    case quitPending
}

nonisolated enum MenuBarRefreshAction: Equatable, Sendable {
    case none
    case refreshStatus
    case reconnect
    case retryStatus
}

nonisolated enum MenuBarDisabledReason: Equatable, Sendable {
    case transitionInProgress
    case operationInProgress
    case profileRequired
    case controllerUnavailable
    case privilegedComponentUnavailable
    case currentBackendMustStop
    case alreadyActive
    case quitInProgress
}

nonisolated struct MenuBarActionAvailability: Equatable, Sendable {
    let canStart: Bool
    let canStop: Bool
    let canSelectSystemProxy: Bool
    let canSelectTun: Bool
    let canSelectScene: Bool
    let canSelectProxy: Bool
    let canPause: Bool
    let canResume: Bool
    let backendDisabledReason: MenuBarDisabledReason?
    let sceneDisabledReason: MenuBarDisabledReason?
    let proxyDisabledReason: MenuBarDisabledReason?
}

nonisolated struct MenuBarNamedValue: Equatable, Sendable {
    let displayName: String
    let fullName: String

    init(_ value: String, maximumLength: Int = 24) {
        fullName = value
        displayName = Self.shortened(value, maximumLength: maximumLength)
    }

    private static func shortened(_ value: String, maximumLength: Int) -> String {
        guard value.count > maximumLength, maximumLength > 1 else { return value }
        return String(value.prefix(maximumLength - 1)) + "…"
    }
}

nonisolated struct MenuBarPresentationSnapshot: Equatable, Sendable {
    let generation: UInt64
    let overallState: MenuBarOverallState
    let activeBackend: MenuBarBackend?
    let preferredBackend: MenuBarBackend?
    let requestedBackend: MenuBarBackend?
    let lastKnownBackend: MenuBarBackend?
    let transitionPhase: EngineTransitionPhase?
    let profile: MenuBarNamedValue?
    let mode: String?
    let scene: MenuBarNamedValue?
    let proxy: MenuBarNamedValue?
    let healthIssueCount: Int
    let freshness: MenuBarFreshness
    let tunCapability: MenuBarTunCapability
    let refreshAction: MenuBarRefreshAction
    let actions: MenuBarActionAvailability
}

nonisolated struct MenuBarPresentationInput: Sendable {
    let isRunning: Bool
    let engineFailed: Bool
    let controllerState: ControllerConnectionState
    let activeBackendKind: EngineBackendKind
    let activeRuntimeExists: Bool
    let systemProxyIsAuthoritativelyApplied: Bool
    let systemProxyWasManaged: Bool
    let preferredBackend: MenuBarBackend?
    let transitionSnapshot: EngineTransitionSnapshot
    let hasProfile: Bool
    let profileName: String?
    let modeName: String?
    let sceneName: String?
    let proxyName: String?
    let healthIssueCount: Int
    let lastVerifiedAt: Date?
    let generation: UInt64
    let tunCapability: MenuBarTunCapability
    let pauseDeadline: Date?
    let isBusy: Bool
    let canStart: Bool
    let canEnableSystemProxy: Bool
    let canRestoreSystemProxy: Bool
    let canEnableTun: Bool
    let controllerIsAuthoritative: Bool
    let sceneMutationInProgress: Bool
    let proxyMutationInProgress: Bool
    let isPreparingToTerminate: Bool
}

nonisolated enum MenuBarPresentationResolver {
    static func resolve(
        _ input: MenuBarPresentationInput,
        now: Date = .now
    ) -> MenuBarPresentationSnapshot {
        let activeBackend = authoritativeActiveBackend(input)
        let requestedBackend = requestedBackend(input)
        let isTransitioning = requestedBackend != nil
        let lastKnownBackend = lastKnownBackend(
            input,
            authoritativeActive: activeBackend,
            isTransitioning: isTransitioning
        )
        let freshness = freshness(input, now: now)
        let pausedRemaining = input.pauseDeadline.map {
            max(0, Int($0.timeIntervalSince(now).rounded(.up)))
        }
        let recoveryRequired = input.tunCapability == .recoveryRequired
        let overallState: MenuBarOverallState

        if input.isPreparingToTerminate {
            overallState = .quitPending
        } else if recoveryRequired {
            overallState = .recoveryRequired
        } else if let requestedBackend {
            overallState = .transitioning(
                current: activeBackend ?? lastKnownBackend,
                requested: requestedBackend
            )
        } else if let pausedRemaining, pausedRemaining > 0 {
            overallState = .paused(remainingSeconds: pausedRemaining)
        } else if !input.hasProfile {
            overallState = .noProfile
        } else if let activeBackend, activeBackend != .engineOnly {
            overallState = .connected(activeBackend)
        } else if input.engineFailed {
            overallState = .runtimeFailure
        } else if activeBackend == .engineOnly {
            overallState = .engineOnly
        } else {
            overallState = .off
        }

        let mutationBlocked = isTransitioning || input.isPreparingToTerminate || input.isBusy
        let backendDisabledReason: MenuBarDisabledReason? = if input.isPreparingToTerminate {
            .quitInProgress
        } else if isTransitioning {
            .transitionInProgress
        } else if input.isBusy {
            .operationInProgress
        } else if !input.hasProfile {
            .profileRequired
        } else {
            nil
        }
        let sceneDisabledReason: MenuBarDisabledReason? = if input.isPreparingToTerminate {
            .quitInProgress
        } else if isTransitioning || input.sceneMutationInProgress {
            .transitionInProgress
        } else if !input.hasProfile {
            .profileRequired
        } else {
            nil
        }
        let proxyDisabledReason: MenuBarDisabledReason? = if input.isPreparingToTerminate {
            .quitInProgress
        } else if isTransitioning || input.proxyMutationInProgress {
            .transitionInProgress
        } else if !input.controllerIsAuthoritative {
            .controllerUnavailable
        } else {
            nil
        }

        return MenuBarPresentationSnapshot(
            generation: input.generation,
            overallState: overallState,
            activeBackend: activeBackend,
            preferredBackend: input.preferredBackend,
            requestedBackend: requestedBackend,
            lastKnownBackend: lastKnownBackend,
            transitionPhase: input.transitionSnapshot.state.phase,
            profile: input.profileName.map { MenuBarNamedValue($0) },
            mode: input.modeName,
            scene: input.sceneName.map { MenuBarNamedValue($0) },
            proxy: input.proxyName.map { MenuBarNamedValue($0) },
            healthIssueCount: input.healthIssueCount,
            freshness: freshness,
            tunCapability: isTransitioning ? .transitioning : input.tunCapability,
            refreshAction: refreshAction(input, freshness: freshness),
            actions: MenuBarActionAvailability(
                canStart: input.canStart && !mutationBlocked,
                canStop: input.isRunning && !mutationBlocked,
                canSelectSystemProxy: !mutationBlocked
                    && (input.canEnableSystemProxy || input.canRestoreSystemProxy),
                canSelectTun: !mutationBlocked
                    && (activeBackend == .tun || input.canEnableTun),
                canSelectScene: sceneDisabledReason == nil,
                canSelectProxy: proxyDisabledReason == nil,
                canPause: activeBackend == .tun && !mutationBlocked,
                canResume: pausedRemaining != nil && !mutationBlocked,
                backendDisabledReason: backendDisabledReason,
                sceneDisabledReason: sceneDisabledReason,
                proxyDisabledReason: proxyDisabledReason
            )
        )
    }

    private static func authoritativeActiveBackend(
        _ input: MenuBarPresentationInput
    ) -> MenuBarBackend? {
        if input.activeBackendKind == .privilegedDaemon,
            input.activeRuntimeExists,
            input.isRunning
        {
            return .tun
        }
        if input.systemProxyIsAuthoritativelyApplied {
            return .systemProxy
        }
        if input.activeBackendKind == .userProcess,
            input.activeRuntimeExists,
            input.isRunning
        {
            return .engineOnly
        }
        return nil
    }

    private static func requestedBackend(
        _ input: MenuBarPresentationInput
    ) -> MenuBarBackend? {
        guard input.transitionSnapshot.state.phase != nil,
            let target = input.transitionSnapshot.target
        else { return nil }
        switch target {
        case .privilegedDaemon:
            return .tun
        case .userProcess:
            return input.preferredBackend == .systemProxy ? .systemProxy : .engineOnly
        }
    }

    private static func lastKnownBackend(
        _ input: MenuBarPresentationInput,
        authoritativeActive: MenuBarBackend?,
        isTransitioning: Bool
    ) -> MenuBarBackend? {
        guard authoritativeActive == nil else { return nil }
        guard input.lastVerifiedAt != nil || input.systemProxyWasManaged || isTransitioning else {
            return nil
        }
        if input.systemProxyWasManaged { return .systemProxy }
        return input.activeBackendKind == .privilegedDaemon ? .tun : .engineOnly
    }

    private static func freshness(
        _ input: MenuBarPresentationInput,
        now: Date
    ) -> MenuBarFreshness {
        guard let lastVerifiedAt = input.lastVerifiedAt else { return .unknown }
        let ageSeconds = max(0, Int(now.timeIntervalSince(lastVerifiedAt).rounded(.down)))
        switch input.controllerState {
        case .disconnected, .unavailable:
            return .stale(
                lastVerifiedAt: lastVerifiedAt,
                ageSeconds: ageSeconds,
                generation: input.generation
            )
        case .connecting, .connected:
            break
        }
        return .live(verifiedAt: lastVerifiedAt, generation: input.generation)
    }

    private static func refreshAction(
        _ input: MenuBarPresentationInput,
        freshness: MenuBarFreshness
    ) -> MenuBarRefreshAction {
        if input.engineFailed { return .retryStatus }
        if case .disconnected = input.controllerState { return .reconnect }
        if case .stale = freshness { return .refreshStatus }
        return .none
    }
}

@MainActor
extension MenuBarPresentationSnapshot {
    static func live(
        engineStore: EngineStore,
        sceneController: SceneFeatureController?,
        now: Date = .now
    ) -> Self {
        let componentCapability = tunCapability(
            manager: engineStore.privilegedComponentManager,
            transitionState: engineStore.transitionState
        )
        let issueCount = engineStore.lastHealthReport?.issues.count ?? 0
        let input = MenuBarPresentationInput(
            isRunning: engineStore.isRunning,
            engineFailed: engineStore.state.isFailed,
            controllerState: engineStore.controllerState,
            activeBackendKind: engineStore.activeBackendKind,
            activeRuntimeExists: engineStore.activeRuntime != nil,
            systemProxyIsAuthoritativelyApplied: engineStore.isSystemProxyApplied,
            systemProxyWasManaged: engineStore.systemProxyNeedsRestore,
            preferredBackend: preferredBackend(engineStore),
            transitionSnapshot: engineStore.transitionSnapshot,
            hasProfile: engineStore.selectedProfileID != nil,
            profileName: engineStore.selectedProfile?.name,
            modeName: engineStore.runtimeMode?.displayName,
            sceneName: sceneController?.activeScene?.name,
            proxyName: activeProxyName(engineStore),
            healthIssueCount: issueCount,
            lastVerifiedAt: engineStore.lastHealthReport?.completedAt,
            generation: engineStore.lastHealthReport?.sequence ?? 0,
            tunCapability: componentCapability,
            pauseDeadline: engineStore.tunPauseUntil,
            isBusy: engineStore.isBusy,
            canStart: engineStore.canStart,
            canEnableSystemProxy: engineStore.canEnableSystemProxy,
            canRestoreSystemProxy: engineStore.canRestoreSystemProxy,
            canEnableTun: engineStore.canEnableTun,
            controllerIsAuthoritative: engineStore.controllerState == .connected,
            sceneMutationInProgress: sceneController?.isBusy == true,
            proxyMutationInProgress: engineStore.isProxyOperationInProgress,
            isPreparingToTerminate: engineStore.isPreparingForTerminationForPresentation
        )
        return MenuBarPresentationResolver.resolve(input, now: now)
    }

    private static func preferredBackend(_ engineStore: EngineStore) -> MenuBarBackend? {
        if engineStore.isEngineTransitioning,
            engineStore.transitionSnapshot.target == .userProcess
        {
            return engineStore.restoreSystemProxyAfterTun ? .systemProxy : .engineOnly
        }
        if engineStore.isTunActive || engineStore.activeBackendKind == .privilegedDaemon {
            return .tun
        }
        if engineStore.isSystemProxyApplied || engineStore.systemProxyNeedsRestore {
            return .systemProxy
        }
        return engineStore.isRunning ? .engineOnly : nil
    }

    private static func activeProxyName(_ engineStore: EngineStore) -> String? {
        for group in engineStore.proxyCatalog.groups where group.isSelectable {
            if let value = group.now.flatMap({ $0.isEmpty ? nil : $0 })
                ?? group.fixed.flatMap({ $0.isEmpty ? nil : $0 })
            {
                return value
            }
        }
        return nil
    }

    private static func tunCapability(
        manager: PrivilegedComponentManager?,
        transitionState: EngineTransitionState
    ) -> MenuBarTunCapability {
        if case let .failed(failure) = transitionState,
            case .failed = failure.rollback
        {
            return .recoveryRequired
        }
        guard let manager else { return .notInstalled }
        switch manager.state {
        case .notInstalled:
            return .notInstalled
        case .needsApproval:
            return .needsApproval
        case .registering, .connecting, .uninstalling:
            return .connecting
        case .ready:
            return .ready
        case .incompatible, .damaged, .failed:
            return .repairRequired
        }
    }
}

private extension EngineState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
