# Core Lifecycle Audit

Review baseline: `main` at `1aece344b57c7ce660206eb49772b686d923208b`.

## Current ownership

### `CoreStore` actor

Owns durable core catalog/install/activation state, preferences, journals, filesystem validation and atomic private writes. It already enforces bounded resources (state, transaction, install journal, reconciliation history and installed-core count), uses `openat`/`O_NOFOLLOW`, `fsync`, strict JSON and private file modes. This is the correct low-level security/durability boundary and must not be moved back to a MainActor controller.

### `CoreLifecycleController`

Owns workflow orchestration and UI-facing operation state:

- catalog refresh and trust evidence
- download/staging/compatibility checks
- activation orchestration
- EngineStore snapshot, stop/start, health proof and restore
- probation and rollback
- root parity/helper policy
- background scheduling and update-safe-mode/journal presentation

### `EngineStore`

Remains the runtime facade and source of the runtime snapshot/operations consumed by activation. It must not become a second owner of core catalog persistence or install journals.

## Findings

### CORE-LIFE-001

- **Severity:** P1
- **File:** `Vela/Core/CoreLifecycle/CoreLifecycleController.swift`
- **Line/Type:** `activate`, approximately lines 659-861; lease cleanup near 687-692
- **Evidence:** `activate` acquires the shared runtime mutation lease, then a `defer` starts an unstructured `Task` to release it when ownership is not transferred to probation. The public async method can therefore return before the gate release completes. A same-core early return after acquisition also relies on that deferred task.
- **Impact:** A caller can immediately begin another runtime mutation and observe a spurious “update in progress”/busy state, or ordering can vary under cancellation. Mutation serialization is not mechanically proved at the method boundary.
- **Fix:** Remove the fire-and-forget release. Explicitly `await runtimeMutationGate.release(lease)` on the same-core early return and once at the common terminal path when probation did not assume ownership. Keep the probation-owned release unchanged.
- **Test:** Prove the gate is immediately reacquirable after same-core no-op, pre-transaction failure, cancellation/rollback and successful non-probation completion; prove probation retains ownership until commit/rollback.
- **Status:** Fixed and verified. GitNexus upstream impact was LOW (three direct callers, one affected module). The unstructured deferred release was removed; same-Core return and the common non-probation terminal path now await the shared gate release. `CoreLifecycleControllerTests.sameCoreActivationReleasesMutationLeaseBeforeReturning` passed on macOS.

### CORE-MAIN-001

- **Severity:** P2
- **File:** `Vela/Core/CoreLifecycle/CoreLifecycleController.swift`
- **Line/Type:** `download`, approximately lines 534-650
- **Evidence:** The controller delegates network transfer and durable install to async services/CoreStore, but performs synchronous directory creation and deferred removal on MainActor.
- **Impact:** Filesystem latency can block UI operation-state updates.
- **Fix:** Move staging-directory lifecycle into the existing download/install service or a nonisolated helper without weakening path/symlink checks.
- **Test:** Slow-filesystem fault injection with responsive operation state and deterministic cleanup.
- **Status:** Open after P1.

### CORE-STORE-001

- **Severity:** P1
- **File:** `Vela/Core/CoreLifecycle/CoreStore.swift`
- **Line/Type:** `updateTransaction`, durable commit verification near lines 225-299
- **Evidence:** `CoreActivationTransaction.startedAt` defaults to a subsecond `Date`, while `CoreJSONCoding` deliberately serializes lifecycle dates as canonical whole-second timestamps. After the atomic rename, `updateTransaction` decoded the durable file and compared it with the original higher-precision in-memory transaction. A valid write therefore failed with `CoreStoreError.writeVerificationFailed` whenever `startedAt` contained a fractional second.
- **Impact:** Activation cancellation and rollback could restore the previous Core successfully but fail while recording the terminal journal phase, incorrectly latch manual repair and retain a failed activation journal. The same false failure was reachable from probation and update-recovery journal updates.
- **Fix:** Preserve size, strict JSON, compare-and-swap inode, temporary-file verification, atomic rename and directory `fsync` checks. Compare the reopened durable transaction with the validated canonical decode of the exact bytes being committed, not the pre-canonical in-memory value.
- **Test:** `CoreLifecycleControllerTests.transactionUpdateAcceptsCanonicalTimestamp` proves subsecond journal creation/update; `cancellationAfterJournalRollsBackBeforeReturning` proves cancellation restores the factory Core, clears the journal, avoids a manual-repair latch and releases the runtime mutation lease.
- **Status:** Fixed and verified. GitNexus upstream impact was MEDIUM: six direct callers, 13 affected symbols and the Core recovery flow. All five focused Core lifecycle tests pass.

### CORE-TEST-001

- **Severity:** P1 test gap
- **File:** `Vela/Core/CoreLifecycle/CoreLifecycleController.swift`; `VelaTests/`
- **Line/Type:** activation/cancellation/rollback/probation workflows
- **Evidence:** Privileged/root CoreStore contract tests exist, but no focused app-level CoreLifecycleController suite was found for the full activation workflow and mutation-lease ownership.
- **Impact:** The highest-risk multi-system workflow can regress despite lower-level store/helper tests passing.
- **Fix:** Add controller-level tests using existing fault-injection and test doubles. Do not create a second failure framework.
- **Test:** Candidate start timeout, Controller unavailable, health-proof failure, rollback failure, cancellation at each phase, probation commit/rollback and gate ownership.
- **Status:** Closed for the confirmed P1 paths. The app-level controller suite proves immediate lease release for same-Core and failed activation, cancellation after journal creation with awaited rollback/journal cleanup/lease release, injected rollback failure with durable failed-journal retention plus a manual-repair latch, candidate health failure with restoration of the previous Core, and healthy probation commit with journal cleanup and lease release. Broader timeout/relaunch/backend-snapshot combinations remain P2 integration coverage rather than an unhandled known P1 defect.

### CORE-BOUND-001

- **Severity:** P2
- **File:** `Vela/Core/CoreLifecycle/CoreLifecycleController.swift`
- **Line/Type:** 2,580-line controller, 52 methods
- **Evidence:** Workflow orchestration, scheduling, UI presentation and some low-level staging mechanics coexist. `activate` is about 202 lines.
- **Impact:** Large change surface and difficult phase-level testing, but size alone is not a correctness defect.
- **Fix:** After P1 stabilization, extract bounded workflow steps around existing CoreStore/download/verification/runtime owners while keeping the controller facade and public contract.
- **Test:** Characterization tests before each extraction plus unchanged public behavior.
- **Status:** Planned strangler refactor; no wholesale rewrite.

## Activation invariants to preserve

1. Only one runtime/core mutation lease owner exists.
2. The previous runtime/core/profile/system-network snapshot is durable before destructive mutation.
3. Cancellation triggers and awaits rollback; rollback is not cancelled with the forward task.
4. Probation owns the lease until commit or rollback and releases it exactly once.
5. CoreStore remains authoritative for durable catalog/install/activation state.
6. Existing trust, signature/hash, path and helper contracts remain unchanged.

## Verification for the first bounded batch

1. `CoreLifecycleControllerTests`: passed.
2. `RuntimeMutationGateTests`: passed.
3. `RuntimeConfigTransactionCoordinatorTests`: passed.
4. `xcodebuild build -project Vela.xcodeproj -scheme Vela -destination 'platform=macOS'`: passed.
5. GitNexus `detect_changes(scope: all)`: LOW risk; only `CoreLifecycleController.activate` and its containing type were touched, with no affected execution process reported.
6. Existing warning observed, not introduced by this batch: optional interpolation in `VelaUITests/VelaUITests.swift:49`. It remains tracked by the build-warning audit.
