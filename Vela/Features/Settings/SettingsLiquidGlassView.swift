import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VelaIPC

@MainActor
struct SettingsLiquidGlassView: View {
  @Environment(\.locale) private var locale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let snapshot: SettingsSnapshot
  let preferences: SettingsPreferencesStore
  let exportDocument: () -> SettingsTransferDocument
  let onImportDocument: (SettingsTransferDocument) throws -> Void
  let onResetDefaults: () -> Void
  let onSetLaunchAtLogin: (Bool) -> Void
  let onSetAutomaticUpdates: (Bool) -> Void
  let onSetSystemProxy: (Bool) -> Void
  let onSetTun: (Bool) async -> UserFacingError?
  let onSetDNSHijack: (Bool) -> Void
  let onSetIPv6: (Bool) async throws -> Void
  let onOpenDataDirectory: () -> Void
  let onOpenDiagnostics: () -> Void
  let onClearTransientData: () async throws -> Void

  @State private var selectedCategory: SettingsPageCategory = .general
  @State private var searchText = ""
  @State private var scrollRequest: SettingsScrollRequest?
  @State private var advancedOptionsExpanded = false
  @State private var pendingConfirmation: SettingsConfirmation?
  @State private var operationMessage: SettingsOperationMessage?
  @State private var isChangingIPv6 = false
  @FocusState private var searchIsFocused: Bool

  private var copy: SettingsPageCopy {
    SettingsPageCopy(locale: locale)
  }

  var body: some View {
    GeometryReader { geometry in
      let compact = geometry.size.height < 780

      ZStack {
        VelaPageCanvas()

        VStack(spacing: 0) {
          pageHeader(compact: compact)

          Group {
            if #available(macOS 26.0, *) {
              GlassEffectContainer(spacing: SettingsDesignTokens.glassFusionSpacing) {
                settingsColumns(compact: compact)
              }
            } else {
              settingsColumns(compact: compact)
            }
          }
          .padding(.horizontal, SettingsDesignTokens.pagePadding)
          .padding(.bottom, SettingsDesignTokens.pagePadding)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(item: $pendingConfirmation) { confirmation in
      switch confirmation {
      case .resetDefaults:
        VelaConfirmationSheet(
          title: copy.resetConfirmationTitle,
          message: copy.resetConfirmationDetail,
          confirmTitle: copy.resetToDefaults,
          onConfirm: {
            pendingConfirmation = nil
            onResetDefaults()
            operationMessage = .success(copy.defaultsRestored)
          },
          onCancel: {
            pendingConfirmation = nil
          }
        )
      case .clearTransientData:
        VelaConfirmationSheet(
          title: copy.clearConfirmationTitle,
          message: copy.clearConfirmationDetail,
          confirmTitle: copy.clearData,
          onConfirm: {
            pendingConfirmation = nil
            performClearData()
          },
          onCancel: {
            pendingConfirmation = nil
          }
        )
      }
    }
    .alert(item: $operationMessage) { message in
      Alert(
        title: Text(message.isError ? copy.operationFailed : copy.settingsUpdated),
        message: Text(message.text),
        dismissButton: .default(Text(copy.ok))
      )
    }
    .onAppear {
      guard let category = SettingsNavigationRequest.consumePendingCategory()
      else { return }
      navigate(to: pageCategory(for: category))
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .velaOpenSettingsCategory)
    ) { notification in
      guard let legacyCategory = SettingsNavigationRequest.category(from: notification)
      else { return }
      navigate(to: pageCategory(for: legacyCategory))
      SettingsNavigationRequest.acknowledge(legacyCategory)
    }
    .onReceive(NotificationCenter.default.publisher(for: .velaFocusSearch)) { _ in
      searchIsFocused = true
    }
  }

  private func settingsColumns(compact _: Bool) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        settingsContent
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.bottom, SettingsDesignTokens.pagePadding)
      }
      .scrollIndicators(.visible)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: scrollRequest) {
        guard let request = scrollRequest else { return }
        withAnimation(
          VelaMotion.animation(VelaMotion.slowSeconds, reduceMotion: reduceMotion)
        ) {
          proxy.scrollTo(request.targetID, anchor: .top)
        }
      }
      .onChange(of: searchText) {
        guard let match = firstSearchMatch else { return }
        if match.revealsAdvancedOptions {
          advancedOptionsExpanded = true
        }
        selectedCategory = match.category
        requestScroll(to: match.id, category: match.category)
      }
    }
  }

  private func pageHeader(compact: Bool) -> some View {
    HStack(alignment: .center, spacing: 18) {
      VStack(alignment: .leading, spacing: 5) {
        Text(copy.settings)
          .font(VelaTypography.mainPageTitle)
          .minimumScaleFactor(0.82)
          .foregroundStyle(SettingsDesignTokens.textPrimary)
          .accessibilityAddTraits(.isHeader)

        Text(copy.pageSubtitle)
          .font(VelaTypography.pageSubtitle)
          .foregroundStyle(SettingsDesignTokens.textSecondary)
      }

      Spacer(minLength: 24)

      HStack(spacing: 14) {
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(SettingsDesignTokens.textSecondary)
            .accessibilityHidden(true)

          TextField(copy.searchSettings, text: $searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($searchIsFocused)
            .accessibilityIdentifier("settings.search")

          if !searchText.isEmpty {
            Button {
              searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(SettingsDesignTokens.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copy.clearSearch)
          }
        }
        .padding(.horizontal, 14)
        .frame(width: compact ? 220 : 258, height: 42)
        .settingsGlassSurface(radius: 12)

        Button {
          pendingConfirmation = .resetDefaults
        } label: {
          if compact {
            Image(systemName: "arrow.counterclockwise")
              .font(.system(size: 14, weight: .semibold))
              .frame(width: 42, height: 42)
          } else {
            Label(copy.resetToDefaults, systemImage: "arrow.counterclockwise")
              .font(.system(size: 13, weight: .semibold))
              .padding(.horizontal, 15)
              .frame(height: 42)
          }
        }
        .buttonStyle(SettingsGlassButtonStyle(radius: 12))
        .help(copy.resetToDefaults)
        .accessibilityLabel(copy.resetToDefaults)
        .accessibilityIdentifier("settings.reset")
      }
    }
    .padding(.horizontal, SettingsDesignTokens.pagePadding)
    .padding(.top, compact ? 24 : 34)
    .padding(.bottom, compact ? 18 : 24)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings.categoryHeader")
  }

  private var firstSearchMatch: SettingsSearchEntry? {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    return searchEntries.first { entry in
      entry.haystack.localizedCaseInsensitiveContains(query)
    }
  }

  private var searchEntries: [SettingsSearchEntry] {
    [
      searchEntry(.general, copy.startupBehavior, copy.startupBehaviorDetail),
      searchEntry(.general, copy.launchAtLogin, copy.launchAtLoginDetail),
      searchEntry(.general, copy.minimizeToMenuBar, copy.minimizeToMenuBarDetail),
      searchEntry(.general, copy.checkForUpdates, copy.checkForUpdatesDetail),
      searchEntry(.coreNetwork, copy.systemProxy, copy.systemProxyDetail),
      searchEntry(.coreNetwork, copy.tunMode, copy.tunModeDetail),
      searchEntry(.coreNetwork, copy.ruleMode, copy.ruleModeDetail),
      searchEntry(.coreNetwork, copy.dnsSettings, copy.dnsSettingsDetail),
      searchEntry(.coreNetwork, copy.ipv6, copy.ipv6Detail),
      searchEntry(.coreNetwork, copy.mihomoCore, copy.mihomoCoreDetail),
      searchEntry(.coreNetwork, copy.serviceStatus, copy.serviceStatusDetail),
      searchEntry(.profiles, copy.dataDirectory, copy.dataDirectoryDetail),
      searchEntry(.profiles, copy.configurationBackup, copy.configurationBackupDetail),
      searchEntry(.profiles, copy.exportSettings, copy.exportSettingsDetail),
      searchEntry(.profiles, copy.importSettings, copy.importSettingsDetail),
      searchEntry(.profiles, copy.logRetention, copy.logRetentionDetail),
      searchEntry(.profiles, copy.cacheSizeLimit, copy.cacheSizeLimitDetail),
      searchEntry(
        .profiles,
        copy.clearAllData,
        copy.clearAllDataDetail,
        revealsAdvancedOptions: true
      ),
      searchEntry(.appearance, copy.language, copy.languageDetail),
      searchEntry(.diagnostics, copy.openDiagnostics, copy.openDiagnosticsDetail),
      searchEntry(.diagnostics, copy.lastUpdateCheck, copy.lastUpdateCheckDetail),
      searchEntry(.diagnostics, copy.version, copy.versionDetail),
      searchEntry(.diagnostics, copy.updateChannel, copy.updateChannelDetail),
    ]
  }

  private func searchEntry(
    _ category: SettingsPageCategory,
    _ title: String,
    _ detail: String,
    revealsAdvancedOptions: Bool = false
  ) -> SettingsSearchEntry {
    SettingsSearchEntry(
      id: sectionID(category),
      category: category,
      haystack: "\(copy.title(category)) \(copy.subtitle(category)) \(title) \(detail)",
      revealsAdvancedOptions: revealsAdvancedOptions
    )
  }

  private func isSearchMatch(in category: SettingsPageCategory) -> Bool {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return false }
    return searchEntries.contains { entry in
      entry.category == category
        && entry.haystack.localizedCaseInsensitiveContains(query)
    }
  }

  @ViewBuilder
  private var settingsContent: some View {
    VStack(spacing: 18) {
      generalContent
      coreNetworkContent
      profilesContent
      appearanceContent
      diagnosticsContent
    }
  }

  private var generalContent: some View {
    VStack(spacing: 18) {
      generalGroup
    }
    .id(sectionID(.general))
    .settingsSearchSectionHighlight(isSearchMatch(in: .general))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings.detail.general")
  }

  private var generalGroup: some View {
    SettingsGroup(title: copy.general) {
      SettingsValueRow(
        title: copy.startupBehavior,
        detail: copy.startupBehaviorDetail
      ) {
        Picker("", selection: preferenceBinding(\.startupBehavior)) {
          ForEach(SettingsStartupBehavior.allCases, id: \.self) { behavior in
            Text(copy.startupBehaviorTitle(behavior)).tag(behavior)
          }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(copy.startupBehavior)
        .accessibilityHint(copy.startupBehaviorDetail)
      }

      SettingsRowDivider()

      SettingsValueRow(
        title: copy.launchAtLogin,
        detail: copy.launchAtLoginDetail
      ) {
        VStack(alignment: .trailing, spacing: 4) {
          Toggle(
            "",
            isOn: Binding(
              get: { snapshot.general.launchAtLoginEnabled },
              set: { enabled in onSetLaunchAtLogin(enabled) }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .tint(SettingsDesignTokens.accent)
          .accessibilityLabel(copy.launchAtLogin)
          .accessibilityValue(
            copy.launchAtLoginStatusTitle(snapshot.general.launchAtLoginStatus)
          )
          .accessibilityHint(copy.launchAtLoginDetail)
          .accessibilityIdentifier("settings.setting.launchAtLogin")

          if let failure = snapshot.general.launchAtLoginFailure {
            Text(copy.launchAtLoginFailureTitle(failure))
              .font(VelaTypography.caption.weight(.medium))
              .foregroundStyle(SettingsDesignTokens.destructive)
          } else if snapshot.general.launchAtLoginStatus == .requiresApproval {
            Text(copy.launchAtLoginStatusTitle(.requiresApproval))
              .font(VelaTypography.caption.weight(.medium))
              .foregroundStyle(SettingsDesignTokens.warning)
          }
        }
      }

      SettingsRowDivider()

      SettingsValueRow(
        title: copy.minimizeToMenuBar,
        detail: copy.minimizeToMenuBarDetail
      ) {
        Toggle("", isOn: preferenceBinding(\.minimizeToMenuBar))
          .labelsHidden()
          .toggleStyle(.switch)
          .tint(SettingsDesignTokens.accent)
          .accessibilityLabel(copy.minimizeToMenuBar)
          .accessibilityValue(preferences.minimizeToMenuBar ? copy.enabled : copy.disabled)
          .accessibilityHint(copy.minimizeToMenuBarDetail)
      }

      SettingsRowDivider()

      SettingsValueRow(
        title: copy.checkForUpdates,
        detail: copy.checkForUpdatesDetail
      ) {
        Toggle(
          "",
          isOn: Binding(
            get: { snapshot.general.automaticallyChecksForUpdates },
            set: { enabled in onSetAutomaticUpdates(enabled) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(SettingsDesignTokens.accent)
        .accessibilityLabel(copy.checkForUpdates)
        .accessibilityValue(
          snapshot.general.automaticallyChecksForUpdates ? copy.enabled : copy.disabled
        )
        .accessibilityHint(copy.checkForUpdatesDetail)
      }
    }
  }

  private var coreNetworkContent: some View {
    VStack(spacing: 18) {
      SettingsGroup(title: copy.networkAndRouting) {
        SettingsNavigationRow(
          title: copy.systemProxy,
          detail: copy.systemProxyDetail,
          status: snapshot.system.systemProxyStatus,
          isEnabled: snapshot.system.canChangeSystemProxy
        ) {
          onSetSystemProxy(!snapshot.system.systemProxyEnabled)
        }
        SettingsRowDivider()
        SettingsNavigationRow(
          title: copy.tunMode,
          detail: copy.tunModeDetail,
          status: copy.tunStatusTitle(snapshot.system.tunStatus),
          statusTone: snapshot.system.tunFailure == nil ? .automatic : .error,
          isEnabled: snapshot.system.canChangeTun,
          accessibilityIdentifier: "settings.action.tun"
        ) {
          performTunChange(!snapshot.system.tunEnabled)
        }
        SettingsRowDivider()
        SettingsReadOnlyRow(
          title: copy.ruleMode,
          detail: copy.ruleModeDetail,
          value: snapshot.system.runtimeMode
        )
        SettingsRowDivider()
        SettingsNavigationRow(
          title: copy.dnsSettings,
          detail: copy.dnsSettingsDetail,
          status: snapshot.system.dnsHijackEnabled ? copy.enhanced : copy.systemValue,
          isEnabled: snapshot.system.canChangeDNS
        ) {
          onSetDNSHijack(!snapshot.system.dnsHijackEnabled)
        }
        SettingsRowDivider()
        SettingsValueRow(
          title: copy.ipv6,
          detail: copy.ipv6Detail
        ) {
          Toggle(
            "",
            isOn: Binding(
              get: { preferences.ipv6Enabled },
              set: { enabled in performIPv6Change(enabled) }
            )
          )
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(SettingsDesignTokens.accent)
            .accessibilityLabel(copy.ipv6)
            .accessibilityValue(preferences.ipv6Enabled ? copy.enabled : copy.disabled)
            .accessibilityHint(copy.ipv6Detail)
        }
        SettingsRowDivider()
        SettingsReadOnlyRow(
          title: copy.mihomoCore,
          detail: copy.mihomoCoreDetail,
          value: snapshot.system.mihomoVersion
        )
        SettingsRowDivider()
        SettingsReadOnlyRow(
          title: copy.serviceStatus,
          detail: copy.serviceStatusDetail,
          value: snapshot.about.serviceRunning ? copy.enabled : copy.disabled
        )
      }
    }
    .id(sectionID(.coreNetwork))
    .settingsSearchSectionHighlight(isSearchMatch(in: .coreNetwork))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings.detail.coreNetwork")
  }

  private var profilesContent: some View {
    VStack(spacing: 18) {
      SettingsGroup(title: copy.configurationAndData) {
        SettingsValueRow(
          title: copy.dataDirectory,
          detail: copy.dataDirectoryDetail
        ) {
          HStack(spacing: 10) {
            Text(snapshot.storage.dataDirectory)
              .font(.system(size: 12.5, weight: .medium))
              .foregroundStyle(SettingsDesignTokens.textPrimary)
              .lineLimit(1)
              .truncationMode(.middle)
            Button(action: onOpenDataDirectory) {
              Image(systemName: "folder")
                .frame(width: 30, height: 28)
            }
            .buttonStyle(SettingsGlassButtonStyle(radius: 8))
            .accessibilityLabel(copy.openDataDirectory)
          }
          .frame(maxWidth: 340, alignment: .trailing)
        }
        SettingsRowDivider()
        SettingsReadOnlyRow(
          title: copy.configurationBackup,
          detail: copy.configurationBackupDetail,
          value: copy.available
        )
        SettingsRowDivider()
        SettingsValueRow(
          title: copy.exportSettings,
          detail: copy.exportSettingsDetail
        ) {
          Button(copy.exportAction) { performExport() }
            .buttonStyle(SettingsGlassButtonStyle(radius: 8))
            .accessibilityIdentifier("settings.export")
        }
        SettingsRowDivider()
        SettingsValueRow(
          title: copy.importSettings,
          detail: copy.importSettingsDetail
        ) {
          Button(copy.importAction) { performImport() }
            .buttonStyle(SettingsGlassButtonStyle(radius: 8))
            .accessibilityHint(copy.importSettingsDetail)
            .accessibilityIdentifier("settings.import")
        }
        SettingsRowDivider()
        SettingsReadOnlyRow(
          title: copy.logRetention,
          detail: copy.logRetentionDetail,
          value: copy.days(preferences.logRetentionDays)
        )
        SettingsRowDivider()
        SettingsReadOnlyRow(
          title: copy.cacheSizeLimit,
          detail: copy.cacheSizeLimitDetail,
          value: copy.megabytes(preferences.cacheSizeLimitMB)
        )
      }

      SettingsAdvancedDisclosure(
        title: copy.advanced,
        detail: copy.advancedDetail,
        isExpanded: $advancedOptionsExpanded
      ) {
        SettingsValueRow(
          title: copy.clearAllData,
          detail: copy.clearAllDataDetail
        ) {
          Button(copy.clearData) {
            pendingConfirmation = .clearTransientData
          }
          .buttonStyle(SettingsDestructiveButtonStyle())
          .accessibilityIdentifier("settings.clearData")
        }
      }
    }
    .id(sectionID(.profiles))
    .settingsSearchSectionHighlight(isSearchMatch(in: .profiles))
    .accessibilityIdentifier("settings.detail.profiles")
  }

  private var appearanceContent: some View {
    VStack(spacing: 18) {
      SettingsGroup(title: copy.uiAndAppearance) {
        SettingsReadOnlyRow(
          title: copy.language,
          detail: copy.languageDetail,
          value: copy.languageTitle(preferences.language)
        )
      }
    }
    .id(sectionID(.appearance))
    .settingsSearchSectionHighlight(isSearchMatch(in: .appearance))
    .accessibilityIdentifier("settings.detail.appearance")
  }

  private var diagnosticsContent: some View {
    VStack(spacing: 18) {
      SettingsGroup(title: copy.logsAndDiagnostics) {
        SettingsNavigationRow(
          title: copy.openDiagnostics,
          detail: copy.openDiagnosticsDetail,
          status: copy.open,
          isEnabled: true,
          action: onOpenDiagnostics
        )
        SettingsRowDivider()
        SettingsReadOnlyRow(
          title: copy.lastUpdateCheck,
          detail: copy.lastUpdateCheckDetail,
          value: snapshot.about.lastUpdated
        )
      }

      SettingsGroup(title: copy.about) {
        SettingsReadOnlyRow(
          title: copy.version,
          detail: copy.versionDetail,
          value: snapshot.about.applicationVersion
        )
        SettingsRowDivider()
        SettingsReadOnlyRow(
          title: copy.updateChannel,
          detail: copy.updateChannelDetail,
          value: snapshot.about.updateChannel
        )
        SettingsRowDivider()
        SettingsReadOnlyRow(
          title: copy.mihomoCore,
          detail: copy.mihomoCoreDetail,
          value: snapshot.system.mihomoVersion
        )
      }
    }
    .id(sectionID(.diagnostics))
    .settingsSearchSectionHighlight(isSearchMatch(in: .diagnostics))
    .accessibilityIdentifier("settings.detail.diagnostics")
  }

  private func preferenceBinding<Value>(
    _ keyPath: ReferenceWritableKeyPath<SettingsPreferencesStore, Value>
  ) -> Binding<Value> {
    Binding(
      get: { preferences[keyPath: keyPath] },
      set: { preferences[keyPath: keyPath] = $0 }
    )
  }

  private func pageCategory(for category: SettingsCategory) -> SettingsPageCategory {
    switch category {
    case .general: .general
    case .network, .tun, .core: .coreNetwork
    case .automation, .advanced: .profiles
    case .updates, .betaDiagnostics, .about: .diagnostics
    }
  }

  private func navigate(to category: SettingsPageCategory) {
    let destination = canonicalCategory(category)
    if category == .advanced {
      advancedOptionsExpanded = true
    }
    requestScroll(to: sectionID(destination), category: destination)
  }

  private func requestScroll(to targetID: String, category: SettingsPageCategory) {
    selectedCategory = category
    scrollRequest = SettingsScrollRequest(targetID: targetID)
  }

  private func sectionID(_ category: SettingsPageCategory) -> String {
    "settings.section.\(canonicalCategory(category).rawValue)"
  }

  private func canonicalCategory(
    _ category: SettingsPageCategory
  ) -> SettingsPageCategory {
    switch category {
    case .general:
      .general
    case .coreNetwork, .proxies, .rulesRouting:
      .coreNetwork
    case .profiles, .advanced:
      .profiles
    case .appearance:
      .appearance
    case .diagnostics, .about:
      .diagnostics
    }
  }

  private func performExport() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Vela-Settings.json"
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    do {
      let data = try SettingsTransferCodec.encode(exportDocument())
      try data.write(to: destination, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: destination.path
      )
      operationMessage = .success(copy.exportSucceeded)
    } catch {
      operationMessage = .failure(
        copy.exportFailed(error.localizedDescription)
      )
    }
  }

  private func performImport() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    guard panel.runModal() == .OK, let source = panel.url else { return }

    do {
      let data = try Data(contentsOf: source, options: [.mappedIfSafe])
      let document = try SettingsTransferCodec.decode(data)
      try onImportDocument(document)
      operationMessage = .success(copy.importSucceeded)
    } catch {
      operationMessage = .failure(
        copy.importFailed(error.localizedDescription)
      )
    }
  }

  private func performClearData() {
    Task { @MainActor in
      do {
        try await onClearTransientData()
        operationMessage = .success(copy.clearSucceeded)
      } catch {
        operationMessage = .failure(
          copy.clearFailed(error.localizedDescription)
        )
      }
    }
  }

  private func performTunChange(_ enabled: Bool) {
    Task { @MainActor in
      guard let failure = await onSetTun(enabled) else { return }
      let detail = [failure.title, failure.message, failure.suggestedAction]
        .compactMap { $0 }
        .joined(separator: "\n")
      operationMessage = .failure(detail)
    }
  }

  private func performIPv6Change(_ enabled: Bool) {
    guard !isChangingIPv6 else { return }
    let previousValue = preferences.ipv6Enabled
    guard previousValue != enabled else { return }

    // Keep the native switch interactive while Mihomo validates the mutation.
    // Changing hit-testing or enabled state during the pointer-up transition can
    // leave AppKit's switch in a stale highlighted appearance. The guard above
    // already prevents duplicate writes while the operation is pending.
    preferences.ipv6Enabled = enabled
    isChangingIPv6 = true
    Task { @MainActor in
      defer { isChangingIPv6 = false }
      do {
        try await onSetIPv6(enabled)
      } catch {
        preferences.ipv6Enabled = previousValue
        operationMessage = .failure(error.localizedDescription)
      }
    }
  }
}

private struct SettingsScrollRequest: Equatable {
  let id = UUID()
  let targetID: String
}

private struct SettingsSearchEntry {
  let id: String
  let category: SettingsPageCategory
  let haystack: String
  let revealsAdvancedOptions: Bool
}

@MainActor
private struct SettingsGroup<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(.system(size: 15.5, weight: .semibold))
        .foregroundStyle(SettingsDesignTokens.textPrimary)
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsDesignTokens.groupHeaderSurface)
        .overlay(alignment: .bottom) {
          Rectangle()
            .fill(SettingsDesignTokens.separator)
            .frame(height: 1)
        }

      content
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .settingsGlassSurface(radius: 14)
  }
}

@MainActor
private struct SettingsAdvancedDisclosure<Content: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let title: String
  let detail: String
  @Binding var isExpanded: Bool
  let content: Content

  init(
    title: String,
    detail: String,
    isExpanded: Binding<Bool>,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.detail = detail
    _isExpanded = isExpanded
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(
          VelaMotion.animation(VelaMotion.standardSeconds, reduceMotion: reduceMotion)
        ) {
          isExpanded.toggle()
        }
      } label: {
        HStack(alignment: .center, spacing: 18) {
          SettingsRowCopy(title: title, detail: detail)
          Spacer(minLength: 16)
          Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SettingsDesignTokens.textTertiary)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 58)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityHint(detail)

      if isExpanded {
        SettingsRowDivider()
        content
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .settingsGlassSurface(radius: 14)
  }
}

@MainActor
private struct SettingsValueRow<Trailing: View>: View {
  let title: String
  let detail: String
  let trailing: Trailing

  init(
    title: String,
    detail: String,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.detail = detail
    self.trailing = trailing()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 18) {
      SettingsRowCopy(title: title, detail: detail)
      Spacer(minLength: 16)
      trailing
        .frame(minWidth: SettingsDesignTokens.trailingControlWidth, alignment: .trailing)
    }
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity, minHeight: 58)
  }
}

@MainActor
private struct SettingsNavigationRow: View {
  enum StatusTone {
    case automatic
    case error
  }

  let title: String
  let detail: String
  let status: String
  var statusTone: StatusTone = .automatic
  let isEnabled: Bool
  var accessibilityIdentifier: String? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 18) {
        SettingsRowCopy(title: title, detail: detail)
        Spacer(minLength: 16)

        HStack(spacing: 10) {
          if statusTone == .error {
            Circle()
              .fill(SettingsDesignTokens.destructive)
              .frame(width: 7, height: 7)
          } else if status == "Enabled" || status == "在线" || status == "已启用" {
            Circle()
              .fill(SettingsDesignTokens.serviceGreen)
              .frame(width: 7, height: 7)
          }
          Text(status)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(
              statusTone == .error
                ? SettingsDesignTokens.destructive
                : SettingsDesignTokens.textPrimary.opacity(0.82)
            )
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SettingsDesignTokens.textTertiary)
        }
      }
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity, minHeight: 58)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(status)
    .accessibilityHint(detail)
    .accessibilityIdentifier(accessibilityIdentifier ?? "")
  }
}

@MainActor
private struct SettingsReadOnlyRow: View {
  let title: String
  let detail: String
  let value: String

  var body: some View {
    HStack(alignment: .center, spacing: 18) {
      SettingsRowCopy(title: title, detail: detail)
      Spacer(minLength: 16)
      Text(value)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(SettingsDesignTokens.textPrimary.opacity(0.82))
        .multilineTextAlignment(.trailing)
    }
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity, minHeight: 58)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
    .accessibilityHint(detail)
  }
}

@MainActor
private struct SettingsRowCopy: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(SettingsDesignTokens.textPrimary)
      Text(detail)
        .font(VelaTypography.caption)
        .foregroundStyle(SettingsDesignTokens.textSecondary)
        .lineLimit(2)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct SettingsRowDivider: View {
  var body: some View {
    Rectangle()
      .fill(SettingsDesignTokens.separator)
      .frame(height: 1)
      .padding(.leading, 20)
  }
}

private struct SettingsGlassSurfaceModifier: ViewModifier {
  let radius: CGFloat
  let emphasized: Bool

  func body(content: Content) -> some View {
    content.velaWorkspaceGlassSurface(
      radius: radius,
      emphasized: emphasized
    )
  }
}

private struct SettingsSearchSectionHighlightModifier: ViewModifier {
  let isHighlighted: Bool

  func body(content: Content) -> some View {
    content
      .background {
        if isHighlighted {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(SettingsDesignTokens.accent.opacity(0.045))
        }
      }
      .overlay {
        if isHighlighted {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(SettingsDesignTokens.accent.opacity(0.46), lineWidth: 1.5)
        }
      }
  }
}

private struct SettingsGlassButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let radius: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    let label = configuration.label
      .foregroundStyle(SettingsDesignTokens.textPrimary)
      .padding(.horizontal, 12)
      .frame(minHeight: 30)
      .contentShape(.rect)

    Group {
      if #available(macOS 26.0, *), !reduceTransparency {
        label.glassEffect(
          .regular.interactive(),
          in: .rect(cornerRadius: radius)
        )
      } else {
        label
          .background(
            Color.white.opacity(configuration.isPressed ? 0.48 : 0.66),
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
          )
          .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
          )
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .stroke(SettingsDesignTokens.glassStroke, lineWidth: 1)
    }
    .scaleEffect(configuration.isPressed ? 0.98 : 1)
  }
}

private struct SettingsDestructiveButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12.5, weight: .medium))
      .foregroundStyle(Color.red.opacity(configuration.isPressed ? 0.68 : 0.90))
      .padding(.horizontal, 16)
      .frame(minHeight: 30)
      .background(
        Color.white.opacity(configuration.isPressed ? 0.44 : 0.62),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .background(
        .ultraThinMaterial,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.red.opacity(0.62), lineWidth: 1)
      }
  }
}

extension View {
  fileprivate func settingsGlassSurface(
    radius: CGFloat,
    emphasized: Bool = false
  ) -> some View {
    modifier(
      SettingsGlassSurfaceModifier(
        radius: radius,
        emphasized: emphasized
      )
    )
  }

  fileprivate func settingsSearchSectionHighlight(
    _ isHighlighted: Bool
  ) -> some View {
    modifier(SettingsSearchSectionHighlightModifier(isHighlighted: isHighlighted))
  }
}

private enum SettingsDesignTokens {
  static let pagePadding: CGFloat = 28
  static let glassFusionSpacing: CGFloat = 8
  static let trailingControlWidth: CGFloat = 176

  static let accent = Color(red: 27 / 255, green: 178 / 255, blue: 132 / 255)
  static let serviceGreen = Color(red: 57 / 255, green: 201 / 255, blue: 139 / 255)
  static let warning = Color(red: 220 / 255, green: 142 / 255, blue: 32 / 255)
  static let destructive = Color(red: 214 / 255, green: 63 / 255, blue: 69 / 255)
  static let textPrimary = Color.primary
  static let textSecondary = Color.secondary
  static let textTertiary = Color(nsColor: .tertiaryLabelColor)
  static let separator = Color(red: 174 / 255, green: 193 / 255, blue: 209 / 255)
    .opacity(0.66)
  static let selectedSurface = accent.opacity(0.12)
  static let selectedBorder = accent.opacity(0.22)
  static let glassFill = Color.white.opacity(0.08)
  static let emphasizedGlassFill = Color.white.opacity(0.16)
  static let glassTint = Color.white.opacity(0.08)
  static let emphasizedGlassTint = Color.white.opacity(0.16)
  static let groupHeaderSurface = Color.white.opacity(0.18)
  static let glassStroke = Color.white.opacity(0.92)
  static let glassShadow = Color(red: 36 / 255, green: 58 / 255, blue: 78 / 255)
    .opacity(0.075)
  static let emphasizedGlassShadow = Color(
    red: 28 / 255,
    green: 55 / 255,
    blue: 76 / 255
  )
  .opacity(0.12)
}

private struct SettingsOperationMessage: Identifiable {
  let id = UUID()
  let text: String
  let isError: Bool

  static func success(_ text: String) -> Self {
    SettingsOperationMessage(text: text, isError: false)
  }

  static func failure(_ text: String) -> Self {
    SettingsOperationMessage(text: text, isError: true)
  }
}

private enum SettingsConfirmation: String, Identifiable {
  case resetDefaults
  case clearTransientData

  var id: String { rawValue }
}

@MainActor
struct SettingsMainNavigationRequest {
  static let sectionUserInfoKey = "section"
  private static var pendingSection: AppSection?

  static func open(_ section: AppSection) {
    stage(section)
    NotificationCenter.default.post(name: .velaOpenMainWindow, object: nil)
    NotificationCenter.default.post(
      name: .velaOpenMainSection,
      object: nil,
      userInfo: [sectionUserInfoKey: section.rawValue]
    )
    NSApp.activate(ignoringOtherApps: true)
  }

  static func navigateInCurrentWindow(_ section: AppSection) {
    stage(section)
    NotificationCenter.default.post(
      name: .velaOpenMainSection,
      object: nil,
      userInfo: [sectionUserInfoKey: section.rawValue]
    )
    NSApp.activate(ignoringOtherApps: true)
  }

  static func consumePendingSection() -> AppSection? {
    defer { pendingSection = nil }
    return pendingSection
  }

  static func acknowledge(_ section: AppSection) {
    guard pendingSection == section else { return }
    pendingSection = nil
  }

  static func stage(_ section: AppSection) {
    pendingSection = section
  }

  static func section(from notification: Notification) -> AppSection? {
    guard let rawValue = notification.userInfo?[sectionUserInfoKey] as? String else {
      return nil
    }
    return AppSection(rawValue: rawValue)
  }
}

extension Notification.Name {
  static let velaOpenMainSection = Notification.Name("dev.yilin.Vela.openMainSection")
}

private struct SettingsPageCopy {
  let isChinese: Bool

  init(locale: Locale) {
    isChinese = VelaSupportedLocale.resolve(locale) == .simplifiedChinese
  }

  func text(_ english: String, _ chinese: String) -> String {
    isChinese ? chinese : english
  }

  var settings: String { text("Settings", "设置") }
  var pageSubtitle: String { text("Customize Vela to match your workflow", "自定义 Vela 以匹配你的工作流") }
  var searchSettings: String { text("Search settings…", "搜索设置…") }
  var clearSearch: String { text("Clear search", "清除搜索") }
  var resetToDefaults: String { text("Reset to Defaults", "恢复默认设置") }
  var resetConfirmationTitle: String { text("Reset Settings to Defaults?", "将设置恢复为默认值？") }
  var resetConfirmationDetail: String {
    text(
      "Vela will reset interface and storage preferences. Current network routing will not be interrupted.",
      "Vela 将重置界面和存储偏好，不会中断当前网络路由。"
    )
  }
  var defaultsRestored: String { text("Settings were restored to their defaults.", "设置已恢复为默认值。") }
  var operationFailed: String { text("Operation Failed", "操作失败") }
  var settingsUpdated: String { text("Settings Updated", "设置已更新") }
  var ok: String { text("OK", "好") }
  var cancel: String { text("Cancel", "取消") }

  var brandSubtitle: String { text("A native Mihomo\nnetwork proxy client", "原生 Mihomo\n网络代理客户端") }
  var overview: String { text("Overview", "概览") }
  var proxies: String { text("Proxies", "代理节点") }
  var connections: String { text("Connections", "连接") }
  var rules: String { text("Rules", "规则") }
  var configurationWorkbench: String { text("Configuration\nWorkbench", "配置工作台") }
  var serviceRunning: String { text("Service is running", "服务正在运行") }
  var serviceStopped: String { text("Service is stopped", "服务已停止") }

  var general: String { text("General", "通用") }
  var networkAndRouting: String { text("Network & Routing", "网络与路由") }
  var configurationAndData: String { text("Configuration & Data", "配置与数据") }
  var coreAndNetwork: String { text("Core & Network", "内核与网络") }
  var rulesAndRouting: String { text("Rules & Routing", "规则与路由") }
  var profiles: String { text("Profiles", "配置") }
  var uiAndAppearance: String { text("UI & Appearance", "界面与外观") }
  var logsAndDiagnostics: String { text("Logs & Diagnostics", "日志与诊断") }
  var advanced: String { text("Advanced", "高级") }
  var advancedDetail: String {
    text(
      "Destructive and infrequently used maintenance actions.",
      "破坏性操作与不常用的维护选项。"
    )
  }
  var about: String { text("About", "关于") }

  func title(_ category: SettingsPageCategory) -> String {
    switch category {
    case .general: general
    case .coreNetwork, .proxies, .rulesRouting: networkAndRouting
    case .profiles, .advanced: configurationAndData
    case .appearance: uiAndAppearance
    case .diagnostics, .about: text("Diagnostics & About", "诊断与关于")
    }
  }

  func subtitle(_ category: SettingsPageCategory) -> String {
    switch category {
    case .general: text("Basic settings and startup", "基础设置与启动")
    case .coreNetwork, .proxies, .rulesRouting:
      text("Traffic control, core and routing", "流量控制、内核与路由")
    case .profiles, .advanced:
      text("Profiles, storage and maintenance", "配置、存储与维护")
    case .appearance: text("Theme and interface", "主题与界面")
    case .diagnostics, .about:
      text("Troubleshooting, version and updates", "故障排查、版本与更新")
    }
  }

  var startupBehavior: String { text("Startup Behavior", "启动行为") }
  var startupBehaviorDetail: String {
    text("Choose what Vela does when launched.", "选择 Vela 启动时的行为。")
  }
  func startupBehaviorTitle(_ behavior: SettingsStartupBehavior) -> String {
    switch behavior {
    case .overview: text("Open Overview", "打开概览")
    case .lastSection: text("Open Last Section", "打开上次页面")
    case .menuBarOnly: text("Menu Bar Only", "仅菜单栏")
    }
  }
  var launchAtLogin: String { text("Launch at Login", "登录时启动") }
  var launchAtLoginDetail: String {
    text("Start Vela automatically when you log in to macOS.", "登录 macOS 时自动启动 Vela。")
  }
  func launchAtLoginStatusTitle(_ status: LaunchAtLoginStatus) -> String {
    switch status {
    case .enabled: enabled
    case .notRegistered: disabled
    case .requiresApproval: text("Approval Required", "需要批准")
    case .notFound: text("Unavailable", "不可用")
    case .unknown: text("Status Unknown", "状态未知")
    }
  }
  func launchAtLoginFailureTitle(_ failure: LaunchAtLoginFailure) -> String {
    switch failure {
    case .registerFailed: text("Could not enable", "无法启用")
    case .unregisterFailed: text("Could not disable", "无法停用")
    case .statusUnavailable: text("Status unavailable", "状态不可用")
    }
  }
  var minimizeToMenuBar: String { text("Minimize to Menu Bar", "最小化到菜单栏") }
  var minimizeToMenuBarDetail: String {
    text("Close window will minimize Vela to the menu bar.", "关闭窗口时将 Vela 最小化到菜单栏。")
  }
  var language: String { text("Language", "语言") }
  var languageDetail: String { text("Choose the application language.", "选择应用语言。") }
  func languageTitle(_ language: SettingsLanguagePreference) -> String {
    switch language {
    case .system: text("System Default", "跟随系统")
    case .english: "English"
    case .simplifiedChinese: "简体中文"
    }
  }
  var checkForUpdates: String { text("Check for Updates", "检查更新") }
  var checkForUpdatesDetail: String {
    text("Automatically check for updates in the background.", "在后台自动检查更新。")
  }

  var system: String { text("System", "系统") }
  var systemProxy: String { text("System Proxy", "系统代理") }
  var systemProxyDetail: String { text("Control macOS system proxy settings.", "控制 macOS 系统代理设置。") }
  var tunMode: String { text("Tun Mode (TUN)", "Tun 模式 (TUN)") }
  var tunModeDetail: String {
    text("Enable TUN mode for full system routing.", "启用 TUN 模式进行全系统路由。")
  }
  func tunStatusTitle(_ status: SettingsTunStatus) -> String {
    switch status {
    case .transitioning: text("Transitioning", "正在切换")
    case .enabled: enabled
    case .disabled: disabled
    case .setupRequired: text("Setup Required", "需要设置")
    case .failed: text("Failed", "失败")
    }
  }
  var dnsSettings: String { text("DNS Settings", "DNS 设置") }
  var dnsSettingsDetail: String {
    text("Configure DNS handling and hijack strategy.", "配置 DNS 处理与劫持策略。")
  }
  var ipv6: String { text("IPv6", "IPv6") }
  var ipv6Detail: String { text("Enable IPv6 support.", "启用 IPv6 支持。") }
  var enhanced: String { text("Enhanced", "增强") }
  var systemValue: String { text("System", "系统") }
  var enabled: String { text("Enabled", "已启用") }
  var disabled: String { text("Disabled", "已停用") }
  var dataAndStorage: String { text("Data & Storage", "数据与存储") }
  var dataDirectory: String { text("Data Directory", "数据目录") }
  var dataDirectoryDetail: String {
    text("Directory for Vela data, logs and cache.", "Vela 数据、日志与缓存目录。")
  }
  var openDataDirectory: String { text("Open data directory", "打开数据目录") }
  var logRetention: String { text("Log Retention", "日志保留") }
  var logRetentionDetail: String { text("Automatically delete logs older than.", "自动删除超过保留期限的日志。") }
  var cacheSizeLimit: String { text("Cache Size Limit", "缓存大小限制") }
  var cacheSizeLimitDetail: String {
    text("Limit the maximum size of cache files.", "限制缓存文件的最大大小。")
  }
  var clearAllData: String { text("Clear Logs & Cache", "清除日志与缓存") }
  var clearAllDataDetail: String { text("Remove generated cache and log files.", "移除生成的缓存与日志文件。") }
  var clearData: String { text("Clear…", "清除…") }
  var clearConfirmationTitle: String { text("Clear Logs and Cache?", "清除日志与缓存？") }
  var clearConfirmationDetail: String {
    text(
      "Profiles and active configurations are preserved. This action cannot be undone.",
      "配置与当前生效配置会保留。此操作无法撤销。"
    )
  }
  var clearSucceeded: String { text("Logs and cache were cleared.", "日志和缓存已清除。") }
  func clearFailed(_ detail: String) -> String {
    text("Data could not be cleared: ", "无法清除数据：") + detail
  }
  func days(_ days: Int) -> String { text("\(days) Days", "\(days) 天") }
  func megabytes(_ value: Int) -> String {
    value >= 1_000 ? "\(value / 1_000) GB" : "\(value) MB"
  }

  var backupAndRestore: String { text("Backup & Restore", "备份与恢复") }
  var exportSettings: String { text("Export Settings", "导出设置") }
  var exportSettingsDetail: String {
    text("Export settings and safe configuration preferences to a file.", "将设置和安全配置偏好导出到文件。")
  }
  var importSettings: String { text("Import Settings", "导入设置") }
  var importSettingsDetail: String {
    text(
      "Validate and import a portable Vela Settings backup as one transaction.",
      "校验并以单个事务导入可移植的 Vela 设置备份。"
    )
  }
  var exportAction: String { text("Export…", "导出…") }
  var importAction: String { text("Import…", "导入…") }
  var exportSucceeded: String { text("Settings were exported successfully.", "设置已成功导出。") }
  var importSucceeded: String { text("Settings were imported successfully.", "设置已成功导入。") }
  func exportFailed(_ detail: String) -> String {
    text("Settings could not be exported: ", "无法导出设置：") + detail
  }
  func importFailed(_ detail: String) -> String {
    text("Settings could not be imported: ", "无法导入设置：") + detail
  }

  var mihomoCore: String { text("Mihomo Core", "Mihomo 内核") }
  var mihomoCoreDetail: String { text("Runtime core used by Vela.", "Vela 使用的运行时内核。") }
  var proxyCoreDetail: String { text("Core used for proxy connections.", "代理连接所使用的内核。") }
  var ruleMode: String { text("Rule Mode", "规则模式") }
  var ruleModeDetail: String { text("Current Mihomo routing mode.", "当前 Mihomo 路由模式。") }
  var serviceStatus: String { text("Service Status", "服务状态") }
  var serviceStatusDetail: String {
    text("Current Mihomo runtime availability.", "当前 Mihomo 运行时可用性。")
  }
  var profileDirectoryDetail: String {
    text("Reveal profile and configuration storage.", "显示配置与文件存储位置。")
  }
  var configurationBackup: String { text("Configuration Backup", "配置备份") }
  var configurationBackupDetail: String { text("Portable safe settings document.", "可移植的安全设置文档。") }
  var available: String { text("Available", "可用") }
  var open: String { text("Open", "打开") }
  var openDiagnostics: String { text("Open Diagnostics", "打开诊断") }
  var openDiagnosticsDetail: String {
    text(
      "Run health checks and review troubleshooting evidence.",
      "运行健康检查并查看故障排查证据。"
    )
  }
  var diagnosticsDirectoryDetail: String {
    text("Reveal logs and local diagnostic data.", "显示日志与本地诊断数据。")
  }
  var lastUpdateCheck: String { text("Last Update Check", "上次更新检查") }
  var lastUpdateCheckDetail: String {
    text("Last completed Sparkle update check.", "上次完成的 Sparkle 更新检查。")
  }
  var version: String { text("Version", "版本") }
  var versionDetail: String { text("Installed Vela application version.", "已安装的 Vela 应用版本。") }
  var updateChannel: String { text("Update Channel", "更新通道") }
  var updateChannelDetail: String {
    text("Signed release channel used by Sparkle.", "Sparkle 使用的签名发布通道。")
  }
}
