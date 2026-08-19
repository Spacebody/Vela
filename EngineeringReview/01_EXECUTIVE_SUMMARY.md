# Executive Summary

Status: audit in progress. This report intentionally does not reuse the older `c063aa8` review as proof for the current public `main` snapshot.

## Current baseline

- Branch/commit: `main` / `1aece344b57c7ce660206eb49772b686d923208b`.
- Swift source volume: 171,535 lines including tests and harnesses.
- Largest production file: `Vela/Core/Engine/EngineStore.swift`, 7,760 lines.
- Largest production workflow type: `CoreLifecycleController`, 2,408-line type body.
- Largest composition function: `AppEnvironment.live()`, 559 lines.
- Hardening workflow-pin validation passes.
- Hardening architecture freeze is stale and currently makes 5 of 28 Hardening tests fail.

## Initial risk assessment

No new P0 is asserted at this stage. The first confirmed release-engineering finding is that `main` cannot pass its own architecture-freeze gate. Because the semantic manifest fields did not change, this looks like an unreviewed source-surface drift rather than proof of a new privilege or endpoint; it remains a release-blocking Hardening inconsistency until resolved through the existing ADR process.

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
- **Evidence:** source generation produces `scannedFileCount = 306` instead of 295 and new discovery hashes. `validate_hardening_config.py` fails with `architecture baseline is stale`; 5 Hardening tests fail for the same prerequisite.
- **Impact:** current `main` cannot satisfy the repository's mandatory Hardening source gate. Blindly updating hashes would bypass the intended Security/Release review.
- **Fix:** identify the 11 newly scanned production files and their security signals, confirm no unintended attack-surface change, then generate manifests and add a matching ADR with exact canonical hashes and owners.
- **Test:** all three documented Hardening commands plus deterministic generator test.
- **Status:** Open; evidence collection in progress.

## Next audit stage

The next stage completes the Engine/Core lifecycle, privileged boundary, System Proxy/TUN, configuration transaction, Task/AsyncStream/resource, performance, feature-coupling, and test-gap reviews before selecting the first production-code change.
