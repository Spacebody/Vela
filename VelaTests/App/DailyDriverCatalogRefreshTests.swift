import Foundation
import Testing
@testable import Vela

@MainActor
@Suite("Daily driver resident catalog refresh")
struct DailyDriverCatalogRefreshTests {
    @Test("Remote success refreshes every runtime catalog without a window")
    func remoteSuccessRefreshesResidentCatalogs() async {
        let profile = Self.remoteProfile()
        let service = RemoteProfileServiceFake(
            states: [profile.id: .succeeded(Date(timeIntervalSince1970: 123))]
        )
        let scheduler = RemoteProfileSchedulerFake(
            updateResult: SubscriptionScheduledResult(
                profileID: profile.id,
                result: .success(())
            )
        )
        let engine = RemoteProfileEngineStoreFake(profiles: [profile])
        let viewModel = RemoteProfilesViewModel(
            service: service,
            scheduler: scheduler,
            engineStore: engine
        )
        let recorder = CatalogRefreshRecorder()
        let coordinator = Self.makeCoordinator(
            recorder: recorder,
            refreshProxies: {
                await viewModel.refreshRuntimeProxyCatalog()
            }
        )
        viewModel.setConfigurationAppliedHandler {
            coordinator.configurationDidChange()
        }

        await viewModel.update(profile.id)
        await coordinator.waitUntilIdle()

        #expect(viewModel.configurationApplySequence == 1)
        #expect(recorder.connectionGenerations.count == 1)
        #expect(recorder.ruleGenerations == recorder.connectionGenerations)
        #expect(recorder.providerRefreshes == 1)
        #expect(recorder.proxyRefreshes == 1)
        #expect(engine.proxyRefreshes == 1)
        #expect(engine.proxyRefreshPresentationRequests == [false])
    }

    @Test("Unchanged subscriptions do not invalidate runtime catalogs")
    func unchangedDoesNotRefreshCatalogs() async {
        let profile = Self.remoteProfile()
        let service = RemoteProfileServiceFake(states: [profile.id: .unchanged])
        let scheduler = RemoteProfileSchedulerFake(
            updateResult: SubscriptionScheduledResult(
                profileID: profile.id,
                result: .success(())
            )
        )
        let engine = RemoteProfileEngineStoreFake(profiles: [profile])
        let viewModel = RemoteProfilesViewModel(
            service: service,
            scheduler: scheduler,
            engineStore: engine
        )
        let recorder = CatalogRefreshRecorder()
        let coordinator = Self.makeCoordinator(recorder: recorder)
        viewModel.setConfigurationAppliedHandler {
            coordinator.configurationDidChange()
        }

        await viewModel.update(profile.id)
        await coordinator.waitUntilIdle()

        #expect(viewModel.configurationApplySequence == 0)
        #expect(recorder.connectionGenerations.isEmpty)
        #expect(recorder.ruleGenerations.isEmpty)
        #expect(recorder.providerRefreshes == 0)
        #expect(recorder.proxyRefreshes == 0)
    }

    @Test("Failed initial remote update stays editable without becoming active")
    func failedRemoteCreationDoesNotSelectMetadataOnlyProfile() async throws {
        let profile = Self.remoteProfile()
        let failure = UserFacingError(
            title: "Remote Profile Error",
            message: "Subscription authentication failed.",
            isRetryable: false
        )
        let service = RemoteProfileServiceFake(
            states: [profile.id: .failed(failure)],
            createdProfile: profile
        )
        let engine = RemoteProfileEngineStoreFake(profiles: [profile])
        let viewModel = RemoteProfilesViewModel(
            service: service,
            scheduler: RemoteProfileSchedulerFake(updateResult: nil),
            engineStore: engine
        )
        let url = try #require(URL(string: "https://example.com/subscription"))

        let created = await viewModel.create(
            RemoteProfileCreationRequest(
                name: "Remote",
                secret: SubscriptionSecretEnvelope(url: url)
            )
        )

        #expect(created?.id == profile.id)
        #expect(engine.selectedProfileIDs.isEmpty)
        #expect(viewModel.lastError?.title == failure.title)
        #expect(viewModel.lastError?.message == failure.message)
        #expect(viewModel.configurationApplySequence == 0)

        viewModel.dismissError()
        #expect(viewModel.lastError == nil)
    }

    @Test("Successful initial remote update selects the imported profile")
    func successfulRemoteCreationSelectsProfile() async throws {
        let profile = Self.remoteProfile()
        let service = RemoteProfileServiceFake(
            states: [profile.id: .succeeded(Date(timeIntervalSince1970: 123))],
            createdProfile: profile
        )
        let engine = RemoteProfileEngineStoreFake(profiles: [profile])
        let viewModel = RemoteProfilesViewModel(
            service: service,
            scheduler: RemoteProfileSchedulerFake(updateResult: nil),
            engineStore: engine
        )
        let url = try #require(URL(string: "https://example.com/subscription"))

        let created = await viewModel.create(
            RemoteProfileCreationRequest(
                name: "Remote",
                secret: SubscriptionSecretEnvelope(url: url)
            )
        )

        #expect(created?.id == profile.id)
        #expect(engine.selectedProfileIDs == [profile.id])
        #expect(viewModel.lastError == nil)
        #expect(viewModel.configurationApplySequence == 1)
    }

    @Test("Back-to-back events coalesce catalog requests to the newest generation")
    func backToBackEventsCoalesceRequests() async {
        let recorder = CatalogRefreshRecorder()
        let coordinator = Self.makeCoordinator(recorder: recorder)

        _ = coordinator.configurationDidChange()
        let newestGeneration = coordinator.configurationDidChange()
        await coordinator.waitUntilIdle()

        #expect(recorder.connectionGenerations.count == 2)
        #expect(recorder.ruleGenerations == [newestGeneration])
        #expect(recorder.providerRefreshes == 1)
        #expect(recorder.proxyRefreshes == 1)
    }

    private static func makeCoordinator(
        recorder: CatalogRefreshRecorder,
        refreshProxies: @escaping @MainActor @Sendable () async -> Void = {}
    ) -> DailyDriverCatalogRefreshCoordinator {
        DailyDriverCatalogRefreshCoordinator(
            resetConnections: { generation in
                recorder.connectionGenerations.append(generation)
            },
            refreshRules: { generation in
                recorder.ruleGenerations.append(generation)
            },
            refreshProviders: {
                recorder.providerRefreshes += 1
            },
            refreshProxies: {
                await refreshProxies()
                recorder.proxyRefreshes += 1
            }
        )
    }

    private static func remoteProfile() -> Profile {
        let now = Date(timeIntervalSince1970: 100)
        return Profile(
            id: UUID(),
            name: "Remote",
            originalFileName: "subscription.yaml",
            createdAt: now,
            updatedAt: now,
            sourceKind: .remoteSubscription,
            remote: RemoteProfileMetadata(
                redactedURL: "https://example.com/•••/subscription",
                autoUpdateEnabled: true,
                schedule: .daily,
                nextScheduledUpdateAt: now
            )
        )
    }
}

@MainActor
private final class CatalogRefreshRecorder {
    var connectionGenerations: [ConfigurationGeneration] = []
    var ruleGenerations: [ConfigurationGeneration] = []
    var providerRefreshes = 0
    var proxyRefreshes = 0
}

private actor RemoteProfileServiceFake: RemoteProfileServicing {
    private var states: [UUID: SubscriptionUpdateState]
    private let createdProfile: Profile?

    init(
        states: [UUID: SubscriptionUpdateState],
        createdProfile: Profile? = nil
    ) {
        self.states = states
        self.createdProfile = createdProfile
    }

    func createRemoteProfile(_ request: RemoteProfileCreationRequest) async throws -> Profile {
        if let createdProfile { return createdProfile }
        throw SubscriptionUpdateFailure.runtimeBuildFailed
    }

    func deleteProfile(_ profileID: UUID) async throws {}

    func editableSettings(for profileID: UUID) async throws -> RemoteProfileEditableSettings {
        throw SubscriptionUpdateFailure.invalidURL
    }

    func editRemoteProfile(
        _ profileID: UUID,
        request: RemoteProfileEditRequest
    ) async throws -> Profile {
        throw SubscriptionUpdateFailure.runtimeBuildFailed
    }

    func updateState(for profileID: UUID) -> SubscriptionUpdateState {
        states[profileID] ?? .idle
    }

    func rawConfiguration(for profileID: UUID) async throws -> String {
        ""
    }
}

private actor RemoteProfileSchedulerFake: RemoteProfileScheduling {
    private let updateResult: SubscriptionScheduledResult?

    init(updateResult: SubscriptionScheduledResult?) {
        self.updateResult = updateResult
    }

    func updateNow(profileID: UUID) -> SubscriptionScheduledResult? {
        updateResult
    }

    func updateAllNow(profileIDs: [UUID]) -> [SubscriptionScheduledResult] {
        []
    }

    func runDueUpdates(
        profiles: [Profile],
        at now: Date,
        networkAvailable: Bool,
        reason: SubscriptionUpdateReason
    ) -> [SubscriptionScheduledResult] {
        []
    }

    func profileDeleted(_ profileID: UUID) {}
    func profileRestored(_ profileID: UUID) {}
    func isUpdating(_ profileID: UUID) -> Bool { false }
    func cancelUpdate(_ profileID: UUID) {}
}

@MainActor
private final class RemoteProfileEngineStoreFake: RemoteProfileEngineStoring {
    var profiles: [Profile]
    private(set) var proxyRefreshes = 0
    private(set) var proxyRefreshPresentationRequests: [Bool] = []
    private(set) var selectedProfileIDs: [UUID] = []

    init(profiles: [Profile]) {
        self.profiles = profiles
    }

    func refreshProfiles() async {}
    func selectProfile(id: UUID) async {
        selectedProfileIDs.append(id)
    }

    func refreshProxies(presentErrors: Bool) async {
        proxyRefreshes += 1
        proxyRefreshPresentationRequests.append(presentErrors)
    }

    func presentRuntimeRecoveryFailure(_ error: UserFacingError) {}
}
