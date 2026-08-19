# Feature and UI Architecture Audit

Review baseline: `main` at `9454542`. This audit covers the app shell and the Overview, Proxies, Connections, Rules, Configuration Workbench, Logs and Settings features. It distinguishes verified ownership/cancellation mechanisms from measured or code-proven debt; file size alone is not treated as a defect.

## Feature ownership map

| Feature | UI-facing owner | Expensive projection / IO owner | Lifecycle boundary |
|---|---|---|---|
| Overview | `OverviewView` local state plus `EngineStore` facade | `OverviewProxySnapshotCache`; shared connection snapshot source | `onAppear`/`onDisappear` activates and deactivates the connection consumer |
| Proxies | `ProxiesView` local selection and `EngineStore` facade | serial latest-wins `ProxiesPresentationPipeline`; factory remains pure | page tasks follow profile/catalog revision; engine owns request tasks |
| Connections | dedicated `ConnectionsViewModel` | `ConnectionsPresentationPipeline` actor with one detached worker | explicit `.connectionsPage` / `.overviewPage` consumers own the stream |
| Rules | dedicated `RulesViewModel` | `RulesPresentationPipeline` actor with one detached worker | model cancels superseded search/projection work |
| Configuration Workbench | `ConfigurationView` and `ConfigurationEditorViewModel` | configuration actors plus `ConfigurationWorkbenchYAMLAnalysisCache` | 150 ms cancellable preview task with stale-YAML rejection |
| Logs | `LogsView` local filter/pause/selection state plus `EngineStore.logEntries` | revision-keyed, serial latest-wins presentation actor; export actor | SwiftUI owns/cancels presentation and export tasks on page disappearance |
| Settings | `SettingsPreferencesStore` plus engine/update/data stores | engine services; transient cleanup uses detached utility work | operation state/failure is retained by the page; transfer panels are user-owned modal actions |

## Findings

### UI-LOGS-001

- **Severity:** P2 performance and maintainability risk
- **File:** `Vela/Features/Logs/LogsView.swift`
- **Line/Type:** `LogsView.snapshot`, lines 18-35; `clearInvalidSelection`, lines 110-115; `export`, lines 124-145
- **Evidence:** The original computed `snapshot` was evaluated from the live log array by body, selection validation and export. `LogsPresentationSnapshot.init` maps every entry, filters every row and groups/scans identities. The buffer is bounded to 2,000 entries, but the repeated O(n) work ran on the SwiftUI/MainActor path.
- **Impact:** High-frequency log batches or unrelated view-state changes can repeat formatting/filtering work and increase UI CPU even though storage remains bounded.
- **Fix:** Introduce a narrow logs presentation projection/cache owned by the Logs feature. Recompute only when the log revision or filter changes, preserve `LogBuffer` as the authoritative redacted store, and keep export on the existing actor. Do not add a second log store or sanitizer.
- **Test:** Retain the 1k/10k snapshot and 2,000-entry high-frequency tests; add a projection-revision test proving unchanged rows are not rebuilt for inspector/hover state changes and verify MainActor latency during sustained batches.
- **Status:** Fixed and verified. `LogsView` now derives an O(1) revision from immutable buffer endpoints and filter/runtime state, while a feature-owned actor cancels and joins superseded `@concurrent` projection workers. EngineStore remains authoritative, pause/export snapshots remain immutable, and the redaction path is unchanged. Tests prove 10k behavior, rapid latest-wins serialization with at most one worker, and MainActor responsiveness during a 50k projection.

### UI-PROXY-001

- **Severity:** P2 performance risk
- **File:** `Vela/Features/Proxies/ProxiesView.swift`
- **Line/Type:** `snapshot` and `delayStates`, lines 35-62
- **Evidence:** The original computed snapshot walked every group/node to query delay state, created a new dictionary, then called `ProxiesPresentationFactory.make`, which maps the catalog into all group and node presentation rows. The 100-group/10,000-candidate characterization measured 100 full projections in 7.105 seconds (about 71 ms each) on the test host. Delay testing itself is bounded and cancellation-aware; the issue was projection placement, not network fan-out.
- **Impact:** Large subscriptions and frequent delay-state updates can cause repeated full-catalog work and visible selection/test latency.
- **Fix:** Added a feature-owned, serial latest-wins projection actor. `ProxiesView` captures an immutable request from EngineStore truth, expensive factory work runs in an `@concurrent` worker, superseded work is cancelled and joined, and only the newest ticket can publish. The snapshot contract, selection semantics, delay request concurrency and EngineStore authority are unchanged.
- **Test:** Existing 10,000-candidate characterization remains as a regression baseline. New tests prove rapid large-to-small replacement publishes only the newest catalog, maximum concurrent workers stays one, and a 10,000-candidate projection does not monopolize MainActor.
- **Status:** Fixed and verified. Delay-state capture now builds group membership once and projects the cache in O(catalog + cache) time; the 10,000-entry characterization remains below its 250 ms budget. Incremental replacement is not warranted without production profiling evidence.

### UI-FEATURE-001

- **Severity:** Reviewed architecture boundary (finding withdrawn)
- **File:** `Vela/App/ContentView.swift`; `Vela/Features/Overview/OverviewView.swift`; `Vela/App/DailyDriverFeatureHub.swift`
- **Line/Type:** `ContentView.destination`, lines 158-168; `OverviewConnectionsSource`, lines 4-25
- **Evidence:** The deeper dependency review confirms that `OverviewView` neither imports nor holds `ConnectionsViewModel`, and never reads Connections row, selection, filter, inspector or mutation state. The App composition root adapts the one application-owned Connections runtime consumer into a four-operation `OverviewConnectionsSource` (`snapshot`, `refresh`, `activate`, `deactivate`). The model's private `StreamConsumer` set is the authoritative ownership boundary for the shared websocket and deliberately distinguishes `.connectionsPage` from `.overviewPage`.
- **Impact:** There is no Feature A View → Feature B ViewModel dependency in the feature layer. Moving the stream solely to satisfy a nominal layer rule would modify the CRITICAL `DailyDriverFeatureHub` dependency hub, duplicate lifecycle machinery, or create a second websocket without removing a demonstrated correctness defect.
- **Fix:** Preserve the narrow source at the composition root. Treat the raw `ConnectionsSnapshot` plus acquire/release lifecycle as the shared-domain projection contract; do not expose the page model to Overview and do not split the proven single-stream owner absent a reproduced lifecycle or performance defect.
- **Test:** `ConnectionsServiceTests.overlappingConsumersShareOneStream` proves Overview and Connections share one stream, an intermediate consumer departure keeps it alive, and the final departure closes it. Overview snapshot tests separately prove the raw runtime snapshot is projected without depending on Connections presentation state.
- **Status:** Closed after dependency analysis; the original P2 classification was a false positive. GitNexus reports `DailyDriverFeatureHub` as CRITICAL (458 direct dependents), so speculative extraction would be materially riskier than the current narrow composition-root adapter.

### UI-CONFIG-001

- **Severity:** P2 MainActor responsiveness risk
- **File:** `Vela/Features/Configuration/ConfigurationView.swift`; `Vela/Features/Configuration/ConfigurationLiquidGlassWorkbenchView.swift`; `Vela/Features/Settings/SettingsLiquidGlassView.swift`
- **Line/Type:** Workbench preview/export actions; settings transfer `performExport`/`performImport`, approximately lines 660-705
- **Evidence:** Workbench analysis remains debounced by 150 ms, runs through the detached analysis cache and rejects stale YAML. Settings transfer encoding/decoding plus bytes IO now runs through the feature-owned `SettingsTransferFileCoordinator` actor. Configuration YAML export runs through `ConfigurationExportWriter`. AppKit panels and UI-facing result commits remain on MainActor; the settings task has an explicit view owner, cancellation and generation guard.
- **Impact:** User-selected document IO no longer blocks MainActor. The existing validation, settings commit compensation and configuration transaction contracts are unchanged.
- **Fix:** Completed with two domain-specific serial actors rather than a cross-feature generic manager. Both outputs use atomic writes and `0600` permissions because exported settings/configuration may contain sensitive remote or proxy material.
- **Test:** Settings backup round-trip and the 1 MiB rejection path pass from real files. An approximately 8 MB configuration export preserves UTF-8 and records a MainActor scheduling marker below 250 ms (37 ms total test runtime on the review host). All 13 focused tests pass.
- **Status:** Fixed and verified.

### UI-TASK-001

- **Severity:** Verified mechanism
- **File:** `Vela/App/DailyDriverFeatureHub.swift`; `Vela/Core/Connections/ConnectionsPresentationPipeline.swift`; `Vela/Features/Rules/RulesPresentation.swift`; `Vela/Features/Configuration/ConfigurationView.swift`
- **Line/Type:** connection consumers/presentation pipeline, rules pipeline, preview generation
- **Evidence:** Connections tracks visible Overview/Connections consumers, cancels stream/restart/filter work when none remain, and serializes detached projection workers. Rules cancels and joins the prior detached worker before publishing the newest ticket. Configuration cancels superseded preview tasks and rejects stale YAML. These tasks have explicit owners and terminal conditions.
- **Impact:** Sidebar navigation and rapid filter/editor changes do not create unbounded background mutation tasks in these paths.
- **Fix:** Preserve these patterns. New feature-owned tasks must be stored/cancelled or attached to SwiftUI `.task(id:)`; engine mutation tasks must remain owned by the engine/coordinator.
- **Test:** Existing Connections 10k/churn/worker-count tests, Rules pipeline diagnostics, and Workbench cache/in-flight tests.
- **Status:** No defect found in the reviewed paths.

### UI-SETTINGS-001

- **Severity:** Verified mechanism with a P2 consistency follow-up
- **File:** `Vela/Features/Settings/SettingsView.swift`; `Vela/Features/Settings/SettingsLiquidGlassView.swift`
- **Line/Type:** `setTun`, `performTunChange`, `performIPv6Change`, `clearTransientData`
- **Evidence:** TUN changes await engine verification and publish failure; IPv6 uses a guarded operation and restores the previous preference on failure; transient cleanup runs in detached utility work. System Proxy delegates to the engine's serialized request task/operation state. Settings import validates, checks runtime/update barriers, commits all values, verifies read-back and compensates if commit proof fails. Settings transfer file IO is serialized off MainActor and the view cancels its owned transfer task when it disappears.
- **Impact:** Dangerous toggles are not implemented as bare optimistic preference writes. Operation feedback and rollback behavior exist.
- **Fix:** Preserve the operation-state path. In a later UI pass, surface applying/verified/rollback states consistently without changing the native-switch interaction workaround.
- **Test:** Existing Settings snapshot/transfer/TUN feedback tests plus system network suites.
- **Status:** No P0/P1 defect found.

### UI-ACCESS-001

- **Severity:** P2 accessibility defect and verification gap
- **File:** Overview, Proxies, Connections, Rules, Logs, Configuration and Settings feature views
- **Line/Type:** critical controls and row presentation
- **Evidence:** The reviewed views include explicit accessibility identifiers/labels for many states and rows, Logs builds complete row labels, and animated feature views read Reduce Motion in several key surfaces. One concrete defect remained: the Proxies node row was activated only by `onTapGesture`, so it had no button trait, default assistive action, focus target or Return/Space keyboard path. Configuration Apply already had a stable identifier but no explicit state-aware accessible label.
- **Impact:** Keyboard and VoiceOver users could inspect a proxy row without having a reliable semantic activation path, and an applying Configuration action did not announce its current operation state explicitly. Visual refactors also lacked one compact regression contract covering the existing Overview, Logs and Reduce Motion semantics.
- **Fix:** Keep the existing pointer gesture and selection transaction, but expose the proxy row as a semantic button with selected state, default accessibility action, focusability and Return/Space activation. Give Configuration Apply an explicit state-aware label. Add a focused source-contract suite covering these fixes and the already-established Overview, Logs and Reduce Motion contracts; do not introduce duplicate visible labels or a second interaction implementation.
- **Test:** `CriticalControlsAccessibilityTests` verifies stateful Overview network/route semantics, pointer/assistive/keyboard proxy activation, Logs/Configuration discoverability and Reduce Motion adoption on the daily-driver pages. A clean independent-DerivedData build completed with no Swift compile error. Isolated `xcodebuild test` attempts either stalled before worker materialization or started the first test and then wedged in the host-session/cleanup path (`waiting for workers to materialize` / `Waiting for -runningDidFinish`). The same source read completes in under one millisecond outside XCTest and the result bundle contains no assertion failure. Runtime completion is therefore environment-blocked rather than reported as passing.
- **Status:** Concrete proxy/configuration defects fixed; compact regression suite added and compiled. Runtime execution of that suite remains pending after the local Xcode test-host infrastructure is healthy.

## Feature audit conclusion

No new P0/P1 implementation defect was reproduced in the feature layer. The strongest existing boundaries are the Connections/Rules/Logs single-worker pipelines, the Configuration Workbench debounce/cache/stale-result guards, bounded/redacted Logs storage and operation-aware Settings mutations. Proxy delay capture is now linear and budget-tested. The remaining verification item is runtime completion of the critical-control accessibility contract after the local Xcode test service can execute and clean up a stable host session. The shared Connections runtime consumer is already exposed to Overview through a narrow composition-root projection and should not be moved absent a reproduced defect.
