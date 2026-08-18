import Foundation
import VelaIPC

@MainActor
struct SupportDiagnosticsAdapter {
    let engineStore: EngineStore
    let dailyDriver: DailyDriverFeatureHub
    let updateController: UpdateController
    let coreLifecycle: CoreLifecycleController?
    let sceneController: SceneFeatureController?

    init(
        engineStore: EngineStore,
        dailyDriver: DailyDriverFeatureHub,
        updateController: UpdateController,
        coreLifecycle: CoreLifecycleController?,
        sceneController: SceneFeatureController? = nil
    ) {
        self.engineStore = engineStore
        self.dailyDriver = dailyDriver
        self.updateController = updateController
        self.coreLifecycle = coreLifecycle
        self.sceneController = sceneController
    }

    func run(for category: SupportIssueCategory) async -> [SupportCheckResult] {
        await engineStore.checkCoreIntegrity()
        guard !Task.isCancelled else { return [] }
        await engineStore.refreshPrivilegedComponent()
        guard !Task.isCancelled else { return [] }
        await engineStore.refreshHealth()
        guard !Task.isCancelled else { return [] }
        if engineStore.controllerState == .connected {
            await engineStore.refreshProxies()
        }
        guard !Task.isCancelled else { return [] }
        if category == .scenes {
            await sceneController?.reload()
        }
        guard !Task.isCancelled else { return [] }
        return results(for: category)
    }

    func repair(_ action: SupportRepairActionID) async {
        switch action {
        case .refreshHealth:
            await engineStore.refreshHealth()
        case .validateConfiguration:
            await engineStore.validateSelectedProfile()
        case .reconnectPrivilegedComponent:
            await engineStore.refreshPrivilegedComponent()
        case .restoreSystemProxy:
            if engineStore.isTunActive {
                await engineStore.setTunEnabled(false)
            } else if engineStore.systemProxyNeedsRestore {
                await engineStore.setSystemProxyEnabled(false)
            } else {
                await engineStore.refreshHealth()
            }
        case .stopVelaNetworkServices:
            if engineStore.isTunActive {
                await engineStore.setTunEnabled(false)
            }
            if engineStore.isRunning {
                await engineStore.stop()
            }
        case .refreshSubscriptions:
            await dailyDriver.profiles.updateAll()
        case .checkAppUpdate:
            updateController.checkForUpdates()
        case .checkCoreCatalog:
            await coreLifecycle?.checkNow()
        }
    }

    func results(for category: SupportIssueCategory) -> [SupportCheckResult] {
        var checks = [processResult, controllerResult, configurationResult]
        switch category {
        case .cannotConnect, .systemProxy:
            checks.append(systemProxyResult)
        case .tun:
            checks.append(contentsOf: [privilegedResult, tunResult])
        case .privilegedComponent:
            checks.append(privilegedResult)
        case .subscription:
            checks.append(subscriptionResult)
        case .configuration:
            break
        case .scenes:
            checks.append(sceneResult)
        case .appUpdate:
            checks = [appUpdateResult]
        case .coreUpdate:
            checks = [coreUpdateResult, processResult, configurationResult]
        case .cliAndShortcuts:
            checks = [
                SupportCheckResult(
                    id: "automation.availability",
                    title: VelaL10n.string(
                        "support.category.cliAndShortcuts",
                        defaultValue: "CLI and Shortcuts"
                    ),
                    detail: VelaL10n.string(
                        "support.check.automation.unavailable",
                        defaultValue:
                            "The signed CLI and Automation Socket are not enabled in this build."
                    ),
                    status: .unavailable,
                    stableCode: "AUTOMATION_NOT_IMPLEMENTED"
                )
            ]
        case .performance:
            checks.append(providerResult)
        case .crash:
            checks.append(coreIntegrityResult)
        }
        return checks
    }

    private var sceneResult: SupportCheckResult {
        guard let sceneController else {
            return SupportCheckResult(
                id: "scenes.state",
                title: VelaL10n.string(
                    "navigation.scenes",
                    defaultValue: "Scenes"
                ),
                detail: VelaL10n.string(
                    "support.scenes.stateUnavailable",
                    defaultValue: "Scene state could not be loaded for this support check."
                ),
                status: .unavailable,
                stableCode: "SCENES_STATE_UNAVAILABLE"
            )
        }
        if sceneController.document.manualRepairRequired {
            return SupportCheckResult(
                id: "scenes.state",
                title: VelaL10n.string(
                    "navigation.scenes",
                    defaultValue: "Scenes"
                ),
                detail: VelaL10n.string(
                    "scenes.repair.detail",
                    defaultValue: "The last rollback could not be proved complete. Automatic switching stays off until Diagnostics confirms repair."
                ),
                status: .failed,
                stableCode: "SCENES_MANUAL_REPAIR_REQUIRED"
            )
        }
        if let activeScene = sceneController.activeScene {
            return SupportCheckResult(
                id: "scenes.state",
                title: VelaL10n.string(
                    "navigation.scenes",
                    defaultValue: "Scenes"
                ),
                detail: VelaL10n.string(
                    "support.scenes.activeFormat",
                    defaultValue: "Active Scene: %@. %@",
                    arguments: activeScene.name,
                    sceneController.document.automaticScenesEnabled
                        ? VelaL10n.string(
                            "scenes.automation.on",
                            defaultValue: "Automatic switching on"
                        )
                        : VelaL10n.string(
                            "scenes.automation.off",
                            defaultValue: "Automatic switching off"
                        )
                ),
                status: .healthy,
                stableCode: nil
            )
        }
        return SupportCheckResult(
            id: "scenes.state",
            title: VelaL10n.string(
                "navigation.scenes",
                defaultValue: "Scenes"
            ),
            detail: VelaL10n.string(
                "support.scenes.noActive",
                defaultValue: "No Scene is active. Manual activation remains available."
            ),
            status: .warning,
            stableCode: "SCENES_NO_ACTIVE_SCENE"
        )
    }

    func makeSnapshot(
        category: SupportIssueCategory,
        results: [SupportCheckResult]
    ) -> SupportBundleSnapshot {
        let processInfo = ProcessInfo.processInfo
        let version = updateController.state.currentVersion
        let build = Int(updateController.state.currentBuild) ?? 1
        let os = processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let architecture = HardwareArchitecture.current
        return SupportBundleSnapshot(
            app: SupportBundleAppIdentity(
                version: version,
                build: build,
                channel: updateController.state.channel.rawValue,
                architecture: architecture
            ),
            system: SupportBundleSystemSummary(
                macOSVersion: osVersion,
                architecture: architecture,
                locale: VelaSupportedLocale.resolve().rawValue
            ),
            issueCategory: category,
            diagnostics: results,
            appUpdateSummary: appUpdateDetail(updateController.state.lifecycle),
            coreUpdateSummary: coreLifecycle.map {
                SettingsStatusPresentation.coreCatalogState($0.catalogState)
            },
            stableErrorCodes: results.compactMap(\.stableCode)
        )
    }

    func recentRedactedLogs() -> String? {
        let entries = engineStore.logEntries.suffix(200)
        guard !entries.isEmpty else { return nil }
        return entries.map { entry in
            let timestamp = entry.timestamp.formatted(.iso8601)
            return "\(timestamp) [\(entry.level.rawValue)] \(entry.source.rawValue): \(entry.message)"
        }.joined(separator: "\n")
    }

    private var processResult: SupportCheckResult {
        switch engineStore.state {
        case .running:
            result(
                "runtime.process",
                VelaL10n.string(
                    "support.check.process.title",
                    defaultValue: "Mihomo Process"
                ),
                VelaL10n.string(
                    "support.check.process.running",
                    defaultValue: "Running"
                ),
                .healthy
            )
        case .starting, .stopping, .recovering, .validating:
            result(
                "runtime.process",
                VelaL10n.string(
                    "support.check.process.title",
                    defaultValue: "Mihomo Process"
                ),
                VelaL10n.string(
                    "support.check.process.transitioning",
                    defaultValue: "A transition is in progress."
                ),
                .warning
            )
        case .failed:
            result(
                "runtime.process",
                VelaL10n.string(
                    "support.check.process.title",
                    defaultValue: "Mihomo Process"
                ),
                VelaL10n.string(
                    "support.check.process.failed",
                    defaultValue:
                        "Mihomo stopped after an error. Open Diagnostics for redacted details."
                ),
                .failed,
                "ENGINE_FAILED"
            )
        case .stopped:
            result(
                "runtime.process",
                VelaL10n.string(
                    "support.check.process.title",
                    defaultValue: "Mihomo Process"
                ),
                VelaL10n.string(
                    "support.check.process.stopped",
                    defaultValue: "Stopped"
                ),
                .unavailable
            )
        }
    }

    private var controllerResult: SupportCheckResult {
        switch engineStore.controllerState {
        case .connected:
            result(
                "runtime.controller",
                VelaL10n.string(
                    "support.check.controller.title",
                    defaultValue: "Controller"
                ),
                VelaL10n.string(
                    "support.check.controller.connected",
                    defaultValue: "Connected on loopback."
                ),
                .healthy
            )
        case .connecting:
            result(
                "runtime.controller",
                VelaL10n.string(
                    "support.check.controller.title",
                    defaultValue: "Controller"
                ),
                VelaL10n.string(
                    "support.check.controller.connecting",
                    defaultValue: "Connecting"
                ),
                .warning
            )
        case .disconnected:
            result(
                "runtime.controller",
                VelaL10n.string(
                    "support.check.controller.title",
                    defaultValue: "Controller"
                ),
                engineStore.isRunning
                    ? VelaL10n.string(
                        "support.check.controller.disconnected",
                        defaultValue: "Disconnected while Mihomo is running."
                    )
                    : VelaL10n.string(
                        "support.check.controller.notRequired",
                        defaultValue: "Not required while stopped."
                    ),
                engineStore.isRunning ? .failed : .unavailable,
                engineStore.isRunning ? "CONTROLLER_DISCONNECTED" : nil
            )
        case .unavailable:
            result(
                "runtime.controller",
                VelaL10n.string(
                    "support.check.controller.title",
                    defaultValue: "Controller"
                ),
                VelaL10n.string(
                    "support.check.controller.unavailable",
                    defaultValue:
                        "The Controller is unavailable. Open Diagnostics for redacted details."
                ),
                .failed,
                "CONTROLLER_UNAVAILABLE"
            )
        }
    }

    private var configurationResult: SupportCheckResult {
        if let validation = engineStore.validationResult {
            return result(
                "configuration.validation",
                VelaL10n.string(
                    "support.category.configuration",
                    defaultValue: "Configuration"
                ),
                validation.isValid
                    ? VelaL10n.string(
                        "support.check.configuration.validated",
                        defaultValue: "Validated"
                    )
                    : VelaL10n.string(
                        "support.check.configuration.failed",
                        defaultValue: "Validation failed."
                    ),
                validation.isValid ? .healthy : .failed,
                validation.isValid ? nil : "CONFIGURATION_INVALID"
            )
        }
        return result(
            "configuration.validation",
            VelaL10n.string(
                "support.category.configuration",
                defaultValue: "Configuration"
            ),
            engineStore.selectedProfileID == nil
                ? VelaL10n.string(
                    "support.check.configuration.missing",
                    defaultValue: "No configuration is selected."
                )
                : VelaL10n.string(
                    "support.check.configuration.notValidated",
                    defaultValue: "Not validated in this session."
                ),
            .unavailable,
            engineStore.selectedProfileID == nil ? "CONFIGURATION_MISSING" : nil
        )
    }

    private var systemProxyResult: SupportCheckResult {
        if engineStore.systemProxyNeedsRestore {
            return result(
                "systemProxy.state",
                VelaL10n.string(
                    "support.category.systemProxy",
                    defaultValue: "System Proxy"
                ),
                VelaL10n.string(
                    "support.check.systemProxy.restoreRequired",
                    defaultValue: "The saved System Proxy state requires restoration."
                ),
                .failed,
                "SYSTEM_PROXY_RESTORE_REQUIRED"
            )
        }
        return result(
            "systemProxy.state",
            VelaL10n.string(
                "support.category.systemProxy",
                defaultValue: "System Proxy"
            ),
            engineStore.isSystemProxyApplied
                ? VelaL10n.string(
                    "support.check.systemProxy.enabled",
                    defaultValue: "Enabled"
                )
                : VelaL10n.string(
                    "support.check.systemProxy.disabled",
                    defaultValue: "Disabled"
                ),
            engineStore.isSystemProxyApplied ? .healthy : .unavailable
        )
    }

    private var tunResult: SupportCheckResult {
        let health = engineStore.privilegedHealth
        if engineStore.isTunActive,
            health?.processRunning == true,
            health?.tunInterfacePresent == true,
            health?.routeApplied == true
        {
            return result(
                "tun.health",
                VelaL10n.string("support.category.tun", defaultValue: "TUN"),
                VelaL10n.string(
                    "support.check.tun.ready",
                    defaultValue: "Process, interface, and routes are ready."
                ),
                .healthy
            )
        }
        if engineStore.isTunActive {
            return result(
                "tun.health",
                VelaL10n.string("support.category.tun", defaultValue: "TUN"),
                VelaL10n.string(
                    "support.check.tun.failed",
                    defaultValue: "TUN is selected but one or more readiness checks failed."
                ),
                .failed,
                "TUN_NOT_READY"
            )
        }
        return result(
            "tun.health",
            VelaL10n.string("support.category.tun", defaultValue: "TUN"),
            VelaL10n.string(
                "support.check.tun.notEnabled",
                defaultValue: "Not enabled"
            ),
            .unavailable
        )
    }

    private var privilegedResult: SupportCheckResult {
        guard let manager = engineStore.privilegedComponentManager else {
            return result(
                "privileged.registration",
                VelaL10n.string(
                    "support.category.privilegedComponent",
                    defaultValue: "Privileged Component"
                ),
                VelaL10n.string(
                    "support.check.privileged.unavailable",
                    defaultValue: "Unavailable in this launch mode."
                ),
                .unavailable
            )
        }
        if manager.isReady {
            return result(
                "privileged.registration",
                VelaL10n.string(
                    "support.category.privilegedComponent",
                    defaultValue: "Privileged Component"
                ),
                VelaL10n.string(
                    "support.check.privileged.ready",
                    defaultValue: "Registered and authenticated."
                ),
                .healthy
            )
        }
        return result(
            "privileged.registration",
            VelaL10n.string(
                "support.category.privilegedComponent",
                defaultValue: "Privileged Component"
            ),
            privilegedDetail(manager.state),
            .failed,
            "PRIVILEGED_COMPONENT_NOT_READY"
        )
    }

    private var subscriptionResult: SupportCheckResult {
        let failures = dailyDriver.profiles.updateStates.values.filter { state in
            if case .failed = state { return true }
            return false
        }.count
        return result(
            "subscription.status",
            VelaL10n.string(
                "support.check.subscription.title",
                defaultValue: "Subscription Updates"
            ),
            failures == 0
                ? VelaL10n.string(
                    "support.check.subscription.healthy",
                    defaultValue: "No failed subscription update is recorded."
                )
                : VelaL10n.string(
                    "support.check.subscription.failed",
                    defaultValue: "One or more subscription updates failed."
                ),
            failures == 0 ? .healthy : .failed,
            failures == 0 ? nil : "SUBSCRIPTION_UPDATE_FAILED"
        )
    }

    private var providerResult: SupportCheckResult {
        let failures = engineStore.proxyCatalog.fetchErrors.count
        return result(
            "provider.status",
            VelaL10n.string(
                "support.check.provider.title",
                defaultValue: "Provider Catalog"
            ),
            failures == 0
                ? VelaL10n.string(
                    "support.check.provider.healthy",
                    defaultValue: "No provider fetch error is recorded."
                )
                : VelaL10n.string(
                    "support.check.provider.failed",
                    defaultValue: "Provider fetch errors are present."
                ),
            failures == 0 ? .healthy : .warning,
            failures == 0 ? nil : "PROVIDER_FETCH_FAILED"
        )
    }

    private var appUpdateResult: SupportCheckResult {
        result(
            "update.app",
            VelaL10n.string(
                "support.category.appUpdate",
                defaultValue: "App Update"
            ),
            appUpdateDetail(updateController.state.lifecycle),
            updateController.state.canCheckForUpdates ? .healthy : .warning,
            updateController.state.canCheckForUpdates ? nil : "APP_UPDATE_UNAVAILABLE"
        )
    }

    private var coreUpdateResult: SupportCheckResult {
        guard let coreLifecycle else {
            return result(
                "update.core",
                VelaL10n.string(
                    "support.category.coreUpdate",
                    defaultValue: "Core Update"
                ),
                VelaL10n.string(
                    "runtime.status.unavailable",
                    defaultValue: "Unavailable"
                ),
                .unavailable
            )
        }
        if coreLifecycle.manualRepairRequired {
            return result(
                "update.core",
                VelaL10n.string(
                    "support.category.coreUpdate",
                    defaultValue: "Core Update"
                ),
                VelaL10n.string(
                    "support.check.coreUpdate.repairRequired",
                    defaultValue: "Manual repair is required before another activation."
                ),
                .failed,
                "CORE_MANUAL_REPAIR_REQUIRED"
            )
        }
        return result(
            "update.core",
            VelaL10n.string(
                "support.category.coreUpdate",
                defaultValue: "Core Update"
            ),
            VelaL10n.string(
                "support.core.active",
                defaultValue: "Active Core: %@",
                arguments: coreLifecycle.activeDescriptor.upstreamVersion
            ),
            .healthy
        )
    }

    private var coreIntegrityResult: SupportCheckResult {
        if engineStore.coreLifecycleIntegrityVerified {
            return result(
                "core.integrity",
                VelaL10n.string(
                    "support.check.coreIntegrity.title",
                    defaultValue: "Core Integrity"
                ),
                VelaL10n.string(
                    "settings.core.integrity.verified",
                    defaultValue: "Verified"
                ),
                .healthy
            )
        }
        return result(
            "core.integrity",
            VelaL10n.string(
                "support.check.coreIntegrity.title",
                defaultValue: "Core Integrity"
            ),
            VelaL10n.string(
                "support.check.coreIntegrity.notVerified",
                defaultValue: "Not verified"
            ),
            .failed,
            "CORE_INTEGRITY_UNVERIFIED"
        )
    }

    private func privilegedDetail(_ state: PrivilegedComponentState) -> String {
        switch state {
        case .damaged:
            VelaL10n.string(
                "support.check.privileged.damaged",
                defaultValue: "The Privileged Component is damaged and must be reinstalled."
            )
        case .failed:
            VelaL10n.string(
                "support.check.privileged.failed",
                defaultValue:
                    "The Privileged Component reported an error. Reconnect or reinstall it."
            )
        default:
            VelaRuntimeStatusPresentation.helperDetail(state)
                ?? VelaRuntimeStatusPresentation.helperTitle(state)
        }
    }

    private func appUpdateDetail(_ lifecycle: UpdateLifecycleStatus) -> String {
        switch lifecycle {
        case .unavailable:
            VelaL10n.string(
                "support.check.appUpdate.unavailable",
                defaultValue: "App updates are unavailable in the current configuration."
            )
        case .idle:
            VelaL10n.string(
                "support.check.appUpdate.ready",
                defaultValue: "Ready to check for app updates."
            )
        case .checking:
            VelaL10n.string(
                "support.check.appUpdate.checking",
                defaultValue: "Securely checking the signed update feed."
            )
        case .updateAvailable(let version, let build):
            VelaL10n.string(
                "support.check.appUpdate.availableFormat",
                defaultValue: "Version %@ (%@) is available.",
                arguments: version,
                build
            )
        case .downloaded(let version, let build):
            VelaL10n.string(
                "support.check.appUpdate.downloadedFormat",
                defaultValue: "Version %@ (%@) is ready to install.",
                arguments: version,
                build
            )
        case .preparing:
            VelaL10n.string(
                "support.check.appUpdate.preparing",
                defaultValue: "Preparing network services for a verified safe stop."
            )
        case .readyForInstaller:
            VelaL10n.string(
                "support.check.appUpdate.readyForInstaller",
                defaultValue: "The update installer may continue."
            )
        case .recoveryRequired:
            VelaL10n.string(
                "support.check.appUpdate.recoveryRequired",
                defaultValue: "Update recovery is required. Open Diagnostics for redacted details."
            )
        case .failed:
            VelaL10n.string(
                "support.check.appUpdate.failed",
                defaultValue: "The update check failed. Open Diagnostics for redacted details."
            )
        }
    }

    private func result(
        _ id: String,
        _ title: String,
        _ detail: String,
        _ status: SupportCheckStatus,
        _ code: String? = nil
    ) -> SupportCheckResult {
        SupportCheckResult(
            id: id,
            title: title,
            detail: detail,
            status: status,
            stableCode: code
        )
    }
}

private nonisolated enum HardwareArchitecture {
    static var current: String {
        #if arch(arm64)
        "arm64"
        #else
        "unsupported"
        #endif
    }
}
