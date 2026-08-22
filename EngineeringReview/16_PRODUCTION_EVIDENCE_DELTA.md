# Production Evidence Delta

Date: 2026-08-22  
Canonical current-evidence baseline: `aef42b560b56dcf5a056e6f720d2d0cb33c6d4cc`

## Baselines

- Previous final review: public `main` through `98743c1`, plus the Core activation-preparation batch described by `15_FINAL_REPORT.md`.
- Current local `main`: `aef42b560b56dcf5a056e6f720d2d0cb33c6d4cc`.
- Current `origin/main`: `aef42b560b56dcf5a056e6f720d2d0cb33c6d4cc` when this evidence was closed.
- Commits after `98743c1`:
  - `8b43e5f refactor(core): isolate activation preparation`
  - `d1ed1fa perf: add production evidence harness`
  - `aef42b5 chore: reconcile release evidence baseline`

Historical review reports remain historical. This delta and `19_RELEASE_CLOSURE_REPORT.md` are the canonical entry points for current release evidence.

## Evidence Added Since the Previous Review

1. The production AppEnvironment graph and termination path are exercised by the existing focused Xcode tests.
2. Existing Core lifecycle tests prove late probation degradation rollback, journal retention/cleanup, cancellation, and mutation-lease behavior without adding a second test framework.
3. Actual production SwiftUI page implementations were exercised through the existing isolated visual/performance harness and captured with Instruments-compatible traces.
4. Diagnostics export ownership was rechecked: `DiagnosticsExportWriter` is a stateless serialized IO actor; cancellation remains feature-owned, redaction precedes persistence, writes are atomic, and files are mode `0600`.
5. Explicit unsigned Debug and Release builds now form part of this closure pass.
6. Static CI found a stale generated architecture-freeze digest in the release-candidate baseline. The existing generator updated only that digest, and the resource validator now passes.

## Previous Residual-Risk Disposition

| Previous residual risk | Classification | Current evidence |
|---|---|---|
| Native System Proxy/TUN/helper integration proof on a signed host | `STILL_SIGNED_HOST_GATED` | Not executed. See `18_SIGNED_HOST_EVIDENCE.md`. |
| Native configuration execution and late Core-probation fault composition through the live-services AppEnvironment graph | `CLOSED_BY_TEST_EVIDENCE` | Existing production-graph and Core lifecycle/fault tests pass, including late probation rollback and recovery authority. |
| Full rendered-page Instruments evidence under sustained production telemetry | `CLOSED_BY_CURRENT_SOURCE` | Production views were rendered in the isolated harness and traced. No reproducible sustained bottleneck justified a production refactor. See `17_RENDERED_RUNTIME_EVIDENCE.md`. |
| Accessibility runtime rerun after the local Xcode test-host/session service recovers | `STILL_RUNTIME_EVIDENCE_GATED` | The focused accessibility host stalled for 600.857 seconds before any assertion result. This is not recorded as a pass or product failure. |
| Production release values and evidence required by fail-closed release tooling | `STILL_RELEASE_CONFIGURATION_GATED` | Production trust, legal/privacy, signed/notarized artifacts, provenance, soak and destructive-host matrices remain intentionally open. |

No stale residual item is silently carried forward.

## Diagnostics Export Architectural Rule

`static shared` is permitted only for stateless or serialized utility actors. A globally shared actor must not become the authoritative owner of feature or domain state. `DiagnosticsExportWriter` currently satisfies this rule and required no production-code change.

## Repository-Controlled Findings

- No new P0 was reproduced.
- No new untreated P1 was reproduced.
- No sustained rendered-page performance defect was reproduced.
- No production Swift refactor met the evidence gate.
- The only repository-controlled drift found was the generated architecture-freeze digest; it was reconciled through the existing generator and validator.

## Verification Added in This Pass

- Hardening configuration validation: passed, 12 files.
- GitHub workflow pin validation: passed, 9 workflows.
- Hardening Python tests: 30 passed.
- Static CI: 109 tests passed.
- VelaIPC: 127 tests in 21 suites passed.
- Production AppEnvironment focused proof: passed.
- Core lifecycle focused suite: passed, including late probation rollback.
- Diagnostics export focused suite: 2 passed.
- Unsigned arm64 Debug build: passed.
- Unsigned arm64 Release build: passed.
- Release-candidate resource byte validation: passed.

Signed, notarized, installed-helper and native system-network mutation lanes were not run.
