#if DEBUG
import Foundation
import Testing
@testable import Vela

@Suite("Runtime configuration fault injection")
struct RuntimeConfigFaultInjectionTests {
    @Test("Injected controller apply failure restores the previous active revision")
    func controllerApplyFailureRollsBack() async throws {
        let testRunID = UUID()
        let injector = try FaultInjector(
            plan: FaultPlan(
                planID: UUID(),
                testRunID: testRunID,
                seed: 0xC0FFEE,
                scenarios: [
                    FaultScenario(
                        id: "configuration-apply-failure",
                        point: .configurationApply,
                        occurrence: 1,
                        effect: .throwError(.testInjectedFailure),
                        expectedSafeState: .previousRevisionActive,
                        forbiddenOutcomes: [.activeConfigCorrupt, .staleJournal],
                        destructive: false
                    ),
                ]
            )
        )
        let api = FaultInjectedConfigurationAPI(
            injector: injector,
            testRunID: testRunID
        )
        let fileSystem = TransactionRecordingFileSystem()
        let process = TransactionProcessFake(running: true)
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let directories = ApplicationDirectories(
            root: temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        )
        let source = try ConfigurationTestSupport.write(
            TransactionTestValues.baseRawYAML,
            named: "profile.yaml",
            in: temporaryDirectory
        )
        let profileStore = ProfileStore(directories: directories, fileSystem: fileSystem)
        let profile = try await profileStore.importProfile(from: source)
        try await profileStore.selectProfile(id: profile.id)
        try directories.prepare(fileSystem: fileSystem)
        let previousData = Data("mode: direct\n".utf8)
        try previousData.write(to: directories.activeConfiguration, options: .atomic)

        let coordinator = RuntimeConfigTransactionCoordinator(
            directories: directories,
            fileSystem: fileSystem,
            profileStore: profileStore,
            runtimeParameters: TransactionTestValues.runtimeParameters,
            configurationLayerStore: ConfigurationLayerStore(
                directories: directories,
                fileSystem: fileSystem
            ),
            executableResolver: TransactionExecutableResolverFake(),
            validator: TransactionValidatorFake(result: TransactionTestValues.validValidation),
            apiClient: api,
            processManager: process,
            controllerRecoveryTimeout: .seconds(1),
            controllerPollInterval: .milliseconds(1),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        do {
            _ = try await coordinator.apply(
                rawData: Data("mode: rule\n".utf8),
                profileID: profile.id,
                sourceFileName: "remote.yaml"
            )
            Issue.record("Expected the injected apply failure")
        } catch let error as RuntimeConfigTransactionError {
            #expect(error == .hotReloadFailed)
        }

        #expect(try Data(contentsOf: directories.activeConfiguration) == previousData)
        #expect(try await profileStore.revisions(for: profile.id).isEmpty)
        #expect(await api.reloadCallCount() == 2)
        #expect(!FileManager.default.fileExists(atPath: directories.runtimeTransactionJournal.path))

        let trigger = await api.injectedTrigger()
        #expect(trigger?.rule.point == .configurationApply)
        #expect(
            trigger?.evidenceSummary(
                observedState: .rollbackCompleted,
                cleanupResult: .succeeded
            ).expectedSafeState == .previousRevisionActive
        )
        let snapshot = try await injector.snapshot(testRunID: testRunID)
        #expect(snapshot.checkCounts[.configurationApply] == 2)
    }
}

private actor FaultInjectedConfigurationAPI: MihomoAPIProviding {
    enum InjectedError: Error {
        case expectedFailure
        case unsupportedEffect
    }

    private let injector: FaultInjector
    private let testRunID: UUID
    private var reloads = 0
    private var trigger: FaultTrigger?

    init(injector: FaultInjector, testRunID: UUID) {
        self.injector = injector
        self.testRunID = testRunID
    }

    func version() async throws -> MihomoVersion {
        MihomoVersion(meta: true, version: "v1.19.28")
    }

    func configs() async throws -> MihomoConfigs { TransactionTestValues.configs }
    func patchConfigs(_ patch: MihomoConfigPatch) async throws {}

    func reloadConfiguration(at configurationURL: URL, force: Bool) async throws {
        reloads += 1
        guard let injected = try await injector.trigger(
            at: .configurationApply,
            testRunID: testRunID
        ) else {
            return
        }
        trigger = injected
        let effect = await injected.rule.effect
        guard case .throwError(.testInjectedFailure) = effect else {
            throw InjectedError.unsupportedEffect
        }
        throw InjectedError.expectedFailure
    }

    func proxies() async throws -> MihomoProxiesResponse {
        TransactionTestValues.emptyProxies
    }

    func proxyProviders() async throws -> MihomoProxyProvidersResponse { .empty }
    func ruleProviders() async throws -> MihomoRuleProvidersResponse { .empty }
    func rules() async throws -> MihomoRulesResponse { MihomoRulesResponse(rules: []) }
    func selectProxy(group: String, proxy: String) async throws {}

    func reloadCallCount() -> Int { reloads }
    func injectedTrigger() -> FaultTrigger? { trigger }
}
#endif
