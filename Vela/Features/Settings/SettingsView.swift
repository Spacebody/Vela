import AppKit
import Foundation
import SwiftUI
import VelaIPC

/// Adapts live application services to the Settings feature page rendered by
/// the shared main-window shell.
struct SettingsView: View {
  @Environment(\.openWindow) private var openWindow
#if DEBUG
  @Environment(\.visualUITestConfiguration) private var visualTestConfiguration
#endif

  let engineStore: EngineStore
  let dataSettings: DataSettingsViewModel
  let updateController: UpdateController
  let helpNavigationCoordinator: HelpNavigationCoordinator
  let onOpenDiagnostics: () -> Void

  @State private var preferences = SettingsPreferencesStore()
  @State private var tunOperationFailure: UserFacingError?
  @State private var showsTunOnboarding = false
  @State private var permissionEducation: PermissionEducationModel?
  @State private var externalLinkError: String?

  var body: some View {
    SettingsLiquidGlassView(
      snapshot: SettingsSnapshot.live(
        engineStore: engineStore,
        dataSettings: dataSettings,
        updateController: updateController,
        preferences: preferences,
        tunOperationFailure: tunOperationFailure
      ),
      preferences: preferences,
      exportDocument: {
        SettingsTransferDocument(
          preferences: preferences.snapshot,
          tunSettings: engineStore.tunSettings,
          restoreSystemProxyAfterTun: engineStore.restoreSystemProxyAfterTun,
          updateChannel: updateController.state.channel
        )
      },
      onImportDocument: importDocument,
      onResetDefaults: {
        preferences.reset()
        updateController.setAutomaticallyChecksForUpdates(true)
      },
      onSetLaunchAtLogin: setLaunchAtLogin,
      onSetAutomaticUpdates: updateController.setAutomaticallyChecksForUpdates,
      onSetSystemProxy: { enabled in
        engineStore.requestSystemProxyEnabled(enabled)
      },
      onSetTun: setTun,
      onSetDNSHijack: setDNSHijack,
      onSetIPv6: setIPv6,
      onOpenDataDirectory: openDataDirectory,
      onOpenDiagnostics: onOpenDiagnostics,
      onClearTransientData: clearTransientData
    )
#if DEBUG
    .overlay(alignment: .topLeading) {
      VStack(spacing: 0) {
        VisualSurfaceMarker(
          identifier: "settings.window",
          label: "Vela Settings"
        )
        VisualReadyMarker(fixtureID: "settings.loaded")
      }
    }
#endif
    .sheet(isPresented: $showsTunOnboarding) {
      TunOnboardingView(engineStore: engineStore)
#if DEBUG
        .environment(\.visualUITestConfiguration, visualTestConfiguration)
#endif
    }
    .sheet(item: $permissionEducation) { model in
      PermissionEducationView(
        model: model,
        onPrimaryAction: { approvePermissionEducation(model) },
        onNotNow: { permissionEducation = nil },
        onHelp: { topic in
          openHelp(topic: topic)
          permissionEducation = nil
        }
      )
    }
    .alert(
      VelaL10n.string("legacy.couldNotOpenItem", defaultValue: "Could Not Open Item"),
      isPresented: externalLinkErrorIsPresented
    ) {
      Button(VelaL10n.string("legacy.ok", defaultValue: "OK")) {
        externalLinkError = nil
      }
    } message: {
      Text(externalLinkError ?? "")
    }
  }

  private func setLaunchAtLogin(_ enabled: Bool) {
    if enabled {
      permissionEducation = .launchAtLogin(status: launchAtLoginEducationStatus)
    } else {
      dataSettings.setLaunchAtLoginEnabled(false)
    }
  }

  private func setTun(_ enabled: Bool) async -> UserFacingError? {
    tunOperationFailure = nil
    if enabled, !engineStore.privilegedComponentIsReady {
      showsTunOnboarding = true
      return nil
    }

    let previousErrorID = engineStore.lastError?.id
    await engineStore.setTunEnabled(enabled)
    let failure = SettingsTunOperationFeedback.failure(
      requestedEnabled: enabled,
      isTunActive: engineStore.isTunActive,
      previousErrorID: previousErrorID,
      currentError: engineStore.lastError
    )
    tunOperationFailure = failure
    return failure
  }

  private func setDNSHijack(_ enabled: Bool) {
    var settings = engineStore.tunSettings
    settings.dnsHijack = enabled
    engineStore.updateTunSettings(settings)
  }

  private func setIPv6(_ enabled: Bool) async throws {
    try await engineStore.setIPv6Enabled(enabled)
  }

  private var launchAtLoginEducationStatus: PermissionEducationStatus {
    switch dataSettings.launchAtLoginStatus {
    case .notRegistered: .available
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notFound, .unknown: .unavailable
    }
  }

  private func approvePermissionEducation(_ model: PermissionEducationModel) {
    guard model.topic == .launchAtLogin else {
      permissionEducation = nil
      return
    }
    switch model.status {
    case .requiresApproval, .denied, .unavailable:
      dataSettings.openLoginItemsSettings()
    case .notRequested, .available, .enabled:
      dataSettings.setLaunchAtLoginEnabled(true)
    }
    permissionEducation = nil
  }

  private func openHelp(topic: String?) {
    guard helpNavigationCoordinator.request(topic: topic) else { return }
    openWindow(id: "help")
  }

  private var externalLinkErrorIsPresented: Binding<Bool> {
    Binding(
      get: { externalLinkError != nil },
      set: { isPresented in
        if !isPresented {
          externalLinkError = nil
        }
      }
    )
  }

  private func openDataDirectory() {
    do {
      let directory = try ApplicationDirectories.live().root
      guard FileManager.default.fileExists(atPath: directory.path),
        NSWorkspace.shared.open(directory)
      else {
        externalLinkError = VelaL10n.string(
          "settings.dataDirectory.error.unavailable",
          defaultValue: "Vela's data directory is not available yet."
        )
        return
      }
    } catch {
      externalLinkError = VelaL10n.string(
        "settings.dataDirectory.error.unresolved",
        defaultValue: "Vela's data directory could not be resolved."
      )
    }
  }

  private func clearTransientData() async throws {
    guard !engineStore.isEngineTransitioning else {
      throw SettingsMaintenanceError.runtimeBusy
    }

    let directories = try ApplicationDirectories.live()
    let logDirectory = directories.logs
    let cacheDirectory = directories.root.appendingPathComponent(
      "cache",
      isDirectory: true
    )
    try await Task.detached(priority: .utility) {
      try SettingsTransientDataCleaner.clear(
        logDirectory: logDirectory,
        cacheDirectory: cacheDirectory
      )
    }.value
  }

  private func importDocument(_ document: SettingsTransferDocument) throws {
    let validated = try document.validated()
    guard !engineStore.isEngineTransitioning else {
      throw SettingsTransferError.runtimeBusy
    }
    guard engineStore.updatePreparationState == .idle,
      !engineStore.isUpdateRecoveryInProgress
    else {
      throw SettingsTransferError.updateInProgress
    }

    let previous = SettingsTransferDocument(
      preferences: preferences.snapshot,
      tunSettings: engineStore.tunSettings,
      restoreSystemProxyAfterTun: engineStore.restoreSystemProxyAfterTun,
      updateChannel: updateController.state.channel
    )

    preferences.apply(validated.preferences)
    engineStore.updateTunSettings(validated.tunSettings)
    engineStore.setRestoreSystemProxyAfterTun(validated.restoreSystemProxyAfterTun)
    updateController.setChannel(validated.updateChannel)

    guard preferences.snapshot == validated.preferences,
      engineStore.tunSettings == validated.tunSettings,
      engineStore.restoreSystemProxyAfterTun == validated.restoreSystemProxyAfterTun,
      updateController.state.channel == validated.updateChannel
    else {
      preferences.apply(previous.preferences)
      engineStore.updateTunSettings(previous.tunSettings)
      engineStore.setRestoreSystemProxyAfterTun(previous.restoreSystemProxyAfterTun)
      updateController.setChannel(previous.updateChannel)
      throw SettingsTransferError.commitFailed
    }
  }
}
