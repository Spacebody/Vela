import Foundation
import Testing
import VelaIPC

@testable import Vela

@Suite("Settings snapshot and transfer")
struct SettingsSnapshotTests {
  @Test("Application version presents the latest build date")
  func applicationVersionUsesLatestBuildDate() throws {
    let buildDate = try #require(
      ISO8601DateFormatter().date(from: "2026-08-16T08:30:00Z")
    )

    #expect(
      SettingsApplicationVersionPresentation.text(
        version: "1.0.0",
        bundleBuild: "2026071403",
        buildDate: buildDate,
        timeZone: try #require(TimeZone(secondsFromGMT: 0))
      ) == "1.0.0 (Build 20260816)"
    )
  }

  @Test("Application version falls back to the bundle build")
  func applicationVersionFallsBackToBundleBuild() {
    #expect(
      SettingsApplicationVersionPresentation.text(
        version: "1.0.0",
        bundleBuild: "2026071403",
        buildDate: nil
      ) == "1.0.0 (Build 2026071403)"
    )
  }

  @Test("Settings preferences persist and reset through one authoritative store")
  @MainActor
  func preferencesPersistAndReset() throws {
    let suiteName = "dev.yilin.VelaTests.Settings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = SettingsPreferencesStore(defaults: defaults)
    #expect(store.snapshot == .defaults)

    store.startupBehavior = .lastSection
    store.minimizeToMenuBar = false
    store.language = .simplifiedChinese
    store.ipv6Enabled = false
    store.logRetentionDays = 30
    store.cacheSizeLimitMB = 1_000

    let restored = SettingsPreferencesStore(defaults: defaults)
    #expect(
      SettingsPreferencesStore.persistedStartupBehavior(defaults: defaults)
        == .lastSection
    )
    #expect(
      SettingsPreferencesStore.persistedMinimizeToMenuBar(defaults: defaults)
        == false
    )
    #expect(
      SettingsPreferencesStore.persistedIPv6Enabled(defaults: defaults)
        == false
    )
    #expect(restored.startupBehavior == .lastSection)
    #expect(restored.minimizeToMenuBar == false)
    #expect(restored.language == .simplifiedChinese)
    #expect(restored.ipv6Enabled == false)
    #expect(restored.logRetentionDays == 30)
    #expect(restored.cacheSizeLimitMB == 1_000)

    restored.reset()
    #expect(restored.snapshot == .defaults)
  }

  @Test("Clearing transient data preserves runtime configuration candidates")
  func transientDataCleanupPreservesRuntimeCandidates() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "Vela-Settings-Cleanup-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }

    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let runtimeCandidates = root.appendingPathComponent(
      "runtime/candidates",
      isDirectory: true
    )
    for directory in [logs, cache, runtimeCandidates] {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    }

    let logFile = logs.appendingPathComponent("vela.log")
    let cacheFile = cache.appendingPathComponent("metadata.cache")
    let candidate = runtimeCandidates.appendingPathComponent("transaction.yaml")
    try Data("log".utf8).write(to: logFile)
    try Data("cache".utf8).write(to: cacheFile)
    try Data("candidate".utf8).write(to: candidate)

    try SettingsTransientDataCleaner.clear(
      logDirectory: logs,
      cacheDirectory: cache,
      fileManager: fileManager
    )

    #expect(!fileManager.fileExists(atPath: logFile.path))
    #expect(!fileManager.fileExists(atPath: cacheFile.path))
    #expect(fileManager.fileExists(atPath: candidate.path))
  }

  @Test("Pending main-window navigation survives until the destination mounts")
  @MainActor
  func pendingMainWindowNavigationIsConsumable() {
    SettingsMainNavigationRequest.stage(.rules)
    #expect(SettingsMainNavigationRequest.consumePendingSection() == .rules)
    #expect(SettingsMainNavigationRequest.consumePendingSection() == nil)
  }

  @Test("TUN failure feedback rejects stale errors and reports unresolved state")
  func tunFailureFeedbackIsScopedToTheRequestedMutation() throws {
    let staleError = UserFacingError(
      title: "Old failure",
      message: "This predates the TUN request.",
      isRetryable: true
    )
    let currentError = UserFacingError(
      title: "TUN failed",
      message: "The helper rejected the request.",
      suggestedAction: "Open Diagnostics.",
      isRetryable: true,
      recoveryActions: [.openDiagnostics]
    )

    #expect(
      SettingsTunOperationFeedback.failure(
        requestedEnabled: true,
        isTunActive: true,
        previousErrorID: staleError.id,
        currentError: currentError
      ) == nil
    )
    #expect(
      SettingsTunOperationFeedback.failure(
        requestedEnabled: true,
        isTunActive: false,
        previousErrorID: staleError.id,
        currentError: currentError
      ) == currentError
    )

    let fallback = try #require(
      SettingsTunOperationFeedback.failure(
        requestedEnabled: false,
        isTunActive: true,
        previousErrorID: staleError.id,
        currentError: staleError
      )
    )
    #expect(fallback.title == "TUN change did not complete")
    #expect(fallback.recoveryActions == [.openDiagnostics])
  }

  @Test("Portable Settings document round-trips without runtime secrets")
  func transferDocumentRoundTrip() throws {
    let document = SettingsTransferDocument(
      exportedAt: Date(timeIntervalSince1970: 1_722_326_400),
      preferences: .defaults,
      tunSettings: TunSettings(
        enabled: false,
        stack: .system,
        autoRoute: true,
        autoDetectInterface: true,
        dnsHijack: true,
        allowLocalNetwork: true
      ),
      restoreSystemProxyAfterTun: true,
      updateChannel: .stable
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(document)
    let encodedText = try #require(String(data: encoded, encoding: .utf8))
    #expect(!encodedText.localizedCaseInsensitiveContains("secret"))
    #expect(!encodedText.localizedCaseInsensitiveContains("password"))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SettingsTransferDocument.self, from: encoded)
    #expect(try decoded.validated() == document)

    let portableData = try SettingsTransferCodec.encode(document)
    #expect(try SettingsTransferCodec.decode(portableData) == document)
  }

  @Test("Settings import rejects malformed and oversized documents before mutation")
  func transferCodecFailsClosed() {
    #expect(throws: SettingsTransferError.malformedDocument) {
      try SettingsTransferCodec.decode(Data("not-json".utf8))
    }

    let oversized = Data(
      repeating: 0,
      count: SettingsTransferCodec.maximumDocumentBytes + 1
    )
    #expect(
      throws: SettingsTransferError.documentTooLarge(
        maximumBytes: SettingsTransferCodec.maximumDocumentBytes
      )
    ) {
      try SettingsTransferCodec.decode(oversized)
    }
  }

  @Test("Unsupported storage preferences fail closed during import")
  func invalidPreferencesFailClosed() {
    let document = SettingsTransferDocument(
      preferences: SettingsPreferencesSnapshot(
        startupBehavior: .overview,
        minimizeToMenuBar: true,
        language: .system,
        ipv6Enabled: true,
        logRetentionDays: 365,
        cacheSizeLimitMB: 500
      ),
      tunSettings: .defaults,
      restoreSystemProxyAfterTun: true,
      updateChannel: .stable
    )

    #expect(throws: SettingsTransferError.invalidPreferences) {
      try document.validated()
    }
  }
}
