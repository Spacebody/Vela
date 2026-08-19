# Performance and Long-Run Audit

Review baseline: `main` at `9454542`. This review is code- and test-evidence based. A path is called a risk when work is demonstrably performed on MainActor/SwiftUI recomputation or lacks required scale proof; it is not called a regression without a measured failure.

## Data-volume and ownership table

| Area | Bound / scale evidence | Expensive work placement | Assessment |
|---|---|---|---|
| Logs | `LogBuffer.maximumCapacity == 2_000`; telemetry uses `.bufferingNewest(2_000)` | serial latest-wins `@concurrent` presentation worker; export actor | bounded and verified off MainActor |
| Connections | current snapshot only; 10,000-row tests and 500 search changes | single detached worker in actor pipeline | verified scalable architecture |
| Traffic | Overview history keeps 120 samples; routed telemetry retains newest 1 | sample state is published through wide EngineStore/Overview state | bounded; Observation measurement needed |
| Rules | current snapshot only; search is debounced | detached, serial latest-wins pipeline | 50,000-rule decode, refresh, search and MainActor budgets verified |
| Proxies | current catalog plus delay dictionary; delay cache clears on profile/catalog/reset | serial latest-wins `@concurrent` projection worker; delay requests bounded | bounded cache and off-MainActor projection; O(n) delay capture remains |
| Configuration structure | YAML analysis cache capacity 2; structure output capped at 2,000 items | detached analyzer, 150 ms preview debounce | verified bounded projection; large-YAML IO measurement needed |
| Health reports | latest report/state, not an append-only history | monitor actor; UI projection in EngineStore | bounded |
| Scenes | maximum 128 scenes | actor-backed persistence | bounded |
| Update/reliability export | retained export history capped at 50 | actor/service work | bounded |
| Core download | catalog/envelope/resource contracts cap accepted assets; executable 64 MiB and other resources 5 MiB | existing concurrent downloader, lossless 64 KiB chunks, exact size/SHA-256 verification | finite and integrity preserving |

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

- **Severity:** Verified mechanism
- **File:** `Vela/Features/Rules/RulesPresentation.swift`; `Vela/Features/Rules/RulesViewModel.swift`
- **Line/Type:** `RulesPresentationPipeline.process`, lines 286-329
- **Evidence:** Rule filtering/grouping/sorting runs in a detached latest-ticket worker. Prior work is cancelled and joined and worker diagnostics track concurrency. The existing 50,000-rule reliability tests cover an 8.29 MB Controller response, preservation of original indices/order, decode, service refresh, combined type/policy/search filtering, reset to all rows and a MainActor marker. On the 2026-08-19 review host, decode took 198.30 ms, refresh 32.22 ms, filtering 357.34 ms, reset 146.95 ms and the MainActor marker 0.04 ms.
- **Impact:** The required large-rule scenario has an executable regression budget; current projection work does not monopolize MainActor.
- **Fix:** No production change required. Preserve the existing serial latest-wins pipeline and performance budgets; optimize individual builder stages only if a future measurement regresses.
- **Test:** `RulesServiceTests` covers 50,000-rule decode/refresh/presentation and passes 10/10 focused tests. Existing pipeline tests separately prove cancellation, latest-wins publication and a maximum worker count of one.
- **Status:** Closed; verified with current repository tests and a fresh run.

### PERF-CONFIG-001

- **Severity:** P2
- **File:** `Vela/Features/Configuration/ConfigurationView.swift`; `Vela/Features/Configuration/ConfigurationLiquidGlassWorkbenchView.swift`
- **Line/Type:** preview debounce/analysis cache and file import/export
- **Evidence:** Preview refresh waits 150 ms, cancels superseded generations and rejects analysis for stale YAML. YAML analysis remains detached, de-duplicated in flight and cached with capacity two. Settings transfer and configuration export bytes IO now run on feature-owned serial actors; panel presentation and result mutation remain on MainActor.
- **Impact:** Editing computation and user document IO are both bounded away from the UI actor without changing validation or transaction ownership.
- **Fix:** Added `SettingsTransferFileCoordinator` and `ConfigurationExportWriter`, retained atomic writes, and made exported documents private (`0600`). The settings view owns, cancels and generation-guards the transfer task.
- **Test:** 13 focused tests pass, including real-file settings round-trip, file-based oversize rejection and an approximately 8 MB YAML export with a MainActor marker under the 250 ms budget.
- **Status:** Closed; fixed and verified.

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
- **File:** telemetry/log buffers and `RuntimeControllerRouter`, Overview traffic history, SceneStore, proxy delay cache, privileged lease events
- **Line/Type:** retained state and AsyncStream buffering
- **Evidence:** Major long-lived collections are bounded or replace current snapshots. Proxy delay state is reset on catalog/profile/runtime changes. Long-lived streams use bounded newest buffering; `PrivilegedLeaseCoordinator.events()` retains the newest eight events, routed logs retain the configured log capacity and routed traffic retains only the newest sample while preserving termination cleanup.
- **Impact:** No major application history leak was found. A stalled low-frequency lease subscriber is now bounded as well.
- **Fix:** Completed without changing lease authority or IPC contracts.
- **Test:** `PrivilegedLeaseCoordinatorTests` proves a stalled subscriber receives exactly the newest bounded suffix; `RuntimeControllerRouterTests.trafficRoutingKeepsNewestSample` proves the routed traffic bridge cannot accumulate a stale burst.
- **Status:** Closed.

## Performance conclusion

Connections exceeds the requested 1k/5k validation with a 10k latest-wins pipeline and explicit MainActor/worker assertions. Logs and Proxies now use serial latest-wins presentation workers; Rules has a verified 50,000-rule budget; Configuration uses bounded debounce/cache workers and serial user-document actors. EngineStore runtime fingerprint IO, import staging cleanup, Core download workspace IO and streamed download transfer are off MainActor. The remaining evidence-backed priority is therefore measurement before further extraction: instrument Observation invalidation and the residual O(n) Proxies delay-state capture rather than introducing a broad architecture rewrite. All reviewed retained data and long-lived routing queues are bounded; signed Core downloads additionally enforce finite role size, exact length and digest integrity without using a lossy stream policy.
