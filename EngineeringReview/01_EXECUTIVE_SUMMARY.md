# Executive Summary

Status: audit in progress. This report intentionally does not reuse the older `c063aa8` review as proof for the current public `main` snapshot.

## Current baseline

- Branch/commit under active review: `main` / `e999591` plus the independently verified probation test/documentation batch described below.
- Swift source volume: 171,535 lines including tests and harnesses.
- Largest production file: `Vela/Core/Engine/EngineStore.swift`, 7,760 lines.
- Largest production workflow type: `CoreLifecycleController`, 2,408-line type body.
- Largest composition function: `AppEnvironment.live()`, 559 lines.
- Hardening configuration and workflow-pin validation pass.
- All 30 Hardening Python tests pass; the architecture freeze is current for this source snapshot.

## Initial risk assessment

No new P0 is asserted at this stage. The previously recorded architecture-freeze mismatch has been reconciled through the repository's existing ADR/baseline process and all documented Hardening commands pass. Confirmed lifecycle P1 defects are being closed before architecture and style work continues.

The primary maintainability and correctness risks under active audit are:

1. `EngineStore` is both a broad observable root and a lifecycle façade. It exposes many unrelated high-frequency projections while also retaining task, transition, lease, recovery, and update orchestration state.
2. `CoreLifecycleController` and `CoreStore` are large and contain workflow, persistence, verification, and presentation responsibilities that require boundary-by-boundary review.
3. `AppEnvironment.live()` is a very large composition function. It correctly centralizes shared instances, so cleanup must not duplicate authoritative services.
4. Large feature views (Rules, Configuration Workbench, Diagnostics, Connections, Proxies, Logs) mix rendering with local coordination. Some already have dedicated pipelines/stores, which should be reused rather than replaced.

## Existing mechanisms to preserve

- `RuntimeMutationGate` as the cross-workflow exclusion boundary.
- `EngineTransitionCoordinator` actor and its cancellation/rollback barrier.
- Runtime configuration journals, staging, validation, verification, and rollback.
- System Proxy recovery/verification ownership.
- Helper protocol/session/lease/payload/signing checks and frozen `VelaIPC` contract.
- Existing redaction policy, FaultInjection framework, Hardening gates, and test targets.

## Review policy

No production symbol will be edited without current impact analysis. HIGH or CRITICAL blast radius will be reported before proceeding. Each implementation batch will remain independently buildable/testable and will end with `detect_changes()` scope review before any commit.

## Confirmed Finding ER-HARD-001

- **ID:** ER-HARD-001
- **Severity:** P1 (release correctness / security-gate integrity)
- **File:** `Hardening/config/architecture-freeze.json:198-204`; `Hardening/config/attack-surface.json:2`
- **Line/Type:** generated architecture baseline
- **Evidence:** the initial review snapshot produced `scannedFileCount = 306` instead of 295 and failed the architecture baseline prerequisite. The reconciled current snapshot passes configuration validation, workflow validation and all 30 Hardening tests.
- **Impact:** while open, the repository could not satisfy its mandatory Hardening source gate. Blind hash regeneration would have bypassed the intended Security/Release review.
- **Fix:** identify the 11 newly scanned production files and their security signals, confirm no unintended attack-surface change, then generate manifests and add a matching ADR with exact canonical hashes and owners.
- **Test:** all three documented Hardening commands plus deterministic generator test.
- **Status:** Closed and verified through the existing baseline/ADR mechanism. `validate_hardening_config.py`, `validate_github_workflows.py .github/workflows`, and the 30-test Hardening unittest suite all pass on the current snapshot.

## Next audit stage

The confirmed Core probation and lifecycle P1 paths are now covered by seven focused controller tests. The first dependency-proven EngineStore strangler batch moved runtime fingerprint IO and profile-import cleanup off MainActor while keeping the façade and contracts intact; the complete 84-test EngineStore suite passes. The next stage continues bounded performance and architecture work without weakening the already-verified privileged, network and configuration contracts.
