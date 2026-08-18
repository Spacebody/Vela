#if DEBUG
  import SwiftUI
  import VelaIPC

  /// Deterministic Settings evidence using the same production Liquid Glass
  /// hierarchy without reading or mutating live runtime services.
  struct SettingsVisualFixtureView: View {
    let configuration: VisualUITestConfiguration

    @State private var preferences: SettingsPreferencesStore
    @State private var launchAtLoginEnabled = true
    @State private var automaticUpdatesEnabled = true
    @State private var systemProxyEnabled = true
    @State private var tunEnabled = true
    @State private var dnsHijackEnabled = false

    init(configuration: VisualUITestConfiguration) {
      self.configuration = configuration
      let defaults =
        UserDefaults(
          suiteName: "dev.yilin.Vela.Visual.Settings.\(configuration.fixtureID)"
        ) ?? .standard
      defaults.removePersistentDomain(
        forName: "dev.yilin.Vela.Visual.Settings.\(configuration.fixtureID)"
      )
      _preferences = State(
        initialValue: SettingsPreferencesStore(defaults: defaults)
      )
    }

    var body: some View {
      SettingsLiquidGlassView(
        snapshot: snapshot,
        preferences: preferences,
        exportDocument: {
          SettingsTransferDocument(
            preferences: preferences.snapshot,
            tunSettings: .defaults,
            restoreSystemProxyAfterTun: true,
            updateChannel: .stable
          )
        },
        onImportDocument: { document in
          preferences.apply(try document.validated().preferences)
        },
        onResetDefaults: {
          preferences.reset()
          automaticUpdatesEnabled = true
        },
        onSetLaunchAtLogin: { launchAtLoginEnabled = $0 },
        onSetAutomaticUpdates: { automaticUpdatesEnabled = $0 },
        onSetSystemProxy: { systemProxyEnabled = $0 },
        onSetTun: { enabled in
          if configuration.state == .partialFailure
            || configuration.state == .failure
          {
            return tunFailure
          }
          tunEnabled = enabled
          return nil
        },
        onSetDNSHijack: { dnsHijackEnabled = $0 },
        onSetIPv6: { preferences.ipv6Enabled = $0 },
        onOpenDataDirectory: {},
        onOpenDiagnostics: {},
        onClearTransientData: {}
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .topLeading) {
        VStack(spacing: 0) {
          VisualSurfaceMarker(
            identifier: "settings.window",
            label: "Vela Settings"
          )
          VisualReadyMarker(fixtureID: configuration.fixtureID)
        }
      }
      .environment(\.visualUITestConfiguration, configuration)
      .environment(\.locale, configuration.locale)
      .preferredColorScheme(configuration.colorScheme)
    }

    private var snapshot: SettingsSnapshot {
      let status: LaunchAtLoginStatus =
        switch configuration.state {
        case .permissionRequired:
          .requiresApproval
        case .pendingMutation, .transitioning:
          .unknown
        case .partialFailure, .failure:
          .notRegistered
        default:
          launchAtLoginEnabled ? .enabled : .notRegistered
        }
      let failure: LaunchAtLoginFailure? =
        switch configuration.state {
        case .partialFailure, .failure: .registerFailed
        default: nil
        }
      let tunFailure =
        configuration.state == .partialFailure || configuration.state == .failure
        ? self.tunFailure
        : nil
      let tunStatus: SettingsTunStatus
      if configuration.state == .pendingMutation {
        tunStatus = .transitioning
      } else if tunFailure != nil {
        tunStatus = .failed
      } else {
        tunStatus = tunEnabled ? .enabled : .disabled
      }

      return SettingsSnapshot(
        general: .init(
          launchAtLoginEnabled: launchAtLoginEnabled,
          launchAtLoginStatus: status,
          launchAtLoginFailure: failure,
          automaticallyChecksForUpdates: automaticUpdatesEnabled,
          startupBehavior: preferences.startupBehavior,
          minimizeToMenuBar: preferences.minimizeToMenuBar,
          language: preferences.language
        ),
        system: .init(
          systemProxyEnabled: systemProxyEnabled,
          systemProxyStatus:
            configuration.localeIdentifier == .simplifiedChinese
            ? (systemProxyEnabled ? "已启用" : "已停用")
            : (systemProxyEnabled ? "Enabled" : "Disabled"),
          canChangeSystemProxy: configuration.state != .pendingMutation,
          tunEnabled: tunEnabled,
          tunStatus: tunStatus,
          tunFailure: tunFailure,
          canChangeTun: configuration.state != .pendingMutation,
          dnsHijackEnabled: dnsHijackEnabled,
          canChangeDNS: !tunEnabled,
          ipv6Enabled: preferences.ipv6Enabled,
          runtimeMode: configuration.localeIdentifier == .simplifiedChinese
            ? "规则"
            : "Rule",
          mihomoVersion: "v1.19.29"
        ),
        storage: .init(
          dataDirectory: "~/Library/Application Support/Vela",
          logRetentionDays: preferences.logRetentionDays,
          cacheSizeLimitMB: preferences.cacheSizeLimitMB
        ),
        about: .init(
          applicationVersion: "0.9 (90)",
          updateChannel: configuration.localeIdentifier == .simplifiedChinese
            ? "稳定版"
            : "Stable",
          lastUpdated: "10:24:31",
          serviceRunning: true
        )
      )
    }

    private var tunFailure: UserFacingError {
      UserFacingError(
        title: configuration.localeIdentifier == .simplifiedChinese
          ? "无法启用 TUN"
          : "Unable to Enable TUN",
        message: configuration.localeIdentifier == .simplifiedChinese
          ? "特权网络服务未确认请求的状态。"
          : "The privileged network service did not confirm the requested state.",
        suggestedAction: configuration.localeIdentifier == .simplifiedChinese
          ? "打开诊断后重试。"
          : "Open Diagnostics, then try again.",
        isRetryable: true,
        recoveryActions: [.openDiagnostics]
      )
    }
  }
#endif
