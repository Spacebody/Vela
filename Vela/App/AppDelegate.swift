import AppKit

enum AppTerminationCleanupBarrier {
    private actor Resolution {
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?

        func wait() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resolve(_ result: Bool) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    /// AppKit must always receive its termination reply. Background catalog,
    /// subscription, and Geo tasks are cancelled during shutdown, but a broken
    /// remote operation may ignore cancellation. Bound that non-safety-critical
    /// join so it can never strand the application in `.terminateLater`.
    static func wait(
        timeout: Duration,
        operation: @escaping @MainActor () async -> Void
    ) async -> Bool {
        let resolution = Resolution()
        let operationTask = Task { @MainActor in
            await operation()
            await resolution.resolve(true)
        }
        // A plain `Task` inherits MainActor here. During a busy shutdown (or a
        // concurrent MainActor test run), that can delay the timer itself and
        // defeat the deadline. Keep the clock off the UI executor so AppKit's
        // termination reply remains genuinely bounded.
        let timeoutTask = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: timeout)
                await resolution.resolve(false)
            } catch {
                // The operation won the race and cancelled the timeout.
            }
        }

        let completed = await resolution.wait()
        timeoutTask.cancel()
        if !completed {
            operationTask.cancel()
        }
        return completed
    }
}

nonisolated enum AppTerminationPreparationResult: Equatable, Sendable {
    case completed(safeToTerminate: Bool)
    case timedOut

    var safeToTerminate: Bool {
        switch self {
        case let .completed(safeToTerminate):
            safeToTerminate
        case .timedOut:
            false
        }
    }
}

nonisolated struct AppTerminationResolution: Equatable, Sendable {
    let shouldTerminate: Bool
    let shouldYieldPrivilegedRuntimeToLeaseCleanup: Bool

    static func resolve(
        preparation: AppTerminationPreparationResult,
        privilegedRuntimeMayBeActive: Bool
    ) -> Self {
        Self(
            shouldTerminate: true,
            shouldYieldPrivilegedRuntimeToLeaseCleanup:
                !preparation.safeToTerminate && privilegedRuntimeMayBeActive
        )
    }
}

enum AppTerminationPreparationBarrier {
    private actor Resolution {
        private var result: AppTerminationPreparationResult?
        private var continuation: CheckedContinuation<AppTerminationPreparationResult, Never>?

        func wait() async -> AppTerminationPreparationResult {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resolve(_ result: AppTerminationPreparationResult) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    /// Engine cleanup includes bounded process, system-proxy, and privileged
    /// runtime work, but the coordination chain itself must also be bounded.
    /// Otherwise AppKit can wait forever after `.terminateLater` even when an
    /// individual cleanup dependency fails to resume its continuation.
    static func wait(
        timeout: Duration,
        operation: @escaping @MainActor () async -> Bool
    ) async -> AppTerminationPreparationResult {
        let resolution = Resolution()
        let operationTask = Task { @MainActor in
            let safeToTerminate = await operation()
            await resolution.resolve(.completed(safeToTerminate: safeToTerminate))
        }
        let timeoutTask = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: timeout)
                await resolution.resolve(.timedOut)
            } catch {
                // The cleanup operation won the race and cancelled the deadline.
            }
        }

        let result = await resolution.wait()
        timeoutTask.cancel()
        if result == .timedOut {
            operationTask.cancel()
        }
        return result
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var engineStore: EngineStore? {
        didSet {
            beginBootstrapIfReady()
        }
    }
    weak var dailyDriver: DailyDriverFeatureHub? {
        didSet {
            beginBootstrapIfReady()
        }
    }
    weak var sceneController: SceneFeatureController? {
        didSet {
            beginBootstrapIfReady()
        }
    }
    weak var updateController: UpdateController?
    weak var updateRecoveryCoordinator: UpdateRecoveryCoordinator? {
        didSet {
            beginBootstrapIfReady()
        }
    }
    weak var coreLifecycleController: CoreLifecycleController? {
        didSet {
            beginBootstrapIfReady()
        }
    }
    weak var onboardingCoordinator: OnboardingCoordinator? {
        didSet {
            beginBootstrapIfReady()
        }
    }
    weak var publicBetaSafeModeController: PublicBetaSafeModeController? {
        didSet {
            beginBootstrapIfReady()
        }
    }
    weak var publicBetaEvidenceController: PublicBetaEvidenceController? {
        didSet {
            beginBootstrapIfReady()
        }
    }
    var signpostRecorder: (any VelaSignpostRecording)? {
        didSet {
            beginBootstrapIfReady()
        }
    }
    private var hasFinishedLaunching = false
    private var hasStartedBootstrap = false
    private var isPreparingToTerminate = false
    private var lifecycleTask: Task<Void, Never>?
    private var privilegedReconciliationTask: Task<Void, Never>?
#if DEBUG
    var visualMenuAppearanceName: NSAppearance.Name?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        hasFinishedLaunching = true
#if DEBUG
        if visualMenuAppearanceName != nil {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applyVisualMenuAppearance(_:)),
                name: NSMenu.didBeginTrackingNotification,
                object: nil
            )
        }
#endif
        guard !AppLaunchConfiguration.isHostedUnitTestProcess() else { return }
        beginBootstrapIfReady()
    }

#if DEBUG
    @objc private func applyVisualMenuAppearance(_ notification: Notification) {
        guard let visualMenuAppearanceName,
            let menu = notification.object as? NSMenu
        else {
            return
        }
        menu.appearance = NSAppearance(named: visualMenuAppearanceName)
    }

#endif

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor [weak self] in
            await self?.engineStore?.setApplicationActive(true)
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        Task { @MainActor [weak self] in
            await self?.engineStore?.setApplicationActive(false)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
#if DEBUG
        if !Self.allowsLifecycleBootstrap() {
            lifecycleTask?.cancel()
            lifecycleTask = nil
            privilegedReconciliationTask?.cancel()
            privilegedReconciliationTask = nil
            return .terminateNow
        }
#endif
        guard let engineStore else { return .terminateNow }
        if engineStore.consumePreparedInstallTerminationAuthorization()
            || engineStore.updatePreparationState == .terminationAuthorized
        {
            lifecycleTask?.cancel()
            lifecycleTask = nil
            privilegedReconciliationTask?.cancel()
            privilegedReconciliationTask = nil
            return .terminateNow
        }
        if engineStore.updatePreparationState == .preparing {
            guard !isPreparingToTerminate else { return .terminateLater }
            isPreparingToTerminate = true
            Task { @MainActor [weak self, weak engineStore] in
                guard let self, let engineStore else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                let authorized = await self.waitForUpdatePreparation(
                    engineStore: engineStore
                )
                if authorized {
                    self.lifecycleTask?.cancel()
                    self.lifecycleTask = nil
                    self.privilegedReconciliationTask?.cancel()
                    self.privilegedReconciliationTask = nil
                }
                self.isPreparingToTerminate = false
                sender.reply(toApplicationShouldTerminate: authorized)
            }
            return .terminateLater
        }
        guard !isPreparingToTerminate else { return .terminateLater }

        isPreparingToTerminate = true
        Task {
            let preparation = await AppTerminationPreparationBarrier.wait(
                timeout: .seconds(3)
            ) {
                await engineStore.prepareForTermination()
            }
            let resolution = AppTerminationResolution.resolve(
                preparation: preparation,
                privilegedRuntimeMayBeActive: engineStore.privilegedRuntimeMayBeActive
            )
            if resolution.shouldYieldPrivilegedRuntimeToLeaseCleanup {
                await engineStore.yieldPrivilegedRuntimeToLeaseCleanupForTermination()
            }
            if resolution.shouldTerminate {
                lifecycleTask?.cancel()
                lifecycleTask = nil
                privilegedReconciliationTask?.cancel()
                privilegedReconciliationTask = nil
                if let dailyDriver {
                    _ = await AppTerminationCleanupBarrier.wait(
                        timeout: .seconds(1)
                    ) {
                        await dailyDriver.shutdown()
                    }
                }
            }
            isPreparingToTerminate = false
            sender.reply(toApplicationShouldTerminate: resolution.shouldTerminate)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .velaOpenMainWindow, object: nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        !SettingsPreferencesStore.persistedMinimizeToMenuBar()
    }

    private func beginBootstrapIfReady() {
        guard hasFinishedLaunching, !hasStartedBootstrap,
            let engineStore, let dailyDriver, let updateRecoveryCoordinator,
            let sceneController, let coreLifecycleController, let onboardingCoordinator,
            let publicBetaSafeModeController, let publicBetaEvidenceController,
            let signpostRecorder
        else {
            return
        }

#if DEBUG
        // Visual capture consumes only isolated, deterministic dependencies.
        // Skipping the production recovery/bootstrap graph also prevents Core
        // probes, update recovery, schedulers, and evidence writes from racing
        // the first frame.
        guard Self.allowsLifecycleBootstrap() else {
            hasStartedBootstrap = true
            return
        }
#endif
        hasStartedBootstrap = true
        Task {
            @MainActor [weak self, weak engineStore, weak dailyDriver,
                weak sceneController,
                weak updateRecoveryCoordinator, weak coreLifecycleController,
                weak publicBetaSafeModeController, weak publicBetaEvidenceController] in
            guard let self, let engineStore, let dailyDriver,
                let sceneController,
                let updateRecoveryCoordinator, let coreLifecycleController,
                let publicBetaSafeModeController, let publicBetaEvidenceController
            else {
                return
            }

            let resolvedLaunchConfiguration = try? AppLaunchConfiguration.resolve()
            let allowsAutomaticServices =
                resolvedLaunchConfiguration?.usesLiveServices == true
            let isTestHarness = resolvedLaunchConfiguration != .production

            let launchStartedAt = Date()
            let launchSignpost = await signpostRecorder.begin(
                .appLaunchToFirstMeaningfulRender
            )
            let requestedSafeModeReason = publicBetaSafeModeController.beginLaunch()
            let launchDisposition = await updateRecoveryCoordinator.preflightLaunch()
            guard !Task.isCancelled else {
                await signpostRecorder.end(launchSignpost, outcome: .cancelled)
                return
            }
            let preserveCoreTransaction: Bool
            if case .pendingRecovery = launchDisposition {
                preserveCoreTransaction = true
            } else {
                preserveCoreTransaction = false
            }

            if case .safeMode = launchDisposition {
                publicBetaSafeModeController.activate(.updateRecovery)
            }
            if requestedSafeModeReason != nil || publicBetaSafeModeController.isActive {
                await engineStore.enterUpdateRecoverySafeMode()
            }
            await coreLifecycleController.bootstrap(
                preserveInterruptedTransactionForUpdate: preserveCoreTransaction,
                forceReadOnlySafeMode: requestedSafeModeReason != nil
            )
            guard !Task.isCancelled else {
                await signpostRecorder.end(launchSignpost, outcome: .cancelled)
                return
            }

            if coreLifecycleController.readOnlySafeMode,
                !publicBetaSafeModeController.isActive
            {
                publicBetaSafeModeController.activate(.coreRecovery)
            }

            if case .safeMode = launchDisposition {
                await engineStore.enterUpdateRecoverySafeMode()
            }

            // Restore the durable Scene layer before EngineStore exposes a
            // selected profile to menu-bar actions. Automatic evaluation stays
            // paused until recovery and safe-mode gates have all succeeded.
            await sceneController.bootstrap(
                engineStore: engineStore,
                startsAutomation: false
            )
            await engineStore.bootstrap()
            guard !Task.isCancelled else {
                await signpostRecorder.end(launchSignpost, outcome: .cancelled)
                return
            }

            let persistentTransactionsRecovered: Bool
            if publicBetaSafeModeController.isActive {
                persistentTransactionsRecovered = false
            } else {
                persistentTransactionsRecovered =
                    await dailyDriver.recoverPersistentTransactions()
            }
            if !persistentTransactionsRecovered,
                !publicBetaSafeModeController.isActive
            {
                publicBetaSafeModeController.activate(.migrationFailure)
                await coreLifecycleController.enterPublicBetaSafeMode()
                await engineStore.enterUpdateRecoverySafeMode()
            }
            let updateRecoverySucceeded: Bool
            if persistentTransactionsRecovered {
                switch launchDisposition {
                case .normal:
                    updateRecoverySucceeded = true
                case .pendingRecovery:
                    updateRecoverySucceeded =
                        await updateRecoveryCoordinator.recoverAfterBootstrap()
                case .safeMode:
                    updateRecoverySucceeded = false
                }
            } else {
                updateRecoverySucceeded = false
            }
            await coreLifecycleController.finishUpdateRecovery(
                succeeded: updateRecoverySucceeded
            )

            // Keep the first Configuration Workbench visit off the critical
            // interaction path. Clash Verge keeps its profile model warm while
            // runtime generation continues after the window is visible; do the
            // same here without making Mihomo/Controller startup wait for a UI
            // preview compile. Transaction recovery must finish first so the
            // preview can never observe an interrupted configuration write.
            if persistentTransactionsRecovered, updateRecoverySucceeded,
                let selectedProfileID = engineStore.selectedProfileID
            {
                Task(priority: .userInitiated) { @MainActor [weak dailyDriver] in
                    await dailyDriver?.configuration.selectProfile(selectedProfileID)
                }
            }

            let automaticServicesAllowed = persistentTransactionsRecovered
                && updateRecoverySucceeded
                && !coreLifecycleController.readOnlySafeMode
                && !publicBetaSafeModeController.isActive
                && allowsAutomaticServices
            if !automaticServicesAllowed {
                await engineStore.enterUpdateRecoverySafeMode()
            }
            if automaticServicesAllowed {
                await engineStore.ensureInfrastructureRunning()
                dailyDriver.engineRunningChanged(engineStore.isRunning)
                dailyDriver.startScheduling(
                    networkAvailable: engineStore.networkPathSnapshot.networkReachable
                )
                await coreLifecycleController.startAutomaticCatalogScheduling()
                await sceneController.bootstrap(
                    engineStore: engineStore,
                    startsAutomation: true
                )
            } else {
                dailyDriver.engineRunningChanged(false)
            }
            // TUN is optional. Its Helper may be registered but unreachable,
            // so never let its bounded XPC handshake delay the ordinary
            // app-owned Mihomo/Controller startup path.
            self.privilegedReconciliationTask?.cancel()
            self.privilegedReconciliationTask = Task {
                @MainActor [weak self, weak engineStore, weak dailyDriver] in
                guard let engineStore else { return }
                await engineStore.reconcilePrivilegedComponentAfterBootstrap(
                    restartInfrastructureIfNeeded: automaticServicesAllowed
                )
                guard !Task.isCancelled else { return }
                if automaticServicesAllowed {
                    dailyDriver?.engineRunningChanged(engineStore.isRunning)
                }
                self?.privilegedReconciliationTask = nil
            }
            updateController?.startIfEligible(
                recoveryAllowsUpdates: automaticServicesAllowed
            )
            let arguments = ProcessInfo.processInfo.arguments
#if DEBUG
            let forcesOnboarding = VisualUITestConfiguration.forcesOnboarding(
                arguments: arguments
            )
#else
            let forcesOnboarding = false
#endif
            if !isTestHarness || forcesOnboarding {
                do {
                    try await onboardingCoordinator.prepare(
                        for: OnboardingLaunchContext(
                            hasExistingUserData: !engineStore.profiles.isEmpty
                        )
                    )
                    if case .present = onboardingCoordinator.presentationDecision {
                        NotificationCenter.default.post(
                            name: .velaOpenMainWindow,
                            object: nil
                        )
                        await Task.yield()
                        NotificationCenter.default.post(
                            name: .velaOpenOnboarding,
                            object: nil
                        )
                    }
                } catch {
                    // Onboarding persistence must never block normal startup or
                    // change network state. The flow remains reopenable from Settings.
                }
            }
            guard !Task.isCancelled else {
                await signpostRecorder.end(launchSignpost, outcome: .cancelled)
                return
            }

            let events = engineStore.lifecycleEvents()
            self.lifecycleTask = Task {
                @MainActor [weak dailyDriver, weak coreLifecycleController] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    dailyDriver?.handleLifecycleEvent(event)
                    if case .networkAvailabilityChanged(true) = event {
                        await coreLifecycleController?.automaticNetworkBecameAvailable()
                    }
                }
            }
            publicBetaSafeModeController.markLaunchHealthy()
            await signpostRecorder.end(launchSignpost, outcome: .succeeded)
            await publicBetaEvidenceController.record(
                ReliabilityEventDraft(
                    kind: .appLaunch,
                    phase: .committed,
                    resultCode: .success,
                    durationMilliseconds: Self.boundedMilliseconds(since: launchStartedAt)
                )
            )
        }
    }

#if DEBUG
    nonisolated static func allowsLifecycleBootstrap(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        !VisualUITestConfiguration.isRequested(arguments: arguments)
    }
#endif

    private static func boundedMilliseconds(since startedAt: Date) -> Int {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed.isFinite else { return ReliabilityEvidence.maximumDurationMilliseconds }
        let bounded = min(max(elapsed, 0), 86_400)
        return Int((bounded * 1_000).rounded())
    }

    private func waitForUpdatePreparation(engineStore: EngineStore) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if engineStore.consumePreparedInstallTerminationAuthorization()
                || engineStore.updatePreparationState == .terminationAuthorized
            {
                return true
            }
            if engineStore.updatePreparationState == .idle {
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return false
    }
}

extension Notification.Name {
    static let velaOpenMainWindow = Notification.Name("dev.yilin.Vela.openMainWindow")
}
