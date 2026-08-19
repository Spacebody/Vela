# Performance and Long-Run Audit

Review baseline: `main` at `9454542`. This review is code- and test-evidence based. A path is called a risk when work is demonstrably performed on MainActor/SwiftUI recomputation or lacks required scale proof; it is not called a regression without a measured failure.

## Data-volume and ownership table

| Area | Bound / scale evidence | Expensive work placement | Assessment |
|---|---|---|---|
| Logs | `LogBuffer.maximumCapacity == 2_000`; telemetry uses `.bufferingNewest(2_000)` | serial latest-wins `@concurrent` presentation worker; export actor | bounded and verified off MainActor |
| Connections | current snapshot only; 10,000-row tests and 500 search changes | single detached worker in actor pipeline | verified scalable architecture |
| Traffic | Overview history keeps 120 samples | sample state is published through wide EngineStore/Overview state | bounded; Observation measurement needed |
| Rules | current snapshot only; search is debounced | detached, serial latest-wins pipeline | verified architecture; explicit large-rule benchmark gap |
| Proxies | current catalog plus delay dictionary; delay cache clears on profile/catalog/reset | serial latest-wins `@concurrent` projection worker; delay requests bounded | bounded cache and off-MainActor projection; O(n) delay capture remains |
| Configuration structure | YAML analysis cache capacity 2; structure output capped at 2,000 items | detached analyzer, 150 ms preview debounce | verified bounded projection; large-YAML IO measurement needed |
| Health reports | latest report/state, not an append-only history | monitor actor; UI projection in EngineStore | bounded |
| Scenes | maximum 128 scenes | actor-backed persistence | bounded |
| Update/reliability export | retained export history capped at 50 | actor/service work | bounded |

The first bounded EngineStore performance batch moved runtime-configuration fallback reads/hashing and profile-import staging cleanup off MainActor. A second bounded Core lifecycle batch moved download workspace IO and streamed transfer behind explicit `@concurrent` methods on the existing downloader. These changes preserve the runtime digest, import, trust and install contracts and are covered by focused EngineStore/Core downloader tests.

## Findings

### PERF-CONN-001

- **Severity:** Verified mechanism
- **File:** `Vela/Core/Connections/ConnectionsPresentationPipeline.swift`; `Vela/App/DailyDriverFeatureHub.swift`; `VelaTests/Connections/ConnectionsViewModelPerformanceTests.swift`
- **Line/Type:** presentation worker, snapshot revisions and consumer lifecycle
- **Evidence:** Expensive filtering/sorting/formatting runs in a detached worker owned by an actor. A new request cancels and joins the previous worker, maximum concurrent workers is asserted as one, and stale revisions are rejected. Tests exercise 10,000 rows, three rapid 10,000-row snapshots, cancellation/latest-wins, MainActor latency under 250 ms and 500 search changes with no worker growth.
- **Impact:** The required 1k/5k/rapid-churn scenarios are covered by a stronger 10k characterization and explicit worker diagnostics.
- **Fix:** Preserve this pipeline and add memory/allocation baselines only if Instruments identifies further pressure.
- **Test:** Existing `ConnectionsViewModelPerformanceTests`.
- **Status:** No defect found.

### PERF-LOGS-001

- **Severity:** P2
- **File:** `Vela/Features/Logs/LogsView.swift`; `Vela/Features/Logs/LogsPresentation.swift`
- **Line/Type:** computed `snapshot` and `LogsPresentationSnapshot.init`
- **Evidence:** The original computed snapshot mapped and filtered the complete buffer and grouped row identities from body/change/selection/export paths. The replacement uses an O(1) revision key over immutable buffer endpoints and UI inputs; a feature-owned actor cancels and joins a prior `@concurrent` worker before accepting the latest result.
- **Impact:** CPU and allocation churn can appear during high-rate logging despite a safe 2,000-entry memory bound.
- **Fix:** Revision-keyed Logs feature projection cache/pipeline; recompute only on entry/filter revision. Retain immutable pause/export snapshots and existing redaction policy.
- **Test:** Count projection builds during hover/selection/inspector changes, sustained batch MainActor probe and Instruments allocation comparison.
- **Status:** Fixed and verified. Existing 1k/10k and 2,000-entry batch budgets pass. New tests prove latest-wins serialization, maximum one active worker and MainActor responsiveness during a 50,000-entry projection. EngineStore, pause/export snapshot and redaction contracts are unchanged.

### PERF-PROXY-001

- **Severity:** P2
- **File:** `Vela/Features/Proxies/ProxiesView.swift`; `Vela/Features/Proxies/ProxiesPresentation.swift`
- **Line/Type:** catalog-to-dashboard projection and delay-state scan
- **Evidence:** The original view walked all catalog nodes to rebuild delay state and then rebuilt all presentation groups/rows synchronously. The 100-group/10,000-candidate test measured 100 projections in 7.105 seconds (about 71 ms each). Delay testing is not an unbounded fan-out: controller group testing limits concurrency and multi-group UI tests execute groups sequentially. Engine delay cache entries are profile-scoped and are cleared when configured catalog, runtime catalog or controller state resets (`EngineStore.swift:3418`, `6205-6212`, `6879`).
- **Impact:** Large node catalogs can make selection/delay updates more expensive than the underlying bounded network operation.
- **Fix:** Implemented a revision-triggered Proxies presentation pipeline that cancels and joins superseded workers and performs the existing pure factory projection off MainActor. It deliberately keeps the immutable snapshot shape and EngineStore/request contracts stable. Incremental group replacement is deferred because it would widen the snapshot change surface without current allocation evidence.
- **Test:** The 10,000-candidate baseline remains covered. Added rapid catalog replacement/latest-wins, maximum-worker-count-one and MainActor responsiveness tests; all focused Proxies presentation tests pass.
- **Status:** MainActor full-projection risk fixed and verified. Residual P2: delay-state capture is O(n), so a one-node delay update still scans the catalog before off-actor projection.

### PERF-RULES-001

- **Severity:** P2 test gap
- **File:** `Vela/Features/Rules/RulesPresentation.swift`; `Vela/Features/Rules/RulesViewModel.swift`
- **Line/Type:** `RulesPresentationPipeline.process`, lines 286-329
- **Evidence:** Rule filtering/grouping/sorting runs in a detached latest-ticket worker. Prior work is cancelled and joined and worker diagnostics track concurrency. This is the correct architecture, but the reviewed test suite does not establish an explicit 10k/50k real-rule budget comparable to Connections.
- **Impact:** A future rule parser/presentation change could introduce large-list latency without a failing threshold.
- **Fix:** Add scale characterization before changing the pipeline; optimize only measured builder stages.
- **Test:** 10k and 50k mixed rule types, rapid search/filter changes, maximum worker count one, stale result rejected, MainActor probe.
- **Status:** Open P2 proof gap.

### PERF-CONFIG-001

- **Severity:** P2
- **File:** `Vela/Features/Configuration/ConfigurationView.swift`; `Vela/Features/Configuration/ConfigurationLiquidGlassWorkbenchView.swift`
- **Line/Type:** preview debounce/analysis cache and file import/export
- **Evidence:** Preview refresh waits 150 ms, cancels superseded generations and rejects analysis for stale YAML. YAML analysis is detached, de-duplicated in flight and cached with capacity two. Some panel-completion paths still synchronously read/write documents on MainActor.
- **Impact:** Editing computation is controlled, but large file transfer can pause the UI.
- **Fix:** Move bytes IO behind an existing bounded actor/helper, leaving panel presentation and state commits on MainActor. Keep validation and transaction ownership unchanged.
- **Test:** rapid typing, stale analysis, maximum-size import/export, cancellation and no partial destination.
- **Status:** Open P2.

### PERF-OBS-001

- **Severity:** P2 measurement/refactor candidate
- **File:** `Vela/Core/Engine/EngineStore.swift`; Overview/Proxies/Logs views
- **Line/Type:** wide `@Observable` facade and high-frequency UI-facing fields
- **Evidence:** Traffic samples, log batches, proxy catalog/delay states, health, runtime and operation states share the EngineStore facade. Swift Observation tracks accessed properties, so type width alone does not prove whole-app redraw. However, features that read several of these values also perform full synchronous projections, making invalidation cost sensitive to high-frequency updates.
- **Impact:** Traffic/log/delay updates may amplify MainActor work in the consuming pages; blindly splitting the store would risk duplicate authority without proving benefit.
- **Fix:** Instrument body/projection counts first. Extract only a proven high-frequency feature projection while EngineStore remains the authoritative facade during strangler migration.
- **Test:** signposts/body counters and MainActor latency for traffic bursts, log batches and delay updates with unrelated pages visible.
- **Status:** Open P2; measurement required before store extraction.

### PERF-LONGRUN-001

- **Severity:** Verified mechanism with one P3 follow-up
- **File:** telemetry/log buffers, Overview traffic history, SceneStore, proxy delay cache, privileged lease events
- **Line/Type:** retained state and AsyncStream buffering
- **Evidence:** Major long-lived collections are bounded or replace current snapshots. Proxy delay state is reset on catalog/profile/runtime changes. Long-lived streams use bounded newest buffering; `PrivilegedLeaseCoordinator.events()` now retains only the newest eight events per subscriber while preserving termination cleanup.
- **Impact:** No major application history leak was found. A stalled low-frequency lease subscriber is now bounded as well.
- **Fix:** Completed without changing lease authority or IPC contracts.
- **Test:** `PrivilegedLeaseCoordinatorTests` proves a stalled subscriber receives exactly the newest bounded suffix.
- **Status:** Closed.

## Performance conclusion

Connections already exceeds the requested 1k/5k validation with a 10k latest-wins pipeline and explicit MainActor/worker assertions. Logs now follows the same serial latest-wins direction with a 50k MainActor responsiveness assertion; Rules and Configuration already use bounded worker/debounce mechanisms. EngineStore runtime fingerprint IO, import staging cleanup, Core download workspace IO and streamed download transfer are now off MainActor. The remaining evidence-backed priorities are therefore not broad rewrites: cache or pipeline Proxies projection, move remaining Configuration panel IO off MainActor, add a Rules scale threshold and instrument Observation invalidation before extracting EngineStore state. All reviewed retained data is bounded, including privileged lease event buffering.
