# Final Engineering Review Report

Review baseline: public `main` through `693158b7cc2e`, plus the final canonical review-document and generated Release Candidate baseline reconciliation.

## Scope

The review covered application composition and routing, Engine/Core lifecycle, MainActor placement, Observation scope, feature state and SwiftUI ownership, privileged XPC/helper/TUN boundaries, System Proxy safety, configuration transactions, Core update/recovery, Controller APIs, persistence, logging/privacy, tasks/streams/process resources, performance, localization/accessibility, dependencies, CI, tests, dead code and duplicate domain logic.

Evidence came from current repository source, CodeGraph call paths, GitNexus context/impact/change analysis, existing contracts/ADRs, fault-injection suites, Hardening scripts, focused Xcode tests, VelaIPC tests, deterministic scale tests and unsigned Debug/Release builds.

## Severity disposition

| Severity | Current disposition |
|---|---|
| P0 | No known finding. |
| P1 | No untreated finding. Confirmed lifecycle, journal, migration and test-gate defects were fixed and regression-tested. |
| P2 | Remaining items are explicitly documented integration/measurement/refactor candidates; none is a reproduced data-loss, security or lifecycle-authority defect. |
| P3 | Duplicate local review artifacts were removed; speculative production deletion was rejected where active references exist. |

## Principal fixes

1. Closed delayed Core mutation-lease release and canonical durable-journal verification failures.
2. Preserved legacy prepended rules and semantic ordering during migration.
3. Moved proven EngineStore/Core/configuration IO away from MainActor through existing owners.
4. Made update journal persistence failure visible through the existing privacy-safe logging boundary.
5. Bounded privileged lease and routed log/traffic buffering without making signed Core downloads lossy.
6. Added/retained serial latest-wins projection workers and large-data tests for Logs, Connections, Rules, Proxies and Configuration.
7. Completed critical-control accessibility/Reduce Motion source contracts.
8. Reconciled deterministic Release Candidate resources through the existing generator after the reviewed architecture-freeze changes.

## Architecture result

The authoritative mutation route is singular and preserved:

```text
UI / CLI / App Intent / subscription mutation
→ RuntimeMutationGate
→ EngineTransitionCoordinator or RuntimeConfigTransactionCoordinator
→ backend / process / Controller / privileged owner
→ verification or awaited rollback
→ authoritative EngineStore/CoreStore projection
```

`EngineStore` remains a facade rather than a second persistence or privileged owner. `CoreStore` owns durable Core state; `CoreLifecycleController` owns Core workflow; configuration transaction and system-network actors retain their existing authority. No feature-to-feature UI-state ownership violation was found in the final dependency map.

## Security and safety result

- XPC identity, session correlation, timeouts, interruption/invalidation handling and payload limits remain intact.
- Privileged filesystem operations remain descriptor-relative and symlink/path-traversal resistant.
- Core catalogue, download, size, digest, signing identity and promotion checks remain fail closed.
- System Proxy operations retain snapshot/read-back/compare-and-swap rollback and external-modification detection.
- TUN authority remains the helper lease/runtime proof, not a UI toggle or Controller state.
- Configuration writes remain staged, validated, atomic and recoverable; invalid input cannot replace the known-good configuration through the reviewed route.
- User-visible/exported logs continue through the existing redaction policy; no second sanitizer was added.

No known P0/P1 security or system-network corruption path was found.

## Performance and long-run result

- Logs are bounded at 2,000 entries and use a serial latest-wins presentation worker.
- Connections have 10,000-row churn/search budgets and one active presentation worker.
- Rules pass a 50,000-rule decode/refresh/filter/MainActor budget.
- Proxies pass 10,000-candidate projection tests off MainActor; residual delay capture is O(n) and remains measurement-driven work.
- Overview traffic history is bounded at 120 samples; routed traffic retains only the newest pending sample.
- lease, transition, Controller, process and routed telemetry streams declare bounded retention and termination cleanup.
- signed Core downloads are finite by role, lossless, exact-length and digest verified.

## Verification matrix

| Gate | Result |
|---|---|
| `validate_hardening_config.py` | Passed; 12 configuration files. |
| `validate_github_workflows.py` | Passed; 9 workflows use full SHA pins. |
| Hardening Python tests | 30/30 passed. |
| `./script/ci_test.sh --static-only` | Passed; 109 tests, Xcode/Swift tests intentionally skipped. |
| `swift test --package-path VelaIPC` | 127/127 passed. |
| arm64 Debug Xcode build | Passed unsigned. |
| arm64 Release Xcode build | Passed unsigned. |
| Focused implementation regressions | Passed for each committed batch; domain reports record exact suites. |
| Signed application/UI lane | Not rerun in this final pass; signing requires explicit user approval. |
| Installed-helper/native network integration | Not run; requires explicit privileged host authorization. |

Expected release-preparation blockers (feed/public key, production Core distribution/trust/evidence and Developer ID identity) remain deliberately fail closed. They are not hidden or treated as passing release evidence.

## Definition-of-done audit

| Requirement | Result |
|---|---|
| No known P0 / untreated P1 | Met. |
| Single engine lifecycle mutation route | Met for current start/stop/restart/profile/config/Core writers; preserve route matrix for new writers. |
| System Proxy rollback | Met by code/unit/fault evidence; native host matrix remains P2 proof work. |
| TUN/helper lifecycle | Met by static/unit contract; installed-helper crash/lease matrix remains authorization-gated. |
| Config apply no data-loss path | Met for reviewed transaction and recovery implementation. |
| EngineStore/Core lifecycle responsibility convergence | Met through bounded owner moves; no wholesale facade rewrite. |
| MainActor free of identified heavy IO | Met for reproduced hotspots; Observation runtime measurement remains. |
| No feature reads another feature's UI state as authority | Met in reviewed dependency graph. |
| Streams/tasks/process handles bounded and owned | Met for reviewed long-lived paths. |
| Long-run retained data bounded | Met for Logs, Connections snapshots, Traffic, Scenes, update history, proxy cache and streams. |
| Hardening/static gates | Passed. |
| Complete unsigned build | Debug and Release passed. |
| Unit tests | VelaIPC and all focused implementation suites passed; the full signed app-host lane was not rerun without approval. |
| Privileged tests where applicable | Unit/static proof passed; native installed-helper lane is not applicable without an authorized host. |
| No new warning suppression | Met; no suppression was introduced. |

## Known residual risks

1. Native System Proxy/TUN/helper integration proof on a signed host.
2. Production AppEnvironment configuration/Core probation fault composition.
3. Measured Observation invalidation and residual proxy delay capture cost.
4. Accessibility runtime rerun after the local Xcode test-worker service recovers.
5. Production release values and evidence required by the intentionally fail-closed release tooling.

These are tracked in `12_TEST_GAPS.md` and `14_REFACTOR_PLAN.md`. None is represented as completed proof.

## Final disposition

The repository has no known open P0 or untreated P1 after this review. Current unsigned builds, Hardening, static CI, VelaIPC and focused regression gates are green. The review improved real correctness, lifecycle ownership, MainActor placement and long-run buffering while retaining Vela's existing security and recovery architecture. Further structural work should be measurement- or integration-evidence driven, not file-size driven.
