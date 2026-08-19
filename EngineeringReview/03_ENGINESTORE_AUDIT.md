# EngineStore Audit

Review baseline: `main` at `1aece344b57c7ce660206eb49772b686d923208b`.

See `ENGINESTORE_RESPONSIBILITY_MAP.md` for the complete current responsibility inventory.

## Preserved reliable mechanisms

- `EngineTransitionCoordinator` is an actor with a single active transition, explicit phases, cancellation propagation, rollback and an awaited cancellation barrier.
- Transition events use a bounded `AsyncStream` (`bufferingNewest(32)`) and remove continuations on termination.
- Runtime mutations share the `RuntimeMutationGate` composed in `AppEnvironment.live()`.
- Product connection state is distinct from engine-running and Controller-connected state.
- Static proxy/catalog presentation remains available while Controller data is unavailable.
- Proxy group delay tests already use an explicit concurrency limit; this must not be replaced by unbounded fan-out.
- Profile mutation suspends and restores runtime under the shared mutation lease.

## Findings

### ES-PERF-001

- **Severity:** P2
- **File:** `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** `handleControllerEvent`, around line 6175
- **Evidence:** Controller events mutate log collections, traffic samples, proxy catalog and delay state on the application-wide `@MainActor @Observable` facade. These are high-frequency and/or collection-sized values.
- **Impact:** MainActor pressure and broad feature recomputation are plausible under rapid traffic/log/connection churn. Observation is property-access scoped, so file size alone is not proof of full-app invalidation.
- **Fix:** Instrument update and render cost first. If confirmed, publish narrow bounded traffic/log/proxy projections and leave only cross-feature aggregate state in the facade.
- **Test:** ETTrace/signpost scenarios for sustained traffic, 10k logs, 1k/5k connections and rapid proxy-delay results; compare main-thread time and recomputations.
- **Status:** Open; measurement required before refactor.

### ES-MAIN-001

- **Severity:** P2
- **File:** `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** `configurationSHA256(for:)`, around line 5055; profile-import cleanup
- **Evidence:** The audited implementation performed fallback `Data(contentsOf:)` and deferred temporary-directory removal synchronously on MainActor. The runtime fingerprint now uses the existing `RuntimeConfigurationInspector` when injected and otherwise reads/hashes in a detached user-initiated task. Import staging cleanup now runs in a detached utility task on both success and failure paths.
- **Impact:** Large or slow files can produce avoidable UI stalls. The fingerprint read is normally bypassed by cached data, so current user impact is not yet established.
- **Fix:** Implemented without changing the EngineStore façade or runtime fingerprint contract.
- **Test:** `userBackendRecordsRuntimeConfigurationFingerprint` proves the recorded runtime digest still matches the real file; `profileImportRemovesPrivateStagingDirectory` proves copied import staging is removed before the operation completes. The complete 84-test `EngineStoreTests` suite passes.
- **Status:** Closed.

### ES-LIFE-001

- **Severity:** P2
- **File:** `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** observer startup/teardown around lines 5880-6046 and `deinit`
- **Evidence:** The explicit shutdown path already owns asynchronous teardown. The synchronous `deinit` fallback now cancels every stored task handle and finishes every stored lifecycle continuation, without attempting asynchronous cleanup during destruction.
- **Impact:** Store release can no longer leave continuation-backed lifecycle consumers suspended or owned consumer tasks running solely because the explicit shutdown path was skipped.
- **Fix:** Kept the existing explicit async shutdown owner and made `deinit` a complete synchronous best-effort fallback for all stored tasks and lifecycle streams.
- **Test:** `deinitializationFinishesLifecycleStreams` releases the store without explicit shutdown and proves the lifecycle stream terminates. The complete 85-test `EngineStoreTests` suite passes.
- **Status:** Closed.

### ES-STATE-001

- **Severity:** P1 audit target
- **File:** `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** engine/transition/runtime/backend/controller/product state and public mutation methods
- **Evidence:** Multiple values model intentionally different concepts. Existing tests cover many combinations, and no concrete inconsistent combination has yet been reproduced. Correctness still depends on every mutation entering the coordinator/gate route.
- **Impact:** Any bypass could expose transient invalid authoritative state.
- **Fix:** Enumerate all writers and route every backend mutation through the existing coordinator and gate; prefer one derived snapshot over new flags.
- **Test:** Invariant tests during overlapping start/stop/restart/profile/core operations, including cancellation and rollback failure.
- **Status:** Closed as an audit target; no bypass was found. `start()`, `stop()` and `restart()` acquire the shared `RuntimeMutationGate` and execute backend work through `EngineTransitionCoordinator`; profile/configuration mutation is serialized by `RuntimeConfigTransactionCoordinator`; Core activation uses the same gate and transfers ownership only to the explicit probation workflow. Controller-only refresh/selection operations do not mutate backend lifecycle authority. The distinct `state`, `transitionState`, `activeRuntime` and `activeBackendKind` values remain intentional projections rather than competing writers. Preserve this route matrix and reopen the finding if a new lifecycle mutation path is added outside it.

### Lifecycle mutation route matrix

| Mutation | Serialization owner | Transition owner | Terminal proof |
|---|---|---|---|
| start / stop / restart | `RuntimeMutationGate` | `EngineTransitionCoordinator` | transition phase completion or awaited rollback |
| profile/config apply | `RuntimeConfigTransactionCoordinator` + shared mutation gate | engine restart/reload through the existing lifecycle facade | health proof or durable rollback journal |
| Core activation | `CoreLifecycleController` + shared mutation gate | candidate start/health/probation workflow | probation commit or rollback, then lease release |
| app termination | termination barrier + shared mutation gate | coordinator cancellation and cleanup barrier | environment observers joined after cleanup proof |

## Existing test strength

`VelaTests/Engine/EngineStoreTests.swift` already covers TUN/system-proxy independence, connection-clock semantics, stop rollback/double faults, network/wake recovery, update recovery, validation cancellation, external system-proxy changes, rapid/stale requests, proxy selection/delay and core activation validation. These tests are assets to extend, not replace.

## Refactor decision

No immediate EngineStore split is justified solely by its 7,760-line size. The first bounded strangler batch moved proven file IO and cleanup work off MainActor while preserving the EngineStore public façade and existing runtime/configuration owners. Subsequent extractions must follow the same evidence-backed boundary rule.
