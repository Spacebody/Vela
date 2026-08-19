# Configuration Transaction Audit

Review baseline: `main` at `50de407d`. Scope includes profiles, Configuration Workbench persistence, providers and the runtime apply/recovery transaction.

## Transaction path

```text
edit/import/provider mutation
  -> normalize and validate input
  -> acquire shared RuntimeMutationGate
  -> acquire configuration transaction slot
  -> capture selected profile/revision/runtime state
  -> write private staging data and durable recovery journal
  -> build effective runtime configuration
  -> validate with timeout
  -> atomically persist candidate
  -> reload/restart runtime
  -> wait for Controller and health proof
  -> commit durable profile revision/action
  -> remove recovery artifacts
```

Any failure after destructive mutation enters rollback. Recovery on next launch replays the durable journal and distinguishes committed durable evidence from rollback intent.

## Current ownership

| Responsibility | Owner |
|---|---|
| Global runtime/profile mutation serialization | Shared `RuntimeMutationGate` |
| Apply/recovery workflow and journal phases | `RuntimeConfigTransactionCoordinator` actor |
| Layer normalization, validation and atomic file persistence | `ConfigurationLayerStore` actor |
| Profile metadata, raw revisions and artifact staging | `ProfileStore` actor |
| Subscription secret and remote metadata compensation | `SubscriptionProfileService` actor |
| Provider persistence/apply serialization | Existing provider services using the same mutation gate |
| UI-facing editor/validation/apply state | Configuration Workbench feature/store and EngineStore facade |

## Existing mechanisms that must be preserved

1. Runtime configuration, profile, provider, Core and engine lifecycle mutations share one global mutation gate.
2. The transaction coordinator also owns a bounded FIFO apply slot and removes cancelled waiters.
3. A durable journal and private previous/candidate artifacts are written before active replacement.
4. Validation has a timeout and precedes active apply.
5. Persistent writes use candidate/read-back/normalized-equality checks and atomic destination replacement with private permissions.
6. Restart/reload is not a successful apply until Controller readiness, proxy catalog refresh/selection restoration and process health proof succeed.
7. Rollback restores the previous runtime or proves the previous stopped state; rollback failure retains the journal/artifacts for launch recovery.
8. Recovery requires exact profile revision/hash/raw-byte evidence and treats explicit rollback intent as authoritative.
9. Remote metadata rejects credentials, query and fragment material; subscription secrets remain outside public profile metadata.
10. Profile deletion stages artifacts and compensates index/secret failures instead of partially deleting live state.

## Findings

### CONFIG-TXN-001

- **Severity:** Verified mechanism
- **File:** `Vela/Core/Configuration/RuntimeConfigTransactionCoordinator.swift`
- **Line/Type:** `apply`, `applyExclusively`, `rollback`, `recoverIfNeeded`, `recoverExclusively`
- **Evidence:** The coordinator holds the shared runtime mutation lease, records phase transitions before destructive work, validates with timeout, verifies runtime health and retains recovery evidence if rollback cannot be proved.
- **Impact:** Invalid or partially applied configuration cannot silently replace the last known-good state without a durable recovery path.
- **Fix:** Preserve phase ordering and journal semantics. New configuration entry points must delegate to this owner rather than implement direct write/restart logic.
- **Test:** Existing RuntimeConfigTransactionCoordinator cancellation, recovery, rollback and mutation-barrier tests.
- **Status:** No defect found.

### CONFIG-STORE-001

- **Severity:** Verified mechanism
- **File:** `Vela/Core/Configuration/ConfigurationLayerStore.swift`; `Vela/Core/Profiles/ProfileStore.swift`
- **Line/Type:** layer persist, raw revision commit and profile deletion
- **Evidence:** Candidate bytes are normalized, decoded and read back before/after atomic write; private modes are applied. Profile revision/index changes compensate failure, and deletion stages artifacts before committing metadata.
- **Impact:** Disk failure/corruption is detected and does not automatically destroy the previous durable configuration.
- **Fix:** Preserve atomic/private persistence and compensation. Do not replace with direct `Data.write` at call sites.
- **Test:** Existing layer/profile atomicity, malformed data, revision and deletion rollback tests.
- **Status:** No defect found.

### CONFIG-SERIAL-001

- **Severity:** Verified mechanism
- **File:** `Vela/Core/Configuration/RuntimeConfigTransactionCoordinator.swift`; profile/provider services
- **Line/Type:** mutation gate and transaction-slot acquisition
- **Evidence:** Apply/recovery, direct profile mutation, subscription mutation and provider mutation use the same runtime mutation authority; cancelled queued transactions are removed before mutation.
- **Impact:** Profile/core/backend/config operations cannot concurrently publish competing authoritative runtime revisions.
- **Fix:** Preserve. Any new import/editor/provider apply route must acquire the same lease.
- **Test:** Existing overlapping mutation/update barrier tests; add a table-driven cross-entry-point matrix as routes grow.
- **Status:** No bypass found in the reviewed routes.

### CONFIG-BOUND-001

- **Severity:** P2
- **File:** `Vela/Core/Configuration/RuntimeConfigTransactionCoordinator.swift`
- **Line/Type:** `applyExclusively` (approximately 325 lines)
- **Evidence:** One actor-isolated method owns capture, staging, validation, active replacement, Controller wait, catalog/selection restoration, health proof, durable commit and rollback dispatch.
- **Impact:** Correct ordering is currently strong, but small changes have a broad review surface and individual phases are difficult to fault-inject independently.
- **Fix:** Strangler refactor only after characterization tests: extract private phase values/functions or bounded existing collaborators for stage, validate, activate/prove and durable commit. Keep the coordinator as the sole public workflow owner and keep journal phase writes adjacent to their mutations.
- **Test:** Fault injection before/after every phase with unchanged journal and rollback outcomes.
- **Status:** Planned after correctness/test expansion; no wholesale rewrite.

### CONFIG-PERF-001

- **Severity:** Verified performance boundary
- **File:** `Vela/Core/Configuration/RuntimeConfigTransactionCoordinator.swift`; Configuration Workbench validation path
- **Line/Type:** runtime build/serialization/validation projection
- **Evidence:** Durable IO and build work run on dedicated actors rather than MainActor. Workbench analysis is delayed by a cancellable 150 ms generation, de-duplicates identical in-flight YAML and runs parsing in a detached worker. The structure projection is capped at 2,000 rows. A 20,000-rule YAML characterization keeps the MainActor scheduling marker below 250 ms and completes below the three-second interaction budget.
- **Impact:** Large documents remain bounded away from MainActor, while durable configuration mutations stay serialized for correctness.
- **Fix:** Preserve the bounded cache/debounce and serial transaction ownership. Further worker extraction requires an Instruments trace showing queue contention; do not parallelize durable mutation phases speculatively.
- **Test:** `ConfigurationWorkbenchEditorProvenanceTests.largeYAMLAnalysisKeepsMainActorResponsive`, in-flight coalescing, stale-validation rejection and large-file export tests.
- **Status:** Closed; measured and verified without changing transaction authority.

### CONFIG-TEST-001

- **Severity:** P2 integration proof gap
- **File:** `VelaTests/`
- **Line/Type:** cross-feature transaction failure matrix
- **Evidence:** `RuntimeConfigTransactionCoordinatorTests` already proves health-failure rollback, candidate-reload failure, controlled restart fallback, rollback-failure journal retention, crash recovery of profile/raw/runtime state and phase-aware idempotent recovery. `AppEnvironmentCompositionTests` now constructs the production live-services graph in an isolated startup-smoke directory and proves the termination barrier. The remaining gap is native Mihomo/Controller fault execution through that graph.
- **Impact:** The transaction owner is characterized, but a composition regression in AppEnvironment, native Controller startup or production adapter wiring could still escape the actor-level suite.
- **Fix:** Add an integration-style app test using existing fault injection; do not create a second fake failure framework.
- **Test:** Preserve the existing coordinator matrix; add production-wiring coverage for Controller timeout, process health failure and launch recovery in an environment where the native adapters are available.
- **Status:** Partially closed. Production composition and teardown are executable; native process/controller fault injection remains environment-sensitive. No current data-loss path was reproduced and the core workflow is covered at its authoritative coordinator boundary.

## Configuration conclusion

No known P0/P1 implementation defect was found in the reviewed configuration paths. The durable transaction/journal/atomic-write design is substantially stronger than a simple edit-and-restart flow. The measured editor path is bounded away from MainActor; remaining work is native-process composition evidence and cautious phase extraction only after additional characterization.

## Verification

- `RuntimeConfigTransactionCoordinatorTests`: 27 tests passed, including FIFO/cancellation, cross-operation serialization, validation, health-proof rollback, reload/restart fallback, rollback failure evidence, phase-aware recovery, stale paths and post-commit cleanup.
- `ConfigurationLayerStoreTests`: 5 tests passed, including precedence, revision persistence, conflict protection and failed final-replacement rollback.
- `ProfileStoreTests`: 9 tests passed, including malformed import rejection, independent filenames, active runtime output, Scene layer application and deletion compensation.
- Combined targeted Xcode run: 66 tests in 5 suites passed with `CODE_SIGNING_ALLOWED=NO`. The only runtime messages were the existing unavailable `com.apple.linkd.autoShortcut` test-environment diagnostics; the selected tests succeeded.
