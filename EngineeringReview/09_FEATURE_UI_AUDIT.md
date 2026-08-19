# Feature and UI Architecture Audit

Review baseline: `main` at `9454542`. This audit covers the app shell and the Overview, Proxies, Connections, Rules, Configuration Workbench, Logs and Settings features. It distinguishes verified ownership/cancellation mechanisms from measured or code-proven debt; file size alone is not treated as a defect.

## Feature ownership map

| Feature | UI-facing owner | Expensive projection / IO owner | Lifecycle boundary |
|---|---|---|---|
| Overview | `OverviewView` local state plus `EngineStore` facade | `OverviewProxySnapshotCache`; shared connection snapshot source | `onAppear`/`onDisappear` activates and deactivates the connection consumer |
| Proxies | `ProxiesView` local selection and `EngineStore` facade | `ProxiesPresentationFactory` currently called from the view | page tasks follow profile/catalog generation; engine owns request tasks |
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
- **Evidence:** Every snapshot construction walks every group/node to query delay state, creates a new dictionary, then calls `ProxiesPresentationFactory.make`, which maps the catalog into all group and node presentation rows. This work is performed from the SwiftUI view on MainActor. Delay testing itself is bounded and cancellation-aware; the issue is projection placement, not network fan-out.
- **Impact:** Large subscriptions and frequent delay-state updates can cause repeated full-catalog work and visible selection/test latency.
- **Fix:** Add a Proxies feature projection pipeline or revision-keyed cache using the existing catalog generation and delay revision. Preserve `EngineStore` as the temporary facade and existing request/cancellation semantics. Measure before deciding whether a dedicated observable projection is necessary.
- **Test:** Characterize 100, 1,000 and 10,000 candidate-node catalogs; verify one delay update does not rebuild unrelated groups and that stale projection results never replace a newer catalog.
- **Status:** Open P2.

### UI-FEATURE-001

- **Severity:** P2 architecture debt
- **File:** `Vela/App/ContentView.swift`; `Vela/Features/Overview/OverviewView.swift`; `Vela/App/DailyDriverFeatureHub.swift`
- **Line/Type:** `ContentView.destination`, lines 158-168; `OverviewConnectionsSource`, lines 4-25
- **Evidence:** Overview does not consume Connections rows or selection/filter UI state; it receives a narrow closure-based source exposing only the raw `ConnectionsSnapshot` and activation lifecycle. However, the closures are backed by the Connections feature's `ConnectionsViewModel`, so the Connections page model currently owns the shared stream used by Overview.
- **Impact:** This is much safer than Feature A reading Feature B presentation state, but stream ownership and page presentation ownership remain coupled. Refactoring or destroying the Connections feature model can affect Overview data availability.
- **Fix:** Move the raw snapshot/consumer lifecycle contract to a shared domain-level connection snapshot source or service. Keep both feature models as consumers; do not duplicate the websocket stream and do not expose the Connections UI model publicly.
- **Test:** Overview-only navigation starts exactly one stream consumer, Connections/Overview overlap still uses one stream, and both consumers disappearing cancels it.
- **Status:** Open P2; no current incorrect data path reproduced.

### UI-CONFIG-001

- **Severity:** P2 MainActor responsiveness risk
- **File:** `Vela/Features/Configuration/ConfigurationView.swift`; `Vela/Features/Configuration/ConfigurationLiquidGlassWorkbenchView.swift`; `Vela/Features/Settings/SettingsLiquidGlassView.swift`
- **Line/Type:** Workbench preview/export actions; settings transfer `performExport`/`performImport`, approximately lines 660-705
- **Evidence:** Workbench analysis is correctly debounced by 150 ms, performed through a detached analysis cache, and guarded against stale YAML. Some user-initiated save/import/export paths still perform `Data(contentsOf:)` or atomic `Data.write` synchronously after a modal panel returns. These are bounded by settings document size for settings transfer, but configuration YAML can be materially larger.
- **Impact:** Large imported/exported documents can briefly block the MainActor without compromising transaction safety.
- **Fix:** Keep AppKit panels and state mutation on MainActor, but move file read/write to an existing bounded IO actor/helper and return immutable `Data`/result values. Do not bypass configuration validation, atomic persistence or transaction coordinators.
- **Test:** Import/export a maximum supported document while probing MainActor latency; cancellation/error leaves no partial destination and surfaces a redacted operation error.
- **Status:** Open P2; no data-loss path found.

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
- **Evidence:** TUN changes await engine verification and publish failure; IPv6 uses a guarded operation and restores the previous preference on failure; transient cleanup runs in detached utility work. System Proxy delegates to the engine's serialized request task/operation state. Settings import validates, checks runtime/update barriers, commits all values, verifies read-back and compensates if commit proof fails. The remaining synchronous settings import/export IO is addressed by `UI-CONFIG-001`.
- **Impact:** Dangerous toggles are not implemented as bare optimistic preference writes. Operation feedback and rollback behavior exist.
- **Fix:** Preserve the operation-state path. In a later UI pass, surface applying/verified/rollback states consistently without changing the native-switch interaction workaround.
- **Test:** Existing Settings snapshot/transfer/TUN feedback tests plus system network suites.
- **Status:** No P0/P1 defect found.

### UI-ACCESS-001

- **Severity:** P2 verification gap
- **File:** Overview, Proxies, Connections, Rules, Logs, Configuration and Settings feature views
- **Line/Type:** critical controls and row presentation
- **Evidence:** The reviewed views include explicit accessibility identifiers/labels for many states and rows, Logs builds complete row labels, and animated feature views read Reduce Motion in several key surfaces. There is no single automated matrix proving labels, keyboard focus and reduced-motion behavior for every critical System Proxy, TUN, mode, node selection, log filter and Configuration Apply action.
- **Impact:** A visual refactor can regress keyboard/VoiceOver semantics without failing domain tests.
- **Fix:** Add targeted accessibility UI/harness assertions for critical actions. Reuse semantic controls and existing visual harness; do not add duplicate visual-only labels.
- **Test:** VoiceOver labels/values, keyboard activation/focus order, Escape/cancel behavior, and Reduce Motion snapshots for critical workflows.
- **Status:** Open verification gap, not evidence that all listed controls are inaccessible.

## Feature audit conclusion

No new P0/P1 implementation defect was reproduced in the feature layer. The strongest existing boundaries are the Connections/Rules/Logs single-worker pipelines, the Configuration Workbench debounce/cache/stale-result guards, bounded/redacted Logs storage and operation-aware Settings mutations. The remaining highest-value feature refactors are a narrow Proxies projection and moving shared connection stream ownership below the Connections page model. These are strangler changes after correctness coverage, not reasons to rewrite the views wholesale.
