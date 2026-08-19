# Concurrency and Lifecycle Audit

Review baseline: `main` through `693158b`, including the bounded Core lifecycle, lease-event and routed-telemetry fixes recorded below.

## Ownership map

| Owner | Work | Termination/cancellation contract |
|---|---|---|
| `EngineTransitionCoordinator` actor | Single backend transition, phase execution and rollback | New work replaces/cancels the active transition; `cancelCurrentTransitionAndWait()` waits through rollback before returning. Event buffering is `bufferingNewest(32)` and terminated subscribers are removed. |
| `RuntimeMutationGate` actor | Serializes engine lifecycle, Controller mutation, configuration transaction, Core activation and update barriers | Callers must hold a lease for the complete public async operation and release it before returning, except when ownership is deliberately transferred to probation/update recovery. |
| `EngineStore` | App-owned observation tasks and recovery workers | `prepareForTermination()` cancels and joins transitions, holds the mutation gate during the cleanup barrier and only then stops and joins environment observers. |
| `MihomoControllerSession` actor | Controller session, telemetry, proxy operations and batched log publication | Uses generation IDs to reject stale events; the public event stream is bounded to the newest 64 events and removes continuations on termination. |
| `PrivilegedLeaseCoordinator` actor | One helper-lease renewal loop | `stop()` and sleep suspension cancel and await the renewal task before clearing authority; each subscriber retains the newest eight state events and is removed on termination. |
| `MihomoProcessManager` / `ProcessExecutor` | Owned Mihomo/child process and pipe capture | Termination races are bounded, owned processes receive termination escalation, capture cleanup is deferred and the process event stream is bounded. |

## Correct mechanisms that must be preserved

1. Backend transition cancellation is not treated as completion until rollback has also completed.
2. Update installation holds a global update barrier from the runtime snapshot through shutdown proof, preventing late UI, CLI, App Intent or subscription mutations.
3. Normal app termination distinguishes a verified cleanup from the explicit lease-expiry fallback for an unverified privileged runtime.
4. Sleep handling cancels and joins privileged recovery workers before suspending lease renewal; wake recovery is generation guarded.
5. Controller and proxy operations use generation/identity checks to reject stale results.
6. High-rate event channels use bounded buffering; controller logs are batched rather than published for every line.

## Findings

### CONC-LIFE-001

- **Severity:** P1
- **File:** `Vela/Core/CoreLifecycle/CoreLifecycleController.swift`
- **Line/Type:** `activate`
- **Evidence:** The shared runtime mutation lease was released by an unstructured `Task` created in `defer`, allowing the public async operation to return before serialization authority had actually been released.
- **Impact:** A following Core/runtime mutation could observe a transient busy/update state or race ordering with the delayed release.
- **Fix:** Await release on the same-Core early return and at the common non-probation terminal path. Preserve the deliberate probation ownership transfer.
- **Test:** `CoreLifecycleControllerTests.sameCoreActivationReleasesMutationLeaseBeforeReturning`, plus `RuntimeMutationGateTests` and `RuntimeConfigTransactionCoordinatorTests`.
- **Status:** Fixed and verified; see `04_CORE_LIFECYCLE_AUDIT.md`.

### CONC-ENG-001

- **Severity:** P2
- **File:** `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** task declarations around lines 320-358, `deinit` around line 484, observer startup around lines 5881-5950 and `stopEnvironmentObservers()` around line 6046
- **Evidence:** The explicit async shutdown path remains the authoritative owner for joined teardown. The synchronous `deinit` fallback now cancels every stored task handle and finishes all lifecycle continuations, covering process, Controller, health, environment, transition, lease/recovery, validation, proxy-selection and system-proxy consumers.
- **Impact:** Releasing a store without first running explicit shutdown no longer leaves lifecycle consumers suspended or stored consumer tasks running beyond ownership.
- **Fix:** Preserved the existing idempotent async shutdown route and completed the synchronous `deinit` cancellation/continuation-finish fallback; no asynchronous work is initiated from `deinit`.
- **Test:** `deinitializationFinishesLifecycleStreams` injects a non-finishing process stream, releases the store and proves the lifecycle stream reaches termination. The complete 85-test `EngineStoreTests` suite passes.
- **Status:** Fixed and verified.

### CONC-CORE-001

- **Severity:** P1
- **File:** `Vela/Core/CoreLifecycle/CoreStore.swift`; `Vela/Core/CoreLifecycle/CoreLifecycleController.swift`
- **Line/Type:** durable activation-journal update and cancellation rollback
- **Evidence:** A journal `startedAt` value with fractional seconds was canonicalized to whole seconds on disk, then compared against the original value. The resulting false `writeVerificationFailed` occurred while cancellation awaited rollback and converted an otherwise successful restore into a manual-repair state.
- **Impact:** Cancellation correctness depended on an impossible round-trip equality invariant and could leave the durable journal retained even though the authoritative Core state had already been restored.
- **Fix:** Verify the committed journal against the canonical decode of its exact encoded bytes. Preserve the compare-and-swap, atomic rename, file verification and `fsync` barriers. Propagate the final attempted restore error into the existing safe diagnostic path instead of replacing it with a generic rollback failure.
- **Test:** Focused Core lifecycle suite passes seven tests, including a subsecond transaction round trip, cancellation after journal creation, failed automatic rollback retaining the durable journal for manual repair, candidate health failure rollback, and healthy probation commit.
- **Status:** Fixed and verified.

### CONC-STREAM-001

- **Severity:** P3
- **File:** `Vela/Core/Privileged/PrivilegedLeaseCoordinator.swift`
- **Line/Type:** `events()`, lines 37-45
- **Evidence:** The audited stream installed subscriber cleanup but used the default unbounded `AsyncStream` buffer, unlike transition, Controller, process, network, health and lifecycle streams. It now retains only the newest eight state-like lease events.
- **Impact:** The current event rate is low (the default renewal interval is 30 seconds), so this is not an immediate memory risk. A stalled subscriber combined with injected rapid renewal/failure events can nevertheless grow the queue without a declared bound.
- **Fix:** Implemented with `.bufferingNewest(8)` while preserving `onTermination` cleanup and event ordering.
- **Test:** `PrivilegedLeaseCoordinatorTests.stalledConsumerReceivesNewestBoundedSuffix` publishes twelve events to a stalled subscriber and proves that the newest eight-event suffix is retained.
- **Status:** Closed.

### CONC-TERM-001

- **Severity:** Verified mechanism
- **File:** `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** `prepareForTermination()`, lines 2961-3029; update-safe-mode and lease-cleanup termination paths, lines 3031-3100
- **Evidence:** The normal path cancels and waits for the transition coordinator, obtains the engine-lifecycle mutation lease, runs the cleanup barrier, releases the lease, and stops/joins environment observers only after the barrier proves safe. Update preparation retains its barrier until installer handoff. The explicit privileged fallback stops and joins lease renewal before invalidating the XPC client.
- **Impact:** App termination does not silently equate Controller disconnection with proof that Mihomo, TUN/routes or System Proxy are stopped.
- **Fix:** Preserve. Add tests for update-safe-mode termination and observer shutdown because CodeGraph reports no direct coverage for those private branches.
- **Test:** Existing `EngineStoreTests` termination-barrier cases, plus new branch-specific observer/lease tests.
- **Status:** No defect found in the reviewed route.

### CONC-STREAM-002

- **Severity:** P2
- **File:** `Vela/Core/Controller/RuntimeControllerRouter.swift`; `VelaTests/RuntimeControllerRouterTests.swift`
- **Line/Type:** routed telemetry stream bridge
- **Evidence:** The concrete Mihomo log and traffic sources were bounded, but the routing façade wrapped either source in a default `AsyncThrowingStream`. A stalled routed subscriber could therefore accumulate an unbounded second queue after the bounded source.
- **Impact:** Long-running log routing could retain old batches behind a slow consumer even though the transport-level buffers were correctly bounded.
- **Fix:** The routing bridge now requires an explicit buffering policy: logs retain the newest `LogBuffer.maximumCapacity` entries and traffic retains only the newest sample. Termination still cancels the forwarding task.
- **Test:** `RuntimeControllerRouterTests.trafficRoutingKeepsNewestSample` bursts samples into a stalled subscriber and proves that only the latest sample survives; the focused router suite passes 3/3.
- **Status:** Fixed and verified in `693158b`.

### CONC-STREAM-003

- **Severity:** Verified mechanism
- **File:** `Vela/Core/CoreLifecycle/CoreDownloader.swift`; `Vela/Core/CoreLifecycle/CoreCatalog.swift`
- **Line/Type:** signed asset streaming and size enforcement
- **Evidence:** Core downloads are delivered losslessly in 64 KiB chunks. Catalog/envelope/resource roles declare maximum byte counts (64 MiB for the executable and 5 MiB for other resources), and the consumer rejects cumulative overflow, final-size mismatch and SHA-256 mismatch before installation.
- **Impact:** The stream is intentionally not configured with a dropping newest/oldest policy: dropping bytes would corrupt a signed asset. Retained transfer data nevertheless has a finite contract-level upper bound and cannot be accepted without exact size and digest proof.
- **Fix:** Preserve the lossless bounded-by-contract mechanism. Introduce explicit lossless backpressure only if profiling demonstrates material buffering pressure.
- **Test:** Existing Core downloader size, integrity, cancellation and install-contract tests.
- **Status:** No defect found.

## Task classification status

- **App-owned:** EngineStore process/Controller/health/network/sleep/transition/lease observers; AppDelegate bootstrap and reconciliation tasks.
- **Operation-owned:** validation, proxy selection, system-proxy convergence, Core activation/download and configuration transactions.
- **Recovery-owned:** local-network, network-change, wake and lease recovery workers; identity/generation fields prevent stale workers from publishing authority.
- **Process-owned:** process wait, output capture and Controller telemetry loops.
- **View-owned:** `.task` work is tied to SwiftUI lifetime; explicit feature tasks are stored and cancelled on disappearance, replacement or coordinator teardown. File panels and export/import tasks are generation guarded before UI publication.

The repository-wide inventory of `Task {`, `Task.detached`, `AsyncStream`, `AsyncThrowingStream`, continuation and NotificationCenter bridges found no additional unowned mutation task or unbounded long-lived stream. Detached work is awaited, owned by a serial/latest-wins actor pipeline, or paired with timeout/cancellation. NotificationCenter bridges either own explicit observer tokens or are process-lifetime observers.

## Remaining proof work

1. Run the separately authorized privileged integration lane on a signed helper-capable host; ordinary unsigned CI cannot prove helper lease/crash cleanup end to end.
2. Preserve and extend the existing overlap/fault-injection matrix whenever a new lifecycle mutation route is added; the current start/stop/restart/profile/Core paths are serialized by `RuntimeMutationGate` and transition tests.
3. Treat any no-layer/degraded GitNexus PDG result as unknown risk rather than proof of safety.
