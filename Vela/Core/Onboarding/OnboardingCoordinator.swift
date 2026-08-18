import Foundation
import Observation

nonisolated enum OnboardingConfigurationAction: String, Equatable, Sendable {
    case importConfiguration = "import-configuration"
    case validateConfiguration = "validate-configuration"
}

nonisolated enum OnboardingConfigurationActionState: Equatable, Sendable {
    case idle
    case running(OnboardingConfigurationAction)
    case succeeded(OnboardingConfigurationAction)
    case failed(OnboardingConfigurationAction)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// The only production injection boundary for onboarding configuration work.
/// Production closures must adapt `EngineStore.importProfile(url:)` and
/// `EngineStore.validateSelectedProfile()` so onboarding cannot bypass the
/// runtime mutation gate or duplicate profile transactions.
@MainActor
struct OnboardingEngineActions: Sendable {
    typealias ImportConfiguration = @MainActor @Sendable (URL) async throws -> Bool
    typealias ValidateConfiguration = @MainActor @Sendable () async throws -> Bool

    let importConfiguration: ImportConfiguration
    let validateConfiguration: ValidateConfiguration

    init(
        importConfiguration: @escaping ImportConfiguration = { _ in false },
        validateConfiguration: @escaping ValidateConfiguration = { false }
    ) {
        self.importConfiguration = importConfiguration
        self.validateConfiguration = validateConfiguration
    }
}

nonisolated enum OnboardingNavigationResult: Equatable, Sendable {
    case advanced(OnboardingStepID)
    case finished
}

nonisolated enum OnboardingCoordinatorError: Error, Equatable, Sendable {
    case transitionInProgress
    case externalActionFailed(OnboardingConfigurationAction)
}

@MainActor
@Observable
final class OnboardingCoordinator {
    private(set) var progress: OnboardingProgress
    private(set) var currentStepID: OnboardingStepID
    private(set) var flowMode: OnboardingFlowMode
    private(set) var presentationDecision: OnboardingPresentationDecision
    private(set) var configurationActionState: OnboardingConfigurationActionState
    private(set) var isTransitioning: Bool
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let store: OnboardingProgressStore
    @ObservationIgnored private let actions: OnboardingEngineActions
    @ObservationIgnored private let clock: OnboardingClock

    init(
        store: OnboardingProgressStore,
        actions: OnboardingEngineActions = OnboardingEngineActions(),
        clock: OnboardingClock = .live
    ) {
        self.store = store
        self.actions = actions
        self.clock = clock
        progress = .empty()
        currentStepID = .welcome
        flowMode = .full
        presentationDecision = .none
        configurationActionState = .idle
        isTransitioning = false
        lastErrorMessage = nil
    }

    var isBusy: Bool {
        isTransitioning || configurationActionState.isRunning
    }

    var canGoBack: Bool { currentStepID.previous != nil }

    func prepare(for context: OnboardingLaunchContext) async throws {
        try beginTransition()
        defer { endTransition() }

        do {
            let loaded = try await store.load()
            try Task<Never, Never>.checkCancellation()
            let decision = OnboardingDecisionPolicy.decide(
                progress: loaded,
                context: context
            )
            progress = loaded ?? .empty()
            presentationDecision = decision
            configurationActionState = .idle
            lastErrorMessage = nil

            switch decision {
            case let .present(mode, startAt):
                flowMode = mode
                currentStepID = startAt
            case .offerTour:
                flowMode = .tour
                currentStepID = .welcome
            case .none:
                currentStepID = progress.resumeStepID
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordPersistenceFailure()
            throw error
        }
    }

    func startFullFlow() async throws {
        try await start(mode: .full)
    }

    func startTour() async throws {
        try await start(mode: .tour)
    }

    func resume() async throws {
        try beginTransition()
        defer { endTransition() }

        var candidate = progress
        if candidate.flowVersion != OnboardingProgress.currentFlowVersion {
            candidate = .empty()
        }
        candidate.reopen()
        let startAt = candidate.resumeStepID
        candidate.recordArrival(at: startAt)

        do {
            try await store.save(candidate)
            progress = candidate
            currentStepID = startAt
            presentationDecision = .present(mode: flowMode, startAt: startAt)
            configurationActionState = .idle
            lastErrorMessage = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordPersistenceFailure()
            throw error
        }
    }

    @discardableResult
    func advance() async throws -> OnboardingNavigationResult {
        try beginTransition()
        defer { endTransition() }

        var candidate = progress
        candidate.markStepCompleted(currentStepID)

        let result: OnboardingNavigationResult
        if let next = currentStepID.next {
            candidate.recordArrival(at: next)
            result = .advanced(next)
        } else {
            candidate.markCompleted(at: clock.now())
            result = .finished
        }

        do {
            try await store.save(candidate)
            progress = candidate
            configurationActionState = .idle
            lastErrorMessage = nil
            switch result {
            case let .advanced(next):
                currentStepID = next
                presentationDecision = .present(mode: flowMode, startAt: next)
            case .finished:
                currentStepID = .finish
                presentationDecision = .none
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordPersistenceFailure()
            throw error
        }
    }

    func goBack() async throws {
        guard let previous = currentStepID.previous else { return }
        try beginTransition()
        defer { endTransition() }

        var candidate = progress
        candidate.recordArrival(at: previous)
        do {
            try await store.save(candidate)
            progress = candidate
            currentStepID = previous
            presentationDecision = .present(mode: flowMode, startAt: previous)
            configurationActionState = .idle
            lastErrorMessage = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordPersistenceFailure()
            throw error
        }
    }

    func skip() async throws {
        try beginTransition()
        defer { endTransition() }

        var candidate = progress
        candidate.recordArrival(at: currentStepID)
        candidate.markSkipped(at: clock.now())
        do {
            try await store.save(candidate)
            progress = candidate
            presentationDecision = .none
            configurationActionState = .idle
            lastErrorMessage = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordPersistenceFailure()
            throw error
        }
    }

    func reset() async throws {
        try beginTransition()
        defer { endTransition() }

        do {
            try await store.reset()
            progress = .empty()
            currentStepID = .welcome
            flowMode = .full
            presentationDecision = .present(mode: .full, startAt: .welcome)
            configurationActionState = .idle
            lastErrorMessage = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordPersistenceFailure()
            throw error
        }
    }

    func importConfiguration(from url: URL) async throws {
        try await runConfigurationAction(.importConfiguration) { [self] in
            try await self.actions.importConfiguration(url)
        }
    }

    func validateConfiguration() async throws {
        try await runConfigurationAction(.validateConfiguration) { [self] in
            try await self.actions.validateConfiguration()
        }
    }

    func clearConfigurationActionState() {
        guard !configurationActionState.isRunning else { return }
        configurationActionState = .idle
    }

    private func start(mode: OnboardingFlowMode) async throws {
        try beginTransition()
        defer { endTransition() }

        var candidate = OnboardingProgress.empty()
        candidate.recordArrival(at: .welcome)
        do {
            try await store.save(candidate)
            progress = candidate
            currentStepID = .welcome
            flowMode = mode
            presentationDecision = .present(mode: mode, startAt: .welcome)
            configurationActionState = .idle
            lastErrorMessage = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordPersistenceFailure()
            throw error
        }
    }

    private func runConfigurationAction(
        _ action: OnboardingConfigurationAction,
        operation: @escaping @MainActor @Sendable () async throws -> Bool
    ) async throws {
        try beginTransition()
        configurationActionState = .running(action)
        lastErrorMessage = nil
        defer { endTransition() }

        do {
            let succeeded = try await operation()
            try Task<Never, Never>.checkCancellation()
            configurationActionState = succeeded ? .succeeded(action) : .failed(action)
            if !succeeded {
                lastErrorMessage = VelaL10n.string(
                    "onboarding.configuration.incomplete",
                    defaultValue: "The requested configuration action did not complete. Your existing setup was not changed."
                )
            }
        } catch is CancellationError {
            configurationActionState = .idle
            throw CancellationError()
        } catch {
            configurationActionState = .failed(action)
            lastErrorMessage = VelaL10n.string(
                "onboarding.configuration.failed",
                defaultValue: "The requested configuration action failed. Review the configuration and try again."
            )
            throw OnboardingCoordinatorError.externalActionFailed(action)
        }
    }

    private func beginTransition() throws {
        guard !isTransitioning else {
            throw OnboardingCoordinatorError.transitionInProgress
        }
        isTransitioning = true
    }

    private func endTransition() {
        isTransitioning = false
    }

    private func recordPersistenceFailure() {
        lastErrorMessage = VelaL10n.string(
            "onboarding.progress.saveFailed",
            defaultValue: "Onboarding progress could not be saved. No network settings were changed."
        )
    }
}
