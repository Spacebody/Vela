# Vela Architecture Map

Review baseline: `main` at `1aece344b57c7ce660206eb49772b686d923208b` (2026-08-19).

This map is derived from the current production source, CodeGraph call paths, the Xcode project, `Contracts/v1`, and the generated Hardening manifests. It is not a proposed replacement architecture.

## Runtime dependency chain

```text
VelaApp / AppDelegate
→ AppEnvironment.live() composition root
→ ContentView / Sidebar / AppSection routing
→ Feature views
→ feature presentation state in DailyDriverFeatureHub and dedicated feature stores
→ EngineStore façade and CoreLifecycleController
→ RuntimeMutationGate / EngineTransitionCoordinator / transaction coordinators
→ user-process EngineBackend or PrivilegedMihomoBackend
→ RuntimeControllerRouter / MihomoControllerSession
→ PrivilegedHelperClient
→ VelaIPC frozen contracts
→ VelaHelper / VelaPrivilegedCore
→ Mihomo process and macOS System Configuration / privileged filesystem
```

## Composition root

`Vela/App/AppEnvironment.swift:19-291` constructs the live object graph. It creates the profile/configuration stores, Core store and resolver, validation/process/controller services, optional Helper-backed runtime, System Proxy manager, health/network observers, a single shared `RuntimeMutationGate`, `EngineStore`, feature services, and the runtime configuration transaction coordinator.

The 559-line `AppEnvironment.live()` function is a composition hotspot, but it is also the intentional dependency root. Any split must preserve one authoritative instance of the mutation gate, controller router, profile store, and runtime services.

## App shell and feature routing

`Vela/App/ContentView.swift:5-343` owns sidebar routing and injects shared dependencies into feature views. `ContentView.destination` selects Overview, Proxies, Connections, Rules, Configuration, Settings, Logs, Unlock Tests, and diagnostics/support surfaces. Refresh behavior is routed by `refreshCurrentSection()` (`ContentView.swift:293-311`).

The app shell therefore depends on feature-facing APIs, but feature views must not depend on another feature's view state. Shared runtime facts should come from Core services or purpose-built projections.

## Feature state

`Vela/App/DailyDriverFeatureHub.swift` contains multiple dedicated `@Observable` models, including profiles/providers/connections/rules/geo state. Connections already uses a separate presentation pipeline and configuration generation (`DailyDriverFeatureHub.swift:942-1479`) rather than deriving every row directly in a View body.

This is a partial feature-state boundary, not a license to make `DailyDriverFeatureHub` a second global store. The review will verify ownership and cross-feature reads before moving any state.

## Engine and lifecycle

`Vela/Core/Engine/EngineStore.swift:183-490` is the UI-facing runtime façade and current aggregate state owner. It coordinates engine state and runtime/backend identity; profile selection and validation; controller, traffic, logs, proxies, delay results, and health projections; System Proxy and TUN state; transition, lease, sleep/wake, network recovery, update preparation/recovery, and scene transactions.

`Vela/Core/Engine/EngineTransitionCoordinator.swift:41-295` is an actor that permits one active backend transition, emits bounded events, propagates cancellation, and waits for rollback. This direction is authoritative and must be preserved.

`RuntimeMutationGate` is created once in `AppEnvironment.live()` and passed to Engine, Core lifecycle, provider/geo services, subscriptions, and configuration transactions. It is the cross-workflow exclusion boundary.

## Configuration path

```text
Feature editor / subscription operation
→ ProfileStore / ConfigurationLayerStore
→ RuntimeConfigTransactionCoordinator
→ validate and stage
→ atomic persistence / journal
→ process or controller apply
→ runtime verification
→ rollback / recovery journal on failure
```

`Vela/Core/Configuration/RuntimeConfigTransactionCoordinator.swift` and `ProfileStore.swift` are the existing bounded owners. Refactors must strengthen these owners rather than duplicate transaction logic in views or `EngineStore`.

## Core lifecycle

```text
CoreStore (catalog, installed state, durable mutation)
→ CoreLifecycleController (download/verify/install/activate workflow)
→ EngineStore façade for runtime quiesce/restore
→ RuntimeMutationGate
→ factory or installed Core resolver
```

The precise overlap between `CoreStore`, `CoreLifecycleController`, and `EngineStore` is audited in `04_CORE_LIFECYCLE_AUDIT.md` before any extraction.

## Controller boundary

`RuntimeControllerRouter` provides the active controller endpoint while `MihomoControllerSession` owns readiness/reconnect/stream behavior. Controller connectivity is infrastructure state and is not equivalent to engine-running or user traffic-takeover state.

## Privileged boundary

```text
Vela app
→ PrivilegedHelperClient (actor, XPC lifecycle and request bounds)
→ VelaIPC schema/protocol v2
→ VelaHelper bootstrap and per-connection service
→ PrivilegedHelperCoordinator / lease and session checks
→ VelaPrivilegedCore root stores/runtime controller
→ Mihomo and protected filesystem/network operations
```

The frozen IPC constants are in `VelaIPC/VelaIPCConstants.swift:3-44`: schema version 1, protocol min/max 2, explicit payload/resource bounds, and a 2,000-entry Helper log cap.

## System network ownership

System Proxy and TUN are independent, composable traffic-takeover mechanisms. `EngineStore.isTrafficTakeoverActive` is true when either verified System Proxy ownership or a verified privileged runtime is active. `trafficTakeoverStartedAt` is derived from that product-level state, not controller readiness.

Authoritative owners to preserve:

- System Proxy mutation/verification/recovery: `SystemProxyManager` and its recovery store.
- TUN process/session/lease proof: privileged backend + Helper coordinator + lease coordinator.
- UI-facing combined state: `EngineStore` façade.

## Cross-layer dependencies requiring review

| Source | Target | Current reason | Review concern |
| --- | --- | --- | --- |
| App shell | EngineStore | global runtime presentation and actions | broad Observation invalidation |
| App shell | DailyDriverFeatureHub | feature model injection | hub growth / feature coupling |
| CoreLifecycleController | EngineStore | quiesce, activate, restore runtime | workflow overlap |
| EngineStore | ProfileStore and transaction services | runtime/profile coordination | duplicate mutation paths |
| EngineStore | Helper/backend/controller | runtime façade | MainActor orchestration load |
| Features | controller-backed services | live data | controller must not gate static data |
| Helper | VelaIPC | frozen privileged contract | no public/API expansion without ADR |

## External dependencies

| Dependency | Use | Current assessment |
| --- | --- | --- |
| Yams 6.2.2 | YAML parsing/encoding | actively used; replacing it would add risk without a demonstrated benefit |
| Sparkle 2.9.4 | application update lifecycle | actively used; integrated with update hardening and recovery |
| VelaIPC local package | frozen app/helper contracts and privileged core | required cross-target contract, not replaceable by an app-internal type |

Apple frameworks provide UI, Observation, Foundation, Network, CryptoKit, Security/XPC, ServiceManagement, and System Configuration integration.

## Baseline gate status

- Workflow action-pin validation: PASS (9 workflows).
- Architecture/attack-surface freeze: FAIL because generated source-discovery hashes and scanned-file count differ from the committed baseline.
- Hardening unit suite: 23 pass, 5 fail; all five failures are downstream of the stale architecture freeze.

The semantic frozen capabilities, protocol range, trust roots, and declared stores/endpoints did not change in the generated diff. Only discovery hashes/count and the dependent attack-surface manifest hash changed. This still requires the repository's ADR process; it must not be silently regenerated.
