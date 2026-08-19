# EngineStore Responsibility Map

Review baseline: `main` at `1aece344b57c7ce660206eb49772b686d923208b`.

`EngineStore` is the application-owned, `@MainActor @Observable` facade for the runtime. It is intentionally not being replaced wholesale. This map establishes the current boundaries before any strangler refactor.

## Current responsibilities

| Responsibility | Current evidence | Appropriate long-term owner | Disposition |
|---|---|---|---|
| Engine lifecycle presentation | `EngineStore.swift:43-170` owns engine state, transition state, active runtime/backend and connection-clock state | `EngineStore` facade backed by `EngineTransitionCoordinator` | Keep aggregate UI state; remove any mutation route that bypasses the coordinator |
| Transition serialization | `EngineTransitionCoordinator.swift:41-295` owns one active transition, cancellation, rollback barrier and bounded events | Existing `EngineTransitionCoordinator` actor | Keep; it is the authoritative transition coordinator |
| Runtime mutation serialization | Start/stop, profile, TUN and system-proxy operations acquire the shared `RuntimeMutationGate` constructed by `AppEnvironment.live()` | Existing `RuntimeMutationGate` | Keep and make lease ownership/release mechanically provable |
| Profile catalog and active profile projection | `EngineStore` exposes profile catalog, active profile, validation and mutation state | Existing profile services/stores; `EngineStore` as facade | Keep UI projection; move durable IO/parsing to the existing services |
| Configuration validation and fingerprinting | Validation tasks use existing validators, while `configurationSHA256(for:)` contains a synchronous file-read fallback around `EngineStore.swift:5055` | Existing configuration validation/fingerprint services | P2 candidate: eliminate MainActor fallback IO after profiling and tests |
| Controller connection and controller-derived presentation | Controller session state, controller events, static catalog fallback, proxy selections and traffic/log projections | Existing controller session/service plus narrow feature projections | Keep controller state distinct from engine-running and traffic-takeover state |
| Traffic samples | `handleControllerEvent` around `EngineStore.swift:6175` mutates the global observable root for high-frequency samples | Dedicated traffic projection already consumed by feature state | P2 performance candidate; benchmark before extraction |
| Logs | Controller events replace/append log presentation on the global root | Existing log buffer/redaction pipeline plus Logs feature projection | P2 strangler candidate; preserve the single redaction policy |
| Proxy catalog and delay tests | Static catalog, runtime catalog, selections, delay cache and test requests are coordinated in the store; group fan-out already uses `ProxyTestDefaults.groupConcurrencyLimit` | Existing proxy catalog/delay services | Preserve bounded fan-out; extract only UI-facing snapshot ownership if invalidation data proves necessary |
| System Proxy | Request state, reconciliation and UI state are exposed from the store while mutations use existing system-proxy manager and mutation gate | Existing system-proxy manager/ownership model | Keep facade; audit rollback and external-modification proof before changing |
| TUN / privileged runtime | Backend choice, lease state and recovery are projected through the store, with privileged operations delegated to existing actors/helper contracts | Existing privileged backend/lease controller | Keep facade; do not duplicate helper or lease state machines |
| Health | Health reports and recovery decisions are projected in the store | Existing `EngineHealthMonitor` and health report types | P2 strangler candidate: narrow health projection if polling causes measurable invalidation |
| Network/sleep-wake observation | `bootstrap()` starts path/sleep observers; `stopEnvironmentObservers()` cancels and joins them | Existing observer services with app-owned lifecycle | Keep ownership explicit; close teardown gaps |
| Core activation integration | The store exposes active core/runtime and participates in activation snapshot/restore | `CoreLifecycleController` orchestration + `CoreStore` durability | Keep public facade contract; core workflow does not belong inside EngineStore |
| Update recovery and scene runtime transactions | Update shutdown/recovery and scene transactions coordinate several runtime surfaces | Existing transaction/recovery coordinators | High-value strangler candidates after P1 lifecycle work |

## Aggregate state that belongs in EngineStore

The facade should retain only authoritative UI-facing runtime aggregate state:

1. Product connection/takeover state, separately from engine and Controller infrastructure state.
2. Current transition summary and user-action operation state.
3. Active profile/core/backend identifiers and a consistent runtime snapshot.
4. Narrow projections needed by the App shell and cross-feature routing.
5. Facade methods that enter the single runtime mutation route.

Durable storage, file/network IO, parsing, crypto, process ownership, privileged calls and large collection transformations should remain in or move to the existing bounded services/actors.

## Duplicate or potentially inconsistent state sources

### ES-STATE-001

- **Severity:** P1 audit target
- **File:** `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** state group near `43-170`; lifecycle methods and Controller event handling
- **Evidence:** `state`, `transitionState`, `activeRuntime`, `activeBackendKind`, Controller connection state and product connection clock are maintained as separate values. Existing code deliberately distinguishes them, but correctness relies on all mutations entering the same route.
- **Impact:** A bypass can create transient combinations such as a running backend with stale active-runtime presentation, or a connected Controller while the product correctly remains “not connected.”
- **Fix:** Audit every backend mutation and close bypasses; do not add another boolean flag.
- **Test:** Table-driven invariant tests over start, stop, restart, profile switch, core activation, cancellation and rollback.
- **Status:** Open audit; no inconsistency has yet been proven in the current baseline.

### ES-LIFE-001

- **Severity:** P2
- **File:** `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** observer tasks around `5880-6046`; `deinit`
- **Evidence:** `stopEnvironmentObservers()` cancels and joins the observer families, but `deinit` cancels only a subset and does not finish every lifecycle continuation. The store is application-owned, so the normal route masks this asymmetry.
- **Impact:** Non-standard construction/destruction in tests or future scenes can leave tasks/continuations alive longer than their owner.
- **Fix:** Make one idempotent async shutdown owner; keep `deinit` as a last-resort synchronous cancellation only.
- **Test:** Deallocate a test store after bootstrap and prove all injected streams observe termination.
- **Status:** Open; lower priority than mutation correctness.

## MainActor work classification

| Category | Current route | Assessment |
|---|---|---|
| UI state mutation | Direct MainActor property updates | Correct |
| Network/controller calls | Delegated to async services/session | Correct direction |
| Parsing/validation | Mostly delegated; results applied on MainActor | Correct direction; inspect individual fallbacks |
| Filesystem | Profile import uses detached reads/writes, but cleanup and fingerprint fallback include synchronous `FileManager`/`Data(contentsOf:)` work | P2 candidate |
| Proxy transforms/sorting | Some catalog/delay projection occurs while handling Controller events | Benchmark and move only proven heavy transforms |
| Logs/traffic | High-frequency collection/sample updates land on the wide observable facade | P2 performance/observation candidate |
| Crypto/core verification | Delegated to services/CoreStore | Preserve |

## Strangler order based on current dependencies

1. Close P1 mutation-gate/lifecycle ordering issues across Core activation and runtime transitions.
2. Extract update-recovery and scene-runtime transaction ownership into their existing coordinators while retaining facade calls.
3. Narrow logs and traffic projections only after signpost/ETTrace evidence.
4. Move remaining synchronous fingerprint/cleanup IO off MainActor.
5. Re-evaluate health and proxy-delay projection invalidation with feature benchmarks.

This order deliberately does not split by file size. Each step must preserve the current public facade, pass its focused tests, then pass the hardening and regression suites.
