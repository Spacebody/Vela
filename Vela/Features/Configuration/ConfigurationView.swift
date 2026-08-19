import AppKit
import SwiftUI

struct ConfigurationView: View {
#if DEBUG
    @Environment(\.visualUITestConfiguration) private var visualTestConfiguration
#endif
    let viewModel: ConfigurationEditorViewModel
    let remoteProfiles: RemoteProfilesViewModel
    let selectedProfileID: UUID?
    let profiles: [Profile]
    let onSelectProfile: (UUID) -> Void
    let onAddConfiguration: () -> Void
    let onAddRemoteSubscription: () -> Void
    let onRefreshConfigurations: () async -> Void
    let onUpdateConfiguration: (UUID) async -> Void
    let onDeleteConfiguration: (UUID) async -> Void
    let onOpenConfigurationPage: () -> Void
    @State private var workspaceMode: ConfigurationWorkbenchMode = .editor
    @State private var isInspectorPresented = false
    @State private var isInspectorPreferred = true
    @State private var availableContentWidth: CGFloat = 0
    @State private var exportErrorMessage: String?
    @State private var profilePendingEdit: Profile?
    @State private var yamlAnalysis: ConfigurationWorkbenchSnapshot.YAMLAnalysis?
    @State private var previewRefreshTask: Task<Void, Never>?
    @State private var previewRefreshGeneration: UInt64 = 0

    var body: some View {
        @Bindable var model = viewModel
        GeometryReader { geometry in
            let status = ConfigurationWorkbenchPresentationPolicy.status(
                hasProfile: selectedProfileID != nil,
                hasChanges: model.hasChanges,
                isLoading: model.isLoading,
                isSaving: model.isSaving,
                preview: model.preview,
                errorMessage: model.errorMessage
            )
            let snapshot = ConfigurationWorkbenchSnapshot.resolve(
                profiles: profiles,
                selectedProfileID: selectedProfileID,
                preview: model.preview,
                status: status,
                isLoading: model.isLoading || model.isSaving,
                errorMessage: model.errorMessage,
                hasChanges: model.hasChanges,
                canApply: model.canSave,
                yamlAnalysis: ConfigurationWorkbenchYAMLAnalysisCache.shared.cachedAnalysis(
                    for: model.preview?.finalYAML ?? model.preview?.rawYAML
                ) ?? yamlAnalysis
            )

            ConfigurationLiquidGlassWorkbenchView(
                snapshot: snapshot,
                overrides: selectedProfileID == nil ? nil : $model.draft,
                mode: $workspaceMode,
                prefersInspector: isInspectorPresented,
                identifierNamespace: "configuration",
                action: handleWorkbenchAction
            )
            .onAppear {
                reconcileInspector(for: geometry.size.width)
            }
            .onChange(of: geometry.size.width) { _, width in
                reconcileInspector(for: width)
            }
        }
        .velaPageRoot()
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = remoteProfiles.lastError {
                VelaStateBanner(
                    kind: .error,
                    title: error.title,
                    detail: [error.message, error.suggestedAction]
                        .compactMap { $0 }
                        .joined(separator: " "),
                    dismissalID: error.id.uuidString,
                    onDismiss: { remoteProfiles.dismissError() }
                )
                .padding(.horizontal, VelaSpacing.medium)
                .padding(.top, VelaSpacing.small)
                .accessibilityIdentifier("configuration.subscription.error.banner")
            }
        }
        .navigationTitle(
            VelaL10n.string(
                "configuration.workbench.title",
                defaultValue: "Configuration Workbench"
            )
        )
        .task(id: selectedProfileID) {
            cancelScheduledPreviewRefresh()
            await viewModel.selectProfile(selectedProfileID)
            await refreshYAMLAnalysis()
        }
        .onChange(of: model.draft) { _, _ in
            schedulePreviewRefresh()
        }
        .onDisappear {
            cancelScheduledPreviewRefresh()
        }
        .alert(
            VelaL10n.string(
                "configuration.export.error.title",
                defaultValue: "Export Failed"
            ),
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        exportErrorMessage = nil
                    }
                }
            )
        ) {
            Button(VelaL10n.string("legacy.ok", defaultValue: "OK")) {
                exportErrorMessage = nil
            }
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .sheet(item: $profilePendingEdit) { profile in
            if profile.sourceKind == .remoteSubscription {
                RemoteConfigurationEditorSheet(
                    profile: profile,
                    viewModel: viewModel,
                    remoteProfiles: remoteProfiles
                ) { finishProfileEdit($0) }
            } else {
                RawConfigurationEditorSheet(
                    profile: profile,
                    viewModel: viewModel
                ) { finishProfileEdit($0) }
            }
        }
    }

    @MainActor
    private func finishProfileEdit(_ editedProfileID: UUID) {
        profilePendingEdit = nil
        Task {
            await onRefreshConfigurations()
            await reloadEditorIfNeeded(editedProfileID)
        }
    }

    @MainActor
    private func handleWorkbenchAction(_ action: ConfigurationWorkbenchAction) {
        switch action {
        case let .selectProfile(id):
            onSelectProfile(id)
        case let .editProfile(id):
            guard let profile = profiles.first(where: { $0.id == id }) else { return }
            Task { @MainActor in
                // A Menu action runs before AppKit has finished dismissing its
                // transient menu window. Presenting a sheet in that same update
                // can be dropped on macOS, so wait for the dismissal cycle.
                await Task.yield()
                profilePendingEdit = profile
            }
        case .refreshProfiles:
            Task {
                await onRefreshConfigurations()
                await reloadEditorIfNeeded(selectedProfileID)
            }
        case let .updateProfile(id):
            Task {
                await onUpdateConfiguration(id)
                await reloadEditorIfNeeded(id)
            }
        case let .deleteProfile(id):
            Task {
                await onDeleteConfiguration(id)
            }
        case .validate:
            cancelScheduledPreviewRefresh()
            Task {
                try? await viewModel.updatePreview()
                await refreshYAMLAnalysis()
            }
        case .apply:
            cancelScheduledPreviewRefresh()
            Task {
                await viewModel.save()
                await refreshYAMLAnalysis()
            }
        case .revert:
            cancelScheduledPreviewRefresh()
            Task {
                await viewModel.discardChanges()
                await refreshYAMLAnalysis()
            }
        case .addRemoteSubscription:
            onAddRemoteSubscription()
        case .importConfiguration:
            onAddConfiguration()
        case .exportConfiguration:
            Task { await exportCurrentConfiguration() }
        case .openConfigurationFolder:
            openConfigurationFolder()
        case .viewChangeHistory:
            workspaceMode = .diff
        case .toggleInspector:
            toggleInspector()
        }
    }

    @MainActor
    private func reloadEditorIfNeeded(_ profileID: UUID?) async {
        guard let profileID, viewModel.profileID == profileID else { return }
        try? await viewModel.updatePreview()
        await refreshYAMLAnalysis()
    }

    @MainActor
    private func refreshYAMLAnalysis() async {
        guard let yaml = viewModel.preview?.finalYAML ?? viewModel.preview?.rawYAML else {
            yamlAnalysis = nil
            return
        }
        let analysis = await ConfigurationWorkbenchYAMLAnalysisCache.shared.analysis(for: yaml)
        guard !Task.isCancelled else { return }
        let currentYAML = viewModel.preview?.finalYAML ?? viewModel.preview?.rawYAML
        guard currentYAML == yaml else { return }
        yamlAnalysis = analysis
    }

    @MainActor
    private func schedulePreviewRefresh() {
        guard !viewModel.isLoading, !viewModel.isSaving else { return }
        previewRefreshGeneration &+= 1
        let generation = previewRefreshGeneration
        previewRefreshTask?.cancel()
        previewRefreshTask = Task { @MainActor in
            defer {
                if previewRefreshGeneration == generation {
                    previewRefreshTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                guard !viewModel.isLoading, !viewModel.isSaving else { return }
                try await viewModel.updatePreview()
                try Task.checkCancellation()
                await refreshYAMLAnalysis()
            } catch {
                // A newer draft, profile, save, or page transition superseded this preview.
            }
        }
    }

    @MainActor
    private func cancelScheduledPreviewRefresh() {
        previewRefreshGeneration &+= 1
        previewRefreshTask?.cancel()
        previewRefreshTask = nil
    }

    @MainActor
    private func exportCurrentConfiguration() async {
        let yaml: String
        do {
            yaml = try await viewModel.runnableYAMLForExport()
        } catch {
            exportErrorMessage = VelaL10n.string(
                "configuration.export.error.prepare",
                defaultValue: "Vela could not prepare a runnable configuration for export."
            )
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = profiles
            .first(where: { $0.id == selectedProfileID })
            .map { "\($0.name.replacingOccurrences(of: " ", with: "-").lowercased()).yaml" }
            ?? "config.yaml"
        panel.title = VelaL10n.string(
            "configuration.export.title",
            defaultValue: "Export Configuration"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await ConfigurationExportWriter.shared.write(yaml, to: url)
        } catch {
            exportErrorMessage = VelaL10n.string(
                "configuration.export.error.write",
                defaultValue: "Vela could not write the configuration to the selected location."
            )
        }
    }

    @MainActor
    private func openConfigurationFolder() {
        do {
            let profilesDirectory = try ApplicationDirectories.live().profiles
            guard FileManager.default.fileExists(atPath: profilesDirectory.path),
                  NSWorkspace.shared.open(profilesDirectory)
            else {
                onOpenConfigurationPage()
                return
            }
        } catch {
            onOpenConfigurationPage()
        }
    }

    private func reconcileInspector(for contentWidth: CGFloat) {
        availableContentWidth = contentWidth
        guard selectedProfileID != nil else {
            isInspectorPresented = false
            return
        }
#if DEBUG
        if visualTestConfiguration?.page == .workbench {
            isInspectorPreferred = visualTestConfiguration?.inspector == .open
        }
#endif
        isInspectorPresented = ConfigurationWorkbenchLayoutPolicy.inspectorPresentation(
            isPreferred: isInspectorPreferred,
            contentWidth: contentWidth
        ) == .presented
    }

    private func toggleInspector() {
        guard ConfigurationWorkbenchLayoutPolicy.canPresentInspector(
            contentWidth: availableContentWidth
        ) else { return }
        isInspectorPreferred = !isInspectorPresented
        isInspectorPresented = isInspectorPreferred
    }
}

private struct RemoteConfigurationEditorSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let profile: Profile
    let viewModel: ConfigurationEditorViewModel
    let remoteProfiles: RemoteProfilesViewModel
    let saved: (UUID) -> Void

    @State private var section: Section = .configuration
    @State private var cachedSubscriptionSettings: RemoteProfileEditableSettings?

    var body: some View {
        ZStack {
            VelaPageCanvas()

            VStack(spacing: 0) {
                Picker("", selection: $section) {
                    ForEach(Section.allCases) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .padding(.horizontal, VelaSpacing.standard)
                .padding(.vertical, VelaSpacing.medium)
                .accessibilityIdentifier("configuration.remoteEditor.section")

                Divider()

                switch section {
                case .configuration:
                    RawConfigurationEditorSheet(
                        profile: profile,
                        viewModel: viewModel,
                        reloadRemote: {
                            await remoteProfiles.update(profile.id)
                        },
                        embedded: true,
                        saved: saved
                    )
                case .subscription:
                    EditRemoteProfileSheet(
                        profile: profile,
                        remoteProfiles: remoteProfiles,
                        cachedSettings: $cachedSubscriptionSettings,
                        embedded: true
                    ) { edited in
                        saved(edited.id)
                    }
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 680)
        .frame(minHeight: 500, idealHeight: 620, maxHeight: 650)
        .animation(
            VelaMotion.animation(reduceMotion: reduceMotion),
            value: section
        )
        .clipped()
        .accessibilityIdentifier("configuration.remoteEditor")
        .onDisappear {
            cachedSubscriptionSettings = nil
        }
    }

    private enum Section: String, CaseIterable, Identifiable {
        case subscription
        case configuration

        var id: Self { self }

        var title: String {
            switch self {
            case .configuration:
                VelaL10n.string(
                    "configuration.remoteEditor.content",
                    defaultValue: "Configuration Content"
                )
            case .subscription:
                VelaL10n.string(
                    "configuration.remoteEditor.subscription",
                    defaultValue: "Subscription Settings"
                )
            }
        }

        var systemImage: String {
            switch self {
            case .configuration: "doc.text"
            case .subscription: "link"
            }
        }
    }
}

private struct RawConfigurationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let profile: Profile
    let viewModel: ConfigurationEditorViewModel
    let reloadRemote: (() async -> Void)?
    let embedded: Bool
    let saved: (UUID) -> Void

    @State private var yaml = ""
    @State private var originalYAML = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isReloadingRemote = false
    @State private var isMissingRemoteContent = false
    @State private var errorMessage: String?

    init(
        profile: Profile,
        viewModel: ConfigurationEditorViewModel,
        reloadRemote: (() async -> Void)? = nil,
        embedded: Bool = false,
        saved: @escaping (UUID) -> Void
    ) {
        self.profile = profile
        self.viewModel = viewModel
        self.reloadRemote = reloadRemote
        self.embedded = embedded
        self.saved = saved
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.title)
                        .font(.system(size: 18, weight: .semibold))
                    Text(profile.originalFileName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            Group {
                if isLoading {
                    ProgressView(strings.loading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        VelaCodeEditor(
                            text: $yaml,
                            accessibilityLabel: strings.title
                        )
                        .frame(minHeight: 240, maxHeight: .infinity)
                        .padding(1)
                        .background(
                            Color(nsColor: .textBackgroundColor).opacity(0.72),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.72), lineWidth: 1)
                        }
                        .layoutPriority(1)

                        if profile.sourceKind == .remoteSubscription {
                            Label(strings.remoteOverwriteWarning, systemImage: "arrow.clockwise.circle")
                                .font(VelaTypography.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(18)
                }
            }

            if let errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    if isMissingRemoteContent, reloadRemote != nil {
                        Button(strings.downloadLatest) {
                            reloadRemoteContent()
                        }
                        .disabled(isReloadingRemote)
                        .accessibilityIdentifier("configuration.rawEditor.downloadRemote")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }

            Divider()

            HStack {
                Text(strings.validationHint)
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(strings.cancel, role: .cancel) {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                Button(strings.save) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(18)
        }
        .frame(
            width: embedded ? nil : 760,
            height: embedded ? nil : 640
        )
        .background {
            if !embedded {
                VelaPageCanvas()
            }
        }
        .clipped()
        .accessibilityIdentifier("configuration.rawEditor")
        .task(id: profile.id) {
            await load()
        }
    }

    private var strings: RawConfigurationEditorStrings {
        RawConfigurationEditorStrings(locale: locale, profileName: profile.name)
    }

    private var canSave: Bool {
        !isLoading
            && !isSaving
            && yaml != originalYAML
            && !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func load() async {
        isLoading = true
        isMissingRemoteContent = false
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loadedYAML = try await viewModel.rawYAMLForEditing(profileID: profile.id)
            yaml = loadedYAML
            originalYAML = loadedYAML
        } catch ConfigurationOverrideStoreError.profileNotFound
            where profile.sourceKind == .remoteSubscription
        {
            yaml = ""
            originalYAML = ""
            isMissingRemoteContent = true
            errorMessage = strings.remoteContentMissing
        } catch {
            errorMessage = strings.loadFailed
        }
    }

    @MainActor
    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await viewModel.saveRawYAML(
                    yaml,
                    profileID: profile.id,
                    sourceFileName: profile.originalFileName
                )
                originalYAML = yaml
                saved(profile.id)
            } catch let ConfigurationOverrideStoreError.runtimeValidationFailed(result) {
                errorMessage = result.issues.first?.message
                    ?? nonEmpty(result.copyableError)
                    ?? strings.validationFailed
            } catch {
                errorMessage = strings.saveFailed
            }
        }
    }

    @MainActor
    private func reloadRemoteContent() {
        guard let reloadRemote, !isReloadingRemote else { return }
        isReloadingRemote = true
        Task {
            await reloadRemote()
            isReloadingRemote = false
            await load()
        }
    }

    private func nonEmpty(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}

private struct RawConfigurationEditorStrings {
    private let isChinese: Bool
    private let profileName: String

    init(locale: Locale, profileName: String) {
        isChinese = locale.language.languageCode?.identifier == "zh"
        self.profileName = profileName
    }

    private func copy(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }

    var title: String {
        copy("Edit \(profileName)", "编辑 \(profileName)")
    }
    var loading: String { copy("Loading configuration…", "正在载入配置…") }
    var validationHint: String {
        copy(
            "Vela validates the YAML before saving and applying it.",
            "Vela 会先验证 YAML，再保存并应用。"
        )
    }
    var cancel: String { copy("Cancel", "取消") }
    var save: String { copy("Save", "保存") }
    var loadFailed: String {
        copy("The configuration file could not be loaded.", "无法载入配置文件。")
    }
    var validationFailed: String {
        copy("Mihomo rejected this configuration.", "Mihomo 未通过此配置的验证。")
    }
    var remoteOverwriteWarning: String {
        copy(
            "Direct edits change the current snapshot. A future subscription update can replace them; use overrides for changes that must persist.",
            "直接编辑会修改当前快照；后续订阅更新可能覆盖这些内容。需要长期保留的改动请使用覆盖编辑器。"
        )
    }
    var remoteContentMissing: String {
        copy(
            "No downloaded subscription content is available. Download it now or paste a complete Mihomo YAML configuration.",
            "当前没有已下载的订阅内容。你可以立即下载，或粘贴一份完整的 Mihomo YAML 配置。"
        )
    }
    var downloadLatest: String {
        copy("Download Latest", "下载最新订阅")
    }
    var saveFailed: String {
        copy("The configuration file could not be saved.", "无法保存配置文件。")
    }
}

nonisolated enum ConfigurationWorkbenchInspectorPresentation: Equatable, Sendable {
    case presented
    case collapsedForSpace
    case hiddenByUser
}

nonisolated enum ConfigurationWorkbenchLayoutPolicy {
    static var minimumPrimaryContentWidth: CGFloat {
        ConfigurationWorkbenchLayoutMetrics.primaryMinimumWidth
    }

    static var minimumThreeColumnContentWidth: CGFloat {
        ConfigurationWorkbenchLayoutMetrics.threePaneMinimumWidth
    }

    static func availableContentWidth(
        windowWidth: CGFloat,
        outerSidebarWidth: CGFloat,
        shellDividerAllowance: CGFloat = 1
    ) -> CGFloat {
        windowWidth - outerSidebarWidth - shellDividerAllowance
    }

    static func canPresentInspector(contentWidth: CGFloat) -> Bool {
        ConfigurationWorkbenchLayoutMetrics.inspectorFits(contentWidth: contentWidth)
    }

    static func inspectorPresentation(
        isPreferred: Bool,
        contentWidth: CGFloat
    ) -> ConfigurationWorkbenchInspectorPresentation {
        guard isPreferred else { return .hiddenByUser }
        return canPresentInspector(contentWidth: contentWidth)
            ? .presented
            : .collapsedForSpace
    }
}

private enum ConfigurationSection: String, CaseIterable, Identifiable {
    case dns
    case sniffer

    var id: Self { self }
    var title: String {
        switch self {
        case .dns:
            VelaL10n.string("configuration.section.dns", defaultValue: "DNS")
        case .sniffer:
            VelaL10n.string("configuration.section.sniffer", defaultValue: "Sniffer")
        }
    }
}

struct ConfigurationStructuredOverridesEditor: View {
    @Binding var draft: ProfileStructuredOverrides
    @State private var section: ConfigurationSection = .dns

    var body: some View {
        Form {
            Section {
                Picker(
                    VelaL10n.string(
                        "configuration.structuredEditor.section",
                        defaultValue: "Override Section"
                    ),
                    selection: $section
                ) {
                    ForEach(ConfigurationSection.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if section == .dns {
                DNSOverrideEditor(draft: $draft)
            } else {
                SnifferOverrideEditor(draft: $draft)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, VelaSpacing.large, for: .scrollContent)
        .accessibilityIdentifier("configuration.structuredOverrides")
    }
}

private enum BoolOverrideChoice: String, CaseIterable, Identifiable {
    case inherit
    case enabled
    case disabled
    case remove

    var id: Self { self }
    var title: String {
        switch self {
        case .inherit:
            VelaL10n.string("configuration.override.inherit", defaultValue: "Inherit")
        case .enabled:
            VelaL10n.string("configuration.override.on", defaultValue: "On")
        case .disabled:
            VelaL10n.string("configuration.override.off", defaultValue: "Off")
        case .remove:
            VelaL10n.string("configuration.override.remove", defaultValue: "Remove")
        }
    }

    init(_ value: OverrideValue<Bool>) {
        self = switch value {
        case .inherit: .inherit
        case .set(true): .enabled
        case .set(false): .disabled
        case .remove: .remove
        }
    }

    var overrideValue: OverrideValue<Bool> {
        switch self {
        case .inherit: .inherit
        case .enabled: .set(true)
        case .disabled: .set(false)
        case .remove: .remove
        }
    }
}

private struct DNSOverrideEditor: View {
    @Environment(\.locale) private var locale
    @Binding var draft: ProfileStructuredOverrides

    private var copy: ConfigurationOverrideCopy {
        ConfigurationOverrideCopy(locale: locale)
    }

    var body: some View {
        Section(VelaL10n.string("legacy.dns", defaultValue: "DNS")) {
            boolOverride(copy.text("Enable DNS", "启用 DNS"), value: $draft.dns.enable)
            boolOverride("IPv6", value: $draft.dns.ipv6)
            enumOverride(
                copy.text("Enhanced Mode", "增强模式"),
                value: $draft.dns.enhancedMode,
                defaultValue: .fakeIP,
                values: DNSEnhancedMode.allCases,
                label: { $0.rawValue }
            )
            stringOverride(
                copy.text("Fake IP Range", "Fake IP 范围"),
                value: $draft.dns.fakeIPRange,
                defaultValue: "198.18.0.1/16",
                prompt: "198.18.0.1/16"
            )
            enumOverride(
                copy.text("Fake IP Filter Mode", "Fake IP 过滤模式"),
                value: $draft.dns.fakeIPFilterMode,
                defaultValue: .blacklist,
                values: DNSFakeIPFilterMode.allCases,
                label: { $0.rawValue }
            )
            stringListOverride(
                copy.text("Fake IP Filter", "Fake IP 过滤器"),
                value: $draft.dns.fakeIPFilter,
                prompt: copy.text("One domain pattern per line", "每行一个域名匹配项")
            )
            boolOverride(copy.text("Use Hosts", "使用 Hosts"), value: $draft.dns.useHosts)
            boolOverride(
                copy.text("Use System Hosts", "使用系统 Hosts"),
                value: $draft.dns.useSystemHosts
            )
            boolOverride(copy.text("Respect Rules", "遵循规则"), value: $draft.dns.respectRules)
            stringListOverride(
                copy.text("Default Nameserver", "默认 DNS 服务器"),
                value: $draft.dns.defaultNameserver,
                prompt: copy.text("One server per line", "每行一个服务器地址")
            )
            stringListOverride(
                copy.text("Nameserver", "DNS 服务器"),
                value: $draft.dns.nameserver,
                prompt: copy.text("One server per line", "每行一个服务器地址")
            )
            stringListOverride(
                copy.text("Fallback", "备用 DNS"),
                value: $draft.dns.fallback,
                prompt: copy.text("One server per line", "每行一个服务器地址")
            )
            stringListOverride(
                copy.text("Proxy Server Nameserver", "代理服务器 DNS"),
                value: $draft.dns.proxyServerNameserver,
                prompt: copy.text("One server per line", "每行一个服务器地址")
            )
            stringListOverride(
                copy.text("Direct Nameserver", "直连 DNS"),
                value: $draft.dns.directNameserver,
                prompt: copy.text("One server per line", "每行一个服务器地址")
            )
            boolOverride(
                copy.text("Direct Nameserver Follows Policy", "直连 DNS 遵循策略"),
                value: $draft.dns.directNameserverFollowPolicy
            )
            nameserverPolicyOverride(
                copy.text("Nameserver Policy", "DNS 服务器策略"),
                value: $draft.dns.nameserverPolicy
            )
        }
        Section {
            Text(VelaL10n.string("legacy.eachFieldCanInheritTheProfileValueOverrideItOrRemoveTheYamlKeyListsUseOneItemPerLineNameserverPolicyUsesPatternServer1Server2UnknownFieldsRemainUntouched", defaultValue: "Each field can inherit the profile value, override it, or remove the YAML key. Lists use one item per line; nameserver policy uses `pattern = server1, server2`. Unknown fields remain untouched."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SnifferOverrideEditor: View {
    @Environment(\.locale) private var locale
    @Binding var draft: ProfileStructuredOverrides

    private var copy: ConfigurationOverrideCopy {
        ConfigurationOverrideCopy(locale: locale)
    }

    var body: some View {
        Section(VelaL10n.string("legacy.sniffer", defaultValue: "Sniffer")) {
            boolOverride(copy.text("Enable Sniffer", "启用嗅探"), value: $draft.sniffer.enable)
            boolOverride(
                copy.text("Force DNS Mapping", "强制 DNS 映射"),
                value: $draft.sniffer.forceDNSMapping
            )
            boolOverride(copy.text("Parse Pure IP", "解析纯 IP"), value: $draft.sniffer.parsePureIP)
            boolOverride(
                copy.text("Override Destination", "覆盖目标地址"),
                value: $draft.sniffer.overrideDestination
            )
            stringListOverride(
                copy.text("Force Domain", "强制域名"),
                value: $draft.sniffer.forceDomain,
                prompt: copy.text("One domain pattern per line", "每行一个域名匹配项")
            )
            stringListOverride(
                copy.text("Skip Domain", "跳过域名"),
                value: $draft.sniffer.skipDomain,
                prompt: copy.text("One domain pattern per line", "每行一个域名匹配项")
            )
            stringListOverride(
                copy.text("Skip Source Address", "跳过源地址"),
                value: $draft.sniffer.skipSourceAddress,
                prompt: copy.text(
                    "One IPv4 or IPv6 CIDR per line",
                    "每行一个 IPv4 或 IPv6 CIDR"
                )
            )
            stringListOverride(
                copy.text("Skip Destination Address", "跳过目标地址"),
                value: $draft.sniffer.skipDestinationAddress,
                prompt: copy.text(
                    "One IPv4 or IPv6 CIDR per line",
                    "每行一个 IPv4 或 IPv6 CIDR"
                )
            )
        }

        Section(VelaL10n.string("legacy.httpSniffing", defaultValue: "HTTP Sniffing")) {
            PortListOverrideEditor(
                title: copy.text("Ports", "端口"),
                value: $draft.sniffer.sniff.http.ports
            )
            boolOverride(
                copy.text("Override Destination", "覆盖目标地址"),
                value: $draft.sniffer.sniff.http.overrideDestination
            )
        }

        Section(VelaL10n.string("legacy.tlsSniffing", defaultValue: "TLS Sniffing")) {
            PortListOverrideEditor(
                title: copy.text("Ports", "端口"),
                value: $draft.sniffer.sniff.tls.ports
            )
            boolOverride(
                copy.text("Override Destination", "覆盖目标地址"),
                value: $draft.sniffer.sniff.tls.overrideDestination
            )
        }

        Section(VelaL10n.string("legacy.quicSniffing", defaultValue: "QUIC Sniffing")) {
            PortListOverrideEditor(
                title: copy.text("Ports", "端口"),
                value: $draft.sniffer.sniff.quic.ports
            )
            boolOverride(
                copy.text("Override Destination", "覆盖目标地址"),
                value: $draft.sniffer.sniff.quic.overrideDestination
            )
        }
        Section {
            Text(VelaL10n.string("legacy.portsAcceptOneValueOrAscendingRangePerLineSuchAs80Or4438443DomainAndCidrListsAreValidatedBeforeSave", defaultValue: "Ports accept one value or ascending range per line, such as `80` or `443-8443`. Domain and CIDR lists are validated before Save."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ConfigurationOverrideCopy {
    let isChinese: Bool

    init(locale: Locale) {
        isChinese = VelaSupportedLocale.resolve(locale) == .simplifiedChinese
    }

    func text(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }
}

@ViewBuilder
private func boolOverride(
    _ title: String,
    value: Binding<OverrideValue<Bool>>
) -> some View {
    LabeledContent(title) {
        Picker(title, selection: Binding(
            get: { BoolOverrideChoice(value.wrappedValue) },
            set: { value.wrappedValue = $0.overrideValue }
        )) {
            ForEach(BoolOverrideChoice.allCases) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .labelsHidden()
        .frame(
            minWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMinimumWidth,
            idealWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlIdealWidth,
            maxWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMaximumWidth
        )
    }
}

private enum OverrideModeChoice: String, CaseIterable, Identifiable {
    case inherit
    case set
    case remove

    var id: Self { self }
    var title: String {
        switch self {
        case .inherit:
            VelaL10n.string("configuration.override.inherit", defaultValue: "Inherit")
        case .set:
            VelaL10n.string("configuration.override.set", defaultValue: "Override")
        case .remove:
            VelaL10n.string("configuration.override.remove", defaultValue: "Remove")
        }
    }
}

@ViewBuilder
private func enumOverride<Value: Codable & Equatable & Sendable & Hashable>(
    _ title: String,
    value: Binding<OverrideValue<Value>>,
    defaultValue: Value,
    values: [Value],
    label: @escaping (Value) -> String
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        LabeledContent(title) {
            Picker(VelaL10n.string("legacy.modeObjectFormat", defaultValue: "%@ Mode", arguments: title), selection: overrideMode(value, defaultValue: defaultValue)) {
                ForEach(OverrideModeChoice.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .frame(
                minWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMinimumWidth,
                idealWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlIdealWidth,
                maxWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMaximumWidth
            )
        }
        if case .set = value.wrappedValue {
            Picker(title, selection: setValue(value, defaultValue: defaultValue)) {
                ForEach(values, id: \.self) { item in
                    Text(label(item)).tag(item)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

@ViewBuilder
private func stringOverride(
    _ title: String,
    value: Binding<OverrideValue<String>>,
    defaultValue: String,
    prompt: String
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        LabeledContent(title) {
            Picker(VelaL10n.string("legacy.modeObjectFormat", defaultValue: "%@ Mode", arguments: title), selection: overrideMode(value, defaultValue: defaultValue)) {
                ForEach(OverrideModeChoice.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .frame(
                minWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMinimumWidth,
                idealWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlIdealWidth,
                maxWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMaximumWidth
            )
        }
        if case .set = value.wrappedValue {
            TextField(prompt, text: setValue(value, defaultValue: defaultValue))
                .textFieldStyle(.roundedBorder)
        }
    }
}

@ViewBuilder
private func stringListOverride(
    _ title: String,
    value: Binding<OverrideValue<[String]>>,
    prompt: String
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        LabeledContent(title) {
            Picker(VelaL10n.string("legacy.modeObjectFormat", defaultValue: "%@ Mode", arguments: title), selection: overrideMode(value, defaultValue: [])) {
                ForEach(OverrideModeChoice.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .frame(
                minWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMinimumWidth,
                idealWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlIdealWidth,
                maxWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMaximumWidth
            )
        }
        if case .set = value.wrappedValue {
            TextEditor(text: stringListText(value))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 62, maxHeight: 100)
                .overlay(alignment: .topLeading) {
                    if listValue(value).isEmpty {
                        Text(prompt)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

@ViewBuilder
private func nameserverPolicyOverride(
    _ title: String,
    value: Binding<OverrideValue<[NameserverPolicyEntry]>>
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        LabeledContent(title) {
            Picker(VelaL10n.string("legacy.modeObjectFormat", defaultValue: "%@ Mode", arguments: title), selection: overrideMode(value, defaultValue: [])) {
                ForEach(OverrideModeChoice.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .frame(
                minWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMinimumWidth,
                idealWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlIdealWidth,
                maxWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMaximumWidth
            )
        }
        if case .set = value.wrappedValue {
            TextEditor(text: nameserverPolicyText(value))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 72, maxHeight: 120)
        }
    }
}

private struct PortListOverrideEditor: View {
    let title: String
    @Binding var value: OverrideValue<[SnifferPort]>
    @State private var draftText = ""
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                Picker(
                    VelaL10n.string("legacy.modeObjectFormat", defaultValue: "%@ Mode", arguments: title),
                    selection: overrideMode($value, defaultValue: [])
                ) {
                    ForEach(OverrideModeChoice.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(
                    minWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMinimumWidth,
                    idealWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlIdealWidth,
                    maxWidth: ConfigurationWorkbenchLayoutMetrics.overrideControlMaximumWidth
                )
            }
            if case .set = value {
                TextEditor(text: $draftText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 58, maxHeight: 90)
                    .onChange(of: draftText) { _, text in
                        apply(text)
                    }
                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { synchronizeText() }
        .onChange(of: value) { _, _ in synchronizeTextIfNeeded() }
    }

    private func synchronizeText() {
        guard case let .set(ports) = value else {
            draftText = ""
            validationError = nil
            return
        }
        draftText = ports.map(\.canonicalText).joined(separator: "\n")
    }

    private func synchronizeTextIfNeeded() {
        guard case let .set(ports) = value else {
            if !draftText.isEmpty { draftText = "" }
            validationError = nil
            return
        }
        let canonical = ports.map(\.canonicalText).joined(separator: "\n")
        if validationError == nil, draftText != canonical {
            draftText = canonical
        }
    }

    private func apply(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            value = .set(try lines.map(SnifferPort.init(parsing:)))
            validationError = nil
        } catch {
            value = .set([])
            validationError = error.localizedDescription
        }
    }
}

private func overrideMode<Value: Codable & Sendable>(
    _ value: Binding<OverrideValue<Value>>,
    defaultValue: Value
) -> Binding<OverrideModeChoice> {
    Binding(
        get: {
            switch value.wrappedValue {
            case .inherit: .inherit
            case .set: .set
            case .remove: .remove
            }
        },
        set: { mode in
            value.wrappedValue = switch mode {
            case .inherit: .inherit
            case .set:
                if case .set = value.wrappedValue {
                    value.wrappedValue
                } else {
                    .set(defaultValue)
                }
            case .remove: .remove
            }
        }
    )
}

private func setValue<Value: Codable & Sendable>(
    _ value: Binding<OverrideValue<Value>>,
    defaultValue: Value
) -> Binding<Value> {
    Binding(
        get: {
            if case let .set(current) = value.wrappedValue { return current }
            return defaultValue
        },
        set: { value.wrappedValue = .set($0) }
    )
}

private func listValue(
    _ value: Binding<OverrideValue<[String]>>
) -> [String] {
    if case let .set(values) = value.wrappedValue { return values }
    return []
}

private func stringListText(
    _ value: Binding<OverrideValue<[String]>>
) -> Binding<String> {
    Binding(
        get: { listValue(value).joined(separator: "\n") },
        set: { text in
            value.wrappedValue = .set(
                text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
    )
}

private func nameserverPolicyText(
    _ value: Binding<OverrideValue<[NameserverPolicyEntry]>>
) -> Binding<String> {
    Binding(
        get: {
            guard case let .set(entries) = value.wrappedValue else { return "" }
            return entries.map { entry in
                "\(entry.pattern) = \(entry.servers.joined(separator: ", "))"
            }.joined(separator: "\n")
        },
        set: { text in
            let entries = text.components(separatedBy: .newlines)
                .map { line -> NameserverPolicyEntry in
                    let pieces = line.split(separator: "=", maxSplits: 1).map(String.init)
                    let pattern = pieces.first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let servers = pieces.count > 1
                        ? pieces[1].split(separator: ",").map {
                            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        : []
                    return NameserverPolicyEntry(pattern: pattern, servers: servers)
                }
                .filter { !$0.pattern.isEmpty || !$0.servers.isEmpty }
            value.wrappedValue = .set(entries)
        }
    )
}
