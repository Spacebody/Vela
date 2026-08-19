import Foundation
import VelaIPC

@MainActor
struct AppEnvironment {
    let engineStore: EngineStore
    let sceneController: SceneFeatureController
    let dailyDriver: DailyDriverFeatureHub
    let updateController: UpdateController
    let updateInstallationCoordinator: UpdateInstallationCoordinator
    let updateRecoveryCoordinator: UpdateRecoveryCoordinator
    let coreLifecycleController: CoreLifecycleController
    let onboardingCoordinator: OnboardingCoordinator
    let helpNavigationCoordinator: HelpNavigationCoordinator
    let publicBetaSafeModeController: PublicBetaSafeModeController
    let publicBetaEvidenceController: PublicBetaEvidenceController
    let signpostRecorder: any VelaSignpostRecording

    static func live(
        launchConfiguration injectedLaunchConfiguration: AppLaunchConfiguration? = nil,
        directories injectedDirectories: ApplicationDirectories? = nil
    ) throws -> AppEnvironment {
        let fileSystem = LiveFileSystem()
        let launchConfiguration = try injectedLaunchConfiguration
            ?? AppLaunchConfiguration.resolve()
        let usesLiveServices = launchConfiguration.usesLiveServices
#if DEBUG
        let visualFixtureConfiguration = try VisualUITestConfiguration.resolve()
        let visualIsolation = usesLiveServices
            ? nil
            : VisualRuntimeIsolation(
                fixedDate: visualFixtureConfiguration?.fixedDate ?? .distantPast
            )
#endif
        let directories: ApplicationDirectories
        if let injectedDirectories {
            directories = injectedDirectories
        } else {
            directories = switch launchConfiguration {
            case .production:
                try ApplicationDirectories.live(fileSystem: fileSystem)
#if DEBUG
            case .uiTesting:
                try makeFreshUITestDirectories(fileSystem: fileSystem)
#endif
            case let .startupSmoke(root):
                ApplicationDirectories(root: root)
            }
        }
        let profileStore = ProfileStore(
            directories: directories,
            fileSystem: fileSystem
        )
        let staticConfigurationCatalog = StaticConfigurationCatalogService(
            profileStore: profileStore,
            fileSystem: fileSystem
        )
        let hardeningDefaults: UserDefaults
        if usesLiveServices {
            hardeningDefaults = .standard
        } else {
            hardeningDefaults = try makeFreshUITestDefaults(
                namespace: "dev.yilin.Vela.hardening.tests"
            )
        }
        let publicBetaSafeModeController = PublicBetaSafeModeController(
            launchHealthStore: PublicBetaLaunchHealthStore(
                directoryURL: directories.root.appendingPathComponent(
                    "hardening",
                    isDirectory: true
                ),
                fileSystem: fileSystem
            ),
            defaults: hardeningDefaults
        )
        let processExecutor: any ProcessExecuting
#if DEBUG
        if let visualIsolation {
            processExecutor = visualIsolation.processExecutor
        } else {
            processExecutor = ProcessExecutor()
        }
#else
        processExecutor = ProcessExecutor()
#endif
        let applicationBundleURL = Bundle.main.bundleURL
        let factoryManifestURL = applicationBundleURL
            .appending(path: MihomoCoreDescriptor.requiredMetadataBundleRelativePath)
            .appending(path: "manifest.json")
        let factoryManifest = try JSONMihomoCoreDescriptorLoader(
            fileSystem: fileSystem
        ).load(from: factoryManifestURL)
        let factoryCoreDescriptor = try CoreDescriptor.factory(
            from: factoryManifest,
            appBundleURL: applicationBundleURL
        )
        let coreDirectories = CoreDirectories(applicationDirectories: directories)
        let coreStore = CoreStore(directories: coreDirectories)
        let factoryExecutableResolver = MihomoExecutableResolver(
            processExecutor: processExecutor,
            versionProbeCurrentDirectoryURL: directories.mihomo
        )
        let executableResolver = ActiveCoreResolver(
            factoryResolver: factoryExecutableResolver
        )
        let configurationValidator = ConfigurationValidator(
            processExecutor: processExecutor
        )
        let processManager = MihomoProcessManager(
            resolver: executableResolver,
            validator: configurationValidator
        )
        let runtimeStateBackend = RuntimePrivateFileStoreBackend(
            directoryURL: directories.metadata.appendingPathComponent(
                "runtime-state",
                isDirectory: true
            )
        )
        let runtimeSecret: String
#if DEBUG
        if let visualFixtureConfiguration {
            var uuidGenerator = SeededVisualUUIDGenerator(
                seed: visualFixtureConfiguration.uuidSeed
            )
            runtimeSecret = uuidGenerator.next().uuidString
                .replacingOccurrences(of: "-", with: "")
        } else {
            runtimeSecret = RuntimeControllerSecretProvider(
                backend: runtimeStateBackend
            ).loadOrCreate()
        }
#else
        runtimeSecret = RuntimeControllerSecretProvider(
            backend: runtimeStateBackend
        ).loadOrCreate()
#endif
        let runtimeParameters = RuntimeConfigParameters(
            externalController: "127.0.0.1:9090",
            secret: runtimeSecret,
            mixedPort: 7_890,
            ipv6: SettingsPreferencesStore.persistedIPv6Enabled()
        )
        guard let controllerURL = URL(string: "http://\(runtimeParameters.externalController)") else {
            throw AppEnvironmentError.invalidControllerAddress(
                runtimeParameters.externalController
            )
        }
        let controllerRouter: RuntimeControllerRouter
#if DEBUG
        if let visualIsolation {
            // An unbound router rejects HTTP and WebSocket operations before a
            // transport can contact even the loopback Controller.
            controllerRouter = visualIsolation.controllerRouter
        } else {
            controllerRouter = RuntimeControllerRouter(
                initialBackend: .userProcess,
                endpoint: controllerURL,
                secret: SecretValue(runtimeParameters.secret)
            )
        }
#else
        controllerRouter = RuntimeControllerRouter(
            initialBackend: .userProcess,
            endpoint: controllerURL,
            secret: SecretValue(runtimeParameters.secret)
        )
#endif
        let controllerManager = MihomoControllerSession(
            apiClient: controllerRouter,
            telemetry: controllerRouter
        )
        let helperClient: PrivilegedHelperClient? = usesLiveServices
            ? PrivilegedHelperClient()
            : nil
        let privilegedComponentManager = helperClient.map {
            PrivilegedComponentManager(client: $0)
        }
        let privilegedBackend: PrivilegedMihomoBackend? = helperClient.map {
            PrivilegedMihomoBackend(client: $0)
        }
        let privilegedLeaseCoordinator: PrivilegedLeaseCoordinator? = helperClient.map {
            PrivilegedLeaseCoordinator(client: $0)
        }
        let systemProxyManager: (any SystemProxyManaging)? = if usesLiveServices {
            SystemProxyManager(
                backend: LiveSystemProxyBackend(),
                recoveryStore: SystemProxyRecoveryStore(directories: directories),
                initialTarget: SystemProxyTarget(port: runtimeParameters.mixedPort)
            )
        } else {
            nil
        }
        let runtimeConfigurationInspector = RuntimeConfigurationInspector(
            fileSystem: fileSystem
        )
        let runtimeValidationCache: any RuntimeValidationCaching = usesLiveServices
            ? RuntimeValidationCache(backend: runtimeStateBackend)
            : DisabledRuntimeValidationCache()
        let networkPathObserver: (any NetworkPathObserving)? = usesLiveServices
            ? NetworkPathObserver()
            : nil
        let sleepWakeObserver: (any SleepWakeObserving)? = usesLiveServices
            ? SleepWakeObserver()
            : nil
        let healthMonitor: (any EngineHealthMonitoring)?
        if usesLiveServices {
            let checker = DefaultEngineHealthChecker(
                processManager: processManager,
                controllerProbe: ControllerHealthProbe(
                    baseURL: controllerURL,
                    secret: runtimeParameters.secret
                ),
                configurationInspector: runtimeConfigurationInspector,
                connectivityProbe: ConnectivityProbe(),
                systemProxyManager: systemProxyManager
            )
            healthMonitor = EngineHealthMonitor(checker: checker)
        } else {
            healthMonitor = nil
        }

        let runtimeMutationGate = RuntimeMutationGate()
        let configurationLayerStore = ConfigurationLayerStore(
            directories: directories,
            fileSystem: fileSystem
        )
        let tunPreferenceStore: any TunPreferenceStoring = usesLiveServices
            ? UserDefaultsTunPreferenceStore()
            : TransientTunPreferenceStore()
        let engineStore = EngineStore(
                profileStore: profileStore,
                staticConfigurationCatalog: staticConfigurationCatalog,
                runtimeParameters: runtimeParameters,
                executableResolver: executableResolver,
                configurationValidator: configurationValidator,
                processManager: processManager,
                controllerManager: controllerManager,
                recentProxyStore: RecentProxyStore(directories: directories),
                systemProxyManager: systemProxyManager,
                healthMonitor: healthMonitor,
                runtimeConfigurationInspector: runtimeConfigurationInspector,
                runtimeValidationCache: runtimeValidationCache,
                networkPathObserver: networkPathObserver,
                sleepWakeObserver: sleepWakeObserver,
                runtimeMutationGate: runtimeMutationGate,
                configurationLayerStore: configurationLayerStore,
                mihomoDataDirectoryURL: directories.mihomo,
                controllerRouter: controllerRouter,
                privilegedBackend: privilegedBackend,
                privilegedHelperClient: helperClient,
                transitionCoordinator: privilegedBackend == nil
                    ? nil
                    : EngineTransitionCoordinator(),
                privilegedLeaseCoordinator: privilegedLeaseCoordinator,
                privilegedComponentManager: privilegedComponentManager,
                tunPreferenceStore: tunPreferenceStore,
                localNetworkContextProvider: {
#if DEBUG
                    if let visualIsolation {
                        return visualIsolation.localNetworkContextProvider
                            as any LocalNetworkContextProviding
                    }
#endif
                    return LocalNetworkContextProvider()
                        as any LocalNetworkContextProviding
                }()
            )
        let sceneController = SceneFeatureController(
            store: SceneStore(
                directories: directories,
                fileSystem: fileSystem
            ),
            transitionCoordinator: SceneTransitionCoordinator(runtime: engineStore)
        )
        let providerService = ProviderManagementService(
            apiClient: controllerRouter,
            staticConfigurationCatalog: staticConfigurationCatalog,
            runtimeMutationGate: runtimeMutationGate
        )
        let connectionsService = ConnectionsService(apiClient: controllerRouter)
        let rulesService = RulesService(
            apiClient: controllerRouter,
            staticConfigurationCatalog: staticConfigurationCatalog
        )
        let geoService = GeoDataService(
            apiClient: controllerRouter,
            runtimeMutationGate: runtimeMutationGate
        )
        let transactionCoordinator = RuntimeConfigTransactionCoordinator(
            directories: directories,
            fileSystem: fileSystem,
            profileStore: profileStore,
            runtimeParameters: runtimeParameters,
            configurationLayerStore: configurationLayerStore,
            executableResolver: executableResolver,
            validator: configurationValidator,
            apiClient: controllerRouter,
            processManager: processManager,
            runtimeMutationGate: runtimeMutationGate
        )
        let subscriptionSecretStore: SubscriptionSecretStore
        let subscriptionHTTPFetcher: any SubscriptionHTTPFetching
#if DEBUG
        if let visualIsolation {
            subscriptionSecretStore = SubscriptionSecretStore(
                backend: visualIsolation.secureStoreBackend
            )
            subscriptionHTTPFetcher = visualIsolation.subscriptionHTTPFetcher
        } else {
            subscriptionSecretStore = SubscriptionSecretStore()
            subscriptionHTTPFetcher = SubscriptionHTTPClient()
        }
#else
        subscriptionSecretStore = SubscriptionSecretStore()
        subscriptionHTTPFetcher = SubscriptionHTTPClient()
#endif
        let subscriptionService = SubscriptionProfileService(
            profileStore: profileStore,
            secretStore: subscriptionSecretStore,
            httpClient: subscriptionHTTPFetcher,
            transactionCoordinator: transactionCoordinator,
            runtimeMutationGate: runtimeMutationGate
        )
        let subscriptionScheduler = SubscriptionUpdateScheduler(
            updater: subscriptionService,
            maximumConcurrentUpdates: 2
        )
        let configurationOverrideStore = ConfigurationOverrideStore(
            profileStore: profileStore,
            directories: directories,
            fileSystem: fileSystem,
            transactionCoordinator: transactionCoordinator
        )
        let rulesViewModel = RulesViewModel(service: rulesService)
        let providersViewModel = ProvidersViewModel(
            service: providerService,
            onCatalogMutation: { kind in
                await engineStore.refreshProxies()
                if kind == .rule {
                    await rulesViewModel.refresh()
                }
            }
        )
        let launchAtLoginManager: any LaunchAtLoginManaging
#if DEBUG
        if let visualIsolation {
            launchAtLoginManager = visualIsolation.launchAtLoginManager
        } else {
            launchAtLoginManager = MainAppLaunchAtLoginManager()
        }
#else
        launchAtLoginManager = MainAppLaunchAtLoginManager()
#endif
        let dataSettingsViewModel = DataSettingsViewModel(
            geoService: geoService,
            launchAtLogin: launchAtLoginManager,
            onGeoUpdated: {
                await providersViewModel.refresh()
                await rulesViewModel.refresh()
                await engineStore.refreshHealth()
            }
        )
        let dailyDriver = DailyDriverFeatureHub(
            profiles: RemoteProfilesViewModel(
                service: subscriptionService,
                scheduler: subscriptionScheduler,
                engineStore: engineStore
            ),
            providers: providersViewModel,
            connections: ConnectionsViewModel(
                service: connectionsService,
                stream: controllerRouter
            ),
            rules: rulesViewModel,
            configuration: ConfigurationEditorViewModel(
                store: configurationOverrideStore,
                forcedFields: [
                    ConfigurationForcedField(
                        path: ["external-controller"],
                        value: .string(runtimeParameters.externalController)
                    ),
                    ConfigurationForcedField(
                        path: ["secret"],
                        value: .string(runtimeParameters.secret)
                    ),
                    ConfigurationForcedField(
                        path: ["mixed-port"],
                        value: .integer(Int(runtimeParameters.mixedPort))
                    ),
                ]
            ),
            dataSettings: dataSettingsViewModel,
            transactionCoordinator: transactionCoordinator
        )

        let appIdentity = try ReleaseBuildIdentity(bundle: .main)
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        let coreCompatibilityEnvironment = CoreCompatibilityEnvironment(
            velaVersion: appIdentity.version,
            velaBuild: UInt64(appIdentity.build),
            helperProtocol: UInt64(VelaIPCConstants.protocolMaximum),
            dataSchema: 6,
            controllerAPIProfile: VelaIPCConstants.currentControllerAPIProfile,
            macOSVersion: "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)"
        )
        let coreCatalogDownloader: CoreCatalogDownloader
        let coreFileDownloader: CoreFileDownloader
#if DEBUG
        if let visualIsolation {
            coreCatalogDownloader = CoreCatalogDownloader(
                transport: visualIsolation.coreHTTPTransport
            )
            coreFileDownloader = CoreFileDownloader(
                transport: visualIsolation.coreHTTPTransport
            )
        } else {
            coreCatalogDownloader = CoreCatalogDownloader()
            coreFileDownloader = CoreFileDownloader()
        }
#else
        coreCatalogDownloader = CoreCatalogDownloader()
        coreFileDownloader = CoreFileDownloader()
#endif
        let coreLifecycleController = CoreLifecycleController(
            store: coreStore,
            directories: coreDirectories,
            factoryDescriptor: factoryCoreDescriptor,
            activeResolver: executableResolver,
            engineStore: engineStore,
            runtimeMutationGate: runtimeMutationGate,
            compatibilityEnvironment: coreCompatibilityEnvironment,
            helperClient: helperClient,
            privilegedComponentManager: privilegedComponentManager,
            catalogDownloader: coreCatalogDownloader,
            fileDownloader: coreFileDownloader,
            configurationGeneration: { [dailyDriver] in
                dailyDriver.configurationGeneration.id
            },
            automaticCheckDefaults: hardeningDefaults
        )
        engineStore.setTunCorePolicyGate { [weak coreLifecycleController] coreID in
            guard let coreLifecycleController else {
                throw CoreLifecycleError.notBootstrapped
            }
            try await coreLifecycleController.prepareCoreForTun(coreID)
        }

        let updateDefaults: UserDefaults
        if usesLiveServices {
            updateDefaults = .standard
        } else {
            updateDefaults = try makeFreshUITestDefaults(
                namespace: "dev.yilin.Vela.updates.tests"
            )
        }
        let updateController = UpdateController(defaults: updateDefaults)
        guard let reliabilityVersion = ReliabilityAppVersion(rawValue: appIdentity.version) else {
            throw AppEnvironmentError.invalidReliabilityBuildIdentity
        }
        let reliabilityChannel: ReliabilityChannel = switch updateController.state.channel {
        case .stable: .stable
        case .beta: .beta
        }
        let publicBetaEvidenceController = PublicBetaEvidenceController(
            store: ReliabilityEvidenceStore(
                rootDirectory: directories.root.appendingPathComponent(
                    "hardening",
                    isDirectory: true
                ),
                identity: ReliabilityBuildIdentity(
                    version: reliabilityVersion,
                    build: appIdentity.build,
                    channel: reliabilityChannel
                )
            ),
            defaults: hardeningDefaults
        )
        let signpostRecorder: any VelaSignpostRecording = LiveVelaSignpostRecorder()
        let updateJournalStore = UpdateJournalStore(
            directories: directories,
            fileSystem: fileSystem
        )
        let updateIdentity = appIdentity
        let updateInstallationCoordinator = UpdateInstallationCoordinator(
            engineStore: engineStore,
            dailyDriver: dailyDriver,
            journalStore: updateJournalStore,
            sourceIdentity: updateIdentity,
            lifecycleSink: { [weak updateController] lifecycle in
                updateController?.state.setLifecycle(lifecycle)
            }
        )
        updateController.attachInstallationCoordinator(
            updateInstallationCoordinator
        )
        let updateRecoveryCoordinator = UpdateRecoveryCoordinator(
            store: updateJournalStore,
            validateHelper: { [weak privilegedComponentManager] journal in
                guard journal.snapshot.backend == .tun else { return }
                guard let privilegedComponentManager else {
                    throw UpdateRecoveryCoordinatorError.helperUnavailable
                }
                await privilegedComponentManager.refresh()
                guard privilegedComponentManager.isReady,
                    let handshake = privilegedComponentManager.lastHandshake,
                    handshake.hasCompatibleProtocol
                else {
                    throw UpdateRecoveryCoordinatorError.helperIncompatible
                }
                if let requiredProtocol = journal.snapshot.helperProtocol {
                    guard handshake.helperProtocolMinimum <= requiredProtocol,
                        handshake.helperProtocolMaximum >= requiredProtocol
                    else {
                        throw UpdateRecoveryCoordinatorError.helperIncompatible
                    }
                }
            },
            // Production restores Core selection inside EngineStore's update
            // barrier. The coordinator-level hook remains intentionally empty
            // so there is no pre-barrier Core Store mutation window.
            restoreCore: { _ in },
            restoreRuntime: { [engineStore, coreLifecycleController] snapshot in
                try await engineStore.recoverAfterUpdate(
                    snapshot,
                    beforeRuntimeRestore: {
                        try await coreLifecycleController.restoreCoreForUpdate(snapshot)
                    }
                )
            },
            lifecycleSink: { [weak updateController] lifecycle in
                updateController?.state.setLifecycle(lifecycle)
            }
        )

        let onboardingCoordinator = OnboardingCoordinator(
            store: OnboardingProgressStore(
                directoryURL: directories.root.appendingPathComponent(
                    "onboarding",
                    isDirectory: true
                ),
                fileSystem: fileSystem
            ),
            actions: OnboardingEngineActions(
                importConfiguration: { [weak engineStore] url in
                    guard let engineStore else { return false }
                    // Onboarding owns the presentation of this transaction.
                    // Clear any older main-window alert and consume a new
                    // import failure after deriving the step result so it
                    // cannot surface behind the sheet when setup closes.
                    engineStore.dismissError()
                    let profileIDsBeforeImport = Set(engineStore.profiles.map(\.id))
                    await engineStore.importProfile(url: url)
                    let succeeded = engineStore.lastError == nil
                        && Set(engineStore.profiles.map(\.id)) != profileIDsBeforeImport
                        && engineStore.selectedProfileID != nil
                    engineStore.dismissError()
                    return succeeded
                },
                validateConfiguration: { [weak engineStore] in
                    guard let engineStore else { return false }
                    engineStore.dismissError()
                    await engineStore.validateSelectedProfile()
                    let succeeded = engineStore.lastError == nil
                        && engineStore.validationResult?.isValid == true
                    engineStore.dismissError()
                    return succeeded
                }
            )
        )
        let helpNavigationCoordinator = HelpNavigationCoordinator()

        return AppEnvironment(
            engineStore: engineStore,
            sceneController: sceneController,
            dailyDriver: dailyDriver,
            updateController: updateController,
            updateInstallationCoordinator: updateInstallationCoordinator,
            updateRecoveryCoordinator: updateRecoveryCoordinator,
            coreLifecycleController: coreLifecycleController,
            onboardingCoordinator: onboardingCoordinator,
            helpNavigationCoordinator: helpNavigationCoordinator,
            publicBetaSafeModeController: publicBetaSafeModeController,
            publicBetaEvidenceController: publicBetaEvidenceController,
            signpostRecorder: signpostRecorder
        )
    }

#if DEBUG
    private static func makeFreshUITestDirectories(
        fileSystem: any FileSystemProviding
    ) throws -> ApplicationDirectories {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dev.yilin.Vela-tests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            .standardizedFileURL
        if fileSystem.fileExists(at: root) {
            try fileSystem.removeItem(at: root)
        }
        try fileSystem.createDirectory(at: root)
        try fileSystem.setPOSIXPermissions(0o700, at: root)
        return ApplicationDirectories(root: root)
    }
#endif

    static func makeFreshUITestDefaults(
        namespace: String,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        factory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) throws -> UserDefaults {
        let suiteName = "\(namespace).\(processIdentifier)"
        guard let defaults = factory(suiteName) else {
            throw AppEnvironmentError.isolatedDefaultsUnavailable(suiteName)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

nonisolated enum AppEnvironmentError: LocalizedError, Equatable, Sendable {
    case invalidControllerAddress(String)
    case invalidReliabilityBuildIdentity
    case isolatedDefaultsUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .invalidControllerAddress(address):
            "The Mihomo Controller address is invalid: \(address)"
        case .invalidReliabilityBuildIdentity:
            "The application version cannot be represented in local reliability evidence."
        case let .isolatedDefaultsUnavailable(suiteName):
            "The isolated test defaults domain could not be created: \(suiteName)"
        }
    }
}
