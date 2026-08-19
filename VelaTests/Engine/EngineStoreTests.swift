import Darwin
import Foundation
import Observation
import ServiceManagement
import Testing
import VelaIPC
@testable import Vela

@MainActor
@Suite("Engine store")
struct EngineStoreTests {
    @Test("Deinitialization finishes lifecycle streams")
    func deinitializationFinishesLifecycleStreams() async {
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        var store: EngineStore? = makeStore(
            profileManager: EngineStoreProfileManagerFake(),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )
        weak let releasedStore = store
        let stream = store?.lifecycleEvents()
        var iterator = stream?.makeAsyncIterator()

        store = nil

        #expect(releasedStore == nil)
        #expect(await iterator?.next() == nil)
        await processManager.finishEvents()
    }

    @Test("Bootstrap loads profiles and the selected profile")
    func bootstrapLoadsPersistedState() async {
        let profile = makeProfile()
        let profileManager = EngineStoreProfileManagerFake(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: profileManager,
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )

        await store.bootstrap()

        #expect(store.profiles == [profile])
        #expect(store.selectedProfileID == profile.id)
        #expect(store.selectedProfile == profile)
        #expect(store.state == .stopped)
        #expect(await profileManager.prepareCallCount() == 1)
        #expect(await profileManager.profilesCallCount() == 1)
        #expect(await profileManager.selectedProfileIDCallCount() == 1)
        await processManager.finishEvents()
    }

    @Test("User backend records the runtime configuration fingerprint")
    func userBackendRecordsRuntimeConfigurationFingerprint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-runtime-fingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configurationURL = root.appendingPathComponent("runtime.yaml")
        try Data("rules: [MATCH,DIRECT]\n".utf8).write(to: configurationURL)
        let expectedFingerprint = try await RuntimeConfigurationInspector().fingerprint(
            at: configurationURL
        )
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id,
                runtimeConfigurationURL: configurationURL
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )

        await store.bootstrap()
        await store.start()

        #expect(store.activeRuntime?.configurationSHA256 == expectedFingerprint.sha256)
        await store.stop()
        await processManager.finishEvents()
    }

    @Test("Profile import removes its private staging directory")
    func profileImportRemovesPrivateStagingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-profile-import-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.yaml")
        try Data("""
        proxies: []
        proxy-groups: []
        rules: [MATCH,DIRECT]
        """.utf8).write(to: sourceURL)
        let profileManager = EngineStoreProfileManagerFake()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = EngineStore(
            profileStore: profileManager,
            runtimeParameters: RuntimeConfigParameters(
                externalController: "127.0.0.1:19090",
                secret: "engine-store-test-secret",
                mixedPort: 17890
            ),
            executableResolver: EngineStoreExecutableResolverFake(),
            configurationValidator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            subscriptionConverter: EngineStoreSubscriptionConverterFake(),
            processManager: processManager,
            mihomoDataDirectoryURL: EngineStoreTestValues.dataDirectory
        )

        await store.importProfile(url: sourceURL)

        let stagedURL = try #require(await profileManager.lastImportedSourceURL())
        #expect(!FileManager.default.fileExists(atPath: stagedURL.deletingLastPathComponent().path))
        await processManager.finishEvents()
    }

    @Test("Bootstrap does not wait for the optional privileged Helper")
    func bootstrapDoesNotWaitForPrivilegedHelper() async {
        let helper = EngineStorePrivilegedHelperFake()
        await helper.suspendNextHandshake()
        let componentManager = PrivilegedComponentManager(
            service: EngineStorePrivilegedAppServiceFake(status: .enabled),
            client: helper,
            preflight: EngineStorePrivilegedPreflightFake(),
            openSystemSettingsAction: {}
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            privilegedHelperClient: helper,
            privilegedComponentManager: componentManager
        )

        await store.bootstrap()

        #expect(await helper.handshakeCallCount() == 0)

        let reconciliation = Task { @MainActor in
            await store.reconcilePrivilegedComponentAfterBootstrap(
                restartInfrastructureIfNeeded: false
            )
        }
        await helper.waitUntilHandshakeSuspended()
        #expect(await helper.handshakeCallCount() == 1)
        await helper.releaseHandshake()
        await reconciliation.value
        await processManager.finishEvents()
    }

    @Test("Uninstall forwards both user-selected cleanup modes")
    func uninstallForwardsSelectedCleanupModes() async {
        for mode in [
            PrivilegedCleanupMode.removeRuntimeData,
            .keepDiagnosticMetadata,
        ] {
            let processManager = EngineStoreProcessManagerFake(isRunning: false)
            let helper = EngineStorePrivilegedHelperFake()
            let service = EngineStorePrivilegedAppServiceFake(status: .enabled)
            let componentManager = PrivilegedComponentManager(
                service: service,
                client: helper,
                preflight: EngineStorePrivilegedPreflightFake(),
                openSystemSettingsAction: {}
            )
            let store = makeStore(
                profileManager: EngineStoreProfileManagerFake(),
                resolver: EngineStoreExecutableResolverFake(),
                validator: EngineStoreConfigurationValidatorFake(
                    result: EngineStoreTestValues.validValidation,
                    suspendValidation: false
                ),
                processManager: processManager,
                privilegedHelperClient: helper,
                privilegedComponentManager: componentManager
            )

            await store.uninstallPrivilegedComponent(
                userConfirmed: true,
                cleanupMode: mode
            )

            #expect(await helper.cleanupModes() == [mode])
            #expect(service.status == .notRegistered)
            await processManager.finishEvents()
        }
    }

    @Test("TUN transition preserves System Proxy and merges detected local routes")
    func tunTransitionComposesWithSystemProxyAndMergesLocalRoutes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-tun-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationURL = root.appendingPathComponent("runtime.yaml")
        try Data("""
        dns:
          enable: true
          nameserver: [1.1.1.1]
        proxies: []
        proxy-groups: []
        rules: [MATCH,DIRECT]
        """.utf8).write(to: configurationURL)

        let profile = makeProfile()
        let profileManager = EngineStoreProfileManagerFake(
            profiles: [profile],
            selectedProfileID: profile.id,
            runtimeConfigurationURL: configurationURL
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let controllerManager = EngineStoreControllerManagerFake()
        let systemProxyManager = EngineStoreSystemProxyManagerFake()
        let helper = EngineStorePrivilegedHelperFake()
        let componentManager = PrivilegedComponentManager(
            service: EngineStorePrivilegedAppServiceFake(status: .enabled),
            client: helper,
            preflight: EngineStorePrivilegedPreflightFake(),
            openSystemSettingsAction: {}
        )
        let backend = PrivilegedMihomoBackend(client: helper)
        let store = makeStore(
            profileManager: profileManager,
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager,
            systemProxyManager: systemProxyManager,
            privilegedBackend: backend,
            privilegedHelperClient: helper,
            transitionCoordinator: EngineTransitionCoordinator(),
            privilegedLeaseCoordinator: PrivilegedLeaseCoordinator(client: helper),
            privilegedComponentManager: componentManager,
            localNetworkContextProvider: EngineStoreLocalNetworkContextFake(
                exclusions: ["192.168.50.0/24"]
            )
        )
        var settings = store.tunSettings
        settings.routeExcludeCIDRs = ["10.0.0.0/8"]
        store.updateTunSettings(settings)

        await store.bootstrap()
        await store.start()
        await controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(store, toEqual: .connected)
        await store.setSystemProxyEnabled(true)
        #expect(store.isSystemProxyApplied)

        await store.setTunEnabled(true)
        await controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(store, toEqual: .connected)
        await waitForSystemProxyEnableCount(systemProxyManager, expected: 2)

        #expect(store.lastError == nil, Comment(rawValue: store.lastError?.technicalDetails ?? store.lastError?.message ?? "no error"))
        #expect(store.isTunActive)
        #expect(store.activeBackendKind == .privilegedDaemon)
        #expect(store.isSystemProxyApplied)
        #expect(store.effectiveTunRouteExclusions == ["10.0.0.0/8", "192.168.50.0/24"])
        let request = try #require(await helper.lastPrepareRequest())
        #expect(request.tunSettings.routeExcludeCIDRs == ["10.0.0.0/8", "192.168.50.0/24"])
        #expect(await systemProxyManager.restoreCallCount() >= 1)
        #expect(await systemProxyManager.enableCallCount() == 2)

        await store.stop()
        await processManager.finishEvents()
    }

    @Test("Connection clock follows traffic takeover instead of Controller readiness")
    func trafficTakeoverClockTracksUserConnection() async throws {
        let fixture = try await makeBackendTransitionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.store.start()
        await waitForControllerState(fixture.store, toEqual: .connected)

        #expect(fixture.store.isRunning)
        #expect(fixture.store.controllerState == .connected)
        #expect(fixture.store.trafficTakeoverStartedAt == nil)

        let connectionBoundary = Date.now
        await fixture.store.setSystemProxyEnabled(true)

        let connectedAt = try #require(fixture.store.trafficTakeoverStartedAt)
        #expect(connectedAt >= connectionBoundary)
        #expect(connectedAt <= Date.now)

        await fixture.store.setSystemProxyEnabled(false)

        #expect(fixture.store.trafficTakeoverStartedAt == nil)
        await fixture.processManager.finishEvents()
    }

    @Test("Failed user stop restores the original System Proxy before rollback succeeds")
    func userRollbackSynchronouslyRestoresSystemProxy() async throws {
        let fixture = try await makeBackendTransitionFixture(
            processStopFailure: .simulatedStopFailure
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.store.start()
        await waitForControllerState(fixture.store, toEqual: .connected)
        await fixture.store.setSystemProxyEnabled(true)
        #expect(fixture.store.isSystemProxyApplied)

        await fixture.store.setTunEnabled(true)

        #expect(fixture.store.activeBackendKind == .userProcess)
        #expect(fixture.store.isRunning)
        #expect(fixture.store.isSystemProxyApplied)
        #expect(await fixture.systemProxyManager.enableCallCount() == 2)
        #expect(await fixture.helper.commitCallCount() == 0)
        #expect(await fixture.helper.abortCallCount() == 1)
        if case let .failed(failure) = (await fixture.transitionCoordinator.snapshot()).state {
            #expect(failure.rollback == .succeeded)
        } else {
            Issue.record("The failed transition should retain its successful rollback result")
        }
        await fixture.processManager.finishEvents()
    }

    @Test("Failed System Proxy re-enable is reported as a rollback double fault")
    func userRollbackProxyFailureIsExplicit() async throws {
        let fixture = try await makeBackendTransitionFixture(
            processStopFailure: .simulatedStopFailure
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.store.start()
        await waitForControllerState(fixture.store, toEqual: .connected)
        await fixture.store.setSystemProxyEnabled(true)
        await fixture.systemProxyManager.failNextEnableWithPartialApply()

        await fixture.store.setTunEnabled(true)

        #expect(fixture.store.activeBackendKind == .userProcess)
        #expect(fixture.store.isRunning)
        #expect(!fixture.store.isSystemProxyApplied)
        #expect(fixture.store.systemProxyNeedsRestore)
        #expect(await fixture.helper.commitCallCount() == 0)
        if case let .failed(failure) = (await fixture.transitionCoordinator.snapshot()).state {
            guard case .failed = failure.rollback else {
                Issue.record("Rollback should expose the System Proxy double fault")
                return
            }
        } else {
            Issue.record("The transition should remain failed after rollback failure")
        }
        await fixture.processManager.finishEvents()
    }

    @Test("Partial System Proxy cleanup blocks privileged rollback and a second core")
    func privilegedRollbackRequiresCleanSystemProxy() async throws {
        let fixture = try await makeBackendTransitionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.start()
        await waitForControllerState(fixture.store, toEqual: .connected)
        await fixture.store.setTunEnabled(true)
        let baselineCommit = await fixture.helper.commitCallCount()
        await fixture.store.setSystemProxyEnabled(true)
        #expect(fixture.store.isSystemProxyApplied)
        await fixture.processManager.failNextStart()
        await fixture.systemProxyManager.failNextRestore()

        await fixture.store.setTunEnabled(false)

        #expect(await fixture.helper.commitCallCount() == baselineCommit)
        #expect(!(await fixture.helper.isRuntimeRunning()))
        #expect(fixture.store.activeBackendKind == .userProcess)
        #expect(!fixture.store.isRunning)
        #expect(fixture.store.systemProxyNeedsRestore)
        if case let .failed(failure) = (await fixture.transitionCoordinator.snapshot()).state {
            guard case .failed = failure.rollback else {
                Issue.record("Rollback should fail instead of starting root TUN")
                return
            }
        } else {
            Issue.record("The transition should expose the cleanup double fault")
        }
        await fixture.processManager.finishEvents()
    }

    @Test("A user-process stop failure blocks privileged rollback after proxy cleanup")
    func privilegedRollbackDoesNotStartBesideUserCore() async throws {
        let fixture = try await makeBackendTransitionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.start()
        await waitForControllerState(fixture.store, toEqual: .connected)
        await fixture.store.setTunEnabled(true)
        let baselineCommit = await fixture.helper.commitCallCount()
        await fixture.store.setSystemProxyEnabled(true)
        #expect(fixture.store.isSystemProxyApplied)
        await fixture.processManager.failNextStart(leavingProcessRunning: true)
        await fixture.processManager.failNextStop()

        await fixture.store.setTunEnabled(false)

        #expect(await fixture.helper.commitCallCount() == baselineCommit)
        #expect(!(await fixture.helper.isRuntimeRunning()))
        #expect(await fixture.processManager.isRunning())
        #expect(fixture.store.activeBackendKind == .userProcess)
        #expect(!fixture.store.systemProxyNeedsRestore)
        if case let .failed(failure) = (await fixture.transitionCoordinator.snapshot()).state {
            guard case .failed = failure.rollback else {
                Issue.record("Rollback should fail instead of running two cores")
                return
            }
        } else {
            Issue.record("The transition should expose the user-stop double fault")
        }
        await fixture.processManager.finishEvents()
    }

    @Test("Verified System Proxy cleanup permits exactly one privileged rollback start")
    func privilegedRollbackRestartsOnlyAfterProxyCleanup() async throws {
        let fixture = try await makeBackendTransitionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.start()
        await waitForControllerState(fixture.store, toEqual: .connected)
        await fixture.store.setTunEnabled(true)
        let baselineCommit = await fixture.helper.commitCallCount()
        await fixture.store.setSystemProxyEnabled(true)
        #expect(fixture.store.isSystemProxyApplied)
        await fixture.processManager.failNextStart()

        await fixture.store.setTunEnabled(false)
        await fixture.controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(fixture.store, toEqual: .connected)
        await waitForSystemProxyEnableCount(fixture.systemProxyManager, expected: 2)

        #expect(await fixture.helper.commitCallCount() == baselineCommit + 1)
        #expect(await fixture.helper.isRuntimeRunning())
        #expect(fixture.store.isTunActive)
        #expect(fixture.store.isSystemProxyApplied)
        #expect(fixture.store.systemProxyNeedsRestore)
        #expect(!(await fixture.processManager.isRunning()))
        if case let .failed(failure) = (await fixture.transitionCoordinator.snapshot()).state {
            #expect(failure.rollback == .succeeded)
        } else {
            Issue.record("The original commit fault should remain visible after rollback")
        }
        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("A still-running privileged source is rebound, re-leased, and freshly verified")
    func privilegedFastPathRollbackReestablishesOwnership() async throws {
        let fixture = try await makeBackendTransitionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.start()
        await waitForControllerState(fixture.store, toEqual: .connected)
        await fixture.store.setTunEnabled(true)
        let baselineCommit = await fixture.helper.commitCallCount()
        let baselineControllerStarts = await fixture.controllerManager.startCallCount()
        await fixture.helper.failNextStop()

        await fixture.store.setTunEnabled(false)

        #expect(await fixture.helper.commitCallCount() == baselineCommit)
        #expect(await fixture.helper.isRuntimeRunning())
        #expect(fixture.store.isTunActive)
        #expect(await fixture.controllerManager.startCallCount() == baselineControllerStarts + 1)
        if case let .failed(failure) = (await fixture.transitionCoordinator.snapshot()).state {
            #expect(failure.rollback == .succeeded)
        } else {
            Issue.record("The failed source stop should retain a verified rollback result")
        }
        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("TUN staging rejects a provider resource reached through a symlink")
    func tunTransitionRejectsSymlinkedProviderResource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-tun-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let realResource = root.appendingPathComponent("real-provider.yaml")
        let linkedResource = root.appendingPathComponent("linked-provider.yaml")
        try Data("payload: []\n".utf8).write(to: realResource)
        try FileManager.default.createSymbolicLink(
            at: linkedResource,
            withDestinationURL: realResource
        )
        let configurationURL = root.appendingPathComponent("runtime.yaml")
        try Data("""
        dns:
          enable: true
          nameserver: [1.1.1.1]
        proxy-providers:
          local:
            type: file
            path: linked-provider.yaml
        proxies: []
        proxy-groups: []
        rules: [MATCH,DIRECT]
        """.utf8).write(to: configurationURL)

        let profile = makeProfile()
        let helper = EngineStorePrivilegedHelperFake()
        let componentManager = PrivilegedComponentManager(
            service: EngineStorePrivilegedAppServiceFake(status: .enabled),
            client: helper,
            preflight: EngineStorePrivilegedPreflightFake(),
            openSystemSettingsAction: {}
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id,
                runtimeConfigurationURL: configurationURL
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            privilegedBackend: PrivilegedMihomoBackend(client: helper),
            privilegedHelperClient: helper,
            transitionCoordinator: EngineTransitionCoordinator(),
            privilegedLeaseCoordinator: PrivilegedLeaseCoordinator(client: helper),
            privilegedComponentManager: componentManager
        )

        await store.bootstrap()
        await store.setTunEnabled(true)

        #expect(!store.isTunActive)
        #expect(store.lastError?.title == "TUN Could Not Be Enabled")
        #expect(await helper.lastPrepareRequest() == nil)
        await processManager.finishEvents()
    }

    @Test("TUN startup failure explains competing VPN and TUN recovery")
    func tunStartupFailureSuggestsStoppingCompetingTunnel() async throws {
        let fixture = try await makeBackendTransitionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.store.start()
        await fixture.helper.failNextCommit()
        await fixture.store.setTunEnabled(true)

        #expect(fixture.store.lastError?.title == "TUN Could Not Be Enabled")
        #expect(
            fixture.store.lastError?.suggestedAction?.contains("Clash Verge") == true
        )
        #expect(!fixture.store.isTunActive)
        #expect(fixture.store.activeBackendKind == .userProcess)
        await fixture.processManager.finishEvents()
    }

    @Test("Wake waits for a reachable path, handshakes, checks health, and restarts once")
    func wakeRecoveryWaitsForPathAndRestartsAtMostOnce() async throws {
        let fixture = try await makeActiveTunWakeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let baselineHandshake = await fixture.helper.handshakeCallCount()
        let baselineStatus = await fixture.helper.statusCallCount()
        let baselinePrepare = await fixture.helper.prepareCallCount()
        let baselineCommit = await fixture.helper.commitCallCount()
        let baselineStop = await fixture.helper.stopCallCount()
        let baselineRenew = await fixture.helper.renewCallCount()
        await fixture.helper.setRuntimeHealthy(false)

        fixture.sleepWakeObserver.emit(.willSleep)
        for _ in 0..<20 { await Task.yield() }
        await fixture.networkPathObserver.emit(NetworkPathSnapshot(status: .unsatisfied))
        await waitForNetworkPath(fixture.store, status: .unsatisfied)
        fixture.sleepWakeObserver.emit(.didWake)
        await waitForWakeSleepCalls(fixture.wakeSleep, count: 1)

        #expect(await fixture.helper.renewCallCount() == baselineRenew + 1)
        #expect(await fixture.helper.handshakeCallCount() == baselineHandshake)
        #expect(await fixture.helper.statusCallCount() == baselineStatus)
        #expect(await fixture.helper.stopCallCount() == baselineStop)

        await fixture.networkPathObserver.emit(NetworkPathSnapshot(status: .satisfied))
        await fixture.wakeSleep.advanceOne()
        await waitForHelperCommitCalls(fixture.helper, count: baselineCommit + 1)
        await waitForHelperStatusCalls(fixture.helper, count: baselineStatus + 3)

        #expect(await fixture.helper.handshakeCallCount() == baselineHandshake + 1)
        #expect(await fixture.helper.prepareCallCount() == baselinePrepare + 1)
        #expect(await fixture.helper.commitCallCount() == baselineCommit + 1)
        #expect(await fixture.helper.stopCallCount() == baselineStop + 1)
        #expect(fixture.store.isTunActive)
        if case let .running(health) = fixture.store.state {
            #expect(health.overallState == .healthy)
            #expect(health.processRunning)
        } else {
            Issue.record("Wake recovery should restore a healthy running TUN")
        }

        let timeoutHandshake = await fixture.helper.handshakeCallCount()
        let timeoutStatus = await fixture.helper.statusCallCount()
        let timeoutCommit = await fixture.helper.commitCallCount()
        let timeoutStop = await fixture.helper.stopCallCount()
        let timeoutRenew = await fixture.helper.renewCallCount()
        let sleepCalls = await fixture.wakeSleep.callCount()

        fixture.sleepWakeObserver.emit(.willSleep)
        for _ in 0..<20 { await Task.yield() }
        await fixture.networkPathObserver.emit(NetworkPathSnapshot(status: .unsatisfied))
        await waitForNetworkPath(fixture.store, status: .unsatisfied)
        fixture.sleepWakeObserver.emit(.didWake)
        await waitForWakeSleepCalls(fixture.wakeSleep, count: sleepCalls + 1)
        await fixture.wakeSleep.advanceOne()
        await waitForWakeSleepCalls(fixture.wakeSleep, count: sleepCalls + 2)
        await fixture.wakeSleep.advanceOne()
        await waitForLastError(
            fixture.store,
            title: "TUN Wake Recovery Is Degraded"
        )

        #expect(await fixture.helper.renewCallCount() == timeoutRenew + 1)
        #expect(await fixture.helper.handshakeCallCount() == timeoutHandshake)
        #expect(await fixture.helper.statusCallCount() == timeoutStatus)
        #expect(await fixture.helper.commitCallCount() == timeoutCommit)
        #expect(await fixture.helper.stopCallCount() == timeoutStop)
        if case let .running(health) = fixture.store.state {
            #expect(health.overallState == .degraded)
            #expect(health.processRunning)
        } else {
            Issue.record("A path timeout with a live child should remain running but degraded")
        }

        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("A failed wake restart aborts its candidate and exposes clean stopped state")
    func wakeRestartFailureAbortsCandidateAndFailsStopped() async throws {
        let fixture = try await makeActiveTunWakeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baselineAbort = await fixture.helper.abortCallCount()
        let baselineCommit = await fixture.helper.commitCallCount()
        let baselineStop = await fixture.helper.stopCallCount()
        await fixture.helper.setRuntimeHealthy(false)
        await fixture.helper.failNextCommit()

        fixture.sleepWakeObserver.emit(.willSleep)
        fixture.sleepWakeObserver.emit(.didWake)
        await waitForHelperAbortCalls(fixture.helper, count: baselineAbort + 1)
        await waitForActiveBackend(fixture.store, toEqual: .userProcess)

        #expect(await fixture.helper.commitCallCount() == baselineCommit + 1)
        #expect(await fixture.helper.stopCallCount() == baselineStop + 1)
        #expect(await fixture.helper.abortCallCount() == baselineAbort + 1)
        #expect(!fixture.store.isTunActive)
        #expect(fixture.store.activeRuntime == nil)
        #expect(fixture.store.activeBackendKind == .userProcess)
        if case .failed = fixture.store.state {
            // Expected: Helper status proved the root runtime is cleanly stopped.
        } else {
            Issue.record("A clean stopped restart failure must not look running")
        }
        await fixture.processManager.finishEvents()
    }

    @Test("A dead child after wake never becomes running with processRunning false")
    func wakeDeadChildFailsInsteadOfPublishingRunning() async throws {
        let fixture = try await makeActiveTunWakeFixture(fixedInterface: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baselineCommit = await fixture.helper.commitCallCount()
        let baselineStop = await fixture.helper.stopCallCount()
        await fixture.helper.simulateRuntimeDeath()

        fixture.sleepWakeObserver.emit(.willSleep)
        fixture.sleepWakeObserver.emit(.didWake)
        await waitForLastError(
            fixture.store,
            title: "TUN Wake Recovery Is Degraded"
        )

        #expect(await fixture.helper.commitCallCount() == baselineCommit)
        #expect(await fixture.helper.stopCallCount() == baselineStop)
        #expect(fixture.store.activeRuntime == nil)
        #expect(fixture.store.activeBackendKind == .userProcess)
        if case .failed = fixture.store.state {
            // Expected: a confirmed dead child is not represented as running.
        } else {
            Issue.record("A dead child must produce a failed state")
        }
        await fixture.processManager.finishEvents()
    }

    @Test("A healthy TUN needs no restart after a debounced network path change")
    func healthyNetworkChangeDoesNotRestartTun() async throws {
        let fixture = try await makeActiveTunWakeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baselineSleep = await fixture.networkChangeSleep.callCount()
        let baselineStatus = await fixture.helper.statusCallCount()
        let baselineCommit = await fixture.helper.commitCallCount()
        let baselineStop = await fixture.helper.stopCallCount()

        await triggerReachableNetworkChange(
            store: fixture.store,
            observer: fixture.networkPathObserver
        )
        await waitForControlledSleepCalls(
            fixture.networkChangeSleep,
            count: baselineSleep + 1
        )
        await fixture.networkChangeSleep.advanceLatest()
        await waitForHelperStatusCalls(fixture.helper, count: baselineStatus + 1)
        await waitForPrivilegedHealth(fixture.store, state: .healthy)

        #expect(await fixture.helper.commitCallCount() == baselineCommit)
        #expect(await fixture.helper.stopCallCount() == baselineStop)
        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("A fixed interface degrades without restarting after a network path change")
    func fixedInterfaceNetworkChangeDoesNotRestartTun() async throws {
        let fixture = try await makeActiveTunWakeFixture(fixedInterface: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.helper.setRuntimeHealthy(false)
        let baselineSleep = await fixture.networkChangeSleep.callCount()
        let baselineCommit = await fixture.helper.commitCallCount()
        let baselineStop = await fixture.helper.stopCallCount()

        await triggerReachableNetworkChange(
            store: fixture.store,
            observer: fixture.networkPathObserver
        )
        await waitForControlledSleepCalls(
            fixture.networkChangeSleep,
            count: baselineSleep + 1
        )
        await fixture.networkChangeSleep.advanceLatest()
        await waitForLastError(
            fixture.store,
            title: "TUN Network Recovery Is Degraded"
        )

        #expect(await fixture.helper.commitCallCount() == baselineCommit)
        #expect(await fixture.helper.stopCallCount() == baselineStop)
        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("An unhealthy automatic interface gets one controlled network-change restart")
    func unhealthyAutomaticNetworkChangeRestartsOnce() async throws {
        let fixture = try await makeActiveTunWakeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.helper.setRuntimeHealthy(false)
        let baselineSleep = await fixture.networkChangeSleep.callCount()
        let baselineCommit = await fixture.helper.commitCallCount()
        let baselineStop = await fixture.helper.stopCallCount()

        await triggerReachableNetworkChange(
            store: fixture.store,
            observer: fixture.networkPathObserver
        )
        await waitForControlledSleepCalls(
            fixture.networkChangeSleep,
            count: baselineSleep + 1
        )
        await fixture.networkChangeSleep.advanceLatest()
        await waitForHelperCommitCalls(fixture.helper, count: baselineCommit + 1)
        await waitForPrivilegedHealth(fixture.store, state: .healthy)

        #expect(await fixture.helper.commitCallCount() == baselineCommit + 1)
        #expect(await fixture.helper.stopCallCount() == baselineStop + 1)
        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("A network event storm coalesces into one restart cycle")
    func networkChangeEventStormRestartsAtMostOnce() async throws {
        let fixture = try await makeActiveTunWakeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.helper.setRuntimeHealthy(false)
        let baselineSleep = await fixture.networkChangeSleep.callCount()
        let baselineCommit = await fixture.helper.commitCallCount()
        let baselineStop = await fixture.helper.stopCallCount()

        await fixture.networkPathObserver.emit(.init(status: .unsatisfied))
        await waitForNetworkPath(fixture.store, status: .unsatisfied)
        await fixture.networkPathObserver.emit(.init(status: .satisfied))
        await waitForControlledSleepCalls(
            fixture.networkChangeSleep,
            count: baselineSleep + 1
        )
        await fixture.networkPathObserver.emit(.init(status: .satisfied, isExpensive: true))
        await waitForControlledSleepCalls(
            fixture.networkChangeSleep,
            count: baselineSleep + 2
        )
        await fixture.networkPathObserver.emit(.init(status: .satisfied, isConstrained: true))
        await waitForControlledSleepCalls(
            fixture.networkChangeSleep,
            count: baselineSleep + 3
        )
        await fixture.networkChangeSleep.advanceLatest()
        await waitForHelperCommitCalls(fixture.helper, count: baselineCommit + 1)
        await waitForPrivilegedHealth(fixture.store, state: .healthy)

        #expect(await fixture.helper.commitCallCount() == baselineCommit + 1)
        #expect(await fixture.helper.stopCallCount() == baselineStop + 1)
        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("A rejected Core policy never stops the running TUN during restart")
    func rejectedCorePolicyPreflightsBeforePrivilegedStop() async throws {
        let fixture = try await makeActiveTunWakeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baselineStop = await fixture.helper.stopCallCount()
        let baselineCommit = await fixture.helper.commitCallCount()
        fixture.store.setTunCorePolicyGate { _ in
            throw EngineCoreActivationError.controllerAPIUnavailable
        }

        await fixture.store.restart()

        #expect(await fixture.helper.stopCallCount() == baselineStop)
        #expect(await fixture.helper.commitCallCount() == baselineCommit)
        #expect(fixture.store.isTunActive)
        #expect(fixture.store.activeBackendKind == .privilegedDaemon)
        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("Sleep joins an in-flight network recovery before resuming the Helper lease")
    func sleepDoesNotOverlapNetworkRecovery() async throws {
        let fixture = try await makeActiveTunWakeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.helper.suspendNextStatusCall()
        let baselineSleep = await fixture.networkChangeSleep.callCount()
        let baselineRenew = await fixture.helper.renewCallCount()

        await triggerReachableNetworkChange(
            store: fixture.store,
            observer: fixture.networkPathObserver
        )
        await waitForControlledSleepCalls(
            fixture.networkChangeSleep,
            count: baselineSleep + 1
        )
        await fixture.networkChangeSleep.advanceLatest()
        await fixture.helper.waitUntilStatusCallSuspended()

        fixture.sleepWakeObserver.emit(.willSleep)
        fixture.sleepWakeObserver.emit(.didWake)
        for _ in 0..<20 { await Task.yield() }
        #expect(await fixture.helper.renewCallCount() == baselineRenew)

        await fixture.helper.releaseStatusCall()
        await waitForHelperRenewCalls(
            fixture.helper,
            count: baselineRenew + 1
        )

        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("Sleep cancels a pending local-route restart before it can mutate root TUN")
    func sleepCancelsPendingLocalNetworkRecovery() async throws {
        let localContext = EngineStoreMutableLocalNetworkContextFake()
        let fixture = try await makeActiveTunWakeFixture(
            allowLocalNetwork: true,
            localNetworkContextProvider: localContext
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baselineLocalSleep = await fixture.localNetworkRecoverySleep.callCount()

        fixture.sleepWakeObserver.emit(.willSleep)
        for _ in 0..<20 { await Task.yield() }
        localContext.setExclusions(["192.168.77.0/24"])
        fixture.sleepWakeObserver.emit(.didWake)
        await waitForControlledSleepCalls(
            fixture.localNetworkRecoverySleep,
            count: baselineLocalSleep + 1
        )
        let baselineCommit = await fixture.helper.commitCallCount()
        let baselineStop = await fixture.helper.stopCallCount()

        fixture.sleepWakeObserver.emit(.willSleep)
        await waitForControlledSleepToDrain(fixture.localNetworkRecoverySleep)
        await fixture.localNetworkRecoverySleep.advanceLatest()
        for _ in 0..<100 { await Task.yield() }

        #expect(await fixture.helper.commitCallCount() == baselineCommit)
        #expect(await fixture.helper.stopCallCount() == baselineStop)
        #expect(fixture.store.isTunActive)
        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("Sleep cancels a pending lease repair before it can resume renewal")
    func sleepCancelsPendingLeaseRecovery() async throws {
        let fixture = try await makeActiveTunWakeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await waitForControlledSleepCalls(fixture.leaseSleep, count: 1)
        let baselineLeaseSleep = await fixture.leaseSleep.callCount()
        await fixture.helper.failNextRenew()
        await fixture.helper.suspendNextHandshake()

        await fixture.leaseSleep.advanceLatest()
        await fixture.helper.waitUntilHandshakeSuspended()
        await waitForControlledSleepCalls(
            fixture.leaseSleep,
            count: baselineLeaseSleep + 1
        )
        let renewalsAfterFailure = await fixture.helper.renewCallCount()

        fixture.sleepWakeObserver.emit(.willSleep)
        for _ in 0..<20 { await Task.yield() }
        await fixture.helper.releaseHandshake()
        await waitForControlledSleepToDrain(fixture.leaseSleep)
        for _ in 0..<100 { await Task.yield() }

        #expect(await fixture.helper.renewCallCount() == renewalsAfterFailure)
        #expect(fixture.store.isTunActive)
        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("A failed network-change restart aborts and exposes clean stopped state")
    func networkChangeRestartFailureFailsStopped() async throws {
        let fixture = try await makeActiveTunWakeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.helper.setRuntimeHealthy(false)
        await fixture.helper.failNextCommit()
        let baselineSleep = await fixture.networkChangeSleep.callCount()
        let baselineAbort = await fixture.helper.abortCallCount()
        let baselineCommit = await fixture.helper.commitCallCount()
        let baselineStop = await fixture.helper.stopCallCount()

        await triggerReachableNetworkChange(
            store: fixture.store,
            observer: fixture.networkPathObserver
        )
        await waitForControlledSleepCalls(
            fixture.networkChangeSleep,
            count: baselineSleep + 1
        )
        await fixture.networkChangeSleep.advanceLatest()
        await waitForHelperAbortCalls(fixture.helper, count: baselineAbort + 1)
        await waitForActiveBackend(fixture.store, toEqual: .userProcess)

        #expect(await fixture.helper.commitCallCount() == baselineCommit + 1)
        #expect(await fixture.helper.stopCallCount() == baselineStop + 1)
        #expect(await fixture.helper.abortCallCount() == baselineAbort + 1)
        #expect(!fixture.store.isTunActive)
        #expect(fixture.store.activeRuntime == nil)
        #expect(fixture.store.activeBackendKind == .userProcess)
        if case .failed = fixture.store.state {
            // Expected: Helper status proved the failed restart left no root runtime.
        } else {
            Issue.record("A clean stopped network restart failure must be failed")
        }
        await fixture.processManager.finishEvents()
    }

    @Test("A suspended privileged startup log read never blocks start or lease recovery")
    func suspendedStartupLogReadDoesNotBlockPrivilegedRuntime() async throws {
        let fixture = try await makeActiveTunWakeFixture(
            suspendStartupLogRead: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.helper.waitUntilReadLogBatchStarted()

        #expect(fixture.store.isTunActive)
        #expect(fixture.store.isRunning)
        let baselineRenew = await fixture.helper.renewCallCount()

        fixture.sleepWakeObserver.emit(.willSleep)
        fixture.sleepWakeObserver.emit(.didWake)
        await waitForHelperRenewCalls(
            fixture.helper,
            count: baselineRenew + 1
        )

        #expect(fixture.store.isTunActive)
        #expect(fixture.store.isRunning)
        await fixture.helper.releaseReadLogBatch()
        await fixture.store.stop()
        await fixture.processManager.finishEvents()
    }

    @Test("Quit Anyway yields an active TUN to Helper lease cleanup without claiming it stopped")
    func forcedTerminationYieldsPrivilegedRuntimeWithoutClearingState() async throws {
        let fixture = try await makeActiveTunWakeFixture(
            suspendStartupLogRead: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.helper.waitUntilReadLogBatchStarted()

        let runtimeBeforeYield = fixture.store.activeRuntime
        let stateBeforeYield = fixture.store.state
        let healthBeforeYield = fixture.store.privilegedHealth
        let invalidationsBeforeYield = await fixture.helper.invalidateCallCount()
        let renewalsBeforeYield = await fixture.helper.renewCallCount()
        let stopsBeforeYield = await fixture.helper.stopCallCount()

        await fixture.store.yieldPrivilegedRuntimeToLeaseCleanupForTermination()

        #expect(await fixture.helper.invalidateCallCount() == invalidationsBeforeYield + 1)
        #expect(await fixture.helper.renewCallCount() == renewalsBeforeYield)
        #expect(await fixture.helper.stopCallCount() == stopsBeforeYield)
        #expect(await fixture.helper.isRuntimeRunning())
        #expect(fixture.store.activeRuntime == runtimeBeforeYield)
        #expect(fixture.store.activeBackendKind == .privilegedDaemon)
        #expect(fixture.store.privilegedHealth == healthBeforeYield)
        #expect(fixture.store.state == stateBeforeYield)
        #expect(fixture.store.privilegedRuntimeMayBeActive)

        // Sleep/wake observation has been detached, so it cannot reconnect or
        // renew after App-side ownership is yielded.
        fixture.sleepWakeObserver.emit(.willSleep)
        fixture.sleepWakeObserver.emit(.didWake)
        for _ in 0..<20 { await Task.yield() }
        #expect(await fixture.helper.renewCallCount() == renewalsBeforeYield)

        await fixture.processManager.finishEvents()
    }

    @Test("Post-bootstrap reconciliation stops a stale privileged runtime")
    func bootstrapRecoversStalePrivilegedRuntime() async {
        let helper = EngineStorePrivilegedHelperFake(running: true)
        let componentManager = PrivilegedComponentManager(
            service: EngineStorePrivilegedAppServiceFake(status: .enabled),
            client: helper,
            preflight: EngineStorePrivilegedPreflightFake(),
            openSystemSettingsAction: {}
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            privilegedBackend: PrivilegedMihomoBackend(client: helper),
            privilegedHelperClient: helper,
            transitionCoordinator: EngineTransitionCoordinator(),
            privilegedLeaseCoordinator: PrivilegedLeaseCoordinator(client: helper),
            privilegedComponentManager: componentManager
        )

        await store.bootstrap()
        await store.reconcilePrivilegedComponentAfterBootstrap(
            restartInfrastructureIfNeeded: false
        )

        #expect(await helper.stopCallCount() == 1)
        #expect(store.privilegedHealth?.processRunning == false)
        #expect(!store.privilegedRuntimeMayBeActive)
        #expect(store.lastError?.title == "Recovered Stale TUN Runtime")
        await processManager.finishEvents()
    }

    @Test("Quit cancels a suspended privileged commit and stops its late root runtime")
    func terminationBarrierReconcilesSuspendedPrivilegedCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-tun-quit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationURL = root.appendingPathComponent("runtime.yaml")
        try Data("""
        dns:
          enable: true
          nameserver: [1.1.1.1]
        proxies: []
        proxy-groups: []
        rules: [MATCH,DIRECT]
        """.utf8).write(to: configurationURL)

        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let helper = EngineStorePrivilegedHelperFake(suspendCommit: true)
        let componentManager = PrivilegedComponentManager(
            service: EngineStorePrivilegedAppServiceFake(status: .enabled),
            client: helper,
            preflight: EngineStorePrivilegedPreflightFake(),
            openSystemSettingsAction: {}
        )
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id,
                runtimeConfigurationURL: configurationURL
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            privilegedBackend: PrivilegedMihomoBackend(client: helper),
            privilegedHelperClient: helper,
            transitionCoordinator: EngineTransitionCoordinator(),
            privilegedLeaseCoordinator: PrivilegedLeaseCoordinator(client: helper),
            privilegedComponentManager: componentManager
        )

        await store.bootstrap()
        await store.start()
        #expect(store.isRunning)

        let enableTask = Task { @MainActor in
            await store.setTunEnabled(true)
        }
        await helper.waitUntilCommitStarted()

        let terminationTask = Task { @MainActor in
            await store.prepareForTermination()
        }
        await helper.waitUntilCommitCallerCancelled()
        await helper.completeCommitAfterCallerCancellation()

        let safeToTerminate = await terminationTask.value
        await enableTask.value

        #expect(safeToTerminate)
        #expect(await helper.isRuntimeRunning() == false)
        #expect(await helper.stopCallCount() == 1)
        #expect(store.state == .stopped)
        #expect(store.activeRuntime == nil)
        #expect(store.activeBackendKind == .userProcess)
        await processManager.finishEvents()
    }

    @Test("Update preparation proves shutdown once and makes Sparkle termination idempotent")
    func updatePreparationProducesReusableShutdownProof() async throws {
        let revisionID = UUID(uuidString: "0B8E8372-F264-45FB-97A5-D3D9FC0CF079")!
        let generationID = UUID(uuidString: "78DAF57D-32EE-4628-8222-C0077C3F961E")!
        var profile = makeProfile()
        profile.currentRevisionID = revisionID
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let controllerManager = EngineStoreControllerManagerFake()
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager
        )

        await store.bootstrap()
        await store.start()
        await repopulateProxyCatalog(in: store, using: controllerManager)
        #expect(store.isRunning)

        let preparation = try await store.prepareForUpdateInstallation(
            configurationGenerationID: generationID
        )
        let proof = preparation.proof
        let stopCallsAfterPreparation = await processManager.stopCallCount()

        #expect(proof.isSafeForInstaller)
        #expect(proof.userProcessStopped)
        #expect(proof.privilegedRuntimeStopped)
        #expect(proof.systemProxyRestored)
        #expect(store.state == .stopped)
        #expect(store.updatePreparationState == .prepared)
        #expect(stopCallsAfterPreparation == 1)
        #expect(preparation.snapshot.profileID == profile.id)
        #expect(preparation.snapshot.profileRevisionID == revisionID)
        #expect(preparation.snapshot.backend == .userProcess)
        #expect(preparation.snapshot.systemProxyDesired == false)
        #expect(preparation.snapshot.mihomoMode == .rule)
        #expect(preparation.snapshot.sceneID == nil)
        #expect(preparation.snapshot.automaticScenesEnabled == false)
        #expect(preparation.snapshot.configurationGenerationID == generationID)
        #expect(preparation.snapshot.proxySelections == [
            UpdateProxySelection(
                groupID: "runtime:Proxy",
                proxyID: "runtime:Hong Kong 01"
            )
        ])
        #expect(store.updateRuntimeSnapshot == preparation.snapshot)

        let repeatedProof = try await store.prepareForUpdateInstallation()
        #expect(repeatedProof == proof)
        #expect(await processManager.stopCallCount() == stopCallsAfterPreparation)

        await store.start()
        #expect(store.lastError?.title == "Updating Vela")
        #expect(store.lastError?.technicalDetails == "updateInProgress")
        #expect(await processManager.startCallCount() == 1)

        #expect(store.consumePreparedInstallTerminationAuthorization())
        #expect(!store.consumePreparedInstallTerminationAuthorization())
        #expect(store.updatePreparationState == .terminationAuthorized)

        #expect(await store.prepareForTermination())
        #expect(await processManager.stopCallCount() == stopCallsAfterPreparation)
        await processManager.finishEvents()
    }

    @Test("Failed update preparation releases the update barrier and never authorizes install")
    func failedUpdatePreparationReleasesBarrier() async throws {
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(
            isRunning: false,
            stopFailure: .simulatedStopFailure
        )
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )

        await store.bootstrap()
        await store.start()
        #expect(store.isRunning)

        await #expect(throws: EngineUpdatePreparationError.runtimeCleanupFailed) {
            try await store.prepareForUpdateInstallation()
        }

        #expect(store.updatePreparationState == .idle)
        #expect(store.updatePreparationProof == nil)
        #expect(!store.consumePreparedInstallTerminationAuthorization())
        #expect(store.isRunning)

        // A normal mutation reaches its own validation path instead of the
        // stable Updating error, proving the failed barrier was released.
        await store.setTunEnabled(true)
        #expect(store.lastError?.title != "Updating Vela")
        await processManager.finishEvents()
    }

    @Test("Update recovery Safe Mode blocks mutations but still allows a proven quit")
    func updateRecoverySafeModeIsReadOnlyAndTerminatesSafely() async {
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )

        await store.bootstrap()
        await store.enterUpdateRecoverySafeMode()
        await store.start()

        #expect(!store.isRunning)
        #expect(store.lastError?.title == "Updating Vela")
        #expect(store.lastError?.technicalDetails == "updateInProgress")
        #expect(await processManager.startCallCount() == 0)

        #expect(await store.prepareForTermination())
        #expect(await processManager.stopCallCount() == 0)
        await processManager.finishEvents()
    }

    @Test("Update recovery restores user runtime once and proves System Proxy")
    func updateRecoveryIsProofBearingAndSingleAttempt() async throws {
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let controllerManager = EngineStoreControllerManagerFake(
            emitsReadyOnStart: true
        )
        let systemProxyManager = EngineStoreSystemProxyManagerFake()
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager,
            systemProxyManager: systemProxyManager
        )
        await store.bootstrap()

        let snapshot = UpdateRuntimeSnapshot(
            profileID: profile.id,
            backend: .userProcess,
            systemProxyDesired: true,
            mihomoMode: .rule
        )
        let proof = try await store.recoverAfterUpdate(snapshot)

        #expect(proof.isHealthy)
        #expect(proof.profileRestored)
        #expect(proof.backendRestored)
        #expect(proof.healthVerified)
        #expect(proof.systemProxyRestored)
        #expect(store.updateRecoveryAttempted)
        #expect(!store.isUpdateRecoveryInProgress)
        #expect(store.isRunning)
        #expect(store.activeBackendKind == .userProcess)
        #expect(store.isSystemProxyApplied)
        #expect(await processManager.startCallCount() == 1)
        #expect(await systemProxyManager.enableCallCount() == 1)

        await #expect(throws: EngineUpdateRecoveryError.alreadyAttempted) {
            try await store.recoverAfterUpdate(snapshot)
        }
        #expect(await processManager.startCallCount() == 1)
        await processManager.finishEvents()
    }

    @Test("Starting without a profile reports an error without launching")
    func startWithoutProfileDoesNotLaunch() async {
        let profileManager = EngineStoreProfileManagerFake()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let resolver = EngineStoreExecutableResolverFake()
        let validator = EngineStoreConfigurationValidatorFake(
            result: EngineStoreTestValues.validValidation,
            suspendValidation: false
        )
        let store = makeStore(
            profileManager: profileManager,
            resolver: resolver,
            validator: validator,
            processManager: processManager
        )

        await store.bootstrap()
        await store.start()

        #expect(store.state == .stopped)
        #expect(store.lastError?.title == "No profile selected")
        #expect(await profileManager.buildCallCount() == 0)
        #expect(await resolver.callCount() == 0)
        #expect(await validator.callCount() == 0)
        #expect(await processManager.startCallCount() == 0)
        await processManager.finishEvents()
    }

    @Test("Validation exposes validating state and returns to stopped")
    func validationStateTransition() async {
        let profile = makeProfile()
        let profileManager = EngineStoreProfileManagerFake(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        let validator = EngineStoreConfigurationValidatorFake(
            result: EngineStoreTestValues.validValidation,
            suspendValidation: true
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: profileManager,
            resolver: EngineStoreExecutableResolverFake(),
            validator: validator,
            processManager: processManager
        )
        await store.bootstrap()

        let validationTask = Task { @MainActor in
            await store.validateSelectedProfile()
        }
        await waitForValidatorCall(validator)

        #expect(store.state == .validating)
        await validator.releaseValidation()
        await validationTask.value

        #expect(store.state == .stopped)
        #expect(store.validationResult?.status == .valid)
        #expect(store.resolvedExecutable == EngineStoreTestValues.executable)
        #expect(await profileManager.buildCallCount() == 1)
        await processManager.finishEvents()
    }

    @Test("A repeated start does not launch a second process")
    func repeatedStartIsIdempotent() async {
        let profile = makeProfile()
        let profileManager = EngineStoreProfileManagerFake(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        let resolver = EngineStoreExecutableResolverFake()
        let validator = EngineStoreConfigurationValidatorFake(
            result: EngineStoreTestValues.validValidation,
            suspendValidation: false
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: profileManager,
            resolver: resolver,
            validator: validator,
            processManager: processManager
        )
        await store.bootstrap()

        await store.start()
        await store.start()

        #expect(store.isRunning)
        #expect(await processManager.startCallCount() == 1)
        #expect(await profileManager.buildCallCount() == 1)
        #expect(await resolver.callCount() == 1)
        #expect(await validator.callCount() == 1)
        await processManager.finishEvents()
    }

    @Test("Stop during validation prevents the suspended start from launching")
    func stopDuringValidationCancelsStaleStart() async {
        let profile = makeProfile()
        let replacementProfile = Profile(
            id: UUID(),
            name: "Replacement",
            originalFileName: "replacement.yaml",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let validator = EngineStoreConfigurationValidatorFake(
            result: EngineStoreTestValues.validValidation,
            suspendValidation: true
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let profileManager = EngineStoreProfileManagerFake(
            profiles: [profile, replacementProfile],
            selectedProfileID: profile.id
        )
        let store = makeStore(
            profileManager: profileManager,
            resolver: EngineStoreExecutableResolverFake(),
            validator: validator,
            processManager: processManager
        )
        await store.bootstrap()

        let startTask = Task { @MainActor in
            await store.start()
        }
        await waitForValidatorCall(validator)
        #expect(store.state == .validating)

        let stopCompletion = EngineStoreCompletionProbe()
        let stopTask = Task { @MainActor in
            await store.stop()
            await stopCompletion.markCompleted()
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!(await stopCompletion.isCompleted()))
        #expect(store.state == .validating)

        let profileMutationTask = Task { @MainActor in
            await store.selectProfile(id: replacementProfile.id)
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await profileManager.selectCallCount() == 0)
        #expect(store.selectedProfileID == profile.id)

        await validator.releaseValidation()
        await startTask.value
        await stopTask.value
        await profileMutationTask.value

        #expect(store.state == .stopped)
        #expect(await processManager.startCallCount() == 0)
        #expect(await profileManager.selectCallCount() == 0)
        #expect(store.selectedProfileID == profile.id)
        await processManager.finishEvents()
    }

    @Test("Quit during suspended validation waits for validator cleanup before returning safe")
    func quitDuringValidationCancelsStaleStart() async {
        let profile = makeProfile()
        let validator = EngineStoreConfigurationValidatorFake(
            result: EngineStoreTestValues.validValidation,
            suspendValidation: true
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: validator,
            processManager: processManager
        )
        await store.bootstrap()

        let startTask = Task { @MainActor in
            await store.start()
        }
        await waitForValidatorCall(validator)
        #expect(store.state == .validating)

        let terminationCompletion = EngineStoreCompletionProbe()
        let terminationTask = Task { @MainActor in
            let result = await store.prepareForTermination()
            await terminationCompletion.markCompleted()
            return result
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!(await terminationCompletion.isCompleted()))
        #expect(store.state == .validating)

        await validator.releaseValidation()
        let safeToTerminate = await terminationTask.value
        #expect(safeToTerminate)
        #expect(store.state == .stopped)
        #expect(await processManager.startCallCount() == 0)

        await startTask.value

        #expect(store.state == .stopped)
        #expect(await processManager.startCallCount() == 0)
        await processManager.finishEvents()
    }

    @Test("Quit fails closed when validator cleanup exceeds its shutdown bound")
    func quitDuringValidationTimesOutWithoutClaimingStopped() async {
        let profile = makeProfile()
        let validator = EngineStoreConfigurationValidatorFake(
            result: EngineStoreTestValues.validValidation,
            suspendValidation: true
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: validator,
            processManager: processManager,
            validationShutdownWaitTimeout: .milliseconds(20),
            validationShutdownPollInterval: .milliseconds(1)
        )
        await store.bootstrap()

        let startTask = Task { @MainActor in
            await store.start()
        }
        await waitForValidatorCall(validator)

        let safeToTerminate = await store.prepareForTermination()

        #expect(!safeToTerminate)
        #expect(store.lastError?.title == "Validation Cleanup Is Still Running")
        #expect(store.state != .stopped)
        #expect(await processManager.stopCallCount() == 0)
        #expect(await processManager.startCallCount() == 0)

        await validator.releaseValidation()
        await startTask.value
        await store.stop()
        #expect(store.state == .stopped)
        await processManager.finishEvents()
    }

    @Test("Stop verifies and cleans an untracked user process during validation")
    func stopDuringValidationCleansUntrackedRunningProcess() async {
        let profile = makeProfile()
        let validator = EngineStoreConfigurationValidatorFake(
            result: EngineStoreTestValues.validValidation,
            suspendValidation: true
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: validator,
            processManager: processManager
        )
        await store.bootstrap()

        let startTask = Task { @MainActor in
            await store.start()
        }
        await waitForValidatorCall(validator)
        #expect(store.state == .validating)
        await processManager.simulateUntrackedRunningProcess()

        let stopCompletion = EngineStoreCompletionProbe()
        let stopTask = Task { @MainActor in
            await store.stop()
            await stopCompletion.markCompleted()
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!(await stopCompletion.isCompleted()))
        #expect(await processManager.stopCallCount() == 0)

        await validator.releaseValidation()
        await stopTask.value

        #expect(store.state == .stopped)
        #expect(await processManager.stopCallCount() == 1)
        #expect(!(await processManager.isRunning()))
        #expect(await processManager.startCallCount() == 0)

        await startTask.value
        #expect(store.state == .stopped)
        #expect(await processManager.startCallCount() == 0)
        await processManager.finishEvents()
    }

    @Test("Validation shutdown blocks a queued Start until Stop finishes")
    func validationShutdownRejectsQueuedStart() async {
        let profile = makeProfile()
        let validator = EngineStoreConfigurationValidatorFake(
            result: EngineStoreTestValues.validValidation,
            suspendValidation: true,
            resumesWhenCancelled: true,
            suspendsOnlyFirstCall: true
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: validator,
            processManager: processManager
        )
        await store.bootstrap()

        let firstStartTask = Task { @MainActor in
            await store.start()
        }
        await waitForValidatorCall(validator)
        await processManager.suspendNextIsRunningCall()

        let stopTask = Task { @MainActor in
            await store.stop()
        }
        await waitForSuspendedIsRunning(processManager)

        let queuedStartTask = Task { @MainActor in
            await store.start()
        }
        await queuedStartTask.value
        #expect(await validator.callCount() == 1)
        #expect(await processManager.startCallCount() == 0)

        await processManager.releaseIsRunningCall()
        await stopTask.value
        await firstStartTask.value

        #expect(store.state == .stopped)
        #expect(await processManager.startCallCount() == 0)
        #expect(!(await processManager.isRunning()))
        await processManager.finishEvents()
    }

    @Test("Stopping an already stopped engine is idempotent")
    func stoppedStopIsIdempotent() async {
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )

        await store.stop()

        #expect(store.state == .stopped)
        #expect(await processManager.stopCallCount() == 0)
        await processManager.finishEvents()
    }

    @Test("A failed stop keeps the verified running state and blocks a second start")
    func failedStopPreservesRunningState() async {
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(
            isRunning: false,
            stopFailure: .simulatedStopFailure
        )
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )
        await store.bootstrap()
        await store.start()

        await store.stop()

        #expect(store.isRunning)
        #expect(!store.canStart)
        #expect(store.lastError?.title == "Mihomo is still running")
        #expect(await processManager.startCallCount() == 1)
        #expect(await processManager.stopCallCount() == 1)
        await processManager.finishEvents()
    }

    @Test("Restart stops a running process before starting it")
    func restartOrdersStopBeforeStart() async {
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(isRunning: true)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )
        await store.bootstrap()
        await processManager.resetOperations()

        await store.restart()

        #expect(store.isRunning)
        #expect(await processManager.operations() == [.isRunning, .stop, .start])
        await processManager.finishEvents()
    }

    @Test("Bootstrap reads the true system proxy state without changing it")
    func bootstrapOnlyInspectsSystemProxy() async {
        let systemProxyManager = EngineStoreSystemProxyManagerFake()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            systemProxyManager: systemProxyManager
        )

        await store.bootstrap()

        #expect(store.systemProxyStatus.aggregate == .disabled)
        #expect(await systemProxyManager.statusCallCount() == 1)
        #expect(await systemProxyManager.enableCallCount() == 0)
        #expect(await systemProxyManager.restoreCallCount() == 0)
        await processManager.finishEvents()
    }

    @Test("Termination skips redundant restore after a verified disabled status")
    func terminationSkipsRestoreForVerifiedDisabledSystemProxy() async {
        let systemProxyManager = EngineStoreSystemProxyManagerFake()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            systemProxyManager: systemProxyManager
        )

        await store.bootstrap()
        let safeToTerminate = await store.prepareForTermination()

        #expect(safeToTerminate)
        #expect(store.systemProxyStatus.aggregate == .disabled)
        #expect(await systemProxyManager.restoreCallCount() == 0)
        await processManager.finishEvents()
    }

    @Test("Termination restores when system proxy status is still unavailable")
    func terminationRestoresWhenSystemProxyStatusIsUnverified() async {
        let systemProxyManager = EngineStoreSystemProxyManagerFake()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            systemProxyManager: systemProxyManager
        )

        #expect(store.systemProxyStatus.aggregate == .unavailable)
        let safeToTerminate = await store.prepareForTermination()

        #expect(safeToTerminate)
        #expect(await systemProxyManager.restoreCallCount() == 1)
        await processManager.finishEvents()
    }

    @Test("Ordinary termination does not probe an idle privileged helper")
    func terminationSkipsIdlePrivilegedHelperProbe() async {
        let helper = EngineStorePrivilegedHelperFake(running: false)
        let componentManager = PrivilegedComponentManager(
            service: EngineStorePrivilegedAppServiceFake(status: .enabled),
            client: helper,
            preflight: EngineStorePrivilegedPreflightFake(),
            openSystemSettingsAction: {}
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            privilegedHelperClient: helper,
            privilegedComponentManager: componentManager
        )

        let safeToTerminate = await store.prepareForTermination()

        #expect(safeToTerminate)
        #expect(await helper.invalidateCallCount() == 0)
        #expect(await helper.statusCallCount() == 0)
        await processManager.finishEvents()
    }

    @Test("A verified system proxy enable updates status and engine health")
    func verifiedSystemProxyEnableUpdatesHealth() async {
        let profile = makeProfile()
        let controllerManager = EngineStoreControllerManagerFake()
        let systemProxyManager = EngineStoreSystemProxyManagerFake()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager,
            systemProxyManager: systemProxyManager
        )
        await store.bootstrap()
        await store.start()
        await controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(store, toEqual: .connected)

        await store.setSystemProxyEnabled(true)

        #expect(store.isSystemProxyApplied)
        #expect(store.systemProxyStatus.aggregate == .applied)
        #expect(await systemProxyManager.enabledTargets() == [
            SystemProxyTarget(host: "127.0.0.1", port: Int(17_890))
        ])
        if case let .running(health) = store.state {
            #expect(health.systemProxyApplied)
        } else {
            Issue.record("Engine should remain running after enabling System Proxy")
        }
        await controllerManager.finishEvents()
        await processManager.finishEvents()
    }

    @Test("Stop restores the system proxy before stopping Mihomo")
    func stopRestoresSystemProxyBeforeProcess() async {
        let recorder = EngineStoreLifecycleRecorder()
        let fixture = await makeSystemProxyManagedStore(recorder: recorder)
        await recorder.reset()

        await fixture.store.stop()

        #expect(await recorder.events() == [.systemProxyRestore, .processStop])
        #expect(fixture.store.state == .stopped)
        #expect(!fixture.store.systemProxyNeedsRestore)
        await fixture.controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("A failed restore keeps Mihomo alive and cancels termination")
    func failedSystemProxyRestoreKeepsProcessRunning() async {
        let recorder = EngineStoreLifecycleRecorder()
        let fixture = await makeSystemProxyManagedStore(
            recorder: recorder,
            restoreFailure: .simulatedRestoreFailure
        )
        await recorder.reset()

        let safeToTerminate = await fixture.store.prepareForTermination()

        #expect(!safeToTerminate)
        #expect(fixture.store.isRunning)
        #expect(!fixture.store.isBusy)
        #expect(await fixture.processManager.stopCallCount() == 0)
        #expect(await recorder.events() == [.systemProxyRestore, .systemProxyStatus])
        #expect(fixture.store.lastError?.title == "Mihomo was kept running to protect connectivity")
        await fixture.controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Restore and readback failure fail closed even with a stale empty cache")
    func restoreReadbackFailureNeverTrustsStaleProxyCache() async {
        let profile = makeProfile()
        let controllerManager = EngineStoreControllerManagerFake()
        let systemProxyManager = EngineStoreSystemProxyManagerFake(
            restoreFailure: .simulatedRestoreFailure
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager,
            systemProxyManager: systemProxyManager
        )
        await store.bootstrap()
        #expect(!store.systemProxyNeedsRestore)
        await store.start()
        await controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(store, toEqual: .connected)
        await systemProxyManager.simulateUnpublishedRecoveryAndStatusFailure()

        let safeToTerminate = await store.prepareForTermination()

        #expect(!safeToTerminate)
        #expect(store.isRunning)
        #expect(await processManager.stopCallCount() == 0)
        #expect(store.lastError?.title == "Mihomo was kept running to protect connectivity")
        await controllerManager.finishEvents()
        await processManager.finishEvents()
    }

    @Test("Unexpected exit warns when System Proxy readback cannot be verified")
    func unexpectedExitWithProxyReadbackFailureShowsFailSafeWarning() async {
        let profile = makeProfile()
        let systemProxyManager = EngineStoreSystemProxyManagerFake()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            systemProxyManager: systemProxyManager
        )
        await store.bootstrap()
        await store.start()
        await systemProxyManager.simulateStatusReadbackFailure()

        await processManager.emit(
            .terminated(EngineStoreTestValues.unexpectedTermination(status: 9))
        )
        await waitForState(
            store,
            toEqual: .failed(.unexpectedTermination(exitCode: 9))
        )

        #expect(
            store.lastError?.title
                == "Mihomo stopped before System Proxy cleanup was verified"
        )
        #expect(store.lastError?.message.contains("status 9") == true)
        #expect(store.lastError?.technicalDetails?.contains("readback failed") == true)
        await processManager.finishEvents()
    }

    @Test("Missing-only recovery is retained without blocking Stop")
    func missingOnlySystemProxyRecoveryAllowsStop() async {
        let profile = makeProfile()
        let systemProxyManager = EngineStoreSystemProxyManagerFake()
        await systemProxyManager.simulateMissingOnlyRecovery()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            systemProxyManager: systemProxyManager
        )
        await store.bootstrap()
        #expect(store.systemProxyNeedsRestore)
        await store.start()

        await store.stop()

        #expect(store.state == .stopped)
        #expect(store.systemProxyNeedsRestore)
        #expect(await processManager.stopCallCount() == 1)
        #expect(
            store.lastError?.title
                == "System proxy recovery is waiting for unavailable services"
        )
        await processManager.finishEvents()
    }

    @Test("A visible external Vela endpoint blocks Stop")
    func externalSystemProxyTargetKeepsMihomoRunning() async {
        let profile = makeProfile()
        let systemProxyManager = EngineStoreSystemProxyManagerFake()
        await systemProxyManager.simulateExternalTargetWithoutOwnership()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            systemProxyManager: systemProxyManager
        )
        await store.bootstrap()
        await store.start()

        await store.stop()

        #expect(store.isRunning)
        #expect(await processManager.stopCallCount() == 0)
        #expect(store.lastError?.title == "Mihomo was kept running to protect connectivity")
        #expect(store.lastError?.message.contains("Wi-Fi") == true)
        await processManager.finishEvents()
    }

    @Test("Unexpected exit reports a visible external Vela endpoint")
    func unexpectedExitReportsExternalSystemProxyTarget() async {
        let profile = makeProfile()
        let systemProxyManager = EngineStoreSystemProxyManagerFake()
        await systemProxyManager.simulateExternalTargetWithoutOwnership()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            systemProxyManager: systemProxyManager
        )
        await store.bootstrap()
        await store.start()

        await processManager.emit(
            .terminated(EngineStoreTestValues.unexpectedTermination(status: 9))
        )
        await waitForState(
            store,
            toEqual: .failed(.unexpectedTermination(exitCode: 9))
        )

        #expect(store.lastError?.title == "System Proxy still points to stopped Mihomo")
        #expect(store.lastError?.message.contains("Wi-Fi") == true)
        await processManager.finishEvents()
    }

    @Test("Restart restores, restarts, then reapplies after Controller readiness")
    func restartReappliesManagedSystemProxy() async {
        let recorder = EngineStoreLifecycleRecorder()
        let fixture = await makeSystemProxyManagedStore(recorder: recorder)
        await recorder.reset()

        await fixture.store.restart()

        #expect(await recorder.events() == [
            .systemProxyRestore, .processStop, .processStart
        ])
        #expect(fixture.store.controllerState == .connecting)

        await fixture.controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForSystemProxyEnableCount(fixture.systemProxyManager, expected: 2)

        #expect(await recorder.events() == [
            .systemProxyRestore, .processStop, .processStart, .systemProxyEnable
        ])
        #expect(fixture.store.isSystemProxyApplied)
        await fixture.controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Profile selection restarts infrastructure and restores System Proxy")
    func profileSelectionRestoresManagedSystemProxy() async {
        let firstProfile = makeProfile()
        let secondProfile = Profile(
            id: UUID(),
            name: "Second",
            originalFileName: "second.yaml",
            createdAt: Date(timeIntervalSince1970: 1_700_000_010),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let recorder = EngineStoreLifecycleRecorder()
        let processManager = EngineStoreProcessManagerFake(
            isRunning: false,
            lifecycleRecorder: recorder
        )
        let controllerManager = EngineStoreControllerManagerFake()
        let systemProxyManager = EngineStoreSystemProxyManagerFake(
            lifecycleRecorder: recorder
        )
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [firstProfile, secondProfile],
                selectedProfileID: firstProfile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager,
            systemProxyManager: systemProxyManager
        )
        await store.bootstrap()
        await store.start()
        await controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(store, toEqual: .connected)
        await store.setSystemProxyEnabled(true)
        await recorder.reset()

        let selection = Task { @MainActor in
            await store.selectProfile(id: secondProfile.id)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline, await processManager.startCallCount() < 2 {
            try? await clock.sleep(for: .milliseconds(1))
        }
        await controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await selection.value

        #expect(store.selectedProfileID == secondProfile.id)
        #expect(store.isRunning)
        #expect(store.isSystemProxyApplied)
        #expect(await recorder.events() == [
            .systemProxyRestore, .processStop, .processStart, .systemProxyEnable,
        ])
        await controllerManager.finishEvents()
        await processManager.finishEvents()
    }

    @Test("Restart preserves external proxy conflicts and does not reapply")
    func restartDoesNotOverwriteExternalProxyConflict() async {
        let recorder = EngineStoreLifecycleRecorder()
        let fixture = await makeSystemProxyManagedStore(
            recorder: recorder,
            restoreConflicts: true
        )
        await recorder.reset()

        await fixture.store.restart()
        await fixture.controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(fixture.store, toEqual: .connected)
        for _ in 0..<20 { await Task.yield() }

        #expect(await fixture.systemProxyManager.enableCallCount() == 1)
        #expect(await recorder.events() == [
            .systemProxyRestore, .processStop, .processStart
        ])
        #expect(
            fixture.store.lastError?.title
                == "External proxy changes were not overwritten"
        )
        await fixture.controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Unexpected Mihomo exit reports any owned system proxy recovery")
    func unexpectedExitReportsSystemProxyRecovery() async {
        let recorder = EngineStoreLifecycleRecorder()
        let fixture = await makeSystemProxyManagedStore(recorder: recorder)
        await recorder.reset()

        await fixture.processManager.emit(
            .terminated(EngineStoreTestValues.unexpectedTermination(status: 9))
        )
        await waitForState(
            fixture.store,
            toEqual: .failed(.unexpectedTermination(exitCode: 9))
        )

        #expect(fixture.store.systemProxyNeedsRestore)
        #expect(
            fixture.store.lastError?.title
                == "Mihomo stopped while System Proxy needs recovery"
        )
        #expect(await recorder.events() == [.systemProxyStatus])
        await fixture.controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("A late enable result cannot overwrite Stop cleanup")
    func lateSystemProxyEnableCannotWinOverStop() async {
        let profile = makeProfile()
        let recorder = EngineStoreLifecycleRecorder()
        let controllerManager = EngineStoreControllerManagerFake()
        let systemProxyManager = EngineStoreSystemProxyManagerFake(
            suspendsEnable: true,
            lifecycleRecorder: recorder
        )
        let processManager = EngineStoreProcessManagerFake(
            isRunning: false,
            lifecycleRecorder: recorder
        )
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager,
            systemProxyManager: systemProxyManager
        )
        await store.bootstrap()
        await store.start()
        await controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(store, toEqual: .connected)
        await recorder.reset()

        let enableTask = Task { @MainActor in
            await store.setSystemProxyEnabled(true)
        }
        await waitForSystemProxyEnableToSuspend(systemProxyManager)

        let stopTask = Task { @MainActor in
            await store.stop()
        }
        await Task.yield()
        await systemProxyManager.releaseEnable()
        await enableTask.value
        await stopTask.value

        #expect(store.state == .stopped)
        #expect(!store.systemProxyNeedsRestore)
        #expect(store.systemProxyStatus.aggregate == .disabled)
        #expect(await recorder.events() == [
            .systemProxyEnable, .systemProxyRestore, .processStop
        ])
        await controllerManager.finishEvents()
        await processManager.finishEvents()
    }

    @Test("Rapid System Proxy requests converge to the latest requested state")
    func rapidSystemProxyRequestsUseLatestState() async {
        let profile = makeProfile()
        let controllerManager = EngineStoreControllerManagerFake()
        let systemProxyManager = EngineStoreSystemProxyManagerFake(
            suspendsEnable: true
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager,
            systemProxyManager: systemProxyManager
        )
        await store.bootstrap()
        await store.start()
        await controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(store, toEqual: .connected)

        store.requestSystemProxyEnabled(true)
        await waitForSystemProxyEnableToSuspend(systemProxyManager)
        store.requestSystemProxyEnabled(false)
        await systemProxyManager.releaseEnable()
        await waitForSystemProxyRestoreCount(systemProxyManager, expected: 1)

        #expect(await systemProxyManager.enableCallCount() == 1)
        #expect(await systemProxyManager.restoreCallCount() == 1)
        #expect(!store.isSystemProxyApplied)
        #expect(store.systemProxyStatus.aggregate == .disabled)
        #expect(store.systemProxyOperation == nil)

        await store.stop()
        await controllerManager.finishEvents()
        await processManager.finishEvents()
    }

    @Test("A stale health refresh cannot overwrite a completed Stop")
    func staleHealthRefreshCannotReviveStoppedState() async {
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )
        await store.bootstrap()
        await store.start()
        #expect(store.isRunning)
        await processManager.suspendNextIsRunningCall()

        let refreshTask = Task { @MainActor in
            await store.refreshHealth()
        }
        await waitForSuspendedIsRunning(processManager)

        await store.stop()
        #expect(store.state == .stopped)
        await processManager.releaseIsRunningCall()
        await refreshTask.value

        #expect(store.state == .stopped)
        #expect(!store.isRunning)
        await processManager.finishEvents()
    }

    @Test("Termination prevents a suspended Restart from starting Mihomo again")
    func terminationBarrierStopsSuspendedRestartFromRelaunching() async {
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )
        await store.bootstrap()
        await store.start()
        #expect(store.isRunning)
        #expect(await processManager.startCallCount() == 1)
        await processManager.suspendNextIsRunningCall()

        let restartTask = Task { @MainActor in
            await store.restart()
        }
        await waitForSuspendedIsRunning(processManager)

        let terminationTask = Task { @MainActor in
            await store.prepareForTermination()
        }
        for _ in 0..<1_000 {
            if store.isBusy { break }
            await Task.yield()
        }
        #expect(store.isBusy)

        await processManager.releaseIsRunningCall()
        await restartTask.value
        let safeToTerminate = await terminationTask.value
        #expect(safeToTerminate)
        #expect(store.state == .stopped)
        #expect(await processManager.stopCallCount() == 1)

        #expect(store.state == .stopped)
        #expect(!store.canStart)
        #expect(await processManager.startCallCount() == 1)
        await processManager.finishEvents()
    }

    @Test("An unexpected termination moves the engine to failed")
    func unexpectedTerminationUpdatesState() async {
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )
        await store.bootstrap()
        await store.start()
        #expect(store.isRunning)

        await processManager.emit(
            .terminated(EngineStoreTestValues.unexpectedTermination(status: 9))
        )
        await waitForState(store, toEqual: .failed(.unexpectedTermination(exitCode: 9)))

        #expect(store.state == .failed(.unexpectedTermination(exitCode: 9)))
        #expect(store.lastError?.message.contains("status 9") == true)
        await processManager.finishEvents()
    }

    @Test("Controller events update health, telemetry, mode actions, and process logs")
    func controllerLifecycleIsIntegrated() async {
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let controllerManager = EngineStoreControllerManagerFake()
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager
        )
        await store.bootstrap()

        await store.start()
        #expect(store.isRunning)
        #expect(store.controllerState == .connecting)
        #expect(await controllerManager.startCallCount() == 1)

        await controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(store, toEqual: .connected)

        #expect(store.controllerVersion == "1.19.28-test")
        #expect(store.runtimeMode == .rule)
        if case let .running(health) = store.state {
            #expect(health.controllerReachable)
        } else {
            Issue.record("Engine should remain running after Controller readiness")
        }

        await controllerManager.emit(.trafficUpdated(EngineStoreTestValues.trafficSample))
        await controllerManager.emit(.logsUpdated([EngineStoreTestValues.controllerLog]))
        await waitForTelemetry(store)
        #expect(store.trafficSample == EngineStoreTestValues.trafficSample)
        #expect(store.logEntries == [EngineStoreTestValues.controllerLog])

        let processOutput = MihomoProcessOutput(
            id: UUID(),
            channel: .stderr,
            text: "process warning",
            timestamp: Date(timeIntervalSince1970: 1_700_000_003)
        )
        await processManager.emit(.output(processOutput))
        #expect(await waitForProcessOutput(processOutput, in: controllerManager))

        await store.changeMode(.global)
        #expect(await controllerManager.changedModes() == [.global])

        await controllerManager.emit(.unavailable("connection refused"))
        await waitForControllerState(store, toEqual: .unavailable("connection refused"))
        #expect(store.isRunning)
        #expect(store.lastControllerError == "connection refused")

        await store.stop()
        #expect(store.state == .stopped)
        #expect(store.controllerState == .disconnected)
        #expect(await controllerManager.stopCallCount() == 1)

        await controllerManager.finishEvents()
        await processManager.finishEvents()
    }

    @Test("Traffic telemetry does not invalidate proxy catalog observers")
    func trafficUpdatesKeepProxyCatalogObservationNarrow() async {
        let controllerManager = EngineStoreControllerManagerFake()
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager
        )
        let store = fixture.store

        let invalidation = EngineStoreObservationProbe()
        withObservationTracking {
            _ = store.proxyCatalog
        } onChange: {
            Task { await invalidation.recordInvalidation() }
        }

        await controllerManager.emit(.trafficUpdated(EngineStoreTestValues.trafficSample))
        let clock = ContinuousClock()
        let trafficDeadline = clock.now.advanced(by: .seconds(2))
        while store.trafficSample != EngineStoreTestValues.trafficSample,
            clock.now < trafficDeadline
        {
            try? await clock.sleep(for: .milliseconds(1))
        }
        try? await clock.sleep(for: .milliseconds(20))
        #expect(!(await invalidation.hasInvalidated()))

        await controllerManager.emit(.proxiesUpdated(MihomoProxiesResponse(proxies: [:])))
        let invalidationDeadline = clock.now.advanced(by: .seconds(2))
        while !(await invalidation.hasInvalidated()), clock.now < invalidationDeadline {
            try? await clock.sleep(for: .milliseconds(1))
        }
        #expect(await invalidation.hasInvalidated())

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Proxy updates map the Controller response into a trusted catalog")
    func proxyUpdatesMapCatalog() async {
        let controllerManager = EngineStoreControllerManagerFake()
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager
        )

        let catalog = fixture.store.proxyCatalog
        #expect(catalog.groups.map(\.name) == ["Proxy"])
        let group = catalog.group(named: "Proxy")
        #expect(group?.type == "Selector")
        #expect(group?.now == "Hong Kong 01")
        #expect(group?.testURL == "https://example.com/generate_204")
        #expect(group?.expectedStatus == "204")
        #expect(group?.nodes.map(\.name) == [
            "Hong Kong 01", "Japan 02", "United States 01"
        ])
        #expect(group?.nodes.first?.type == "Shadowsocks")
        #expect(group?.nodes.first?.delay == .measured(milliseconds: 75))
        #expect(group?.nodes.first?.isCurrent == true)
        #expect(group?.nodes.dropFirst().first?.delay == .unavailable)
        #expect(group?.nodes.last?.delay == .untested)
        #expect(fixture.store.proxyCatalogError == nil)
        #expect(!fixture.store.isLoadingProxies)

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Background proxy refresh stays silent while the Controller is disconnected")
    func disconnectedBackgroundProxyRefreshDoesNotPresentError() async {
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager
        )

        await store.refreshProxies(presentErrors: false)
        #expect(store.lastError == nil)

        await store.refreshProxies()
        #expect(store.lastError?.title == "Controller unavailable")

        await processManager.finishEvents()
    }

    @Test("A verified proxy selection records recency only after manager success")
    func verifiedProxySelectionRecordsRecentProxy() async {
        let recentProxyStore = EngineStoreRecentProxyStoreFake()
        let controllerManager = EngineStoreControllerManagerFake()
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager,
            recentProxyStore: recentProxyStore
        )

        await fixture.store.selectProxy(group: "Proxy", proxy: "Japan 02")

        #expect(await controllerManager.proxySelectionRequests() == [
            EngineStoreProxySelectionRequest(
                groupName: "Proxy",
                proxyName: "Japan 02"
            )
        ])
        let recorded = await recentProxyStore.recordedRecords()
        #expect(recorded.count == 1)
        #expect(recorded.first?.profileID == EngineStoreTestValues.profileID)
        #expect(recorded.first?.groupName == "Proxy")
        #expect(recorded.first?.proxyName == "Japan 02")
        #expect(fixture.store.recentProxies.map(\.proxyName) == ["Japan 02"])
        #expect(fixture.store.proxyOperation == nil)
        #expect(fixture.store.lastError == nil)

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Rapid proxy selections submit only the latest pending choice")
    func rapidProxySelectionsUseLatestChoice() async {
        let recentProxyStore = EngineStoreRecentProxyStoreFake()
        let controllerManager = EngineStoreControllerManagerFake()
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager,
            recentProxyStore: recentProxyStore
        )

        fixture.store.requestProxySelection(group: "Proxy", proxy: "Japan 02")
        fixture.store.requestProxySelection(group: "Proxy", proxy: "United States 01")
        await waitForProxySelectionCount(controllerManager, expected: 1)

        #expect(await controllerManager.proxySelectionRequests() == [
            EngineStoreProxySelectionRequest(
                groupName: "Proxy",
                proxyName: "United States 01"
            )
        ])
        #expect(await recentProxyStore.recordedRecords().map(\.proxyName) == [
            "United States 01"
        ])
        #expect(fixture.store.proxyOperation == nil)

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("An automatic group can pin the node that is currently active")
    func automaticGroupCanPinItsCurrentNode() async {
        let recentProxyStore = EngineStoreRecentProxyStoreFake()
        let controllerManager = EngineStoreControllerManagerFake()
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager,
            recentProxyStore: recentProxyStore
        )
        var proxies = EngineStoreTestValues.proxyResponse.proxies
        proxies["Proxy"] = EngineStoreTestValues.proxy(
            name: "Proxy",
            type: "URLTest",
            now: "Hong Kong 01",
            all: ["Hong Kong 01", "Japan 02"],
            testURL: "https://example.com/generate_204",
            expectedStatus: "204"
        )
        await controllerManager.emit(
            .proxiesUpdated(MihomoProxiesResponse(proxies: proxies))
        )
        await waitForProxyCatalog(
            fixture.store,
            toEqual: ProxyCatalog(
                response: MihomoProxiesResponse(proxies: proxies)
            )
        )

        await fixture.store.selectProxy(group: "Proxy", proxy: "Hong Kong 01")

        #expect(await controllerManager.proxySelectionRequests() == [
            EngineStoreProxySelectionRequest(
                groupName: "Proxy",
                proxyName: "Hong Kong 01"
            )
        ])
        #expect(await recentProxyStore.recordedRecords().map(\.proxyName) == [
            "Hong Kong 01"
        ])

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("A failed proxy selection preserves catalog state and does not record recency")
    func failedProxySelectionPreservesCatalogAndRecency() async {
        let recentProxyStore = EngineStoreRecentProxyStoreFake()
        let controllerManager = EngineStoreControllerManagerFake(
            proxySelectionFailure: .simulatedProxySelectionFailure
        )
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager,
            recentProxyStore: recentProxyStore
        )
        let originalCatalog = fixture.store.proxyCatalog

        await fixture.store.selectProxy(group: "Proxy", proxy: "Japan 02")

        #expect(fixture.store.proxyCatalog == originalCatalog)
        #expect(fixture.store.proxyCatalog.group(named: "Proxy")?.now == "Hong Kong 01")
        #expect(await recentProxyStore.recordedRecords().isEmpty)
        #expect(fixture.store.recentProxies.isEmpty)
        #expect(fixture.store.proxyOperation == nil)
        #expect(fixture.store.lastError?.title == "Proxy switch failed")

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Single and group delay results map into node delay states")
    func delayResultsMapToProxyStates() async {
        let controllerManager = EngineStoreControllerManagerFake(
            singleDelayResult: MihomoProxyDelayResult(
                proxyName: "Japan 02",
                delayMilliseconds: 88
            ),
            groupDelayResults: [
                MihomoProxyDelayResult(
                    proxyName: "Hong Kong 01",
                    delayMilliseconds: 51
                ),
                MihomoProxyDelayResult(
                    proxyName: "Japan 02",
                    delayMilliseconds: nil,
                    errorDescription: "request timed out"
                ),
                MihomoProxyDelayResult(
                    proxyName: "United States 01",
                    delayMilliseconds: nil
                )
            ]
        )
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager
        )

        await fixture.store.testProxyDelay(group: "Proxy", proxy: "Japan 02")

        #expect(
            fixture.store.proxyDelayState(group: "Proxy", proxy: "Japan 02")
                == .measured(milliseconds: 88)
        )
        #expect(await controllerManager.singleDelayRequests() == [
            EngineStoreSingleDelayRequest(
                name: "Japan 02",
                url: "https://example.com/generate_204",
                timeoutMilliseconds: 5_000,
                expectedStatus: "204"
            )
        ])

        await fixture.store.testProxyGroupDelay(group: "Proxy")

        #expect(
            fixture.store.proxyDelayState(group: "Proxy", proxy: "Hong Kong 01")
                == .measured(milliseconds: 51)
        )
        #expect(
            fixture.store.proxyDelayState(group: "Proxy", proxy: "Japan 02")
                == .failed("request timed out")
        )
        #expect(
            fixture.store.proxyDelayState(group: "Proxy", proxy: "United States 01")
                == .unavailable
        )
        #expect(await controllerManager.groupDelayRequests() == [
            EngineStoreGroupDelayRequest(
                names: ["Hong Kong 01", "Japan 02", "United States 01"],
                url: "https://example.com/generate_204",
                timeoutMilliseconds: 5_000,
                expectedStatus: "204",
                concurrencyLimit: 4
            )
        ])
        #expect(fixture.store.proxyOperation == nil)

        await controllerManager.emit(
            .proxiesUpdated(EngineStoreTestValues.proxyResponse)
        )
        for _ in 0..<1_000 {
            if fixture.store.proxyDelayStates.isEmpty {
                break
            }
            await Task.yield()
        }
        #expect(fixture.store.proxyDelayStates.isEmpty)

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Same-name provider catalog nodes keep routes without multiplying group members")
    func sameNameProviderDelaysUseCompositeIdentity() async throws {
        let providerAID = ProxyCatalogID(
            origin: .provider(name: "Provider A"),
            name: "Shared Node"
        )
        let providerBID = ProxyCatalogID(
            origin: .provider(name: "Provider B"),
            name: "Shared Node"
        )
        let controllerManager = EngineStoreControllerManagerFake()
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager
        )
        let runtimeResponse = MihomoProxiesResponse(proxies: [
            "Proxy": EngineStoreTestValues.proxy(
                name: "Proxy",
                type: "Selector",
                now: "Shared Node",
                all: ["Shared Node"],
                testURL: "https://example.com/generate_204",
                expectedStatus: "204"
            ),
        ])
        let sharedProxy = EngineStoreTestValues.proxy(
            name: "Shared Node",
            type: "Shadowsocks"
        )
        let providerResponse = MihomoProxyProvidersResponse(providers: [
            "Provider A": MihomoProxyProvider(
                name: "Provider A",
                type: "Proxy",
                vehicleType: "File",
                proxies: [sharedProxy],
                testURL: nil,
                expectedStatus: nil,
                updatedAt: nil
            ),
            "Provider B": MihomoProxyProvider(
                name: "Provider B",
                type: "Proxy",
                vehicleType: "File",
                proxies: [sharedProxy],
                testURL: nil,
                expectedStatus: nil,
                updatedAt: nil
            ),
        ])
        let catalog = ProxyCatalog(
            runtimeResponse: runtimeResponse,
            providerResponse: providerResponse
        )
        await controllerManager.emit(.proxyCatalogUpdated(catalog))
        await waitForProxyCatalog(fixture.store, toEqual: catalog)

        let group = try #require(fixture.store.proxyCatalog.group(named: "Proxy"))
        #expect(group.nodes.count == 1)
        #expect(group.nodes[0].name == "Shared Node")
        #expect(group.nodes[0].isPlaceholder)
        #expect(fixture.store.proxyCatalog.nodes(named: "Shared Node").map(\.id) == [
            providerAID, providerBID,
        ])

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Nested proxy groups resolve to the selected leaf for delay tests")
    func nestedProxyGroupDelayUsesSelectedLeaf() async {
        let controllerManager = EngineStoreControllerManagerFake(
            singleDelayResult: MihomoProxyDelayResult(
                proxyName: "Hong Kong 01",
                delayMilliseconds: 67
            ),
            groupDelayResults: [
                MihomoProxyDelayResult(
                    proxyName: "Hong Kong 01",
                    delayMilliseconds: 71
                )
            ]
        )
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager
        )
        let response = MihomoProxiesResponse(proxies: [
            "Primary": EngineStoreTestValues.proxy(
                name: "Primary",
                type: "Selector",
                now: "Hong Kong",
                all: ["Hong Kong"],
                testURL: "https://outer.example.com/generate_204",
                expectedStatus: "204"
            ),
            "Hong Kong": EngineStoreTestValues.proxy(
                name: "Hong Kong",
                type: "Selector",
                now: "Hong Kong 01",
                all: ["Hong Kong 01"],
                testURL: "https://inner.example.com/generate_204",
                expectedStatus: "200/204"
            ),
            "Hong Kong 01": EngineStoreTestValues.proxy(
                name: "Hong Kong 01",
                type: "AnyTLS"
            ),
        ])
        let catalog = ProxyCatalog(response: response)
        await controllerManager.emit(.proxyCatalogUpdated(catalog))
        await waitForProxyCatalog(fixture.store, toEqual: catalog)

        await fixture.store.testProxyDelay(group: "Primary", proxy: "Hong Kong")

        #expect(await controllerManager.singleDelayRequests() == [
            EngineStoreSingleDelayRequest(
                name: "Hong Kong 01",
                url: "https://inner.example.com/generate_204",
                timeoutMilliseconds: 5_000,
                expectedStatus: "200/204"
            )
        ])
        #expect(
            fixture.store.proxyDelayState(group: "Primary", proxy: "Hong Kong")
                == .measured(milliseconds: 67)
        )

        await fixture.store.testProxyGroupDelay(group: "Primary")

        #expect(await controllerManager.groupDelayRequests() == [
            EngineStoreGroupDelayRequest(
                names: ["Hong Kong 01"],
                url: "https://outer.example.com/generate_204",
                timeoutMilliseconds: 5_000,
                expectedStatus: "204",
                concurrencyLimit: 4
            )
        ])
        #expect(
            fixture.store.proxyDelayState(group: "Primary", proxy: "Hong Kong")
                == .measured(milliseconds: 71)
        )

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Delay cache is scoped by group and test URL")
    func delayCacheIsScopedByGroupAndTestURL() async {
        let controllerManager = EngineStoreControllerManagerFake(
            singleDelayResult: MihomoProxyDelayResult(
                proxyName: "Japan 02",
                delayMilliseconds: 88
            )
        )
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager
        )
        var proxies = EngineStoreTestValues.proxyResponse.proxies
        proxies["Fallback"] = EngineStoreTestValues.proxy(
            name: "Fallback",
            type: "Fallback",
            now: "Japan 02",
            all: ["Japan 02"],
            testURL: "https://status.example.com/ping",
            expectedStatus: "200"
        )
        let response = MihomoProxiesResponse(proxies: proxies)
        await controllerManager.emit(.proxiesUpdated(response))
        await waitForProxyCatalog(
            fixture.store,
            toEqual: ProxyCatalog(response: response)
        )

        await fixture.store.testProxyDelay(group: "Proxy", proxy: "Japan 02")

        #expect(
            fixture.store.proxyDelayState(group: "Proxy", proxy: "Japan 02")
                == .measured(milliseconds: 88)
        )
        #expect(
            fixture.store.proxyDelayState(group: "Fallback", proxy: "Japan 02")
                == nil
        )

        await fixture.store.testProxyDelay(group: "Fallback", proxy: "Japan 02")

        #expect(
            fixture.store.proxyDelayState(group: "Proxy", proxy: "Japan 02")
                == .measured(milliseconds: 88)
        )
        #expect(
            fixture.store.proxyDelayState(group: "Fallback", proxy: "Japan 02")
                == .measured(milliseconds: 88)
        )

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("A late delay result cannot repopulate state after disconnect")
    func lateDelayResultIsRejectedAfterDisconnect() async {
        let controllerManager = EngineStoreControllerManagerFake(
            suspendsSingleDelay: true,
            singleDelayResult: MihomoProxyDelayResult(
                proxyName: "Japan 02",
                delayMilliseconds: 88
            )
        )
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager
        )

        let delayTask = Task { @MainActor in
            await fixture.store.testProxyDelay(group: "Proxy", proxy: "Japan 02")
        }
        for _ in 0..<1_000 {
            if await controllerManager.didStartSingleDelay() {
                break
            }
            await Task.yield()
        }
        #expect(await controllerManager.didStartSingleDelay())

        await controllerManager.emit(.disconnected)
        await waitForControllerState(fixture.store, toEqual: .disconnected)
        await controllerManager.releaseSingleDelay()
        await delayTask.value

        expectProxyRuntimeStateIsCleared(fixture.store)
        #expect(fixture.store.lastError == nil)

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Controller transitions discard proxy state that is no longer trustworthy")
    func controllerTransitionsClearProxyRuntimeState() async {
        let controllerManager = EngineStoreControllerManagerFake()
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager
        )
        await fixture.store.testProxyDelay(group: "Proxy", proxy: "Japan 02")
        await controllerManager.emit(.proxiesUnavailable("stale proxy response"))
        await waitForProxyCatalogError(fixture.store, toEqual: "stale proxy response")

        await controllerManager.emit(.connecting)
        await waitForControllerState(fixture.store, toEqual: .connecting)
        expectProxyRuntimeStateIsCleared(fixture.store)

        await repopulateProxyCatalog(
            in: fixture.store,
            using: controllerManager
        )
        await fixture.store.testProxyDelay(group: "Proxy", proxy: "Japan 02")
        await controllerManager.emit(.unavailable("connection refused"))
        await waitForControllerState(
            fixture.store,
            toEqual: .unavailable("connection refused")
        )
        expectProxyRuntimeStateIsCleared(fixture.store)

        await repopulateProxyCatalog(
            in: fixture.store,
            using: controllerManager
        )
        await fixture.store.testProxyDelay(group: "Proxy", proxy: "Japan 02")
        await controllerManager.emit(.disconnected)
        await waitForControllerState(fixture.store, toEqual: .disconnected)
        expectProxyRuntimeStateIsCleared(fixture.store)

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("Available recent proxies belong to the selected profile and current catalog")
    func availableRecentProxiesFilterProfileAndCatalog() async {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_100)
        let recentProxyStore = EngineStoreRecentProxyStoreFake(loadResult: [
            RecentProxyRecord(
                profileID: EngineStoreTestValues.profileID,
                groupName: "Proxy",
                proxyName: "Hong Kong 01",
                usedAt: timestamp
            ),
            RecentProxyRecord(
                profileID: EngineStoreTestValues.profileID,
                groupName: "Missing Group",
                proxyName: "Hong Kong 01",
                usedAt: timestamp.addingTimeInterval(-1)
            ),
            RecentProxyRecord(
                profileID: EngineStoreTestValues.profileID,
                groupName: "Proxy",
                proxyName: "Removed Node",
                usedAt: timestamp.addingTimeInterval(-2)
            ),
            RecentProxyRecord(
                profileID: EngineStoreTestValues.otherProfileID,
                groupName: "Proxy",
                proxyName: "Japan 02",
                usedAt: timestamp.addingTimeInterval(-3)
            )
        ])
        let controllerManager = EngineStoreControllerManagerFake()
        let fixture = await makeConnectedProxyStore(
            controllerManager: controllerManager,
            recentProxyStore: recentProxyStore
        )

        let available = fixture.store.availableRecentProxies
        #expect(available.count == 1)
        #expect(available.first?.profileID == EngineStoreTestValues.profileID)
        #expect(available.first?.groupName == "Proxy")
        #expect(available.first?.proxyName == "Hong Kong 01")
        #expect(await recentProxyStore.loadedProfileIDs() == [
            EngineStoreTestValues.profileID
        ])

        await controllerManager.finishEvents()
        await fixture.processManager.finishEvents()
    }

    @Test("A slow recent load cannot overwrite a newer profile selection")
    func staleRecentLoadCannotOverwriteNewProfile() async {
        let firstProfile = makeProfile()
        let secondProfile = Profile(
            id: EngineStoreTestValues.otherProfileID,
            name: "Second Profile",
            originalFileName: "second.yaml",
            createdAt: Date(timeIntervalSince1970: 1_700_000_010),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let firstRecord = RecentProxyRecord(
            profileID: firstProfile.id,
            groupName: "Proxy",
            proxyName: "Hong Kong 01",
            usedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let secondRecord = RecentProxyRecord(
            profileID: secondProfile.id,
            groupName: "Proxy",
            proxyName: "Japan 02",
            usedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let recentProxyStore = EngineStoreDelayedRecentProxyStoreFake(
            suspendedProfileID: firstProfile.id,
            recordsByProfile: [
                firstProfile.id: [firstRecord],
                secondProfile.id: [secondRecord],
            ]
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [firstProfile, secondProfile],
                selectedProfileID: firstProfile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            recentProxyStore: recentProxyStore
        )

        let bootstrapTask = Task { @MainActor in
            await store.bootstrap()
        }
        for _ in 0..<1_000 {
            if await recentProxyStore.didStartSuspendedLoad() {
                break
            }
            await Task.yield()
        }
        #expect(await recentProxyStore.didStartSuspendedLoad())

        await store.selectProfile(id: secondProfile.id)
        #expect(store.selectedProfileID == secondProfile.id)
        #expect(store.recentProxies == [secondRecord])

        await recentProxyStore.releaseSuspendedLoad()
        await bootstrapTask.value

        #expect(store.selectedProfileID == secondProfile.id)
        #expect(store.recentProxies == [secondRecord])

        await processManager.finishEvents()
    }

    @Test("Core activation validates the candidate against the current profile before stopping")
    func coreActivationPreStopValidationLeavesRuntimeUntouched() async throws {
        let profile = makeProfile()
        let profileManager = EngineStoreProfileManagerFake(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        let validator = EngineStoreConfigurationValidatorFake(
            result: EngineStoreTestValues.validValidation,
            suspendValidation: false
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: profileManager,
            resolver: EngineStoreExecutableResolverFake(),
            validator: validator,
            processManager: processManager
        )

        await store.bootstrap()
        try await store.validateCoreCandidateForActivation(
            EngineStoreTestValues.executable
        )

        #expect(await validator.callCount() == 1)
        #expect(await profileManager.buildCallCount() == 1)
        #expect(await processManager.stopCallCount() == 0)
        #expect(await processManager.startCallCount() == 0)
        #expect(store.resolvedExecutable == nil)
        await processManager.finishEvents()
    }

    @Test("A candidate that rejects the current profile fails before any runtime mutation")
    func coreActivationPreStopValidationRejectsCandidateWithoutStopping() async {
        let profile = makeProfile()
        let profileManager = EngineStoreProfileManagerFake(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        let invalid = ConfigurationValidationResult(
            status: .invalid(exitCode: 1),
            stdout: "",
            stderr: "configuration rejected",
            issues: [],
            duration: .milliseconds(1)
        )
        let validator = EngineStoreConfigurationValidatorFake(
            result: invalid,
            suspendValidation: false
        )
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: profileManager,
            resolver: EngineStoreExecutableResolverFake(),
            validator: validator,
            processManager: processManager
        )

        await store.bootstrap()
        await #expect(throws: EngineCoreActivationError.configurationRejected) {
            try await store.validateCoreCandidateForActivation(
                EngineStoreTestValues.executable
            )
        }

        #expect(await validator.callCount() == 1)
        #expect(await processManager.stopCallCount() == 0)
        #expect(await processManager.startCallCount() == 0)
        #expect(store.resolvedExecutable == nil)
        await processManager.finishEvents()
    }

    private func makeStore(
        profileManager: EngineStoreProfileManagerFake,
        resolver: EngineStoreExecutableResolverFake,
        validator: EngineStoreConfigurationValidatorFake,
        processManager: EngineStoreProcessManagerFake,
        controllerManager: EngineStoreControllerManagerFake? = nil,
        recentProxyStore: (any RecentProxyStoring)? = nil,
        systemProxyManager: (any SystemProxyManaging)? = nil,
        privilegedBackend: (any EngineBackend)? = nil,
        privilegedHelperClient: (any PrivilegedHelperClientProtocol)? = nil,
        transitionCoordinator: EngineTransitionCoordinator? = nil,
        privilegedLeaseCoordinator: PrivilegedLeaseCoordinator? = nil,
        privilegedComponentManager: PrivilegedComponentManager? = nil,
        localNetworkContextProvider: any LocalNetworkContextProviding = EngineStoreLocalNetworkContextFake(),
        networkPathObserver: (any NetworkPathObserving)? = nil,
        sleepWakeObserver: (any SleepWakeObserving)? = nil,
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
        }
    ) -> EngineStore {
        EngineStore(
            profileStore: profileManager,
            runtimeParameters: RuntimeConfigParameters(
                externalController: "127.0.0.1:19090",
                secret: "engine-store-test-secret",
                mixedPort: 17890
            ),
            executableResolver: resolver,
            configurationValidator: validator,
            processManager: processManager,
            controllerManager: controllerManager,
            recentProxyStore: recentProxyStore,
            systemProxyManager: systemProxyManager,
            networkPathObserver: networkPathObserver,
            sleepWakeObserver: sleepWakeObserver,
            mihomoDataDirectoryURL: EngineStoreTestValues.dataDirectory,
            privilegedBackend: privilegedBackend,
            privilegedHelperClient: privilegedHelperClient,
            transitionCoordinator: transitionCoordinator,
            privilegedLeaseCoordinator: privilegedLeaseCoordinator,
            privilegedComponentManager: privilegedComponentManager,
            localNetworkContextProvider: localNetworkContextProvider,
            wakePathWaitTimeout: wakePathWaitTimeout,
            wakePathPollInterval: wakePathPollInterval,
            validationShutdownWaitTimeout: validationShutdownWaitTimeout,
            validationShutdownPollInterval: validationShutdownPollInterval,
            networkChangeRecoveryDebounce: networkChangeRecoveryDebounce,
            networkChangeSleep: networkChangeSleep,
            localNetworkRecoverySleep: localNetworkRecoverySleep,
            wakeSleep: wakeSleep
        )
    }

    private func makeBackendTransitionFixture(
        processStopFailure: EngineStoreProcessManagerFakeError? = nil
    ) async throws -> (
        root: URL,
        store: EngineStore,
        processManager: EngineStoreProcessManagerFake,
        controllerManager: EngineStoreControllerManagerFake,
        systemProxyManager: EngineStoreSystemProxyManagerFake,
        helper: EngineStorePrivilegedHelperFake,
        transitionCoordinator: EngineTransitionCoordinator
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-transition-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configurationURL = root.appendingPathComponent("runtime.yaml")
        try Data("""
        dns:
          enable: true
          nameserver: [1.1.1.1]
        proxies: []
        proxy-groups: []
        rules: [MATCH,DIRECT]
        """.utf8).write(to: configurationURL)

        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(
            isRunning: false,
            stopFailure: processStopFailure
        )
        let controllerManager = EngineStoreControllerManagerFake(emitsReadyOnStart: true)
        let systemProxyManager = EngineStoreSystemProxyManagerFake()
        let helper = EngineStorePrivilegedHelperFake()
        let transitionCoordinator = EngineTransitionCoordinator()
        let componentManager = PrivilegedComponentManager(
            service: EngineStorePrivilegedAppServiceFake(status: .enabled),
            client: helper,
            preflight: EngineStorePrivilegedPreflightFake(),
            openSystemSettingsAction: {}
        )
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id,
                runtimeConfigurationURL: configurationURL
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager,
            systemProxyManager: systemProxyManager,
            privilegedBackend: PrivilegedMihomoBackend(client: helper),
            privilegedHelperClient: helper,
            transitionCoordinator: transitionCoordinator,
            privilegedLeaseCoordinator: PrivilegedLeaseCoordinator(client: helper),
            privilegedComponentManager: componentManager
        )
        await store.bootstrap()
        return (
            root,
            store,
            processManager,
            controllerManager,
            systemProxyManager,
            helper,
            transitionCoordinator
        )
    }

    private func makeActiveTunWakeFixture(
        fixedInterface: Bool = false,
        suspendStartupLogRead: Bool = false,
        allowLocalNetwork: Bool = false,
        localNetworkContextProvider: any LocalNetworkContextProviding = EngineStoreLocalNetworkContextFake()
    ) async throws -> (
        root: URL,
        store: EngineStore,
        processManager: EngineStoreProcessManagerFake,
        helper: EngineStorePrivilegedHelperFake,
        networkPathObserver: EngineStoreNetworkPathObserverFake,
        sleepWakeObserver: EngineStoreSleepWakeObserverFake,
        networkChangeSleep: EngineStoreControlledSleepFake,
        localNetworkRecoverySleep: EngineStoreControlledSleepFake,
        leaseSleep: EngineStoreControlledSleepFake,
        wakeSleep: EngineStoreWakeSleepFake
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-wake-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configurationURL = root.appendingPathComponent("runtime.yaml")
        try Data("""
        dns:
          enable: true
          nameserver: [1.1.1.1]
        proxies: []
        proxy-groups: []
        rules: [MATCH,DIRECT]
        """.utf8).write(to: configurationURL)

        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let helper = EngineStorePrivilegedHelperFake(
            suspendReadLogBatch: suspendStartupLogRead
        )
        let networkPathObserver = EngineStoreNetworkPathObserverFake()
        let sleepWakeObserver = EngineStoreSleepWakeObserverFake()
        let networkChangeSleep = EngineStoreControlledSleepFake()
        let localNetworkRecoverySleep = EngineStoreControlledSleepFake()
        let leaseSleep = EngineStoreControlledSleepFake()
        let wakeSleep = EngineStoreWakeSleepFake()
        let componentManager = PrivilegedComponentManager(
            service: EngineStorePrivilegedAppServiceFake(status: .enabled),
            client: helper,
            preflight: EngineStorePrivilegedPreflightFake(),
            openSystemSettingsAction: {}
        )
        let leaseCoordinator = PrivilegedLeaseCoordinator(
            client: helper,
            renewalInterval: .milliseconds(100),
            sleep: { duration in
                try await leaseSleep.sleep(duration)
            }
        )
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id,
                runtimeConfigurationURL: configurationURL
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            privilegedBackend: PrivilegedMihomoBackend(client: helper),
            privilegedHelperClient: helper,
            transitionCoordinator: EngineTransitionCoordinator(),
            privilegedLeaseCoordinator: leaseCoordinator,
            privilegedComponentManager: componentManager,
            localNetworkContextProvider: localNetworkContextProvider,
            networkPathObserver: networkPathObserver,
            sleepWakeObserver: sleepWakeObserver,
            wakePathWaitTimeout: .milliseconds(3),
            wakePathPollInterval: .milliseconds(1),
            networkChangeRecoveryDebounce: .milliseconds(1_500),
            networkChangeSleep: { duration in
                try await networkChangeSleep.sleep(duration)
            },
            localNetworkRecoverySleep: { duration in
                try await localNetworkRecoverySleep.sleep(duration)
            },
            wakeSleep: { duration in
                try await wakeSleep.sleep(duration)
            }
        )

        await store.bootstrap()
        await networkPathObserver.emit(NetworkPathSnapshot(status: .satisfied))
        await waitForNetworkPath(store, status: .satisfied)
        if fixedInterface {
            var settings = store.tunSettings
            settings.autoDetectInterface = false
            settings.outboundInterface = "en0"
            store.updateTunSettings(settings)
        }
        if allowLocalNetwork {
            var settings = store.tunSettings
            settings.allowLocalNetwork = true
            store.updateTunSettings(settings)
        }
        await store.start()
        await store.setTunEnabled(true)
        #expect(store.isTunActive)

        return (
            root,
            store,
            processManager,
            helper,
            networkPathObserver,
            sleepWakeObserver,
            networkChangeSleep,
            localNetworkRecoverySleep,
            leaseSleep,
            wakeSleep
        )
    }

    private func waitForNetworkPath(
        _ store: EngineStore,
        status: NetworkPathSnapshot.Status
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.networkPathSnapshot.status == status { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for network path \(status.rawValue)")
    }

    private func triggerReachableNetworkChange(
        store: EngineStore,
        observer: EngineStoreNetworkPathObserverFake
    ) async {
        await observer.emit(NetworkPathSnapshot(status: .unsatisfied))
        await waitForNetworkPath(store, status: .unsatisfied)
        await observer.emit(NetworkPathSnapshot(status: .satisfied))
        await waitForNetworkPath(store, status: .satisfied)
    }

    private func waitForControlledSleepCalls(
        _ sleep: EngineStoreControlledSleepFake,
        count: Int
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await sleep.callCount() >= count { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for network-change debounce")
    }

    private func waitForControlledSleepToDrain(
        _ sleep: EngineStoreControlledSleepFake
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await sleep.pendingCount() == 0 { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for a cancelled recovery sleep to drain")
    }

    private func waitForPrivilegedHealth(
        _ store: EngineStore,
        state expected: EngineHealthState
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if case let .running(health) = store.state,
                health.overallState == expected
            {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for privileged health \(expected.rawValue)")
    }

    private func waitForWakeSleepCalls(
        _ sleep: EngineStoreWakeSleepFake,
        count: Int
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await sleep.callCount() >= count { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for wake path polling")
    }

    private func waitForHelperCommitCalls(
        _ helper: EngineStorePrivilegedHelperFake,
        count: Int
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await helper.commitCallCount() >= count { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for privileged commit")
    }

    private func waitForHelperStatusCalls(
        _ helper: EngineStorePrivilegedHelperFake,
        count: Int
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await helper.statusCallCount() >= count { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for privileged health confirmation")
    }

    private func waitForHelperAbortCalls(
        _ helper: EngineStorePrivilegedHelperFake,
        count: Int
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await helper.abortCallCount() >= count { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for privileged candidate abort")
    }

    private func waitForHelperRenewCalls(
        _ helper: EngineStorePrivilegedHelperFake,
        count: Int
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await helper.renewCallCount() >= count { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for post-wake lease renewal")
    }

    private func waitForActiveBackend(
        _ store: EngineStore,
        toEqual expectedBackend: EngineBackendKind
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.activeBackendKind == expectedBackend { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for active backend \(expectedBackend)")
    }

    private func waitForLastError(
        _ store: EngineStore,
        title: String
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.lastError?.title == title { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for error: \(title)")
    }

    private func makeSystemProxyManagedStore(
        recorder: EngineStoreLifecycleRecorder,
        restoreFailure: EngineStoreSystemProxyManagerFakeError? = nil,
        restoreConflicts: Bool = false
    ) async -> (
        store: EngineStore,
        processManager: EngineStoreProcessManagerFake,
        controllerManager: EngineStoreControllerManagerFake,
        systemProxyManager: EngineStoreSystemProxyManagerFake
    ) {
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(
            isRunning: false,
            lifecycleRecorder: recorder
        )
        let controllerManager = EngineStoreControllerManagerFake()
        let systemProxyManager = EngineStoreSystemProxyManagerFake(
            restoreFailure: restoreFailure,
            restoreConflicts: restoreConflicts,
            lifecycleRecorder: recorder
        )
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager,
            systemProxyManager: systemProxyManager
        )

        await store.bootstrap()
        await store.start()
        await controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(store, toEqual: .connected)
        await store.setSystemProxyEnabled(true)
        #expect(store.isSystemProxyApplied)

        return (store, processManager, controllerManager, systemProxyManager)
    }

    private func makeConnectedProxyStore(
        controllerManager: EngineStoreControllerManagerFake,
        recentProxyStore: (any RecentProxyStoring)? = nil
    ) async -> (
        store: EngineStore,
        processManager: EngineStoreProcessManagerFake
    ) {
        let profile = makeProfile()
        let processManager = EngineStoreProcessManagerFake(isRunning: false)
        let store = makeStore(
            profileManager: EngineStoreProfileManagerFake(
                profiles: [profile],
                selectedProfileID: profile.id
            ),
            resolver: EngineStoreExecutableResolverFake(),
            validator: EngineStoreConfigurationValidatorFake(
                result: EngineStoreTestValues.validValidation,
                suspendValidation: false
            ),
            processManager: processManager,
            controllerManager: controllerManager,
            recentProxyStore: recentProxyStore
        )

        await store.bootstrap()
        await repopulateProxyCatalog(in: store, using: controllerManager)
        return (store, processManager)
    }

    private func repopulateProxyCatalog(
        in store: EngineStore,
        using controllerManager: EngineStoreControllerManagerFake
    ) async {
        await controllerManager.emit(.ready(EngineStoreTestValues.controllerSnapshot))
        await waitForControllerState(store, toEqual: .connected)
        await controllerManager.emit(.proxiesUpdated(EngineStoreTestValues.proxyResponse))
        await waitForProxyCatalog(store, toEqual: EngineStoreTestValues.proxyCatalog)
    }

    private func makeProfile() -> Profile {
        Profile(
            id: EngineStoreTestValues.profileID,
            name: "Test Profile",
            originalFileName: "test.yaml",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func waitForValidatorCall(
        _ validator: EngineStoreConfigurationValidatorFake
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await validator.callCount() > 0 {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for validation to start")
    }

    private func waitForState(
        _ store: EngineStore,
        toEqual expectedState: EngineState
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.state == expectedState {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for state \(expectedState)")
    }

    private func waitForControllerState(
        _ store: EngineStore,
        toEqual expectedState: ControllerConnectionState
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.controllerState == expectedState {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for Controller state \(expectedState)")
    }

    private func waitForSystemProxyEnableCount(
        _ manager: EngineStoreSystemProxyManagerFake,
        expected: Int
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await manager.enableCallCount() == expected {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for \(expected) System Proxy enable calls")
    }

    private func waitForSystemProxyEnableToSuspend(
        _ manager: EngineStoreSystemProxyManagerFake
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await manager.didSuspendEnable() {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for System Proxy enable to suspend")
    }

    private func waitForSystemProxyRestoreCount(
        _ manager: EngineStoreSystemProxyManagerFake,
        expected: Int
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await manager.restoreCallCount() == expected {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for \(expected) System Proxy restore calls")
    }

    private func waitForProxySelectionCount(
        _ manager: EngineStoreControllerManagerFake,
        expected: Int
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await manager.proxySelectionRequests().count == expected {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for \(expected) proxy selections")
    }

    private func waitForSuspendedIsRunning(
        _ manager: EngineStoreProcessManagerFake
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await manager.didSuspendIsRunningCall() {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for isRunning to suspend")
    }

    private func waitForTelemetry(_ store: EngineStore) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.trafficSample != nil, !store.logEntries.isEmpty {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for Controller telemetry")
    }

    private func waitForProxyCatalog(
        _ store: EngineStore,
        toEqual expectedCatalog: ProxyCatalog
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.proxyCatalog == expectedCatalog {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for the proxy catalog")
    }

    private func waitForProxyCatalogError(
        _ store: EngineStore,
        toEqual expectedError: String
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.proxyCatalogError == expectedError {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for proxy catalog error \(expectedError)")
    }

    private func expectProxyRuntimeStateIsCleared(_ store: EngineStore) {
        #expect(store.proxyCatalog == .empty)
        #expect(store.proxyCatalogError == nil)
        #expect(!store.isLoadingProxies)
        #expect(store.proxyOperation == nil)
        #expect(store.proxyDelayStates.isEmpty)
    }

    private func waitForProcessOutput(
        _ output: MihomoProcessOutput,
        in controllerManager: EngineStoreControllerManagerFake
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await controllerManager.processOutputs().contains(output) {
                return true
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        return false
    }
}

nonisolated private enum EngineStoreTestValues {
    static let profileID = UUID(uuidString: "AF184D70-6F32-4CF9-A419-991957FAEA32")
        ?? UUID()
    static let otherProfileID = UUID(uuidString: "6C67BA68-8667-4398-B9F2-C61DF87D8A61")
        ?? UUID()
    static let runtimeConfiguration = URL(fileURLWithPath: "/tmp/vela-engine-store-active.yaml")
    static let executableURL = URL(fileURLWithPath: "/tmp/vela-engine-store-mihomo")
    static let dataDirectory = URL(fileURLWithPath: "/tmp/vela-engine-store-data")
    static let executable = ResolvedMihomoExecutable(
        url: executableURL,
        version: "Mihomo Meta test",
        sha256: String(repeating: "a", count: 64)
    )

    static let validValidation = ConfigurationValidationResult(
        status: .valid,
        stdout: "configuration is valid",
        stderr: "",
        issues: [],
        duration: .milliseconds(1)
    )

    static let runningSnapshot = MihomoProcessSnapshot(
        pid: 42,
        isRunning: true,
        executable: executable,
        configurationURL: runtimeConfiguration,
        startedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )

    static let controllerSnapshot = MihomoControllerSnapshot(
        version: MihomoVersion(meta: true, version: "1.19.28-test"),
        configs: MihomoConfigs(
            port: 0,
            socksPort: 0,
            redirPort: 0,
            tproxyPort: 0,
            mixedPort: 17_890,
            allowLan: false,
            bindAddress: "*",
            mode: .rule,
            logLevel: "info",
            ipv6: true,
            unifiedDelay: false,
            tcpConcurrent: true,
            findProcessMode: "strict",
            interfaceName: "",
            sniffing: false
        )
    )

    static let trafficSample = TrafficSample(
        timestamp: Date(timeIntervalSince1970: 1_700_000_002),
        uploadBytesPerSecond: 1_024,
        downloadBytesPerSecond: 2_048,
        totalUploadBytes: 4_096,
        totalDownloadBytes: 8_192
    )

    static let controllerLog = LogEntry(
        timestamp: Date(timeIntervalSince1970: 1_700_000_002),
        level: .info,
        source: .controller,
        message: "controller ready"
    )

    static let proxyResponse = MihomoProxiesResponse(proxies: [
        "Proxy": proxy(
            name: "Proxy",
            type: "Selector",
            now: "Hong Kong 01",
            all: ["Hong Kong 01", "Japan 02", "United States 01"],
            testURL: "https://example.com/generate_204",
            expectedStatus: "204"
        ),
        "Hidden": proxy(
            name: "Hidden",
            type: "Selector",
            all: ["Hong Kong 01"],
            hidden: true
        ),
        "Hong Kong 01": proxy(
            name: "Hong Kong 01",
            type: "Shadowsocks",
            alive: true,
            history: [MihomoDelayHistory(time: "2026-07-11T09:00:00Z", delay: 75)]
        ),
        "Japan 02": proxy(
            name: "Japan 02",
            type: "Trojan",
            alive: false,
            history: [MihomoDelayHistory(time: "2026-07-11T09:00:00Z", delay: 0)]
        ),
        "United States 01": proxy(
            name: "United States 01",
            type: "WireGuard",
            alive: nil
        )
    ])

    static let proxyCatalog = ProxyCatalog(response: proxyResponse)

    static func proxy(
        name: String,
        type: String,
        alive: Bool? = nil,
        now: String? = nil,
        all: [String]? = nil,
        testURL: String? = nil,
        expectedStatus: String? = nil,
        hidden: Bool? = nil,
        history: [MihomoDelayHistory]? = nil
    ) -> MihomoProxy {
        MihomoProxy(
            id: nil,
            name: name,
            type: type,
            alive: alive,
            udp: nil,
            uot: nil,
            xudp: nil,
            tfo: nil,
            mptcp: nil,
            smux: nil,
            interfaceName: nil,
            routingMark: nil,
            providerName: nil,
            dialerProxy: nil,
            now: now,
            all: all,
            testURL: testURL,
            expectedStatus: expectedStatus,
            fixed: nil,
            hidden: hidden,
            icon: nil,
            emptyFallback: nil,
            history: history,
            extra: nil
        )
    }

    static func unexpectedTermination(status: Int32) -> MihomoProcessTermination {
        MihomoProcessTermination(
            pid: 42,
            status: status,
            reason: .exit,
            expected: false,
            forced: false,
            stdout: "",
            stderr: "unexpected exit",
            startedAt: Date(timeIntervalSince1970: 1_700_000_001),
            endedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )
    }
}

private actor EngineStoreObservationProbe {
    private var invalidated = false

    func recordInvalidation() {
        invalidated = true
    }

    func hasInvalidated() -> Bool {
        invalidated
    }
}

private actor EngineStoreProfileManagerFake: ProfileManaging {
    private var storedProfiles: [Profile]
    private var storedSelectedProfileID: UUID?
    private var prepareCalls = 0
    private var profileListCalls = 0
    private var selectedIDCalls = 0
    private var selectCalls = 0
    private var buildCalls = 0
    private var importedSourceURL: URL?
    private let runtimeConfigurationURL: URL

    init(
        profiles: [Profile] = [],
        selectedProfileID: UUID? = nil,
        runtimeConfigurationURL: URL = EngineStoreTestValues.runtimeConfiguration
    ) {
        storedProfiles = profiles
        storedSelectedProfileID = selectedProfileID
        self.runtimeConfigurationURL = runtimeConfigurationURL
    }

    func prepareStorage() throws {
        prepareCalls += 1
    }

    func importProfile(from source: URL, name: String?) throws -> Profile {
        importedSourceURL = source
        let profile = Profile(
            id: UUID(),
            name: name ?? source.deletingPathExtension().lastPathComponent,
            originalFileName: source.lastPathComponent,
            createdAt: .now,
            updatedAt: .now
        )
        storedProfiles.append(profile)
        return profile
    }

    func profiles() throws -> [Profile] {
        profileListCalls += 1
        return storedProfiles
    }

    func selectedProfileID() throws -> UUID? {
        selectedIDCalls += 1
        return storedSelectedProfileID
    }

    func selectProfile(id: UUID) throws {
        selectCalls += 1
        storedSelectedProfileID = id
    }

    func configurationURL(for profileID: UUID) -> URL {
        runtimeConfigurationURL
    }

    func buildRuntimeConfiguration(
        for profileID: UUID,
        parameters: RuntimeConfigParameters,
        using builder: RuntimeConfigBuilder
    ) throws -> URL {
        buildCalls += 1
        return runtimeConfigurationURL
    }

    func prepareCallCount() -> Int { prepareCalls }
    func profilesCallCount() -> Int { profileListCalls }
    func selectedProfileIDCallCount() -> Int { selectedIDCalls }
    func selectCallCount() -> Int { selectCalls }
    func buildCallCount() -> Int { buildCalls }
    func lastImportedSourceURL() -> URL? { importedSourceURL }
}

private actor EngineStoreSubscriptionConverterFake: SubscriptionConverting {
    func convertToMihomoYAML(
        content: String,
        sourceURL: URL?,
        options: SubscriptionConversionOptions
    ) async throws -> ConvertedSubscription {
        ConvertedSubscription(
            yaml: content,
            detectedFormat: .mihomoYAML,
            nodeCount: 1,
            warnings: [],
            rejectedItems: [],
            convertedLocally: false
        )
    }
}

private actor EngineStoreExecutableResolverFake: MihomoExecutableResolving {
    private var calls = 0

    init() {}

    func resolve() async throws -> ResolvedMihomoExecutable {
        calls += 1
        return EngineStoreTestValues.executable
    }

    func callCount() -> Int { calls }
}

private actor EngineStoreCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor EngineStoreConfigurationValidatorFake: ConfigurationValidating {
    private let result: ConfigurationValidationResult
    private let suspendValidation: Bool
    private let resumesWhenCancelled: Bool
    private let suspendsOnlyFirstCall: Bool
    private var calls = 0
    private var validationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false

    init(
        result: ConfigurationValidationResult,
        suspendValidation: Bool,
        resumesWhenCancelled: Bool = false,
        suspendsOnlyFirstCall: Bool = false
    ) {
        self.result = result
        self.suspendValidation = suspendValidation
        self.resumesWhenCancelled = resumesWhenCancelled
        self.suspendsOnlyFirstCall = suspendsOnlyFirstCall
    }

    func validate(
        configurationURL: URL,
        using executable: ResolvedMihomoExecutable,
        timeout: Duration
    ) async -> ConfigurationValidationResult {
        calls += 1
        let shouldSuspend = suspendValidation && (!suspendsOnlyFirstCall || calls == 1)
        if shouldSuspend {
            let resumesWhenCancelled = self.resumesWhenCancelled
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if cancellationRequested {
                        continuation.resume()
                    } else {
                        validationContinuation = continuation
                    }
                }
            } onCancel: {
                guard resumesWhenCancelled else { return }
                Task { await self.cancelSuspendedValidation() }
            }
        }
        return result
    }

    private func cancelSuspendedValidation() {
        cancellationRequested = true
        let continuation = validationContinuation
        validationContinuation = nil
        continuation?.resume()
    }

    func releaseValidation() {
        cancellationRequested = false
        let continuation = validationContinuation
        validationContinuation = nil
        continuation?.resume()
    }

    func callCount() -> Int { calls }
}

nonisolated private enum EngineStoreLifecycleEvent: Equatable, Sendable {
    case systemProxyStatus
    case systemProxyEnable
    case systemProxyRestore
    case processStart
    case processStop
}

private actor EngineStoreLifecycleRecorder {
    private var recordedEvents: [EngineStoreLifecycleEvent] = []

    func record(_ event: EngineStoreLifecycleEvent) {
        recordedEvents.append(event)
    }

    func reset() {
        recordedEvents = []
    }

    func events() -> [EngineStoreLifecycleEvent] {
        recordedEvents
    }
}

nonisolated private enum EngineStoreSystemProxyManagerFakeError: Error, Sendable {
    case simulatedEnableFailure
    case simulatedRestoreFailure
    case simulatedStatusFailure
}

private actor EngineStoreSystemProxyManagerFake: SystemProxyManaging {
    private var currentStatus: SystemProxyStatus
    private let appliedStatus: SystemProxyStatus
    private let restoredStatus: SystemProxyStatus
    private let restoreFailure: EngineStoreSystemProxyManagerFakeError?
    private let restoreConflicts: Bool
    private let suspendsEnable: Bool
    private let lifecycleRecorder: EngineStoreLifecycleRecorder?
    private var statusCalls = 0
    private var enableCalls = 0
    private var restoreCalls = 0
    private var targets: [SystemProxyTarget] = []
    private var enableDidSuspend = false
    private var enableContinuation: CheckedContinuation<Void, Never>?
    private var shouldFailStatus = false
    private var shouldFailNextEnableWithPartialApply = false
    private var shouldFailNextRestore = false
    private var shouldReturnMissingOnlyRecovery = false
    private var shouldPreserveExternalTarget = false

    init(
        restoreFailure: EngineStoreSystemProxyManagerFakeError? = nil,
        restoreConflicts: Bool = false,
        suspendsEnable: Bool = false,
        lifecycleRecorder: EngineStoreLifecycleRecorder? = nil
    ) {
        let target = SystemProxyTarget(host: "127.0.0.1", port: Int(17_890))
        currentStatus = Self.makeStatus(
            target: target,
            aggregate: .disabled,
            recovery: .none,
            ownership: .untracked,
            enabled: false
        )
        appliedStatus = Self.makeStatus(
            target: target,
            aggregate: .applied,
            recovery: .managed(serviceNames: ["Wi-Fi"]),
            ownership: .managedByVela,
            enabled: true
        )
        restoredStatus = Self.makeStatus(
            target: target,
            aggregate: .disabled,
            recovery: .none,
            ownership: .alreadyRestored,
            enabled: false
        )
        self.restoreFailure = restoreFailure
        self.restoreConflicts = restoreConflicts
        self.suspendsEnable = suspendsEnable
        self.lifecycleRecorder = lifecycleRecorder
    }

    func status(for target: SystemProxyTarget) async throws -> SystemProxyStatus {
        await lifecycleRecorder?.record(.systemProxyStatus)
        statusCalls += 1
        if shouldFailStatus {
            throw EngineStoreSystemProxyManagerFakeError.simulatedStatusFailure
        }
        return currentStatus
    }

    func enable(_ target: SystemProxyTarget) async throws -> SystemProxyEnableResult {
        await lifecycleRecorder?.record(.systemProxyEnable)
        enableCalls += 1
        targets.append(target)
        if shouldFailNextEnableWithPartialApply {
            shouldFailNextEnableWithPartialApply = false
            currentStatus = Self.makeStatus(
                target: target,
                aggregate: .partiallyApplied,
                recovery: .recoveryRequired(serviceNames: ["Wi-Fi"]),
                ownership: .managedByVela,
                enabled: true
            )
            throw EngineStoreSystemProxyManagerFakeError.simulatedEnableFailure
        }
        currentStatus = appliedStatus
        if suspendsEnable {
            enableDidSuspend = true
            await withCheckedContinuation { continuation in
                enableContinuation = continuation
            }
        }
        return SystemProxyEnableResult(
            status: appliedStatus,
            changedServiceNames: ["Wi-Fi"]
        )
    }

    func restore() async throws -> SystemProxyRestoreResult {
        await lifecycleRecorder?.record(.systemProxyRestore)
        restoreCalls += 1
        if shouldFailNextRestore {
            shouldFailNextRestore = false
            throw EngineStoreSystemProxyManagerFakeError.simulatedRestoreFailure
        }
        if let restoreFailure {
            throw restoreFailure
        }
        if shouldReturnMissingOnlyRecovery {
            return SystemProxyRestoreResult(
                status: currentStatus,
                restoredServiceNames: [],
                alreadyRestoredServiceNames: [],
                conflictedServiceNames: [],
                missingServiceNames: ["Wi-Fi"]
            )
        }
        if shouldPreserveExternalTarget {
            return SystemProxyRestoreResult(
                status: currentStatus,
                restoredServiceNames: [],
                alreadyRestoredServiceNames: [],
                conflictedServiceNames: [],
                missingServiceNames: []
            )
        }
        if restoreConflicts {
            currentStatus = Self.makeStatus(
                target: appliedStatus.target,
                aggregate: .externallyConfigured,
                recovery: .none,
                ownership: .externallyModified,
                enabled: false
            )
            return SystemProxyRestoreResult(
                status: currentStatus,
                restoredServiceNames: [],
                alreadyRestoredServiceNames: [],
                conflictedServiceNames: ["Wi-Fi"],
                missingServiceNames: []
            )
        }
        currentStatus = restoredStatus
        return SystemProxyRestoreResult(
            status: restoredStatus,
            restoredServiceNames: ["Wi-Fi"],
            alreadyRestoredServiceNames: [],
            conflictedServiceNames: [],
            missingServiceNames: []
        )
    }

    func statusCallCount() -> Int { statusCalls }
    func enableCallCount() -> Int { enableCalls }
    func restoreCallCount() -> Int { restoreCalls }
    func enabledTargets() -> [SystemProxyTarget] { targets }
    func didSuspendEnable() -> Bool { enableDidSuspend }
    func releaseEnable() {
        let continuation = enableContinuation
        enableContinuation = nil
        continuation?.resume()
    }
    func simulateUnpublishedRecoveryAndStatusFailure() {
        currentStatus = appliedStatus
        shouldFailStatus = true
    }
    func simulateStatusReadbackFailure() {
        shouldFailStatus = true
    }
    func failNextEnableWithPartialApply() {
        shouldFailNextEnableWithPartialApply = true
    }
    func failNextRestore() {
        shouldFailNextRestore = true
    }
    func simulateMissingOnlyRecovery() {
        currentStatus = SystemProxyStatus(
            target: appliedStatus.target,
            aggregate: .unavailable,
            services: [],
            recovery: .recoveryRequired(serviceNames: ["Wi-Fi"])
        )
        shouldReturnMissingOnlyRecovery = true
    }
    func simulateExternalTargetWithoutOwnership() {
        currentStatus = Self.makeStatus(
            target: appliedStatus.target,
            aggregate: .applied,
            recovery: .none,
            ownership: .untracked,
            enabled: true
        )
        shouldPreserveExternalTarget = true
    }

    private nonisolated static func makeStatus(
        target: SystemProxyTarget,
        aggregate: SystemProxyAggregateState,
        recovery: SystemProxyRecoveryState,
        ownership: SystemProxyServiceOwnership,
        enabled: Bool
    ) -> SystemProxyStatus {
        func endpoint(_ kind: SystemProxyEndpointKind) -> SystemProxyEndpointState {
            SystemProxyEndpointState(
                kind: kind,
                isEnabled: enabled,
                host: enabled ? target.host : nil,
                port: enabled ? target.port : nil
            )
        }
        return SystemProxyStatus(
            target: target,
            aggregate: aggregate,
            services: [
                SystemProxyServiceState(
                    id: "wifi-service",
                    name: "Wi-Fi",
                    isServiceEnabled: true,
                    http: endpoint(.http),
                    https: endpoint(.https),
                    socks: endpoint(.socks),
                    ownership: ownership
                )
            ],
            recovery: recovery
        )
    }
}

nonisolated private enum EngineStoreProcessOperation: Equatable, Sendable {
    case isRunning
    case start
    case stop
}

private actor EngineStoreProcessManagerFake: MihomoProcessManaging {
    private var running: Bool
    private let stopFailure: EngineStoreProcessManagerFakeError?
    private let lifecycleRecorder: EngineStoreLifecycleRecorder?
    private var recordedOperations: [EngineStoreProcessOperation] = []
    private var startCalls = 0
    private var stopCalls = 0
    private var shouldFailNextStart = false
    private var shouldLeaveProcessRunningOnNextStartFailure = false
    private var shouldFailNextStop = false
    private var eventContinuation: AsyncStream<MihomoProcessEvent>.Continuation?
    private var shouldSuspendNextIsRunning = false
    private var isRunningDidSuspend = false
    private var isRunningContinuation: CheckedContinuation<Void, Never>?

    init(
        isRunning: Bool,
        stopFailure: EngineStoreProcessManagerFakeError? = nil,
        lifecycleRecorder: EngineStoreLifecycleRecorder? = nil
    ) {
        running = isRunning
        self.stopFailure = stopFailure
        self.lifecycleRecorder = lifecycleRecorder
    }

    func start(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration
    ) async throws -> MihomoProcessSnapshot {
        await lifecycleRecorder?.record(.processStart)
        recordedOperations.append(.start)
        startCalls += 1
        if shouldFailNextStart {
            shouldFailNextStart = false
            running = shouldLeaveProcessRunningOnNextStartFailure
            shouldLeaveProcessRunningOnNextStartFailure = false
            throw EngineStoreProcessManagerFakeError.simulatedStartFailure
        }
        running = true
        return EngineStoreTestValues.runningSnapshot
    }

    func stop(timeout: Duration) async throws -> MihomoProcessTermination? {
        await lifecycleRecorder?.record(.processStop)
        recordedOperations.append(.stop)
        stopCalls += 1
        if shouldFailNextStop {
            shouldFailNextStop = false
            throw EngineStoreProcessManagerFakeError.simulatedStopFailure
        }
        if let stopFailure {
            throw stopFailure
        }
        let wasRunning = running
        running = false
        return wasRunning ? EngineStoreTestValues.expectedTermination : nil
    }

    func restart(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration,
        stopTimeout: Duration
    ) async throws -> MihomoProcessSnapshot {
        _ = try await stop(timeout: stopTimeout)
        return try await start(
            configurationURL: configurationURL,
            dataDirectoryURL: dataDirectoryURL,
            additionalArguments: additionalArguments,
            validationTimeout: validationTimeout
        )
    }

    func isRunning() async -> Bool {
        recordedOperations.append(.isRunning)
        let result = running
        if shouldSuspendNextIsRunning {
            shouldSuspendNextIsRunning = false
            isRunningDidSuspend = true
            await withCheckedContinuation { continuation in
                isRunningContinuation = continuation
            }
        }
        return result
    }

    func snapshot() async -> MihomoProcessSnapshot {
        running ? EngineStoreTestValues.runningSnapshot : .stopped
    }

    func events() async -> AsyncStream<MihomoProcessEvent> {
        AsyncStream { continuation in
            eventContinuation = continuation
        }
    }

    func emit(_ event: MihomoProcessEvent) {
        if case .terminated = event {
            running = false
        }
        eventContinuation?.yield(event)
    }

    func finishEvents() {
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func simulateUntrackedRunningProcess() {
        running = true
    }

    func resetOperations() {
        recordedOperations = []
    }

    func operations() -> [EngineStoreProcessOperation] { recordedOperations }
    func startCallCount() -> Int { startCalls }
    func stopCallCount() -> Int { stopCalls }
    func failNextStart(leavingProcessRunning: Bool = false) {
        shouldFailNextStart = true
        shouldLeaveProcessRunningOnNextStartFailure = leavingProcessRunning
    }
    func failNextStop() { shouldFailNextStop = true }
    func suspendNextIsRunningCall() {
        shouldSuspendNextIsRunning = true
        isRunningDidSuspend = false
    }
    func didSuspendIsRunningCall() -> Bool { isRunningDidSuspend }
    func releaseIsRunningCall() {
        let continuation = isRunningContinuation
        isRunningContinuation = nil
        continuation?.resume()
    }
}

nonisolated private enum EngineStoreProcessManagerFakeError: Error, Sendable {
    case simulatedStartFailure
    case simulatedStopFailure
}

nonisolated private struct EngineStoreProxySelectionRequest: Equatable, Sendable {
    let groupName: String
    let proxyName: String
}

nonisolated private struct EngineStoreSingleDelayRequest: Equatable, Sendable {
    let nodeID: ProxyCatalogID
    let url: String
    let timeoutMilliseconds: Int
    let expectedStatus: String?

    var name: String { nodeID.name }

    init(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) {
        self.init(
            nodeID: ProxyCatalogID(origin: .runtime, name: name),
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus
        )
    }

    init(
        nodeID: ProxyCatalogID,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) {
        self.nodeID = nodeID
        self.url = url
        self.timeoutMilliseconds = timeoutMilliseconds
        self.expectedStatus = expectedStatus
    }
}

nonisolated private struct EngineStoreGroupDelayRequest: Equatable, Sendable {
    let names: [String]
    let url: String
    let timeoutMilliseconds: Int
    let expectedStatus: String?
    let concurrencyLimit: Int
}

nonisolated private enum EngineStoreControllerManagerFakeError: Error, Sendable {
    case simulatedProxySelectionFailure
}

private actor EngineStoreControllerManagerFake: MihomoControllerManaging {
    private let proxySelectionFailure: EngineStoreControllerManagerFakeError?
    private let suspendsSingleDelay: Bool
    private let emitsReadyOnStart: Bool
    private let singleDelayResult: MihomoProxyDelayResult
    private let singleDelayResultsByID: [ProxyCatalogID: MihomoProxyDelayResult]
    private let groupDelayResults: [MihomoProxyDelayResult]?
    private var starts = 0
    private var stops = 0
    private var refreshes = 0
    private var modes: [MihomoMode] = []
    private var proxyRefreshes = 0
    private var proxySelections: [EngineStoreProxySelectionRequest] = []
    private var recordedSingleDelayRequests: [EngineStoreSingleDelayRequest] = []
    private var recordedGroupDelayRequests: [EngineStoreGroupDelayRequest] = []
    private var singleDelayStarted = false
    private var singleDelayContinuation: CheckedContinuation<Void, Never>?
    private var outputs: [MihomoProcessOutput] = []
    private var eventContinuation: AsyncStream<MihomoControllerEvent>.Continuation?

    init(
        proxySelectionFailure: EngineStoreControllerManagerFakeError? = nil,
        suspendsSingleDelay: Bool = false,
        emitsReadyOnStart: Bool = false,
        singleDelayResult: MihomoProxyDelayResult = MihomoProxyDelayResult(
            proxyName: "Proxy",
            delayMilliseconds: 42
        ),
        singleDelayResultsByID: [ProxyCatalogID: MihomoProxyDelayResult] = [:],
        groupDelayResults: [MihomoProxyDelayResult]? = nil
    ) {
        self.proxySelectionFailure = proxySelectionFailure
        self.suspendsSingleDelay = suspendsSingleDelay
        self.emitsReadyOnStart = emitsReadyOnStart
        self.singleDelayResult = singleDelayResult
        self.singleDelayResultsByID = singleDelayResultsByID
        self.groupDelayResults = groupDelayResults
    }

    func events() -> AsyncStream<MihomoControllerEvent> {
        AsyncStream { continuation in
            eventContinuation = continuation
        }
    }

    func start() {
        starts += 1
        if emitsReadyOnStart {
            eventContinuation?.yield(.ready(EngineStoreTestValues.controllerSnapshot))
        }
    }

    func refresh() {
        refreshes += 1
    }

    func stop() {
        stops += 1
    }

    func changeMode(_ mode: MihomoMode) {
        modes.append(mode)
    }

    func refreshProxies() {
        proxyRefreshes += 1
    }

    func selectProxy(group: String, proxy: String) throws {
        proxySelections.append(
            EngineStoreProxySelectionRequest(
                groupName: group,
                proxyName: proxy
            )
        )
        if let proxySelectionFailure {
            throw proxySelectionFailure
        }
    }

    func testProxyDelay(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async -> MihomoProxyDelayResult {
        await performSingleDelay(
            nodeID: ProxyCatalogID(origin: .runtime, name: name),
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus
        )
    }

    func testProxyDelay(
        nodeID: ProxyCatalogID,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async -> MihomoProxyDelayResult {
        await performSingleDelay(
            nodeID: nodeID,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus
        )
    }

    private func performSingleDelay(
        nodeID: ProxyCatalogID,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async -> MihomoProxyDelayResult {
        recordedSingleDelayRequests.append(
            EngineStoreSingleDelayRequest(
                nodeID: nodeID,
                url: url,
                timeoutMilliseconds: timeoutMilliseconds,
                expectedStatus: expectedStatus
            )
        )
        singleDelayStarted = true
        if suspendsSingleDelay {
            await withCheckedContinuation { continuation in
                singleDelayContinuation = continuation
            }
        }
        return singleDelayResultsByID[nodeID] ?? singleDelayResult
    }

    func testProxyGroupDelay(
        names: [String],
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?,
        concurrencyLimit: Int
    ) -> [MihomoProxyDelayResult] {
        recordedGroupDelayRequests.append(
            EngineStoreGroupDelayRequest(
                names: names,
                url: url,
                timeoutMilliseconds: timeoutMilliseconds,
                expectedStatus: expectedStatus,
                concurrencyLimit: concurrencyLimit
            )
        )
        return groupDelayResults ?? names.map {
            MihomoProxyDelayResult(proxyName: $0, delayMilliseconds: 42)
        }
    }

    func appendProcessOutput(_ output: MihomoProcessOutput) {
        outputs.append(output)
    }

    func clearLogs() {}

    func emit(_ event: MihomoControllerEvent) {
        eventContinuation?.yield(event)
    }

    func finishEvents() {
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func startCallCount() -> Int { starts }
    func stopCallCount() -> Int { stops }
    func changedModes() -> [MihomoMode] { modes }
    func processOutputs() -> [MihomoProcessOutput] { outputs }
    func proxySelectionRequests() -> [EngineStoreProxySelectionRequest] { proxySelections }
    func singleDelayRequests() -> [EngineStoreSingleDelayRequest] {
        recordedSingleDelayRequests
    }
    func groupDelayRequests() -> [EngineStoreGroupDelayRequest] {
        recordedGroupDelayRequests
    }
    func didStartSingleDelay() -> Bool { singleDelayStarted }
    func releaseSingleDelay() {
        let continuation = singleDelayContinuation
        singleDelayContinuation = nil
        continuation?.resume()
    }
}

private actor EngineStoreRecentProxyStoreFake: RecentProxyStoring {
    private let loadResult: [RecentProxyRecord]
    private var loadedProfiles: [UUID] = []
    private var records: [RecentProxyRecord] = []

    init(loadResult: [RecentProxyRecord] = []) {
        self.loadResult = loadResult
    }

    func load(for profileID: UUID) -> [RecentProxyRecord] {
        loadedProfiles.append(profileID)
        return loadResult
    }

    func record(
        profileID: UUID,
        groupName: String,
        proxyName: String,
        usedAt: Date
    ) {
        records.append(
            RecentProxyRecord(
                profileID: profileID,
                groupName: groupName,
                proxyName: proxyName,
                usedAt: usedAt
            )
        )
    }

    func loadedProfileIDs() -> [UUID] { loadedProfiles }
    func recordedRecords() -> [RecentProxyRecord] { records }
}

private actor EngineStoreDelayedRecentProxyStoreFake: RecentProxyStoring {
    private let suspendedProfileID: UUID
    private let recordsByProfile: [UUID: [RecentProxyRecord]]
    private var suspendedLoadStarted = false
    private var suspendedLoadContinuation: CheckedContinuation<Void, Never>?

    init(
        suspendedProfileID: UUID,
        recordsByProfile: [UUID: [RecentProxyRecord]]
    ) {
        self.suspendedProfileID = suspendedProfileID
        self.recordsByProfile = recordsByProfile
    }

    func load(for profileID: UUID) async -> [RecentProxyRecord] {
        if profileID == suspendedProfileID {
            suspendedLoadStarted = true
            await withCheckedContinuation { continuation in
                suspendedLoadContinuation = continuation
            }
        }
        return recordsByProfile[profileID] ?? []
    }

    func record(
        profileID: UUID,
        groupName: String,
        proxyName: String,
        usedAt: Date
    ) {}

    func didStartSuspendedLoad() -> Bool { suspendedLoadStarted }

    func releaseSuspendedLoad() {
        let continuation = suspendedLoadContinuation
        suspendedLoadContinuation = nil
        continuation?.resume()
    }
}

nonisolated private extension EngineStoreTestValues {
    static let expectedTermination = MihomoProcessTermination(
        pid: 42,
        status: 0,
        reason: .exit,
        expected: true,
        forced: false,
        stdout: "",
        stderr: "",
        startedAt: Date(timeIntervalSince1970: 1_700_000_001),
        endedAt: Date(timeIntervalSince1970: 1_700_000_002)
    )
}

@MainActor
private final class EngineStorePrivilegedAppServiceFake: PrivilegedAppServiceProviding {
    var status: SMAppService.Status

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
}

nonisolated private struct EngineStorePrivilegedPreflightFake: PrivilegedBundlePreflighting {
    func inspect() throws -> PrivilegedBundleSnapshot {
        PrivilegedBundleSnapshot(
            applicationURL: URL(fileURLWithPath: "/Applications/Vela.app"),
            helperURL: URL(fileURLWithPath: "/Applications/Vela.app/Contents/Library/LaunchServices/VelaHelper"),
            mihomoURL: URL(fileURLWithPath: "/Applications/Vela.app/Contents/Helpers/mihomo"),
            daemonPlistURL: URL(fileURLWithPath: "/Applications/Vela.app/Contents/Library/LaunchDaemons/dev.yilin.Vela.Helper.plist"),
            teamIdentifier: "TESTTEAM01",
            helperSigningIdentifier: VelaIPCConstants.helperIdentifier,
            isInApplications: true
        )
    }
}

nonisolated private struct EngineStoreLocalNetworkContextFake: LocalNetworkContextProviding {
    let exclusions: [String]

    init(exclusions: [String] = []) {
        self.exclusions = exclusions
    }

    func currentContext() throws -> LocalNetworkContext {
        LocalNetworkContext(
            routes: exclusions.map {
                LocalNetworkRoute(interfaceName: "en0", cidr: $0)
            },
            collectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

nonisolated private final class EngineStoreMutableLocalNetworkContextFake:
    LocalNetworkContextProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private var exclusions: [String]

    init(exclusions: [String] = []) {
        self.exclusions = exclusions
    }

    func setExclusions(_ exclusions: [String]) {
        lock.withLock { self.exclusions = exclusions }
    }

    func currentContext() throws -> LocalNetworkContext {
        let snapshot = lock.withLock { exclusions }
        return LocalNetworkContext(
            routes: snapshot.map {
                LocalNetworkRoute(interfaceName: "en0", cidr: $0)
            },
            collectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private actor EngineStoreNetworkPathObserverFake: NetworkPathObserving {
    private var snapshot: NetworkPathSnapshot = .unknown
    private var continuation: AsyncStream<NetworkPathSnapshot>.Continuation?

    func start() {}

    func events() -> AsyncStream<NetworkPathSnapshot> {
        let initial = snapshot
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            self.continuation = continuation
            continuation.yield(initial)
        }
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ snapshot: NetworkPathSnapshot) {
        self.snapshot = snapshot
        continuation?.yield(snapshot)
    }
}

@MainActor
private final class EngineStoreSleepWakeObserverFake: SleepWakeObserving, @unchecked Sendable {
    private var continuation: AsyncStream<SleepWakeEvent>.Continuation?

    func start() async {}

    func events() async -> AsyncStream<SleepWakeEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            self.continuation = continuation
        }
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ event: SleepWakeEvent) {
        continuation?.yield(event)
    }
}

private actor EngineStoreWakeSleepFake {
    private var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        calls += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.releaseAll() }
        }
        try Task.checkCancellation()
    }

    func callCount() -> Int { calls }

    func advanceOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func releaseAll() {
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor EngineStoreControlledSleepFake {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var calls = 0
    private var waiters: [Waiter] = []

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        calls += 1
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        try Task.checkCancellation()
    }

    func callCount() -> Int { calls }
    func pendingCount() -> Int { waiters.count }

    func advanceLatest() {
        guard let waiter = waiters.popLast() else { return }
        waiter.continuation.resume()
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }
}

private actor EngineStorePrivilegedHelperFake: PrivilegedHelperClientProtocol {
    private let sessionID = UUID()
    private let suspendCommit: Bool
    private let suspendReadLogBatch: Bool
    private var running: Bool
    private var commitInFlight = false
    private var prepareRequest: PrepareStartRequest?
    private var instanceID: UUID?
    private var stopCalls = 0
    private var handshakeCalls = 0
    private var statusCalls = 0
    private var prepareCalls = 0
    private var commitCalls = 0
    private var abortCalls = 0
    private var cleanupModeRequests: [PrivilegedCleanupMode] = []
    private var renewCalls = 0
    private var invalidateCalls = 0
    private var reportsHealthy = true
    private var shouldFailNextCommit = false
    private var shouldFailNextStop = false
    private var shouldFailNextRenew = false
    private var shouldSuspendNextHandshake = false
    private var handshakeDidSuspend = false
    private var handshakeContinuation: CheckedContinuation<Void, Never>?
    private var handshakeSuspensionObservers: [CheckedContinuation<Void, Never>] = []
    private var shouldSuspendNextStatus = false
    private var statusCallDidSuspend = false
    private var statusCallContinuation: CheckedContinuation<Void, Never>?
    private var statusSuspensionObservers: [CheckedContinuation<Void, Never>] = []
    private var readLogBatchStarted = false
    private var readLogBatchContinuation: CheckedContinuation<Void, Never>?
    private var readLogBatchObservers: [CheckedContinuation<Void, Never>] = []
    private var suspendedCommitContinuation: CheckedContinuation<PrivilegedEngineRuntime, Error>?
    private var commitStartedObservers: [CheckedContinuation<Void, Never>] = []
    private var commitCancellationObservers: [CheckedContinuation<Void, Never>] = []
    private var commitWasCancelled = false

    init(
        running: Bool = false,
        suspendCommit: Bool = false,
        suspendReadLogBatch: Bool = false
    ) {
        self.running = running
        self.suspendCommit = suspendCommit
        self.suspendReadLogBatch = suspendReadLogBatch
        instanceID = running ? UUID() : nil
    }

    func handshake(
        clientVersion: String,
        clientBuild: String,
        requestedSessionID: UUID?
    ) async throws -> HelperHandshakeResponse {
        handshakeCalls += 1
        if shouldSuspendNextHandshake {
            shouldSuspendNextHandshake = false
            handshakeDidSuspend = true
            let observers = handshakeSuspensionObservers
            handshakeSuspensionObservers.removeAll()
            observers.forEach { $0.resume() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    handshakeContinuation = continuation
                }
            } onCancel: {
                Task { await self.releaseHandshake() }
            }
            try Task.checkCancellation()
        }
        return HelperHandshakeResponse(
            requestID: UUID(),
            daemonUID: 0,
            currentOwnerUID: UInt32(getuid()),
            sessionID: sessionID,
            mihomoVersion: "1.19.28",
            mihomoPlatform: "darwin",
            mihomoArchitecture: "arm64",
            state: commitInFlight ? .preparing : (running ? .running : .stopped),
            processID: running ? 9_001 : nil
        )
    }

    func status() async throws -> HelperStatusResponse {
        statusCalls += 1
        if shouldSuspendNextStatus {
            shouldSuspendNextStatus = false
            statusCallDidSuspend = true
            let observers = statusSuspensionObservers
            statusSuspensionObservers.removeAll()
            observers.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                statusCallContinuation = continuation
            }
        }
        return HelperStatusResponse(
            requestID: UUID(),
            state: commitInFlight ? .preparing : (running ? .running : .stopped),
            currentOwnerUID: UInt32(getuid()),
            processID: running ? 9_001 : nil,
            instanceID: instanceID,
            configurationSHA256: prepareRequest?.configurationSHA256,
            health: health
        )
    }

    func prepareStart(_ request: PrepareStartRequest) async throws -> PrepareStartResponse {
        prepareCalls += 1
        prepareRequest = request
        return PrepareStartResponse(
            requestID: request.requestID,
            transactionID: UUID(),
            expiresAt: .now.addingTimeInterval(30),
            maximumResourceBytesRemaining: VelaIPCConstants.maximumResourceTotalBytes
        )
    }

    func stageConfiguration(_ request: StageConfigurationRequest, data: Data) async throws {}
    func stageResource(_ request: StageResourceRequest, file: FileHandle) async throws {}

    func commitStart(_ request: CommitStartRequest) async throws -> PrivilegedEngineRuntime {
        commitCalls += 1
        if shouldFailNextCommit {
            shouldFailNextCommit = false
            throw EngineStorePrivilegedHelperFakeError.simulatedCommitFailure
        }
        guard suspendCommit else {
            return makeRuntime(requestID: request.requestID)
        }
        commitInFlight = true
        let observers = commitStartedObservers
        commitStartedObservers.removeAll()
        observers.forEach { $0.resume() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                suspendedCommitContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancelSuspendedCommitCaller() }
        }
    }

    private func makeRuntime(requestID: UUID) -> PrivilegedEngineRuntime {
        let runtimeID = UUID()
        instanceID = runtimeID
        running = true
        reportsHealthy = true
        commitInFlight = false
        return PrivilegedEngineRuntime(
            requestID: requestID,
            instanceID: runtimeID,
            controllerHost: "127.0.0.1",
            controllerPort: 29_090,
            controllerSecret: "test-privileged-secret",
            processID: 9_001,
            startedAt: .now,
            configurationSHA256: prepareRequest?.configurationSHA256 ?? String(repeating: "0", count: 64),
            tunInterface: "utun99"
        )
    }

    private func cancelSuspendedCommitCaller() {
        guard let continuation = suspendedCommitContinuation else { return }
        suspendedCommitContinuation = nil
        commitWasCancelled = true
        continuation.resume(throwing: CancellationError())
        let observers = commitCancellationObservers
        commitCancellationObservers.removeAll()
        observers.forEach { $0.resume() }
    }

    func abortStart(_ request: AbortStartRequest) async throws {
        abortCalls += 1
        prepareRequest = nil
    }

    func stop(_ request: StopHelperRequest) async throws {
        stopCalls += 1
        if shouldFailNextStop {
            shouldFailNextStop = false
            throw EngineStorePrivilegedHelperFakeError.simulatedStopFailure
        }
        running = false
        commitInFlight = false
        instanceID = nil
    }

    func renewLease(_ request: RenewLeaseRequest) async throws {
        renewCalls += 1
        if shouldFailNextRenew {
            shouldFailNextRenew = false
            throw VelaHelperFailure(
                code: .helperUnavailable,
                requestID: request.requestID,
                safeMessage: "Simulated lease renewal failure."
            )
        }
    }

    func readLogBatch(_ request: ReadLogBatchRequest) async throws -> ReadLogBatchResponse {
        if suspendReadLogBatch {
            readLogBatchStarted = true
            let observers = readLogBatchObservers
            readLogBatchObservers.removeAll()
            observers.forEach { $0.resume() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    readLogBatchContinuation = continuation
                }
            } onCancel: {
                Task { await self.releaseReadLogBatch() }
            }
        }
        return ReadLogBatchResponse(requestID: request.requestID, entries: [])
    }

    func cleanup(_ request: CleanupHelperRequest) async throws {
        cleanupModeRequests.append(request.mode)
        running = false
        instanceID = nil
    }

    func invalidate() async {
        invalidateCalls += 1
    }

    func lastPrepareRequest() -> PrepareStartRequest? { prepareRequest }
    func stopCallCount() -> Int { stopCalls }
    func handshakeCallCount() -> Int { handshakeCalls }
    func statusCallCount() -> Int { statusCalls }
    func prepareCallCount() -> Int { prepareCalls }
    func commitCallCount() -> Int { commitCalls }
    func abortCallCount() -> Int { abortCalls }
    func renewCallCount() -> Int { renewCalls }
    func invalidateCallCount() -> Int { invalidateCalls }
    func cleanupModes() -> [PrivilegedCleanupMode] { cleanupModeRequests }
    func isRuntimeRunning() -> Bool { running }

    func setRuntimeHealthy(_ healthy: Bool) {
        reportsHealthy = healthy
    }

    func simulateRuntimeDeath() {
        running = false
        reportsHealthy = false
        instanceID = nil
    }

    func failNextCommit() {
        shouldFailNextCommit = true
    }

    func failNextStop() {
        shouldFailNextStop = true
    }

    func failNextRenew() {
        shouldFailNextRenew = true
    }

    func suspendNextHandshake() {
        shouldSuspendNextHandshake = true
        handshakeDidSuspend = false
    }

    func waitUntilHandshakeSuspended() async {
        guard !handshakeDidSuspend else { return }
        await withCheckedContinuation { continuation in
            handshakeSuspensionObservers.append(continuation)
        }
    }

    func releaseHandshake() {
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        continuation?.resume()
    }

    func suspendNextStatusCall() {
        shouldSuspendNextStatus = true
        statusCallDidSuspend = false
    }

    func waitUntilStatusCallSuspended() async {
        guard !statusCallDidSuspend else { return }
        await withCheckedContinuation { continuation in
            statusSuspensionObservers.append(continuation)
        }
    }

    func releaseStatusCall() {
        let continuation = statusCallContinuation
        statusCallContinuation = nil
        continuation?.resume()
    }

    func waitUntilReadLogBatchStarted() async {
        guard !readLogBatchStarted else { return }
        await withCheckedContinuation { continuation in
            readLogBatchObservers.append(continuation)
        }
    }

    func releaseReadLogBatch() {
        let continuation = readLogBatchContinuation
        readLogBatchContinuation = nil
        continuation?.resume()
    }

    func waitUntilCommitStarted() async {
        guard !commitInFlight else { return }
        await withCheckedContinuation { continuation in
            commitStartedObservers.append(continuation)
        }
    }

    func waitUntilCommitCallerCancelled() async {
        guard !commitWasCancelled else { return }
        await withCheckedContinuation { continuation in
            commitCancellationObservers.append(continuation)
        }
    }

    func completeCommitAfterCallerCancellation() {
        guard commitInFlight else { return }
        _ = makeRuntime(requestID: UUID())
    }

    private var health: PrivilegedRuntimeHealth {
        let ready = running && reportsHealthy
        return PrivilegedRuntimeHealth(
            helperReachable: true,
            helperVersionCompatible: true,
            processRunning: running,
            controllerReachable: ready,
            configurationHashMatches: ready,
            tunEnabledInController: ready,
            tunInterfacePresent: ready,
            routeApplied: ready,
            dnsReady: ready,
            ownerLeaseValid: ready,
            tunInterface: running ? "utun99" : nil,
            lastCheckedAt: .now
        )
    }
}

nonisolated private enum EngineStorePrivilegedHelperFakeError: Error, Sendable {
    case simulatedCommitFailure
    case simulatedStopFailure
}
