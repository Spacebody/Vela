# Refactor Plan

This plan is intentionally a Strangler Refactor, not a rewrite. Every batch keeps the existing facade/public contract, uses the current domain owner, runs impact analysis before symbol edits and ends with focused tests, regression gates, an unsigned build and `detect_changes()`.

## Completed correctness batches

### P0

No P0 defect was reproduced.

### P1 lifecycle and durable state

1. Await Core runtime-mutation lease release at the public async boundary.
2. Canonicalize Core activation-journal verification against the exact persisted bytes.
3. Preserve prepended rules during legacy structured-profile migration.
4. Keep rollback/manual-repair state durable when rollback itself fails.
5. Diagnose terminal update-journal persistence failure without weakening fail-closed state.

Exit criteria: focused fault/cancellation tests, Hardening gates and build passed. Completed.

## Completed bounded performance and lifecycle batches

1. Move proven EngineStore filesystem read/hash and profile-staging cleanup off MainActor through existing owners.
2. Move Core download workspace IO/stream transfer behind the existing concurrent downloader.
3. Bound privileged lease and routed telemetry stream buffers.
4. Use serial latest-wins projection pipelines for Logs, Proxies, Rules and Connections where scale tests proved the boundary.
5. Move Configuration user-document IO behind feature-owned serial actors; preserve atomic/private writes.
6. Complete EngineStore synchronous deinit cancellation/continuation fallback while retaining explicit async termination as authority.

Exit criteria: focused concurrency/performance suites and current unsigned Debug/Release build passed. Completed.

## Next batch A — privileged integration evidence

Scope:

- System Proxy enable → verify → restore, partial failure and external modification.
- TUN start → lease active → Controller ready → stop → cleanup proof.
- helper crash, lease expiry, sleep/wake and stop timeout.

Constraints:

- Reuse `VelaPrivilegedIntegrationTests` and existing `FaultInjection`.
- Run only on an explicitly authorized signed helper-capable host.
- Snapshot and restore the exact macOS network service; do not run in ordinary unit CI.

Exit criterion: every mutation ends in verified applied or verified restored state, with no ambiguous half-configured network state.

## Next batch B — production composition proof

Scope:

- AppEnvironment configuration apply → restart → Controller/health proof → previous-state restore.
- Core probation degradation after initial health and production-adapter runtime snapshot restore.
- malformed/stale Controller event during restart and profile switch.

Constraints:

- Exercise the current coordinators and adapters; do not add a parallel integration framework.
- Keep Controller connectivity distinct from engine-running and traffic-takeover state.

Exit criterion: fault-injected composition tests prove ordering and durable rollback across the real dependency assembly.

## Next batch C — measurement before EngineStore extraction

Measure:

- Observation/body/projection counts during traffic bursts and log batches.
- unrelated-page recomputation during proxy delay and health updates.
- residual O(n) proxy-delay snapshot capture on 10k candidates.

Decision rule:

- If a measured high-rate field causes material unrelated work, extract only that feature projection behind its existing service/pipeline and keep EngineStore as a facade.
- If measurements are within budget, do not split for file-size aesthetics.

Preferred extraction candidates, in dependency order:

1. proxy delay presentation projection;
2. health presentation projection;
3. update-recovery presentation;
4. scene runtime transaction facade;
5. profile mutation transaction facade.

Logs already have a bounded buffer and feature projection pipeline, so another log owner is not currently justified.

## Next batch D — bounded maintainability cleanup

1. Consolidate latency domain-to-presentation mapping inside the proxy feature with exhaustive state tests.
2. Consider a parameterized internal byte formatter only during a coordinated multi-surface edit.
3. Tighten access control only after an ownership extraction makes the correct boundary explicit.
4. Re-run CodeGraph, target membership, scripts/contracts and tests before deleting newly orphaned production code.

## Permanent guardrails

- Preserve `RuntimeMutationGate`, `EngineTransitionCoordinator`, configuration journals, system-network ownership/recovery, helper lease/session checks and the frozen IPC schema.
- Do not make System Proxy and TUN mutually exclusive.
- Do not make static profiles, rules or proxy catalog presentation depend on Controller connectivity.
- Do not perform expensive IO/parsing on MainActor solely for caller convenience.
- Do not add fire-and-forget mutation tasks or default-unbounded long-lived streams.
- Do not weaken Hardening, release fail-closed values, signature/hash verification, path protections or log redaction.
- No signing, installation or privileged mutation without explicit user authorization.
