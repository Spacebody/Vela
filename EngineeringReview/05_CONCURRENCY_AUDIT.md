# Concurrency and Lifecycle Audit

Review baseline: `main` at `1aece344b57c7ce660206eb49772b686d923208b`, plus the bounded `CORE-LIFE-001` fix recorded in `04_CORE_LIFECYCLE_AUDIT.md`.

## Ownership map

| Owner | Work | Termination/cancellation contract |
|---|---|---|
| `EngineTransitionCoordinator` actor | Single backend transition, phase execution and rollback | New work replaces/cancels the active transition; `cancelCurrentTransitionAndWait()` waits through rollback before returning. Event buffering is `bufferingNewest(32)` and terminated subscribers are removed. |
| `RuntimeMutationGate` actor | Serializes engine lifecycle, Controller mutation, configuration transaction, Core activation and update barriers | Callers must hold a lease for the complete public async operation and release it before returning, except when ownership is deliberately transferred to probation/update recovery. |
| `EngineStore` | App-owned observation tasks and recovery workers | `prepareForTermination()` cancels and joins transitions, holds the mutation gate during the cleanup barrier and only then stops and joins environment observers. |
| `MihomoControllerSession` actor | Controller session, telemetry, proxy operations and batched log publication | Uses generation IDs to reject stale events; the public event stream is bounded to the newest 64 events and removes continuations on termination. |
| `PrivilegedLeaseCoordinator` actor | One helper-lease renewal loop | `stop()` and sleep suspension cancel and await the renewal task before clearing authority; subscriber removal is installed, but the event stream currently has no explicit buffer bound. |
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
- **Evidence:** The explicit async shutdown path cancels and awaits network, sleep/wake, health, transition, lease and recovery tasks. `deinit` cancels only a subset and does not cancel the process, Controller, health, network, sleep/wake, validation, proxy-selection or system-proxy request tasks, nor finish the stored lifecycle continuations.
- **Impact:** `EngineStore` is currently app-owned, limiting production exposure, but test fixtures, future secondary ownership or failed bootstrap replacement can leave detached tasks waiting on streams after the store is destroyed. A `Task` handle disappearing does not itself cancel the underlying task.
- **Fix:** Define one explicit idempotent async shutdown owner for every stored task/stream. Keep `deinit` as a synchronous best-effort cancellation/continuation finish fallback; do not attempt asynchronous cleanup from `deinit`.
- **Test:** Inject non-finishing streams, invoke shutdown and release the store; assert every producer receives termination and no consumer task remains. Cover repeated shutdown.
- **Status:** Open after P1 safety work; no runtime-state bug has been reproduced.

### CONC-CORE-001

- **Severity:** P1
- **File:** `Vela/Core/CoreLifecycle/CoreStore.swift`; `Vela/Core/CoreLifecycle/CoreLifecycleController.swift`
- **Line/Type:** durable activation-journal update and cancellation rollback
- **Evidence:** A journal `startedAt` value with fractional seconds was canonicalized to whole seconds on disk, then compared against the original value. The resulting false `writeVerificationFailed` occurred while cancellation awaited rollback and converted an otherwise successful restore into a manual-repair state.
- **Impact:** Cancellation correctness depended on an impossible round-trip equality invariant and could leave the durable journal retained even though the authoritative Core state had already been restored.
- **Fix:** Verify the committed journal against the canonical decode of its exact encoded bytes. Preserve the compare-and-swap, atomic rename, file verification and `fsync` barriers. Propagate the final attempted restore error into the existing safe diagnostic path instead of replacing it with a generic rollback failure.
- **Test:** Focused Core lifecycle suite passes four tests, including a subsecond transaction round trip and cancellation after journal creation.
- **Status:** Fixed and verified.

### CONC-STREAM-001

- **Severity:** P3
- **File:** `Vela/Core/Privileged/PrivilegedLeaseCoordinator.swift`
- **Line/Type:** `events()`, lines 37-45
- **Evidence:** The stream installs subscriber cleanup but uses the default unbounded `AsyncStream` buffer, unlike transition, Controller, process, network, health and lifecycle streams.
- **Impact:** The current event rate is low (the default renewal interval is 30 seconds), so this is not an immediate memory risk. A stalled subscriber combined with injected rapid renewal/failure events can nevertheless grow the queue without a declared bound.
- **Fix:** Use a small `bufferingNewest` limit appropriate for state-like lease events; retain `onTermination` cleanup.
- **Test:** Publish more events than the limit to a suspended consumer and verify only the newest bounded suffix is observed.
- **Status:** Open; low-risk hardening.

### CONC-TERM-001

- **Severity:** Verified mechanism
- **File:** `Vela/Core/Engine/EngineStore.swift`
- **Line/Type:** `prepareForTermination()`, lines 2961-3029; update-safe-mode and lease-cleanup termination paths, lines 3031-3100
- **Evidence:** The normal path cancels and waits for the transition coordinator, obtains the engine-lifecycle mutation lease, runs the cleanup barrier, releases the lease, and stops/joins environment observers only after the barrier proves safe. Update preparation retains its barrier until installer handoff. The explicit privileged fallback stops and joins lease renewal before invalidating the XPC client.
- **Impact:** App termination does not silently equate Controller disconnection with proof that Mihomo, TUN/routes or System Proxy are stopped.
- **Fix:** Preserve. Add tests for update-safe-mode termination and observer shutdown because CodeGraph reports no direct coverage for those private branches.
- **Test:** Existing `EngineStoreTests` termination-barrier cases, plus new branch-specific observer/lease tests.
- **Status:** No defect found in the reviewed route.

## Task classification status

- **App-owned:** EngineStore process/Controller/health/network/sleep/transition/lease observers; AppDelegate bootstrap and reconciliation tasks.
- **Operation-owned:** validation, proxy selection, system-proxy convergence, Core activation/download and configuration transactions.
- **Recovery-owned:** local-network, network-change, wake and lease recovery workers; identity/generation fields prevent stale workers from publishing authority.
- **Process-owned:** process wait, output capture and Controller telemetry loops.
- **View-owned:** remains to be completed in `09_FEATURE_UI_AUDIT.md`; every `.task` and view-created `Task` will be checked against disappearance/cancellation.

## Remaining proof work

1. Enumerate every `Task {` and `Task.detached` outside the reviewed engine/core paths and record its owner and terminal condition.
2. Audit every NotificationCenter bridge and AsyncStream for termination cleanup and buffering policy.
3. Add overlap/probation/rollback-failure tests for engine start, stop, restart, profile switch and Core activation. Cancellation after Core journal creation is now covered.
4. Verify AppDelegate's bounded termination resolution against slow XPC and slow Controller shutdown fault injection.
5. Treat any no-layer/degraded GitNexus PDG result as unknown risk rather than proof of safety.
