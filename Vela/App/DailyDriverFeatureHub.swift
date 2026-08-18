import Foundation
import Observation

nonisolated protocol RemoteProfileServicing: Sendable {
    func createRemoteProfile(_ request: RemoteProfileCreationRequest) async throws -> Profile
    func deleteProfile(_ profileID: UUID) async throws
    func editableSettings(for profileID: UUID) async throws -> RemoteProfileEditableSettings
    func editRemoteProfile(
        _ profileID: UUID,
        request: RemoteProfileEditRequest
    ) async throws -> Profile
    func updateState(for profileID: UUID) async -> SubscriptionUpdateState
    func rawConfiguration(for profileID: UUID) async throws -> String
}

extension SubscriptionProfileService: RemoteProfileServicing {}

nonisolated protocol RemoteProfileScheduling: Sendable {
    func updateNow(profileID: UUID) async -> SubscriptionScheduledResult?
    func updateAllNow(profileIDs: [UUID]) async -> [SubscriptionScheduledResult]
    func runDueUpdates(
        profiles: [Profile],
        at now: Date,
        networkAvailable: Bool,
        reason: SubscriptionUpdateReason
    ) async -> [SubscriptionScheduledResult]
    func profileDeleted(_ profileID: UUID) async
    func profileRestored(_ profileID: UUID) async
    func isUpdating(_ profileID: UUID) async -> Bool
    func cancelUpdate(_ profileID: UUID) async
    func cancelAllUpdatesAndWait() async
}

extension RemoteProfileScheduling {
    func cancelAllUpdatesAndWait() async {}
}

extension SubscriptionUpdateScheduler: RemoteProfileScheduling {}

@MainActor
protocol RemoteProfileEngineStoring: AnyObject {
    var profiles: [Profile] { get }

    func refreshProfiles() async
    func selectProfile(id: UUID) async
    func refreshProxies(presentErrors: Bool) async
    func presentRuntimeRecoveryFailure(_ error: UserFacingError)
}

extension EngineStore: RemoteProfileEngineStoring {}

@MainActor
@Observable
final class RemoteProfilesViewModel {
    private let service: any RemoteProfileServicing
    private let scheduler: any RemoteProfileScheduling
    private let engineStore: any RemoteProfileEngineStoring
    private(set) var updateStates: [UUID: SubscriptionUpdateState] = [:]
    private(set) var isCreating = false
    private(set) var lastError: UserFacingError?
    private(set) var configurationApplySequence = 0
    private(set) var updatingProfileIDs: Set<UUID> = []
    private var onScheduleChange: @MainActor @Sendable () -> Void = {}
    private var onConfigurationApplied: @MainActor @Sendable () -> Void = {}

    init(
        service: any RemoteProfileServicing,
        scheduler: any RemoteProfileScheduling,
        engineStore: any RemoteProfileEngineStoring
    ) {
        self.service = service
        self.scheduler = scheduler
        self.engineStore = engineStore
    }

    func create(_ request: RemoteProfileCreationRequest) async -> Profile? {
        guard !isCreating else { return nil }
        isCreating = true
        defer { isCreating = false }
        do {
            let profile = try await service.createRemoteProfile(request)
            await engineStore.refreshProfiles()
            let updateState = await service.updateState(for: profile.id)
            updateStates[profile.id] = updateState
            onScheduleChange()

            if case let .failed(error) = updateState {
                // The service deliberately keeps a failed first-time profile so
                // its URL and credentials remain editable. Do not make that
                // metadata-only record the active configuration: it has no YAML
                // document yet and cannot be rendered or applied safely.
                lastError = error
                return profile
            }

            await engineStore.selectProfile(id: profile.id)
            lastError = nil
            if case .succeeded = updateState {
                configurationApplied()
            }
            return profile
        } catch let failure as SubscriptionUpdateFailure {
            lastError = Self.error(for: failure)
        } catch {
            lastError = Self.error(for: .runtimeBuildFailed)
        }
        return nil
    }

    func update(_ profileID: UUID) async {
        guard updatingProfileIDs.insert(profileID).inserted else { return }
        updateStates[profileID] = .checking
        defer { updatingProfileIDs.remove(profileID) }
        guard let result = await scheduler.updateNow(profileID: profileID) else { return }
        if case .failure(.cancelled) = result.result {
            updateStates[profileID] = .idle
        } else {
            updateStates[profileID] = await service.updateState(for: profileID)
        }
        await engineStore.refreshProfiles()
        onScheduleChange()
        if case let .failed(error) = updateStates[profileID] {
            lastError = error
        } else {
            lastError = nil
            if configurationWasApplied(result) {
                configurationApplied()
            }
        }
    }

    func updateAll() async {
        let profileIDs = engineStore.profiles
            .filter { $0.sourceKind == .remoteSubscription }
            .map(\.id)
            .filter { !updatingProfileIDs.contains($0) }
        guard !profileIDs.isEmpty else { return }

        updatingProfileIDs.formUnion(profileIDs)
        for profileID in profileIDs {
            updateStates[profileID] = .checking
        }
        defer { updatingProfileIDs.subtract(profileIDs) }

        let results = await scheduler.updateAllNow(profileIDs: profileIDs)
        for result in results {
            if case .failure(.cancelled) = result.result {
                updateStates[result.profileID] = .idle
            } else {
                updateStates[result.profileID] = await service.updateState(for: result.profileID)
            }
        }
        await engineStore.refreshProfiles()
        onScheduleChange()

        if results.contains(where: configurationWasApplied) {
            configurationApplied()
        }
        lastError = results.lazy.compactMap { result -> UserFacingError? in
            guard case let .failure(failure) = result.result, failure != .cancelled else {
                return nil
            }
            if case let .failed(error) = self.updateStates[result.profileID] {
                return error
            }
            return Self.error(for: failure)
        }.first
    }

    func cancel(_ profileID: UUID) async {
        let schedulerIsUpdating = await scheduler.isUpdating(profileID)
        guard updatingProfileIDs.contains(profileID) || schedulerIsUpdating else { return }

        await scheduler.cancelUpdate(profileID)
        updateStates[profileID] = .idle
        updatingProfileIDs.remove(profileID)
        await engineStore.refreshProfiles()
        onScheduleChange()
        if lastError?.category == .subscription {
            lastError = nil
        }
    }

    func dismissError() {
        lastError = nil
    }

    func delete(_ profileID: UUID) async {
        do {
            await scheduler.profileDeleted(profileID)
            try await service.deleteProfile(profileID)
            updateStates.removeValue(forKey: profileID)
            await engineStore.refreshProfiles()
            lastError = nil
            onScheduleChange()
        } catch let failure as SubscriptionUpdateFailure {
            await scheduler.profileRestored(profileID)
            lastError = Self.error(for: failure)
        } catch {
            await scheduler.profileRestored(profileID)
            lastError = Self.error(for: .runtimeBuildFailed)
        }
    }

    func editableSettings(for profileID: UUID) async -> RemoteProfileEditableSettings? {
        do {
            let settings = try await service.editableSettings(for: profileID)
            lastError = nil
            return settings
        } catch let failure as SubscriptionUpdateFailure {
            lastError = Self.error(for: failure)
        } catch {
            lastError = Self.error(for: .secretMissing)
        }
        return nil
    }

    func edit(
        _ profileID: UUID,
        request: RemoteProfileEditRequest
    ) async -> Profile? {
        do {
            let profile = try await service.editRemoteProfile(
                profileID,
                request: request
            )
            await engineStore.refreshProfiles()
            updateStates[profileID] = await service.updateState(for: profileID)
            lastError = nil
            onScheduleChange()
            return profile
        } catch let failure as SubscriptionUpdateFailure {
            lastError = Self.error(for: failure)
        } catch {
            lastError = Self.error(for: .runtimeBuildFailed)
        }
        return nil
    }

    func runDue(networkAvailable: Bool, reason: SubscriptionUpdateReason) async {
        let profiles = engineStore.profiles
        let now = Date.now
        let dueProfileIDs = networkAvailable ? profiles.compactMap { profile -> UUID? in
            guard profile.sourceKind == .remoteSubscription,
                profile.remote?.autoUpdateEnabled == true,
                (profile.remote?.nextScheduledUpdateAt ?? .distantPast) <= now
            else { return nil }
            return profile.id
        } : []
        let newlyTrackedProfileIDs = Set(dueProfileIDs).subtracting(updatingProfileIDs)
        updatingProfileIDs.formUnion(newlyTrackedProfileIDs)
        for profileID in newlyTrackedProfileIDs {
            updateStates[profileID] = .checking
        }
        defer { updatingProfileIDs.subtract(newlyTrackedProfileIDs) }
        let results = await scheduler.runDueUpdates(
            profiles: profiles,
            at: now,
            networkAvailable: networkAvailable,
            reason: reason
        )
        for result in results {
            if case .failure(.cancelled) = result.result {
                updateStates[result.profileID] = .idle
            } else {
                updateStates[result.profileID] = await service.updateState(for: result.profileID)
            }
        }
        if results.contains(where: configurationWasApplied) {
            configurationApplied()
        }
        if !results.isEmpty { await engineStore.refreshProfiles() }
        onScheduleChange()
    }

    func refreshState(_ profileID: UUID) async {
        updateStates[profileID] = await service.updateState(for: profileID)
    }

    func nextScheduledUpdateDate() -> Date? {
        engineStore.profiles
            .filter {
                $0.sourceKind == .remoteSubscription
                    && $0.remote?.autoUpdateEnabled == true
            }
            .map { $0.remote?.nextScheduledUpdateAt ?? .distantPast }
            .min()
    }

    func setScheduleChangeHandler(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) {
        onScheduleChange = handler
    }

    func setConfigurationAppliedHandler(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) {
        onConfigurationApplied = handler
    }

    func refreshRuntimeProxyCatalog() async {
        await engineStore.refreshProxies(presentErrors: false)
    }

    func isUpdating(_ profileID: UUID) -> Bool {
        updatingProfileIDs.contains(profileID)
    }

    func presentRuntimeRecoveryFailure(_ error: UserFacingError) {
        lastError = error
        engineStore.presentRuntimeRecoveryFailure(error)
    }

    func suspendForUpdate() async {
        await scheduler.cancelAllUpdatesAndWait()
        for profileID in updatingProfileIDs {
            updateStates[profileID] = .idle
        }
        updatingProfileIDs.removeAll()
    }

    private func configurationWasApplied(
        _ result: SubscriptionScheduledResult
    ) -> Bool {
        guard case .success = result.result,
            case .succeeded = updateStates[result.profileID]
        else {
            return false
        }
        return true
    }

    private func configurationApplied() {
        configurationApplySequence &+= 1
        onConfigurationApplied()
    }

    private static func error(for failure: SubscriptionUpdateFailure) -> UserFacingError {
        UserFacingError(
            title: VelaL10n.string(
                "error.subscription.remoteProfile.title",
                defaultValue: "Remote Profile Error"
            ),
            message: localizedMessage(for: failure),
            technicalDetails: String(describing: failure),
            suggestedAction: VelaL10n.string(
                "error.subscription.remoteProfile.action",
                defaultValue: "Review the subscription settings and try again."
            ),
            isRetryable: failure != .authenticationFailed,
            category: .subscription,
            recoveryActions: [.retry, .editSubscription, .openDiagnostics]
        )
    }

    private static func localizedMessage(for failure: SubscriptionUpdateFailure) -> String {
        switch failure {
        case .secretMissing:
            VelaL10n.string(
                "error.subscription.secretMissing",
                defaultValue: "Subscription credentials are missing."
            )
        case .invalidURL, .invalidUserAgent:
            VelaL10n.string(
                "error.subscription.addressInvalid",
                defaultValue: "The subscription address or redirect policy is not valid."
            )
        case .unsupportedScheme, .insecureHTTPNotAllowed, .redirectLimitExceeded,
            .insecureRedirect:
            VelaL10n.string(
                "error.subscription.addressInvalid",
                defaultValue: "The subscription address or redirect policy is not valid."
            )
        case .authenticationFailed:
            VelaL10n.string(
                "error.subscription.authenticationFailed",
                defaultValue: "Subscription authentication failed."
            )
        case .accessDenied, .requestTimedOut, .notFound, .rateLimited, .serverError,
            .unexpectedHTTPStatus, .transportFailed:
            VelaL10n.string(
                "error.subscription.requestFailed",
                defaultValue: "The subscription server could not provide the profile."
            )
        case .responseTooLarge, .emptyResponse, .invalidEncoding:
            VelaL10n.string(
                "error.subscription.contentInvalid",
                defaultValue: "The subscription response is not a valid Mihomo configuration."
            )
        case .htmlResponse:
            VelaL10n.string(
                "error.subscription.htmlResponse",
                defaultValue: "The server returned HTML instead of Clash/Mihomo YAML. Confirm the URL is a direct subscription endpoint (use the raw file URL for GitHub), or try the Clash Verge User-Agent."
            )
        case .unsupportedFormat:
            VelaL10n.string(
                "error.subscription.unsupportedFormat",
                defaultValue: "The subscription is not Clash/Mihomo YAML. Vela does not convert Base64, proxy URI, Surge, or sing-box subscriptions."
            )
        case .missingProxySection:
            VelaL10n.string(
                "error.subscription.missingProxySection",
                defaultValue: "The YAML does not contain proxies or proxy-providers. Confirm the provider returned a Clash/Mihomo subscription."
            )
        case .yamlParsingFailed:
            VelaL10n.string(
                "error.subscription.yamlParsingFailed",
                defaultValue: "The subscription is not a valid YAML mapping."
            )
        case .runtimeBuildFailed, .configurationValidationFailed, .hotReloadFailed,
            .controllerDidNotRecover, .healthVerificationFailed:
            VelaL10n.string(
                "error.subscription.applyFailed",
                defaultValue: "Mihomo could not safely apply the updated configuration."
            )
        case .rollbackFailed, .profileMutationRecoveryFailed:
            VelaL10n.string(
                "error.subscription.recoveryFailed",
                defaultValue:
                    "Vela could not restore a consistent profile state after the update failed."
            )
        case .profileDeletionCleanupFailed:
            VelaL10n.string(
                "error.subscription.cleanupFailed",
                defaultValue:
                    "The subscription profile was deleted, but its private staged files could not be cleaned up."
            )
        case .cancelled:
            VelaL10n.string(
                "error.subscription.cancelled",
                defaultValue: "The subscription update was cancelled."
            )
        }
    }
}

/// Prevents scheduled remote-profile work from starting until an interrupted
/// runtime configuration transaction has been recovered successfully.
///
/// Recovery errors deliberately cross the UI boundary as stable codes only.
/// The underlying error may contain a journal path, profile YAML, or a secret,
/// so neither `localizedDescription` nor `String(describing:)` is exposed.
@MainActor
final class DailyDriverBootstrapGate {
    typealias Recover = @MainActor @Sendable () async throws -> Void
    typealias StartScheduling = @MainActor @Sendable (Bool) -> Void
    typealias PresentFailure = @MainActor @Sendable (UserFacingError) -> Void

    private let recover: Recover
    private let startScheduling: StartScheduling
    private let presentFailure: PresentFailure
    private var recoverySucceeded = false

    init(
        recover: @escaping Recover,
        startScheduling: @escaping StartScheduling,
        presentFailure: @escaping PresentFailure
    ) {
        self.recover = recover
        self.startScheduling = startScheduling
        self.presentFailure = presentFailure
    }

    @discardableResult
    func bootstrap(networkAvailable: Bool) async -> UserFacingError? {
        let error = await recoverPersistentTransactions()
        if error == nil {
            startSchedulingIfRecovered(networkAvailable: networkAvailable)
        }
        return error
    }

    @discardableResult
    func recoverPersistentTransactions() async -> UserFacingError? {
        do {
            try await recover()
            try Task.checkCancellation()
            recoverySucceeded = true
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            recoverySucceeded = false
            let userFacingError = Self.userFacingError(for: error)
            presentFailure(userFacingError)
            return userFacingError
        }
    }

    func startSchedulingIfRecovered(networkAvailable: Bool) {
        guard recoverySucceeded else { return }
        startScheduling(networkAvailable)
    }

    static func userFacingError(for error: any Error) -> UserFacingError {
        UserFacingError(
            title: VelaL10n.string(
                "error.configurationRecovery.title",
                defaultValue: "Configuration Recovery Needs Attention"
            ),
            message: VelaL10n.string(
                "error.configurationRecovery.message",
                defaultValue:
                    "Vela could not safely finish recovering an interrupted configuration change."
            ),
            technicalDetails: "Recovery code: \(recoveryCode(for: error))",
            suggestedAction: VelaL10n.string(
                "error.configurationRecovery.action",
                defaultValue:
                    "Open Diagnostics and copy the redacted recovery code. Scheduled remote profile updates remain paused until recovery succeeds on a later launch."
            ),
            isRetryable: true,
            category: .startup,
            recoveryActions: [.openDiagnostics, .copyRedactedDetails]
        )
    }

    private static func recoveryCode(for error: any Error) -> String {
        guard let transactionError = error as? RuntimeConfigTransactionError else {
            return "runtime-transaction-recovery-unexpected"
        }

        return switch transactionError {
        case .transactionAlreadyRunning:
            "runtime-transaction-recovery-busy"
        case .stagingFailed:
            "runtime-transaction-recovery-staging-failed"
        case .runtimeBuildFailed:
            "runtime-transaction-recovery-build-failed"
        case .executableResolutionFailed:
            "runtime-transaction-recovery-core-unavailable"
        case .configurationValidationFailed:
            "runtime-transaction-recovery-validation-failed"
        case .activeReplacementFailed:
            "runtime-transaction-recovery-replacement-failed"
        case .hotReloadFailed:
            "runtime-transaction-recovery-reload-failed"
        case .controllerDidNotRecover:
            "runtime-transaction-recovery-controller-unavailable"
        case .healthVerificationFailed:
            "runtime-transaction-recovery-health-failed"
        case .revisionCommitFailed:
            "runtime-transaction-recovery-commit-failed"
        case .rollbackFailed:
            "runtime-transaction-recovery-rollback-failed"
        case .journalCorrupt:
            "runtime-transaction-recovery-journal-invalid"
        case .recoveryFailed:
            "runtime-transaction-recovery-failed"
        }
    }
}

/// Keeps subscription updates resident when Vela runs menu-bar-only.
///
/// It owns exactly one deadline wait and sleeps until the next persisted
/// deadline. Profile, network and sleep/wake events cancel that wait and
/// recompute it; there is no periodic polling timer.
@MainActor
final class SubscriptionDeadlineDriver {
    typealias SleepUntil = @MainActor @Sendable (Date) async throws -> Void
    typealias NextDeadline = @MainActor @Sendable () -> Date?
    typealias RunDue = @MainActor @Sendable (
        Bool,
        SubscriptionUpdateReason
    ) async -> Void

    private let now: @MainActor @Sendable () -> Date
    private let sleepUntil: SleepUntil
    private let nextDeadline: NextDeadline
    private let runDue: RunDue
    private let minimumRefireInterval: TimeInterval
    private var deadlineTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var waitGeneration: UInt64 = 0
    private var pendingReason: SubscriptionUpdateReason?
    private var isStarted = false
    private var isSleeping = false
    private var networkAvailable = false

    private(set) var scheduledDeadline: Date?

    init(
        now: @escaping @MainActor @Sendable () -> Date = { .now },
        sleepUntil: @escaping SleepUntil = { deadline in
            let interval = deadline.timeIntervalSinceNow
            if interval > 0 {
                try await Task.sleep(for: .seconds(interval))
            }
        },
        nextDeadline: @escaping NextDeadline,
        runDue: @escaping RunDue,
        minimumRefireInterval: TimeInterval = 60
    ) {
        self.now = now
        self.sleepUntil = sleepUntil
        self.nextDeadline = nextDeadline
        self.runDue = runDue
        self.minimumRefireInterval = max(1, minimumRefireInterval)
    }

    func start(networkAvailable: Bool) {
        self.networkAvailable = networkAvailable
        guard !isStarted else {
            scheduleNextDeadline()
            return
        }
        isStarted = true
        requestRun(reason: .scheduled)
    }

    func networkAvailabilityChanged(_ available: Bool) {
        let wasAvailable = networkAvailable
        networkAvailable = available
        guard isStarted else { return }

        if !available {
            cancelDeadlineWait()
        } else if !wasAvailable {
            requestRun(reason: .networkRecovery)
        }
    }

    func willSleep() {
        isSleeping = true
        cancelDeadlineWait()
    }

    func didWake() {
        isSleeping = false
        guard isStarted else { return }
        requestRun(reason: .wake)
    }

    func profilesDidChange() {
        guard isStarted else { return }
        if runTask == nil {
            scheduleNextDeadline()
        }
    }

    func stop() async {
        isStarted = false
        pendingReason = nil
        cancelDeadlineWait()
        let activeRun = runTask
        runTask = nil
        activeRun?.cancel()
        if let activeRun { await activeRun.value }
    }

    private func requestRun(reason: SubscriptionUpdateReason) {
        cancelDeadlineWait()
        guard isStarted, !isSleeping else { return }
        guard runTask == nil else {
            pendingReason = reason
            return
        }

        let available = networkAvailable
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDue(available, reason)
            self.completeRun()
        }
    }

    private func completeRun() {
        runTask = nil
        guard isStarted, !Task.isCancelled else { return }
        if let pendingReason {
            self.pendingReason = nil
            requestRun(reason: pendingReason)
        } else {
            scheduleNextDeadline()
        }
    }

    private func scheduleNextDeadline() {
        cancelDeadlineWait()
        guard isStarted, networkAvailable, !isSleeping,
            let persistedDeadline = nextDeadline()
        else { return }

        let earliestRefire = now().addingTimeInterval(minimumRefireInterval)
        let deadline = max(persistedDeadline, earliestRefire)
        scheduledDeadline = deadline
        waitGeneration &+= 1
        let generation = waitGeneration
        deadlineTask = Task { @MainActor [weak self, sleepUntil] in
            do {
                try await sleepUntil(deadline)
                guard !Task.isCancelled else { return }
                self?.deadlineReached(generation: generation)
            } catch is CancellationError {
                // A newer lifecycle/profile event owns the next wait.
            } catch {
                guard !Task.isCancelled else { return }
                self?.deadlineReached(generation: generation)
            }
        }
    }

    private func deadlineReached(generation: UInt64) {
        guard generation == waitGeneration else { return }
        deadlineTask = nil
        scheduledDeadline = nil
        requestRun(reason: .scheduled)
    }

    private func cancelDeadlineWait() {
        waitGeneration &+= 1
        deadlineTask?.cancel()
        deadlineTask = nil
        scheduledDeadline = nil
    }
}

@MainActor
@Observable
final class ProvidersViewModel {
    private let service: ProviderManagementService
    private let onCatalogMutation: @MainActor @Sendable (ProviderKind) async -> Void
    private(set) var snapshot: ProviderCatalogSnapshot = .empty
    private(set) var isLoading = false
    private(set) var hasReceivedSnapshot = false
    private(set) var runningOperations: Set<ProviderOperationKey> = []
    private(set) var lastError: ProviderFailure?
    private(set) var lastBatchSummary: ProviderBatchSummary?

    init(
        service: ProviderManagementService,
        onCatalogMutation: @escaping @MainActor @Sendable (ProviderKind) async -> Void = { _ in }
    ) {
        self.service = service
        self.onCatalogMutation = onCatalogMutation
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await service.refresh()
            hasReceivedSnapshot = true
            lastError = nil
        } catch let failure as ProviderFailure {
            lastError = failure
        } catch {
            lastError = .fetchFailed
        }
    }

    func update(_ key: ProviderOperationKey) async {
        guard runningOperations.insert(key).inserted else { return }
        lastBatchSummary = nil
        defer { runningOperations.remove(key) }
        do {
            try await service.update(key)
            snapshot = try await service.refresh()
            hasReceivedSnapshot = true
            await onCatalogMutation(key.kind)
            lastError = nil
        } catch let failure as ProviderFailure {
            lastError = failure
        } catch {
            lastError = .updateFailed
        }
    }

    func healthCheck(named name: String) async {
        let key = ProviderOperationKey(kind: .proxy, name: name)
        guard runningOperations.insert(key).inserted else { return }
        lastBatchSummary = nil
        defer { runningOperations.remove(key) }
        do {
            try await service.healthCheckProxyProvider(named: name)
            snapshot = try await service.refresh()
            hasReceivedSnapshot = true
            lastError = nil
        } catch let failure as ProviderFailure {
            lastError = failure
        } catch {
            lastError = .healthCheckFailed
        }
    }

    func updateAll() async {
        let keys = snapshot.proxyProviders.keys.map {
            ProviderOperationKey(kind: .proxy, name: $0)
        } + snapshot.ruleProviders.keys.map {
            ProviderOperationKey(kind: .rule, name: $0)
        }
        guard !keys.isEmpty else { return }
        lastBatchSummary = nil
        runningOperations.formUnion(keys)
        let results = await service.updateAll(keys, maximumConcurrent: 2)
        runningOperations.subtract(keys)
        await refresh()
        let summary = ProviderBatchSummary(operation: .update, results: results)
        lastBatchSummary = summary
        if summary.failedCount > 0 {
            lastError = .updateFailed
        }
        await onCatalogMutation(.proxy)
        await onCatalogMutation(.rule)
    }

    func dismissBatchSummary() {
        lastBatchSummary = nil
    }

    func healthCheckAll() async {
        let keys = snapshot.proxyProviders.keys.sorted().map {
            ProviderOperationKey(kind: .proxy, name: $0)
        }
        guard !keys.isEmpty else { return }

        lastBatchSummary = nil
        var iterator = keys.makeIterator()
        var results: [ProviderBatchResult] = []
        let service = service

        await withTaskGroup(of: ProviderBatchResult.self) { group in
            for _ in 0 ..< 2 {
                guard !Task.isCancelled, let key = iterator.next() else { break }
                runningOperations.insert(key)
                group.addTask {
                    await Self.performHealthCheck(key, service: service)
                }
            }

            while let result = await group.next() {
                results.append(result)
                runningOperations.remove(result.key)
                if !Task.isCancelled, let next = iterator.next() {
                    runningOperations.insert(next)
                    group.addTask {
                        await Self.performHealthCheck(next, service: service)
                    }
                }
            }
        }

        while let key = iterator.next() {
            results.append(ProviderBatchResult(
                key: key,
                result: .failure(.cancelledBeforeStart)
            ))
        }
        runningOperations.subtract(keys)
        results.sort { $0.key.name < $1.key.name }

        await refresh()
        let summary = ProviderBatchSummary(operation: .healthCheck, results: results)
        lastBatchSummary = summary
        if summary.failedCount > 0 {
            lastError = .healthCheckFailed
        }
    }

    private nonisolated static func performHealthCheck(
        _ key: ProviderOperationKey,
        service: ProviderManagementService
    ) async -> ProviderBatchResult {
        guard !Task.isCancelled else {
            return ProviderBatchResult(key: key, result: .failure(.cancelledBeforeStart))
        }
        do {
            try await service.healthCheckProxyProvider(named: key.name)
            return ProviderBatchResult(key: key, result: .success(()))
        } catch let failure as ProviderFailure {
            return ProviderBatchResult(key: key, result: .failure(failure))
        } catch is CancellationError {
            return ProviderBatchResult(key: key, result: .failure(.cancelledResultUnknown))
        } catch {
            return ProviderBatchResult(key: key, result: .failure(.healthCheckFailed))
        }
    }
}

nonisolated enum ProviderBatchOperation: Equatable, Sendable {
    case update
    case healthCheck
}

nonisolated struct ProviderBatchOutcome: Equatable, Sendable {
    let operation: ProviderBatchOperation
    let result: Result<Void, ProviderFailure>

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.operation, lhs.result, rhs.operation, rhs.result) {
        case let (lhsOperation, .success, rhsOperation, .success):
            lhsOperation == rhsOperation
        case let (lhsOperation, .failure(lhsFailure), rhsOperation, .failure(rhsFailure)):
            lhsOperation == rhsOperation && lhsFailure == rhsFailure
        default:
            false
        }
    }
}

nonisolated struct ProviderBatchSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let generatedAt: Date
    let operation: ProviderBatchOperation
    let results: [ProviderBatchResult]

    init(
        id: UUID = UUID(),
        generatedAt: Date = .now,
        operation: ProviderBatchOperation,
        results: [ProviderBatchResult]
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.operation = operation
        self.results = results
    }

    func outcome(for key: ProviderOperationKey) -> ProviderBatchOutcome? {
        guard let result = results.first(where: { $0.key == key }) else { return nil }
        return ProviderBatchOutcome(operation: operation, result: result.result)
    }

    var succeededCount: Int {
        results.count { if case .success = $0.result { true } else { false } }
    }

    var skippedCount: Int {
        results.count {
            if case .failure(.cancelledBeforeStart) = $0.result { true } else { false }
        }
    }

    var failedCount: Int {
        results.count - succeededCount - skippedCount
    }
}

@MainActor
@Observable
final class ConnectionsViewModel {
    private enum StreamConsumer: Hashable {
        case connectionsPage
        case overviewPage
    }

    private let service: ConnectionsService
    private let stream: any MihomoConnectionsStreaming
    private let now: @Sendable () -> Date
    private let localeIdentifier: @Sendable () -> String
    private let streamRestartDelay: @Sendable (Int) -> Duration
    private let presentationPipeline = ConnectionsPresentationPipeline()
    private var streamTask: Task<Void, Never>?
    private var streamTaskToken: UUID?
    private var streamRestartTask: Task<Void, Never>?
    private var streamRestartAttempt = 0
    private var filterTask: Task<Void, Never>?
    private var filterGeneration: UInt64 = 0
    private var snapshotRevision: UInt64 = 0
    private var generation = ConfigurationGeneration()
    private var pendingSnapshot: ConnectionsSnapshot?
    private var streamConsumers: Set<StreamConsumer> = []
    private var isEngineRunning = false
    private var hasReceivedSnapshot = false
    private var selectionConfigurationID: UUID?
    @ObservationIgnored private var visibleRowsByID: [String: ConnectionRowModel] = [:]
#if DEBUG
    private var debugPhaseOverride: ConnectionsWorkspacePhase?
    private(set) var isDebugFixtureReady = false
#endif

    private(set) var snapshot = ConnectionsSnapshot(
        downloadTotal: 0,
        uploadTotal: 0,
        connections: [],
        memory: nil
    )
    private(set) var visibleRows: [ConnectionRowModel] = []
    private(set) var metrics = ConnectionMetricsPresentation.empty
    private(set) var availableProtocols: [String] = []
    private(set) var availableNetworks: [String] = []
    private(set) var availableProcesses: [String] = []
    private(set) var availableRules: [String] = []
    private(set) var appliedSnapshotRevision: UInt64 = 0
    private(set) var isStreaming = false
    private(set) var isRefreshing = false
    private(set) var pendingCloseIDs: Set<String> = []
    private(set) var pendingMutation: PendingConnectionMutation?
    private(set) var isCloseAllPending = false
    private(set) var lastSuccessfulRefreshAt: Date?
    private(set) var lastError: ConnectionsFailure?
    private(set) var isPaused = false
    var searchText = "" {
        didSet { scheduleFilter(debounced: true) }
    }
    var protocolFilter: String? {
        didSet { scheduleFilter() }
    }
    var networkFilter: String? {
        didSet { scheduleFilter() }
    }
    var processFilter: String? {
        didSet { scheduleFilter() }
    }
    var ruleFilter: String? {
        didSet { scheduleFilter() }
    }
    var sortField: ConnectionSortField = .host {
        didSet { scheduleFilter() }
    }
    var sortAscending = true {
        didSet { scheduleFilter() }
    }
    var selectedConnectionID: String? {
        didSet {
            if selectedConnectionID == nil {
                selectionConfigurationID = nil
            } else if oldValue != selectedConnectionID {
                selectionConfigurationID = generation.id
            }
            updateSelectedRow()
        }
    }
    private(set) var selectedRow: ConnectionRowModel?
    private(set) var selectedStartedAtText: String?

    var selectedConnection: MihomoConnection? {
        selectedRow?.connection
    }

    var hasActiveFilters: Bool {
        protocolFilter != nil || networkFilter != nil
            || processFilter != nil || ruleFilter != nil
    }

    var presentation: ConnectionsPresentationSnapshot {
        ConnectionsPresentationFactory.make(
            configurationID: generation.id,
            snapshotRevision: appliedSnapshotRevision,
            phase: presentationPhase,
            rows: visibleRows,
            selectedConnectionID: selectedConnectionID,
            selectionConfigurationID: selectionConfigurationID,
            metrics: metrics,
            availableProtocols: availableProtocols,
            lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
            referenceDate: now(),
            pendingMutation: pendingMutation,
            lastError: lastError,
            isPaused: isPaused
        )
    }

    private var presentationPhase: ConnectionsWorkspacePhase {
#if DEBUG
        if let debugPhaseOverride { return debugPhaseOverride }
#endif
        if pendingMutation != nil || isCloseAllPending { return .pendingMutation }
        if !isEngineRunning {
            return hasReceivedSnapshot ? .offlineWithSnapshot : .offlineWithoutSnapshot
        }
        if isRefreshing {
            return hasReceivedSnapshot ? .refreshing : .loading
        }
        if let lastError {
            _ = lastError
            return hasReceivedSnapshot ? .partialFailure : .failure
        }
        guard hasReceivedSnapshot else { return .loading }
        if snapshot.connections.isEmpty { return .empty }
        return isStreaming ? .loaded : .stale
    }

    init(
        service: ConnectionsService,
        stream: any MihomoConnectionsStreaming,
        now: @escaping @Sendable () -> Date = { .now },
        localeIdentifier: @escaping @Sendable () -> String = {
            Locale.autoupdatingCurrent.identifier
        },
        streamRestartDelay: @escaping @Sendable (Int) -> Duration = { attempt in
            switch attempt {
            case 0: .seconds(1)
            case 1: .seconds(2)
            case 2: .seconds(4)
            case 3: .seconds(8)
            default: .seconds(15)
            }
        }
    ) {
        self.service = service
        self.stream = stream
        self.now = now
        self.localeIdentifier = localeIdentifier
        self.streamRestartDelay = streamRestartDelay
    }

    func viewDidAppear() {
        setStreamConsumer(.connectionsPage, visible: true)
    }

    func viewDidDisappear() {
        setStreamConsumer(.connectionsPage, visible: false)
    }

    func overviewDidAppear() {
        setStreamConsumer(.overviewPage, visible: true)
    }

    func overviewDidDisappear() {
        setStreamConsumer(.overviewPage, visible: false)
    }

    func engineRunningChanged(_ running: Bool) {
        isEngineRunning = running
        if running, hasVisibleStreamConsumer {
            start()
        } else if !running {
            // Keep a verified last-good snapshot as explicitly stale/offline
            // evidence. A configuration-generation change still clears it.
            stop(clearSnapshot: false)
        }
    }

    func start() {
        guard hasVisibleStreamConsumer, isEngineRunning else { return }
        guard streamTask == nil else { return }
        streamRestartTask?.cancel()
        streamRestartTask = nil
        let taskToken = UUID()
        streamTaskToken = taskToken
        isStreaming = true
        let generation = self.generation
        streamTask = Task { [weak self] in
            guard let self else { return }
            guard self.streamTaskToken == taskToken, !Task.isCancelled else { return }
            do {
                for try await event in stream.snapshots(generation: generation) {
                    guard self.streamTaskToken == taskToken else { return }
                    guard event.generation == self.generation else { continue }
                    if self.isPaused {
                        self.pendingSnapshot = event.snapshot
                    } else {
                        self.acceptSnapshot(event.snapshot)
                    }
                    self.streamRestartAttempt = 0
                    self.lastError = nil
                }
            } catch is CancellationError {
                // Deliberate stop.
            } catch {
                if self.streamTaskToken == taskToken {
                    self.lastError = error as? ConnectionsFailure ?? .streamUnavailable
                }
            }
            let shouldRestart = !Task.isCancelled
                && self.streamTaskToken == taskToken
                && self.hasVisibleStreamConsumer
                && self.isEngineRunning
            guard self.streamTaskToken == taskToken else { return }
            self.streamTaskToken = nil
            self.isStreaming = false
            self.streamTask = nil
            if shouldRestart {
                self.scheduleStreamRestart()
            }
        }
    }

    func stop(clearSnapshot: Bool = false) {
        let task = streamTask
        let restartTask = streamRestartTask
        streamTaskToken = nil
        streamTask = nil
        streamRestartTask = nil
        task?.cancel()
        restartTask?.cancel()
        streamRestartAttempt = 0
        filterTask?.cancel()
        filterTask = nil
        isStreaming = false
        if clearSnapshot {
            snapshot = ConnectionsSnapshot(
                downloadTotal: 0,
                uploadTotal: 0,
                connections: [],
                memory: nil
            )
            visibleRows = []
            visibleRowsByID = [:]
            metrics = .empty
            availableProtocols = []
            availableNetworks = []
            availableProcesses = []
            availableRules = []
            selectedConnectionID = nil
            selectedRow = nil
            selectedStartedAtText = nil
            pendingSnapshot = nil
            hasReceivedSnapshot = false
            lastSuccessfulRefreshAt = nil
            pendingMutation = nil
            pendingCloseIDs = []
            isCloseAllPending = false
            lastError = nil
            isPaused = false
            isRefreshing = false
        }
    }

    private var hasVisibleStreamConsumer: Bool {
        !streamConsumers.isEmpty
    }

    private func setStreamConsumer(_ consumer: StreamConsumer, visible: Bool) {
        let wasVisible = hasVisibleStreamConsumer
        if visible {
            streamConsumers.insert(consumer)
        } else {
            streamConsumers.remove(consumer)
        }

        if hasVisibleStreamConsumer {
            if !wasVisible, isEngineRunning {
                start()
            }
        } else if wasVisible {
            stop()
        }
    }

    private func scheduleStreamRestart() {
        guard hasVisibleStreamConsumer, isEngineRunning else { return }
        guard streamTask == nil, streamRestartTask == nil else { return }

        let attempt = streamRestartAttempt
        streamRestartAttempt = min(streamRestartAttempt + 1, 4)
        let delay = streamRestartDelay(attempt)
        streamRestartTask = Task { @MainActor [weak self] in
            do {
                if delay == .zero {
                    await Task.yield()
                } else {
                    try await Task.sleep(for: delay)
                }
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.streamRestartTask = nil
            self.start()
        }
    }

#if DEBUG
    func installVisualFixture(
        snapshot fixtureSnapshot: ConnectionsSnapshot?,
        phase: ConnectionsWorkspacePhase,
        selectedConnectionID: String?,
        lastSuccessfulRefreshAt: Date?,
        error: ConnectionsFailure?,
        pendingMutationPhase: ConnectionMutationPhase? = nil
    ) async {
        isDebugFixtureReady = false
        debugPhaseOverride = phase
        stop(clearSnapshot: true)

        if let fixtureSnapshot {
            snapshot = fixtureSnapshot
            hasReceivedSnapshot = true
            self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
            snapshotRevision &+= 1
            let request = ConnectionsProcessingRequest(
                snapshotRevision: snapshotRevision,
                snapshot: fixtureSnapshot,
                query: "",
                filters: ConnectionFilterSelection(
                    protocolName: nil,
                    network: nil,
                    process: nil,
                    rule: nil
                ),
                sort: ConnectionSortSelection(field: .download, ascending: false),
                now: now(),
                localeIdentifier: localeIdentifier()
            )
            if let result = await presentationPipeline.process(request) {
                apply(result)
            }
        }

        self.selectedConnectionID = selectedConnectionID
        lastError = error
        if let pendingMutationPhase,
           let selectedConnectionID
        {
            pendingCloseIDs = [selectedConnectionID]
            pendingMutation = PendingConnectionMutation(
                targetConnectionID: selectedConnectionID,
                configurationID: generation.id,
                phase: pendingMutationPhase,
                startedAt: now()
            )
        }
        isDebugFixtureReady = true
    }
#endif

    func setPaused(_ paused: Bool) async {
        isPaused = paused
        if !paused, let pendingSnapshot {
            self.pendingSnapshot = nil
            acceptSnapshot(pendingSnapshot)
        }
    }

    func configurationDidChange(_ newGeneration: ConfigurationGeneration) {
        let shouldRestart = streamTask != nil
        generation = newGeneration
        stop(clearSnapshot: true)
        if shouldRestart, hasVisibleStreamConsumer, isEngineRunning {
            start()
        }
    }

    func refreshSnapshot() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            acceptSnapshot(try await service.snapshot())
        } catch let failure as ConnectionsFailure {
            lastError = failure
        } catch {
            lastError = .streamUnavailable
        }
    }

    func closeConnection(id: String) async {
        guard pendingMutation == nil,
              selectedConnectionID == id,
              visibleRowsByID[id] != nil
        else {
            return
        }
        let configurationID = generation.id
        let startedAt = now()
        pendingCloseIDs.insert(id)
        pendingMutation = PendingConnectionMutation(
            targetConnectionID: id,
            configurationID: configurationID,
            phase: .preparing,
            startedAt: startedAt
        )
        defer {
            pendingCloseIDs.remove(id)
            pendingMutation = nil
        }
        await Task.yield()
        guard generation.id == configurationID,
              selectedConnectionID == id,
              visibleRowsByID[id] != nil
        else {
            return
        }
        pendingMutation = PendingConnectionMutation(
            targetConnectionID: id,
            configurationID: configurationID,
            phase: .closing,
            startedAt: startedAt
        )
        do {
            try await service.closeConnection(id: id)
            guard generation.id == configurationID else { return }
            pendingMutation = PendingConnectionMutation(
                targetConnectionID: id,
                configurationID: configurationID,
                phase: .committing,
                startedAt: startedAt
            )
            await refreshSnapshot()
        } catch let failure as ConnectionsFailure {
            pendingMutation = PendingConnectionMutation(
                targetConnectionID: id,
                configurationID: configurationID,
                phase: .rollingBack,
                startedAt: startedAt
            )
            lastError = failure
        } catch {
            pendingMutation = PendingConnectionMutation(
                targetConnectionID: id,
                configurationID: configurationID,
                phase: .rollingBack,
                startedAt: startedAt
            )
            lastError = .closeFailed
        }
    }

    func closeAll() async {
        guard !isCloseAllPending,
              presentation.actions.canCloseAll
        else {
            return
        }
        isCloseAllPending = true
        defer { isCloseAllPending = false }
        do {
            try await service.closeAll()
            await refreshSnapshot()
        } catch let failure as ConnectionsFailure {
            lastError = failure
        } catch {
            lastError = .closeAllFailed
        }
    }

    func clearFilters() {
        protocolFilter = nil
        networkFilter = nil
        processFilter = nil
        ruleFilter = nil
    }

    func processingDiagnostics() async -> ConnectionsProcessingDiagnostics {
        await presentationPipeline.diagnostics()
    }

    private func acceptSnapshot(_ snapshot: ConnectionsSnapshot) {
        self.snapshot = snapshot
        hasReceivedSnapshot = true
        lastSuccessfulRefreshAt = now()
        lastError = nil
        snapshotRevision &+= 1
        scheduleFilter()
    }

    private func scheduleFilter(debounced: Bool = false) {
        filterGeneration &+= 1
        let generation = filterGeneration
        filterTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filters = ConnectionFilterSelection(
            protocolName: protocolFilter,
            network: networkFilter,
            process: processFilter,
            rule: ruleFilter
        )
        let sort = ConnectionSortSelection(field: sortField, ascending: sortAscending)
        let request = ConnectionsProcessingRequest(
            snapshotRevision: snapshotRevision,
            snapshot: snapshot,
            query: query,
            filters: filters,
            sort: sort,
            now: now(),
            localeIdentifier: localeIdentifier()
        )
        let pipeline = presentationPipeline
        filterTask = Task { @MainActor [weak self] in
            if debounced {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard let result = await pipeline.process(request) else { return }
            guard !Task.isCancelled,
                let self,
                generation == self.filterGeneration
            else { return }
            self.apply(result)
        }
    }

    private func apply(_ result: ConnectionsProcessingResult) {
        visibleRows = result.rows
        visibleRowsByID = result.rowsByID
        availableProtocols = result.options.protocols
        availableNetworks = result.options.networks
        availableProcesses = result.options.processes
        availableRules = result.options.rules
        metrics = result.metrics
        appliedSnapshotRevision = result.snapshotRevision
        updateSelectedRow()
    }

    private func updateSelectedRow() {
        guard let selectedConnectionID,
              selectionConfigurationID == generation.id,
              let row = visibleRowsByID[selectedConnectionID]
        else {
            if selectedConnectionID != nil {
                self.selectedConnectionID = nil
            }
            selectedRow = nil
            selectedStartedAtText = nil
            return
        }
        selectedRow = row
        selectedStartedAtText = row.startedAtText
    }
}

nonisolated private extension Comparable {
    func comparison(to other: Self) -> ComparisonResult {
        if self < other { return .orderedAscending }
        if self > other { return .orderedDescending }
        return .orderedSame
    }
}

@MainActor
@Observable
final class DataSettingsViewModel {
    private let geoService: GeoDataService
    private let launchAtLogin: any LaunchAtLoginManaging
    private let onGeoUpdated: @MainActor @Sendable () async -> Void
    private(set) var geoState: GeoUpdateState = .idle
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    private(set) var lastLaunchAtLoginError: LaunchAtLoginFailure?
    private var geoUpdateTask: Task<Void, Never>?
    private var geoUpdateGeneration: UUID?

    var isGeoUpdateInFlight: Bool {
        geoUpdateTask != nil
    }

    init(
        geoService: GeoDataService,
        launchAtLogin: any LaunchAtLoginManaging,
        onGeoUpdated: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.geoService = geoService
        self.launchAtLogin = launchAtLogin
        self.onGeoUpdated = onGeoUpdated
        launchAtLoginStatus = launchAtLogin.status
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = launchAtLogin.status
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try launchAtLogin.register()
            } else {
                try launchAtLogin.unregister()
            }
            lastLaunchAtLoginError = nil
        } catch let failure as LaunchAtLoginFailure {
            lastLaunchAtLoginError = failure
        } catch {
            lastLaunchAtLoginError = enabled ? .registerFailed : .unregisterFailed
        }
        refreshLaunchAtLoginStatus()
    }

    func openLoginItemsSettings() {
        launchAtLogin.openSystemSettings()
    }

    func updateGeoData() async {
        guard geoState != .updating else { return }
        geoState = .updating
        do {
            try await geoService.update()
        } catch {
            // The service owns the precise result, including unknown-after-cancel.
        }
        geoState = await geoService.currentState()
        if case .succeeded = geoState {
            await onGeoUpdated()
        }
    }

    func startGeoDataUpdate() {
        guard geoUpdateTask == nil, geoState != .updating else { return }
        let generation = UUID()
        geoUpdateGeneration = generation
        geoUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.updateGeoData()
            guard self.geoUpdateGeneration == generation else { return }
            self.geoUpdateTask = nil
            self.geoUpdateGeneration = nil
        }
    }

    func cancelGeoUpdate() {
        guard let geoUpdateTask else { return }
        geoState = .resultUnknown
        geoUpdateTask.cancel()
    }

    func suspendForUpdate() async {
        guard let geoUpdateTask else { return }
        geoState = .resultUnknown
        geoUpdateTask.cancel()
        _ = await geoUpdateTask.value
        self.geoUpdateTask = nil
        geoUpdateGeneration = nil
        geoState = await geoService.currentState()
    }
}

@MainActor
@Observable
final class ConfigurationEditorViewModel {
    private let store: ConfigurationOverrideStore
    private let forcedFields: [ConfigurationForcedField]
    private var profileSelectionGeneration: UInt64 = 0
    private var previewGeneration: UInt64 = 0
    private var loadedProfileID: UUID?
    private(set) var profileID: UUID?
    var draft = ProfileStructuredOverrides()
    private(set) var saved = ProfileStructuredOverrides()
    private(set) var preview: ConfigurationPreview?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var configurationApplySequence = 0

    var hasChanges: Bool { draft != saved }
    var canSave: Bool {
        profileID != nil && hasChanges && preview?.validation.isValid == true && !isSaving
    }

    init(
        store: ConfigurationOverrideStore,
        forcedFields: [ConfigurationForcedField]
    ) {
        self.store = store
        self.forcedFields = forcedFields
    }

    func selectProfile(_ id: UUID?) async {
        guard id != profileID || loadedProfileID != id else { return }
        profileSelectionGeneration &+= 1
        previewGeneration &+= 1
        let selectionGeneration = profileSelectionGeneration
        profileID = id
        loadedProfileID = nil
        preview = nil
        errorMessage = nil
        guard let id else {
            draft = ProfileStructuredOverrides()
            saved = draft
            return
        }
        isLoading = true
        defer {
            if selectionGeneration == profileSelectionGeneration {
                isLoading = false
            }
        }
        do {
            let value = try await store.load(for: id)
            try Task.checkCancellation()
            guard selectionGeneration == profileSelectionGeneration,
                profileID == id
            else {
                throw CancellationError()
            }
            draft = value
            saved = value
            try await updatePreview()
            guard selectionGeneration == profileSelectionGeneration,
                profileID == id
            else {
                throw CancellationError()
            }
            loadedProfileID = id
        } catch is CancellationError {
            return
        } catch {
            guard selectionGeneration == profileSelectionGeneration,
                profileID == id
            else { return }
            errorMessage = VelaL10n.string(
                "error.configurationEditor.load",
                defaultValue: "The configuration overrides could not be loaded."
            )
        }
    }

    func updatePreview() async throws {
        guard let profileID else { return }
        previewGeneration &+= 1
        let generation = previewGeneration
        let draft = self.draft
        do {
            let resolvedPreview = try await store.preview(
                draft,
                for: profileID,
                forcedFields: forcedFields
            ).preview
            try Task.checkCancellation()
            guard generation == previewGeneration,
                self.profileID == profileID,
                self.draft == draft
            else {
                throw CancellationError()
            }
            preview = resolvedPreview
            errorMessage = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard generation == previewGeneration,
                self.profileID == profileID,
                self.draft == draft
            else {
                throw CancellationError()
            }
            preview = nil
            errorMessage = VelaL10n.string(
                "error.configurationEditor.preview",
                defaultValue: "The configuration preview could not be generated."
            )
            throw error
        }
    }

    func runnableYAMLForExport() async throws -> String {
        guard let profileID else {
            throw ConfigurationOverrideStoreError.profileNotFound
        }
        do {
            let result = try await store.preview(
                draft,
                for: profileID,
                forcedFields: forcedFields
            )
            errorMessage = nil
            return result.finalYAML
        } catch {
            errorMessage = VelaL10n.string(
                "error.configurationEditor.export",
                defaultValue: "The runnable configuration could not be prepared for export."
            )
            throw error
        }
    }

    func rawYAMLForEditing(profileID: UUID) async throws -> String {
        try await store.rawConfiguration(for: profileID)
    }

    func saveRawYAML(
        _ yaml: String,
        profileID: UUID,
        sourceFileName: String
    ) async throws {
        do {
            _ = try await store.saveRawConfiguration(
                yaml,
                for: profileID,
                sourceFileName: sourceFileName
            )
        } catch {
            if self.profileID == profileID {
                errorMessage = VelaL10n.string(
                    "error.configurationEditor.rawSave",
                    defaultValue: "The configuration file could not be saved."
                )
            }
            throw error
        }

        configurationApplySequence &+= 1
        if self.profileID == profileID {
            try? await updatePreview()
        } else {
            errorMessage = nil
        }
    }

    func addRule(_ rule: String, profileID: UUID) async throws {
        let current = try await store.load(for: profileID)
        var updated = current
        updated.prependedRules.append(rule)
        let result = try await store.save(
            updated,
            for: profileID,
            forcedFields: forcedFields
        )
        if self.profileID == profileID {
            draft = result.normalizedOverrides
            saved = result.normalizedOverrides
            preview = result.preview
            errorMessage = nil
        }
        configurationApplySequence &+= 1
    }

    func save() async {
        guard let profileID, canSave else { return }
        previewGeneration &+= 1
        isSaving = true
        defer { isSaving = false }
        do {
            let result = try await store.save(
                draft,
                for: profileID,
                forcedFields: forcedFields
            )
            guard self.profileID == profileID else { return }
            draft = result.normalizedOverrides
            saved = result.normalizedOverrides
            preview = result.preview
            errorMessage = nil
            configurationApplySequence &+= 1
        } catch {
            errorMessage = VelaL10n.string(
                "error.configurationEditor.save",
                defaultValue: "The configuration overrides could not be saved."
            )
        }
    }

    func discardChanges() async {
        draft = saved
        try? await updatePreview()
    }
}

/// Owns runtime-catalog invalidation independently of any SwiftUI window.
///
/// Connection generation changes are synchronous so an old WebSocket snapshot
/// cannot be accepted after a configuration commit. Controller-backed catalog
/// requests are drained by one resident task. Multiple commits arriving before
/// the task gets CPU time are coalesced to the newest generation.
@MainActor
final class DailyDriverCatalogRefreshCoordinator {
    typealias ResetConnections = @MainActor @Sendable (ConfigurationGeneration) -> Void
    typealias RefreshRules = @MainActor @Sendable (ConfigurationGeneration) async -> Void
    typealias RefreshCatalog = @MainActor @Sendable () async -> Void

    private let resetConnections: ResetConnections
    private let refreshRules: RefreshRules
    private let refreshProviders: RefreshCatalog
    private let refreshProxies: RefreshCatalog
    private var pendingGeneration: ConfigurationGeneration?
    private var refreshTask: Task<Void, Never>?

    init(
        resetConnections: @escaping ResetConnections,
        refreshRules: @escaping RefreshRules,
        refreshProviders: @escaping RefreshCatalog,
        refreshProxies: @escaping RefreshCatalog
    ) {
        self.resetConnections = resetConnections
        self.refreshRules = refreshRules
        self.refreshProviders = refreshProviders
        self.refreshProxies = refreshProxies
    }

    @discardableResult
    func configurationDidChange() -> ConfigurationGeneration {
        let generation = ConfigurationGeneration()
        resetConnections(generation)
        pendingGeneration = generation
        startRefreshTaskIfNeeded()
        return generation
    }

    func waitUntilIdle() async {
        while let refreshTask {
            await refreshTask.value
        }
    }

    func stop() async {
        pendingGeneration = nil
        let task = refreshTask
        refreshTask = nil
        task?.cancel()
        if let task {
            await task.value
        }
    }

    private func startRefreshTaskIfNeeded() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            await self?.drainRefreshes()
        }
    }

    private func drainRefreshes() async {
        while !Task.isCancelled, let generation = pendingGeneration {
            pendingGeneration = nil
            async let rules: Void = refreshRules(generation)
            async let providers: Void = refreshProviders()
            async let proxies: Void = refreshProxies()
            _ = await (rules, providers, proxies)
        }
        refreshTask = nil
        if pendingGeneration != nil {
            startRefreshTaskIfNeeded()
        }
    }
}

@MainActor
@Observable
final class DailyDriverFeatureHub {
    let profiles: RemoteProfilesViewModel
    let providers: ProvidersViewModel
    let connections: ConnectionsViewModel
    let rules: RulesViewModel
    let configuration: ConfigurationEditorViewModel
    let dataSettings: DataSettingsViewModel
    @ObservationIgnored private let bootstrapGate: DailyDriverBootstrapGate
    @ObservationIgnored private let subscriptionDeadlineDriver: SubscriptionDeadlineDriver
    @ObservationIgnored private let catalogRefreshCoordinator: DailyDriverCatalogRefreshCoordinator
    private(set) var configurationGeneration = ConfigurationGeneration()
    private(set) var runtimeRecoveryError: UserFacingError?

    init(
        profiles: RemoteProfilesViewModel,
        providers: ProvidersViewModel,
        connections: ConnectionsViewModel,
        rules: RulesViewModel,
        configuration: ConfigurationEditorViewModel,
        dataSettings: DataSettingsViewModel,
        transactionCoordinator: RuntimeConfigTransactionCoordinator
    ) {
        self.profiles = profiles
        self.providers = providers
        self.connections = connections
        self.rules = rules
        self.configuration = configuration
        self.dataSettings = dataSettings
        let subscriptionDeadlineDriver = SubscriptionDeadlineDriver(
            nextDeadline: { [weak profiles] in
                profiles?.nextScheduledUpdateDate()
            },
            runDue: { [weak profiles] networkAvailable, reason in
                await profiles?.runDue(
                    networkAvailable: networkAvailable,
                    reason: reason
                )
            }
        )
        self.subscriptionDeadlineDriver = subscriptionDeadlineDriver
        catalogRefreshCoordinator = DailyDriverCatalogRefreshCoordinator(
            resetConnections: { [weak connections] generation in
                connections?.configurationDidChange(generation)
            },
            refreshRules: { [weak rules] generation in
                await rules?.configurationDidChange(generation)
            },
            refreshProviders: { [weak providers] in
                await providers?.refresh()
            },
            refreshProxies: { [weak profiles] in
                await profiles?.refreshRuntimeProxyCatalog()
            }
        )
        bootstrapGate = DailyDriverBootstrapGate(
            recover: {
                try await transactionCoordinator.recoverIfNeeded()
            },
            startScheduling: { [weak subscriptionDeadlineDriver] networkAvailable in
                subscriptionDeadlineDriver?.start(networkAvailable: networkAvailable)
            },
            presentFailure: { [weak profiles] error in
                profiles?.presentRuntimeRecoveryFailure(error)
            }
        )
        profiles.setScheduleChangeHandler { [weak subscriptionDeadlineDriver] in
            subscriptionDeadlineDriver?.profilesDidChange()
        }
        profiles.setConfigurationAppliedHandler { [weak self] in
            self?.configurationDidChange()
        }
    }

    func engineRunningChanged(_ isRunning: Bool) {
        connections.engineRunningChanged(isRunning)
        if isRunning {
            Task {
                await providers.refresh()
                await rules.refresh()
            }
        }
    }

    func bootstrap(networkAvailable: Bool) async {
        runtimeRecoveryError = await bootstrapGate.bootstrap(
            networkAvailable: networkAvailable
        )
    }

    @discardableResult
    func recoverPersistentTransactions() async -> Bool {
        runtimeRecoveryError = await bootstrapGate.recoverPersistentTransactions()
        return runtimeRecoveryError == nil
    }

    func startScheduling(networkAvailable: Bool) {
        guard runtimeRecoveryError == nil else { return }
        bootstrapGate.startSchedulingIfRecovered(networkAvailable: networkAvailable)
    }

    func handleLifecycleEvent(_ event: EngineLifecycleEvent) {
        switch event {
        case let .engineRunningChanged(isRunning):
            engineRunningChanged(isRunning)
        case let .networkAvailabilityChanged(isAvailable):
            subscriptionDeadlineDriver.networkAvailabilityChanged(isAvailable)
        case .willSleep:
            subscriptionDeadlineDriver.willSleep()
        case .didWake:
            subscriptionDeadlineDriver.didWake()
        }
    }

    func shutdown() async {
        await suspendForUpdate()
    }

    func suspendForUpdate() async {
        await subscriptionDeadlineDriver.stop()
        await profiles.suspendForUpdate()
        await dataSettings.suspendForUpdate()
        await catalogRefreshCoordinator.stop()
        connections.engineRunningChanged(false)
    }

    func resumeAfterCancelledUpdate(
        networkAvailable: Bool,
        engineRunning: Bool
    ) {
        subscriptionDeadlineDriver.start(networkAvailable: networkAvailable)
        connections.engineRunningChanged(engineRunning)
    }

    func configurationDidChange() {
        configurationGeneration = catalogRefreshCoordinator.configurationDidChange()
    }
}
