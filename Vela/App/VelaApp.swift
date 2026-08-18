import AppKit
import SwiftUI

@main
struct VelaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment: Result<AppEnvironment, UserFacingError>
    private let mainWindowLaunchBehavior: SceneLaunchBehavior
    private let settingsStartupBehavior: SettingsStartupBehavior
    private let presentationOverrideFrameSize: CGSize?
    private let presentationOverrideColorScheme: ColorScheme?
    private let presentationOverrideLocale: Locale?
    private let windowTestRequest: VelaWindowTestRequest?
#if DEBUG
    private let visualTestConfiguration: VisualUITestConfiguration?
#endif

    init() {
        let configurationError: Error?
#if DEBUG
        var requestedMenuAppearanceName: NSAppearance.Name?
        do {
            let configuration = try VisualUITestConfiguration.resolve()
            let resolvedWindowTestRequest = try VelaWindowTestRequest.resolve()
            visualTestConfiguration = configuration
            windowTestRequest = resolvedWindowTestRequest
            presentationOverrideFrameSize = resolvedWindowTestRequest == nil
                ? configuration?.windowSize.size
                : nil
            presentationOverrideColorScheme = configuration?.colorScheme
            presentationOverrideLocale = configuration?.locale
            if let appearance = configuration?.appearance {
                // SwiftUI's preferred color scheme does not reliably reach the
                // native NSMenu used by MenuBarExtra. Apply the same Debug-only
                // fixture choice at the AppKit host boundary so light/dark menu
                // captures describe the requested appearance.
                let appearanceName: NSAppearance.Name =
                    appearance == .light ? .aqua : .darkAqua
                NSApplication.shared.appearance = NSAppearance(named: appearanceName)
                requestedMenuAppearanceName = appearanceName
            } else {
                requestedMenuAppearanceName = nil
            }
            configurationError = nil
        } catch {
            visualTestConfiguration = nil
            presentationOverrideFrameSize = nil
            presentationOverrideColorScheme = nil
            presentationOverrideLocale = nil
            windowTestRequest = nil
            requestedMenuAppearanceName = nil
            configurationError = error
        }
        let isVisualTestLaunch = VisualUITestConfiguration.isRequested()
#else
        presentationOverrideFrameSize = nil
        presentationOverrideColorScheme = nil
        presentationOverrideLocale = nil
        windowTestRequest = nil
        configurationError = nil
        let isVisualTestLaunch = false
#endif
        settingsStartupBehavior = SettingsPreferencesStore.persistedStartupBehavior()
        let forcesMainWindow = isVisualTestLaunch
            || ProcessInfo.processInfo.arguments.contains(
                AppLaunchConfiguration.startupSmokeArgument
            )
        mainWindowLaunchBehavior =
            forcesMainWindow || settingsStartupBehavior != .menuBarOnly
            ? .presented
            : .suppressed
        let resolvedEnvironment: Result<AppEnvironment, UserFacingError>
        do {
            if let configurationError {
                throw configurationError
            }
            resolvedEnvironment = .success(try AppEnvironment.live())
        } catch {
            resolvedEnvironment = .failure(
                UserFacingError(
                    title: VelaL10n.string(
                        "app.bootstrap.failure.title",
                        defaultValue: "Vela could not start"
                    ),
                    message: VelaL10n.string(
                        "app.bootstrap.failure.message",
                        defaultValue: "The application environment could not be created."
                    ),
                    technicalDetails: error.localizedDescription,
                    suggestedAction: VelaL10n.string(
                        "app.bootstrap.failure.action",
                        defaultValue: "Check Application Support permissions and relaunch Vela."
                    ),
                    isRetryable: true
                )
            )
        }
        environment = resolvedEnvironment
#if DEBUG
        appDelegate.visualMenuAppearanceName = requestedMenuAppearanceName
#endif
        if case let .success(environment) = resolvedEnvironment {
            appDelegate.engineStore = environment.engineStore
            appDelegate.dailyDriver = environment.dailyDriver
            appDelegate.sceneController = environment.sceneController
            appDelegate.updateController = environment.updateController
            appDelegate.updateRecoveryCoordinator =
                environment.updateRecoveryCoordinator
            appDelegate.coreLifecycleController =
                environment.coreLifecycleController
            appDelegate.onboardingCoordinator =
                environment.onboardingCoordinator
            appDelegate.publicBetaSafeModeController =
                environment.publicBetaSafeModeController
            appDelegate.publicBetaEvidenceController =
                environment.publicBetaEvidenceController
            appDelegate.signpostRecorder = environment.signpostRecorder
        }
    }

    var body: some Scene {
        WindowGroup(
            VelaL10n.string("legacy.vela", defaultValue: "Vela"),
            id: mainWindowSceneIdentifier
        ) {
            VelaMainWindowSizingView(
                minimumContentSize: VelaWindowSizePolicy.mainMinimumContentSize,
                idealContentSize: VelaWindowSizePolicy.mainIdealContentSize,
                targetFrameSize: presentationOverrideFrameSize,
                windowTestRequest: windowTestRequest
            ) {
                mainWindowContent
            }
            .preferredColorScheme(presentationOverrideColorScheme ?? .light)
            .environment(\.locale, presentationOverrideLocale ?? .current)
        }
        .defaultSize(
            width: VelaWindowSizePolicy.mainDefaultReferenceFrameSize.width,
            height: VelaWindowSizePolicy.mainDefaultReferenceFrameSize.height
        )
        .windowStyle(.hiddenTitleBar)
        .windowResizability(mainWindowResizability)
        .defaultLaunchBehavior(mainWindowLaunchBehavior)
        .commands {
            if case let .success(environment) = environment {
                AppCommands(
                    engineStore: environment.engineStore,
                    dailyDriver: environment.dailyDriver,
                    updateController: environment.updateController,
                    onboardingCoordinator: environment.onboardingCoordinator,
                    helpNavigationCoordinator: environment.helpNavigationCoordinator
                )
            }
        }

        Window(
            VelaL10n.string("help.window.title", defaultValue: "Vela Help"),
            id: "help"
        ) {
            switch environment {
            case let .success(environment):
                HelpCenterView(
                    navigationCoordinator: environment.helpNavigationCoordinator,
                    supportDependencies: HelpCenterSupportDependencies(
                        diagnosticsAdapter: SupportDiagnosticsAdapter(
                            engineStore: environment.engineStore,
                            dailyDriver: environment.dailyDriver,
                            updateController: environment.updateController,
                            coreLifecycle: environment.coreLifecycleController,
                            sceneController: environment.sceneController
                        ),
                        publicBetaEvidence: environment.publicBetaEvidenceController
                    )
                )
                .preferredColorScheme(presentationOverrideColorScheme ?? .light)
                .environment(\.locale, presentationOverrideLocale ?? .current)
            case let .failure(error):
                BootstrapFailureView(error: error)
            }
        }
        .defaultSize(width: 1_120, height: 720)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            menuBarContent
            .preferredColorScheme(presentationOverrideColorScheme ?? .light)
            .environment(\.locale, presentationOverrideLocale ?? .current)
        } label: {
            Group {
#if DEBUG
                if let configuration = visualTestConfiguration,
                    configuration.page == .menuBar
                {
                    MenuBarVisualFixtureStatusItem(configuration: configuration)
                } else {
                    liveMenuBarLabel
                }
#else
                liveMenuBarLabel
#endif
            }
            .preferredColorScheme(presentationOverrideColorScheme ?? .light)
            .environment(\.locale, presentationOverrideLocale ?? .current)
#if DEBUG
            .environment(\.visualUITestConfiguration, visualTestConfiguration)
#endif
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var liveMenuBarLabel: some View {
        Group {
            switch environment {
            case let .success(environment):
                MenuBarLabel(
                    engineStore: environment.engineStore,
                    sceneController: environment.sceneController
                )
            case .failure:
                Label(
                    VelaL10n.string("legacy.vela", defaultValue: "Vela"),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    @ViewBuilder
    private var mainWindowContent: some View {
#if DEBUG
        if let configuration = visualTestConfiguration,
            configuration.usesProductionFeatureViews
        {
            // Production-view verification keeps the strict isolated Debug
            // dependency graph, but renders the real feature views instead of
            // the synthetic visual catalog. This is the evidence path for
            // layout regressions that the generic fixture host cannot prove.
            liveMainWindowContent
                .environment(\.visualUITestConfiguration, configuration)
                .overlay(alignment: .topLeading) {
                    VisualProductionFeatureViewMarker(
                        fixtureID: configuration.fixtureID
                    )
                }
        } else if let configuration = visualTestConfiguration,
            VisualFixturePresentationCatalog.supports(
                configuration,
                captureBoundary: .mainWindow
            )
        {
            VisualFixtureMainWindowHost(configuration: configuration)
        } else {
            liveMainWindowContent
                .environment(\.visualUITestConfiguration, visualTestConfiguration)
        }
#else
        liveMainWindowContent
#endif
    }

    @ViewBuilder
    private var liveMainWindowContent: some View {
        switch environment {
        case let .success(environment):
            ContentView(
                engineStore: environment.engineStore,
                sceneController: environment.sceneController,
                dailyDriver: environment.dailyDriver,
                coreLifecycle: environment.coreLifecycleController,
                updateController: environment.updateController,
                onboardingCoordinator: environment.onboardingCoordinator,
                helpNavigationCoordinator: environment.helpNavigationCoordinator,
                publicBetaEvidence: environment.publicBetaEvidenceController,
                publicBetaSafeMode: environment.publicBetaSafeModeController,
                initialSection: visualInitialSection
            )
        case let .failure(error):
            BootstrapFailureView(error: error)
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
#if DEBUG
        if let configuration = visualTestConfiguration,
            VisualFixturePresentationCatalog.supports(
                configuration,
                captureBoundary: .menu
            )
        {
            VisualFixtureMenuContent(configuration: configuration)
        } else {
            liveMenuBarContent
        }
#else
        liveMenuBarContent
#endif
    }

    @ViewBuilder
    private var liveMenuBarContent: some View {
        switch environment {
        case let .success(environment):
            MenuBarView(
                engineStore: environment.engineStore,
                sceneController: environment.sceneController
            )
        case let .failure(error):
            Text(error.title)
            Divider()
            Button(VelaL10n.string("legacy.openVela", defaultValue: "Open Vela")) {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(VelaL10n.string("legacy.quitVela", defaultValue: "Quit Vela")) {
                NSApp.terminate(nil)
            }
        }
    }

    private var visualInitialSection: AppSection? {
#if DEBUG
        if let section = visualTestConfiguration?.page.appSection {
            return section
        }
#endif
        return settingsStartupBehavior == .overview ? .overview : nil
    }

    private var mainWindowResizability: WindowResizability {
        presentationOverrideFrameSize == nil ? .contentMinSize : .contentSize
    }

    /// Policy UI tests use a disposable scene identity so historic AppKit and
    /// SwiftUI restoration records for the production `main` scene cannot
    /// masquerade as a fresh-install default-size result.
    private var mainWindowSceneIdentifier: String {
#if DEBUG
        windowTestRequest?.sceneIdentifier ?? "main"
#else
        "main"
#endif
    }

}

private struct VelaMainWindowSizingView<Content: View>: View {
    let minimumContentSize: CGSize
    let idealContentSize: CGSize
    let targetFrameSize: CGSize?
    let windowTestRequest: VelaWindowTestRequest?
    let content: Content
    // Seed the supported native titlebar measurement so exact visual fixtures
    // render the intended frame on their first layout pass. The AppKit bridge
    // still re-measures it and reports the actual geometry.
    @State private var chromeSize = VelaWindowSizePolicy.measuredUnifiedChromeSize
    @State private var geometry: VelaWindowGeometry?

    init(
        minimumContentSize: CGSize,
        idealContentSize: CGSize,
        targetFrameSize: CGSize?,
        windowTestRequest: VelaWindowTestRequest?,
        @ViewBuilder content: () -> Content
    ) {
        self.minimumContentSize = minimumContentSize
        self.idealContentSize = idealContentSize
        self.targetFrameSize = targetFrameSize
        self.windowTestRequest = windowTestRequest
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                minWidth: minimumContentSize.width,
                idealWidth: idealContentSize.width,
                minHeight: minimumContentSize.height,
                idealHeight: idealContentSize.height
            )
            .frame(
                width: targetContentSize?.width,
                height: targetContentSize?.height
            )
            .background {
                ZStack {
                    VelaMainWindowChromeView()

                    if targetFrameSize != nil || windowTestRequest != nil {
                        VelaWindowConfigurationView(
                            targetFrameSize: targetFrameSize,
                            testRequest: windowTestRequest,
                            chromeSize: $chromeSize,
                            geometry: $geometry
                        )
                    }
                }
            }
#if DEBUG
            .overlay(alignment: .topLeading) {
                if let geometry {
                    VisualSurfaceMarker(
                        identifier: "main.window.root",
                        label: geometry.accessibilityLabel
                    )
                }
            }
#endif
    }

    private var targetContentSize: CGSize? {
        guard let targetFrameSize else { return nil }
        return CGSize(
            width: max(1, targetFrameSize.width - chromeSize.width),
            height: max(1, targetFrameSize.height - chromeSize.height)
        )
    }
}

private struct VelaMainWindowChromeView: NSViewRepresentable {
    func makeNSView(context _: Context) -> VelaMainWindowChromeNSView {
        VelaMainWindowChromeNSView()
    }

    func updateNSView(_ nsView: VelaMainWindowChromeNSView, context _: Context) {
        nsView.configureWindowIfAvailable()
    }
}

private final class VelaMainWindowChromeNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfAvailable()
    }

    func configureWindowIfAvailable() {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Keep overlay scrollers and empty list regions from being interpreted
        // as window-background drag handles. The native titlebar remains the
        // single owner of window movement.
        window.isMovableByWindowBackground = false
        window.toolbar = nil
        // SwiftUI's content minimum does not include native titlebar chrome.
        // Keep the approved outer-frame minimum authoritative in AppKit too.
        window.minSize = VelaWindowSizePolicy.mainMinimumReferenceFrameSize
    }
}

private struct BootstrapFailureView: View {
    let error: UserFacingError

    var body: some View {
        ContentUnavailableView {
            Label(error.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.message)
        }
        .frame(minWidth: 600, minHeight: 400)
        .accessibilityIdentifier("app.bootstrap.failure")
        .accessibilityValue(error.technicalDetails ?? error.message)
    }
}
