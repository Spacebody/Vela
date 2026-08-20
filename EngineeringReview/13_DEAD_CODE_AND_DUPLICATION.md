# Dead Code and Duplicate Logic Audit

Audit date: 2026-08-19
Scope: current `main`, production targets, test targets, visual harnesses, release scripts, and the review artifacts themselves.

## Findings

### DEAD-001

- **Severity:** P3
- **File:** `EngineeringReview/`
- **Line/Type:** legacy review artifact set
- **Evidence:** The repository contains an older parallel sequence (`02_P0_P1_FINDINGS.md` through `11_FINAL_REPORT.md`) beside the evidence-oriented `00_ARCHITECTURE_MAP.md` through `15_FINAL_REPORT.md` sequence requested by this review. The two sets describe overlapping findings and create two possible sources of review truth.
- **Impact:** Maintainers can update one report set while readers consume the other, producing review drift rather than executable product risk.
- **Fix:** Keep one canonical 00–15 review sequence. Merge still-relevant evidence from the legacy files before removing only the redundant artifacts.
- **Test:** Review-document link check and `git diff --check`.
- **Status:** Closed. Relevant evidence was merged into the canonical 00–15 sequence and the ignored local parallel report set was removed.

### DEAD-002

- **Severity:** P3
- **File:** `Vela/Features/Overview/OverviewView.swift`; `Vela/Features/Settings/TunFlowPresentation.swift`; `Vela/Features/Settings/TunOnboardingView.swift`
- **Line/Type:** suspected old feature code
- **Evidence:** CodeGraph resolves `OverviewView` to `ContentView`, `TunOnboardingView` to both Overview and Settings, and `TunFlowPresentation` to the active TUN onboarding flow. `OverviewRecoveryAction` also participates in the current Overview snapshot/recovery projection.
- **Impact:** Deleting these files based on naming or size would remove active behavior.
- **Fix:** No deletion. Require target membership, dynamic-reference, test, script, and CodeGraph caller proof before future removals.
- **Test:** Existing Overview/TUN presentation tests plus full target build.
- **Status:** Verified active; not dead code.

### DEAD-003

- **Severity:** P3
- **File:** `Vela/Visual/`; `script/visual_capture_helper.swift`; release documentation scripts
- **Line/Type:** debug and visual-fixture infrastructure
- **Evidence:** CodeGraph links visual fixtures and helper types to debug visual-test presentation, capture helpers, and release-documentation generation. These are build/test/release inputs rather than unreachable application features.
- **Impact:** Treating non-runtime code as dead would break deterministic visual verification and release documentation.
- **Fix:** Retain while referenced by targets or scripts; keep production target membership narrow.
- **Test:** Visual harness build and existing release-script validation.
- **Status:** Verified infrastructure; not dead code.

### DUP-001

- **Severity:** P2
- **File:** `Vela/Features/Overview/OverviewView.swift`; `Vela/Features/Connections/ConnectionsPresentationPipeline.swift`; `Vela/Features/Settings/TunOnboardingView.swift`; `Vela/Features/Configuration/ConfigurationLiquidGlassWorkbenchView.swift`; support-bundle code
- **Line/Type:** byte-count presentation
- **Evidence:** Multiple feature and support paths independently construct or call `ByteCountFormatter`; Configuration Workbench also wraps it in a local `formattedBytes` helper. These are presentation variants of the same byte-unit rule.
- **Impact:** Unit style, zero handling, localization, and decimal precision can drift between pages and exported diagnostics.
- **Fix:** Introduce one internal authoritative byte-formatting utility only when the affected surfaces are modified together. Preserve context-specific style parameters rather than forcing one literal string format.
- **Test:** Table-driven formatter tests for zero, KiB/MiB/GiB, locale, and unknown values; existing snapshot tests.
- **Status:** Accepted bounded variation. The call sites use different zero/unknown and export/UI policies, and this review found no contradictory domain value. Consolidate behind an internal parameterized utility only when those surfaces are changed together and table-driven tests can preserve every contract.

### DUP-002

- **Severity:** P2
- **File:** `Vela/Features/Proxies/ProxiesLiquidGlassDashboardView.swift:1380`; shared latency presentation components
- **Line/Type:** latency text, semantic color, and signal-strength mapping
- **Evidence:** `ProxiesLiquidGlassDashboardView` locally maps `ProxiesLatencySnapshot` to text (`ms`, testing, failed), color, and signal strength, while the shared design system already exposes latency state/badge presentation used by other proxy surfaces.
- **Impact:** The same latency state may receive different wording or semantics across the proxy dashboard, inspector, and reusable badge.
- **Fix:** Move the domain-to-presentation mapping into one internal latency presentation model; keep layout in the feature view. Do not widen public API.
- **Test:** Unit tests over every `VelaLatencyState` and UI snapshot coverage for testing/failed/unknown values.
- **Status:** Closed. `ProxyLatencyPresentation` now owns latency text and signal-strength mapping, while semantic color delegates to the shared `VelaLatencyState.status` design-system contract. The dashboard retains layout only, no public API was widened, and exhaustive state tests cover text and signal mapping.

### DUP-003

- **Severity:** P3
- **File:** `Vela/Core/Engine/MihomoMode.swift`; Overview/Rules/Settings presentation strings
- **Line/Type:** route-mode representation
- **Evidence:** CodeGraph finds one authoritative domain enum, `MihomoMode`, used by controller, scenes, updates, Core snapshots, EngineStore, and tests. Feature code supplies localized display titles but does not define a second mutation enum.
- **Impact:** No correctness defect is currently proven. Collapsing localized display concerns into the domain enum would increase coupling.
- **Fix:** Retain the existing separation; consolidate only if a second domain conversion is introduced.
- **Test:** Existing mode mutation and localization tests.
- **Status:** Verified single domain source; no change.

### DEAD-004

- **Severity:** P3
- **File:** repository-wide production Swift sources
- **Line/Type:** deletion eligibility
- **Evidence:** The CodeGraph dead-code survey did not identify a production feature file with zero target/script/test/dynamic references that can be safely removed from current evidence alone.
- **Impact:** Speculative deletion would create regression risk without measurable maintainability gain.
- **Fix:** Do not delete production code merely because a file is large, old-looking, or debug-only. Re-run the proof after architectural extractions reduce indirection.
- **Test:** Target membership inspection, CodeGraph caller graph, scripts/contracts search, full build/tests.
- **Status:** No proven production deletion candidate in this audit pass.

## Access-Control Review

The default visibility policy remains `private` → `fileprivate` → `internal` → `public`. Cross-target contracts in `VelaIPC` and privileged modules are legitimate exceptions. Visibility tightening is intentionally deferred until the corresponding owner extraction because changing access while ownership is still broad produces churn without reducing runtime risk.

## Dependency Review

| Dependency | Evidence of use | Decision |
|---|---|---|
| Yams 6.2.2 | Configuration parsing, YAML document analysis and privileged configuration sanitization | Retain. Foundation has no equivalent mature YAML parser; replacement would enlarge risk around imported configuration and validation. |
| Sparkle 2.9.4 | `UpdateController`, update settings and release/appcast tooling | Retain. It is part of the existing update/release contract; replacing it would duplicate mature signing/update behavior. |
| Local `VelaIPC` / `VelaPrivilegedCore` packages | Frozen XPC schema, privileged Core store, path and trust verification | Retain. These are intentional cross-target contracts rather than third-party debt. |

No unused external package was proven. The project pins exact package versions and the release tooling verifies third-party notices/SBOM inputs.

## CI Review

The nine workflow files pass the repository's full-SHA action-pin validator. Apparent overlap is intentional: PR feedback, Hardening source/release gates, nightly coverage, CodeQL, dependency review, secret scanning and release evidence have different trust or timing boundaries. No security job was removed or weakened. The current opportunity is cache/runtime measurement, not merging gates whose evidence has different consumers.

## Safe Cleanup Order

1. Close correctness and lifecycle proof gaps.
2. Consolidate latency presentation as a bounded proxy-feature change only when the feature is next modified.
3. Consolidate byte formatting with table-driven tests only when multiple affected surfaces are changed together.
4. Re-run CodeGraph, target membership, scripts/contracts, build, and tests before deleting any newly orphaned code.
