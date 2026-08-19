import Foundation
import Testing
import VelaIPC
@testable import Vela

@Suite("Core lifecycle controller")
@MainActor
struct CoreLifecycleControllerTests {
    @Test("A same-Core activation returns with the runtime mutation lease released")
    func sameCoreActivationReleasesMutationLeaseBeforeReturning() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data(TransactionTestValues.baseRawYAML.utf8),
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer {
            ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory)
        }

        let factoryCoreID = try CoreID.factory(version: "v1.19.28")
        let factoryURL = fixture.temporaryDirectory.appendingPathComponent(
            "FactoryCore.bundle",
            isDirectory: true
        )
        let factoryDescriptor = CoreDescriptor(
            coreID: factoryCoreID,
            source: .factory,
            bundleURL: factoryURL,
            executableURL: factoryURL.appendingPathComponent("mihomo"),
            upstreamVersion: "v1.19.28",
            packageRevision: nil
        )
        let activeResolver = ActiveCoreResolver(
            factoryResolver: TransactionExecutableResolverFake()
        )
        let controller = CoreLifecycleController(
            store: CoreStore(
                directories: CoreDirectories(
                    root: fixture.temporaryDirectory.appendingPathComponent(
                        "Cores",
                        isDirectory: true
                    )
                )
            ),
            directories: CoreDirectories(
                root: fixture.temporaryDirectory.appendingPathComponent(
                    "Cores",
                    isDirectory: true
                )
            ),
            factoryDescriptor: factoryDescriptor,
            activeResolver: activeResolver,
            engineStore: makeTransactionEngineStore(fixture),
            runtimeMutationGate: fixture.runtimeMutationGate,
            compatibilityEnvironment: CoreCompatibilityEnvironment(
                velaVersion: "1.0.0",
                velaBuild: 1,
                helperProtocol: 1,
                dataSchema: 1,
                controllerAPIProfile: "test",
                macOSVersion: "15.0"
            ),
            catalogEndpoint: nil,
            configurationGeneration: { UUID() }
        )

        await controller.bootstrap()
        await controller.activate(factoryCoreID)

        let updateLease = try await fixture.runtimeMutationGate.beginUpdateBarrier(
            .updatePreparation
        )
        try await fixture.runtimeMutationGate.releaseUpdateBarrier(updateLease)
    }
}
