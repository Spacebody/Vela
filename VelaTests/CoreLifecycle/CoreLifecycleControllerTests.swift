import Foundation
import Testing
import VelaIPC

@testable import Vela

@Suite("Core lifecycle controller")
@MainActor
struct CoreLifecycleControllerTests {
  @Test("A same-Core activation returns with the runtime mutation lease released")
  func sameCoreActivationReleasesMutationLeaseBeforeReturning() async throws {
    let (controller, fixture) = try await makeController()
    defer {
      ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory)
    }

    let factoryCoreID = try #require(CoreID(rawValue: "factory:v1.19.28"))
    await controller.bootstrap()
    await controller.activate(factoryCoreID)

    try await proveUpdateBarrierIsAvailable(fixture.runtimeMutationGate)
  }

  @Test("A failed Core activation returns with the runtime mutation lease released")
  func failedCoreActivationReleasesMutationLeaseBeforeReturning() async throws {
    let (controller, fixture) = try await makeController()
    defer {
      ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory)
    }

    let unavailableCoreID = try #require(CoreID(rawValue: "v9.9.9-r1"))
    await controller.bootstrap()
    await controller.activate(unavailableCoreID)

    #expect(controller.lastError != nil)
    try await proveUpdateBarrierIsAvailable(fixture.runtimeMutationGate)
  }

  private func makeController() async throws -> (
    controller: CoreLifecycleController,
    fixture: TransactionTestFixture
  ) {
    let fileSystem = TransactionRecordingFileSystem()
    let fixture = try await makeTransactionFixture(
      active: true,
      activeData: Data(TransactionTestValues.baseRawYAML.utf8),
      fileSystem: fileSystem,
      api: TransactionAPIFake(),
      process: TransactionProcessFake(running: false)
    )
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
    return (
      CoreLifecycleController(
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
      ),
      fixture
    )
  }

  private func proveUpdateBarrierIsAvailable(_ gate: RuntimeMutationGate) async throws {
    let updateLease = try await gate.beginUpdateBarrier(
      .updatePreparation
    )
    try await gate.releaseUpdateBarrier(updateLease)
  }
}
