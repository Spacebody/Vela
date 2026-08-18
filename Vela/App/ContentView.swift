import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow

    let engineStore: EngineStore
    let sceneController: SceneFeatureController
    let dailyDriver: DailyDriverFeatureHub
    let coreLifecycle: CoreLifecycleController
    let updateController: UpdateController
    let onboardingCoordinator: OnboardingCoordinator
    let helpNavigationCoordinator: HelpNavigationCoordinator
    let publicBetaEvidence: PublicBetaEvidenceController
    let publicBetaSafeMode: PublicBetaSafeModeController
    var initialSection: AppSection?
    @SceneStorage("vela.main.selectedSection") private var selectedSectionRawValue =
        AppSection.overview.rawValue
    @State private var isInitialSectionOverrideActive = true
    @State private var showsOnboarding = false
    @State private var showsRemoteSubscriptionSheet = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                selection: selection,
                isServiceRunning: engineStore.isTrafficTakeoverActive,
                coreVersion: MihomoCoreDescriptor.requiredVersion
            )
            .frame(width: SidebarView.width)
            .clipped()
#if DEBUG
            .overlay(alignment: .topLeading) {
                VisualSurfaceMarker(identifier: "main.sidebar", label: "Vela main sidebar")
            }
#endif

            ZStack {
                VelaPageCanvas()
                destination
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .velaContainsNestedScrolling()
            .environment(\.colorScheme, .light)
#if DEBUG
            .overlay(alignment: .topLeading) {
                VisualSurfaceMarker(identifier: "main.detail", label: "Vela main detail")
            }
#endif
        }
        .ignoresSafeArea(.container, edges: .all)
#if DEBUG
        .overlay(alignment: .topLeading) {
            VisualScreenMarker(page: selectedSection.rawValue)
            VisualSurfaceMarker(identifier: "main.toolbar", label: "Vela main toolbar")
        }
#endif
        .alert(
            engineStore.lastError?.title ?? "Vela",
            isPresented: errorIsPresented
        ) {
            if engineStore.lastError?.recoveryActions.contains(.editSubscription) == true {
                Button(VelaL10n.string("legacy.editSubscription", defaultValue: "Edit Subscription")) {
                    select(.configuration)
                    engineStore.dismissError()
                }
            }
            if engineStore.lastError?.recoveryActions.contains(.openDiagnostics) == true {
                Button(VelaL10n.string("legacy.openDiagnostics", defaultValue: "Open Diagnostics")) {
                    select(.diagnostics)
                    engineStore.dismissError()
                }
            }
            if engineStore.lastError?.technicalDetails != nil {
                Button(VelaL10n.string("legacy.copyRedactedDetails", defaultValue: "Copy Redacted Details")) {
                    copyErrorDetails()
                }
            }
            Button(VelaL10n.string("legacy.ok", defaultValue: "OK")) {
                engineStore.dismissError()
            }
        } message: {
            if let error = engineStore.lastError {
                Text([error.message, error.suggestedAction].compactMap { $0 }.joined(separator: "\n\n"))
            }
        }
        .onChange(of: dailyDriver.configuration.configurationApplySequence) { _, _ in
            dailyDriver.configurationDidChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaRefreshCurrentSection)) { _ in
            Task { await refreshCurrentSection() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaOpenDiagnostics)) { _ in
            select(.diagnostics)
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaOpenMainSection)) {
            notification in
            guard let section = SettingsMainNavigationRequest.section(from: notification)
            else { return }
            select(section)
            SettingsMainNavigationRequest.acknowledge(section)
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaOpenHelpTopic)) { note in
            let topic = note.userInfo?["topic"] as? String
            guard helpNavigationCoordinator.request(topic: topic) else { return }
            openWindow(id: "help")
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaOpenOnboarding)) { _ in
            if case .present = onboardingCoordinator.presentationDecision {
                showsOnboarding = true
            }
        }
        .task {
            if let pendingSection = SettingsMainNavigationRequest.consumePendingSection() {
                select(pendingSection)
            }
            await sceneController.bootstrap(
                engineStore: engineStore,
                startsAutomation: false
            )
            if case .present = onboardingCoordinator.presentationDecision {
                showsOnboarding = true
            }
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingFlowView(
                coordinator: onboardingCoordinator,
                onFinished: { showsOnboarding = false },
                onSkipped: { showsOnboarding = false }
            )
            .interactiveDismissDisabled(onboardingCoordinator.isBusy)
        }
        .sheet(isPresented: $showsRemoteSubscriptionSheet) {
            AddRemoteProfileSheet(remoteProfiles: dailyDriver.profiles) { _ in
                showsRemoteSubscriptionSheet = false
            }
        }
    }

    private var selectedSection: AppSection {
        if isInitialSectionOverrideActive, let initialSection {
            return initialSection
        }
        return AppSection(rawValue: selectedSectionRawValue) ?? .overview
    }

    private var selection: Binding<AppSection?> {
        Binding(
            get: { selectedSection },
            set: { newValue in
                select(newValue ?? .overview)
            }
        )
    }

    @ViewBuilder
    private var destination: some View {
        switch selectedSection {
        case .overview:
            OverviewView(
                engineStore: engineStore,
                connectionsSource: OverviewConnectionsSource(
                    snapshot: { dailyDriver.connections.snapshot },
                    refresh: { await dailyDriver.connections.refreshSnapshot() },
                    activate: { dailyDriver.connections.overviewDidAppear() },
                    deactivate: { dailyDriver.connections.overviewDidDisappear() }
                )
            )
        case .proxies:
            ProxiesView(engineStore: engineStore)
        case .providers:
            ProvidersView(
                viewModel: dailyDriver.providers,
                activeProfileID: engineStore.selectedProfileID,
                runtimeGeneration: dailyDriver.configurationGeneration.id,
                runtimeAvailability: ProvidersRuntimeAvailability(
                    isMihomoRunning: engineStore.isRunning,
                    isControllerConnected: engineStore.controllerState == .connected,
                    hasConfiguration: engineStore.selectedProfileID != nil
                ),
                startMihomo: {
                    await engineStore.ensureInfrastructureRunning()
                }
            )
        case .connections:
            ConnectionsView(
                viewModel: dailyDriver.connections,
                showsLiveMetrics: engineStore.isTrafficTakeoverActive
                    && engineStore.controllerState == .connected
            )
        case .rules:
            RulesView(
                viewModel: dailyDriver.rules,
                runtimeAvailability: RulesRuntimeAvailability(
                    isMihomoRunning: engineStore.isRunning,
                    isControllerConnected: engineStore.controllerState == .connected,
                    hasConfiguration: engineStore.selectedProfileID != nil,
                    isTrafficTakeoverActive: engineStore.isTrafficTakeoverActive,
                    runtimeMode: engineStore.runtimeMode
                ),
                onAddRule: { rule in
                    guard let profileID = engineStore.selectedProfileID else {
                        throw ConfigurationOverrideStoreError.profileNotFound
                    }
                    try await dailyDriver.configuration.addRule(rule, profileID: profileID)
                }
            )
        case .configuration:
            ConfigurationView(
                viewModel: dailyDriver.configuration,
                remoteProfiles: dailyDriver.profiles,
                selectedProfileID: engineStore.selectedProfileID,
                profiles: engineStore.profiles,
                onSelectProfile: { profileID in
                    Task { await engineStore.selectProfile(id: profileID) }
                },
                onAddConfiguration: chooseConfigurationFile,
                onAddRemoteSubscription: {
                    showsRemoteSubscriptionSheet = true
                },
                onRefreshConfigurations: {
                    await engineStore.refreshProfiles()
                },
                onUpdateConfiguration: { profileID in
                    if engineStore.profiles.first(where: { $0.id == profileID })?.sourceKind
                        == .remoteSubscription
                    {
                        await dailyDriver.profiles.update(profileID)
                    } else {
                        await engineStore.refreshProfiles()
                    }
                },
                onDeleteConfiguration: { profileID in
                    if engineStore.profiles.first(where: { $0.id == profileID })?.sourceKind
                        == .remoteSubscription
                    {
                        await dailyDriver.profiles.delete(profileID)
                    } else {
                        await engineStore.deleteProfile(id: profileID)
                    }
                },
                onOpenConfigurationPage: chooseConfigurationFile
            )
        case .unlockTests:
            UnlockTestsView()
        case .settings:
            SettingsView(
                engineStore: engineStore,
                dataSettings: dailyDriver.dataSettings,
                updateController: updateController,
                helpNavigationCoordinator: helpNavigationCoordinator,
                onOpenDiagnostics: { select(.diagnostics) }
            )
        case .logs:
            LogsView(engineStore: engineStore)
        case .diagnostics:
            DiagnosticsView(
                engineStore: engineStore,
                dailyDriver: dailyDriver,
                sceneController: sceneController,
                coreLifecycle: coreLifecycle,
                updateController: updateController,
                publicBetaEvidence: publicBetaEvidence,
                publicBetaSafeMode: publicBetaSafeMode
            )
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { engineStore.lastError != nil },
            set: { isPresented in
                if !isPresented {
                    engineStore.dismissError()
                }
            }
        )
    }

    private func copyErrorDetails() {
        guard let error = engineStore.lastError,
            let details = error.redactedTechnicalDetails
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            "Correlation: \(error.correlationID.uuidString)\n\(details)",
            forType: .string
        )
    }

    private func refreshCurrentSection() async {
        switch selectedSection {
        case .overview, .diagnostics:
            await engineStore.refreshHealth()
        case .proxies:
            await engineStore.refreshProxies()
        case .connections:
            await dailyDriver.connections.refreshSnapshot()
        case .rules:
            await dailyDriver.rules.refresh()
        case .providers:
            await dailyDriver.providers.refresh()
        case .configuration:
            try? await dailyDriver.configuration.updatePreview()
        case .settings:
            await engineStore.refreshHealth()
        case .logs, .unlockTests:
            break
        }
    }

    private func select(_ section: AppSection) {
        // `initialSection` seeds deterministic visual/UI-test launches, but it
        // must not pin the destination after the user navigates elsewhere.
        isInitialSectionOverrideActive = false
        selectedSectionRawValue = section.rawValue
    }

    private func chooseConfigurationFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "yaml") ?? .plainText,
            UTType(filenameExtension: "yml") ?? .plainText,
        ]
        panel.prompt = VelaL10n.string(
            "configuration.empty.add.action",
            defaultValue: "Add Configuration…"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await engineStore.importProfile(url: url)
        }
    }

}
