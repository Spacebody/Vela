# Vela Final Release Qualification

Date: 2026-08-23
Source baseline: `80cc6e490eae65c542d4936cf52c157a3b5bd58d`

## Decision

**NOT YET QUALIFIED FOR RELEASE**

Repository-controlled qualification reproduced no P0. Two full-suite-load evidence failures were characterized: a real P2 final-output capture race received the smallest local synchronization fix, and a P2 test-only Core rollback timing budget was calibrated without production lifecycle changes. A stale UI route test was corrected to current source truth.

Release remains blocked by evidence that cannot be inferred from repository tests:

- exact immutable production-pipeline candidate built with production endpoints/trust inputs and ephemeral credentials (a current-source Developer ID export was accepted by Apple, stapled and Gatekeeper accepted, but remains an integration sample rather than a release-eligible candidate);
- production trust/endpoints/legal/release-readiness inputs;
- signed-host System Proxy and TUN/Helper destructive matrices;
- combined Proxy+TUN transitions;
- repeated sleep/wake and network transitions;
- 24-hour and 72-hour soak;
- healthy-host accessibility runtime;
- previous-version upgrade/migration on the exact candidate.

## Evidence separation

### Repository-controlled correctness

- `./script/ci_test.sh` passed after rerunning outside the restricted sandbox used by the first attempt.
- Hardening validation reports 32 passing tests.
- Static CI reports 109 passing checks.
- VelaIPC reports 127 tests in 21 suites passing.
- Vela Xcode tests report 678 tests in 88 suites passing.
- VelaHelper reports 1 passing test.
- Focused Mihomo/Core suites pass five iterations (95 test executions).
- Focused profile-migration and critical-control accessibility contracts pass 15 tests in 2 suites.
- Four isolated rendered UI accessibility scenarios pass for Overview, Settings, Help and Core/update recovery using the fail-closed `dev.yilin.Vela.VisualTests` fixture.
- Unsigned Debug and Release builds pass.

The initial in-sandbox CI attempt was not an application failure: SwiftPM was denied by `sandbox-exec`. The identical repository command passed when allowed to execute with its normal build sandbox behavior. Privileged target availability is not treated as signed-host proof. The isolated UI fixture results likewise do not substitute for VoiceOver and keyboard/focus verification on the exact signed candidate.

### Measured runtime performance

Existing rendered evidence applies to the same production UI source and shows no threshold breach. No new real-use bottleneck was reproduced, so no performance refactor was made.

### Signed-host evidence

`NOT EXECUTED — EXPLICIT AUTHORIZATION REQUIRED`

### Release credential/configuration evidence

`PARTIAL — CURRENT-SOURCE SIGNING, EXPORT AND NOTARIZATION INTEGRATION PASSED; PRODUCTION CANDIDATE NOT EXECUTED`

The exported current-source sample proves Developer ID, nested Helper/Core/Sparkle signing, Hardened Runtime, Apple notarization, stapling and Gatekeeper acceptance. Apple submission `1a651f09-1e81-409b-9f6e-818e2b5e7a2f` was accepted. The sample used persistent local credentials and placeholder release configuration, so it is not the immutable production candidate. The installed `/Applications/Vela.app` remains an old invalid/non-candidate artifact and cannot close any release lane.

The earlier invalid submission `4b7f8e80-c9b0-42df-a885-613e63733f16` used the archive intermediate App before `exportArchive`; it is retained as a negative control and did not require a production-code fix.

### Upgrade and accessibility evidence

`PARTIAL — REPOSITORY MIGRATION AND ISOLATED UI INVARIANTS PASS; REAL CANDIDATE LANES NOT EXECUTED`

The current source passes 11 transaction/recovery/idempotence tests for profile schema migration and four rendered accessibility UI scenarios in addition to four source-contract tests. A previous signed Vela package to the exact production candidate upgrade, and a healthy signed-host VoiceOver/focus pass, remain unexecuted and must not be inferred from these repository-controlled results.

## Architecture preservation

No EngineStore split, Core workflow rewrite, global state owner or speculative abstraction was introduced. Runtime authority, mutation gates, privileged boundaries, configuration journals, Core trust, redaction and FaultInjector remain unchanged.

Do not release until RQ-004 and every explicitly gated matrix above has accepted evidence for the same candidate SHA. Failure to run a lane is not a pass.
