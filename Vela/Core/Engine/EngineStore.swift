import CryptoKit
import Foundation
import Observation
import VelaIPC

nonisolated enum EngineLifecycleEvent: Equatable, Sendable {
    case engineRunningChanged(Bool)
    case networkAvailabilityChanged(Bool)
    case willSleep
    case didWake
}

nonisolated enum EngineCoreActivationError: Error, Equatable, Sendable {
    case appUpdateInProgress
    case engineUnavailable
    case preflightFailed(String)
    case configurationRejected
    case restartFailed
    case systemProxyQuiesceFailed
    case systemProxyRestoreFailed
    case controllerAPIUnavailable
    case controllerAPIContractFailed(String)
    case activationSnapshotFailed(String)
    case runtimeStateRestoreFailed(String)
}

extension EngineCoreActivationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .appUpdateInProgress:
            "An application update is in progress."
        case .engineUnavailable:
            "The engine is preparing to terminate."
        case let .preflightFailed(message):
            DiagnosticTextSanitizer.redact(message)
        case .configurationRejected:
            "The selected Core rejected the active configuration."
        case .restartFailed:
            "The selected Core could not start and pass runtime verification."
        case .systemProxyQuiesceFailed:
            "Vela could not safely disable System Proxy before changing Core."
        case .systemProxyRestoreFailed:
            "The selected Core started, but Vela could not safely restore System Proxy."
        case .controllerAPIUnavailable:
            "The selected Core has no stable Controller binding for compatibility verification."
        case let .controllerAPIContractFailed(message):
            "The selected Core returned an incompatible Controller response. \(message)"
        case let .activationSnapshotFailed(message):
            "Vela could not create a durable Core activation snapshot. \(message)"
        case let .runtimeStateRestoreFailed(message):
            "The selected Core did not restore the previous runtime state. \(message)"
        }
    }
}

nonisolated private enum ValidationShutdownResult {
    case notApplicable
    case completed
    case timedOut
}

nonisolated private enum ProfileMutationRuntimeSnapshot: Sendable {
    case stopped
    case userProcess(systemProxyWasApplied: Bool)
    case tun
}

nonisolated struct EngineUpdatePreparationProof: Equatable, Sendable {
    let preparedAt: Date
    let userProcessStopped: Bool
    let privilegedRuntimeStopped: Bool
    let systemProxyRestored: Bool
    let controllerServicesClosed: Bool
    let environmentObserversStopped: Bool

    var isSafeForInstaller: Bool {
        userProcessStopped
            && privilegedRuntimeStopped
            && systemProxyRestored
            && controllerServicesClosed
            && environmentObserversStopped
    }
}

nonisolated struct EngineUpdateInstallationPreparationResult: Equatable, Sendable {
    let proof: EngineUpdatePreparationProof
    let snapshot: UpdateRuntimeSnapshot
}

nonisolated enum EngineUpdatePreparationState: String, Equatable, Sendable {
    case idle
    case preparing
    case prepared
    case terminationAuthorized
}

nonisolated enum EngineUpdatePreparationError: Error, Equatable, Sendable {
    case snapshotFailed
    case runtimeCleanupFailed
    case shutdownProofFailed
}

extension EngineUpdatePreparationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .snapshotFailed:
            "Vela could not create a safe, non-secret update recovery snapshot."
        case .runtimeCleanupFailed:
            "Vela could not stop all runtime and network services safely."
        case .shutdownProofFailed:
            "Vela could not prove that the runtime is safe for installation."
        }
    }
}

nonisolated struct EngineUpdateRecoveryProof: Equatable, Sendable {
    let recoveredAt: Date
    let profileRestored: Bool
    let backendRestored: Bool
    let tunStateProved: Bool
    let modeRestored: Bool
    let restoredProxySelectionCount: Int
    let expectedProxySelectionCount: Int
    let systemProxyRestored: Bool

    var isComplete: Bool {
        profileRestored
            && backendRestored
            && tunStateProved
            && modeRestored
            && restoredProxySelectionCount == expectedProxySelectionCount
            && systemProxyRestored
    }
}

nonisolated enum EngineUpdateRecoveryError: Error, Equatable, Sendable {
    case alreadyAttempted
    case invalidSnapshot
    case profileUnavailable
    case profileRevisionMismatch
    case helperUnavailable
    case backendRestoreFailed
    case controllerUnavailable
    case modeRestoreFailed
    case proxySelectionRestoreFailed
    case systemProxyRestoreFailed
    case recoveryProofFailed
    case failClosedCleanupFailed
}

extension EngineUpdateRecoveryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .alreadyAttempted:
            "Automatic update recovery has already been attempted."
        case .invalidSnapshot:
            "The saved update recovery snapshot is invalid."
        case .profileUnavailable:
            "The saved profile is unavailable."
        case .profileRevisionMismatch:
            "The saved profile revision no longer matches."
        case .helperUnavailable:
            "The privileged component is unavailable or incompatible."
        case .backendRestoreFailed:
            "The previous Mihomo backend could not be restored safely."
        case .controllerUnavailable:
            "The Mihomo Controller did not become ready during recovery."
        case .modeRestoreFailed:
            "The previous Mihomo mode could not be restored."
        case .proxySelectionRestoreFailed:
            "A previous proxy selection could not be restored."
        case .systemProxyRestoreFailed:
            "The previous System Proxy state could not be restored safely."
        case .recoveryProofFailed:
            "Vela could not prove that update recovery completed safely."
        case .failClosedCleanupFailed:
            "Vela could not prove a safe stopped state after recovery failed."
        }
    }
}

@MainActor
@Observable
final class EngineStore {
    private struct SceneRuntimeSnapshot {
        let activeSceneID: UUID?
        let profileID: UUID?
        let profileRevisionID: UUID?
        let wasRunning: Bool
        let backend: EngineBackendKind
        let systemProxyApplied: Bool
        let mihomoMode: MihomoMode?
        let proxySelections: [String: String]
    }

    private struct ActiveSceneRuntimeTransaction {
        let token: SceneRuntimeTransitionToken
        let lease: RuntimeMutationLease
        let snapshot: SceneRuntimeSnapshot
        let targetSceneID: UUID
    }

    private struct RequestedProxySelection {
        let profileID: UUID
        let group: String
        let requestedNodeID: ProxyCatalogID?
        let proxyName: String
    }

    private(set) var state: EngineState = .stopped {
        didSet {
            synchronizeTrafficTakeoverSession()
            let wasRunning = Self.isRunningState(oldValue)
            let isRunning = Self.isRunningState(state)
            guard wasRunning != isRunning else { return }
            emitLifecycleEvent(.engineRunningChanged(isRunning))
        }
    }
    private(set) var profiles: [Profile] = []
    private(set) var selectedProfileID: UUID?
    private(set) var validationResult: ConfigurationValidationResult?
    private(set) var resolvedExecutable: ResolvedMihomoExecutable?
    private(set) var lastError: UserFacingError?
    private(set) var controllerState: ControllerConnectionState = .disconnected
    private(set) var controllerVersion: String?
    private(set) var runtimeMode: MihomoMode?
    private(set) var trafficSample: TrafficSample?
    private(set) var logEntries: [LogEntry] = []
    private(set) var privilegedStartupLogEntries: [LogEntry] = []
    private(set) var lastControllerError: String?
    private(set) var isChangingMode = false
    private(set) var proxyCatalog: ProxyCatalog = .empty
    private(set) var proxyCatalogError: String?
    private(set) var isLoadingProxies = false
    private(set) var proxyOperation: ProxyOperationState?
    private(set) var proxyDelayStates: [ProxyDelayCacheKey: ProxyDelayState] = [:]
    private(set) var recentProxies: [RecentProxyRecord] = []
    private(set) var recentProxyError: String?
    private(set) var systemProxyStatus: SystemProxyStatus {
        didSet { synchronizeTrafficTakeoverSession() }
    }
    private(set) var systemProxyOperation: SystemProxyOperationState?
    private(set) var lastHealthReport: EngineHealthReport?
    private(set) var networkPathSnapshot: NetworkPathSnapshot = .unknown
    private(set) var corePreflightResult: MihomoCorePreflightResult?
    private(set) var coreLifecycleIntegrityVerified = false
    private(set) var corePreflightError: String?
    private(set) var isCheckingCoreIntegrity = false
    private(set) var activeBackendKind: EngineBackendKind = .userProcess {
        didSet { synchronizeTrafficTakeoverSession() }
    }
    private(set) var activeRuntime: EngineRuntime? {
        didSet { synchronizeTrafficTakeoverSession() }
    }
    private(set) var trafficTakeoverStartedAt: Date?
    private(set) var transitionState: EngineTransitionState = .idle
    private(set) var transitionSnapshot = EngineTransitionSnapshot(
        transitionID: nil,
        source: nil,
        target: nil,
        state: .idle
    )
    private(set) var privilegedHealth: PrivilegedRuntimeHealth?
    private(set) var tunSettings: TunSettings
    private(set) var restoreSystemProxyAfterTun: Bool
    private(set) var tunPauseUntil: Date?
    private(set) var trafficTakeoverRequest: Bool? = nil
    private(set) var lastLeaseRenewalAt: Date?
    private(set) var lastLeaseErrorCode: VelaHelperErrorCode?
    private(set) var effectiveTunRouteExclusions: [String] = []
    private(set) var updatePreparationState: EngineUpdatePreparationState = .idle
    private(set) var updatePreparationProof: EngineUpdatePreparationProof?
    private(set) var updateRuntimeSnapshot: UpdateRuntimeSnapshot?
    private(set) var isUpdateRecoveryInProgress = false
    private(set) var updateRecoveryAttempted = false

    let privilegedComponentManager: PrivilegedComponentManager?

    @ObservationIgnored private let profileStore: any ProfileManaging
    @ObservationIgnored private let staticConfigurationCatalog:
        (any StaticConfigurationCatalogProviding)?
    @ObservationIgnored private let runtimeConfigBuilder: RuntimeConfigBuilder
    @ObservationIgnored private var runtimeParameters: RuntimeConfigParameters
    @ObservationIgnored private let executableResolver: any MihomoExecutableResolving
    @ObservationIgnored private let activeCoreResolver: ActiveCoreResolver?
    @ObservationIgnored private let configurationValidator: any ConfigurationValidating
    @ObservationIgnored private let subscriptionConverter: any SubscriptionConverting
    @ObservationIgnored private let processManager: any MihomoProcessManaging
    @ObservationIgnored private let controllerManager: (any MihomoControllerManaging)?
    @ObservationIgnored private let recentProxyStore: (any RecentProxyStoring)?
    @ObservationIgnored private let systemProxyManager: (any SystemProxyManaging)?
    @ObservationIgnored private let healthMonitor: (any EngineHealthMonitoring)?
    @ObservationIgnored private let runtimeConfigurationInspector: (any RuntimeConfigurationInspecting)?
    @ObservationIgnored private let runtimeValidationCache: any RuntimeValidationCaching
    @ObservationIgnored private let networkPathObserver: (any NetworkPathObserving)?
    @ObservationIgnored private let sleepWakeObserver: (any SleepWakeObserving)?
    @ObservationIgnored private let runtimeMutationGate: RuntimeMutationGate
    @ObservationIgnored private let configurationLayerStore: ConfigurationLayerStore?
    @ObservationIgnored private let systemProxyTarget: SystemProxyTarget
    @ObservationIgnored private let mihomoDataDirectoryURL: URL
    @ObservationIgnored private let controllerRouter: RuntimeControllerRouter?
    @ObservationIgnored private let privilegedBackend: (any EngineBackend)?
    @ObservationIgnored private let privilegedHelperClient: (any PrivilegedHelperClientProtocol)?
    @ObservationIgnored private let transitionCoordinator: EngineTransitionCoordinator?
    @ObservationIgnored private let privilegedLeaseCoordinator: PrivilegedLeaseCoordinator?
    @ObservationIgnored private let tunPreferenceStore: any TunPreferenceStoring
    @ObservationIgnored private let localNetworkContextProvider: any LocalNetworkContextProviding
    @ObservationIgnored private let wakePathWaitTimeout: Duration
    @ObservationIgnored private let wakePathPollInterval: Duration
    @ObservationIgnored private let validationShutdownWaitTimeout: Duration
    @ObservationIgnored private let validationShutdownPollInterval: Duration
    @ObservationIgnored private let networkChangeRecoveryDebounce: Duration
    @ObservationIgnored private let networkChangeSleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let localNetworkRecoverySleep:
        @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let wakeSleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var tunCorePolicyGate:
        (@MainActor @Sendable (CoreID) async throws -> Void)?
    @ObservationIgnored private var processEventTask: Task<Void, Never>?
    @ObservationIgnored private var controllerEventTask: Task<Void, Never>?
    @ObservationIgnored private var healthReportTask: Task<Void, Never>?
    @ObservationIgnored private var networkPathTask: Task<Void, Never>?
    @ObservationIgnored private var sleepWakeTask: Task<Void, Never>?
    @ObservationIgnored private var transitionEventTask: Task<Void, Never>?
    @ObservationIgnored private var leaseEventTask: Task<Void, Never>?
    @ObservationIgnored private var leaseRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var leaseRecoveryTaskID: UUID?
    @ObservationIgnored private var tunPauseTask: Task<Void, Never>?
    @ObservationIgnored private var localNetworkRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var localNetworkRecoveryTaskID: UUID?
    @ObservationIgnored private var networkChangeRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var networkChangeRecoveryTaskID: UUID?
    @ObservationIgnored private var isNetworkChangeRecoveryInProgress = false
    @ObservationIgnored private var wakeRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var wakeRecoveryTaskID: UUID?
    @ObservationIgnored private var activeValidationTask: Task<ConfigurationValidationResult, Never>?
    @ObservationIgnored private var activeValidationTaskID: UUID?
    @ObservationIgnored private var lifecycleContinuations: [
        UUID: AsyncStream<EngineLifecycleEvent>.Continuation
    ] = [:]
    @ObservationIgnored private var engineOperationGeneration: UInt64 = 0
    @ObservationIgnored private var proxyOperationGeneration: UInt64 = 0
    @ObservationIgnored private var requestedProxySelection: RequestedProxySelection?
    @ObservationIgnored private var proxySelectionRequestTask: Task<Void, Never>?
    @ObservationIgnored private var recentLoadGeneration: UInt64 = 0
    @ObservationIgnored private var configuredProxyCatalog: ProxyCatalog = .empty
    @ObservationIgnored private var systemProxyOperationGeneration: UInt64 = 0
    @ObservationIgnored private var requestedSystemProxyState: Bool?
    @ObservationIgnored private var systemProxyRequestTask: Task<Void, Never>?
    @ObservationIgnored private var wantsEngineRunning = false
    @ObservationIgnored private var managedProcessID: Int32?
    @ObservationIgnored private var pendingSystemProxyReapply = false
    @ObservationIgnored private var validatedConfigurationFingerprint: RuntimeConfigurationFingerprint?
    @ObservationIgnored private var healthSessionID: UUID?
    @ObservationIgnored private var latestHealthSequence: UInt64 = 0
    @ObservationIgnored private var isApplicationActive = true
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private var systemProxyExpected = false
    @ObservationIgnored private var controllerRecoveryAttempted = false
    @ObservationIgnored private var controllerRecoveryCount = 0
    @ObservationIgnored private var isBootstrapping = false
    @ObservationIgnored private var hasBootstrapped = false
    @ObservationIgnored private var preparedPrivilegedCandidate: EnginePreparedStart?
    @ObservationIgnored private var preparedUserTransitionLaunch: ValidatedLaunch?
    @ObservationIgnored private var lastPrivilegedStartMaterial: PrivilegedEngineStartMaterial?
    @ObservationIgnored private var transitionSourceWasRunning = false
    @ObservationIgnored private var transitionSystemProxyWasApplied = false
    @ObservationIgnored private var leaseRecoveryAttempted = false
    @ObservationIgnored private var privilegedOperationOutcomeUnknown = false
    @ObservationIgnored private var privilegedStartupLogTask: Task<Void, Never>?
    @ObservationIgnored private var isValidationShutdownInProgress = false
    @ObservationIgnored private var isPrivilegedWakeRecoveryInProgress = false
    @ObservationIgnored private var updatePreparationLease: RuntimeMutationLease?
    @ObservationIgnored private var updateSafeModeLease: RuntimeMutationLease?
    @ObservationIgnored private var activeConfigurationSceneID: UUID?
    @ObservationIgnored private var pendingConfigurationBackend: EngineBackendKind?
    @ObservationIgnored private var activeSceneRuntimeTransaction: ActiveSceneRuntimeTransaction?
    private var isPreparingForTermination = false

    init(
        profileStore: any ProfileManaging,
        staticConfigurationCatalog: (any StaticConfigurationCatalogProviding)? = nil,
        runtimeConfigBuilder: RuntimeConfigBuilder = RuntimeConfigBuilder(),
        runtimeParameters: RuntimeConfigParameters,
        executableResolver: any MihomoExecutableResolving,
        configurationValidator: any ConfigurationValidating,
        subscriptionConverter: any SubscriptionConverting = SubscriptionConversionService(),
        processManager: any MihomoProcessManaging,
        controllerManager: (any MihomoControllerManaging)? = nil,
        recentProxyStore: (any RecentProxyStoring)? = nil,
        systemProxyManager: (any SystemProxyManaging)? = nil,
        healthMonitor: (any EngineHealthMonitoring)? = nil,
        runtimeConfigurationInspector: (any RuntimeConfigurationInspecting)? = nil,
        runtimeValidationCache: any RuntimeValidationCaching = DisabledRuntimeValidationCache(),
        networkPathObserver: (any NetworkPathObserving)? = nil,
        sleepWakeObserver: (any SleepWakeObserving)? = nil,
        runtimeMutationGate: RuntimeMutationGate = RuntimeMutationGate(),
        configurationLayerStore: ConfigurationLayerStore? = nil,
        mihomoDataDirectoryURL: URL,
        controllerRouter: RuntimeControllerRouter? = nil,
        privilegedBackend: (any EngineBackend)? = nil,
        privilegedHelperClient: (any PrivilegedHelperClientProtocol)? = nil,
        transitionCoordinator: EngineTransitionCoordinator? = nil,
        privilegedLeaseCoordinator: PrivilegedLeaseCoordinator? = nil,
        privilegedComponentManager: PrivilegedComponentManager? = nil,
        tunPreferenceStore: any TunPreferenceStoring = TransientTunPreferenceStore(),
        localNetworkContextProvider: any LocalNetworkContextProviding = LocalNetworkContextProvider(),
        wakePathWaitTimeout: Duration = .seconds(8),
        wakePathPollInterval: Duration = .milliseconds(250),
        validationShutdownWaitTimeout: Duration = .seconds(4),
        validationShutdownPollInterval: Duration = .milliseconds(10),
        networkChangeRecoveryDebounce: Duration = .milliseconds(1_500),
        networkChangeSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        localNetworkRecoverySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        wakeSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.profileStore = profileStore
        self.staticConfigurationCatalog = staticConfigurationCatalog
        self.runtimeConfigBuilder = runtimeConfigBuilder
        self.runtimeParameters = runtimeParameters
        self.executableResolver = executableResolver
        activeCoreResolver = executableResolver as? ActiveCoreResolver
        self.configurationValidator = configurationValidator
        self.subscriptionConverter = subscriptionConverter
        self.processManager = processManager
        self.controllerManager = controllerManager
        self.recentProxyStore = recentProxyStore
        self.systemProxyManager = systemProxyManager
        self.healthMonitor = healthMonitor
        self.runtimeConfigurationInspector = runtimeConfigurationInspector
        self.runtimeValidationCache = runtimeValidationCache
        self.networkPathObserver = networkPathObserver
        self.sleepWakeObserver = sleepWakeObserver
        self.runtimeMutationGate = runtimeMutationGate
        self.configurationLayerStore = configurationLayerStore
        self.controllerRouter = controllerRouter
        self.privilegedBackend = privilegedBackend
        self.privilegedHelperClient = privilegedHelperClient
        self.transitionCoordinator = transitionCoordinator
        self.privilegedLeaseCoordinator = privilegedLeaseCoordinator
        self.privilegedComponentManager = privilegedComponentManager
        self.tunPreferenceStore = tunPreferenceStore
        self.localNetworkContextProvider = localNetworkContextProvider
        self.wakePathWaitTimeout = max(.milliseconds(1), wakePathWaitTimeout)
        self.wakePathPollInterval = max(.milliseconds(1), wakePathPollInterval)
        self.validationShutdownWaitTimeout = max(
            .milliseconds(1),
            validationShutdownWaitTimeout
        )
        self.validationShutdownPollInterval = max(
            .milliseconds(1),
            validationShutdownPollInterval
        )
        self.networkChangeRecoveryDebounce = max(
            .milliseconds(1),
            networkChangeRecoveryDebounce
        )
        self.networkChangeSleep = networkChangeSleep
        self.localNetworkRecoverySleep = localNetworkRecoverySleep
        self.wakeSleep = wakeSleep
        self.now = now
        let preferences = tunPreferenceStore.load()
        tunSettings = preferences.settings
        restoreSystemProxyAfterTun = preferences.restoreSystemProxyAfterTun
        let systemProxyTarget = SystemProxyTarget(port: runtimeParameters.mixedPort)
        self.systemProxyTarget = systemProxyTarget
        systemProxyStatus = SystemProxyStatus(
            target: systemProxyTarget,
            aggregate: .unavailable,
            services: [],
            recovery: .none
        )
        self.mihomoDataDirectoryURL = mihomoDataDirectoryURL
    }

    deinit {
        processEventTask?.cancel()
        controllerEventTask?.cancel()
        healthReportTask?.cancel()
        networkPathTask?.cancel()
        sleepWakeTask?.cancel()
        transitionEventTask?.cancel()
        leaseEventTask?.cancel()
        leaseRecoveryTask?.cancel()
        tunPauseTask?.cancel()
        localNetworkRecoveryTask?.cancel()
        networkChangeRecoveryTask?.cancel()
        wakeRecoveryTask?.cancel()
        activeValidationTask?.cancel()
        proxySelectionRequestTask?.cancel()
        systemProxyRequestTask?.cancel()
        privilegedStartupLogTask?.cancel()
        for continuation in lifecycleContinuations.values {
            continuation.finish()
        }
    }

    var selectedProfile: Profile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var isTunActive: Bool {
        activeBackendKind == .privilegedDaemon && activeRuntime != nil && isRunning
    }

    /// The product-level connection state. Mihomo and its Controller are
    /// infrastructure; the user is connected only while Vela owns a traffic
    /// takeover route through System Proxy or TUN.
    var isTrafficTakeoverActive: Bool {
        isSystemProxyApplied || isTunActive
    }

    /// The user-visible connection clock starts only after Vela owns an active
    /// System Proxy or TUN route. Controller and Mihomo readiness intentionally
    /// do not start this clock because they are warm infrastructure.
    private func synchronizeTrafficTakeoverSession() {
        if isTrafficTakeoverActive {
            if trafficTakeoverStartedAt == nil {
                trafficTakeoverStartedAt = now()
            }
        } else if trafficTakeoverStartedAt != nil {
            trafficTakeoverStartedAt = nil
        }
    }

    var isTrafficTakeoverOperationInProgress: Bool {
        trafficTakeoverRequest != nil
            || isSystemProxyOperationInProgress
            || isEngineTransitioning
    }

    var canToggleTrafficTakeover: Bool {
        guard selectedProfileID != nil,
            trafficTakeoverRequest == nil,
            !isPreparingForTermination,
            !isSystemProxyOperationInProgress,
            !isEngineTransitioning
        else {
            return false
        }
        if isTrafficTakeoverActive || systemProxyNeedsRestore {
            return true
        }
        if isRunning {
            return activeBackendKind == .userProcess
        }
        return canStart
    }

    var privilegedRuntimeMayBeActive: Bool {
        isTunActive
            || activeRuntime?.backend == .privilegedDaemon
            || privilegedOperationOutcomeUnknown
            || privilegedHealth?.processRunning == true
    }

    var isEngineTransitioning: Bool {
        switch transitionState {
        case .idle, .failed:
            false
        case .preparingTarget, .disablingSystemProxy, .stoppingSource,
            .startingTarget, .verifyingTarget, .committing, .rollingBack:
            true
        }
    }

    var privilegedComponentIsReady: Bool {
        privilegedComponentManager?.isReady == true
    }

    var canEnableTun: Bool {
        privilegedBackend != nil
            && transitionCoordinator != nil
            && privilegedComponentIsReady
            && selectedProfileID != nil
            && !isBusy
            && !isEngineTransitioning
            && !isTunActive
    }

    func checkCoreIntegrity() async {
        guard !isCheckingCoreIntegrity else { return }
        isCheckingCoreIntegrity = true
        defer { isCheckingCoreIntegrity = false }

        do {
            let executable = try await executableResolver.resolve()
            resolvedExecutable = executable
            corePreflightResult = executable.preflight
            coreLifecycleIntegrityVerified = executable.hasVerifiedIntegritySnapshot
            corePreflightError = executable.hasVerifiedIntegritySnapshot
                ? nil
                : "The resolver did not return a verified Core integrity snapshot."
        } catch is CancellationError {
            return
        } catch {
            corePreflightResult = nil
            coreLifecycleIntegrityVerified = false
            corePreflightError = error.localizedDescription
        }
    }

    var isBusy: Bool {
        if isPreparingForTermination || isSystemProxyOperationInProgress
            || isEngineTransitioning
        {
            return true
        }
        switch state {
        case .validating, .starting, .stopping, .recovering:
            return true
        case .stopped, .running, .failed:
            return false
        }
    }

    /// Read-only lifecycle evidence for surfaces that must gate duplicate Quit
    /// actions without owning a second termination state machine.
    var isPreparingForTerminationForPresentation: Bool {
        isPreparingForTermination
    }

    var canStart: Bool {
        selectedProfileID != nil && !isBusy && !isRunning
    }

    var isRunning: Bool {
        Self.isRunningState(state)
    }

    func currentCoreID() async -> CoreID {
        await activeCoreResolver?.coreID() ?? .factoryV11928
    }

    func lifecycleEvents() -> AsyncStream<EngineLifecycleEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            lifecycleContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.removeLifecycleContinuation(id: id)
                }
            }
        }
    }

    var availableRecentProxies: [RecentProxyRecord] {
        recentProxies.filter { record in
            guard record.profileID == selectedProfileID else {
                return false
            }
            guard let group = proxyCatalog.group(named: record.groupName) else {
                return false
            }
            return group.isSelectable && group.nodes.contains { $0.name == record.proxyName }
        }
    }

    var isProxyOperationInProgress: Bool {
        proxyOperation != nil
    }

    var isSystemProxyOperationInProgress: Bool {
        systemProxyOperation != nil
    }

    var isSystemProxyApplied: Bool {
        guard systemProxyStatus.aggregate == .applied else { return false }
        if case .managed = systemProxyStatus.recovery {
            return true
        }
        return false
    }

    var systemProxyNeedsRestore: Bool {
        switch systemProxyStatus.recovery {
        case .none:
            false
        case .managed, .recoveryRequired:
            true
        }
    }

    var canEnableSystemProxy: Bool {
        systemProxyManager != nil
            && isRunning
            && controllerState == .connected
            && !isSystemProxyOperationInProgress
            && !systemProxyNeedsRestore
            && !systemProxyHasAutomaticConfiguration
            && !systemProxyMatchesTargetWithoutOwnership
    }

    var canRestoreSystemProxy: Bool {
        systemProxyManager != nil
            && systemProxyNeedsRestore
            && !isSystemProxyOperationInProgress
    }

    var systemProxyIsExternallyConfigured: Bool {
        guard !systemProxyNeedsRestore else { return false }
        switch systemProxyStatus.aggregate {
        case .applied, .partiallyApplied, .externallyConfigured:
            return true
        case .unavailable, .disabled:
            return false
        }
    }

    var systemProxyHasAutomaticConfiguration: Bool {
        systemProxyStatus.services.contains { $0.automatic.isEnabled }
    }

    var systemProxyMatchesTargetWithoutOwnership: Bool {
        guard !systemProxyNeedsRestore,
            !systemProxyHasAutomaticConfiguration,
            !systemProxyStatus.services.isEmpty
        else {
            return false
        }
        return systemProxyStatus.services
            .flatMap(\.endpoints)
            .contains { $0.matches(systemProxyTarget) }
    }

    func proxyDelayState(group: String, proxy: String) -> ProxyDelayState? {
        guard let selectedGroup = proxyCatalog.group(named: group),
            let node = selectedGroup.nodes.first(where: { $0.name == proxy })
        else {
            return nil
        }

        return proxyDelayState(group: group, nodeID: node.id)
    }

    func proxyDelayState(
        group: String,
        nodeID: ProxyCatalogID
    ) -> ProxyDelayState? {
        guard let selectedProfileID,
            let selectedGroup = proxyCatalog.group(named: group),
            selectedGroup.nodes.contains(where: { $0.id == nodeID })
        else {
            return nil
        }
        return proxyDelayStates[
            delayCacheKey(
                profileID: selectedProfileID,
                group: selectedGroup,
                proxyID: nodeID
            )
        ]
    }

    func bootstrap() async {
        guard !hasBootstrapped, !isBootstrapping else { return }
        isBootstrapping = true
        defer {
            isBootstrapping = false
            hasBootstrapped = true
        }

        await beginObservingProcessEventsIfNeeded()
        await beginObservingControllerEventsIfNeeded()
        await beginObservingHealthReportsIfNeeded()
        await beginObservingNetworkPathIfNeeded()
        await beginObservingSleepWakeEventsIfNeeded()
        await beginObservingTransitionEventsIfNeeded()
        await beginObservingLeaseEventsIfNeeded()
        await networkPathObserver?.start()
        await sleepWakeObserver?.start()

        do {
            try await profileStore.prepareStorage()
            profiles = try await profileStore.profiles()
            selectedProfileID = try await profileStore.selectedProfileID()
        } catch {
            present(
                title: "Storage unavailable",
                message: "Vela could not prepare its Application Support directory.",
                error: error,
                suggestedAction: "Check the folder permissions, then try again.",
                isRetryable: true
            )
        }

        await refreshConfiguredProxyCatalog()
        await loadRecentProxies()

        await refreshHealth()
        systemProxyExpected = systemProxyNeedsRestore
    }

    /// Refreshes the optional privileged TUN component after the app-owned
    /// Mihomo/Controller startup path has had a chance to complete. A damaged
    /// or unreachable Helper must not delay ordinary Controller availability.
    ///
    /// If a stale privileged runtime occupied the Controller endpoint, retry
    /// the normal infrastructure start after the verified recovery stop.
    func reconcilePrivilegedComponentAfterBootstrap(
        restartInfrastructureIfNeeded: Bool
    ) async {
        guard !Task.isCancelled, let privilegedComponentManager else { return }
        await privilegedComponentManager.refresh()
        guard !Task.isCancelled else { return }
        await recoverStalePrivilegedRuntimeIfNeeded()
        guard !Task.isCancelled else { return }
        if restartInfrastructureIfNeeded, !isRunning {
            await ensureInfrastructureRunning()
        }
    }

    /// Keeps Mihomo and the Controller available as app-owned infrastructure.
    /// Traffic is not intercepted until the user explicitly connects.
    func ensureInfrastructureRunning() async {
        guard selectedProfileID != nil,
            !isPreparingForTermination,
            !isEngineTransitioning
        else {
            return
        }
        if isRunning {
            if controllerState != .connected {
                await refreshHealth()
            }
            return
        }
        guard !isBusy else { return }
        await start()
    }

    func importProfile(url: URL) async {
        guard let lease = await acquireRuntimeMutationLease(.profileMutation) else { return }
        guard let runtimeSnapshot = await suspendRuntimeForProfileMutation() else {
            await runtimeMutationGate.release(lease)
            return
        }
        await performImportProfile(url: url)
        await restoreRuntimeAfterProfileMutation(runtimeSnapshot)
        await runtimeMutationGate.release(lease)
    }

    private func performImportProfile(url: URL) async {
        guard canChangeProfile else {
            presentProfileChangeBlocked()
            return
        }

        lastError = nil
        var temporaryDirectoryForCleanup: URL?
        do {
            let sourceData = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            guard let sourceText = String(data: sourceData, encoding: .utf8) else {
                throw SubscriptionUpdateFailure.invalidEncoding
            }
            let converted = try await subscriptionConverter.convertToMihomoYAML(
                content: sourceText,
                sourceURL: url,
                options: SubscriptionConversionOptions()
            )
            let candidateData = Data(converted.yaml.utf8)
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VelaProfileImport", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            temporaryDirectoryForCleanup = temporaryDirectory
            let sourceFileName = url.lastPathComponent.isEmpty
                ? "configuration.yaml"
                : url.lastPathComponent
            let candidateURL = temporaryDirectory.appendingPathComponent(sourceFileName)
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(
                    at: temporaryDirectory,
                    withIntermediateDirectories: true
                )
                try candidateData.write(to: candidateURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: candidateURL.path
                )
            }.value
            let executable = try await executableResolver.resolve()
            let validation = await configurationValidator.validate(
                configurationURL: candidateURL,
                dataDirectoryURL: mihomoDataDirectoryURL,
                using: executable,
                timeout: .seconds(10)
            )
            guard validation.isValid else {
                throw SubscriptionUpdateFailure.configurationValidationFailed
            }

            let profile = try await profileStore.importProfile(from: candidateURL, name: nil)
            await Self.removeTemporaryProfileImportDirectory(temporaryDirectory)
            temporaryDirectoryForCleanup = nil
            try await profileStore.selectProfile(id: profile.id)
            profiles = try await profileStore.profiles()
            selectedProfileID = profile.id
            validationResult = nil
            validatedConfigurationFingerprint = nil
            lastHealthReport = nil
            resetProxyRuntimeState()
            await refreshConfiguredProxyCatalog()
            await loadRecentProxies()
        } catch {
            if let temporaryDirectoryForCleanup {
                await Self.removeTemporaryProfileImportDirectory(temporaryDirectoryForCleanup)
            }
            present(
                title: "Import failed",
                message: "The selected subscription could not be converted and imported.",
                error: error,
                suggestedAction: "Choose a supported YAML, Base64, URI, Surge, or sing-box file and try again.",
                isRetryable: true
            )
        }
    }

    private nonisolated static func removeTemporaryProfileImportDirectory(_ url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }

    func refreshProfiles() async {
        do {
            profiles = try await profileStore.profiles()
            selectedProfileID = try await profileStore.selectedProfileID()
            await refreshConfiguredProxyCatalog()
        } catch {
            present(
                title: "Profiles unavailable",
                message: "Vela could not refresh the profile database.",
                error: error,
                suggestedAction: "Check Application Support permissions and try again.",
                isRetryable: true
            )
        }
    }

    func deleteProfile(id: UUID) async {
        guard let lease = await acquireRuntimeMutationLease(.profileMutation) else { return }
        let deletesSelectedProfile = id == selectedProfileID
        let runtimeSnapshot: ProfileMutationRuntimeSnapshot?
        if deletesSelectedProfile {
            runtimeSnapshot = await suspendRuntimeForProfileMutation()
            guard runtimeSnapshot != nil else {
                await runtimeMutationGate.release(lease)
                return
            }
        } else {
            runtimeSnapshot = nil
        }
        await performDeleteProfile(id: id)
        if let runtimeSnapshot {
            await restoreRuntimeAfterProfileMutation(runtimeSnapshot)
        }
        await runtimeMutationGate.release(lease)
    }

    private func performDeleteProfile(id: UUID) async {
        let deletesSelectedProfile = id == selectedProfileID
        guard !deletesSelectedProfile || canChangeProfile else {
            presentProfileChangeBlocked()
            return
        }
        do {
            try await profileStore.deleteProfile(id: id)
            profiles = try await profileStore.profiles()
            selectedProfileID = try await profileStore.selectedProfileID()
            if deletesSelectedProfile {
                validationResult = nil
                validatedConfigurationFingerprint = nil
                lastHealthReport = nil
                resetProxyRuntimeState()
                await refreshConfiguredProxyCatalog()
                await loadRecentProxies()
            }
        } catch {
            present(
                title: "Delete failed",
                message: "Vela could not delete the selected profile.",
                error: error,
                suggestedAction: "Refresh the profile list and try again.",
                isRetryable: true
            )
        }
    }

    func selectProfile(id: UUID) async {
        guard id != selectedProfileID else { return }
        guard let lease = await acquireRuntimeMutationLease(.profileMutation) else { return }
        guard let runtimeSnapshot = await suspendRuntimeForProfileMutation() else {
            await runtimeMutationGate.release(lease)
            return
        }
        await performSelectProfile(id: id)
        await restoreRuntimeAfterProfileMutation(runtimeSnapshot)
        await runtimeMutationGate.release(lease)
    }

    /// Profile files can only be replaced while Mihomo is stopped. The app
    /// owns that lifecycle detail, so callers only wait for a bounded shutdown
    /// and never need to expose a manual "Stop Mihomo" step to the user.
    private func suspendRuntimeForProfileMutation() async -> ProfileMutationRuntimeSnapshot? {
        let deadline = now().addingTimeInterval(8)
        while (isBusy || isEngineTransitioning), now() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return nil
            }
        }
        guard !isBusy, !isEngineTransitioning else {
            presentBusyAction()
            return nil
        }

        let snapshot: ProfileMutationRuntimeSnapshot
        if isTunActive {
            snapshot = .tun
        } else if isRunning {
            snapshot = .userProcess(systemProxyWasApplied: isSystemProxyApplied)
        } else {
            return .stopped
        }

        cancelPrivilegedNetworkChangeRecovery()
        tunPauseTask?.cancel()
        tunPauseTask = nil
        tunPauseUntil = nil
        await performPublicStop()
        guard !isRunning, !isBusy else { return nil }
        return snapshot
    }

    private func restoreRuntimeAfterProfileMutation(
        _ snapshot: ProfileMutationRuntimeSnapshot
    ) async {
        guard selectedProfileID != nil,
            !isPreparingForTermination
        else {
            return
        }

        await performStart()
        guard isRunning else { return }

        switch snapshot {
        case .stopped, .userProcess(systemProxyWasApplied: false):
            return
        case .userProcess(systemProxyWasApplied: true):
            guard await waitForControllerConnection() else {
                presentTrafficTakeoverUnavailable()
                return
            }
            await performSetSystemProxyEnabled(true)
        case .tun:
            await transitionToTun()
        }
    }

    private func performSelectProfile(id: UUID) async {
        guard canChangeProfile else {
            presentProfileChangeBlocked()
            return
        }

        lastError = nil
        do {
            try await profileStore.selectProfile(id: id)
            selectedProfileID = id
            validationResult = nil
            validatedConfigurationFingerprint = nil
            lastHealthReport = nil
            resetProxyRuntimeState()
            await refreshConfiguredProxyCatalog()
            await loadRecentProxies()
        } catch {
            present(
                title: "Profile selection failed",
                message: "Vela could not select that profile.",
                error: error,
                suggestedAction: "Refresh the profile list and try again.",
                isRetryable: true
            )
        }
    }

    func validateSelectedProfile() async {
        guard let lease = await acquireRuntimeMutationLease(.runtimeValidation) else { return }
        await performValidateSelectedProfile()
        await runtimeMutationGate.release(lease)
    }

    private func performValidateSelectedProfile() async {
        guard !isBusy, !isRunning else { return }
        guard selectedProfileID != nil else {
            presentNoSelectedProfile()
            return
        }

        lastError = nil
        let generation = beginEngineOperation(wantsRunning: false)
        state = .validating

        do {
            _ = try await prepareValidatedLaunch(
                operationGeneration: generation,
                allowsCachedValidation: false
            )
            guard isCurrentEngineOperation(generation) else { return }
            state = .stopped
        } catch {
            guard isCurrentEngineOperation(generation) else { return }
            fail(mapToEngineFailure(error))
        }
    }

    func start() async {
        guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else { return }
        await performStart()
        await runtimeMutationGate.release(lease)
    }

    /// Connects or disconnects the user-visible traffic route without exposing
    /// Mihomo or Controller lifecycle controls. A new connection defaults to
    /// System Proxy; an active TUN route is disconnected back to the warm user
    /// process without restoring another takeover backend.
    func setTrafficTakeoverEnabled(_ enabled: Bool) async {
        guard trafficTakeoverRequest == nil else { return }
        guard selectedProfileID != nil else {
            presentNoSelectedProfile()
            return
        }

        trafficTakeoverRequest = enabled
        defer { trafficTakeoverRequest = nil }

        if enabled {
            guard !isTrafficTakeoverActive else { return }
            await ensureInfrastructureRunning()
            guard isRunning, activeBackendKind == .userProcess else { return }

            if controllerState != .connected {
                await refreshHealth()
            }
            guard await waitForControllerConnection() else {
                presentTrafficTakeoverUnavailable()
                return
            }
            await setSystemProxyEnabled(true)
            return
        }

        if isSystemProxyApplied || systemProxyNeedsRestore {
            await setSystemProxyEnabled(false)
            guard !isSystemProxyApplied, !systemProxyNeedsRestore else { return }
        }
        if isTunActive {
            cancelPrivilegedNetworkChangeRecovery()
            guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else { return }
            tunPauseTask?.cancel()
            tunPauseTask = nil
            tunPauseUntil = nil
            await transitionToUser(restoreSystemProxy: false)
            await runtimeMutationGate.release(lease)
            return
        }
    }

    private func performStart() async {
        guard !isPreparingForTermination else { return }

        switch state {
        case .running, .starting, .validating:
            return
        case .stopping, .recovering:
            presentBusyAction()
            return
        case .stopped, .failed:
            break
        }

        guard selectedProfileID != nil else {
            presentNoSelectedProfile()
            return
        }

        lastError = nil
        let generation = beginEngineOperation(wantsRunning: true)
        state = .validating

        do {
            await beginObservingProcessEventsIfNeeded()
            await beginObservingControllerEventsIfNeeded()
            await beginObservingHealthReportsIfNeeded()
            await beginObservingNetworkPathIfNeeded()
            await beginObservingSleepWakeEventsIfNeeded()
            await beginObservingTransitionEventsIfNeeded()
            await beginObservingLeaseEventsIfNeeded()
            await networkPathObserver?.start()
            await sleepWakeObserver?.start()
            try ensureCurrentEngineOperation(generation, wantsRunning: true)

            let launch = try await prepareValidatedLaunch(
                operationGeneration: generation
            )
            try ensureCurrentEngineOperation(generation, wantsRunning: true)
            let controllerEndpoint = try userControllerEndpoint()
            let runtimeConfigurationSHA256 = await configurationSHA256(
                for: launch.configurationURL
            )
            state = .starting
            let snapshot = try await processManager.start(
                preparedLaunch: MihomoPreparedLaunch(
                    executable: launch.executable,
                    configurationURL: launch.configurationURL,
                    dataDirectoryURL: mihomoDataDirectoryURL,
                    validationResult: launch.validationResult
                )
            )

            guard isCurrentEngineOperation(generation, wantsRunning: true) else {
                if snapshot.isRunning {
                    _ = try? await processManager.stop(timeout: .seconds(3))
                }
                return
            }
            guard snapshot.isRunning else {
                throw EngineStoreOperationError.processDidNotStart
            }

            managedProcessID = snapshot.pid
            activeBackendKind = .userProcess
            let runtime = EngineRuntime(
                instanceID: UUID(),
                backend: .userProcess,
                controller: EngineControllerAccess(
                    endpoint: controllerEndpoint,
                    secret: SecretValue(runtimeParameters.secret)
                ),
                processID: snapshot.pid,
                startedAt: snapshot.startedAt ?? now(),
                configurationSHA256: runtimeConfigurationSHA256
            )
            activeRuntime = runtime
            try await bindController(to: runtime)
            updateRunningHealth(controllerReachable: false)
            await startControllerIfAvailable()
            await startHealthMonitoringIfNeeded()
        } catch {
            guard isCurrentEngineOperation(generation, wantsRunning: true) else { return }
            fail(mapToEngineFailure(error))
        }
    }

    func stop() async {
        guard !rejectMutationDuringUpdateIfNeeded() else { return }
        guard !isPreparingForTermination else { return }
        cancelPrivilegedNetworkChangeRecovery()
        switch await cancelUnstartedValidationIfSafe() {
        case .completed, .timedOut:
            return
        case .notApplicable:
            break
        }
        guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else { return }
        await performPublicStop()
        await runtimeMutationGate.release(lease)
    }

    private func performPublicStop() async {
        if activeBackendKind == .privilegedDaemon {
            let cleanup = await restoreSystemProxyBeforeStopping()
            guard cleanup.isSafe else { return }
            await stopPrivilegedEngine(reason: .userRequested, updateState: true)
            return
        }
        _ = await performStop()
    }

    @discardableResult
    private func performStop() async -> EngineStopResult {
        switch state {
        case .stopped:
            invalidateHealthSession()
            let stopGeneration = beginEngineOperation(wantsRunning: false)
            state = .stopping
            await healthMonitor?.stop()
            guard isCurrentEngineOperation(stopGeneration, wantsRunning: false) else {
                return .failed
            }
            let cleanup = await restoreSystemProxyBeforeStopping()
            guard isCurrentEngineOperation(stopGeneration, wantsRunning: false) else {
                return .failed
            }
            state = .stopped
            return EngineStopResult(
                stoppedSafely: cleanup.isSafe,
                allowsSystemProxyReapply: cleanup.allowsReapply
            )
        case .stopping:
            return .failed
        case .validating, .starting, .running, .recovering, .failed:
            break
        }

        let previousState = state
        pendingSystemProxyReapply = false
        invalidateHealthSession()
        let stopGeneration = beginEngineOperation(wantsRunning: false)
        state = .stopping
        await healthMonitor?.stop()
        guard isCurrentEngineOperation(stopGeneration, wantsRunning: false) else {
            return .failed
        }
        let cleanup = await restoreSystemProxyBeforeStopping()
        guard isCurrentEngineOperation(stopGeneration, wantsRunning: false) else {
            return .failed
        }
        guard cleanup.isSafe else {
            if case .running = previousState {
                let processStillRunning = await processManager.isRunning()
                guard isCurrentEngineOperation(stopGeneration, wantsRunning: false) else {
                    return .failed
                }
                guard processStillRunning else {
                    managedProcessID = nil
                    fail(.unexpectedTermination(exitCode: -1))
                    return .failed
                }
            }
            switch previousState {
            case .running:
                state = previousState
                _ = beginEngineOperation(wantsRunning: true)
                await startHealthMonitoringIfNeeded()
            case .failed:
                state = previousState
            case .stopped, .validating, .starting, .stopping, .recovering:
                state = .stopped
            }
            return .failed
        }

        await controllerManager?.stop()
        guard isCurrentEngineOperation(stopGeneration, wantsRunning: false) else {
            return .failed
        }
        resetControllerRuntimeState()
        do {
            _ = try await processManager.stop(timeout: .seconds(3))
            if isCurrentEngineOperation(stopGeneration, wantsRunning: false) {
                managedProcessID = nil
                await unbindActiveController()
                activeRuntime = nil
                state = .stopped
            } else if state == .stopping, !wantsEngineRunning {
                state = .stopped
            } else if state != .stopped {
                return .failed
            }
            return EngineStopResult(
                stoppedSafely: true,
                allowsSystemProxyReapply: cleanup.allowsReapply
            )
        } catch {
            if !isCurrentEngineOperation(stopGeneration, wantsRunning: false) {
                return (state == .stopped || (state == .stopping && !wantsEngineRunning))
                    ? EngineStopResult(
                        stoppedSafely: true,
                        allowsSystemProxyReapply: cleanup.allowsReapply
                    )
                    : .failed
            }
            let processStillRunning = await processManager.isRunning()
            guard isCurrentEngineOperation(stopGeneration, wantsRunning: false) else {
                return (state == .stopped || (state == .stopping && !wantsEngineRunning))
                    ? EngineStopResult(
                        stoppedSafely: true,
                        allowsSystemProxyReapply: cleanup.allowsReapply
                    )
                    : .failed
            }
            if processStillRunning {
                _ = beginEngineOperation(wantsRunning: true)
                state = .running(.sprintTwo(
                    processRunning: true,
                    controllerReachable: false,
                    configurationValid: validationResult?.isValid == true,
                    systemProxyApplied: systemProxyStatus.aggregate == .applied
                ))
                if let activeRuntime {
                    try? await bindController(to: activeRuntime)
                }
                await startControllerIfAvailable()
                await startHealthMonitoringIfNeeded()
                lastError = UserFacingError(
                    title: "Mihomo is still running",
                    message: EngineFailure.stopFailed(error.localizedDescription).summary,
                    technicalDetails: error.localizedDescription,
                    suggestedAction: "Retry Stop. Vela will not start a second process.",
                    isRetryable: true
                )
            } else {
                managedProcessID = nil
                await unbindActiveController()
                activeRuntime = nil
                fail(.stopFailed(error.localizedDescription))
            }
            return .failed
        }
    }

    func restart() async {
        guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else { return }
        if activeBackendKind == .privilegedDaemon {
            await performPrivilegedRestart()
            await runtimeMutationGate.release(lease)
            return
        }
        await performRestart()
        await runtimeMutationGate.release(lease)
    }

    /// Runs only while `CoreActivationCoordinator` owns the global mutation
    /// lease. It intentionally calls the private lifecycle paths directly to
    /// avoid a re-entrant gate acquisition after the point where the current
    /// runtime has been stopped.
    func applySelectedCoreForActivation(
        restoreRunningRuntime: Bool? = nil,
        restoreBackend: CoreBackendSelection? = nil
    ) async throws {
        guard !isPreparingForTermination else {
            throw EngineCoreActivationError.engineUnavailable
        }
        if await runtimeMutationGate.isUpdateInProgress() {
            throw EngineCoreActivationError.appUpdateInProgress
        }

        let shouldRun = restoreRunningRuntime ?? isRunning
        if shouldRun {
            let shouldUsePrivilegedBackend = restoreBackend == .tun
                || (restoreBackend == nil && activeBackendKind == .privilegedDaemon)
            if shouldUsePrivilegedBackend {
                guard await performPrivilegedRestart(), isRunning else {
                    throw EngineCoreActivationError.restartFailed
                }
            } else {
                if restoreBackend == .systemProxy, isSystemProxyApplied {
                    await performSetSystemProxyEnabled(false)
                    guard !isSystemProxyApplied, !systemProxyNeedsRestore else {
                        throw EngineCoreActivationError.systemProxyQuiesceFailed
                    }
                }
                await performRestart()
                guard isRunning else {
                    throw EngineCoreActivationError.restartFailed
                }
            }
        } else {
            await checkCoreIntegrity()
            guard corePreflightError == nil else {
                throw EngineCoreActivationError.preflightFailed(
                    corePreflightError ?? "Core preflight failed."
                )
            }
            if selectedProfileID != nil {
                await performValidateSelectedProfile()
                guard validationResult?.isValid == true else {
                    throw EngineCoreActivationError.configurationRejected
                }
            }
        }
    }

    /// Tests the candidate Core against the durable, currently selected
    /// profile before activation is allowed to create a transaction, stop the
    /// running Core, or alter System Proxy/TUN state.
    ///
    /// The candidate is intentionally not published as `resolvedExecutable`:
    /// until the lifecycle transaction commits, that property must continue to
    /// describe the active runtime. The normal launch path resolves and
    /// verifies the candidate again after selection, closing the time-of-check
    /// to time-of-use window.
    func validateCoreCandidateForActivation(
        _ candidate: ResolvedMihomoExecutable
    ) async throws {
        guard !isPreparingForTermination else {
            throw EngineCoreActivationError.engineUnavailable
        }
        if await runtimeMutationGate.isUpdateInProgress() {
            throw EngineCoreActivationError.appUpdateInProgress
        }
        guard let selectedProfileID else {
            throw EngineCoreActivationError.configurationRejected
        }

        do {
            let durableProfileID = try await profileStore.selectedProfileID()
            let profiles = try await profileStore.profiles()
            guard durableProfileID == selectedProfileID,
                let profile = profiles.first(where: { $0.id == selectedProfileID })
            else {
                throw EngineCoreActivationError.activationSnapshotFailed(
                    "The selected profile is not durable."
                )
            }
            let expectedRevisionID = profile.currentRevisionID
            let configurationURL = try await profileStore.buildRuntimeConfiguration(
                for: selectedProfileID,
                parameters: runtimeParameters,
                using: runtimeConfigBuilder
            )
            let result = await configurationValidator.validate(
                configurationURL: configurationURL,
                dataDirectoryURL: mihomoDataDirectoryURL,
                using: candidate,
                timeout: .seconds(10)
            )
            guard result.isValid else {
                throw EngineCoreActivationError.configurationRejected
            }

            let confirmedProfileID = try await profileStore.selectedProfileID()
            let confirmedProfiles = try await profileStore.profiles()
            guard confirmedProfileID == selectedProfileID,
                let confirmedProfile = confirmedProfiles.first(where: {
                    $0.id == selectedProfileID
                }),
                confirmedProfile.currentRevisionID == expectedRevisionID
            else {
                throw EngineCoreActivationError.activationSnapshotFailed(
                    "The selected profile changed during candidate validation."
                )
            }
        } catch let error as EngineCoreActivationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EngineCoreActivationError.preflightFailed(
                DiagnosticTextSanitizer.redact(error.localizedDescription)
            )
        }
    }

    /// Completes the backend-specific part of a Core activation only after the
    /// caller has proved Controller/API and backend health. In particular,
    /// System Proxy stays disabled while the candidate is unverified so macOS
    /// never points at a dead or incompatible listener.
    func completeSelectedCoreActivationBackendRestore(
        _ backend: CoreBackendSelection?
    ) async throws {
        guard backend == .systemProxy else { return }
        guard isRunning, controllerState == .connected else {
            throw EngineCoreActivationError.systemProxyRestoreFailed
        }
        if !isSystemProxyApplied {
            await performSetSystemProxyEnabled(true)
        }
        // A successfully managed System Proxy intentionally retains a
        // `.managed` recovery snapshot so Vela can restore the user's prior
        // settings on disable/crash. `systemProxyNeedsRestore` is therefore
        // true in the healthy applied state and must not be used as a success
        // predicate here.
        guard isSystemProxyApplied, !isSystemProxyOperationInProgress else {
            throw EngineCoreActivationError.systemProxyRestoreFailed
        }
    }

    func captureCoreActivationSnapshot(
        previousCoreID: CoreID,
        backend: CoreBackendSelection,
        configurationGenerationID: UUID
    ) async throws -> CoreActivationSnapshot {
        do {
            let durableProfileID = try await profileStore.selectedProfileID()
            let profiles = try await profileStore.profiles()
            guard let profileID = durableProfileID,
                let profile = profiles.first(where: { $0.id == profileID })
            else {
                throw EngineCoreActivationError.activationSnapshotFailed(
                    "The selected profile is not durable."
                )
            }
            let snapshot = CoreActivationSnapshot(
                previousCoreID: previousCoreID,
                backend: backend,
                profileID: profileID,
                profileRevisionID: profile.currentRevisionID,
                sceneID: nil,
                mihomoMode: isRunning ? runtimeMode : nil,
                proxySelections: isRunning ? unambiguousUpdateProxySelections() : [],
                systemProxyDesired: backend == .systemProxy,
                configurationGenerationID: configurationGenerationID
            )
            try snapshot.validate()
            return snapshot
        } catch let error as EngineCoreActivationError {
            throw error
        } catch {
            throw EngineCoreActivationError.activationSnapshotFailed(
                DiagnosticTextSanitizer.redact(error.localizedDescription)
            )
        }
    }

    /// Replays only non-secret runtime preferences captured before the Core
    /// replacement. Every mutation is followed by a Controller readback; a
    /// missing group/node or schema-incompatible response aborts activation.
    func restoreCoreActivationRuntimeState(
        _ snapshot: CoreActivationSnapshot,
        runtimeExpected: Bool
    ) async throws {
        do {
            try snapshot.validate()
            guard selectedProfileID == snapshot.profileID else {
                throw EngineCoreActivationError.runtimeStateRestoreFailed(
                    "The selected profile changed during activation."
                )
            }
            let profiles = try await profileStore.profiles()
            guard let profile = profiles.first(where: { $0.id == snapshot.profileID }),
                snapshot.profileRevisionID == nil
                    || profile.currentRevisionID == snapshot.profileRevisionID
            else {
                throw EngineCoreActivationError.runtimeStateRestoreFailed(
                    "The selected profile revision changed during activation."
                )
            }
            guard runtimeExpected else { return }
            guard isRunning, controllerState == .connected else {
                throw EngineCoreActivationError.controllerAPIUnavailable
            }

            if let desiredMode = snapshot.mihomoMode, runtimeMode != desiredMode {
                await performModeChange(desiredMode)
                guard runtimeMode == desiredMode else {
                    throw EngineCoreActivationError.runtimeStateRestoreFailed(
                        "Mihomo did not confirm mode \(desiredMode.rawValue)."
                    )
                }
            }

            if !snapshot.proxySelections.isEmpty {
                try await controllerManager?.refreshProxies()
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            for selection in snapshot.proxySelections {
                guard let decoded = decodeUpdateProxySelection(selection),
                    await waitForUpdateRecoveryCondition(deadline: deadline, {
                        self.proxyCatalog.group(named: decoded.groupName)?
                            .nodes.contains(where: { $0.id == decoded.nodeID }) == true
                    })
                else {
                    throw EngineCoreActivationError.runtimeStateRestoreFailed(
                        "A saved proxy selection is unavailable."
                    )
                }
                if !updateProxySelectionIsProved(decoded) {
                    await performProxySelection(
                        group: decoded.groupName,
                        requestedNodeID: decoded.nodeID,
                        proxyName: decoded.nodeID.name
                    )
                }
                guard await waitForUpdateRecoveryCondition(deadline: deadline, {
                    self.updateProxySelectionIsProved(decoded)
                }) else {
                    throw EngineCoreActivationError.runtimeStateRestoreFailed(
                        "Mihomo did not confirm a saved proxy selection."
                    )
                }
            }
        } catch let error as EngineCoreActivationError {
            throw error
        } catch {
            throw EngineCoreActivationError.runtimeStateRestoreFailed(
                DiagnosticTextSanitizer.redact(error.localizedDescription)
            )
        }
    }

    var coreActivationPrivilegedHealthReady: Bool {
        guard activeBackendKind == .privilegedDaemon,
            let privilegedHealth
        else { return activeBackendKind != .privilegedDaemon }
        return privilegedHealthIsReady(privilegedHealth)
    }

    /// Performs a typed, generation-bound read of every Controller endpoint
    /// whose schema is critical to Core activation. The binding checks prevent
    /// a concurrent backend replacement from satisfying the candidate probe.
    func verifyActiveCoreControllerAPIContract() async throws {
        guard let controllerRouter,
            let runtime = activeRuntime,
            let before = await controllerRouter.binding(),
            before.instanceID == runtime.instanceID,
            before.backend == runtime.backend
        else { throw EngineCoreActivationError.controllerAPIUnavailable }

        do {
            try await CoreControllerAPIContractProbe(api: controllerRouter).run()
        } catch {
            throw EngineCoreActivationError.controllerAPIContractFailed(
                DiagnosticTextSanitizer.redact(error.localizedDescription)
            )
        }

        guard let after = await controllerRouter.binding(),
            after == before,
            activeRuntime?.instanceID == runtime.instanceID
        else { throw EngineCoreActivationError.controllerAPIUnavailable }
    }

    private func performRestart() async {
        guard !isPreparingForTermination else { return }

        switch state {
        case .stopping, .recovering, .validating, .starting:
            presentBusyAction()
            return
        case .stopped, .running, .failed:
            break
        }

        let restartGeneration = engineOperationGeneration
        let shouldReapplySystemProxy = isSystemProxyApplied
        let previouslyManagedServices = systemProxyRecoveryServiceNames
        var reapplyWasSuppressed = false
        let processRunning = await processManager.isRunning()
        guard !isPreparingForTermination,
            isCurrentEngineOperation(restartGeneration)
        else {
            return
        }

        if processRunning || shouldReapplySystemProxy {
            let stopResult = await performStop()
            guard stopResult.stoppedSafely else { return }
            guard !isPreparingForTermination else { return }
            guard case .stopped = state else { return }
            pendingSystemProxyReapply = shouldReapplySystemProxy
                && stopResult.allowsSystemProxyReapply
            reapplyWasSuppressed = shouldReapplySystemProxy
                && !stopResult.allowsSystemProxyReapply
        } else {
            pendingSystemProxyReapply = false
        }
        guard !isPreparingForTermination else { return }
        await performStart()
        if !isRunning {
            pendingSystemProxyReapply = false
        } else if pendingSystemProxyReapply, controllerState == .connected {
            pendingSystemProxyReapply = false
            await performSetSystemProxyEnabled(true)
        } else if reapplyWasSuppressed, isRunning {
            let names = previouslyManagedServices.joined(separator: ", ")
            lastError = UserFacingError(
                title: "External proxy changes were not overwritten",
                message: names.isEmpty
                    ? "Vela restarted Mihomo without re-enabling System Proxy because recovery found external or missing settings."
                    : "Vela restarted Mihomo without re-enabling System Proxy for: \(names).",
                technicalDetails: names.isEmpty ? nil : "Affected network services: \(names)",
                suggestedAction: "Review macOS Network settings, then enable System Proxy manually if desired.",
                isRetryable: false
            )
        }
    }

    func refreshHealth() async {
        if activeBackendKind == .privilegedDaemon {
            await refreshPrivilegedHealth(presentErrors: true)
            return
        }
        if let healthMonitor {
            if isRunning {
                if healthSessionID == nil {
                    await startHealthMonitoringIfNeeded()
                } else {
                    await synchronizeHealthContext()
                    await healthMonitor.trigger(.manual)
                }
            } else {
                await refreshSystemProxyStatus(presentErrors: true)
            }
            return
        }

        let healthGeneration = engineOperationGeneration
        await beginObservingControllerEventsIfNeeded()
        guard healthGeneration == engineOperationGeneration else { return }
        let processRunning = await processManager.isRunning()
        guard healthGeneration == engineOperationGeneration else { return }
        if processRunning {
            wantsEngineRunning = true
            let configurationValid = validationResult?.isValid == true
            state = .running(.sprintTwo(
                processRunning: true,
                controllerReachable: controllerState == .connected,
                configurationValid: configurationValid,
                systemProxyApplied: systemProxyStatus.aggregate == .applied
            ))
            if controllerManager != nil {
                await controllerManager?.refresh()
            }
        } else if case .running = state {
            managedProcessID = nil
            fail(.unexpectedTermination(exitCode: -1))
        }

        guard healthGeneration == engineOperationGeneration else { return }

        await refreshSystemProxyStatus(presentErrors: true)
        if !processRunning, systemProxyNeedsRestore {
            presentUnexpectedTerminationRecoveryWarning(exitCode: -1)
        }
    }

    func setApplicationActive(_ active: Bool) async {
        isApplicationActive = active
        await healthMonitor?.setApplicationActive(active && !isSleeping)
    }

    func updateTunSettings(_ settings: TunSettings) {
        guard !rejectMutationDuringUpdateIfNeeded() else { return }
        do {
            tunSettings = try settings.validated()
            persistTunPreferences()
        } catch {
            lastError = UserFacingError(
                title: "Invalid TUN Settings",
                message: error.localizedDescription,
                suggestedAction: "Review the TUN network fields and try again.",
                isRetryable: true
            )
        }
    }

    func setRestoreSystemProxyAfterTun(_ enabled: Bool) {
        guard !rejectMutationDuringUpdateIfNeeded() else { return }
        restoreSystemProxyAfterTun = enabled
        persistTunPreferences()
    }

    func refreshPrivilegedComponent() async {
        await privilegedComponentManager?.refresh()
        if privilegedComponentIsReady {
            await refreshPrivilegedHealth(presentErrors: false)
        }
    }

    private func recoverStalePrivilegedRuntimeIfNeeded() async {
        guard !Task.isCancelled,
            privilegedComponentIsReady,
            let client = privilegedHelperClient,
            let sessionID = privilegedComponentManager?.lastHandshake?.sessionID
        else { return }
        do {
            let status = try await client.status()
            privilegedHealth = status.health
            guard !Task.isCancelled, status.health.processRunning else { return }
            guard let instanceID = status.instanceID else {
                throw EngineStoreTunError.staleRuntimeIdentityUnavailable
            }
            try await client.stop(StopHelperRequest(
                sessionID: sessionID,
                instanceID: instanceID,
                reason: .recovery
            ))
            let verified = try await client.status()
            privilegedHealth = verified.health
            guard !verified.health.processRunning else {
                throw EngineStoreTunError.staleRuntimeCleanupFailed
            }
            lastError = UserFacingError(
                title: "Recovered Stale TUN Runtime",
                message: "Vela found a TUN runtime left inside the Helper grace window and stopped it safely.",
                suggestedAction: "Enable TUN again when you are ready.",
                isRetryable: false,
                recoveryActions: [.openDiagnostics]
            )
        } catch {
            lastError = UserFacingError(
                title: "Stale TUN Runtime Needs Attention",
                message: "Vela could not prove that the previous privileged runtime was cleaned up.",
                technicalDetails: DiagnosticTextSanitizer.redact(error.localizedDescription),
                suggestedAction: "Do not reinstall or uninstall the component until Diagnostics confirms cleanup.",
                isRetryable: true,
                recoveryActions: [.openDiagnostics]
            )
        }
    }

    func installPrivilegedComponent(userConfirmed: Bool) async {
        guard !rejectMutationDuringUpdateIfNeeded() else { return }
        guard !isPreparingForTermination else { return }
        guard !isEngineTransitioning else {
            presentBusyAction()
            return
        }
        guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else { return }
        await privilegedComponentManager?.install(
            userConfirmed: userConfirmed,
            tunIsActive: privilegedRuntimeMayBeActive
        )
        await runtimeMutationGate.release(lease)
    }

    func reinstallPrivilegedComponent(userConfirmed: Bool) async {
        guard !rejectMutationDuringUpdateIfNeeded() else { return }
        guard !isPreparingForTermination else { return }
        guard !isEngineTransitioning else {
            presentBusyAction()
            return
        }
        guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else { return }
        await privilegedComponentManager?.reinstall(
            userConfirmed: userConfirmed,
            tunIsActive: privilegedRuntimeMayBeActive
        )
        await runtimeMutationGate.release(lease)
    }

    func uninstallPrivilegedComponent(
        userConfirmed: Bool,
        cleanupMode: PrivilegedCleanupMode = .removeRuntimeData
    ) async {
        guard userConfirmed else { return }
        guard !rejectMutationDuringUpdateIfNeeded() else { return }
        guard !isPreparingForTermination else { return }
        guard !isEngineTransitioning else {
            presentBusyAction()
            return
        }
        guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else { return }
        privilegedStartupLogTask?.cancel()
        privilegedStartupLogTask = nil
        await privilegedComponentManager?.uninstall(
            userConfirmed: userConfirmed,
            tunIsActive: privilegedRuntimeMayBeActive,
            cleanupMode: cleanupMode
        )
        if privilegedComponentManager?.registrationStatus == .notRegistered {
            await privilegedLeaseCoordinator?.stop()
            if let runtime = activeRuntime, runtime.backend == .privilegedDaemon {
                await controllerRouter?.unbind(instanceID: runtime.instanceID)
                activeRuntime = nil
                activeBackendKind = .userProcess
                state = .stopped
                resetControllerRuntimeState()
            }
            privilegedHealth = nil
            preparedPrivilegedCandidate = nil
            lastPrivilegedStartMaterial = nil
        }
        await runtimeMutationGate.release(lease)
    }

    func runPrivilegedCleanup(userConfirmed: Bool) async {
        guard userConfirmed else { return }
        guard !rejectMutationDuringUpdateIfNeeded() else { return }
        guard !isPreparingForTermination else { return }
        guard !isEngineTransitioning else {
            presentBusyAction()
            return
        }
        guard let manager = privilegedComponentManager,
            let lease = await acquireRuntimeMutationLease(.engineLifecycle)
        else { return }

        privilegedStartupLogTask?.cancel()
        privilegedStartupLogTask = nil
        let locallyActivePrivilegedRuntime = activeBackendKind == .privilegedDaemon
            ? activeRuntime
            : nil
        if locallyActivePrivilegedRuntime != nil {
            await controllerManager?.stop()
            await privilegedLeaseCoordinator?.stop()
        }
        let previousResultID = manager.lastCleanupResult?.id
        await manager.runCleanup(userConfirmed: userConfirmed)
        let result = manager.lastCleanupResult
        if result?.id != previousResultID, result?.succeeded == true {
            if activeBackendKind == .privilegedDaemon {
                if let runtime = activeRuntime {
                    await controllerRouter?.unbind(instanceID: runtime.instanceID)
                }
                activeRuntime = nil
                activeBackendKind = .userProcess
                state = .stopped
                resetControllerRuntimeState()
            }
            privilegedOperationOutcomeUnknown = false
            preparedPrivilegedCandidate = nil
            lastPrivilegedStartMaterial = nil
            if let privilegedHelperClient,
                let response = try? await privilegedHelperClient.status()
            {
                privilegedHealth = response.health
            }
        } else if let runtime = locallyActivePrivilegedRuntime {
            await controllerManager?.start()
            if let sessionID = manager.lastHandshake?.sessionID {
                await privilegedLeaseCoordinator?.start(
                    sessionID: sessionID,
                    instanceID: runtime.instanceID
                )
            }
        }
        await runtimeMutationGate.release(lease)
    }

    func setTunEnabled(_ enabled: Bool) async {
        guard !rejectMutationDuringUpdateIfNeeded() else { return }
        guard !isPreparingForTermination else { return }
        if !enabled {
            cancelPrivilegedNetworkChangeRecovery()
        }
        guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else { return }
        await performSetTunEnabled(enabled)
        await runtimeMutationGate.release(lease)
    }

    private func performSetTunEnabled(_ enabled: Bool) async {
        if enabled {
            guard !isTunActive else { return }
            await privilegedComponentManager?.refresh()
            guard privilegedComponentIsReady else {
                presentPrivilegedComponentNotReady()
                return
            }
            await transitionToTun()
        } else {
            guard activeBackendKind == .privilegedDaemon else { return }
            tunPauseTask?.cancel()
            tunPauseTask = nil
            tunPauseUntil = nil
            await transitionToUser(restoreSystemProxy: false)
        }
    }

    func setTunCorePolicyGate(
        _ gate: (@MainActor @Sendable (CoreID) async throws -> Void)?
    ) {
        tunCorePolicyGate = gate
    }

    private func preparePrivilegedStart(
        using backend: any EngineBackend,
        _ request: EngineStartRequest
    ) async throws -> EnginePreparedStart {
        try await tunCorePolicyGate?(request.coreID)
        return try await backend.prepareStart(request)
    }

    func pauseTun(for duration: Duration) async {
        guard !rejectMutationDuringUpdateIfNeeded() else { return }
        guard !isPreparingForTermination, duration > .zero, isTunActive else { return }
        cancelPrivilegedNetworkChangeRecovery()
        guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else { return }
        await transitionToUser(restoreSystemProxy: false)
        await runtimeMutationGate.release(lease)
        guard activeBackendKind == .userProcess, isRunning else { return }

        let seconds = duration.timeInterval
        let deadline = now().addingTimeInterval(seconds)
        tunPauseUntil = deadline
        tunPauseTask?.cancel()
        tunPauseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
                guard let self, self.tunPauseUntil == deadline else { return }
                self.tunPauseUntil = nil
                await self.setTunEnabled(true)
            } catch {
                // Cancellation means the user resumed or stopped explicitly.
            }
        }
    }

    func resumeTun() async {
        guard !rejectMutationDuringUpdateIfNeeded() else { return }
        guard tunPauseUntil != nil else { return }
        tunPauseTask?.cancel()
        tunPauseTask = nil
        tunPauseUntil = nil
        await setTunEnabled(true)
    }

    func setSystemProxyEnabled(_ enabled: Bool) async {
        guard !rejectMutationDuringUpdateIfNeeded() else { return }
        guard !isEngineTransitioning else {
            presentBusyAction()
            return
        }
        guard let lease = await acquireRuntimeMutationLease(.controllerMutation) else { return }
        await performSetSystemProxyEnabled(enabled)
        await runtimeMutationGate.release(lease)
    }

    /// Coalesces rapid toggle changes so the runtime converges to the latest
    /// requested state after any in-flight engine or proxy transition finishes.
    func requestSystemProxyEnabled(_ enabled: Bool) {
        requestedSystemProxyState = enabled
        startSystemProxyRequestTaskIfNeeded()
    }

    private func startSystemProxyRequestTaskIfNeeded() {
        guard systemProxyRequestTask == nil else { return }
        systemProxyRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let requestedState = self.requestedSystemProxyState else { break }
                if self.systemProxyOperation != nil || self.isEngineTransitioning {
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        break
                    }
                    continue
                }

                self.requestedSystemProxyState = nil
                guard !self.isPreparingForTermination else { continue }
                await self.setSystemProxyEnabled(requestedState)
            }
            self.systemProxyRequestTask = nil
        }
    }

    private func performSetSystemProxyEnabled(_ enabled: Bool) async {
        guard !isPreparingForTermination else { return }

        guard let systemProxyManager else {
            presentSystemProxyUnavailable()
            return
        }
        guard systemProxyOperation == nil else {
            presentSystemProxyOperationInProgress()
            return
        }
        if enabled {
            guard isRunning, controllerState == .connected else {
                present(
                    title: "Start Mihomo first",
                    message: "Vela enables the system proxy only after Mihomo and its Controller are connected.",
                    error: EngineFailure.systemProxyFailed("Mihomo is not ready."),
                    suggestedAction: "Start Mihomo and wait for Connected, then try again.",
                    isRetryable: true
                )
                return
            }
            guard !systemProxyNeedsRestore else {
                present(
                    title: "Restore system proxy first",
                    message: "Vela still has recovery data from an earlier system proxy operation.",
                    error: EngineFailure.systemProxyFailed("Recovery is required before a new enable operation."),
                    suggestedAction: "Restore the previous settings, then enable System Proxy again.",
                    isRetryable: true
                )
                return
            }
        }

        lastError = nil
        let operation: SystemProxyOperationState = enabled ? .enabling : .restoring
        let generation = beginSystemProxyOperation(operation)
        defer { finishSystemProxyOperation(generation, operation: operation) }

        do {
            let status: SystemProxyStatus
            if enabled {
                status = try await systemProxyManager.enable(systemProxyTarget).status
            } else {
                status = try await systemProxyManager.restore().status
            }
            guard isCurrentSystemProxyOperation(generation, operation: operation) else {
                return
            }
            systemProxyExpected = enabled
            applySystemProxyStatus(status)
            await synchronizeHealthContext()
            await healthMonitor?.trigger(.manual)
        } catch {
            guard isCurrentSystemProxyOperation(generation, operation: operation) else {
                return
            }
            await refreshSystemProxyStatusAfterFailure(
                manager: systemProxyManager,
                generation: generation,
                operation: operation
            )
            presentSystemProxyFailure(
                enabled ? "System proxy could not be enabled" : "System proxy could not be restored",
                error: error,
                suggestedAction: enabled
                    ? "Review the affected network services, then try again."
                    : "Keep Mihomo running and retry Restore before stopping or quitting Vela."
            )
        }
    }

    /// Acquires the global update barrier once, lets the current mutation drain,
    /// and then reuses Vela's existing fail-closed termination cleanup. The
    /// successful lease deliberately remains held until the installer replaces
    /// the process, preventing any late UI/CLI/App Intent mutation from racing
    /// Sparkle termination.
    func prepareForUpdateInstallation() async throws -> EngineUpdatePreparationProof {
        try await prepareForUpdateInstallation(
            configurationGenerationID: nil
        ).proof
    }

    /// Returns both the shutdown proof and the non-secret runtime snapshot that
    /// recovery needs. Snapshotting happens only after the update barrier is
    /// granted, closing the race with a final profile or Controller mutation,
    /// and before any runtime cleanup changes the values being captured.
    func prepareForUpdateInstallation(
        configurationGenerationID: UUID?
    ) async throws -> EngineUpdateInstallationPreparationResult {
        if let proof = updatePreparationProof,
            proof.isSafeForInstaller,
            let snapshot = updateRuntimeSnapshot
        {
            return EngineUpdateInstallationPreparationResult(
                proof: proof,
                snapshot: snapshot
            )
        }
        guard updatePreparationState == .idle else {
            throw RuntimeMutationGateError.updateInProgress
        }
        updatePreparationState = .preparing

        do {
            return try await performUpdateInstallationPreparation(
                configurationGenerationID: configurationGenerationID
            )
        } catch {
            if updatePreparationProof == nil {
                updatePreparationState = .idle
            }
            throw error
        }
    }

    /// Returns true exactly once after update preparation has produced a full
    /// shutdown proof. AppKit/Sparkle integration can consume this authorization
    /// without running a second cleanup barrier.
    func consumePreparedInstallTerminationAuthorization() -> Bool {
        guard updatePreparationState == .prepared,
            updatePreparationProof?.isSafeForInstaller == true
        else {
            return false
        }
        updatePreparationState = .terminationAuthorized
        return true
    }

    /// Releases a completed preparation barrier when Sparkle never received
    /// the installation handler (for example, a durable journal write failed).
    /// The runtime remains safely stopped, but the old App becomes usable
    /// again and may be quit or relaunched without retaining a permanent gate.
    func cancelPreparedUpdateInstallation() async {
        guard updatePreparationState == .prepared,
            let updatePreparationLease
        else {
            return
        }

        await resumeEnvironmentObserversAfterFailedUpdatePreparation()
        try? await runtimeMutationGate.releaseUpdateBarrier(
            updatePreparationLease
        )
        self.updatePreparationLease = nil
        updatePreparationProof = nil
        updateRuntimeSnapshot = nil
        updatePreparationState = .idle
        isPreparingForTermination = false
    }

    /// Holds the global mutation barrier while post-update validation or
    /// recovery requires read-only Safe Mode. Bootstrap cleanup and
    /// diagnostics remain available, but no UI, CLI, intent, subscription, or
    /// Controller mutation can start until a later verified launch.
    func enterUpdateRecoverySafeMode() async {
        guard updateSafeModeLease == nil else { return }
        guard updatePreparationState == .idle,
            updatePreparationLease == nil
        else {
            return
        }

        do {
            let lease = try await runtimeMutationGate.beginUpdateBarrier(
                .updateRecovery
            )
            try await runtimeMutationGate.validateUpdateLease(lease)
            updateSafeModeLease = lease
            isUpdateRecoveryInProgress = true
        } catch {
            presentUpdateRecoveryFailure(
                code: "safeModeBarrierFailed",
                cleanupSafe: !privilegedRuntimeMayBeActive
            )
        }
    }

    private func performUpdateInstallationPreparation(
        configurationGenerationID: UUID?
    ) async throws -> EngineUpdateInstallationPreparationResult {
        let errorBeforePreparation = lastError
        let updateLease: RuntimeMutationLease
        do {
            updateLease = try await runtimeMutationGate.beginUpdateBarrier(
                .updatePreparation
            )
            try await runtimeMutationGate.validateUpdateLease(updateLease)
        } catch {
            updatePreparationState = .idle
            throw error
        }

        updatePreparationLease = updateLease
        let snapshot: UpdateRuntimeSnapshot
        do {
            snapshot = try await captureUpdateRuntimeSnapshot(
                configurationGenerationID: configurationGenerationID
            )
        } catch {
            await releaseFailedUpdatePreparation(updateLease)
            if lastError == errorBeforePreparation {
                presentUpdatePreparationFailure(code: "snapshotFailed")
            }
            throw EngineUpdatePreparationError.snapshotFailed
        }

        cancelPrivilegedNetworkChangeRecovery()
        isPreparingForTermination = true
        _ = beginEngineOperation(wantsRunning: false)
        pendingSystemProxyReapply = false

        // The update barrier was granted only after the previous global holder
        // completed. This should normally be idle, but joining a lingering
        // transition remains a fail-closed defense against a future caller that
        // releases its mutation lease too early.
        if let transitionCoordinator {
            _ = await transitionCoordinator.cancelCurrentTransitionAndWait()
        }

        let stoppedSafely = await performTerminationBarrier()
        guard stoppedSafely else {
            await releaseFailedUpdatePreparation(updateLease)
            if lastError == errorBeforePreparation {
                presentUpdatePreparationFailure(code: "runtimeCleanupFailed")
            }
            throw EngineUpdatePreparationError.runtimeCleanupFailed
        }

        await stopEnvironmentObservers()

        let userProcessStopped = !(await processManager.isRunning())
        let privilegedRuntimeStopped = !privilegedRuntimeMayBeActive
            && activeBackendKind == .userProcess
            && activeRuntime?.backend != .privilegedDaemon
        let systemProxyRestored = systemProxyOperation == nil
            && !isSystemProxyApplied
            && !systemProxyNeedsRestore
            && visibleSystemProxyTargetServiceNames(in: systemProxyStatus).isEmpty
        let controllerServicesClosed = controllerState == .disconnected
            && activeRuntime == nil
            && state == .stopped
        let proof = EngineUpdatePreparationProof(
            preparedAt: now(),
            userProcessStopped: userProcessStopped,
            privilegedRuntimeStopped: privilegedRuntimeStopped,
            systemProxyRestored: systemProxyRestored,
            controllerServicesClosed: controllerServicesClosed,
            environmentObserversStopped: true
        )

        guard proof.isSafeForInstaller else {
            await resumeEnvironmentObserversAfterFailedUpdatePreparation()
            await releaseFailedUpdatePreparation(updateLease)
            if lastError == errorBeforePreparation {
                presentUpdatePreparationFailure(code: "shutdownProofFailed")
            }
            throw EngineUpdatePreparationError.shutdownProofFailed
        }

        updatePreparationProof = proof
        updateRuntimeSnapshot = snapshot
        updatePreparationState = .prepared
        return EngineUpdateInstallationPreparationResult(
            proof: proof,
            snapshot: snapshot
        )
    }

    private func captureUpdateRuntimeSnapshot(
        configurationGenerationID: UUID?
    ) async throws -> UpdateRuntimeSnapshot {
        let durableSelectedProfileID = try await profileStore.selectedProfileID()
        let durableProfiles = try await profileStore.profiles()
        let selectedRevisionID = durableSelectedProfileID.flatMap { selectedID in
            durableProfiles.first(where: { $0.id == selectedID })?.currentRevisionID
        }

        let userProcessRunning = await processManager.isRunning()
        let backend: UpdateJournalBackend?
        if privilegedRuntimeMayBeActive
            || activeBackendKind == .privilegedDaemon
            || activeRuntime?.backend == .privilegedDaemon
        {
            backend = .tun
        } else if userProcessRunning
            || (isRunning && activeBackendKind == .userProcess)
            || activeRuntime?.backend == .userProcess
        {
            backend = .userProcess
        } else {
            backend = nil
        }

        let handshake = privilegedComponentManager?.lastHandshake
        let helperProtocol: Int? = if let handshake, handshake.hasCompatibleProtocol {
            min(VelaIPCConstants.protocolMaximum, handshake.helperProtocolMaximum)
        } else {
            nil
        }
        let coreMetadata = await activeCoreResolver?.lifecycleMetadata()
            ?? ActiveCoreLifecycleMetadata(
                activeCoreID: .factoryV11928,
                previousKnownGoodCoreID: nil,
                selectionMode: .followRecommended,
                highestCatalogSequence: 0,
                trustRootSetVersion: VelaCoreCatalogTrustRoots.version
            )
        let snapshot = UpdateRuntimeSnapshot(
            profileID: durableSelectedProfileID,
            profileRevisionID: selectedRevisionID,
            sceneID: nil,
            backend: backend,
            systemProxyDesired: systemProxyExpected,
            mihomoMode: runtimeMode,
            automaticScenesEnabled: false,
            helperVersion: handshake?.helperVersion,
            helperProtocol: helperProtocol,
            configurationGenerationID: configurationGenerationID,
            proxySelections: unambiguousUpdateProxySelections(),
            activeCoreID: coreMetadata.activeCoreID,
            previousKnownGoodCoreID: coreMetadata.previousKnownGoodCoreID,
            coreSelectionMode: coreMetadata.selectionMode,
            highestCatalogSequence: coreMetadata.highestCatalogSequence,
            coreTrustRootSetVersion: coreMetadata.trustRootSetVersion
        )
        try snapshot.validate()
        return snapshot
    }

    private func unambiguousUpdateProxySelections() -> [UpdateProxySelection] {
        proxyCatalog.groups.compactMap { group in
            guard group.isSelectable else { return nil }
            let currentNodes = group.nodes.filter {
                $0.isCurrent && !$0.isPlaceholder
            }
            guard currentNodes.count == 1, let node = currentNodes.first else {
                return nil
            }

            let proxyID: String
            switch node.origin {
            case .runtime:
                proxyID = "runtime:\(node.name)"
            case let .provider(name):
                // The first provider separator is the decoding boundary. Omit
                // names containing it instead of persisting an ambiguous ID.
                guard !name.contains(":") else { return nil }
                proxyID = "provider:\(name):\(node.name)"
            }
            return UpdateProxySelection(
                groupID: "runtime:\(group.name)",
                proxyID: proxyID
            )
        }
    }

    private func releaseFailedUpdatePreparation(_ lease: RuntimeMutationLease) async {
        try? await runtimeMutationGate.releaseUpdateBarrier(lease)
        if updatePreparationLease == lease {
            updatePreparationLease = nil
        }
        updatePreparationProof = nil
        updateRuntimeSnapshot = nil
        updatePreparationState = .idle
        isPreparingForTermination = false
    }

    private func resumeEnvironmentObserversAfterFailedUpdatePreparation() async {
        await beginObservingProcessEventsIfNeeded()
        await beginObservingControllerEventsIfNeeded()
        await beginObservingHealthReportsIfNeeded()
        await beginObservingNetworkPathIfNeeded()
        await beginObservingSleepWakeEventsIfNeeded()
        await beginObservingTransitionEventsIfNeeded()
        await beginObservingLeaseEventsIfNeeded()
        await networkPathObserver?.start()
        await sleepWakeObserver?.start()
    }

    /// Performs at most one automatic post-update restoration attempt while a
    /// first-class update barrier excludes every other runtime mutation. The
    /// implementation calls the existing private lifecycle paths directly so
    /// none of those operations tries to acquire the gate reentrantly.
    @discardableResult
    func recoverAfterUpdate(
        _ snapshot: UpdateRuntimeSnapshot,
        beforeRuntimeRestore: (@MainActor @Sendable () async throws -> Void)? = nil
    ) async throws -> UpdateRecoveryProof {
        guard !updateRecoveryAttempted else {
            throw EngineUpdateRecoveryError.alreadyAttempted
        }
        guard !isUpdateRecoveryInProgress,
            updatePreparationState == .idle
        else {
            throw RuntimeMutationGateError.updateInProgress
        }

        isUpdateRecoveryInProgress = true
        let recoveryLease: RuntimeMutationLease
        do {
            recoveryLease = try await runtimeMutationGate.beginUpdateBarrier(
                .updateRecovery
            )
            try await runtimeMutationGate.validateUpdateLease(recoveryLease)
        } catch {
            isUpdateRecoveryInProgress = false
            throw error
        }

        updateRecoveryAttempted = true
        let errorBeforeRecovery = lastError
        do {
            do {
                try snapshot.validate()
            } catch {
                throw EngineUpdateRecoveryError.invalidSnapshot
            }
            guard snapshot.backend == nil || snapshot.profileID != nil,
                snapshot.backend != .tun || !snapshot.systemProxyDesired,
                snapshot.backend != nil
                    || (snapshot.mihomoMode == nil
                        && snapshot.proxySelections.isEmpty
                        && !snapshot.systemProxyDesired)
            else {
                throw EngineUpdateRecoveryError.invalidSnapshot
            }

            // Core selection is part of the same first-launch recovery
            // transaction. Run it only after the update barrier is latched so
            // download/activate/remove cannot race the backend restore.
            try await beforeRuntimeRestore?()

            let proof = try await performUpdateRecovery(snapshot)
            guard proof.isComplete else {
                throw EngineUpdateRecoveryError.recoveryProofFailed
            }
            try await runtimeMutationGate.releaseUpdateBarrier(recoveryLease)
            isUpdateRecoveryInProgress = false
            return UpdateRecoveryProof(
                profileRestored: proof.profileRestored,
                backendRestored: proof.backendRestored,
                modeRestored: proof.modeRestored,
                proxySelectionsRestored: proof.restoredProxySelectionCount
                    == proof.expectedProxySelectionCount,
                systemProxyRestored: proof.systemProxyRestored,
                healthVerified: proof.tunStateProved,
                warnings: []
            )
        } catch {
            let recoveryError = error as? EngineUpdateRecoveryError
                ?? EngineUpdateRecoveryError.recoveryProofFailed
            let cleanupSafe = await failClosedAfterUpdateRecoveryFailure()
            try? await runtimeMutationGate.releaseUpdateBarrier(recoveryLease)
            isUpdateRecoveryInProgress = false
            if lastError == errorBeforeRecovery || !cleanupSafe {
                presentUpdateRecoveryFailure(
                    code: cleanupSafe
                        ? String(describing: recoveryError)
                        : "failClosedCleanupFailed",
                    cleanupSafe: cleanupSafe
                )
            }
            guard cleanupSafe else {
                throw EngineUpdateRecoveryError.failClosedCleanupFailed
            }
            throw recoveryError
        }
    }

    private func performUpdateRecovery(
        _ snapshot: UpdateRuntimeSnapshot
    ) async throws -> EngineUpdateRecoveryProof {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        let profileRestored = try await restoreUpdateProfile(snapshot)

        // Preparation always leaves proxy state clean. Re-prove that invariant
        // on first launch before starting either backend; stale recovery data
        // must never coexist with a newly restored runtime.
        try await restoreUpdateSystemProxy(
            desired: false,
            backend: snapshot.backend
        )

        let backendRestored: Bool
        var tunStateProved = true
        switch snapshot.backend {
        case nil:
            backendRestored = try await proveNoUpdateRecoveryRuntime()
        case .userProcess:
            guard try await provePrivilegedRuntimeStoppedForUpdateRecovery() else {
                throw EngineUpdateRecoveryError.backendRestoreFailed
            }
            await performStart()
            guard await waitForUpdateRecoveryCondition(deadline: deadline, {
                self.isRunning
                    && self.activeBackendKind == .userProcess
                    && self.activeRuntime?.backend == .userProcess
                    && self.controllerState == .connected
            }), await processManager.isRunning()
            else {
                throw EngineUpdateRecoveryError.backendRestoreFailed
            }
            backendRestored = true
        case .tun:
            guard let privilegedComponentManager else {
                throw EngineUpdateRecoveryError.helperUnavailable
            }
            await privilegedComponentManager.refresh()
            guard privilegedComponentManager.isReady,
                let handshake = privilegedComponentManager.lastHandshake,
                handshake.hasCompatibleProtocol,
                snapshot.helperProtocol.map({
                    handshake.helperProtocolMinimum <= $0
                        && handshake.helperProtocolMaximum >= $0
                }) ?? true
            else {
                throw EngineUpdateRecoveryError.helperUnavailable
            }
            await transitionToTun()
            tunStateProved = try await proveRestoredTunRuntime()
            guard tunStateProved else {
                throw EngineUpdateRecoveryError.backendRestoreFailed
            }
            backendRestored = true
        }

        let modeRestored: Bool
        var restoredProxySelectionCount = 0
        if snapshot.backend != nil {
            guard await waitForUpdateRecoveryCondition(deadline: deadline, {
                self.controllerState == .connected
            }) else {
                throw EngineUpdateRecoveryError.controllerUnavailable
            }

            if let desiredMode = snapshot.mihomoMode {
                if runtimeMode != desiredMode {
                    await performModeChange(desiredMode)
                }
                modeRestored = await waitForUpdateRecoveryCondition(
                    deadline: deadline,
                    { self.runtimeMode == desiredMode }
                )
                guard modeRestored else {
                    throw EngineUpdateRecoveryError.modeRestoreFailed
                }
            } else {
                modeRestored = true
            }

            for selection in snapshot.proxySelections {
                guard let decoded = decodeUpdateProxySelection(selection),
                    await waitForUpdateRecoveryCondition(deadline: deadline, {
                        self.proxyCatalog.group(named: decoded.groupName)?
                            .nodes.contains(where: { $0.id == decoded.nodeID }) == true
                    })
                else {
                    throw EngineUpdateRecoveryError.proxySelectionRestoreFailed
                }

                if !updateProxySelectionIsProved(decoded) {
                    await performProxySelection(
                        group: decoded.groupName,
                        requestedNodeID: decoded.nodeID,
                        proxyName: decoded.nodeID.name
                    )
                }
                guard await waitForUpdateRecoveryCondition(deadline: deadline, {
                    self.updateProxySelectionIsProved(decoded)
                }) else {
                    throw EngineUpdateRecoveryError.proxySelectionRestoreFailed
                }
                restoredProxySelectionCount += 1
            }
        } else {
            modeRestored = true
            // A stopped snapshot may retain informational Controller values,
            // but it cannot safely replay them without starting a backend.
            restoredProxySelectionCount = snapshot.proxySelections.count
        }

        try await restoreUpdateSystemProxy(
            desired: snapshot.systemProxyDesired,
            backend: snapshot.backend
        )
        let systemProxyRestored = updateSystemProxyMatches(
            desired: snapshot.systemProxyDesired
        )

        if snapshot.backend == .tun {
            tunStateProved = try await proveRestoredTunRuntime()
        } else {
            tunStateProved = try await provePrivilegedRuntimeStoppedForUpdateRecovery()
        }

        return EngineUpdateRecoveryProof(
            recoveredAt: now(),
            profileRestored: profileRestored,
            backendRestored: backendRestored,
            tunStateProved: tunStateProved,
            modeRestored: modeRestored,
            restoredProxySelectionCount: restoredProxySelectionCount,
            expectedProxySelectionCount: snapshot.proxySelections.count,
            systemProxyRestored: systemProxyRestored
        )
    }

    private func restoreUpdateProfile(
        _ snapshot: UpdateRuntimeSnapshot
    ) async throws -> Bool {
        let durableProfiles: [Profile]
        let durableSelectedProfileID: UUID?
        do {
            durableProfiles = try await profileStore.profiles()
            durableSelectedProfileID = try await profileStore.selectedProfileID()
        } catch {
            throw EngineUpdateRecoveryError.profileUnavailable
        }

        guard let profileID = snapshot.profileID else {
            guard durableSelectedProfileID == nil else {
                throw EngineUpdateRecoveryError.profileUnavailable
            }
            profiles = durableProfiles
            selectedProfileID = nil
            return true
        }
        guard let profile = durableProfiles.first(where: { $0.id == profileID }) else {
            throw EngineUpdateRecoveryError.profileUnavailable
        }
        guard snapshot.profileRevisionID == nil
            || profile.currentRevisionID == snapshot.profileRevisionID
        else {
            throw EngineUpdateRecoveryError.profileRevisionMismatch
        }

        profiles = durableProfiles
        selectedProfileID = durableSelectedProfileID
        if durableSelectedProfileID != profileID {
            await performSelectProfile(id: profileID)
        }
        guard selectedProfileID == profileID,
            (try? await profileStore.selectedProfileID()) == profileID
        else {
            throw EngineUpdateRecoveryError.profileUnavailable
        }
        return true
    }

    private func proveNoUpdateRecoveryRuntime() async throws -> Bool {
        guard !(await processManager.isRunning()),
            !isRunning,
            activeRuntime == nil,
            activeBackendKind == .userProcess
        else {
            return false
        }
        return try await provePrivilegedRuntimeStoppedForUpdateRecovery()
    }

    private func provePrivilegedRuntimeStoppedForUpdateRecovery() async throws -> Bool {
        guard !privilegedRuntimeMayBeActive,
            activeRuntime?.backend != .privilegedDaemon
        else {
            return false
        }
        guard let privilegedComponentManager else { return true }
        await privilegedComponentManager.refresh()
        switch privilegedComponentManager.registrationStatus {
        case .notRegistered, .notFound:
            return true
        case .enabled:
            guard privilegedComponentManager.lastHandshake?.hasCompatibleProtocol == true,
                let privilegedHelperClient
            else {
                throw EngineUpdateRecoveryError.helperUnavailable
            }
            let status = try await privilegedHelperClient.status()
            privilegedHealth = status.health
            return Self.isCleanlyStopped(status)
        case .requiresApproval, .unknown:
            throw EngineUpdateRecoveryError.helperUnavailable
        }
    }

    private func proveRestoredTunRuntime() async throws -> Bool {
        guard activeBackendKind == .privilegedDaemon,
            let runtime = activeRuntime,
            runtime.backend == .privilegedDaemon,
            let privilegedHelperClient
        else {
            return false
        }
        let status = try await privilegedHelperClient.status()
        privilegedHealth = status.health
        return status.state == .running
            && status.instanceID == runtime.instanceID
            && status.processID != nil
            && privilegedHealthIsReady(status.health)
            && updateSystemProxyMatches(desired: false)
    }

    private func restoreUpdateSystemProxy(
        desired: Bool,
        backend: UpdateJournalBackend?
    ) async throws {
        guard !desired || backend == .userProcess else {
            throw EngineUpdateRecoveryError.invalidSnapshot
        }
        if !updateSystemProxyMatches(desired: desired) {
            await performSetSystemProxyEnabled(desired)
        }
        guard updateSystemProxyMatches(desired: desired) else {
            throw EngineUpdateRecoveryError.systemProxyRestoreFailed
        }
    }

    private func updateSystemProxyMatches(desired: Bool) -> Bool {
        if desired {
            return systemProxyExpected
                && systemProxyOperation == nil
                && isSystemProxyApplied
                && systemProxyNeedsRestore
                && !visibleSystemProxyTargetServiceNames(in: systemProxyStatus).isEmpty
        }
        return !systemProxyExpected
            && systemProxyOperation == nil
            && !isSystemProxyApplied
            && !systemProxyNeedsRestore
            && visibleSystemProxyTargetServiceNames(in: systemProxyStatus).isEmpty
    }

    private struct DecodedUpdateProxySelection {
        let groupName: String
        let nodeID: ProxyCatalogID
    }

    private func decodeUpdateProxySelection(
        _ selection: UpdateProxySelection
    ) -> DecodedUpdateProxySelection? {
        let runtimePrefix = "runtime:"
        guard selection.groupID.hasPrefix(runtimePrefix) else { return nil }
        let groupName = String(selection.groupID.dropFirst(runtimePrefix.count))
        guard !groupName.isEmpty else { return nil }

        let nodeID: ProxyCatalogID
        if selection.proxyID.hasPrefix(runtimePrefix) {
            let nodeName = String(selection.proxyID.dropFirst(runtimePrefix.count))
            guard !nodeName.isEmpty else { return nil }
            nodeID = ProxyCatalogID(origin: .runtime, name: nodeName)
        } else {
            let providerPrefix = "provider:"
            guard selection.proxyID.hasPrefix(providerPrefix) else { return nil }
            let remainder = selection.proxyID.dropFirst(providerPrefix.count)
            guard let separator = remainder.firstIndex(of: ":") else { return nil }
            let providerName = String(remainder[..<separator])
            let nodeName = String(remainder[remainder.index(after: separator)...])
            guard !providerName.isEmpty, !nodeName.isEmpty else { return nil }
            nodeID = ProxyCatalogID(
                origin: .provider(name: providerName),
                name: nodeName
            )
        }
        return DecodedUpdateProxySelection(
            groupName: groupName,
            nodeID: nodeID
        )
    }

    private func updateProxySelectionIsProved(
        _ selection: DecodedUpdateProxySelection
    ) -> Bool {
        guard let group = proxyCatalog.group(named: selection.groupName),
            group.isSelectable
        else {
            return false
        }
        let currentNodes = group.nodes.filter {
            $0.isCurrent && !$0.isPlaceholder
        }
        return currentNodes.count == 1
            && currentNodes.first?.id == selection.nodeID
    }

    private func waitForUpdateRecoveryCondition(
        deadline: ContinuousClock.Instant,
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        while !condition() {
            guard !Task.isCancelled, clock.now < deadline else { return false }
            let remaining = clock.now.duration(to: deadline)
            do {
                try await Task.sleep(for: min(.milliseconds(50), remaining))
            } catch {
                return false
            }
        }
        return true
    }

    private func failClosedAfterUpdateRecoveryFailure() async -> Bool {
        cancelPrivilegedNetworkChangeRecovery()
        isPreparingForTermination = true
        _ = beginEngineOperation(wantsRunning: false)
        pendingSystemProxyReapply = false
        if let transitionCoordinator {
            _ = await transitionCoordinator.cancelCurrentTransitionAndWait()
        }
        let stoppedSafely = await performTerminationBarrier()
        let userProcessStopped = !(await processManager.isRunning())
        let proof = stoppedSafely
            && userProcessStopped
            && !privilegedRuntimeMayBeActive
            && activeRuntime == nil
            && activeBackendKind == .userProcess
            && updateSystemProxyMatches(desired: false)
        isPreparingForTermination = false
        return proof
    }

    private func presentUpdateRecoveryFailure(
        code: String,
        cleanupSafe: Bool
    ) {
        lastError = UserFacingError(
            title: "Update Recovery Failed",
            message: cleanupSafe
                ? "Vela kept the engine and network proxy off because the saved runtime state could not be restored safely."
                : "Vela could not prove that TUN and System Proxy reached a safe state after update recovery failed.",
            technicalDetails: "Update recovery code: \(code)",
            suggestedAction: "Open Update Recovery or Diagnostics and review the saved state before retrying manually.",
            isRetryable: false,
            recoveryActions: [.openDiagnostics]
        )
    }

    func prepareForTermination() async -> Bool {
        // Update preparation already proved every shutdown invariant and still
        // owns the global barrier. Sparkle's subsequent termination callback is
        // therefore idempotent and must not try to acquire the gate again.
        if updatePreparationProof?.isSafeForInstaller == true {
            return true
        }
        if let updateSafeModeLease {
            return await prepareForTerminationFromUpdateSafeMode(
                lease: updateSafeModeLease
            )
        }
        guard !isPreparingForTermination else { return false }

        cancelPrivilegedNetworkChangeRecovery()
        let errorBeforeTermination = lastError
        isPreparingForTermination = true
        let validationShutdown = await cancelUnstartedValidationIfSafe()
        if case .notApplicable = validationShutdown {
            _ = beginEngineOperation(wantsRunning: false)
        }
        pendingSystemProxyReapply = false

        switch validationShutdown {
        case .completed:
            let safeToTerminate = await performNoRuntimeValidationTerminationBarrier()
            if safeToTerminate {
                await stopEnvironmentObservers()
            } else {
                isPreparingForTermination = false
                if lastError == errorBeforeTermination {
                    presentTerminationBarrierFailure()
                }
            }
            return safeToTerminate
        case .timedOut:
            isPreparingForTermination = false
            if lastError == errorBeforeTermination {
                presentValidationShutdownFailure()
            }
            return false
        case .notApplicable:
            break
        }

        if let transitionCoordinator {
            _ = await transitionCoordinator.cancelCurrentTransitionAndWait()
        }

        guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else {
            isPreparingForTermination = false
            return false
        }

        let safeToTerminate = await performTerminationBarrier(
            probesDormantPrivilegedRuntime: false
        )
        await runtimeMutationGate.release(lease)

        if safeToTerminate {
            await stopEnvironmentObservers()
        } else {
            isPreparingForTermination = false
            if lastError == errorBeforeTermination {
                presentTerminationBarrierFailure()
            }
        }
        return safeToTerminate
    }

    private func prepareForTerminationFromUpdateSafeMode(
        lease: RuntimeMutationLease
    ) async -> Bool {
        guard !isPreparingForTermination else { return false }
        isPreparingForTermination = true
        cancelPrivilegedNetworkChangeRecovery()
        _ = beginEngineOperation(wantsRunning: false)
        pendingSystemProxyReapply = false
        if let transitionCoordinator {
            _ = await transitionCoordinator.cancelCurrentTransitionAndWait()
        }

        let safeToTerminate = await performTerminationBarrier()
        guard safeToTerminate else {
            isPreparingForTermination = false
            presentTerminationBarrierFailure()
            return false
        }

        await stopEnvironmentObservers()
        try? await runtimeMutationGate.releaseUpdateBarrier(lease)
        updateSafeModeLease = nil
        isUpdateRecoveryInProgress = false
        return true
    }

    /// Relinquishes App-side ownership after the user explicitly chooses to
    /// quit despite an unverified privileged cleanup. The Helper remains the
    /// authority for the still-possible root runtime and will enforce its
    /// bounded lease-expiry cleanup. Deliberately preserve all published
    /// runtime/backend/health state: disconnecting the App is not proof that
    /// Mihomo, its TUN interface, or its routes have stopped.
    func yieldPrivilegedRuntimeToLeaseCleanupForTermination() async {
        guard privilegedRuntimeMayBeActive else { return }

        isPreparingForTermination = true

        // Cancel work that could reconnect or issue another privileged RPC
        // while AppKit is completing termination. Do not await diagnostic or
        // recovery tasks that may already be inside a bounded XPC call; the
        // connection invalidation below resolves those calls and the process
        // is about to leave its run loop.
        privilegedStartupLogTask?.cancel()
        privilegedStartupLogTask = nil
        leaseRecoveryTask?.cancel()
        leaseRecoveryTask = nil
        leaseRecoveryTaskID = nil
        tunPauseTask?.cancel()
        tunPauseTask = nil
        localNetworkRecoveryTask?.cancel()
        localNetworkRecoveryTask = nil
        localNetworkRecoveryTaskID = nil
        cancelPrivilegedNetworkChangeRecovery()
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        wakeRecoveryTaskID = nil
        isPrivilegedWakeRecoveryInProgress = false

        // Stop and join the renewal loop before dropping the authenticated App
        // session. This closes the window in which a coordinator-owned task
        // could recreate transport or extend the lease after invalidation.
        await privilegedLeaseCoordinator?.stop()
        await privilegedHelperClient?.invalidate()
        await stopEnvironmentObservers()
    }

    /// Validation has not created a managed Mihomo runtime yet, so Stop/Quit
    /// can converge the visible lifecycle immediately. The validator task keeps
    /// its original mutation-gate lease until its real subprocess/callback has
    /// completed; cancelling it requests the bounded TERM/KILL path in the live
    /// validator without allowing profile/configuration waiters to overtake it.
    private func cancelUnstartedValidationIfSafe() async -> ValidationShutdownResult {
        guard !isValidationShutdownInProgress,
            state == .validating,
            activeBackendKind == .userProcess,
            activeRuntime == nil,
            managedProcessID == nil,
            !isEngineTransitioning,
            !isSystemProxyApplied,
            !systemProxyNeedsRestore,
            systemProxyOperation == nil
        else {
            return .notApplicable
        }

        isValidationShutdownInProgress = true
        defer { isValidationShutdownInProgress = false }
        _ = beginEngineOperation(wantsRunning: false)
        pendingSystemProxyReapply = false
        invalidateHealthSession()
        let validationTaskID = activeValidationTaskID
        activeValidationTask?.cancel()

        // Cancelling is only a request. The production validator owns a real
        // `mihomo -t` subprocess and completes only after its bounded
        // TERM/KILL/reap path. Never publish stopped or allow Quit while that
        // task is still alive.
        guard await waitForValidationShutdown(taskID: validationTaskID) else {
            presentValidationShutdownFailure()
            return .timedOut
        }

        // The published state/PID are not sufficient proof. A process may
        // have survived a prior failure without being adopted into
        // `activeRuntime`, so verify the process manager while the shutdown
        // latch rejects lifecycle waiters. This check intentionally precedes
        // our own lease acquisition so a queued Start can acquire the just-
        // released validation lease, observe the latch, and return instead of
        // waiting behind Stop and relaunching after it.
        let processWasRunning = await processManager.isRunning()

        // The validation wrapper still owns the FIFO runtime lease briefly
        // after its child task finishes. Acquire behind it (and behind any
        // already-queued waiter that the latch rejects) before final cleanup.
        let shutdownLease: RuntimeMutationLease
        do {
            shutdownLease = try await runtimeMutationGate.acquire(.engineLifecycle)
        } catch {
            presentValidationShutdownFailure()
            return .timedOut
        }

        if processWasRunning {
            _ = await performStop()
        } else {
            managedProcessID = nil
            state = .stopped
        }
        await runtimeMutationGate.release(shutdownLease)
        return .completed
    }

    private func waitForValidationShutdown(taskID: UUID?) async -> Bool {
        guard let taskID else { return true }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: validationShutdownWaitTimeout)
        while activeValidationTaskID == taskID {
            if Task.isCancelled || clock.now >= deadline {
                return false
            }
            let remaining = clock.now.duration(to: deadline)
            try? await Task.sleep(for: min(validationShutdownPollInterval, remaining))
        }
        return true
    }

    private func presentValidationShutdownFailure() {
        let details = "The configuration validator did not finish its bounded child-process cleanup."
        fail(.stopFailed(details))
        lastError = UserFacingError(
            title: "Validation Cleanup Is Still Running",
            message: "Vela kept the app open because the Mihomo validation process has not been confirmed reaped.",
            technicalDetails: details,
            suggestedAction: "Wait a moment, then retry Stop or Quit. Vela will not claim the engine is stopped until validation cleanup completes.",
            isRetryable: true
        )
    }

    private func performNoRuntimeValidationTerminationBarrier() async -> Bool {
        privilegedStartupLogTask?.cancel()
        privilegedStartupLogTask = nil
        guard !(await processManager.isRunning()) else { return false }

        if privilegedHelperClient != nil, privilegedRuntimeMayBeActive {
            guard await reconcilePrivilegedRuntimeToStoppedNonCancelling() else {
                return false
            }
        }

        await privilegedLeaseCoordinator?.stop()
        privilegedOperationOutcomeUnknown = false
        preparedPrivilegedCandidate = nil
        lastPrivilegedStartMaterial = nil
        privilegedHealth = nil
        activeBackendKind = .userProcess
        await healthMonitor?.stop()
        await controllerManager?.stop()
        await unbindActiveController()
        activeRuntime = nil
        managedProcessID = nil
        resetControllerRuntimeState()
        state = .stopped
        return true
    }

    private func performTerminationBarrier(
        probesDormantPrivilegedRuntime: Bool = true
    ) async -> Bool {
        privilegedStartupLogTask?.cancel()
        privilegedStartupLogTask = nil
        if privilegedHelperClient != nil,
            probesDormantPrivilegedRuntime || privilegedRuntimeMayBeActive
        {
            guard await reconcilePrivilegedRuntimeToStoppedNonCancelling() else {
                return false
            }
        }

        await privilegedLeaseCoordinator?.stop()
        if let runtime = activeRuntime, runtime.backend == .privilegedDaemon {
            await controllerRouter?.unbind(instanceID: runtime.instanceID)
            activeRuntime = nil
        }
        privilegedOperationOutcomeUnknown = false
        preparedPrivilegedCandidate = nil
        lastPrivilegedStartMaterial = nil
        activeBackendKind = .userProcess
        resetControllerRuntimeState()

        let userProcessRunning = await processManager.isRunning()
        if userProcessRunning {
            state = .running(.sprintTwo(
                processRunning: true,
                controllerReachable: controllerState == .connected,
                configurationValid: validationResult?.isValid == true,
                systemProxyApplied: systemProxyStatus.aggregate == .applied
            ))
        } else {
            managedProcessID = nil
            if activeRuntime?.backend == .userProcess {
                await unbindActiveController()
                activeRuntime = nil
            }
            state = .stopped
        }

        let result = await performStop()
        return result.stoppedSafely
    }

    private func presentTerminationBarrierFailure() {
        lastError = UserFacingError(
            title: "Quit Was Cancelled",
            message: "Vela could not prove that the privileged TUN runtime and its routes were stopped.",
            technicalDetails: "Privileged Helper status did not reach a verified stopped state.",
            suggestedAction: "Open Diagnostics, reconnect the privileged component, and retry Quit.",
            isRetryable: true,
            recoveryActions: [.openDiagnostics]
        )
    }

    private func presentUpdatePreparationFailure(code: String) {
        lastError = UserFacingError(
            title: "Update Preparation Failed",
            message: "Vela kept the installer closed because runtime cleanup could not be proved safe.",
            technicalDetails: "Update preparation code: \(code)",
            suggestedAction: "Open Diagnostics, resolve the runtime cleanup issue, and check for updates again.",
            isRetryable: true,
            recoveryActions: [.openDiagnostics]
        )
    }

    func changeMode(_ mode: MihomoMode) async {
        guard let lease = await acquireRuntimeMutationLease(.controllerMutation) else { return }
        await performModeChange(mode)
        await runtimeMutationGate.release(lease)
    }

    func setIPv6Enabled(_ enabled: Bool) async throws {
        if !isRunning {
            runtimeParameters = runtimeParameters.replacingIPv6(with: enabled)
            return
        }

        guard controllerState == .connected, let controllerRouter else {
            throw EngineIPv6MutationError.controllerUnavailable
        }
        guard let lease = await acquireRuntimeMutationLease(.controllerMutation) else {
            throw EngineIPv6MutationError.runtimeBusy
        }

        do {
            try await controllerRouter.patchConfigs(MihomoConfigPatch(ipv6: enabled))
            let configs = try await controllerRouter.configs()
            guard configs.ipv6 == enabled else {
                throw EngineIPv6MutationError.verificationFailed(
                    expected: enabled,
                    actual: configs.ipv6
                )
            }
            runtimeParameters = runtimeParameters.replacingIPv6(with: enabled)
            await runtimeMutationGate.release(lease)
        } catch {
            await runtimeMutationGate.release(lease)
            throw error
        }
    }

    private func performModeChange(_ mode: MihomoMode) async {
        guard isRunning, controllerState == .connected, let controllerManager else {
            present(
                title: "Controller unavailable",
                message: "Vela can change the runtime mode only while the Mihomo controller is connected.",
                error: MihomoControllerSessionError.notConnected,
                suggestedAction: "Start Mihomo or refresh the Controller connection, then try again.",
                isRetryable: true
            )
            return
        }

        lastError = nil
        isChangingMode = true
        defer { isChangingMode = false }
        do {
            try await controllerManager.changeMode(mode)
        } catch {
            present(
                title: "Mode change failed",
                message: "Mihomo did not confirm the requested runtime mode.",
                error: error,
                suggestedAction: "Refresh the Controller state and try again.",
                isRetryable: true
            )
        }
    }

    func refreshProxies(presentErrors: Bool = true) async {
        guard let controllerManager, controllerState == .connected else {
            if presentErrors {
                presentProxyControllerUnavailable()
            }
            return
        }
        guard proxyOperation == nil else {
            if presentErrors {
                presentProxyOperationInProgress()
            }
            return
        }

        lastError = nil
        proxyCatalogError = nil
        isLoadingProxies = true
        let operation = ProxyOperationState.refreshing
        let generation = beginProxyOperation(operation)
        defer {
            if isCurrentProxyOperation(generation, operation: operation) {
                proxyOperation = nil
            }
        }

        do {
            try await controllerManager.refreshProxies()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentProxyOperation(generation, operation: operation) else {
                return
            }
            isLoadingProxies = false
            proxyCatalogError = error.localizedDescription
            if presentErrors {
                present(
                    title: "Proxy refresh failed",
                    message: "Vela could not refresh the proxy groups from Mihomo.",
                    error: error,
                    suggestedAction: "Check the Controller connection and try again.",
                    isRetryable: true
                )
            }
        }
    }

    /// Loads proxy groups and inline nodes from the selected configuration.
    /// Controller data replaces this baseline while connected; runtime-only
    /// actions remain gated by `controllerState`.
    func refreshConfiguredProxyCatalog() async {
        guard let staticConfigurationCatalog else { return }
        let expectedProfileID = selectedProfileID
        do {
            let snapshot = try await staticConfigurationCatalog.selectedSnapshot()
            guard selectedProfileID == expectedProfileID else { return }
            let configured: ProxyCatalog
            if let snapshot {
                guard snapshot.profileID == expectedProfileID else { return }
                configured = snapshot.proxyCatalog
            } else {
                guard expectedProfileID == nil else { return }
                configured = .empty
            }
            configuredProxyCatalog = configured
            guard controllerState != .connected else { return }
            proxyCatalog = configured
            proxyCatalogError = nil
            isLoadingProxies = false
            proxyOperation = nil
            proxyDelayStates = [:]
        } catch is CancellationError {
            return
        } catch {
            guard controllerState != .connected else { return }
            configuredProxyCatalog = .empty
            proxyCatalog = .empty
            proxyCatalogError = DiagnosticTextSanitizer.redact(error.localizedDescription)
            isLoadingProxies = false
        }
    }

    func selectProxy(group: String, proxy: String) async {
        guard let lease = await acquireRuntimeMutationLease(.controllerMutation) else { return }
        await performProxySelection(
            group: group,
            requestedNodeID: nil,
            proxyName: proxy
        )
        await runtimeMutationGate.release(lease)
    }

    func selectProxy(group: String, nodeID: ProxyCatalogID) async {
        guard let lease = await acquireRuntimeMutationLease(.controllerMutation) else { return }
        await performProxySelection(
            group: group,
            requestedNodeID: nodeID,
            proxyName: nodeID.name
        )
        await runtimeMutationGate.release(lease)
    }

    /// Coalesces rapid page interactions without changing the synchronous
    /// semantics used by scenes, startup recovery, and rollback.
    func requestProxySelection(group: String, proxy: String) {
        guard let selectedProfileID else { return }
        requestedProxySelection = RequestedProxySelection(
            profileID: selectedProfileID,
            group: group,
            requestedNodeID: nil,
            proxyName: proxy
        )
        startProxySelectionRequestTaskIfNeeded()
    }

    /// Node-ID variant used by the Proxies page so duplicate display names
    /// remain unambiguous while requests are being coalesced.
    func requestProxySelection(group: String, nodeID: ProxyCatalogID) {
        guard let selectedProfileID else { return }
        requestedProxySelection = RequestedProxySelection(
            profileID: selectedProfileID,
            group: group,
            requestedNodeID: nodeID,
            proxyName: nodeID.name
        )
        startProxySelectionRequestTaskIfNeeded()
    }

    private func startProxySelectionRequestTaskIfNeeded() {
        guard proxySelectionRequestTask == nil else { return }
        proxySelectionRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let request = self.requestedProxySelection else { break }
                if self.proxyOperation != nil || self.isEngineTransitioning {
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        break
                    }
                    continue
                }

                self.requestedProxySelection = nil
                guard request.profileID == self.selectedProfileID,
                    !self.isPreparingForTermination
                else { continue }

                if let nodeID = request.requestedNodeID {
                    await self.selectProxy(group: request.group, nodeID: nodeID)
                } else {
                    await self.selectProxy(group: request.group, proxy: request.proxyName)
                }
            }
            self.proxySelectionRequestTask = nil
        }
    }

    private func performProxySelection(
        group: String,
        requestedNodeID: ProxyCatalogID?,
        proxyName: String
    ) async {
        guard let controllerManager, controllerState == .connected else {
            presentProxyControllerUnavailable()
            return
        }
        guard proxyOperation == nil else {
            presentProxyOperationInProgress()
            return
        }
        guard let selectedGroup = proxyCatalog.group(named: group),
            selectedGroup.isSelectable,
            let selectedProfileID
        else {
            lastError = UserFacingError(
                title: "Proxy unavailable",
                message: "The selected proxy is no longer available in \(group).",
                suggestedAction: "Refresh the proxy list and choose another node.",
                isRetryable: true
            )
            return
        }

        let selectedNode = if let requestedNodeID {
            selectedGroup.nodes.first { $0.id == requestedNodeID }
        } else {
            selectedGroup.nodes.first { $0.name == proxyName }
        }
        guard let selectedNode else {
            lastError = UserFacingError(
                title: "Proxy unavailable",
                message: "The selected proxy is no longer available in \(group).",
                suggestedAction: "Refresh the proxy list and choose another node.",
                isRetryable: true
            )
            return
        }

        guard !selectionIsConfirmed(proxyName, in: selectedGroup) else { return }

        lastError = nil
        let operation = ProxyOperationState.selecting(
            groupName: group,
            proxyID: selectedNode.id
        )
        let generation = beginProxyOperation(operation)
        defer {
            if isCurrentProxyOperation(
                generation,
                operation: operation,
                profileID: selectedProfileID
            ) {
                proxyOperation = nil
            }
        }

        do {
            try await controllerManager.selectProxy(group: group, proxy: proxyName)
            guard isCurrentProxyOperation(
                generation,
                operation: operation,
                profileID: selectedProfileID
            ) else {
                return
            }
            await recordRecentProxy(
                profileID: selectedProfileID,
                groupName: group,
                proxyName: proxyName,
                operationGeneration: generation
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentProxyOperation(
                generation,
                operation: operation,
                profileID: selectedProfileID
            ) else {
                return
            }
            present(
                title: "Proxy switch failed",
                message: "Mihomo did not confirm the requested proxy.",
                error: error,
                suggestedAction: "Refresh the group state and try again.",
                isRetryable: true
            )
        }
    }

    func testProxyDelay(group: String, proxy: String) async {
        await performProxyDelayTest(
            group: group,
            requestedNodeID: nil,
            proxyName: proxy
        )
    }

    func testProxyDelay(group: String, nodeID: ProxyCatalogID) async {
        await performProxyDelayTest(
            group: group,
            requestedNodeID: nodeID,
            proxyName: nodeID.name
        )
    }

    private func performProxyDelayTest(
        group: String,
        requestedNodeID: ProxyCatalogID?,
        proxyName: String
    ) async {
        guard let controllerManager, controllerState == .connected else {
            presentProxyControllerUnavailable()
            return
        }
        guard proxyOperation == nil else {
            presentProxyOperationInProgress()
            return
        }
        guard let selectedGroup = proxyCatalog.group(named: group),
            let selectedProfileID
        else {
            return
        }

        let node = if let requestedNodeID {
            selectedGroup.nodes.first { $0.id == requestedNodeID }
        } else {
            selectedGroup.nodes.first { $0.name == proxyName }
        }
        guard let node else { return }
        guard !node.isPlaceholder || proxyCatalog.group(named: node.name) != nil else {
            return
        }
        let delayTarget = resolvedDelayTarget(for: node)
        let delayGroup = proxyCatalog.group(named: node.name)

        let operation = ProxyOperationState.testingProxy(
            groupName: group,
            proxyID: node.id
        )
        lastError = nil
        let generation = beginProxyOperation(operation)
        let cacheKey = delayCacheKey(
            profileID: selectedProfileID,
            group: selectedGroup,
            proxyID: node.id
        )
        proxyDelayStates[cacheKey] = .testing
        defer {
            if isCurrentProxyOperation(
                generation,
                operation: operation,
                profileID: selectedProfileID
            ) {
                proxyOperation = nil
            }
        }

        do {
            let result = try await controllerManager.testProxyDelay(
                nodeID: delayTarget.id,
                url: delayGroup.map(testURL(for:)) ?? testURL(for: selectedGroup),
                timeoutMilliseconds: ProxyTestDefaults.timeoutMilliseconds,
                expectedStatus: delayGroup?.expectedStatus?.nilIfEmpty
                    ?? selectedGroup.expectedStatus?.nilIfEmpty
            )
            guard isCurrentProxyOperation(
                generation,
                operation: operation,
                profileID: selectedProfileID
            ) else {
                return
            }
            proxyDelayStates[cacheKey] = delayState(from: result)
        } catch is CancellationError {
            guard isCurrentProxyOperation(
                generation,
                operation: operation,
                profileID: selectedProfileID
            ) else {
                return
            }
            proxyDelayStates.removeValue(forKey: cacheKey)
        } catch {
            guard isCurrentProxyOperation(
                generation,
                operation: operation,
                profileID: selectedProfileID
            ) else {
                return
            }
            proxyDelayStates[cacheKey] = .failed(error.localizedDescription)
            present(
                title: "Delay test failed",
                message: "\(proxyName) did not return a usable delay result.",
                error: error,
                suggestedAction: "Check the node and network, then test it again.",
                isRetryable: true
            )
        }
    }

    func testProxyGroupDelay(
        group: String,
        showsFailureAlert: Bool = true
    ) async {
        guard let controllerManager, controllerState == .connected else {
            presentProxyControllerUnavailable()
            return
        }
        guard proxyOperation == nil else {
            presentProxyOperationInProgress()
            return
        }
        guard let selectedGroup = proxyCatalog.group(named: group),
            let selectedProfileID
        else {
            return
        }

        var seenTargetIDs: Set<ProxyCatalogID> = []
        var cacheKeysByTargetID: [ProxyCatalogID: [ProxyDelayCacheKey]] = [:]
        let nodeIDs = selectedGroup.nodes.compactMap { node -> ProxyCatalogID? in
            guard !node.isPlaceholder || proxyCatalog.group(named: node.name) != nil else {
                return nil
            }
            let target = resolvedDelayTarget(for: node)
            cacheKeysByTargetID[target.id, default: []].append(
                delayCacheKey(
                    profileID: selectedProfileID,
                    group: selectedGroup,
                    proxyID: node.id
                )
            )
            return seenTargetIDs.insert(target.id).inserted ? target.id : nil
        }
        guard !nodeIDs.isEmpty else { return }

        let operation = ProxyOperationState.testingGroup(groupName: group)
        lastError = nil
        let generation = beginProxyOperation(operation)
        let cacheKeys = cacheKeysByTargetID.values.flatMap { $0 }
        for cacheKey in cacheKeys {
            proxyDelayStates[cacheKey] = .testing
        }
        defer {
            if isCurrentProxyOperation(
                generation,
                operation: operation,
                profileID: selectedProfileID
            ) {
                proxyOperation = nil
            }
        }

        do {
            let results = try await controllerManager.testProxyGroupDelay(
                nodeIDs: nodeIDs,
                url: testURL(for: selectedGroup),
                timeoutMilliseconds: ProxyTestDefaults.timeoutMilliseconds,
                expectedStatus: selectedGroup.expectedStatus?.nilIfEmpty,
                concurrencyLimit: ProxyTestDefaults.groupConcurrencyLimit
            )
            guard isCurrentProxyOperation(
                generation,
                operation: operation,
                profileID: selectedProfileID
            ) else {
                return
            }
            for result in results {
                for cacheKey in cacheKeysByTargetID[result.proxyID] ?? [] {
                    proxyDelayStates[cacheKey] = delayState(from: result)
                }
            }
        } catch is CancellationError {
            guard isCurrentProxyOperation(
                generation,
                operation: operation,
                profileID: selectedProfileID
            ) else {
                return
            }
            for cacheKey in cacheKeys where proxyDelayStates[cacheKey] == .testing {
                proxyDelayStates.removeValue(forKey: cacheKey)
            }
        } catch {
            guard isCurrentProxyOperation(
                generation,
                operation: operation,
                profileID: selectedProfileID
            ) else {
                return
            }
            for cacheKey in cacheKeys where proxyDelayStates[cacheKey] == .testing {
                proxyDelayStates[cacheKey] = .failed(error.localizedDescription)
            }
            if showsFailureAlert {
                present(
                    title: "Group delay test failed",
                    message: "Vela could not finish testing \(group).",
                    error: error,
                    suggestedAction: "Check the Controller connection and try again.",
                    isRetryable: true
                )
            }
        }
    }

    func dismissError() {
        lastError = nil
    }

    func presentRuntimeRecoveryFailure(_ error: UserFacingError) {
        lastError = error
    }

    func clearLogs() async {
        privilegedStartupLogTask?.cancel()
        privilegedStartupLogTask = nil
        await controllerManager?.clearLogs()
        privilegedStartupLogEntries = []
        if controllerManager == nil {
            logEntries = []
        }
    }

    private func loadRecentProxies() async {
        recentLoadGeneration &+= 1
        let generation = recentLoadGeneration
        guard let selectedProfileID else {
            recentProxies = []
            recentProxyError = nil
            return
        }
        guard let recentProxyStore else {
            recentProxies = recentProxies.filter { $0.profileID == selectedProfileID }
            return
        }

        do {
            let records = try await recentProxyStore.load(for: selectedProfileID)
            guard recentLoadGeneration == generation,
                self.selectedProfileID == selectedProfileID
            else {
                return
            }
            recentProxies = records
            recentProxyError = nil
        } catch {
            guard recentLoadGeneration == generation,
                self.selectedProfileID == selectedProfileID
            else {
                return
            }
            recentProxies = []
            recentProxyError = error.localizedDescription
        }
    }

    private func recordRecentProxy(
        profileID: UUID,
        groupName: String,
        proxyName: String,
        operationGeneration: UInt64
    ) async {
        guard selectedProfileID == profileID,
            proxyOperationGeneration == operationGeneration
        else {
            return
        }

        let record = RecentProxyRecord(
            profileID: profileID,
            groupName: groupName,
            proxyName: proxyName,
            usedAt: .now
        )
        recentLoadGeneration &+= 1
        recentProxies.removeAll {
            $0.profileID != profileID
                || (
                    $0.groupName == groupName
                        && $0.proxyName == proxyName
                )
        }
        recentProxies.insert(record, at: 0)
        recentProxies = Array(recentProxies.prefix(8))

        guard let recentProxyStore else { return }
        do {
            try await recentProxyStore.record(
                profileID: profileID,
                groupName: groupName,
                proxyName: proxyName,
                usedAt: record.usedAt
            )
            guard selectedProfileID == profileID,
                proxyOperationGeneration == operationGeneration
            else {
                return
            }
            recentProxyError = nil
        } catch {
            guard selectedProfileID == profileID,
                proxyOperationGeneration == operationGeneration
            else {
                return
            }
            recentProxyError = error.localizedDescription
        }
    }

    private func testURL(for group: ProxyGroup) -> String {
        group.testURL?.nilIfEmpty ?? ProxyTestDefaults.url
    }

    private func resolvedDelayTarget(for node: ProxyNode) -> ProxyNode {
        var candidate = node
        var visitedGroupNames = Set<String>()

        while case .runtime = candidate.origin,
            let nestedGroup = proxyCatalog.group(named: candidate.name),
            visitedGroupNames.insert(nestedGroup.name).inserted
        {
            let selectedName = nestedGroup.now?.nilIfEmpty
                ?? nestedGroup.fixed?.nilIfEmpty
            guard let next = selectedName.flatMap({ name in
                nestedGroup.nodes.first { $0.name == name && !$0.isPlaceholder }
            }) ?? nestedGroup.nodes.first(where: { !$0.isPlaceholder }) else {
                break
            }
            candidate = next
        }
        return candidate
    }

    private func delayState(from result: MihomoProxyDelayResult) -> ProxyDelayState {
        if let errorDescription = result.errorDescription {
            return .failed(errorDescription)
        }
        guard let delay = result.delayMilliseconds, delay > 0 else {
            return .unavailable
        }
        return .measured(milliseconds: delay)
    }

    private func selectionIsConfirmed(_ proxyName: String, in group: ProxyGroup) -> Bool {
        switch group.type {
        case "URLTest", "Fallback":
            group.fixed?.nilIfEmpty == proxyName
        case "Selector":
            group.now == proxyName
        default:
            false
        }
    }

    private func delayCacheKey(
        profileID: UUID,
        group: ProxyGroup,
        proxyID: ProxyCatalogID
    ) -> ProxyDelayCacheKey {
        ProxyDelayCacheKey(
            profileID: profileID,
            groupName: group.name,
            proxyID: proxyID,
            testURL: testURL(for: group),
            expectedStatus: group.expectedStatus?.nilIfEmpty
        )
    }

    @discardableResult
    private func beginProxyOperation(_ operation: ProxyOperationState) -> UInt64 {
        proxyOperationGeneration &+= 1
        proxyOperation = operation
        return proxyOperationGeneration
    }

    private func isCurrentProxyOperation(
        _ generation: UInt64,
        operation: ProxyOperationState,
        profileID: UUID? = nil
    ) -> Bool {
        guard proxyOperationGeneration == generation,
            proxyOperation == operation,
            controllerState == .connected
        else {
            return false
        }
        if let profileID {
            return selectedProfileID == profileID
        }
        return true
    }

    private func presentProxyControllerUnavailable() {
        lastError = UserFacingError(
            title: "Controller unavailable",
            message: "Proxy actions require a connected Mihomo Controller.",
            suggestedAction: "Start Mihomo or refresh the Controller connection, then try again.",
            isRetryable: true
        )
    }

    private func presentProxyOperationInProgress() {
        lastError = UserFacingError(
            title: "Proxy operation in progress",
            message: "Wait for the current proxy switch or delay test to finish.",
            isRetryable: true
        )
    }

    private var canChangeProfile: Bool {
        !isBusy && !isRunning
    }

    private func acquireRuntimeMutationLease(
        _ activity: RuntimeMutationActivity
    ) async -> RuntimeMutationLease? {
        do {
            let lease = try await runtimeMutationGate.acquire(activity)
            guard !isValidationShutdownInProgress else {
                await runtimeMutationGate.release(lease)
                return nil
            }
            return lease
        } catch RuntimeMutationGateError.updateInProgress {
            presentUpdateInProgress()
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    private func presentUpdateInProgress() {
        lastError = UserFacingError(
            title: "Updating Vela",
            message: "This change is unavailable while Vela prepares or recovers an update.",
            technicalDetails: "updateInProgress",
            suggestedAction: "Wait for the update operation to finish, then try again.",
            isRetryable: true
        )
    }

    private func rejectMutationDuringUpdateIfNeeded() -> Bool {
        guard updatePreparationState != .idle || isUpdateRecoveryInProgress else {
            return false
        }
        presentUpdateInProgress()
        return true
    }

    private func transitionToTun() async {
        guard let transitionCoordinator, let privilegedBackend else {
            presentPrivilegedComponentNotReady()
            return
        }
        await beginObservingTransitionEventsIfNeeded()
        await transitionCoordinator.resetFailure()
        transitionSourceWasRunning = isRunning
        transitionSystemProxyWasApplied = isSystemProxyApplied
        preparedPrivilegedCandidate = nil

        let plan = EngineTransitionPlan(
            source: .userProcess,
            target: .privilegedDaemon,
            prepareTarget: { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                try await self.preparePrivilegedTarget(using: privilegedBackend)
            },
            disableSystemProxy: { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                if self.isSystemProxyApplied {
                    await self.performSetSystemProxyEnabled(false)
                    guard !self.isSystemProxyApplied, !self.systemProxyNeedsRestore else {
                        throw EngineStoreTunError.systemProxyCouldNotBeDisabled
                    }
                }
            },
            stopSource: { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                if self.transitionSourceWasRunning {
                    let result = await self.performStop()
                    guard result.stoppedSafely else {
                        throw EngineStoreTunError.sourceBackendCouldNotStop
                    }
                }
            },
            startTarget: { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                try await self.startPreparedPrivilegedTarget(using: privilegedBackend)
            },
            verifyTarget: { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                try await self.verifyPrivilegedTarget()
            },
            commit: { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                self.preparedPrivilegedCandidate = nil
                self.tunPauseUntil = nil
                self.state = .running(self.privilegedEngineHealth())
            },
            rollback: { @MainActor [weak self] _ in
                guard let self else { return .failed("The app state was released.") }
                return await self.rollbackToUserSource(using: privilegedBackend)
            }
        )

        do {
            _ = try await transitionCoordinator.transition(using: plan)
            lastError = nil
            do {
                try await restoreTransitionSystemProxyIfNeeded()
            } catch {
                presentSystemProxyFailure(
                    "System Proxy could not be restored",
                    error: error,
                    suggestedAction: "TUN is active. Retry System Proxy after the Controller is connected."
                )
            }
        } catch {
            presentTransitionFailure(
                title: "TUN Could Not Be Enabled",
                error: error,
                fallback: tunEnableRecoverySuggestion(for: error)
            )
        }
    }

    private func tunEnableRecoverySuggestion(for error: Error) -> String {
        guard let transitionError = error as? EngineTransitionCoordinatorError,
            case let .transitionFailed(failure) = transitionError
        else {
            return "Vela attempted to restore the previous user-process mode."
        }

        switch failure.failedPhase {
        case .startingTarget, .verifyingTarget:
            return "Stop any other VPN or TUN client (including Clash Verge), then retry. Vela restored the previous user-process mode."
        case .disablingSystemProxy:
            return "Restore System Proxy first, then retry TUN. Vela kept the previous user-process mode."
        case .preparingTarget, .stoppingSource, .committing, .rollingBack:
            return "Open Diagnostics for the failed transition evidence, then retry after resolving it. Vela attempted to restore the previous user-process mode."
        }
    }

    private func transitionToUser(restoreSystemProxy: Bool) async {
        guard let transitionCoordinator, let privilegedBackend else {
            presentPrivilegedComponentNotReady()
            return
        }
        await beginObservingTransitionEventsIfNeeded()
        await transitionCoordinator.resetFailure()
        transitionSystemProxyWasApplied = isSystemProxyApplied
        preparedUserTransitionLaunch = nil

        let plan = EngineTransitionPlan(
            source: .privilegedDaemon,
            target: .userProcess,
            prepareTarget: { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                try await self.prepareUserTarget()
            },
            disableSystemProxy: {},
            stopSource: { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                try await self.stopPrivilegedRuntime(
                    using: privilegedBackend,
                    reason: .backendTransition
                )
            },
            startTarget: { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                try await self.startPreparedUserTarget()
            },
            verifyTarget: { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                try await self.verifyUserTarget()
            },
            commit: { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                self.preparedUserTransitionLaunch = nil
                if restoreSystemProxy {
                    await self.performSetSystemProxyEnabled(true)
                    guard self.isSystemProxyApplied,
                        self.systemProxyOperation == nil
                    else {
                        throw EngineStoreTunError.systemProxyCouldNotBeRestored
                    }
                }
                self.lastPrivilegedStartMaterial = nil
            },
            rollback: { @MainActor [weak self] _ in
                guard let self else { return .failed("The app state was released.") }
                return await self.rollbackToPrivilegedSource(using: privilegedBackend)
            }
        )

        do {
            _ = try await transitionCoordinator.transition(using: plan)
            lastError = nil
        } catch {
            presentTransitionFailure(
                title: "TUN Could Not Be Disabled",
                error: error,
                fallback: "Vela attempted to restore the privileged runtime."
            )
        }
    }

    private func preparePrivilegedTarget(
        using backend: any EngineBackend
    ) async throws {
        guard let sessionID = privilegedComponentManager?.lastHandshake?.sessionID else {
            throw EngineStoreTunError.helperSessionUnavailable
        }
        let generation = beginEngineOperation(wantsRunning: true)
        let launch = try await prepareValidatedLaunch(operationGeneration: generation)
        try ensureCurrentEngineOperation(generation, wantsRunning: true)
        let configuration = try Data(contentsOf: launch.configurationURL, options: [.mappedIfSafe])
        let resources = try Self.privilegedResources(
            configuration: configuration,
            configurationURL: launch.configurationURL,
            mihomoDataDirectoryURL: mihomoDataDirectoryURL
        )
        let material = PrivilegedEngineStartMaterial(
            sessionID: sessionID,
            configuration: configuration,
            configurationSHA256: Self.sha256(configuration),
            resources: resources,
            tunSettings: try effectiveTunSettings()
        )
        lastPrivilegedStartMaterial = material
        preparedPrivilegedCandidate = try await preparePrivilegedStart(
            using: backend,
            EngineStartRequest(
                backend: .privilegedDaemon,
                coreID: await currentCoreID(),
                material: material
            )
        )
    }

    private func startPreparedPrivilegedTarget(
        using backend: any EngineBackend
    ) async throws {
        guard let candidate = preparedPrivilegedCandidate else {
            throw EngineStoreTunError.preparedTargetUnavailable
        }
        state = .starting
        let runtime: EngineRuntime
        do {
            runtime = try await backend.commitStart(candidate)
        } catch {
            if Self.isIndeterminatePrivilegedRPCFailure(error) {
                privilegedOperationOutcomeUnknown = true
            }
            throw error
        }
        guard runtime.backend == .privilegedDaemon else {
            throw EngineStoreTunError.unexpectedRuntimeBackend
        }
        activeBackendKind = .privilegedDaemon
        activeRuntime = runtime
        managedProcessID = nil
        wantsEngineRunning = true
        await healthMonitor?.stop()
        invalidateHealthSession()
        try await bindController(to: runtime)
        state = .running(privilegedEngineHealth())
        await startControllerIfAvailable()
        if let sessionID = lastPrivilegedStartMaterial?.sessionID {
            await privilegedLeaseCoordinator?.start(
                sessionID: sessionID,
                instanceID: runtime.instanceID
            )
            schedulePrivilegedStartupLogCapture(
                sessionID: sessionID,
                instanceID: runtime.instanceID
            )
        }
    }

    private func schedulePrivilegedStartupLogCapture(
        sessionID: UUID,
        instanceID: UUID
    ) {
        privilegedStartupLogTask?.cancel()
        privilegedStartupLogEntries = []
        guard let privilegedHelperClient else { return }
        privilegedStartupLogTask = Task { @MainActor [weak self, privilegedHelperClient] in
            let entries: [HelperLogEntry]
            do {
                entries = try await PrivilegedStartupLogReader.read(
                    client: privilegedHelperClient,
                    sessionID: sessionID
                )
            } catch {
                guard !Task.isCancelled,
                    let self,
                    self.activeRuntime?.instanceID == instanceID,
                    self.activeBackendKind == .privilegedDaemon
                else { return }
                // Startup logs are diagnostic-only. A failed bounded read must
                // not turn a healthy runtime into a failed transition.
                await self.controllerManager?.recordApplicationLog(
                    level: .warning,
                    message: "Privileged Mihomo startup logs were unavailable."
                )
                return
            }

            guard !Task.isCancelled,
                let self,
                self.activeRuntime?.instanceID == instanceID,
                self.activeBackendKind == .privilegedDaemon
            else { return }

            self.privilegedStartupLogEntries = PrivilegedStartupLogMapper.logEntries(
                from: entries,
                sessionID: sessionID
            )
            let processOutputs = PrivilegedStartupLogMapper.processOutputs(from: entries)
            if let controllerManager = self.controllerManager {
                await controllerManager.appendProcessOutputs(processOutputs)
            } else {
                self.logEntries = self.privilegedStartupLogEntries
            }
        }
    }

    private func verifyPrivilegedTarget() async throws {
        guard let client = privilegedHelperClient else {
            throw EngineStoreTunError.helperSessionUnavailable
        }
        for _ in 0..<40 {
            try Task.checkCancellation()
            let response = try await client.status()
            privilegedHealth = response.health
            if privilegedHealthIsReady(response.health) {
                state = .running(privilegedEngineHealth())
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw EngineStoreTunError.tunHealthVerificationTimedOut
    }

    private func prepareUserTarget() async throws {
        let generation = beginEngineOperation(wantsRunning: true)
        preparedUserTransitionLaunch = try await prepareValidatedLaunch(
            operationGeneration: generation
        )
        try ensureCurrentEngineOperation(generation, wantsRunning: true)
    }

    private func startPreparedUserTarget() async throws {
        guard let launch = preparedUserTransitionLaunch else {
            throw EngineStoreTunError.preparedTargetUnavailable
        }
        let controllerEndpoint = try userControllerEndpoint()
        let configurationSHA = await configurationSHA256(for: launch.configurationURL)
        activeBackendKind = .userProcess
        state = .starting
        let snapshot = try await processManager.start(
            preparedLaunch: MihomoPreparedLaunch(
                executable: launch.executable,
                configurationURL: launch.configurationURL,
                dataDirectoryURL: mihomoDataDirectoryURL,
                validationResult: launch.validationResult
            )
        )
        guard snapshot.isRunning else { throw EngineStoreOperationError.processDidNotStart }
        let runtime = EngineRuntime(
            instanceID: UUID(),
            backend: .userProcess,
            controller: EngineControllerAccess(
                endpoint: controllerEndpoint,
                secret: SecretValue(runtimeParameters.secret)
            ),
            processID: snapshot.pid,
            startedAt: snapshot.startedAt ?? now(),
            configurationSHA256: configurationSHA
        )
        managedProcessID = snapshot.pid
        activeRuntime = runtime
        privilegedHealth = nil
        try await bindController(to: runtime)
        updateRunningHealth(controllerReachable: false)
        await startControllerIfAvailable()
        await startHealthMonitoringIfNeeded()
    }

    private func verifyUserTarget() async throws {
        for _ in 0..<40 {
            try Task.checkCancellation()
            if await processManager.isRunning(), controllerState == .connected {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw EngineStoreTunError.userRuntimeVerificationTimedOut
    }

    private func rollbackToUserSource(
        using backend: any EngineBackend
    ) async -> EngineRollbackOutcome {
        if isPreparingForTermination {
            return .succeeded
        }
        do {
            if privilegedOperationOutcomeUnknown {
                guard await reconcilePrivilegedRuntimeToStoppedNonCancelling() else {
                    throw EngineStoreTunError.privilegedOperationOutcomeUnknown
                }
            }
            if activeBackendKind == .privilegedDaemon, activeRuntime != nil {
                try await stopPrivilegedRuntime(using: backend, reason: .backendTransition)
            } else if let candidate = preparedPrivilegedCandidate {
                await backend.abortStart(candidate)
                preparedPrivilegedCandidate = nil
            }

            activeBackendKind = .userProcess
            pendingSystemProxyReapply = false
            let mustRestoreUserRuntime = transitionSourceWasRunning
                || transitionSystemProxyWasApplied
            if mustRestoreUserRuntime {
                if !isRunning || activeRuntime?.backend != .userProcess {
                    state = .stopped
                    await performStart()
                }
                guard isRunning, activeRuntime?.backend == .userProcess else {
                    throw EngineStoreTunError.rollbackSourceCouldNotStart
                }
                try await verifyUserTarget()
            } else {
                state = .stopped
            }

            // Rollback is not complete until the user backend and its original
            // proxy mode are both synchronously restored. The controller-ready
            // callback must not turn an already-reported success into a later,
            // unobserved proxy failure.
            pendingSystemProxyReapply = false
            if transitionSystemProxyWasApplied {
                try await proveSystemProxyCleanForBackendTransition()
                await performSetSystemProxyEnabled(true)
                guard isSystemProxyApplied, systemProxyOperation == nil else {
                    throw EngineStoreTunError.systemProxyCouldNotBeRestored
                }
            }
            return .succeeded
        } catch {
            pendingSystemProxyReapply = false
            return .failed(error.localizedDescription)
        }
    }

    private func rollbackToPrivilegedSource(
        using backend: any EngineBackend
    ) async -> EngineRollbackOutcome {
        if isPreparingForTermination {
            return .succeeded
        }
        do {
            // Never bring the root TUN back while a failed user-mode commit may
            // have left even a partial Vela System Proxy mutation behind. A
            // fresh restore result is required; cached status alone is not
            // authoritative after an enable/rollback double fault.
            try await proveSystemProxyCleanForBackendTransition()
            if privilegedOperationOutcomeUnknown {
                guard await reconcilePrivilegedRuntimeToStoppedNonCancelling() else {
                    throw EngineStoreTunError.privilegedOperationOutcomeUnknown
                }
            }
            if let runtime = activeRuntime, runtime.backend == .privilegedDaemon {
                guard let sessionID = lastPrivilegedStartMaterial?.sessionID else {
                    throw EngineStoreTunError.rollbackMaterialUnavailable
                }
                try await bindController(to: runtime)
                await startControllerIfAvailable()
                await privilegedLeaseCoordinator?.start(
                    sessionID: sessionID,
                    instanceID: runtime.instanceID
                )
                try await verifyPrivilegedTarget()
                try await restoreTransitionSystemProxyIfNeeded()
                return .succeeded
            }
            guard let material = lastPrivilegedStartMaterial else {
                throw EngineStoreTunError.rollbackMaterialUnavailable
            }
            let coreID = await currentCoreID()
            // Policy is checked before stopping the user-mode source. The
            // Helper repeats validation in prepareStart after the stop.
            try await tunCorePolicyGate?(coreID)
            let userProcessWasRunning = await processManager.isRunning()
            if activeRuntime?.backend == .userProcess || userProcessWasRunning {
                let result = await performStop()
                guard result.stoppedSafely else {
                    throw EngineStoreTunError.sourceBackendCouldNotStop
                }
            }
            guard !(await processManager.isRunning()),
                activeRuntime?.backend != .userProcess
            else {
                throw EngineStoreTunError.sourceBackendCouldNotStop
            }
            let candidate = try await preparePrivilegedStart(
                using: backend,
                EngineStartRequest(
                    backend: .privilegedDaemon,
                    coreID: coreID,
                    material: material
                )
            )
            preparedPrivilegedCandidate = candidate
            try await startPreparedPrivilegedTarget(using: backend)
            try await verifyPrivilegedTarget()
            preparedPrivilegedCandidate = nil
            try await restoreTransitionSystemProxyIfNeeded()
            return .succeeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func proveSystemProxyCleanForBackendTransition() async throws {
        pendingSystemProxyReapply = false
        guard systemProxyOperation == nil else {
            throw EngineStoreTunError.systemProxyCouldNotBeDisabled
        }

        let cleanup = await restoreSystemProxyBeforeStopping()
        guard cleanup.isSafe,
            systemProxyOperation == nil,
            !isSystemProxyApplied,
            !systemProxyNeedsRestore,
            visibleSystemProxyTargetServiceNames(in: systemProxyStatus).isEmpty
        else {
            throw EngineStoreTunError.systemProxyCouldNotBeDisabled
        }
    }

    private func restoreTransitionSystemProxyIfNeeded() async throws {
        guard transitionSystemProxyWasApplied else { return }
        pendingSystemProxyReapply = true
        guard controllerState == .connected else { return }
        pendingSystemProxyReapply = false
        await performSetSystemProxyEnabled(true)
        guard isSystemProxyApplied, systemProxyOperation == nil else {
            throw EngineStoreTunError.systemProxyCouldNotBeRestored
        }
    }

    private func stopPrivilegedRuntime(
        using backend: any EngineBackend,
        reason: EngineStopReason
    ) async throws {
        privilegedStartupLogTask?.cancel()
        privilegedStartupLogTask = nil
        let runtime = activeRuntime
        await controllerManager?.stop()
        await privilegedLeaseCoordinator?.stop()
        do {
            _ = try await backend.stop(
                EngineStopRequest(
                    instanceID: runtime?.instanceID,
                    reason: reason,
                    timeout: .seconds(8)
                )
            )
        } catch {
            guard Self.isIndeterminatePrivilegedRPCFailure(error) else { throw error }
            privilegedOperationOutcomeUnknown = true
            guard !isPreparingForTermination,
                await reconcilePrivilegedRuntimeToStoppedNonCancelling()
            else {
                throw EngineStoreTunError.privilegedOperationOutcomeUnknown
            }
        }
        if let runtime {
            await controllerRouter?.unbind(instanceID: runtime.instanceID)
        }
        activeRuntime = nil
        privilegedHealth = nil
        privilegedOperationOutcomeUnknown = false
        resetControllerRuntimeState()
    }

    private func stopPrivilegedEngine(
        reason: EngineStopReason,
        updateState: Bool
    ) async {
        guard let privilegedBackend else {
            if updateState { state = .stopped }
            return
        }
        if updateState { state = .stopping }
        do {
            try await stopPrivilegedRuntime(using: privilegedBackend, reason: reason)
            activeBackendKind = .userProcess
            wantsEngineRunning = false
            lastPrivilegedStartMaterial = nil
            if updateState { state = .stopped }
        } catch {
            state = .running(privilegedEngineHealth())
            presentTransitionFailure(
                title: "TUN Is Still Running",
                error: error,
                fallback: "Retry Stop or run cleanup from Diagnostics."
            )
        }
    }

    @discardableResult
    private func performPrivilegedRestart() async -> Bool {
        guard let privilegedBackend, let material = lastPrivilegedStartMaterial else {
            presentPrivilegedComponentNotReady()
            return false
        }
        var candidate: EnginePreparedStart?
        do {
            let coreID = await currentCoreID()
            // Never tear down a healthy privileged runtime merely because a
            // newly-blocked Core cannot pass the next-start policy.
            try await tunCorePolicyGate?(coreID)
            state = .stopping
            try await stopPrivilegedRuntime(using: privilegedBackend, reason: .recovery)
            let prepared = try await preparePrivilegedStart(
                using: privilegedBackend,
                EngineStartRequest(
                    backend: .privilegedDaemon,
                    coreID: coreID,
                    material: material
                )
            )
            candidate = prepared
            preparedPrivilegedCandidate = prepared
            try await startPreparedPrivilegedTarget(using: privilegedBackend)
            try await verifyPrivilegedTarget()
            preparedPrivilegedCandidate = nil
            return true
        } catch {
            if let candidate {
                await privilegedBackend.abortStart(candidate)
            }
            preparedPrivilegedCandidate = nil
            await settlePrivilegedRestartFailure(
                using: privilegedBackend,
                error: error
            )
            presentTransitionFailure(
                title: "TUN Restart Failed",
                error: error,
                fallback: "Vela left System Proxy disabled. Open Diagnostics before retrying."
            )
            return false
        }
    }

    private func settlePrivilegedRestartFailure(
        using backend: any EngineBackend,
        error: Error
    ) async {
        do {
            let status = try await backend.status()
            if status.lifecycle == .stopped,
                !status.processRunning,
                status.runtime == nil
            {
                await privilegedLeaseCoordinator?.stop()
                if let runtime = activeRuntime {
                    await controllerRouter?.unbind(instanceID: runtime.instanceID)
                }
                activeRuntime = nil
                privilegedHealth = nil
                privilegedOperationOutcomeUnknown = false
                activeBackendKind = .userProcess
                wantsEngineRunning = false
                resetControllerRuntimeState()
                state = .failed(.healthCheckFailed(error.localizedDescription))
                return
            }

            activeBackendKind = .privilegedDaemon
            if let runtime = status.runtime {
                activeRuntime = runtime
            }
            privilegedOperationOutcomeUnknown = status.processRunning && status.runtime == nil
            if status.processRunning, activeRuntime != nil {
                let health = privilegedEngineHealth()
                state = .running(EngineHealth(
                    processRunning: true,
                    controllerReachable: health.controllerReachable,
                    configurationValid: health.configurationValid,
                    systemProxyApplied: false,
                    networkReachable: networkPathSnapshot.networkReachable,
                    internetReachable: health.internetReachable,
                    portsListening: health.portsListening,
                    lastCheckedAt: now(),
                    overallState: .degraded
                ))
            } else {
                state = .recovering
            }
        } catch {
            // Status failure means a root process cannot be ruled out. Keep the
            // privileged backend in a busy fail-closed state.
            activeBackendKind = .privilegedDaemon
            privilegedOperationOutcomeUnknown = true
            state = .recovering
        }
    }

    private func refreshPrivilegedHealth(presentErrors: Bool) async {
        guard let privilegedHelperClient else {
            if presentErrors { presentPrivilegedComponentNotReady() }
            return
        }
        do {
            let response = try await privilegedHelperClient.status()
            privilegedHealth = response.health
            if activeBackendKind == .privilegedDaemon {
                if response.health.processRunning {
                    state = .running(privilegedEngineHealth())
                } else {
                    await privilegedLeaseCoordinator?.stop()
                    if let runtime = activeRuntime {
                        await controllerRouter?.unbind(instanceID: runtime.instanceID)
                    }
                    activeRuntime = nil
                    state = .failed(.unexpectedTermination(exitCode: -1))
                }
            }
        } catch {
            if presentErrors {
                presentTransitionFailure(
                    title: "Privileged Health Check Failed",
                    error: error,
                    fallback: "Refresh the component or open Diagnostics."
                )
            }
        }
    }

    private func reconcilePrivilegedRuntimeToStoppedNonCancelling() async -> Bool {
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.reconcilePrivilegedRuntimeToStopped()
        }
        return await task.value
    }

    /// Resolves an XPC timeout/cancellation by treating Helper status as the
    /// authority. No user-process rollback or second root start may happen
    /// until this method proves that the original root operation has settled
    /// and the privileged runtime is cleanly stopped.
    private func reconcilePrivilegedRuntimeToStopped() async -> Bool {
        guard let client = privilegedHelperClient,
            let manager = privilegedComponentManager
        else {
            return false
        }

        let requiresAuthoritativeStopProof = privilegedOperationOutcomeUnknown
            || activeBackendKind == .privilegedDaemon
            || activeRuntime?.backend == .privilegedDaemon
            || privilegedHealth?.processRunning == true
        await client.invalidate()
        for attempt in 0..<6 {
            await manager.refresh()
            guard manager.isReady,
                let sessionID = manager.lastHandshake?.sessionID
            else {
                if !requiresAuthoritativeStopProof {
                    switch manager.registrationStatus {
                    case .notRegistered, .requiresApproval, .notFound:
                        privilegedOperationOutcomeUnknown = false
                        return true
                    case .enabled, .unknown:
                        break
                    }
                }
                if attempt < 5 {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                continue
            }

            do {
                let status = try await client.status()
                privilegedHealth = status.health
                if Self.isCleanlyStopped(status) {
                    if let candidate = preparedPrivilegedCandidate,
                        let privilegedBackend
                    {
                        await privilegedBackend.abortStart(candidate)
                        preparedPrivilegedCandidate = nil
                    }
                    _ = try? await privilegedBackend?.status()
                    privilegedOperationOutcomeUnknown = false
                    return true
                }

                if status.health.processRunning
                    || status.state != .stopped
                    || status.instanceID != nil
                {
                    guard let instanceID = status.instanceID else { return false }
                    try await client.stop(StopHelperRequest(
                        sessionID: sessionID,
                        instanceID: instanceID,
                        reason: .recovery
                    ))
                }
            } catch {
                if !Self.isIndeterminatePrivilegedRPCFailure(error) {
                    return false
                }
            }

            if attempt < 5 {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return false
    }

    private nonisolated static func isCleanlyStopped(
        _ status: HelperStatusResponse
    ) -> Bool {
        status.state == .stopped
            && status.processID == nil
            && status.instanceID == nil
            && !status.health.processRunning
            && !status.health.tunInterfacePresent
            && !status.health.routeApplied
            && status.health.tunInterface == nil
    }

    private nonisolated static func isIndeterminatePrivilegedRPCFailure(
        _ error: Error
    ) -> Bool {
        if error is CancellationError { return true }
        guard let failure = error as? VelaHelperFailure else { return false }
        return failure.code == .requestTimedOut || failure.code == .helperUnavailable
    }

    private func privilegedEngineHealth() -> EngineHealth {
        guard let privilegedHealth else {
            return .sprintTwo(
                processRunning: activeRuntime != nil,
                controllerReachable: controllerState == .connected,
                configurationValid: activeRuntime != nil,
                systemProxyApplied: false
            )
        }
        let healthy = privilegedHealthIsReady(privilegedHealth)
        return EngineHealth(
            processRunning: privilegedHealth.processRunning,
            controllerReachable: privilegedHealth.controllerReachable,
            configurationValid: privilegedHealth.configurationHashMatches
                && privilegedHealth.tunEnabledInController,
            systemProxyApplied: false,
            networkReachable: networkPathSnapshot.networkReachable,
            internetReachable: privilegedHealth.routeApplied,
            portsListening: privilegedHealth.controllerReachable,
            lastCheckedAt: privilegedHealth.lastCheckedAt,
            overallState: healthy ? .healthy : .degraded
        )
    }

    private func privilegedHealthIsReady(_ health: PrivilegedRuntimeHealth) -> Bool {
        health.helperReachable
            && health.helperVersionCompatible
            && health.processRunning
            && health.controllerReachable
            && health.configurationHashMatches
            && health.tunEnabledInController
            && health.tunInterfacePresent
            && health.routeApplied
            && (!tunSettings.dnsHijack || health.dnsReady)
            && health.ownerLeaseValid
    }

    nonisolated static func privilegedResources(
        configuration: Data,
        configurationURL: URL,
        mihomoDataDirectoryURL: URL
    ) throws -> [PrivilegedResourceInput] {
        guard let yaml = String(data: configuration, encoding: .utf8) else {
            throw EngineStoreTunError.configurationIsNotUTF8
        }
        let document = try YAMLDocument(yaml: yaml)
        var resources: [PrivilegedResourceInput] = []
        var logicalIDs = Set<String>()
        try appendPrivilegedResources(
            from: document,
            groupKey: "proxy-providers",
            kind: .proxyProvider,
            configurationURL: configurationURL,
            mihomoDataDirectoryURL: mihomoDataDirectoryURL,
            logicalIDs: &logicalIDs,
            resources: &resources
        )
        try appendPrivilegedResources(
            from: document,
            groupKey: "rule-providers",
            kind: .ruleProvider,
            configurationURL: configurationURL,
            mihomoDataDirectoryURL: mihomoDataDirectoryURL,
            logicalIDs: &logicalIDs,
            resources: &resources
        )
        return resources
    }

    nonisolated private static func appendPrivilegedResources(
        from document: YAMLDocument,
        groupKey: String,
        kind: PrivilegedResourceKind,
        configurationURL: URL,
        mihomoDataDirectoryURL: URL,
        logicalIDs: inout Set<String>,
        resources: inout [PrivilegedResourceInput]
    ) throws {
        guard let value = try document.value(at: [groupKey]) else { return }
        guard case let .mapping(providers) = value else {
            throw EngineStoreTunError.invalidProviderConfiguration(groupKey)
        }
        for (name, value) in providers.sorted(by: { $0.key < $1.key }) {
            guard case let .mapping(provider) = value else {
                throw EngineStoreTunError.invalidProviderConfiguration(name)
            }
            guard provider["type"] == .string("file") else { continue }
            let logicalID = "\(kind.rawValue):\(name)"
            guard case let .string(path)? = provider["path"],
                logicalIDs.insert(logicalID).inserted
            else {
                throw EngineStoreTunError.invalidProviderConfiguration(name)
            }
            let sourceURL = try resolvePrivilegedResource(
                path: path,
                configurationURL: configurationURL,
                mihomoDataDirectoryURL: mihomoDataDirectoryURL
            )
            let values = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                let size = values.fileSize,
                size <= VelaIPCConstants.maximumResourceBytes
            else {
                throw EngineStoreTunError.unsafeProviderResource(name)
            }
            let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            let sha = Self.sha256(data)
            resources.append(PrivilegedResourceInput(
                descriptor: PrivilegedResourceDescriptor(
                    logicalID: logicalID,
                    relativeDestination: "providers/\(kind.rawValue)/\(sha).yaml",
                    expectedSize: data.count,
                    expectedSHA256: sha,
                    kind: kind
                ),
                sourceURL: sourceURL
            ))
        }
    }

    nonisolated private static func resolvePrivilegedResource(
        path: String,
        configurationURL: URL,
        mihomoDataDirectoryURL: URL
    ) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw EngineStoreTunError.unsafeProviderPath(path)
        }
        let roots = [configurationURL.deletingLastPathComponent(), mihomoDataDirectoryURL]
            .map(\.standardizedFileURL)
        for root in roots {
            let lexicalCandidate = root.appendingPathComponent(trimmed).standardizedFileURL
            guard Self.isStrictDescendant(lexicalCandidate, of: root),
                FileManager.default.fileExists(atPath: lexicalCandidate.path)
            else { continue }

            var cursor = root
            var containsSymlink = false
            for component in trimmed.split(separator: "/") {
                cursor.appendPathComponent(String(component))
                if try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    containsSymlink = true
                    break
                }
            }
            guard !containsSymlink else {
                throw EngineStoreTunError.unsafeProviderPath(path)
            }

            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let resolvedCandidate = lexicalCandidate.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isStrictDescendant(resolvedCandidate, of: resolvedRoot) else {
                throw EngineStoreTunError.unsafeProviderPath(path)
            }
            return resolvedCandidate
        }
        throw EngineStoreTunError.providerResourceMissing(path)
    }

    private nonisolated static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath != rootPath && candidatePath.hasPrefix(rootPath + "/")
    }

    private func bindController(to runtime: EngineRuntime) async throws {
        _ = try await controllerRouter?.bind(
            instanceID: runtime.instanceID,
            backend: runtime.backend,
            endpoint: runtime.controller.endpoint,
            secret: runtime.controller.secret
        )
    }

    private func unbindActiveController() async {
        guard let activeRuntime else { return }
        await controllerRouter?.unbind(instanceID: activeRuntime.instanceID)
    }

    private func userControllerEndpoint() throws -> URL {
        guard let endpoint = URL(
            string: "http://\(runtimeParameters.externalController)"
        ) else {
            throw EngineStoreTunError.invalidControllerEndpoint
        }
        return endpoint
    }

    private func configurationSHA256(for url: URL) async -> String {
        if let validatedConfigurationFingerprint,
            validatedConfigurationFingerprint.url == url.standardizedFileURL
        {
            return validatedConfigurationFingerprint.sha256
        }

        if let runtimeConfigurationInspector,
            let fingerprint = try? await runtimeConfigurationInspector.fingerprint(at: url)
        {
            return fingerprint.sha256
        }

        let fileDigest = await Task.detached(priority: .userInitiated) {
            try? Self.sha256(Data(contentsOf: url, options: [.mappedIfSafe]))
        }.value
        if let fileDigest {
            return fileDigest
        }
        // Test doubles may model a validated launch without materializing a file.
        // Production launches always have a runtime file and are fingerprinted off MainActor.
        return Self.sha256(Data(url.standardizedFileURL.path.utf8))
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func persistTunPreferences() {
        tunPreferenceStore.save(TunPreferences(
            settings: tunSettings,
            restoreSystemProxyAfterTun: restoreSystemProxyAfterTun
        ))
    }

    private func effectiveTunSettings() throws -> TunSettings {
        var settings = try tunSettings.validated()
        let exclusions = try currentEffectiveTunRouteExclusions(for: settings)
        settings.routeExcludeCIDRs = exclusions
        effectiveTunRouteExclusions = exclusions
        return try settings.validated()
    }

    private func currentEffectiveTunRouteExclusions(
        for settings: TunSettings
    ) throws -> [String] {
        var exclusions = Set(settings.routeExcludeCIDRs)
        if settings.allowLocalNetwork {
            let context = try localNetworkContextProvider.currentContext()
            exclusions.formUnion(context.routeExclusions)
        }
        var normalized = settings
        normalized.routeExcludeCIDRs = Array(exclusions)
        return try normalized.validated().routeExcludeCIDRs
    }

    private func schedulePrivilegedNetworkChangeRecovery() {
        guard isTunActive,
            !isSleeping,
            !isPreparingForTermination,
            !isPrivilegedWakeRecoveryInProgress,
            leaseRecoveryTask == nil
        else { return }

        // A burst of path callbacks is one recovery cycle. Once a cycle has
        // crossed the debounce boundary and begun a bounded status/restart
        // operation, later callbacks are coalesced into that same fresh check
        // rather than creating a second restart attempt.
        guard !isNetworkChangeRecoveryInProgress else { return }
        networkChangeRecoveryTask?.cancel()
        cancelLocalNetworkRecovery()

        let token = UUID()
        networkChangeRecoveryTaskID = token
        let delay = networkChangeRecoveryDebounce
        let sleep = networkChangeSleep
        networkChangeRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                self?.finishPrivilegedNetworkChangeRecovery(token: token)
                return
            }

            guard let self,
                self.networkChangeRecoveryTaskID == token,
                self.isTunActive,
                self.networkPathSnapshot.networkReachable,
                !self.isSleeping,
                !self.isPreparingForTermination,
                !self.isPrivilegedWakeRecoveryInProgress,
                self.leaseRecoveryTask == nil
            else {
                self?.finishPrivilegedNetworkChangeRecovery(token: token)
                return
            }

            self.isNetworkChangeRecoveryInProgress = true
            await self.performPrivilegedNetworkChangeRecovery(token: token)
            self.finishPrivilegedNetworkChangeRecovery(token: token)
        }
    }

    private func cancelPrivilegedNetworkChangeRecovery() {
        let task = takePrivilegedNetworkChangeRecoveryTask()
        task?.cancel()
    }

    private func cancelAndWaitForPrivilegedNetworkChangeRecovery() async {
        let task = takePrivilegedNetworkChangeRecoveryTask()
        task?.cancel()
        if let task {
            await task.value
        }
    }

    private func takePrivilegedNetworkChangeRecoveryTask() -> Task<Void, Never>? {
        networkChangeRecoveryTaskID = nil
        isNetworkChangeRecoveryInProgress = false
        let task = networkChangeRecoveryTask
        networkChangeRecoveryTask = nil
        return task
    }

    private func finishPrivilegedNetworkChangeRecovery(token: UUID) {
        guard networkChangeRecoveryTaskID == token else { return }
        networkChangeRecoveryTaskID = nil
        networkChangeRecoveryTask = nil
        isNetworkChangeRecoveryInProgress = false
    }

    private func performPrivilegedNetworkChangeRecovery(token: UUID) async {
        guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else { return }
        guard networkChangeRecoveryTaskID == token,
            isTunActive,
            !isSleeping,
            !isPreparingForTermination,
            !isPrivilegedWakeRecoveryInProgress,
            leaseRecoveryTask == nil
        else {
            await runtimeMutationGate.release(lease)
            return
        }

        await performPrivilegedNetworkChangeRecoveryWithLease(token: token)
        await runtimeMutationGate.release(lease)
    }

    private func performPrivilegedNetworkChangeRecoveryWithLease(token: UUID) async {
        guard let client = privilegedHelperClient else { return }

        var routeRestartAttempted = false
        if tunSettings.allowLocalNetwork {
            do {
                let exclusions = try currentEffectiveTunRouteExclusions(for: tunSettings)
                if exclusions != effectiveTunRouteExclusions {
                    routeRestartAttempted = true
                    await restartTunForRouteExclusions(exclusions)
                    guard networkChangeRecoveryTaskID == token, isTunActive else { return }
                }
            } catch {
                presentTransitionFailure(
                    title: "Local Network Detection Failed",
                    error: error,
                    fallback: "TUN was left unchanged; retry after the network becomes stable."
                )
                return
            }
        }

        do {
            let status = try await client.status()
            guard networkChangeRecoveryTaskID == token, !Task.isCancelled else { return }
            privilegedHealth = status.health
            if privilegedHealthIsReady(status.health) {
                privilegedOperationOutcomeUnknown = false
                state = .running(privilegedEngineHealth())
                return
            }

            // A route-exclusion refresh already consumed this cycle's single
            // controlled restart opportunity. Never stack another restart on
            // the same path callback burst.
            guard !routeRestartAttempted else {
                await markPrivilegedNetworkChangeRecoveryDegraded(
                    "TUN remained unhealthy after refreshing local route exclusions.",
                    statusWasFresh: true
                )
                return
            }

            guard tunSettings.autoDetectInterface else {
                await markPrivilegedNetworkChangeRecoveryDegraded(
                    "The fixed outbound interface is not healthy after the network path changed. Switch TUN Interface to Auto and retry.",
                    statusWasFresh: true
                )
                return
            }

            // One debounced path-recovery cycle gets at most one restart.
            guard await performPrivilegedRestart() else { return }
            guard networkChangeRecoveryTaskID == token, isTunActive else { return }

            let confirmation = try await client.status()
            guard networkChangeRecoveryTaskID == token, !Task.isCancelled else { return }
            privilegedHealth = confirmation.health
            guard privilegedHealthIsReady(confirmation.health) else {
                await markPrivilegedNetworkChangeRecoveryDegraded(
                    "TUN remained unhealthy after the single network-change restart attempt.",
                    statusWasFresh: true
                )
                return
            }
            privilegedOperationOutcomeUnknown = false
            state = .running(privilegedEngineHealth())
        } catch {
            guard !Task.isCancelled, networkChangeRecoveryTaskID == token else { return }
            await markPrivilegedNetworkChangeRecoveryDegraded(
                error.localizedDescription,
                statusWasFresh: false
            )
        }
    }

    private func markPrivilegedNetworkChangeRecoveryDegraded(
        _ reason: String,
        statusWasFresh: Bool
    ) async {
        guard activeBackendKind == .privilegedDaemon else { return }
        let health = privilegedEngineHealth()
        if !statusWasFresh {
            privilegedOperationOutcomeUnknown = true
            state = .recovering
        } else if activeRuntime != nil, health.processRunning {
            state = .running(EngineHealth(
                processRunning: true,
                controllerReachable: health.controllerReachable,
                configurationValid: health.configurationValid,
                systemProxyApplied: false,
                networkReachable: networkPathSnapshot.networkReachable,
                internetReachable: health.internetReachable,
                portsListening: health.portsListening,
                lastCheckedAt: now(),
                overallState: .degraded
            ))
        } else if health.processRunning {
            privilegedOperationOutcomeUnknown = true
            state = .recovering
        } else {
            await privilegedLeaseCoordinator?.stop()
            if let runtime = activeRuntime {
                await controllerRouter?.unbind(instanceID: runtime.instanceID)
            }
            activeRuntime = nil
            activeBackendKind = .userProcess
            wantsEngineRunning = false
            resetControllerRuntimeState()
            state = .failed(.healthCheckFailed(reason))
        }
        lastError = UserFacingError(
            title: "TUN Network Recovery Is Degraded",
            message: "Vela could not verify a healthy TUN path after the network changed.",
            technicalDetails: DiagnosticTextSanitizer.redact(reason),
            suggestedAction: tunSettings.autoDetectInterface
                ? "Wait for the network to stabilize, then refresh TUN health from Diagnostics."
                : "Switch TUN Interface to Auto, then retry after the network stabilizes.",
            isRetryable: true,
            recoveryActions: [.openDiagnostics]
        )
    }

    private func scheduleLocalNetworkRecoveryIfNeeded() {
        guard isTunActive,
            tunSettings.allowLocalNetwork,
            !isSleeping,
            !isPreparingForTermination
        else { return }
        cancelLocalNetworkRecovery()
        let token = UUID()
        localNetworkRecoveryTaskID = token
        let sleep = localNetworkRecoverySleep
        localNetworkRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await sleep(.milliseconds(1_500))
                guard let self,
                    self.localNetworkRecoveryTaskID == token,
                    self.isTunActive,
                    !self.isSleeping,
                    !self.isPreparingForTermination,
                    !self.isPrivilegedWakeRecoveryInProgress
                else {
                    self?.finishLocalNetworkRecovery(token: token)
                    return
                }
                let next = try self.currentEffectiveTunRouteExclusions(
                    for: self.tunSettings
                )
                guard next != self.effectiveTunRouteExclusions else {
                    self.finishLocalNetworkRecovery(token: token)
                    return
                }
                guard let lease = await self.acquireRuntimeMutationLease(.engineLifecycle) else {
                    self.finishLocalNetworkRecovery(token: token)
                    return
                }
                guard self.localNetworkRecoveryTaskID == token,
                    !Task.isCancelled,
                    self.isTunActive,
                    !self.isSleeping,
                    !self.isPreparingForTermination,
                    !self.isPrivilegedWakeRecoveryInProgress
                else {
                    await self.runtimeMutationGate.release(lease)
                    self.finishLocalNetworkRecovery(token: token)
                    return
                }
                await self.restartTunForRouteExclusions(next)
                await self.runtimeMutationGate.release(lease)
                self.finishLocalNetworkRecovery(token: token)
            } catch is CancellationError {
                self?.finishLocalNetworkRecovery(token: token)
                return
            } catch {
                guard let self,
                    self.localNetworkRecoveryTaskID == token,
                    !self.isSleeping,
                    !self.isPreparingForTermination
                else { return }
                self.finishLocalNetworkRecovery(token: token)
                self.presentTransitionFailure(
                    title: "Local Network Detection Failed",
                    error: error,
                    fallback: "TUN was left unchanged; retry after the network becomes stable."
                )
            }
        }
    }

    private func cancelLocalNetworkRecovery() {
        let task = takeLocalNetworkRecoveryTask()
        task?.cancel()
    }

    private func cancelAndWaitForLocalNetworkRecovery() async {
        let task = takeLocalNetworkRecoveryTask()
        task?.cancel()
        if let task { await task.value }
    }

    private func takeLocalNetworkRecoveryTask() -> Task<Void, Never>? {
        localNetworkRecoveryTaskID = nil
        let task = localNetworkRecoveryTask
        localNetworkRecoveryTask = nil
        return task
    }

    private func finishLocalNetworkRecovery(token: UUID) {
        guard localNetworkRecoveryTaskID == token else { return }
        localNetworkRecoveryTaskID = nil
        localNetworkRecoveryTask = nil
    }

    private func scheduleLeaseRecovery() {
        guard isTunActive,
            !isSleeping,
            !isPreparingForTermination,
            !isPrivilegedWakeRecoveryInProgress,
            !leaseRecoveryAttempted,
            leaseRecoveryTask == nil
        else { return }
        leaseRecoveryAttempted = true
        let token = UUID()
        leaseRecoveryTaskID = token
        leaseRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.leaseRecoveryTaskID == token,
                !self.isSleeping,
                !self.isPreparingForTermination,
                !self.isPrivilegedWakeRecoveryInProgress
            else {
                self.finishLeaseRecovery(token: token)
                return
            }
            guard let lease = await self.acquireRuntimeMutationLease(.engineLifecycle) else {
                self.finishLeaseRecovery(token: token)
                return
            }
            guard self.leaseRecoveryTaskID == token,
                !Task.isCancelled,
                self.isTunActive,
                !self.isSleeping,
                !self.isPreparingForTermination,
                !self.isPrivilegedWakeRecoveryInProgress
            else {
                await self.runtimeMutationGate.release(lease)
                self.finishLeaseRecovery(token: token)
                return
            }
            await self.privilegedComponentManager?.refresh()
            if self.leaseRecoveryTaskID == token,
                !Task.isCancelled,
                self.isTunActive,
                !self.isSleeping,
                !self.isPreparingForTermination,
                !self.isPrivilegedWakeRecoveryInProgress,
                self.privilegedComponentIsReady
            {
                await self.privilegedLeaseCoordinator?.resumeAfterSystemWake()
                await self.refreshPrivilegedHealth(presentErrors: false)
            }
            await self.runtimeMutationGate.release(lease)
            self.finishLeaseRecovery(token: token)
        }
    }

    private func cancelAndWaitForLeaseRecovery() async {
        let task = takeLeaseRecoveryTask()
        task?.cancel()
        if let task { await task.value }
        leaseRecoveryAttempted = false
    }

    private func takeLeaseRecoveryTask() -> Task<Void, Never>? {
        leaseRecoveryTaskID = nil
        let task = leaseRecoveryTask
        leaseRecoveryTask = nil
        return task
    }

    private func finishLeaseRecovery(token: UUID) {
        guard leaseRecoveryTaskID == token else { return }
        leaseRecoveryTaskID = nil
        leaseRecoveryTask = nil
    }

    private func beginPrivilegedWakeRecovery() async {
        cancelPrivilegedNetworkChangeRecovery()
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        let token = UUID()
        wakeRecoveryTaskID = token
        isPrivilegedWakeRecoveryInProgress = true

        // Resume first so the Helper receives its post-wake lease grace before
        // App-side network stabilization and health checks begin.
        await privilegedLeaseCoordinator?.resumeAfterSystemWake()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPrivilegedWakeRecovery()
            self.finishPrivilegedWakeRecovery(token: token)
        }
        wakeRecoveryTask = task
    }

    private func finishPrivilegedWakeRecovery(token: UUID) {
        guard wakeRecoveryTaskID == token else { return }
        wakeRecoveryTask = nil
        wakeRecoveryTaskID = nil
        isPrivilegedWakeRecoveryInProgress = false
    }

    private func performPrivilegedWakeRecovery() async {
        guard isTunActive, !isSleeping, !isPreparingForTermination else { return }

        do {
            guard try await waitForReachableNetworkAfterWake() else {
                await markPrivilegedWakeRecoveryDegraded(
                    "The network path did not become available before the wake recovery window closed."
                )
                return
            }
        } catch is CancellationError {
            return
        } catch {
            await markPrivilegedWakeRecoveryDegraded(error.localizedDescription)
            return
        }

        guard isTunActive, !isSleeping, !isPreparingForTermination else { return }
        guard let lease = await acquireRuntimeMutationLease(.engineLifecycle) else {
            await markPrivilegedWakeRecoveryDegraded(
                "Wake recovery could not acquire the runtime mutation barrier."
            )
            return
        }

        await performPrivilegedWakeRecoveryWithLease()
        await runtimeMutationGate.release(lease)
    }

    private func performPrivilegedWakeRecoveryWithLease() async {
        guard let manager = privilegedComponentManager,
            let client = privilegedHelperClient
        else {
            await markPrivilegedWakeRecoveryDegraded(
                "The privileged component is unavailable after wake."
            )
            return
        }

        await manager.invalidateConnection()
        await manager.refresh()
        guard manager.isReady,
            let sessionID = manager.lastHandshake?.sessionID
        else {
            await markPrivilegedWakeRecoveryDegraded(
                "Vela could not complete the App/Helper handshake after wake."
            )
            return
        }
        updatePrivilegedStartMaterialSession(sessionID)

        do {
            let status = try await client.status()
            privilegedHealth = status.health
            if privilegedHealthIsReady(status.health) {
                state = .running(privilegedEngineHealth())
                scheduleLocalNetworkRecoveryIfNeeded()
                return
            }

            guard tunSettings.autoDetectInterface else {
                await markPrivilegedWakeRecoveryDegraded(
                    "The fixed outbound interface is not healthy after wake. Switch TUN Interface to Auto and retry."
                )
                return
            }

            // One wake event gets at most one controlled restart attempt.
            guard await performPrivilegedRestart() else { return }
            guard isTunActive else { return }

            let confirmation = try await client.status()
            privilegedHealth = confirmation.health
            guard privilegedHealthIsReady(confirmation.health) else {
                await markPrivilegedWakeRecoveryDegraded(
                    "TUN remained unhealthy after the single wake restart attempt."
                )
                return
            }
            state = .running(privilegedEngineHealth())
            scheduleLocalNetworkRecoveryIfNeeded()
        } catch {
            await markPrivilegedWakeRecoveryDegraded(error.localizedDescription)
        }
    }

    private func waitForReachableNetworkAfterWake() async throws -> Bool {
        if networkPathSnapshot.networkReachable { return true }

        let interval = max(0.001, wakePathPollInterval.timeInterval)
        let timeout = max(interval, wakePathWaitTimeout.timeInterval)
        let checks = max(1, Int(ceil(timeout / interval)))
        for index in 0..<checks {
            try Task.checkCancellation()
            if networkPathSnapshot.networkReachable { return true }
            if index + 1 < checks {
                try await wakeSleep(wakePathPollInterval)
            }
        }
        return networkPathSnapshot.networkReachable
    }

    private func updatePrivilegedStartMaterialSession(_ sessionID: UUID) {
        guard let material = lastPrivilegedStartMaterial,
            material.sessionID != sessionID
        else { return }
        lastPrivilegedStartMaterial = PrivilegedEngineStartMaterial(
            sessionID: sessionID,
            configuration: material.configuration,
            configurationSHA256: material.configurationSHA256,
            resources: material.resources,
            tunSettings: material.tunSettings
        )
    }

    private func markPrivilegedWakeRecoveryDegraded(_ reason: String) async {
        guard activeBackendKind == .privilegedDaemon else { return }
        let health = privilegedEngineHealth()
        if activeRuntime != nil, health.processRunning {
            state = .running(EngineHealth(
                processRunning: true,
                controllerReachable: health.controllerReachable,
                configurationValid: health.configurationValid,
                systemProxyApplied: false,
                networkReachable: networkPathSnapshot.networkReachable,
                internetReachable: health.internetReachable,
                portsListening: health.portsListening,
                lastCheckedAt: now(),
                overallState: .degraded
            ))
        } else if health.processRunning {
            privilegedOperationOutcomeUnknown = true
            state = .recovering
        } else {
            await privilegedLeaseCoordinator?.stop()
            if let runtime = activeRuntime {
                await controllerRouter?.unbind(instanceID: runtime.instanceID)
            }
            activeRuntime = nil
            activeBackendKind = .userProcess
            wantsEngineRunning = false
            resetControllerRuntimeState()
            state = .failed(.healthCheckFailed(reason))
        }
        lastError = UserFacingError(
            title: "TUN Wake Recovery Is Degraded",
            message: "Vela kept the current TUN runtime but could not verify a healthy post-wake path.",
            technicalDetails: DiagnosticTextSanitizer.redact(reason),
            suggestedAction: tunSettings.autoDetectInterface
                ? "Reconnect the network, then refresh TUN health from Diagnostics."
                : "Switch TUN Interface to Auto, reconnect the network, and retry.",
            isRetryable: true,
            recoveryActions: [.openDiagnostics]
        )
    }

    private func restartTunForRouteExclusions(_ exclusions: [String]) async {
        guard let privilegedBackend, let previous = lastPrivilegedStartMaterial else { return }
        var updatedSettings = previous.tunSettings
        updatedSettings.routeExcludeCIDRs = exclusions
        let updated = PrivilegedEngineStartMaterial(
            sessionID: previous.sessionID,
            configuration: previous.configuration,
            configurationSHA256: previous.configurationSHA256,
            resources: previous.resources,
            tunSettings: updatedSettings
        )
        let coreID = await currentCoreID()

        do {
            // Route refresh is operational, not an authorization to replace a
            // blocked Core. Check before the destructive stop, then let the
            // Helper re-check at prepareStart.
            try await tunCorePolicyGate?(coreID)
            state = .recovering
            try await stopPrivilegedRuntime(using: privilegedBackend, reason: .recovery)
            let candidate = try await preparePrivilegedStart(
                using: privilegedBackend,
                EngineStartRequest(
                    backend: .privilegedDaemon,
                    coreID: coreID,
                    material: updated
                )
            )
            preparedPrivilegedCandidate = candidate
            lastPrivilegedStartMaterial = updated
            try await startPreparedPrivilegedTarget(using: privilegedBackend)
            try await verifyPrivilegedTarget()
            preparedPrivilegedCandidate = nil
            effectiveTunRouteExclusions = exclusions
        } catch {
            do {
                if let candidate = preparedPrivilegedCandidate {
                    await privilegedBackend.abortStart(candidate)
                    preparedPrivilegedCandidate = nil
                }
                let rollback = try await preparePrivilegedStart(
                    using: privilegedBackend,
                    EngineStartRequest(
                        backend: .privilegedDaemon,
                        coreID: coreID,
                        material: previous
                    )
                )
                preparedPrivilegedCandidate = rollback
                lastPrivilegedStartMaterial = previous
                try await startPreparedPrivilegedTarget(using: privilegedBackend)
                try await verifyPrivilegedTarget()
                preparedPrivilegedCandidate = nil
            } catch {
                state = .failed(.healthCheckFailed(error.localizedDescription))
            }
            presentTransitionFailure(
                title: "TUN Network Refresh Failed",
                error: error,
                fallback: "Vela attempted one rollback to the previous route exclusions."
            )
        }
    }

    private func presentPrivilegedComponentNotReady() {
        lastError = UserFacingError(
            title: "Privileged Component Is Not Ready",
            message: "Install or approve the Vela privileged component before enabling TUN.",
            suggestedAction: "Open Settings, review Privileged Component, then verify it again.",
            isRetryable: true
        )
    }

    private func presentTransitionFailure(
        title: String,
        error: Error,
        fallback: String
    ) {
        lastError = UserFacingError(
            title: title,
            message: error.localizedDescription,
            technicalDetails: DiagnosticTextSanitizer.redact(error.localizedDescription),
            suggestedAction: fallback,
            isRetryable: true,
            recoveryActions: [.openDiagnostics]
        )
    }

    private func prepareValidatedLaunch(
        operationGeneration: UInt64,
        allowsCachedValidation: Bool = true
    ) async throws -> ValidatedLaunch {
        guard let selectedProfileID else {
            throw EngineStoreOperationError.profileNotSelected
        }

        let layers = try await configurationLayerStore?.layers(
            profileID: selectedProfileID,
            sceneID: activeConfigurationSceneID
        ) ?? []
        let compilationContext = ConfigurationCompilationContext(
            profileID: selectedProfileID,
            profileRevisionID: selectedProfile?.currentRevisionID,
            layers: layers,
            backend: ConfigurationBackendContext(
                backend: pendingConfigurationBackend ?? activeBackendKind
            )
        )
        let configurationURL = try await profileStore.buildRuntimeConfiguration(
            for: selectedProfileID,
            parameters: runtimeParameters,
            using: runtimeConfigBuilder,
            context: compilationContext
        )
        try ensureCurrentEngineOperation(operationGeneration)
        corePreflightResult = nil
        coreLifecycleIntegrityVerified = false
        corePreflightError = nil

        let executable: ResolvedMihomoExecutable
        do {
            executable = try await executableResolver.resolve()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            corePreflightError = error.localizedDescription
            throw error
        }
        try ensureCurrentEngineOperation(operationGeneration)
        corePreflightResult = executable.preflight
        coreLifecycleIntegrityVerified = executable.hasVerifiedIntegritySnapshot
        corePreflightError = executable.hasVerifiedIntegritySnapshot
            ? nil
            : "The resolver did not return a verified Core integrity snapshot."

        if allowsCachedValidation,
            let cached = await runtimeValidationCache.cachedValidation(
                configurationURL: configurationURL,
                dataDirectoryURL: mihomoDataDirectoryURL,
                executable: executable
            )
        {
            try ensureCurrentEngineOperation(operationGeneration)
            let result = ConfigurationValidationResult(
                status: .valid,
                stdout: "",
                stderr: "",
                issues: [],
                duration: .zero
            )
            validationResult = result
            resolvedExecutable = executable
            validatedConfigurationFingerprint = cached.configurationFingerprint
            return ValidatedLaunch(
                configurationURL: configurationURL,
                executable: executable,
                validationResult: result
            )
        }

        let validator = configurationValidator
        let dataDirectoryURL = mihomoDataDirectoryURL
        let validationTaskID = UUID()
        let validationTask = Task {
            await validator.validate(
                configurationURL: configurationURL,
                dataDirectoryURL: dataDirectoryURL,
                using: executable,
                timeout: .seconds(10)
            )
        }
        activeValidationTask = validationTask
        activeValidationTaskID = validationTaskID
        defer {
            if activeValidationTaskID == validationTaskID {
                activeValidationTask = nil
                activeValidationTaskID = nil
            }
        }
        let result = await validationTask.value
        try ensureCurrentEngineOperation(operationGeneration)

        validationResult = result
        resolvedExecutable = executable
        if case let .coreIntegrityFailed(message) = result.status {
            corePreflightResult = nil
            coreLifecycleIntegrityVerified = false
            corePreflightError = message
        }
        guard result.isValid else {
            validatedConfigurationFingerprint = nil
            throw EngineStoreOperationError.configurationInvalid(result)
        }

        if let runtimeConfigurationInspector {
            validatedConfigurationFingerprint = try await runtimeConfigurationInspector.fingerprint(
                at: configurationURL
            )
            try ensureCurrentEngineOperation(operationGeneration)
        } else {
            validatedConfigurationFingerprint = nil
        }

        await runtimeValidationCache.recordSuccessfulValidation(
            configurationURL: configurationURL,
            dataDirectoryURL: mihomoDataDirectoryURL,
            executable: executable
        )
        try ensureCurrentEngineOperation(operationGeneration)

        return ValidatedLaunch(
            configurationURL: configurationURL,
            executable: executable,
            validationResult: result
        )
    }

    private func beginObservingProcessEventsIfNeeded() async {
        guard processEventTask == nil else { return }
        let stream = await processManager.events()
        processEventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.handleProcessEvent(event)
            }
        }
    }

    private func beginObservingControllerEventsIfNeeded() async {
        guard controllerEventTask == nil, let controllerManager else { return }
        let stream = await controllerManager.events()
        controllerEventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.handleControllerEvent(event)
            }
        }
    }

    private func beginObservingHealthReportsIfNeeded() async {
        guard healthReportTask == nil, let healthMonitor else { return }
        let stream = await healthMonitor.events()
        healthReportTask = Task { @MainActor [weak self] in
            for await report in stream {
                guard !Task.isCancelled else { break }
                await self?.handleHealthReport(report)
            }
        }
    }

    private func beginObservingNetworkPathIfNeeded() async {
        guard networkPathTask == nil, let networkPathObserver else { return }
        let stream = await networkPathObserver.events()
        networkPathTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                await self?.handleNetworkPath(snapshot)
            }
        }
    }

    private func beginObservingSleepWakeEventsIfNeeded() async {
        guard sleepWakeTask == nil, let sleepWakeObserver else { return }
        let stream = await sleepWakeObserver.events()
        sleepWakeTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.handleSleepWakeEvent(event)
            }
        }
    }

    private func beginObservingTransitionEventsIfNeeded() async {
        guard transitionEventTask == nil, let transitionCoordinator else { return }
        let stream = await transitionCoordinator.events()
        transitionEventTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                self?.transitionSnapshot = snapshot
                self?.transitionState = snapshot.state
            }
        }
    }

    private func beginObservingLeaseEventsIfNeeded() async {
        guard leaseEventTask == nil, let privilegedLeaseCoordinator else { return }
        let stream = await privilegedLeaseCoordinator.events()
        leaseEventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                switch event {
                case .started:
                    self?.lastLeaseErrorCode = nil
                    self?.leaseRecoveryAttempted = false
                case let .renewed(date):
                    self?.lastLeaseRenewalAt = date
                    self?.lastLeaseErrorCode = nil
                    self?.leaseRecoveryAttempted = false
                case let .renewalFailed(code):
                    self?.lastLeaseErrorCode = code
                    if code == .invalidSession || code == .helperUnavailable {
                        self?.scheduleLeaseRecovery()
                    }
                case .suspendedForSleep, .resumedAfterWake, .stopped:
                    break
                }
            }
        }
    }

    private func handleNetworkPath(_ snapshot: NetworkPathSnapshot) async {
        let previous = networkPathSnapshot
        networkPathSnapshot = snapshot
        if previous != snapshot {
            emitLifecycleEvent(
                .networkAvailabilityChanged(snapshot.networkReachable)
            )
        }
        await synchronizeHealthContext()

        if activeBackendKind == .privilegedDaemon, snapshot != previous {
            if snapshot.networkReachable,
                !isSleeping,
                !isPrivilegedWakeRecoveryInProgress
            {
                schedulePrivilegedNetworkChangeRecovery()
            } else {
                cancelPrivilegedNetworkChangeRecovery()
            }
        }

        guard healthSessionID != nil else { return }
        guard snapshot != .unknown || previous != .unknown else { return }
        await healthMonitor?.trigger(.networkChanged)
    }

    private func handleSleepWakeEvent(_ event: SleepWakeEvent) async {
        switch event {
        case .willSleep:
            isSleeping = true
            // Any of the three recovery workers may already be holding or
            // waiting for the runtime gate. Cancel and join all of them before
            // suspending the Helper lease so no task can restart root Mihomo or
            // resume lease renewal after `willSleep` has been observed.
            await cancelAndWaitForPrivilegedNetworkChangeRecovery()
            await cancelAndWaitForLocalNetworkRecovery()
            await cancelAndWaitForLeaseRecovery()
            wakeRecoveryTask?.cancel()
            wakeRecoveryTask = nil
            wakeRecoveryTaskID = nil
            isPrivilegedWakeRecoveryInProgress = false
            emitLifecycleEvent(.willSleep)
            if activeBackendKind == .privilegedDaemon {
                await privilegedLeaseCoordinator?.suspendForSystemSleep()
            }
            await healthMonitor?.setApplicationActive(false)
        case .didWake:
            isSleeping = false
            emitLifecycleEvent(.didWake)
            if activeBackendKind == .privilegedDaemon {
                await beginPrivilegedWakeRecovery()
            }
            await healthMonitor?.resumeAfterWake(
                applicationActive: isApplicationActive
            )
        }
    }

    private func emitLifecycleEvent(_ event: EngineLifecycleEvent) {
        for continuation in lifecycleContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeLifecycleContinuation(id: UUID) {
        lifecycleContinuations.removeValue(forKey: id)
    }

    private static func isRunningState(_ state: EngineState) -> Bool {
        if case .running = state { return true }
        return false
    }

    private func stopEnvironmentObservers() async {
        let networkTask = networkPathTask
        let sleepTask = sleepWakeTask
        let reportTask = healthReportTask
        let transitionTask = transitionEventTask
        let leaseTask = leaseEventTask
        let leaseRecoveryTask = leaseRecoveryTask
        let localNetworkRecoveryTask = localNetworkRecoveryTask
        let networkChangeRecoveryTask = networkChangeRecoveryTask
        let wakeRecoveryTask = wakeRecoveryTask
        networkPathTask = nil
        sleepWakeTask = nil
        healthReportTask = nil
        transitionEventTask = nil
        leaseEventTask = nil
        self.leaseRecoveryTask = nil
        leaseRecoveryTaskID = nil
        self.localNetworkRecoveryTask = nil
        localNetworkRecoveryTaskID = nil
        self.networkChangeRecoveryTask = nil
        networkChangeRecoveryTaskID = nil
        isNetworkChangeRecoveryInProgress = false
        self.wakeRecoveryTask = nil
        wakeRecoveryTaskID = nil
        isPrivilegedWakeRecoveryInProgress = false

        networkTask?.cancel()
        sleepTask?.cancel()
        reportTask?.cancel()
        transitionTask?.cancel()
        leaseTask?.cancel()
        leaseRecoveryTask?.cancel()
        localNetworkRecoveryTask?.cancel()
        networkChangeRecoveryTask?.cancel()
        wakeRecoveryTask?.cancel()
        await networkPathObserver?.stop()
        await sleepWakeObserver?.stop()
        if let networkTask { await networkTask.value }
        if let sleepTask { await sleepTask.value }
        if let reportTask { await reportTask.value }
        if let transitionTask { await transitionTask.value }
        if let leaseTask { await leaseTask.value }
        if let leaseRecoveryTask { await leaseRecoveryTask.value }
        if let localNetworkRecoveryTask { await localNetworkRecoveryTask.value }
        if let networkChangeRecoveryTask { await networkChangeRecoveryTask.value }
        if let wakeRecoveryTask { await wakeRecoveryTask.value }
    }

    private func handleProcessEvent(_ event: MihomoProcessEvent) async {
        switch event {
        case let .started(snapshot):
            guard wantsEngineRunning else {
                _ = try? await processManager.stop(timeout: .seconds(3))
                return
            }
            managedProcessID = snapshot.pid
            guard activeBackendKind == .userProcess,
                activeRuntime?.backend == .userProcess
            else {
                return
            }
            updateRunningHealth(controllerReachable: false)
            await startControllerIfAvailable()
            await startHealthMonitoringIfNeeded()
        case let .output(output):
            await controllerManager?.appendProcessOutput(output)
        case let .terminated(termination):
            guard managedProcessID == termination.pid else { return }
            let systemProxyOperationWasInFlight = systemProxyOperation != nil
            invalidateHealthSession()
            engineOperationGeneration &+= 1
            let terminationGeneration = engineOperationGeneration
            managedProcessID = nil
            wantsEngineRunning = false
            pendingSystemProxyReapply = false
            if termination.expected {
                state = .stopping
            } else {
                state = .recovering
                systemProxyOperationGeneration &+= 1
                systemProxyOperation = nil
            }
            await healthMonitor?.stop()
            await controllerManager?.stop()
            await unbindActiveController()
            activeRuntime = nil
            guard isCurrentEngineOperation(
                terminationGeneration,
                wantsRunning: false
            ) else {
                return
            }
            resetControllerRuntimeState()
            if termination.expected {
                state = .stopped
            } else {
                await refreshSystemProxyStatus(presentErrors: false)
                guard isCurrentEngineOperation(
                    terminationGeneration,
                    wantsRunning: false
                ) else {
                    return
                }
                let visibleTargetServiceNames = visibleSystemProxyTargetServiceNames(
                    in: systemProxyStatus
                )
                fail(.unexpectedTermination(exitCode: termination.status))
                if systemProxyNeedsRestore {
                    presentUnexpectedTerminationRecoveryWarning(
                        exitCode: termination.status
                    )
                } else if !visibleTargetServiceNames.isEmpty {
                    presentUnexpectedTerminationVisibleSystemProxyWarning(
                        exitCode: termination.status,
                        serviceNames: visibleTargetServiceNames
                    )
                } else if systemProxyManager != nil,
                    systemProxyOperationWasInFlight
                        || systemProxyStatus.aggregate == .unavailable
                {
                    presentUnexpectedTerminationUnverifiedSystemProxyWarning(
                        exitCode: termination.status,
                        operationWasInFlight: systemProxyOperationWasInFlight
                    )
                }
            }
        }
    }

    private func handleControllerEvent(_ event: MihomoControllerEvent) async {
        switch event {
        case .connecting:
            controllerState = .connecting
            lastControllerError = nil
            controllerVersion = nil
            runtimeMode = nil
            trafficSample = nil
            resetProxyRuntimeState()
            updateRunningHealth(controllerReachable: false)
        case let .ready(snapshot):
            let wasConnected = controllerState == .connected
            controllerState = .connected
            controllerVersion = snapshot.version.version
            runtimeMode = snapshot.configs.mode
            lastControllerError = nil
            if !wasConnected {
                isLoadingProxies = true
            }
            updateRunningHealth(controllerReachable: true)
            if pendingSystemProxyReapply {
                pendingSystemProxyReapply = false
                await performSetSystemProxyEnabled(true)
            }
            await healthMonitor?.trigger(.manual)
        case let .proxiesUpdated(response):
            guard controllerState == .connected else { return }
            proxyCatalog = ProxyCatalog(response: response)
            proxyCatalogError = nil
            isLoadingProxies = false
            proxyDelayStates = [:]
        case let .proxyCatalogUpdated(catalog):
            guard controllerState == .connected else { return }
            proxyCatalog = catalog
            let messages = catalog.fetchErrors.map(\.localizedDescription)
            proxyCatalogError = messages.isEmpty ? nil : messages.joined(separator: "\n")
            isLoadingProxies = false
            proxyDelayStates = [:]
        case let .proxiesUnavailable(message):
            guard controllerState == .connected else { return }
            proxyCatalogError = message
            isLoadingProxies = false
        case let .logsUpdated(entries):
            logEntries = entries
        case let .trafficUpdated(sample):
            trafficSample = sample
        case let .unavailable(message):
            controllerState = .unavailable(message)
            lastControllerError = message
            controllerVersion = nil
            runtimeMode = nil
            trafficSample = nil
            resetProxyRuntimeState()
            updateRunningHealth(controllerReachable: false)
            await healthMonitor?.trigger(.manual)
            await attemptControllerRecovery(
                reason: "Controller session became unavailable."
            )
        case .disconnected:
            resetControllerRuntimeState()
            updateRunningHealth(controllerReachable: false)
        }
    }

    private func startControllerIfAvailable() async {
        guard wantsEngineRunning, controllerManager != nil else { return }
        controllerState = .connecting
        await controllerManager?.start()
    }

    private func waitForControllerConnection(
        timeout: Duration = .seconds(8),
        pollInterval: Duration = .milliseconds(100)
    ) async -> Bool {
        if controllerState == .connected { return true }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard !Task.isCancelled,
                !isPreparingForTermination,
                isRunning
            else {
                return false
            }
            if controllerState == .connected { return true }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return false
            }
        }
        return controllerState == .connected
    }

    private func presentTrafficTakeoverUnavailable() {
        lastError = UserFacingError(
            title: "Connection unavailable",
            message: "Vela could not prepare traffic routing in time.",
            technicalDetails: lastControllerError.map {
                "The Mihomo Controller did not become ready: \($0)"
            },
            suggestedAction: "Try again, or open Diagnostics if the connection remains unavailable.",
            isRetryable: true,
            recoveryActions: [.openDiagnostics]
        )
    }

    private func updateRunningHealth(controllerReachable: Bool) {
        guard isRunning || state == .starting else { return }
        guard case let .running(current) = state else {
            state = .running(.sprintTwo(
                processRunning: true,
                controllerReachable: controllerReachable,
                configurationValid: validationResult?.isValid == true,
                systemProxyApplied: isSystemProxyApplied
            ))
            return
        }

        let overallState: EngineHealthState = if !controllerReachable,
            current.overallState == .healthy
        {
            .degraded
        } else {
            current.overallState
        }
        state = .running(EngineHealth(
            processRunning: true,
            controllerReachable: controllerReachable,
            configurationValid: current.configurationValid,
            systemProxyApplied: isSystemProxyApplied,
            networkReachable: current.networkReachable,
            internetReachable: current.internetReachable,
            portsListening: current.portsListening,
            lastCheckedAt: current.lastCheckedAt,
            overallState: overallState
        ))
    }

    private func startHealthMonitoringIfNeeded() async {
        guard activeBackendKind == .userProcess,
            let healthMonitor, wantsEngineRunning, isRunning
        else { return }
        if healthSessionID != nil {
            await synchronizeHealthContext()
            return
        }

        let sessionID = UUID()
        healthSessionID = sessionID
        latestHealthSequence = 0
        lastHealthReport = nil
        controllerRecoveryAttempted = false
        controllerRecoveryCount = 0

        await healthMonitor.setApplicationActive(isApplicationActive && !isSleeping)
        guard healthSessionID == sessionID, wantsEngineRunning, isRunning else {
            return
        }
        await healthMonitor.start(context: makeHealthContext(sessionID: sessionID))
        guard healthSessionID == sessionID, wantsEngineRunning, isRunning else {
            if healthSessionID == nil {
                await healthMonitor.stop()
            }
            return
        }
    }

    private func synchronizeHealthContext() async {
        guard let healthMonitor, let healthSessionID else { return }
        await healthMonitor.updateContext(
            makeHealthContext(sessionID: healthSessionID)
        )
    }

    private func makeHealthContext(sessionID: UUID) -> EngineHealthCheckContext {
        EngineHealthCheckContext(
            sessionID: sessionID,
            expectedRunning: true,
            configurationFingerprint: validatedConfigurationFingerprint,
            mixedPort: runtimeParameters.mixedPort,
            systemProxyTarget: systemProxyTarget,
            systemProxyExpected: systemProxyExpected,
            networkPath: networkPathSnapshot
        )
    }

    private func invalidateHealthSession() {
        healthSessionID = nil
        latestHealthSequence = 0
        controllerRecoveryAttempted = false
    }

    private func handleHealthReport(_ report: EngineHealthReport) async {
        guard healthSessionID == report.sessionID,
            report.sequence > latestHealthSequence,
            wantsEngineRunning,
            isRunning
        else {
            return
        }

        let report = reconcilingControllerState(in: report)
        latestHealthSequence = report.sequence
        lastHealthReport = report
        if let status = report.systemProxyStatus, systemProxyOperation == nil {
            systemProxyStatus = status
        }

        guard report.health.processRunning else {
            let systemProxyOperationWasInFlight = systemProxyOperation != nil
            invalidateHealthSession()
            engineOperationGeneration &+= 1
            let crashGeneration = engineOperationGeneration
            systemProxyOperationGeneration &+= 1
            systemProxyOperation = nil
            managedProcessID = nil
            wantsEngineRunning = false
            pendingSystemProxyReapply = false
            state = .recovering
            await healthMonitor?.stop()
            await controllerManager?.stop()
            guard isCurrentEngineOperation(crashGeneration, wantsRunning: false) else {
                return
            }
            resetControllerRuntimeState()
            fail(.unexpectedTermination(exitCode: -1))
            await refreshSystemProxyStatus(presentErrors: false)
            guard isCurrentEngineOperation(crashGeneration, wantsRunning: false) else {
                return
            }

            if systemProxyNeedsRestore {
                presentUnexpectedTerminationRecoveryWarning(exitCode: -1)
            } else {
                let visibleServices = visibleSystemProxyTargetServiceNames(
                    in: systemProxyStatus
                )
                if !visibleServices.isEmpty {
                    presentUnexpectedTerminationVisibleSystemProxyWarning(
                        exitCode: -1,
                        serviceNames: visibleServices
                    )
                } else if systemProxyManager != nil,
                    systemProxyOperationWasInFlight
                        || systemProxyStatus.aggregate == .unavailable
                {
                    presentUnexpectedTerminationUnverifiedSystemProxyWarning(
                        exitCode: -1,
                        operationWasInFlight: systemProxyOperationWasInFlight
                    )
                }
            }
            return
        }

        state = .running(report.health)
        if controllerState != .connected {
            updateRunningHealth(controllerReachable: false)
        }
        if report.health.controllerReachable, controllerState == .connected {
            controllerRecoveryAttempted = false
        } else if !report.health.controllerReachable,
            shouldAttemptControllerRecovery(for: report.triggers)
        {
            await attemptControllerRecovery(
                reason: "A triggered health check could not reach the Controller."
            )
        }
    }

    private func reconcilingControllerState(
        in report: EngineHealthReport
    ) -> EngineHealthReport {
        let sessionReachable = controllerState == .connected
        guard report.health.controllerReachable != sessionReachable else {
            return report
        }

        var checks = report.checks
        let controllerCheck = EngineHealthCheck(
            component: .controller,
            state: sessionReachable ? .passing : .degraded,
            summary: sessionReachable
                ? "The Mihomo Controller session is connected."
                : "The Mihomo Controller session is not ready.",
            technicalDetails: sessionReachable
                ? nil
                : (lastControllerError ?? "Session state: \(controllerState)")
        )
        if let index = checks.firstIndex(where: { $0.component == .controller }) {
            checks[index] = controllerCheck
        } else {
            checks.append(controllerCheck)
        }

        var issues = report.issues.filter { $0.component != .controller }
        if !sessionReachable, report.health.processRunning {
            issues.append(EngineHealthIssue(
                component: .controller,
                severity: .warning,
                summary: "The Controller session is not connected.",
                technicalDetails: lastControllerError,
                suggestedAction: "Wait for startup to finish, then check again."
            ))
        }

        let overallState: EngineHealthState
        if !report.health.processRunning
            || issues.contains(where: { $0.severity == .error })
        {
            overallState = .failed
        } else if !issues.isEmpty || checks.contains(where: { $0.state == .unknown }) {
            overallState = .degraded
        } else {
            overallState = .healthy
        }
        let health = EngineHealth(
            processRunning: report.health.processRunning,
            controllerReachable: sessionReachable,
            configurationValid: report.health.configurationValid,
            systemProxyApplied: report.health.systemProxyApplied,
            networkReachable: report.health.networkReachable,
            internetReachable: report.health.internetReachable,
            portsListening: report.health.portsListening,
            lastCheckedAt: report.health.lastCheckedAt,
            overallState: overallState
        )
        return EngineHealthReport(
            sessionID: report.sessionID,
            sequence: report.sequence,
            triggers: report.triggers,
            health: health,
            systemProxyStatus: report.systemProxyStatus,
            checks: checks,
            issues: issues,
            startedAt: report.startedAt,
            completedAt: report.completedAt
        )
    }

    private func shouldAttemptControllerRecovery(
        for triggers: [HealthCheckTrigger]
    ) -> Bool {
        triggers.contains { trigger in
            switch trigger {
            case .manual, .applicationActivated, .networkChanged, .wokeFromSleep:
                true
            case .startup, .periodic:
                false
            }
        }
    }

    private func attemptControllerRecovery(reason: String) async {
        let maximumRecoveryAttempts = 3
        guard let recoverySessionID = healthSessionID,
            wantsEngineRunning,
            isRunning,
            controllerManager != nil,
            !controllerRecoveryAttempted,
            controllerRecoveryCount < maximumRecoveryAttempts,
            controllerState != .connected,
            controllerState != .connecting
        else {
            return
        }

        controllerRecoveryAttempted = true
        controllerRecoveryCount += 1
        await controllerManager?.recordApplicationLog(
            level: .warning,
            message: "Controller reconnect \(controllerRecoveryCount)/\(maximumRecoveryAttempts): \(reason)"
        )
        guard healthSessionID == recoverySessionID,
            wantsEngineRunning,
            isRunning,
            !isPreparingForTermination
        else {
            return
        }
        await controllerManager?.refresh()
    }

    private func refreshSystemProxyStatus(presentErrors: Bool) async {
        guard let systemProxyManager, systemProxyOperation == nil else { return }

        let operation = SystemProxyOperationState.refreshing
        let generation = beginSystemProxyOperation(operation)
        defer { finishSystemProxyOperation(generation, operation: operation) }

        do {
            let status = try await systemProxyManager.status(for: systemProxyTarget)
            guard isCurrentSystemProxyOperation(generation, operation: operation) else {
                return
            }
            applySystemProxyStatus(status)
        } catch {
            guard isCurrentSystemProxyOperation(generation, operation: operation) else {
                return
            }
            applySystemProxyStatus(
                SystemProxyStatus(
                    target: systemProxyTarget,
                    aggregate: .unavailable,
                    services: [],
                    recovery: systemProxyStatus.recovery
                )
            )
            if presentErrors {
                presentSystemProxyFailure(
                    "System proxy status is unavailable",
                    error: error,
                    suggestedAction: "Check Network settings access, then refresh again."
                )
            }
        }
    }

    private func refreshSystemProxyStatusAfterFailure(
        manager: any SystemProxyManaging,
        generation: UInt64,
        operation: SystemProxyOperationState
    ) async {
        guard let refreshed = try? await manager.status(for: systemProxyTarget),
            isCurrentSystemProxyOperation(generation, operation: operation)
        else {
            return
        }
        applySystemProxyStatus(refreshed)
    }

    private func restoreSystemProxyBeforeStopping() async -> SystemProxyCleanupResult {
        guard let systemProxyManager else {
            return .safe(allowsReapply: false)
        }
        // The cached status is only a hint: perform one fresh read before
        // skipping the restore transaction. If the read fails or exposes any
        // ownership/recovery ambiguity, fall through to the original
        // fail-closed restore path.
        if hasVerifiedCleanSystemProxyState {
            if let freshStatus = try? await systemProxyManager.status(
                for: systemProxyTarget
            ) {
                applySystemProxyStatus(freshStatus)
                if hasVerifiedCleanSystemProxyState {
                    systemProxyExpected = false
                    return .safe(allowsReapply: false)
                }
            }
        }
        let hadRecoveryLease = systemProxyNeedsRestore

        let operation = SystemProxyOperationState.restoring
        let generation = beginSystemProxyOperation(operation)
        defer { finishSystemProxyOperation(generation, operation: operation) }

        do {
            let result = try await systemProxyManager.restore()
            guard isCurrentSystemProxyOperation(generation, operation: operation) else {
                return .unsafe
            }
            systemProxyExpected = false
            applySystemProxyStatus(result.status)

            let visibleTargetServiceNames = visibleSystemProxyTargetServiceNames(
                in: result.status
            )
            guard visibleTargetServiceNames.isEmpty else {
                let names = visibleTargetServiceNames.joined(separator: ", ")
                lastError = UserFacingError(
                    title: "Mihomo was kept running to protect connectivity",
                    message: "System proxy settings still point to Vela on: \(names).",
                    technicalDetails: "Visible Vela proxy endpoints remain on: \(names)",
                    suggestedAction: "Remove the Vela endpoint from those services in macOS Network settings, then retry Stop or Quit.",
                    isRetryable: true
                )
                return .unsafe
            }

            if !result.conflictedServiceNames.isEmpty {
                let names = result.conflictedServiceNames.joined(separator: ", ")
                lastError = UserFacingError(
                    title: "External proxy changes preserved",
                    message: "Vela did not overwrite proxy settings changed by another app on: \(names).",
                    technicalDetails: "Conflicted network services: \(names)",
                    suggestedAction: "Review those services in macOS Network settings if the proxy is unexpected.",
                    isRetryable: false
                )
                return .safe(allowsReapply: false)
            }

            if !result.missingServiceNames.isEmpty {
                guard hasSystemProxyRecovery(result.status) else {
                    presentSystemProxyFailure(
                        "Mihomo was kept running to protect connectivity",
                        error: EngineFailure.systemProxyFailed(
                            "Recovery data was not retained for unavailable network services."
                        ),
                        suggestedAction: "Retry Restore before stopping or quitting Vela."
                    )
                    return .unsafe
                }

                let names = result.missingServiceNames.joined(separator: ", ")
                lastError = UserFacingError(
                    title: "System proxy recovery is waiting for unavailable services",
                    message: "Vela stopped Mihomo without discarding recovery data for: \(names).",
                    technicalDetails: "Unavailable network services: \(names)",
                    suggestedAction: "Reconnect or recreate those services, then use Restore System Proxy.",
                    isRetryable: true
                )
                return .safe(allowsReapply: false)
            }

            guard !hasSystemProxyRecovery(result.status) else {
                presentSystemProxyFailure(
                    "System proxy restoration is incomplete",
                    error: EngineFailure.systemProxyFailed(
                        "Vela-owned proxy settings are still present."
                    ),
                    suggestedAction: "Keep Mihomo running and retry Restore before stopping or quitting."
                )
                return .unsafe
            }

            let allowsReapply = hadRecoveryLease
            return .safe(allowsReapply: allowsReapply)
        } catch {
            await refreshSystemProxyStatusAfterFailure(
                manager: systemProxyManager,
                generation: generation,
                operation: operation
            )
            guard isCurrentSystemProxyOperation(generation, operation: operation) else {
                return .unsafe
            }

            presentSystemProxyFailure(
                "Mihomo was kept running to protect connectivity",
                error: error,
                suggestedAction: "Retry Restore. Vela will not stop Mihomo without a fresh, verified cleanup result."
            )
            return .unsafe
        }
    }

    private func applySystemProxyStatus(_ status: SystemProxyStatus) {
        systemProxyStatus = status
        if case let .running(health) = state {
            updateRunningHealth(controllerReachable: health.controllerReachable)
        }
    }

    private func hasSystemProxyRecovery(_ status: SystemProxyStatus) -> Bool {
        switch status.recovery {
        case .none:
            false
        case .managed, .recoveryRequired:
            true
        }
    }

    private func visibleSystemProxyTargetServiceNames(
        in status: SystemProxyStatus
    ) -> [String] {
        status.services.compactMap { service in
            service.endpoints.contains { $0.matches(systemProxyTarget) }
                ? service.name
                : nil
        }.sorted()
    }

    private var hasVerifiedCleanSystemProxyState: Bool {
        guard !systemProxyExpected,
            systemProxyOperation == nil,
            systemProxyStatus.aggregate == .disabled,
            !systemProxyNeedsRestore
        else {
            return false
        }
        return visibleSystemProxyTargetServiceNames(in: systemProxyStatus).isEmpty
    }

    private var systemProxyRecoveryServiceNames: [String] {
        switch systemProxyStatus.recovery {
        case .none:
            []
        case let .managed(serviceNames), let .recoveryRequired(serviceNames):
            serviceNames
        }
    }

    private func presentUnexpectedTerminationRecoveryWarning(exitCode: Int32) {
        let affectedServices = systemProxyRecoveryServiceNames.joined(separator: ", ")
        lastError = UserFacingError(
            title: "Mihomo stopped while System Proxy needs recovery",
            message: "Mihomo exited with status \(exitCode), and Vela-owned proxy settings may still be active.",
            technicalDetails: affectedServices.isEmpty
                ? "Mihomo exited unexpectedly while a system proxy recovery lease exists."
                : "Affected network services: \(affectedServices)",
            suggestedAction: "Restart Mihomo, or restore System Proxy before using the affected network services.",
            isRetryable: true
        )
    }

    private func presentUnexpectedTerminationUnverifiedSystemProxyWarning(
        exitCode: Int32,
        operationWasInFlight: Bool
    ) {
        lastError = UserFacingError(
            title: "Mihomo stopped before System Proxy cleanup was verified",
            message: "Mihomo exited with status \(exitCode), and Vela could not prove that system proxy settings are safe.",
            technicalDetails: operationWasInFlight
                ? "A system proxy operation was still in progress when Mihomo exited."
                : "The system proxy readback failed after Mihomo exited.",
            suggestedAction: "Restart Mihomo, or use Restore System Proxy and verify macOS Network settings.",
            isRetryable: true
        )
    }

    private func presentUnexpectedTerminationVisibleSystemProxyWarning(
        exitCode: Int32,
        serviceNames: [String]
    ) {
        let names = serviceNames.joined(separator: ", ")
        lastError = UserFacingError(
            title: "System Proxy still points to stopped Mihomo",
            message: "Mihomo exited with status \(exitCode), while proxy settings still point to Vela on: \(names).",
            technicalDetails: "Visible Vela proxy endpoints remain on: \(names)",
            suggestedAction: "Restart Mihomo, or remove the Vela endpoint in macOS Network settings.",
            isRetryable: true
        )
    }

    @discardableResult
    private func beginSystemProxyOperation(_ operation: SystemProxyOperationState) -> UInt64 {
        systemProxyOperationGeneration &+= 1
        systemProxyOperation = operation
        return systemProxyOperationGeneration
    }

    private func isCurrentSystemProxyOperation(
        _ generation: UInt64,
        operation: SystemProxyOperationState
    ) -> Bool {
        systemProxyOperationGeneration == generation && systemProxyOperation == operation
    }

    private func finishSystemProxyOperation(
        _ generation: UInt64,
        operation: SystemProxyOperationState
    ) {
        guard isCurrentSystemProxyOperation(generation, operation: operation) else { return }
        systemProxyOperation = nil
    }

    private func presentSystemProxyUnavailable() {
        lastError = UserFacingError(
            title: "System proxy unavailable",
            message: "Vela could not create its system proxy manager.",
            suggestedAction: "Relaunch Vela and try again.",
            isRetryable: true
        )
    }

    private func presentSystemProxyOperationInProgress() {
        lastError = UserFacingError(
            title: "System proxy operation in progress",
            message: "Wait for the current system proxy operation to finish.",
            isRetryable: true
        )
    }

    private func presentSystemProxyFailure(
        _ title: String,
        error: Error,
        suggestedAction: String
    ) {
        lastError = UserFacingError(
            title: title,
            message: error.localizedDescription,
            technicalDetails: error.localizedDescription,
            suggestedAction: suggestedAction,
            isRetryable: true
        )
    }

    private func resetControllerRuntimeState() {
        controllerState = .disconnected
        controllerVersion = nil
        runtimeMode = nil
        trafficSample = nil
        lastControllerError = nil
        resetProxyRuntimeState()
    }

    private func resetProxyRuntimeState() {
        proxyOperationGeneration &+= 1
        proxyCatalog = configuredProxyCatalog
        proxyCatalogError = nil
        isLoadingProxies = false
        proxyOperation = nil
        proxyDelayStates = [:]
    }

    @discardableResult
    private func beginEngineOperation(wantsRunning: Bool) -> UInt64 {
        engineOperationGeneration &+= 1
        wantsEngineRunning = wantsRunning
        return engineOperationGeneration
    }

    private func isCurrentEngineOperation(
        _ generation: UInt64,
        wantsRunning: Bool? = nil
    ) -> Bool {
        guard engineOperationGeneration == generation else { return false }
        if let wantsRunning {
            return wantsEngineRunning == wantsRunning
        }
        return true
    }

    private func ensureCurrentEngineOperation(
        _ generation: UInt64,
        wantsRunning: Bool? = nil
    ) throws {
        guard isCurrentEngineOperation(generation, wantsRunning: wantsRunning) else {
            throw CancellationError()
        }
    }

    private func mapToEngineFailure(_ error: Error) -> EngineFailure {
        if let operationError = error as? EngineStoreOperationError {
            switch operationError {
            case .profileNotSelected:
                return .runtimeConfigBuildFailed("No profile is selected.")
            case let .configurationInvalid(result):
                if case let .coreIntegrityFailed(message) = result.status {
                    return .coreIntegrityFailed(message)
                }
                return .configurationInvalid(validationMessage(from: result))
            case .processDidNotStart:
                return .processLaunchFailed("The managed process did not report a running state.")
            }
        }

        if let resolverError = error as? MihomoExecutableResolverError {
            switch resolverError {
            case .resourceMissing, .executableMissing:
                return .executableMissing
            case let .executableIsDirectory(url), let .executableNotRunnable(url):
                return .executableNotRunnable(url)
            case let .preflightFailed(error):
                return .coreIntegrityFailed(error.localizedDescription)
            case .versionProbeFailed,
                .versionOutputMissing,
                .checksumFailed:
                return .processLaunchFailed(resolverError.localizedDescription)
            }
        }

        if let processError = error as? MihomoProcessManagerError {
            switch processError {
            case let .configurationInvalid(result):
                if case let .coreIntegrityFailed(message) = result.status {
                    return .coreIntegrityFailed(message)
                }
                return .configurationInvalid(validationMessage(from: result))
            case let .coreIntegrityChanged(_, message):
                return .coreIntegrityFailed(message)
            case let .launchFailed(_, message):
                return .processLaunchFailed(message)
            case let .executableResolutionFailed(message):
                return .processLaunchFailed(message)
            case .launchPreparationInProgress,
                .alreadyRunningWithDifferentConfiguration,
                .stopInProgress,
                .unsafeAdditionalArguments:
                return .processLaunchFailed(processError.localizedDescription)
            case let .stopFailed(_, message):
                return .stopFailed(message)
            }
        }

        if error is RuntimeConfigBuilderError || error is ProfileStoreError {
            return .runtimeConfigBuildFailed(error.localizedDescription)
        }

        if error is RuntimeConfigurationInspectorError {
            return .healthCheckFailed(error.localizedDescription)
        }

        return .processLaunchFailed(error.localizedDescription)
    }

    private func validationMessage(from result: ConfigurationValidationResult) -> String {
        if !result.copyableError.isEmpty {
            return result.copyableError
        }
        return result.issues.map(\.message).joined(separator: "\n")
    }

    private func fail(_ failure: EngineFailure) {
        wantsEngineRunning = false
        state = .failed(failure)
        let isRetryable: Bool = switch failure {
        case .executableMissing, .executableNotRunnable, .coreIntegrityFailed:
            false
        default:
            true
        }
        lastError = UserFacingError(
            title: "Vela needs attention",
            message: failure.summary,
            technicalDetails: failure.summary,
            suggestedAction: suggestedAction(for: failure),
            isRetryable: isRetryable
        )
    }

    private func suggestedAction(for failure: EngineFailure) -> String {
        switch failure {
        case .executableMissing, .executableNotRunnable, .coreIntegrityFailed:
            "Reinstall Vela from a trusted distribution. The app will not download or replace its bundled core at runtime."
        case .configurationInvalid, .runtimeConfigBuildFailed:
            "Review the validation details or import another profile."
        case .processLaunchFailed, .unexpectedTermination, .stopFailed:
            "Retry the operation. If it fails again, copy the technical details."
        case .controllerUnavailable, .systemProxyFailed, .healthCheckFailed:
            "Open Diagnostics and run the relevant checks."
        }
    }

    private func presentNoSelectedProfile() {
        lastError = UserFacingError(
            title: "No profile selected",
            message: "Import and select a Mihomo YAML profile before continuing.",
            suggestedAction: "Open Profiles and import a local YAML file.",
            isRetryable: false
        )
    }

    private func presentProfileChangeBlocked() {
        lastError = UserFacingError(
            title: "Configuration is busy",
            message: "The active profile cannot change during another connection transition.",
            suggestedAction: "Wait for the current operation to finish, then try again.",
            isRetryable: true
        )
    }

    private func presentBusyAction() {
        lastError = UserFacingError(
            title: "Operation in progress",
            message: "Wait for the current engine transition to finish.",
            isRetryable: true
        )
    }

    private func presentNotAvailable(feature: String, sprint: Int) {
        lastError = UserFacingError(
            title: "Not available yet",
            message: "\(feature) is scheduled for Sprint \(sprint).",
            isRetryable: false
        )
    }

    private func present(
        title: String,
        message: String,
        error: Error,
        suggestedAction: String,
        isRetryable: Bool
    ) {
        lastError = UserFacingError(
            title: title,
            message: message,
            technicalDetails: error.localizedDescription,
            suggestedAction: suggestedAction,
            isRetryable: isRetryable
        )
    }
}

nonisolated private struct ValidatedLaunch: Sendable {
    let configurationURL: URL
    let executable: ResolvedMihomoExecutable
    let validationResult: ConfigurationValidationResult
}

nonisolated private struct EngineStopResult: Sendable {
    let stoppedSafely: Bool
    let allowsSystemProxyReapply: Bool

    static let failed = EngineStopResult(
        stoppedSafely: false,
        allowsSystemProxyReapply: false
    )
}

nonisolated private enum SystemProxyCleanupResult: Sendable {
    case safe(allowsReapply: Bool)
    case unsafe

    var isSafe: Bool {
        if case .safe = self { return true }
        return false
    }

    var allowsReapply: Bool {
        if case let .safe(allowsReapply) = self { return allowsReapply }
        return false
    }
}

nonisolated private enum EngineStoreOperationError: Error, Sendable {
    case profileNotSelected
    case configurationInvalid(ConfigurationValidationResult)
    case processDidNotStart
}

nonisolated enum EngineIPv6MutationError: LocalizedError, Equatable, Sendable {
    case controllerUnavailable
    case runtimeBusy
    case verificationFailed(expected: Bool, actual: Bool)

    var errorDescription: String? {
        switch self {
        case .controllerUnavailable:
            "Mihomo is running, but its Controller is not ready to change IPv6."
        case .runtimeBusy:
            "Wait for the current network operation to finish, then try again."
        case let .verificationFailed(expected, actual):
            "Mihomo reported IPv6 as \(actual) after Vela requested \(expected)."
        }
    }
}

nonisolated private enum EngineStoreTunError: Error, Sendable {
    case helperSessionUnavailable
    case systemProxyCouldNotBeDisabled
    case systemProxyCouldNotBeRestored
    case sourceBackendCouldNotStop
    case preparedTargetUnavailable
    case unexpectedRuntimeBackend
    case tunHealthVerificationTimedOut
    case userRuntimeVerificationTimedOut
    case rollbackSourceCouldNotStart
    case rollbackMaterialUnavailable
    case configurationIsNotUTF8
    case invalidProviderConfiguration(String)
    case unsafeProviderResource(String)
    case unsafeProviderPath(String)
    case providerResourceMissing(String)
    case invalidControllerEndpoint
    case staleRuntimeIdentityUnavailable
    case staleRuntimeCleanupFailed
    case privilegedOperationOutcomeUnknown
}

extension EngineStoreTunError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .helperSessionUnavailable:
            "The authenticated privileged helper session is unavailable."
        case .systemProxyCouldNotBeDisabled:
            "System Proxy could not be safely restored before enabling TUN."
        case .systemProxyCouldNotBeRestored:
            "The user-process runtime started, but System Proxy could not be restored."
        case .sourceBackendCouldNotStop:
            "The current Mihomo backend could not be stopped safely."
        case .preparedTargetUnavailable:
            "The prepared target runtime is no longer available."
        case .unexpectedRuntimeBackend:
            "The privileged helper returned an unexpected runtime backend."
        case .tunHealthVerificationTimedOut:
            "The TUN interface, route, DNS, Controller, and owner lease did not all become ready in time."
        case .userRuntimeVerificationTimedOut:
            "The user-process runtime did not become ready in time."
        case .rollbackSourceCouldNotStart:
            "The previous user-process runtime could not be restored."
        case .rollbackMaterialUnavailable:
            "The previous privileged runtime package is no longer available for rollback."
        case .configurationIsNotUTF8:
            "The generated runtime configuration is not valid UTF-8."
        case let .invalidProviderConfiguration(name):
            "The file provider configuration is invalid: \(name)."
        case let .unsafeProviderResource(name):
            "The local provider resource is not a bounded regular file: \(name)."
        case let .unsafeProviderPath(path):
            "The local provider path is outside Vela's profile data: \(path)."
        case let .providerResourceMissing(path):
            "The local provider resource is missing: \(path)."
        case .invalidControllerEndpoint:
            "The user-process Controller endpoint is invalid."
        case .staleRuntimeIdentityUnavailable:
            "The Helper reported a running process without a verifiable Vela instance identity."
        case .staleRuntimeCleanupFailed:
            "The stale privileged runtime was still running after the bounded recovery stop."
        case .privilegedOperationOutcomeUnknown:
            "The privileged operation did not settle to a verified stopped state."
        }
    }
}

nonisolated private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds)
            + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Scene runtime transactions

extension EngineStore: SceneRuntimeTransitioning {
    func restoreActiveSceneConfiguration(_ sceneID: UUID?) {
        guard !isRunning, activeSceneRuntimeTransaction == nil else { return }
        activeConfigurationSceneID = sceneID
    }

    func prepareSceneTransition(
        _ scene: VelaScene,
        activeSceneID: UUID?
    ) async throws -> SceneRuntimeTransitionToken {
        guard scene.enabled else {
            throw EngineSceneTransitionError.sceneDisabled
        }
        guard activeSceneRuntimeTransaction == nil else {
            throw EngineSceneTransitionError.transitionAlreadyInProgress
        }
        guard !isPreparingForTermination, !isBusy else {
            throw EngineSceneTransitionError.engineBusy
        }

        let lease: RuntimeMutationLease
        do {
            lease = try await runtimeMutationGate.acquire(.sceneActivation)
        } catch RuntimeMutationGateError.updateInProgress {
            throw EngineSceneTransitionError.updateInProgress
        }

        do {
            try Task.checkCancellation()
            profiles = try await profileStore.profiles()
            let targetProfileID = scene.profileID ?? selectedProfileID
            if let targetProfileID,
                !profiles.contains(where: { $0.id == targetProfileID })
            {
                throw EngineSceneTransitionError.profileUnavailable(targetProfileID)
            }

            let snapshot = SceneRuntimeSnapshot(
                activeSceneID: activeSceneID,
                profileID: selectedProfileID,
                profileRevisionID: selectedProfile?.currentRevisionID,
                wasRunning: isRunning,
                backend: activeBackendKind,
                systemProxyApplied: isSystemProxyApplied,
                mihomoMode: runtimeMode,
                proxySelections: currentSceneProxySelections()
            )
            let target = resolvedSceneBackend(scene.backend, snapshot: snapshot)
            if target != .off, targetProfileID == nil {
                throw EngineSceneTransitionError.profileRequired
            }

            if target == .tun {
                guard privilegedBackend != nil, transitionCoordinator != nil else {
                    throw EngineSceneTransitionError.tunUnavailable
                }
                await privilegedComponentManager?.refresh()
                guard privilegedComponentIsReady else {
                    throw EngineSceneTransitionError.tunUnavailable
                }
            }

            let targetEngineBackend = engineBackend(for: target, fallback: snapshot.backend)
            if let targetProfileID {
                let layers = try await configurationLayers(
                    scene: scene,
                    profileID: targetProfileID
                )
                let profileRevisionID = profiles.first {
                    $0.id == targetProfileID
                }?.currentRevisionID
                let configurationURL = try await profileStore.buildRuntimeConfiguration(
                    for: targetProfileID,
                    parameters: runtimeParameters,
                    using: runtimeConfigBuilder,
                    context: ConfigurationCompilationContext(
                        profileID: targetProfileID,
                        profileRevisionID: profileRevisionID,
                        layers: layers,
                        backend: ConfigurationBackendContext(backend: targetEngineBackend)
                    )
                )
                let executable = try await executableResolver.resolve()
                let validation = await configurationValidator.validate(
                    configurationURL: configurationURL,
                    dataDirectoryURL: mihomoDataDirectoryURL,
                    using: executable,
                    timeout: .seconds(10)
                )
                guard validation.isValid else {
                    throw EngineSceneTransitionError.configurationRejected
                }
            } else if scene.configurationLayerID != nil {
                throw EngineSceneTransitionError.profileRequired
            }

            try analyzeSceneProxySelections(scene)
            let token = SceneRuntimeTransitionToken()
            activeSceneRuntimeTransaction = ActiveSceneRuntimeTransaction(
                token: token,
                lease: lease,
                snapshot: snapshot,
                targetSceneID: scene.id
            )
            return token
        } catch {
            await runtimeMutationGate.release(lease)
            throw error
        }
    }

    func applySceneTransition(
        _ scene: VelaScene,
        token: SceneRuntimeTransitionToken
    ) async throws {
        let transaction = try sceneTransaction(token, sceneID: scene.id)
        let target = resolvedSceneBackend(scene.backend, snapshot: transaction.snapshot)
        let targetProfileID = scene.profileID ?? transaction.snapshot.profileID

        try await stopRuntimeForSceneTransition()
        activeConfigurationSceneID = scene.id
        pendingConfigurationBackend = engineBackend(
            for: target,
            fallback: transaction.snapshot.backend
        )

        if let targetProfileID, selectedProfileID != targetProfileID {
            await performSelectProfile(id: targetProfileID)
            try throwSceneStepErrorIfPresent("The target profile could not be selected.")
            guard selectedProfileID == targetProfileID else {
                throw EngineSceneTransitionError.profileUnavailable(targetProfileID)
            }
        }

        switch target {
        case .off:
            break
        case .engineOnly, .systemProxy:
            await performStart()
            try throwSceneStepErrorIfPresent("The user-process backend could not start.")
            guard isRunning, activeBackendKind == .userProcess else {
                throw EngineSceneTransitionError.backendVerificationFailed
            }
            try await verifyUserTarget()
            if target == .systemProxy {
                await performSetSystemProxyEnabled(true)
                try throwSceneStepErrorIfPresent("System Proxy could not be enabled.")
            }
        case .tun:
            await performSetTunEnabled(true)
            try throwSceneStepErrorIfPresent("TUN could not be enabled.")
            guard isTunActive else {
                throw EngineSceneTransitionError.backendVerificationFailed
            }
        case .keepCurrent:
            // `resolvedSceneBackend` always converts keepCurrent to a concrete
            // target before the transition starts.
            throw EngineSceneTransitionError.backendVerificationFailed
        }

        guard target == .off || isRunning else {
            throw EngineSceneTransitionError.backendVerificationFailed
        }
        if target != .off {
            try await applySceneControllerTargets(scene)
        }
    }

    func verifySceneTransition(
        _ scene: VelaScene,
        token: SceneRuntimeTransitionToken
    ) async throws {
        let transaction = try sceneTransaction(token, sceneID: scene.id)
        let target = resolvedSceneBackend(scene.backend, snapshot: transaction.snapshot)

        switch target {
        case .off:
            guard !isRunning, !privilegedRuntimeMayBeActive, !isSystemProxyApplied else {
                throw EngineSceneTransitionError.backendVerificationFailed
            }
        case .tun:
            guard isTunActive, !isSystemProxyApplied else {
                throw EngineSceneTransitionError.backendVerificationFailed
            }
        case .systemProxy:
            guard isRunning,
                activeBackendKind == .userProcess,
                isSystemProxyApplied
            else {
                throw EngineSceneTransitionError.backendVerificationFailed
            }
        case .engineOnly:
            guard isRunning,
                activeBackendKind == .userProcess,
                !isSystemProxyApplied
            else {
                throw EngineSceneTransitionError.backendVerificationFailed
            }
        case .keepCurrent:
            throw EngineSceneTransitionError.backendVerificationFailed
        }

        if let expectedMode = scene.mihomoMode {
            try await waitForSceneCondition {
                self.runtimeMode == expectedMode
            }
        }
        for selection in scene.proxySelections {
            guard selection.missingPolicy == .failScene else { continue }
            try await waitForSceneCondition {
                guard let group = self.proxyCatalog.group(named: selection.groupName) else {
                    return false
                }
                return self.selectionIsConfirmed(selection.proxyName, in: group)
            }
        }

        if lastHealthReport?.state == .failed {
            throw EngineSceneTransitionError.healthVerificationFailed
        }
    }

    func commitSceneTransition(
        _ scene: VelaScene,
        token: SceneRuntimeTransitionToken
    ) async throws {
        let transaction = try sceneTransaction(token, sceneID: scene.id)
        pendingConfigurationBackend = nil
        activeSceneRuntimeTransaction = nil
        lastError = nil
        await runtimeMutationGate.release(transaction.lease)
    }

    func rollbackSceneTransition(
        token: SceneRuntimeTransitionToken
    ) async throws {
        let transaction = try sceneTransaction(token, sceneID: nil)
        do {
            try await stopRuntimeForSceneTransition()
            activeConfigurationSceneID = transaction.snapshot.activeSceneID
            pendingConfigurationBackend = transaction.snapshot.backend

            profiles = try await profileStore.profiles()
            if let profileID = transaction.snapshot.profileID {
                guard let profile = profiles.first(where: { $0.id == profileID }),
                    profile.currentRevisionID == transaction.snapshot.profileRevisionID
                else {
                    throw EngineSceneTransitionError.rollbackProfileRevisionUnavailable
                }
                if selectedProfileID != profileID {
                    await performSelectProfile(id: profileID)
                    try throwSceneStepErrorIfPresent(
                        "The previous profile could not be restored."
                    )
                }
            } else {
                try await profileStore.clearSelectedProfile()
                selectedProfileID = nil
            }

            if transaction.snapshot.wasRunning {
                if transaction.snapshot.backend == .privilegedDaemon {
                    await performSetTunEnabled(true)
                    try throwSceneStepErrorIfPresent(
                        "The previous TUN backend could not be restored."
                    )
                    guard isTunActive else {
                        throw EngineSceneTransitionError.rollbackBackendUnavailable
                    }
                } else {
                    await performStart()
                    try throwSceneStepErrorIfPresent(
                        "The previous user-process backend could not be restored."
                    )
                    try await verifyUserTarget()
                    if transaction.snapshot.systemProxyApplied {
                        await performSetSystemProxyEnabled(true)
                        try throwSceneStepErrorIfPresent(
                            "The previous System Proxy state could not be restored."
                        )
                    }
                }

                if let mode = transaction.snapshot.mihomoMode {
                    await performModeChange(mode)
                    try throwSceneStepErrorIfPresent(
                        "The previous Mihomo mode could not be restored."
                    )
                }
                for (group, proxy) in transaction.snapshot.proxySelections.sorted(
                    by: { $0.key < $1.key }
                ) {
                    await performProxySelection(
                        group: group,
                        requestedNodeID: nil,
                        proxyName: proxy
                    )
                    try throwSceneStepErrorIfPresent(
                        "A previous proxy selection could not be restored."
                    )
                }
            }

            pendingConfigurationBackend = nil
            activeSceneRuntimeTransaction = nil
            lastError = nil
            await runtimeMutationGate.release(transaction.lease)
        } catch {
            pendingConfigurationBackend = nil
            activeSceneRuntimeTransaction = nil
            await runtimeMutationGate.release(transaction.lease)
            throw EngineSceneTransitionError.rollbackFailed(
                DiagnosticTextSanitizer.redact(error.localizedDescription)
            )
        }
    }

    private func sceneTransaction(
        _ token: SceneRuntimeTransitionToken,
        sceneID: UUID?
    ) throws -> ActiveSceneRuntimeTransaction {
        guard let transaction = activeSceneRuntimeTransaction,
            transaction.token == token,
            sceneID.map({ transaction.targetSceneID == $0 }) ?? true
        else {
            throw EngineSceneTransitionError.invalidTransaction
        }
        return transaction
    }

    private func resolvedSceneBackend(
        _ preference: SceneBackendPreference,
        snapshot: SceneRuntimeSnapshot
    ) -> SceneBackendPreference {
        guard preference == .keepCurrent else { return preference }
        guard snapshot.wasRunning else { return .off }
        if snapshot.backend == .privilegedDaemon { return .tun }
        return snapshot.systemProxyApplied ? .systemProxy : .engineOnly
    }

    private func engineBackend(
        for target: SceneBackendPreference,
        fallback: EngineBackendKind
    ) -> EngineBackendKind {
        switch target {
        case .tun:
            .privilegedDaemon
        case .systemProxy, .engineOnly, .off:
            .userProcess
        case .keepCurrent:
            fallback
        }
    }

    private func configurationLayers(
        scene: VelaScene,
        profileID: UUID
    ) async throws -> [ConfigurationLayer] {
        guard let configurationLayerStore else {
            if scene.configurationLayerID == nil { return [] }
            throw EngineSceneTransitionError.configurationLayerUnavailable
        }
        let layers = try await configurationLayerStore.layers(
            profileID: profileID,
            sceneID: scene.id
        )
        if let requiredLayerID = scene.configurationLayerID,
            !layers.contains(where: { $0.id == requiredLayerID && $0.kind == .scene })
        {
            throw EngineSceneTransitionError.configurationLayerUnavailable
        }
        return layers
    }

    private func analyzeSceneProxySelections(_ scene: VelaScene) throws {
        guard scene.profileID == nil || scene.profileID == selectedProfileID else {
            // Availability for another profile is proved after its Controller
            // catalog is loaded. Prepare still validates duplicate targets.
            let names = scene.proxySelections.map(\.groupName)
            guard Set(names).count == names.count else {
                throw EngineSceneTransitionError.duplicateProxyGroup
            }
            return
        }
        for selection in scene.proxySelections where selection.missingPolicy == .failScene {
            guard let group = proxyCatalog.group(named: selection.groupName),
                group.nodes.contains(where: { $0.name == selection.proxyName })
            else {
                throw EngineSceneTransitionError.proxyUnavailable(
                    group: selection.groupName,
                    proxy: selection.proxyName
                )
            }
        }
    }

    private func applySceneControllerTargets(_ scene: VelaScene) async throws {
        if controllerState != .connected {
            if activeBackendKind == .privilegedDaemon {
                try await verifyPrivilegedTarget()
            } else {
                try await verifyUserTarget()
            }
        }

        if let mode = scene.mihomoMode {
            await performModeChange(mode)
            try throwSceneStepErrorIfPresent("The requested Mihomo mode was rejected.")
        }

        if !scene.proxySelections.isEmpty {
            await refreshProxies()
            if lastError != nil {
                throw EngineSceneTransitionError.stepFailed(
                    "The proxy catalog could not be refreshed."
                )
            }
        }
        for selection in scene.proxySelections {
            guard let group = proxyCatalog.group(named: selection.groupName),
                group.nodes.contains(where: { $0.name == selection.proxyName })
            else {
                if selection.missingPolicy == .failScene {
                    throw EngineSceneTransitionError.proxyUnavailable(
                        group: selection.groupName,
                        proxy: selection.proxyName
                    )
                }
                continue
            }
            await performProxySelection(
                group: selection.groupName,
                requestedNodeID: nil,
                proxyName: selection.proxyName
            )
            if lastError != nil {
                if selection.missingPolicy == .failScene {
                    try throwSceneStepErrorIfPresent(
                        "A required proxy selection was rejected."
                    )
                }
                lastError = nil
            }
        }
    }

    private func stopRuntimeForSceneTransition() async throws {
        if activeBackendKind == .privilegedDaemon || privilegedRuntimeMayBeActive {
            await stopPrivilegedEngine(reason: .backendTransition, updateState: true)
            guard !privilegedRuntimeMayBeActive, !isRunning else {
                throw EngineSceneTransitionError.sourceBackendCouldNotStop
            }
            lastError = nil
            return
        }
        guard isRunning || state != .stopped else { return }
        let result = await performStop()
        guard result.stoppedSafely, !isRunning else {
            throw EngineSceneTransitionError.sourceBackendCouldNotStop
        }
        lastError = nil
    }

    private func currentSceneProxySelections() -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: proxyCatalog.groups.compactMap { group in
                guard group.isSelectable,
                    let selection = group.now?.nilIfEmpty ?? group.fixed?.nilIfEmpty
                else { return nil }
                return (group.name, selection)
            }
        )
    }

    private func throwSceneStepErrorIfPresent(_ fallback: String) throws {
        guard let lastError else { return }
        let detail = lastError.message.isEmpty ? fallback : lastError.message
        throw EngineSceneTransitionError.stepFailed(detail)
    }

    private func waitForSceneCondition(
        attempts: Int = 40,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        throw EngineSceneTransitionError.controllerVerificationFailed
    }
}

nonisolated private enum EngineSceneTransitionError: Error, Sendable {
    case sceneDisabled
    case transitionAlreadyInProgress
    case engineBusy
    case updateInProgress
    case profileRequired
    case profileUnavailable(UUID)
    case configurationLayerUnavailable
    case configurationRejected
    case tunUnavailable
    case duplicateProxyGroup
    case proxyUnavailable(group: String, proxy: String)
    case sourceBackendCouldNotStop
    case backendVerificationFailed
    case controllerVerificationFailed
    case healthVerificationFailed
    case stepFailed(String)
    case invalidTransaction
    case rollbackProfileRevisionUnavailable
    case rollbackBackendUnavailable
    case rollbackFailed(String)
}

extension EngineSceneTransitionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .sceneDisabled:
            "This Scene is disabled."
        case .transitionAlreadyInProgress:
            "Another Scene transition is already in progress."
        case .engineBusy:
            "Mihomo is busy with another operation."
        case .updateInProgress:
            "A Vela update currently owns the runtime mutation barrier."
        case .profileRequired:
            "This Scene needs an available profile before it can be activated."
        case let .profileUnavailable(id):
            "The Scene profile is unavailable: \(id.uuidString)."
        case .configurationLayerUnavailable:
            "The Scene configuration layer is unavailable or disabled."
        case .configurationRejected:
            "Mihomo rejected the compiled Scene configuration."
        case .tunUnavailable:
            "The privileged component is not ready for this TUN Scene."
        case .duplicateProxyGroup:
            "A Scene cannot select more than one proxy for the same group."
        case let .proxyUnavailable(group, proxy):
            "The required proxy \(proxy) is unavailable in \(group)."
        case .sourceBackendCouldNotStop:
            "The current Mihomo backend could not be stopped safely."
        case .backendVerificationFailed:
            "The Scene target backend did not reach its required state."
        case .controllerVerificationFailed:
            "The Mihomo Controller did not confirm the Scene target in time."
        case .healthVerificationFailed:
            "Runtime health verification failed after applying the Scene."
        case let .stepFailed(reason):
            DiagnosticTextSanitizer.redact(reason)
        case .invalidTransaction:
            "The Scene transaction is no longer valid."
        case .rollbackProfileRevisionUnavailable:
            "The previous profile revision is unavailable for rollback."
        case .rollbackBackendUnavailable:
            "The previous runtime backend could not be restored."
        case let .rollbackFailed(reason):
            "Scene rollback failed: \(DiagnosticTextSanitizer.redact(reason))"
        }
    }
}
