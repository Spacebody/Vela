import Foundation
import Observation
import VelaIPC

nonisolated enum SettingsPageCategory: String, CaseIterable, Identifiable, Sendable {
  case general
  case coreNetwork
  case proxies
  case rulesRouting
  case profiles
  case appearance
  case diagnostics
  case advanced
  case about

  var id: Self { self }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .coreNetwork: "point.3.connected.trianglepath.dotted"
    case .proxies: "globe"
    case .rulesRouting: "point.3.filled.connected.trianglepath.dotted"
    case .profiles: "folder.badge.gearshape"
    case .appearance: "paintpalette"
    case .diagnostics: "doc.text.magnifyingglass"
    case .advanced: "atom"
    case .about: "info.circle"
    }
  }

  var accessibilityIdentifier: String {
    "settings.category.\(rawValue)"
  }
}

nonisolated enum SettingsStartupBehavior: String, CaseIterable, Codable, Sendable {
  case overview
  case lastSection
  case menuBarOnly
}

nonisolated enum SettingsLanguagePreference: String, CaseIterable, Codable, Sendable {
  case system
  case english
  case simplifiedChinese
}

nonisolated enum SettingsTunStatus: Equatable, Sendable {
  case transitioning
  case enabled
  case disabled
  case setupRequired
  case failed
}

nonisolated enum SettingsTunOperationFeedback {
  static func failure(
    requestedEnabled: Bool,
    isTunActive: Bool,
    previousErrorID: UUID?,
    currentError: UserFacingError?
  ) -> UserFacingError? {
    guard requestedEnabled != isTunActive else { return nil }
    if let currentError, currentError.id != previousErrorID {
      return currentError
    }
    return UserFacingError(
      title: "TUN change did not complete",
      message: requestedEnabled
        ? "Vela could not enable TUN mode."
        : "Vela could not disable TUN mode.",
      suggestedAction: "Open Diagnostics for details, then try again.",
      isRetryable: true,
      recoveryActions: [.openDiagnostics]
    )
  }
}

nonisolated struct SettingsPreferencesSnapshot: Codable, Equatable, Sendable {
  var startupBehavior: SettingsStartupBehavior
  var minimizeToMenuBar: Bool
  var language: SettingsLanguagePreference
  var ipv6Enabled: Bool
  var logRetentionDays: Int
  var cacheSizeLimitMB: Int

  static let defaults = SettingsPreferencesSnapshot(
    startupBehavior: .overview,
    minimizeToMenuBar: true,
    language: .system,
    ipv6Enabled: true,
    logRetentionDays: 7,
    cacheSizeLimitMB: 500
  )
}

nonisolated struct SettingsTransferDocument: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let exportedAt: Date
  let preferences: SettingsPreferencesSnapshot
  let tunSettings: TunSettings
  let restoreSystemProxyAfterTun: Bool
  let updateChannel: ReleaseChannel

  init(
    exportedAt: Date = Date(),
    preferences: SettingsPreferencesSnapshot,
    tunSettings: TunSettings,
    restoreSystemProxyAfterTun: Bool,
    updateChannel: ReleaseChannel
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.exportedAt = exportedAt
    self.preferences = preferences
    self.tunSettings = tunSettings
    self.restoreSystemProxyAfterTun = restoreSystemProxyAfterTun
    self.updateChannel = updateChannel
  }

  func validated() throws -> Self {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw SettingsTransferError.unsupportedSchema(schemaVersion)
    }
    let normalizedTunSettings = try tunSettings.validated()
    guard [7, 14, 30, 90].contains(preferences.logRetentionDays),
      [250, 500, 1_000, 2_000].contains(preferences.cacheSizeLimitMB)
    else {
      throw SettingsTransferError.invalidPreferences
    }
    return SettingsTransferDocument(
      exportedAt: exportedAt,
      preferences: preferences,
      tunSettings: normalizedTunSettings,
      restoreSystemProxyAfterTun: restoreSystemProxyAfterTun,
      updateChannel: updateChannel
    )
  }
}

nonisolated enum SettingsTransferError: LocalizedError, Equatable, Sendable {
  case unsupportedSchema(Int)
  case invalidPreferences
  case documentTooLarge(maximumBytes: Int)
  case malformedDocument
  case runtimeBusy
  case updateInProgress
  case commitFailed

  var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let version):
      "This Settings backup uses unsupported schema version \(version)."
    case .invalidPreferences:
      "The Settings backup contains unsupported preference values."
    case .documentTooLarge(let maximumBytes):
      "The Settings backup exceeds the \(maximumBytes / 1_024) KB safety limit."
    case .malformedDocument:
      "The selected file is not a valid Vela Settings backup."
    case .runtimeBusy:
      "Wait for the current network transition to finish, then try again."
    case .updateInProgress:
      "Wait for the application update operation to finish, then try again."
    case .commitFailed:
      "Vela could not commit every imported setting and restored the previous values."
    }
  }
}

nonisolated enum SettingsTransferCodec {
  static let maximumDocumentBytes = 1 * 1_024 * 1_024

  static func encode(_ document: SettingsTransferDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(document)
  }

  static func decode(_ data: Data) throws -> SettingsTransferDocument {
    guard data.count <= maximumDocumentBytes else {
      throw SettingsTransferError.documentTooLarge(
        maximumBytes: maximumDocumentBytes
      )
    }

    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(SettingsTransferDocument.self, from: data)
        .validated()
    } catch let error as SettingsTransferError {
      throw error
    } catch {
      throw SettingsTransferError.malformedDocument
    }
  }
}

nonisolated enum SettingsMaintenanceError: LocalizedError, Equatable, Sendable {
  case runtimeBusy

  var errorDescription: String? {
    switch self {
    case .runtimeBusy:
      "Wait for the current network transition to finish, then try again."
    }
  }
}

nonisolated struct SettingsTransientDataCleaner {
  static func clear(
    logDirectory: URL,
    cacheDirectory: URL,
    fileManager: FileManager = .default
  ) throws {
    for directory in [logDirectory, cacheDirectory] {
      guard fileManager.fileExists(atPath: directory.path) else { continue }
      let children = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
      for child in children {
        try fileManager.removeItem(at: child)
      }
    }
  }
}

@MainActor
@Observable
final class SettingsPreferencesStore {
  nonisolated private enum Key {
    static let startupBehavior = "settings.startupBehavior"
    static let minimizeToMenuBar = "settings.minimizeToMenuBar"
    static let language = "settings.language"
    static let ipv6Enabled = "settings.ipv6Enabled"
    static let logRetentionDays = "settings.logRetentionDays"
    static let cacheSizeLimitMB = "settings.cacheSizeLimitMB"
  }

  @ObservationIgnored private let defaults: UserDefaults

  var startupBehavior: SettingsStartupBehavior {
    didSet { defaults.set(startupBehavior.rawValue, forKey: Key.startupBehavior) }
  }

  var minimizeToMenuBar: Bool {
    didSet { defaults.set(minimizeToMenuBar, forKey: Key.minimizeToMenuBar) }
  }

  var language: SettingsLanguagePreference {
    didSet { defaults.set(language.rawValue, forKey: Key.language) }
  }

  var ipv6Enabled: Bool {
    didSet { defaults.set(ipv6Enabled, forKey: Key.ipv6Enabled) }
  }

  var logRetentionDays: Int {
    didSet { defaults.set(logRetentionDays, forKey: Key.logRetentionDays) }
  }

  var cacheSizeLimitMB: Int {
    didSet { defaults.set(cacheSizeLimitMB, forKey: Key.cacheSizeLimitMB) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let fallback = SettingsPreferencesSnapshot.defaults

    startupBehavior =
      defaults.string(forKey: Key.startupBehavior)
      .flatMap(SettingsStartupBehavior.init(rawValue:))
      ?? fallback.startupBehavior
    minimizeToMenuBar =
      defaults.object(forKey: Key.minimizeToMenuBar) == nil
      ? fallback.minimizeToMenuBar
      : defaults.bool(forKey: Key.minimizeToMenuBar)
    language =
      defaults.string(forKey: Key.language)
      .flatMap(SettingsLanguagePreference.init(rawValue:))
      ?? fallback.language
    ipv6Enabled =
      defaults.object(forKey: Key.ipv6Enabled) == nil
      ? fallback.ipv6Enabled
      : defaults.bool(forKey: Key.ipv6Enabled)
    logRetentionDays =
      Self.allowedLogRetentionDays.contains(defaults.integer(forKey: Key.logRetentionDays))
      ? defaults.integer(forKey: Key.logRetentionDays)
      : fallback.logRetentionDays
    cacheSizeLimitMB =
      Self.allowedCacheSizeLimits.contains(defaults.integer(forKey: Key.cacheSizeLimitMB))
      ? defaults.integer(forKey: Key.cacheSizeLimitMB)
      : fallback.cacheSizeLimitMB
  }

  var snapshot: SettingsPreferencesSnapshot {
    SettingsPreferencesSnapshot(
      startupBehavior: startupBehavior,
      minimizeToMenuBar: minimizeToMenuBar,
      language: language,
      ipv6Enabled: ipv6Enabled,
      logRetentionDays: logRetentionDays,
      cacheSizeLimitMB: cacheSizeLimitMB
    )
  }

  func apply(_ snapshot: SettingsPreferencesSnapshot) {
    startupBehavior = snapshot.startupBehavior
    minimizeToMenuBar = snapshot.minimizeToMenuBar
    language = snapshot.language
    ipv6Enabled = snapshot.ipv6Enabled
    logRetentionDays = snapshot.logRetentionDays
    cacheSizeLimitMB = snapshot.cacheSizeLimitMB
  }

  func reset() {
    apply(.defaults)
  }

  nonisolated static func persistedStartupBehavior(
    defaults: UserDefaults = .standard
  ) -> SettingsStartupBehavior {
    defaults.string(forKey: Key.startupBehavior)
      .flatMap(SettingsStartupBehavior.init(rawValue:))
      ?? SettingsPreferencesSnapshot.defaults.startupBehavior
  }

  nonisolated static func persistedMinimizeToMenuBar(
    defaults: UserDefaults = .standard
  ) -> Bool {
    defaults.object(forKey: Key.minimizeToMenuBar) == nil
      ? SettingsPreferencesSnapshot.defaults.minimizeToMenuBar
      : defaults.bool(forKey: Key.minimizeToMenuBar)
  }

  nonisolated static func persistedIPv6Enabled(
    defaults: UserDefaults = .standard
  ) -> Bool {
    defaults.object(forKey: Key.ipv6Enabled) == nil
      ? SettingsPreferencesSnapshot.defaults.ipv6Enabled
      : defaults.bool(forKey: Key.ipv6Enabled)
  }

  static let allowedLogRetentionDays = [7, 14, 30, 90]
  static let allowedCacheSizeLimits = [250, 500, 1_000, 2_000]
}

nonisolated struct SettingsSnapshot: Equatable, Sendable {
  struct General: Equatable, Sendable {
    let launchAtLoginEnabled: Bool
    let launchAtLoginStatus: LaunchAtLoginStatus
    let launchAtLoginFailure: LaunchAtLoginFailure?
    let automaticallyChecksForUpdates: Bool
    let startupBehavior: SettingsStartupBehavior
    let minimizeToMenuBar: Bool
    let language: SettingsLanguagePreference
  }

  struct System: Equatable, Sendable {
    let systemProxyEnabled: Bool
    let systemProxyStatus: String
    let canChangeSystemProxy: Bool
    let tunEnabled: Bool
    let tunStatus: SettingsTunStatus
    let tunFailure: UserFacingError?
    let canChangeTun: Bool
    let dnsHijackEnabled: Bool
    let canChangeDNS: Bool
    let ipv6Enabled: Bool
    let runtimeMode: String
    let mihomoVersion: String
  }

  struct Storage: Equatable, Sendable {
    let dataDirectory: String
    let logRetentionDays: Int
    let cacheSizeLimitMB: Int
  }

  struct About: Equatable, Sendable {
    let applicationVersion: String
    let updateChannel: String
    let lastUpdated: String
    let serviceRunning: Bool
  }

  let general: General
  let system: System
  let storage: Storage
  let about: About

  @MainActor
  static func live(
    engineStore: EngineStore,
    dataSettings: DataSettingsViewModel,
    updateController: UpdateController,
    preferences: SettingsPreferencesStore,
    tunOperationFailure: UserFacingError? = nil
  ) -> SettingsSnapshot {
    let directory =
      (try? ApplicationDirectories.live().root.path(percentEncoded: false))
      .map(Self.abbreviatedHomePath)
      ?? "~/Library/Application Support/Vela"
    let updateDate =
      updateController.state.lastCheckAt?.formatted(
        date: .omitted,
        time: .standard
      ) ?? "—"
    let applicationVersion = SettingsApplicationVersionPresentation.live()

    return SettingsSnapshot(
      general: General(
        launchAtLoginEnabled: dataSettings.launchAtLoginStatus == .enabled,
        launchAtLoginStatus: dataSettings.launchAtLoginStatus,
        launchAtLoginFailure: dataSettings.lastLaunchAtLoginError,
        automaticallyChecksForUpdates:
          updateController.state.automaticallyChecksForUpdates,
        startupBehavior: preferences.startupBehavior,
        minimizeToMenuBar: preferences.minimizeToMenuBar,
        language: preferences.language
      ),
      system: System(
        systemProxyEnabled: engineStore.isSystemProxyApplied,
        systemProxyStatus: VelaRuntimeStatusPresentation.systemProxyTitle(
          engineStore.systemProxyStatus
        ),
        canChangeSystemProxy:
          engineStore.canEnableSystemProxy || engineStore.canRestoreSystemProxy,
        tunEnabled: engineStore.isTunActive,
        tunStatus: tunStatus(engineStore, failure: tunOperationFailure),
        tunFailure: tunOperationFailure,
        canChangeTun: !engineStore.isEngineTransitioning,
        dnsHijackEnabled: engineStore.tunSettings.dnsHijack,
        canChangeDNS: !engineStore.isTunActive && !engineStore.isEngineTransitioning,
        ipv6Enabled: preferences.ipv6Enabled,
        runtimeMode: engineStore.runtimeMode?.rawValue.capitalized ?? "Rule",
        mihomoVersion: MihomoCoreDescriptor.requiredVersion
      ),
      storage: Storage(
        dataDirectory: directory,
        logRetentionDays: preferences.logRetentionDays,
        cacheSizeLimitMB: preferences.cacheSizeLimitMB
      ),
      about: About(
        applicationVersion: applicationVersion,
        updateChannel: updateController.state.channel.rawValue.capitalized,
        lastUpdated: updateDate,
        serviceRunning: engineStore.isRunning
      )
    )
  }

  private static func abbreviatedHomePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }

  @MainActor
  private static func tunStatus(
    _ engineStore: EngineStore,
    failure: UserFacingError?
  ) -> SettingsTunStatus {
    if engineStore.isEngineTransitioning {
      return .transitioning
    }
    if engineStore.isTunActive {
      return .enabled
    }
    if failure != nil {
      return .failed
    }
    return engineStore.privilegedComponentIsReady ? .disabled : .setupRequired
  }
}

nonisolated enum SettingsApplicationVersionPresentation {
  static func live(bundle: Bundle = .main) -> String {
    let values = bundle.infoDictionary
    let version = values?["CFBundleShortVersionString"] as? String
    let bundleBuild = values?["CFBundleVersion"] as? String
    let buildDate = bundle.executableURL.flatMap { executableURL in
      try? executableURL.resourceValues(
        forKeys: [.contentModificationDateKey]
      ).contentModificationDate
    }
    return text(
      version: version,
      bundleBuild: bundleBuild,
      buildDate: buildDate
    )
  }

  static func text(
    version: String?,
    bundleBuild: String?,
    buildDate: Date?,
    timeZone: TimeZone = .current
  ) -> String {
    let buildLabel: String? = if let buildDate {
      "Build \(formattedBuildDate(buildDate, timeZone: timeZone))"
    } else if let bundleBuild, !bundleBuild.isEmpty {
      "Build \(bundleBuild)"
    } else {
      nil
    }

    switch (version, buildLabel) {
    case (let version?, let buildLabel?): return "\(version) (\(buildLabel))"
    case (let version?, nil): return version
    case (nil, let buildLabel?): return buildLabel
    case (nil, nil): return "Development"
    }
  }

  private static func formattedBuildDate(
    _ date: Date,
    timeZone: TimeZone
  ) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyyMMdd"
    return formatter.string(from: date)
  }
}
