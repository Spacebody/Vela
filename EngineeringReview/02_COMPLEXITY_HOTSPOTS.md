# Complexity Hotspots

Metrics are from the current `main` source tree and the refreshed GitNexus index. Line counts are prioritization evidence, not automatic refactor instructions.

## Largest Swift files

| Rank | Lines | File |
| ---: | ---: | --- |
| 1 | 7,760 | `Vela/Core/Engine/EngineStore.swift` |
| 2 | 5,443 | `VelaTests/Engine/EngineStoreTests.swift` |
| 3 | 3,190 | `Vela/Features/Rules/RulesView.swift` |
| 4 | 2,724 | `Vela/Features/Configuration/ConfigurationLiquidGlassWorkbenchView.swift` |
| 5 | 2,612 | `Vela/Core/CoreLifecycle/CoreLifecycleController.swift` |
| 6 | 2,554 | `Vela/Features/Diagnostics/DiagnosticsView.swift` |
| 7 | 2,104 | `VelaTests/Configuration/RuntimeConfigTransactionCoordinatorTests.swift` |
| 8 | 2,051 | `Vela/App/DailyDriverFeatureHub.swift` |
| 9 | 2,036 | `Vela/Features/Connections/ConnectionsView.swift` |
| 10 | 1,906 | `Vela/Features/Proxies/ProxiesLiquidGlassDashboardView.swift` |
| 11 | 1,577 | `Vela/Core/CoreLifecycle/CoreStore.swift` |
| 12 | 1,518 | `VelaIPC/Sources/VelaPrivilegedCore/RootCoreStore.swift` |
| 13 | 1,507 | `Vela/Core/Engine/MihomoProcessManager.swift` |
| 14 | 1,504 | `VelaIPC/Sources/VelaPrivilegedCore/RootTransactionStore.swift` |
| 15 | 1,462 | `Vela/Features/Settings/TunOnboardingView.swift` |
| 16 | 1,451 | `Vela/Features/Settings/SettingsLiquidGlassView.swift` |
| 17 | 1,441 | `Vela/Features/Providers/ProvidersView.swift` |
| 18 | 1,390 | `Vela/Core/Configuration/RuntimeConfigTransactionCoordinator.swift` |
| 19 | 1,370 | `Vela/Core/Configuration/ProfileStore.swift` |
| 20 | 1,363 | `VelaIPC/Sources/VelaPrivilegedCore/POSIXRootFileSystem.swift` |
| 21 | 1,360 | `Vela/Features/Configuration/ConfigurationView.swift` |
| 22 | 1,274 | `Vela/Core/Controller/MihomoControllerSession.swift` |
| 23 | 1,222 | `VelaIPC/Sources/VelaPrivilegedCore/LivePrivilegedRuntimeController.swift` |
| 24 | 1,219 | `Vela/Features/Overview/OverviewDashboardView.swift` |
| 25 | 1,186 | `Vela/Features/Diagnostics/DiagnosticsWorkspaceView.swift` |
| 26 | 1,166 | `Vela/Features/Proxies/ProxiesView.swift` |
| 27 | 1,079 | `Vela/Core/Subscriptions/SubscriptionProfileService.swift` |

## Longest current functions

| Lines | Function | File |
| ---: | --- | --- |
| 559 | `AppEnvironment.live()` | `Vela/App/AppEnvironment.swift:18-576` |
| 345 | `coreLifecycleChecks` | `Vela/Features/Diagnostics/DiagnosticsView.swift:1620-1964` |
| 340 | `secretLookup` | `Vela/Core/Subscriptions/SubscriptionProfileService.swift:708-1047` |
| 325 | `applyExclusively` | `Vela/Core/Configuration/RuntimeConfigTransactionCoordinator.swift:234-558` |
| 294 | `rulesInspectorCard` | `Vela/Features/Rules/RulesView.swift:1021-1314` |
| 271 | `convert` | `Vela/Core/Subscriptions/Conversion/SingBoxSubscriptionParser.swift:79-349` |
| 246 | `start` | `VelaIPC/Sources/VelaPrivilegedCore/LivePrivilegedRuntimeController.swift:201-446` |
| 240 | `beginBootstrapIfReady` | `Vela/App/AppDelegate.swift:329-568` |
| 199 | `performEnable` | `Vela/Core/SystemProxy/SystemProxyManager.swift:130-328` |
| 190 | `editRemoteProfile` | `Vela/Core/Subscriptions/SubscriptionProfileService.swift:403-592` |
| 174 | `fetch` | `Vela/Core/Subscriptions/SubscriptionHTTPClient.swift:172-345` |
| 173 | `rollbackAfterFailure` | `Vela/Core/CoreLifecycle/CoreLifecycleController.swift:2040-2212` |
| 167 | `commitRawRevision` | `Vela/Core/Configuration/ProfileStore.swift:191-357` |
| 155 | `PatchEngine.apply` | `Vela/Core/ConfigurationWorkbench/PatchEngine.swift:305-459` |
| 153 | `activate` | `Vela/Core/CoreLifecycle/CoreLifecycleController.swift:666-818` |

## Types with the highest method count

| Methods | Type | File |
| ---: | --- | --- |
| 69 | `RootCoreStore` | `VelaIPC/Sources/VelaPrivilegedCore/RootCoreStore.swift` |
| 55 | `RootTransactionStore` | `VelaIPC/Sources/VelaPrivilegedCore/RootTransactionStore.swift` |
| 52 | `ProfileStore` | `Vela/Core/Configuration/ProfileStore.swift` |
| 53 | `CoreLifecycleController` | `Vela/Core/CoreLifecycle/CoreLifecycleController.swift` |
| 49 | `CoreStore` | `Vela/Core/CoreLifecycle/CoreStore.swift` |
| 47 | `MihomoControllerSession` | `Vela/Core/Controller/MihomoControllerSession.swift` |
| 38 | `POSIXRootFileSystem` | `VelaIPC/Sources/VelaPrivilegedCore/POSIXRootFileSystem.swift` |
| 38 | `ConfigurationLiquidGlassWorkbenchView` | `Vela/Features/Configuration/ConfigurationLiquidGlassWorkbenchView.swift` |
| 37 | `RuntimeControllerRouter` | `Vela/Core/Controller/RuntimeControllerRouter.swift` |
| 35 | `PatchEngine` | `Vela/Core/ConfigurationWorkbench/PatchEngine.swift` |
| 34 | `RuntimeConfigTransactionCoordinator` | `Vela/Core/Configuration/RuntimeConfigTransactionCoordinator.swift` |
| 34 | `DiagnosticsWorkspaceView` | `Vela/Features/Diagnostics/DiagnosticsWorkspaceView.swift` |
| 32 | `MihomoAPIClient` | `Vela/Core/Controller/MihomoAPIClient.swift` |
| 31 | `PrivilegedHelperCoordinator` | `VelaIPC/Sources/VelaPrivilegedCore/PrivilegedHelperCoordinator.swift` |
| 29 | `PrivilegedHelperClient` | `Vela/Core/Privileged/PrivilegedHelperClient.swift` |

`EngineStore` is expressed across a primary type plus extensions and is not represented accurately by the graph's single type-method aggregation. Its 7,760-line file and state/dependency inventory are the authoritative hotspot measure.

## Concern mixing

| File | Mixed concerns requiring boundary audit |
| --- | --- |
| `EngineStore.swift` | UI state, runtime lifecycle, profiles, validation, controller, telemetry/logs, proxies/delays, network ownership, health, recovery, updates, scenes |
| `CoreLifecycleController.swift` | download, trust, install, activation, probation, rollback, recovery, presentation |
| `AppEnvironment.swift` | dependency construction, production/test selection, secrets, filesystem, controller, Helper, updates, features |
| `DailyDriverFeatureHub.swift` | several feature stores plus bootstrap/deadline coordination |
| `RulesView.swift` | layout, grouping/filtering, inspector, presentation controls |
| `ConfigurationLiquidGlassWorkbenchView.swift` | editor bridge, search, validation/presentation, workbench layout |
| `DiagnosticsView.swift` | check catalog, execution, evidence, recovery actions, export |

## Priority interpretation

1. Correctness and lifecycle findings override size metrics.
2. Large security-boundary stores are not split until ownership and cleanup paths are proven.
3. Existing actors, services, coordinators, and presentation pipelines are preferred extraction targets.
4. View extraction is justified only where rendering, async lifecycle, domain mutation, or file I/O have a stable behavioral boundary.
