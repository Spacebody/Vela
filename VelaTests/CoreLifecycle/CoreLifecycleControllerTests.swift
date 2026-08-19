import CryptoKit
import Foundation
import Testing
import VelaIPC

@testable import Vela

@Suite("Core lifecycle controller", .serialized)
@MainActor
struct CoreLifecycleControllerTests {
  @Test("Transaction updates verify canonical subsecond timestamps")
  func transactionUpdateAcceptsCanonicalTimestamp() async throws {
    let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
    defer {
      ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory)
    }

    let store = CoreStore(
      directories: CoreDirectories(
        root: temporaryDirectory.appendingPathComponent("Cores", isDirectory: true)
      )
    )
    let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
    var transaction = CoreActivationTransaction(
      coreID: coreID,
      phase: .downloading,
      startedAt: Date(timeIntervalSince1970: 1_787_087_819.987_654)
    )

    try await store.createTransaction(transaction)
    transaction.phase = .filesVerified
    try await store.updateTransaction(
      transaction,
      expectedID: transaction.transactionID
    )

    let committed = try #require(try await store.loadTransaction())
    #expect(committed.phase == .filesVerified)
    #expect(committed.startedAt.timeIntervalSince1970 == 1_787_087_819)
  }

  @Test("A same-Core activation returns with the runtime mutation lease released")
  func sameCoreActivationReleasesMutationLeaseBeforeReturning() async throws {
    let (controller, fixture, _) = try await makeController()
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
    let (controller, fixture, _) = try await makeController()
    defer {
      ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory)
    }

    let unavailableCoreID = try #require(CoreID(rawValue: "v9.9.9-r1"))
    await controller.bootstrap()
    await controller.activate(unavailableCoreID)

    #expect(controller.lastError != nil)
    try await proveUpdateBarrierIsAvailable(fixture.runtimeMutationGate)
  }

  @Test("Cancelling after the activation journal safely rolls back and releases the lease")
  func cancellationAfterJournalRollsBackBeforeReturning() async throws {
    let validationBarrier = CoreActivationBarrier()
    let validator = CoreActivationValidatorFake(
      result: TransactionTestValues.validValidation,
      blockOnCall: 2,
      barrier: validationBarrier
    )
    let (controller, fixture, engineStore) = try await makeController(
      configurationValidator: validator,
      seedActiveInstalledCore: true,
    )
    defer {
      ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory)
    }

    let factoryCoreID = try #require(CoreID(rawValue: "factory:v1.19.28"))
    let installedCoreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
    await engineStore.bootstrap()
    await controller.bootstrap()
    #expect(controller.snapshot?.state.activeCoreID == factoryCoreID)

    let activation = Task { @MainActor in
      await controller.activate(installedCoreID)
    }
    let reachedPostJournalValidation = await validationBarrier.waitUntilStarted()
    if !reachedPostJournalValidation {
      Issue.record(
        "Activation did not reach post-journal validation; state=\(controller.activationState), error=\(controller.lastError ?? "nil")"
      )
    }
    #expect(reachedPostJournalValidation)
    #expect(controller.activationJournal != nil)

    activation.cancel()
    await validationBarrier.release()
    await activation.value

    if controller.manualRepairRequired {
      Issue.record("Rollback diagnostics: \(controller.lastError ?? "nil")")
    }
    #expect(controller.snapshot?.state.activeCoreID == factoryCoreID)
    #expect(controller.activationJournal == nil)
    #expect(!controller.manualRepairRequired)
    try await proveUpdateBarrierIsAvailable(fixture.runtimeMutationGate)
  }

  @Test("A failed automatic rollback retains the journal for manual repair")
  func automaticRollbackFailureRetainsJournal() async throws {
    let process = TransactionProcessFake(running: false, restartFails: true)
    let (controller, fixture, engineStore) = try await makeController(
      process: process,
      seedActiveInstalledCore: true
    )
    defer {
      ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory)
    }

    let installedCoreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
    await engineStore.bootstrap()
    await engineStore.start()
    #expect(engineStore.isRunning)
    await controller.bootstrap()

    await controller.activate(installedCoreID)

    #expect(controller.manualRepairRequired)
    #expect(controller.activationJournal?.coreID == installedCoreID)
    #expect(controller.activationJournal?.phase == .failed)
    if case .failed = controller.activationState {
      // Expected: a failed rollback must remain visible and repairable.
    } else {
      Issue.record("Expected failed activation state, got \(controller.activationState)")
    }
    #expect(controller.lastError?.contains("Manual repair is required") == true)
  }

  @Test("A probation health failure rolls back the candidate and releases the lease")
  func probationHealthFailureRollsBackCandidate() async throws {
    let (controller, fixture, engineStore) = try await makeController(
      seedActiveInstalledCore: true,
      probationDuration: .seconds(1)
    )
    defer {
      ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory)
    }

    let factoryCoreID = try #require(CoreID(rawValue: "factory:v1.19.28"))
    let installedCoreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
    await engineStore.bootstrap()
    await controller.bootstrap()

    await controller.activate(installedCoreID)
    #expect(controller.activationJournal?.coreID == installedCoreID)
    if case .probation = controller.activationState {
      // Expected: a stopped runtime keeps the candidate in probation.
    } else {
      Issue.record("Expected probation state, got \(controller.activationState)")
    }

    await engineStore.start()
    let rollbackCompleted = await waitForCoreLifecycleCondition {
      controller.snapshot?.state.activeCoreID == factoryCoreID
        && controller.activationJournal == nil
    }

    #expect(rollbackCompleted)
    #expect(!controller.manualRepairRequired)
    if case .failed = controller.activationState {
      // Expected: the candidate failed health proof and rollback completed.
    } else {
      Issue.record("Expected failed activation state, got \(controller.activationState)")
    }
    #expect(controller.lastError?.contains("rolled back safely") == true)
    try await proveUpdateBarrierIsAvailable(fixture.runtimeMutationGate)
  }

  @Test("A healthy probation commits the candidate and releases the lease")
  func healthyProbationCommitsCandidate() async throws {
    let registeredProtocol = URLProtocol.registerClass(MihomoMockURLProtocol.self)
    MihomoMockURLProtocol.setHandler { request in
      let body: String
      switch request.url?.path {
      case "/version":
        body = #"{"meta":true,"version":"v1.19.28-test"}"#
      case "/configs":
        body = #"{"port":0,"socks-port":0,"redir-port":0,"tproxy-port":0,"mixed-port":17890,"allow-lan":false,"bind-address":"127.0.0.1","mode":"rule","log-level":"info","ipv6":false,"unified-delay":false,"tcp-concurrent":false,"find-process-mode":"off","interface-name":"","sniffing":false}"#
      case "/proxies":
        body = #"{"proxies":{}}"#
      case "/rules":
        body = #"{"rules":[]}"#
      default:
        return MihomoMockHTTPResponse(statusCode: 404)
      }
      return MihomoMockHTTPResponse(statusCode: 200, data: Data(body.utf8))
    }
    defer {
      MihomoMockURLProtocol.reset()
      if registeredProtocol {
        URLProtocol.unregisterClass(MihomoMockURLProtocol.self)
      }
    }

    let controllerManager = CoreActivationControllerManagerFake()
    let controllerRouter = RuntimeControllerRouter()
    let (controller, fixture, engineStore) = try await makeController(
      seedActiveInstalledCore: true,
      probationDuration: .seconds(1),
      controllerManager: controllerManager,
      controllerRouter: controllerRouter
    )
    defer {
      ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory)
    }

    let installedCoreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
    await engineStore.bootstrap()
    await engineStore.start()
    let controllerReady = await waitForCoreLifecycleCondition {
      engineStore.controllerState == .connected
    }
    #expect(controllerReady)
    await controller.bootstrap()

    await controller.activate(installedCoreID)
    let probationCommitted = await waitForCoreLifecycleCondition {
      controller.snapshot?.state.activeCoreID == installedCoreID
        && controller.activationJournal == nil
        && controller.activationState == .idle
    }

    #expect(probationCommitted)
    #expect(controller.lastError == nil)
    #expect(controller.snapshot?.state.previousKnownGoodCoreID?.isFactory == true)
    try await proveUpdateBarrierIsAvailable(fixture.runtimeMutationGate)
  }

  private func makeController(
    configurationValidator: any ConfigurationValidating = TransactionValidatorFake(
      result: TransactionTestValues.validValidation
    ),
    process: TransactionProcessFake = TransactionProcessFake(running: false),
    seedActiveInstalledCore: Bool = false,
    probationDuration: Duration = .seconds(10 * 60),
    controllerManager: (any MihomoControllerManaging)? = nil,
    controllerRouter: RuntimeControllerRouter? = nil
  ) async throws -> (
    controller: CoreLifecycleController,
    fixture: TransactionTestFixture,
    engineStore: EngineStore
  ) {
    let fileSystem = TransactionRecordingFileSystem()
    let fixture = try await makeTransactionFixture(
      active: true,
      activeData: Data(TransactionTestValues.baseRawYAML.utf8),
      fileSystem: fileSystem,
      api: TransactionAPIFake(),
      process: process
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
    let executableResolver = CoreActivationExecutableResolverFake(
      url: fixture.temporaryDirectory.appendingPathComponent("mihomo-test-core")
    )
    let activeResolver = ActiveCoreResolver(factoryResolver: executableResolver)
    let coreDirectories = CoreDirectories(
      root: fixture.temporaryDirectory.appendingPathComponent(
        "Cores",
        isDirectory: true
      )
    )
    let coreStore = CoreStore(directories: coreDirectories)
    let catalogVerifier = testCatalogVerifier()
    if seedActiveInstalledCore {
      try await seedInstalledCore(
        store: coreStore,
        directories: coreDirectories,
        verifier: catalogVerifier
      )
    }
    let engineStore = EngineStore(
      profileStore: fixture.profileStore,
      runtimeParameters: TransactionTestValues.runtimeParameters,
      executableResolver: executableResolver,
      configurationValidator: configurationValidator,
      processManager: fixture.process,
      controllerManager: controllerManager,
      runtimeMutationGate: fixture.runtimeMutationGate,
      mihomoDataDirectoryURL: fixture.directories.mihomo,
      controllerRouter: controllerRouter
    )
    let configurationGenerationID = UUID()
    return (
      CoreLifecycleController(
        store: coreStore,
        directories: coreDirectories,
        factoryDescriptor: factoryDescriptor,
        activeResolver: activeResolver,
        engineStore: engineStore,
        runtimeMutationGate: fixture.runtimeMutationGate,
        compatibilityEnvironment: CoreCompatibilityEnvironment(
          velaVersion: "1.0.0",
          velaBuild: 2_026_071_301,
          helperProtocol: 2,
          dataSchema: 6,
          controllerAPIProfile: "mihomo-v1.19.28",
          macOSVersion: "15.0"
        ),
        catalogEndpoint: nil,
        catalogVerifier: catalogVerifier,
        installedResolverFactory: { _, _ in executableResolver },
        probationDuration: probationDuration,
        configurationGeneration: { configurationGenerationID }
      ),
      fixture,
      engineStore
    )
  }

  private func seedInstalledCore(
    store: CoreStore,
    directories: CoreDirectories,
    verifier: CoreCatalogVerifier
  ) async throws {
    let catalogBytes = testCatalogBytes()
    let envelopeBytes = try signedCatalogEnvelope(for: catalogBytes)
    let catalogSHA256 = CoreCatalogVerifier.sha256(catalogBytes)
    let catalog = try verifier.verifyInstalledEvidence(
      catalogBytes: catalogBytes,
      envelopeBytes: envelopeBytes,
      expectedSHA256: catalogSHA256
    )
    let entry = try #require(catalog.catalog.entries.first)
    let installedAt = try #require(
      ISO8601DateFormatter().date(from: "2026-07-20T00:00:00Z")
    )
    let record = InstalledCoreRecord(
      coreID: entry.coreID,
      upstreamVersion: entry.upstreamVersion,
      packageRevision: Int(entry.packageRevision),
      catalogSequence: catalog.catalog.sequence,
      catalogSHA256: catalogSHA256,
      installedAt: installedAt,
      lastUsedAt: installedAt,
      status: .knownGood
    )

    let executableURL = directories.bundleURL(for: entry.coreID)
      .appendingPathComponent("Contents/MacOS/mihomo")
    try FileManager.default.createDirectory(
      at: executableURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: CoreStore.privateDirectoryMode)],
      ofItemAtPath: directories.installationDirectory(for: entry.coreID).path
    )
    try Data("test core".utf8).write(to: executableURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: CoreFileRole.executable.requiredPOSIXMode)],
      ofItemAtPath: executableURL.path
    )
    try await store.saveVerifiedCatalog(catalog)
    try await store.saveState(
      CoreStoreState(
        activeCoreID: try #require(CoreID(rawValue: "factory:v1.19.28")),
        previousKnownGoodCoreID: try #require(CoreID(rawValue: "factory:v1.19.28")),
        installed: [record],
        highestCatalogSequence: catalog.catalog.sequence,
        lastCatalogSHA256: catalogSHA256
      )
    )
  }

  private func testCatalogVerifier() -> CoreCatalogVerifier {
    CoreCatalogVerifier(
      keyring: CoreCatalogTrustKeyring(
        version: 1,
        roots: [
          CoreCatalogTrustRoot(
            keyID: "TEST-ONLY-core-catalog-2026-a",
            rawPublicKey: Data(
              base64Encoded: "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="
            )!,
            status: .active,
            notBefore: .distantPast,
            notAfter: .distantFuture
          )
        ]
      ),
      allowTestKeys: true
    )
  }

  private func testCatalogBytes() -> Data {
    Data(
      #"{"catalogKeySetVersion":1,"entries":[{"coreID":"v1.19.28-r1","files":[{"mode":"0644","relativePath":"Contents/Info.plist","role":"infoPlist","sha256":"1111111111111111111111111111111111111111111111111111111111111111","size":768,"url":"https://cores.example.invalid/vela/v1.19.28-r1/Contents/Info.plist"},{"mode":"0755","relativePath":"Contents/MacOS/mihomo","role":"executable","sha256":"2222222222222222222222222222222222222222222222222222222222222222","size":16000000,"url":"https://cores.example.invalid/vela/v1.19.28-r1/Contents/MacOS/mihomo"},{"mode":"0644","relativePath":"Contents/_CodeSignature/CodeResources","role":"codeResources","sha256":"3333333333333333333333333333333333333333333333333333333333333333","size":4096,"url":"https://cores.example.invalid/vela/v1.19.28-r1/Contents/_CodeSignature/CodeResources"},{"mode":"0644","relativePath":"Contents/Resources/LICENSE","role":"license","sha256":"4444444444444444444444444444444444444444444444444444444444444444","size":35149,"url":"https://cores.example.invalid/vela/v1.19.28-r1/Contents/Resources/LICENSE"},{"mode":"0644","relativePath":"Contents/Resources/NOTICE.md","role":"notice","sha256":"5555555555555555555555555555555555555555555555555555555555555555","size":1024,"url":"https://cores.example.invalid/vela/v1.19.28-r1/Contents/Resources/NOTICE.md"},{"mode":"0644","relativePath":"Contents/Resources/source.json","role":"source","sha256":"6666666666666666666666666666666666666666666666666666666666666666","size":1024,"url":"https://cores.example.invalid/vela/v1.19.28-r1/Contents/Resources/source.json"},{"mode":"0644","relativePath":"Contents/Resources/compatibility.json","role":"compatibility","sha256":"7777777777777777777777777777777777777777777777777777777777777777","size":4096,"url":"https://cores.example.invalid/vela/v1.19.28-r1/Contents/Resources/compatibility.json"}],"packageRevision":1,"publishedAt":"2026-07-13T00:00:00Z","releaseNotesURL":"https://cores.example.invalid/vela/v1.19.28-r1/release-notes.md","status":"recommended","upstream":{"archiveSHA256":"40cdae2fab4b18df15f40eaa9dc3af70ab3d8be7f77164ae1e5f1af3a2a4fb44","archiveSizeBytes":15963072,"assetName":"mihomo-darwin-arm64-v1.19.28.gz","assetURL":"https://github.com/MetaCubeX/mihomo/releases/download/v1.19.28/mihomo-darwin-arm64-v1.19.28.gz","commit":"cbd11db","license":"GPL-3.0","repositoryURL":"https://github.com/MetaCubeX/mihomo","sourceURL":"https://github.com/MetaCubeX/mihomo/tree/v1.19.28","tag":"v1.19.28"},"upstreamVersion":"v1.19.28","vela":{"architectures":["arm64"],"bundleIdentifier":"dev.yilin.Vela.MihomoCore","compatibilityReportSHA256":"8888888888888888888888888888888888888888888888888888888888888888","compatibilitySuiteVersion":1,"controllerAPIProfile":"mihomo-v1.19.28","dataSchemaMaximum":6,"dataSchemaMinimum":6,"helperProtocolMaximum":2,"helperProtocolMinimum":2,"maximumVelaBuild":null,"minimumMacOS":"15.0","minimumVelaBuild":2026071301,"minimumVelaVersion":"0.6.0"}}],"expiresAt":"2026-08-12T00:00:00Z","generatedAt":"2026-07-13T00:00:00Z","schemaVersion":1,"sequence":1}"#.utf8
    )
  }

  private func signedCatalogEnvelope(for catalogBytes: Data) throws -> Data {
    let privateKey = try Curve25519.Signing.PrivateKey(
      rawRepresentation: Data((UInt8.min ... 31).map { $0 })
    )
    let envelope: [String: Any] = [
      "schemaVersion": 1,
      "catalogSHA256": CoreCatalogVerifier.sha256(catalogBytes),
      "signatures": [
        [
          "keyID": "TEST-ONLY-core-catalog-2026-a",
          "algorithm": "ed25519",
          "signature": try privateKey.signature(for: catalogBytes).base64EncodedString(),
        ]
      ],
    ]
    return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
  }

  private func proveUpdateBarrierIsAvailable(_ gate: RuntimeMutationGate) async throws {
    let updateLease = try await gate.beginUpdateBarrier(
      .updatePreparation
    )
    try await gate.releaseUpdateBarrier(updateLease)
  }

  private func waitForCoreLifecycleCondition(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }
}

private actor CoreActivationControllerManagerFake: MihomoControllerManaging {
  private var started = false
  private var eventContinuation: AsyncStream<MihomoControllerEvent>.Continuation?

  func events() -> AsyncStream<MihomoControllerEvent> {
    AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
      eventContinuation = continuation
      if started {
        continuation.yield(.ready(Self.snapshot))
      }
    }
  }

  func start() {
    started = true
    eventContinuation?.yield(.ready(Self.snapshot))
  }

  func refresh() {
    guard started else { return }
    eventContinuation?.yield(.ready(Self.snapshot))
  }

  func stop() {
    started = false
    eventContinuation?.yield(.disconnected)
  }

  func changeMode(_: MihomoMode) {}
  func refreshProxies() {}
  func selectProxy(group _: String, proxy _: String) {}

  func testProxyDelay(
    name: String,
    url _: String,
    timeoutMilliseconds _: Int,
    expectedStatus _: String?
  ) -> MihomoProxyDelayResult {
    MihomoProxyDelayResult(proxyName: name, delayMilliseconds: 1)
  }

  func testProxyGroupDelay(
    names: [String],
    url _: String,
    timeoutMilliseconds _: Int,
    expectedStatus _: String?,
    concurrencyLimit _: Int
  ) -> [MihomoProxyDelayResult] {
    names.map { MihomoProxyDelayResult(proxyName: $0, delayMilliseconds: 1) }
  }

  func appendProcessOutput(_: MihomoProcessOutput) {}
  func clearLogs() {}

  private static let snapshot = MihomoControllerSnapshot(
    version: MihomoVersion(meta: true, version: "v1.19.28-test"),
    configs: TransactionTestValues.configs
  )
}

private struct CoreActivationExecutableResolverFake: MihomoExecutableResolving {
  let url: URL

  func resolve() async throws -> ResolvedMihomoExecutable {
    ResolvedMihomoExecutable(
      url: url,
      version: "v1.19.28",
      sha256: String(repeating: "a", count: 64),
      verifiedFile: MihomoCoreFileSnapshot(
        url: url,
        permissions: 0o755,
        ownerUserID: UInt32(getuid()),
        ownerGroupID: UInt32(getgid()),
        deviceID: 1,
        inode: 1,
        fileSize: 1,
        modificationTimeSeconds: 1,
        modificationTimeNanoseconds: 0
      )
    )
  }
}

private actor CoreActivationBarrier {
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?

  func suspend() async {
    started = true
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilStarted() async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if started { return true }
      await Task.yield()
    }
    return started
  }

  func release() {
    let continuation = continuation
    self.continuation = nil
    continuation?.resume()
  }
}

private actor CoreActivationValidatorFake: ConfigurationValidating {
  private let result: ConfigurationValidationResult
  private let blockOnCall: Int
  private let barrier: CoreActivationBarrier
  private var calls = 0

  init(
    result: ConfigurationValidationResult,
    blockOnCall: Int,
    barrier: CoreActivationBarrier
  ) {
    self.result = result
    self.blockOnCall = blockOnCall
    self.barrier = barrier
  }

  func validate(
    configurationURL: URL,
    using executable: ResolvedMihomoExecutable,
    timeout: Duration
  ) async -> ConfigurationValidationResult {
    calls += 1
    if calls == blockOnCall {
      await barrier.suspend()
    }
    return result
  }
}
