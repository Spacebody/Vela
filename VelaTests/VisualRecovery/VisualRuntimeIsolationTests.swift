import Foundation
import Testing
@testable import Vela

@Suite("Visual runtime isolation")
struct VisualRuntimeIsolationTests {
    @Test("Visual mode selects the isolated launch assembly and skips lifecycle bootstrap")
    func visualLaunchUsesIsolationAssembly() throws {
        let arguments = [
            "Vela",
            VisualUITestConfiguration.modeKey, "YES",
        ]

        #expect(
            try AppLaunchConfiguration.resolve(
                arguments: arguments,
                environment: [:]
            ) == .uiTesting
        )
        #expect(!AppDelegate.allowsLifecycleBootstrap(arguments: arguments))
        #expect(AppDelegate.allowsLifecycleBootstrap(arguments: ["Vela"]))

        let malformedArguments = arguments
        #expect(throws: VisualUITestConfigurationError.self) {
            _ = try VisualUITestConfiguration.resolve(arguments: malformedArguments)
        }
        #expect(!AppDelegate.allowsLifecycleBootstrap(arguments: malformedArguments))

        let legacyHostedTestLaunch = try AppLaunchConfiguration.resolve(
            arguments: ["Vela"],
            environment: ["XCTestConfigurationFilePath": "/tmp/VelaTests.xctestconfiguration"]
        )
        #expect(legacyHostedTestLaunch == .uiTesting)
        #expect(!legacyHostedTestLaunch.usesLiveServices)
    }

    @Test("Controller and subprocess dependencies fail before external I/O")
    func controllerAndProcessAreFailClosed() async throws {
        let isolation = VisualRuntimeIsolation()
        let processRequest = ProcessExecutionRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        await #expect(throws: VisualRuntimeIsolationError.processExecutionDisabled) {
            _ = try await isolation.processExecutor.execute(processRequest)
        }
        #expect(await isolation.processExecutor.attemptCount() == 1)

        #expect(await isolation.controllerRouter.binding() == nil)
        await #expect(throws: MihomoAPIError.self) {
            _ = try await isolation.controllerRouter.version()
        }
        #expect(await isolation.controllerRouter.binding() == nil)
    }

    @Test("Every HTTP-backed visual dependency rejects requests in process")
    func networkDependenciesAreFailClosed() async throws {
        let isolation = VisualRuntimeIsolation()
        let catalogURL = try #require(URL(string: "https://example.com/catalog.json"))
        let signatureURL = try #require(URL(string: "https://example.com/catalog.sig.json"))

        await #expect(throws: VisualRuntimeIsolationError.networkAccessDisabled) {
            _ = try await CoreCatalogDownloader(
                transport: isolation.coreHTTPTransport
            ).download(
                catalogURL: catalogURL,
                signatureEnvelopeURL: signatureURL
            )
        }
        #expect(await isolation.coreHTTPTransport.attemptCount() == 1)

        let subscriptionRequest = SubscriptionHTTPRequest(
            secret: SubscriptionSecretEnvelope(url: catalogURL)
        )
        await #expect(throws: VisualRuntimeIsolationError.networkAccessDisabled) {
            _ = try await isolation.subscriptionHTTPFetcher.fetch(subscriptionRequest)
        }
        #expect(await isolation.subscriptionHTTPFetcher.attemptCount() == 1)
    }

    @Test("Sensitive and host-state dependencies remain process local")
    func hostStateDependenciesAreTransient() throws {
        let fixedDate = try #require(
            ISO8601DateFormatter().date(from: "2026-07-14T09:41:00Z")
        )
        let isolation = VisualRuntimeIsolation(fixedDate: fixedDate)
        let payload = Data("fixture-secret".utf8)

        try isolation.secureStoreBackend.setData(
            payload,
            service: "visual.fixture",
            account: "profile"
        )
        #expect(
            try isolation.secureStoreBackend.data(
                service: "visual.fixture",
                account: "profile"
            ) == payload
        )
        #expect(isolation.secureStoreBackend.entryCount() == 1)
        try isolation.secureStoreBackend.removeData(
            service: "visual.fixture",
            account: "profile"
        )
        #expect(isolation.secureStoreBackend.entryCount() == 0)

        let networkContext = try isolation.localNetworkContextProvider.currentContext()
        #expect(networkContext.routes.isEmpty)
        #expect(networkContext.collectedAt == fixedDate)

        #expect(isolation.launchAtLoginManager.status == .notRegistered)
        isolation.launchAtLoginManager.register()
        #expect(isolation.launchAtLoginManager.status == .enabled)
        isolation.launchAtLoginManager.unregister()
        #expect(isolation.launchAtLoginManager.status == .notRegistered)
    }

    @Test("Isolated defaults construction fails closed without a standard-defaults fallback")
    func isolatedDefaultsConstructionFailsClosed() {
        let namespace = "dev.yilin.Vela.visual-tests.forced-defaults-failure"
        let processIdentifier: Int32 = 4242

        #expect(throws: AppEnvironmentError.isolatedDefaultsUnavailable(
            "\(namespace).\(processIdentifier)"
        )) {
            _ = try AppEnvironment.makeFreshUITestDefaults(
                namespace: namespace,
                processIdentifier: processIdentifier,
                factory: { _ in nil }
            )
        }
    }
}
